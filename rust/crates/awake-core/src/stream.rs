//! 直播流解码：把"只能向前读、不可 seek、没有长度"的字节流接进 symphonia。
//!
//! 与文件解码的区别，全部体现在这里：
//! - `is_seekable() == false`、`byte_len() == None`：直播没有总长，也不能拖；
//! - 没有 `duration`：界面只能显示"直播"，进度条没有意义；
//! - 坏帧很常见：单帧解码失败跳过，不当作整条流失败；
//! - 流可能永远不结束：调用方给 `max_secs` 上限，避免探针挂死。
//!
//! 网络怎么来，这个模块不管：任何 `Read + Send + Sync` 都行
//! （curl 管道、reqwest 字节流、TcpStream 都可以）。这样同一段解码逻辑
//! 既能被单测喂本地字节，也能被运行期喂真实电台。

use anyhow::{Context, Result};
use std::io::{self, Read, Seek, SeekFrom};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{
    CodecType, DecoderOptions, CODEC_TYPE_AAC, CODEC_TYPE_ALAC, CODEC_TYPE_FLAC, CODEC_TYPE_MP3,
    CODEC_TYPE_NULL, CODEC_TYPE_OPUS, CODEC_TYPE_PCM_ALAW, CODEC_TYPE_PCM_F32LE,
    CODEC_TYPE_PCM_MULAW, CODEC_TYPE_PCM_S16LE, CODEC_TYPE_VORBIS,
};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::{MediaSource, MediaSourceStream};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

/// 把任意只前向的读取器适配成 symphonia 的数据源。
pub struct StreamSource<R> {
    inner: R,
    bytes_read: u64,
}

impl<R: Read> StreamSource<R> {
    pub fn new(inner: R) -> Self {
        Self { inner, bytes_read: 0 }
    }

    pub fn bytes_read(&self) -> u64 {
        self.bytes_read
    }
}

impl<R: Read> Read for StreamSource<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.bytes_read += n as u64;
        Ok(n)
    }
}

// symphonia 0.5 的 MediaSource 要求同时实现 Seek。直播不能定位，所以明确报 Unsupported，
// 而不是假装能 seek——假装会让 probe 拿到错的长度或位置。
impl<R: Read> Seek for StreamSource<R> {
    fn seek(&mut self, _pos: SeekFrom) -> io::Result<u64> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "直播流不支持定位"))
    }
}

impl<R: Read + Send + Sync> MediaSource for StreamSource<R> {
    fn is_seekable(&self) -> bool {
        false
    }

    fn byte_len(&self) -> Option<u64> {
        None
    }
}

/// symphonia 的 CodecType 是 `CodecType(u32)`，Display 出来是 `0x108` 这种十六进制。
/// 报给人看要名字，所以这里显式映射我们关心的那几个；没映射的保留十六进制，别编。
pub fn codec_label(codec: CodecType) -> &'static str {
    if codec == CODEC_TYPE_MP3 {
        "mp3"
    } else if codec == CODEC_TYPE_AAC {
        "aac"
    } else if codec == CODEC_TYPE_VORBIS {
        "vorbis"
    } else if codec == CODEC_TYPE_OPUS {
        "opus"
    } else if codec == CODEC_TYPE_FLAC {
        "flac"
    } else if codec == CODEC_TYPE_ALAC {
        "alac"
    } else if codec == CODEC_TYPE_PCM_S16LE {
        "pcm_s16le"
    } else if codec == CODEC_TYPE_PCM_F32LE {
        "pcm_f32le"
    } else if codec == CODEC_TYPE_PCM_ALAW {
        "pcm_alaw"
    } else if codec == CODEC_TYPE_PCM_MULAW {
        "pcm_mulaw"
    } else {
        "unknown"
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct StreamFormat {
    pub codec: String,
    pub sample_rate: u32,
    pub channels: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StreamSummary {
    pub format: StreamFormat,
    /// 实际解出的音频时长（秒）。直播里它只代表"我们听了多久"。
    pub decoded_secs: f64,
    pub frames: u64,
    /// 均方根电平（dBFS）。全静音会给 -120。
    pub rms_db: f32,
    pub peak: f32,
    /// 跳过的坏帧数：直播常见，报出来比藏起来好。
    pub bad_packets: usize,
}

/// 解一小段流并给出可核对的数字。`extension_hint` 只是帮 probe 少猜（如 "mp3"）。
pub fn decode_summary<R: Read + Send + Sync + 'static>(
    reader: R,
    extension_hint: Option<&str>,
    max_secs: f64,
) -> Result<StreamSummary> {
    let source = StreamSource::new(reader);
    let mss = MediaSourceStream::new(Box::new(source), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = extension_hint {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .context("这不是能识别的音频流")?;
    let mut format = probed.format;

    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .context("流里没有可解码的音频轨")?;
    let track_id = track.id;
    let params = track.codec_params.clone();
    let sample_rate = params.sample_rate.unwrap_or(0);
    let channels = params.channels.map(|c| c.count()).unwrap_or(0);
    let codec = codec_label(params.codec).to_string();

    let mut decoder = symphonia::default::get_codecs()
        .make(&params, &DecoderOptions::default())
        .context("这个编码不在解码器覆盖范围内")?;

    let mut frames: u64 = 0;
    let mut sum_squares: f64 = 0.0;
    let mut peak: f32 = 0.0;
    let mut bad_packets = 0usize;

    while max_secs <= 0.0 || (sample_rate > 0 && (frames as f64 / sample_rate as f64) < max_secs) {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(SymphoniaError::IoError(err)) if err.kind() == io::ErrorKind::UnexpectedEof => break,
            Err(SymphoniaError::ResetRequired) => break,
            Err(err) => return Err(err).context("读流失败"),
        };
        if packet.track_id() != track_id {
            continue;
        }
        match decoder.decode(&packet) {
            Ok(buffer) => {
                let spec = *buffer.spec();
                let mut samples = SampleBuffer::<f32>::new(buffer.capacity() as u64, spec);
                samples.copy_interleaved_ref(buffer);
                let data = samples.samples();
                for value in data {
                    let v = *value as f64;
                    sum_squares += v * v;
                    peak = peak.max(v.abs() as f32);
                }
                let channels_here = spec.channels.count().max(1);
                frames += (data.len() / channels_here) as u64;
            }
            // 直播里坏一帧就整条失败，等于把能听的台判成不能听。
            Err(SymphoniaError::DecodeError(_)) => bad_packets += 1,
            Err(SymphoniaError::ResetRequired) => break,
            Err(err) => return Err(err).context("解码失败"),
        }
    }

    let decoded_secs = if sample_rate > 0 { frames as f64 / sample_rate as f64 } else { 0.0 };
    let denom = (frames as f64 * channels.max(1) as f64).max(1.0);
    let rms = (sum_squares / denom).sqrt() as f32;
    let rms_db = if rms > 0.0 { (20.0 * rms.log10()).max(-120.0) } else { -120.0 };

    Ok(StreamSummary {
        format: StreamFormat { codec, sample_rate, channels },
        decoded_secs,
        frames,
        rms_db,
        peak,
        bad_packets,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_audio;
    use std::io::Cursor;

    fn wav_bytes() -> Vec<u8> {
        let dir = test_audio::directory();
        let path = dir.join("tone.wav");
        // 1 秒 440Hz 正弦，48kHz 立体声
        let rate = 48_000u32;
        let channels = 2u16;
        let samples: Vec<i16> = (0..rate)
            .flat_map(|i| {
                let v = ((i as f32 * 2.0 * std::f32::consts::PI * 440.0 / rate as f32).sin()
                    * 0.5
                    * i16::MAX as f32) as i16;
                [v, v]
            })
            .collect();
        test_audio::wav(&path, rate, channels, &samples);
        let bytes = std::fs::read(&path).expect("fixture 必须可读");
        std::fs::remove_dir_all(&dir).ok();
        bytes
    }

    #[test]
    fn streaming_source_is_never_seekable_and_has_no_length() {
        let source = StreamSource::new(Cursor::new(vec![1u8, 2, 3]));
        assert!(!source.is_seekable());
        assert_eq!(source.byte_len(), None);
    }

    #[test]
    fn decodes_a_wav_through_a_non_seekable_reader() {
        let bytes = wav_bytes();
        let summary = decode_summary(Cursor::new(bytes), Some("wav"), 0.5).expect("应能解码");
        assert_eq!(summary.format.codec, "pcm_s16le");
        assert_eq!(summary.format.sample_rate, 48_000);
        assert_eq!(summary.format.channels, 2);
        assert!(summary.decoded_secs > 0.2, "至少解出 0.2 秒，实测 {}", summary.decoded_secs);
        assert!(summary.peak > 0.3, "正弦峰值应在 0.5 附近，实测 {}", summary.peak);
        assert!(summary.rms_db > -20.0 && summary.rms_db < 0.0, "RMS {} dBFS", summary.rms_db);
    }

    #[test]
    fn max_seconds_is_respected() {
        let bytes = wav_bytes();
        let short = decode_summary(Cursor::new(bytes.clone()), Some("wav"), 0.1).expect("应能解码");
        let long = decode_summary(Cursor::new(bytes), Some("wav"), 0.9).expect("应能解码");
        assert!(short.decoded_secs < long.decoded_secs, "上限要真的生效");
        assert!(short.decoded_secs <= 0.35, "0.1 秒上限不该解出 {} 秒", short.decoded_secs);
    }

    #[test]
    fn non_audio_bytes_fail_with_a_reason() {
        let junk = vec![0x7fu8; 8192];
        let err = decode_summary(Cursor::new(junk), None, 0.5).unwrap_err();
        assert!(!err.to_string().is_empty());
    }
}
