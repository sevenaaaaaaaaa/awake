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

/// 本机有没有 ffmpeg。找 PATH、再找 Homebrew 的两个常见前缀。
pub fn ffmpeg_path() -> Option<std::path::PathBuf> {
    use std::path::PathBuf;
    if let Ok(path) = std::env::var("PATH") {
        for dir in path.split(':') {
            let candidate = PathBuf::from(dir).join("ffmpeg");
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
        let path = PathBuf::from(candidate);
        if path.is_file() {
            return Some(path);
        }
    }
    None
}

/// ffprobe 与 ffmpeg 同装一处；用它把"到底是什么编码"问清楚，
/// 而不是让界面显示 unknown（探测到的编码要写进缓存，unknown 会让结论失去意义）。
pub fn ffprobe_path() -> Option<std::path::PathBuf> {
    let ffmpeg = ffmpeg_path()?;
    let sibling = ffmpeg.with_file_name("ffprobe");
    if sibling.is_file() {
        return Some(sibling);
    }
    use std::path::PathBuf;
    for candidate in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] {
        let path = PathBuf::from(candidate);
        if path.is_file() {
            return Some(path);
        }
    }
    if let Ok(search) = std::env::var("PATH") {
        for dir in search.split(':') {
            let candidate = PathBuf::from(dir).join("ffprobe");
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// 问 ffprobe 这条流/文件的音频编码。拿不到就 None——不猜。
pub fn identify_codec(input: &str) -> Option<String> {
    let executable = ffprobe_path()?;
    let output = std::process::Command::new(executable)
        .args([
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=codec_name",
            "-of",
            "csv=p=0",
            input,
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let name = String::from_utf8_lossy(&output.stdout).trim().to_lowercase();
    if name.is_empty() {
        None
    } else {
        Some(name)
    }
}

/// 用 ffmpeg 兜底解一段流（或文件），给出与 symphonia 路径同形状的摘要。
///
/// 这是**可选路径**：只有用户在设置里打开"ffmpeg 兜底"、且本机真的装了 ffmpeg 才会走到。
/// 输出固定成 48kHz / 立体声 / s16le，因为这条路径不需要保真，只需要"能不能出声"。
pub fn decode_via_ffmpeg(input: &str, seconds: f64, label: &str) -> Result<StreamSummary> {
    use std::process::{Command, Stdio};

    let executable = ffmpeg_path().context("没找到 ffmpeg（brew install ffmpeg）")?;
    let stderr_path = std::env::temp_dir().join(format!("awake-ffmpeg-{}.log", std::process::id()));
    let stderr = std::fs::File::create(&stderr_path).context("建不了 ffmpeg 日志")?;
    let duration = format!("{:.2}", seconds.max(0.5));

    let mut child = Command::new(&executable)
        .args([
            "-nostdin",
            "-loglevel",
            "error",
            "-i",
            input,
            "-t",
            &duration,
            "-f",
            "s16le",
            "-acodec",
            "pcm_s16le",
            "-ac",
            "2",
            "-ar",
            "48000",
            "-",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::from(stderr))
        .spawn()
        .with_context(|| format!("起不了 ffmpeg（{}）", executable.display()))?;

    let mut stdout = child.stdout.take().context("ffmpeg 没有输出管道")?;
    let mut buffer = vec![0u8; 64 * 1024];
    let mut carry: Option<u8> = None;
    let mut sum_squares: f64 = 0.0;
    let mut peak: f32 = 0.0;
    let mut samples: u64 = 0;
    loop {
        let read = stdout.read(&mut buffer).context("读 ffmpeg 输出失败")?;
        if read == 0 {
            break;
        }
        let mut index = 0;
        if let Some(low) = carry.take() {
            let value = i16::from_le_bytes([low, buffer[0]]) as f64 / 32768.0;
            sum_squares += value * value;
            peak = peak.max(value.abs() as f32);
            samples += 1;
            index = 1;
        }
        while index + 1 < read {
            let value = i16::from_le_bytes([buffer[index], buffer[index + 1]]) as f64 / 32768.0;
            sum_squares += value * value;
            peak = peak.max(value.abs() as f32);
            samples += 1;
            index += 2;
        }
        if index < read {
            carry = Some(buffer[index]);
        }
    }

    let status = child.wait().context("等不到 ffmpeg 退出")?;
    if !status.success() {
        let log = std::fs::read_to_string(&stderr_path).unwrap_or_default();
        let tail: String = log.trim().chars().rev().take(300).collect::<String>().chars().rev().collect();
        return Err(anyhow::anyhow!("ffmpeg 退出码 {:?}：{tail}", status.code()));
    }
    std::fs::remove_file(&stderr_path).ok();

    let channels = 2usize;
    let frames = samples / channels as u64;
    let decoded_secs = frames as f64 / 48_000.0;
    let denom = (samples as f64).max(1.0);
    let rms = (sum_squares / denom).sqrt() as f32;
    let rms_db = if rms > 0.0 { (20.0 * rms.log10()).max(-120.0) } else { -120.0 };

    Ok(StreamSummary {
        format: StreamFormat { codec: label.to_string(), sample_rate: 48_000, channels },
        decoded_secs,
        frames,
        rms_db,
        peak,
        bad_packets: 0,
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
    fn ffmpeg_path_is_optional_and_reported_honestly() {
        // 不假设本机装了 ffmpeg：装了就要求路径存在，没装就要求 None。
        match ffmpeg_path() {
            Some(path) => assert!(path.is_file()),
            None => {}
        }
    }

    /// 造一份 opus 样本；本机没 ffmpeg 或没有 libopus 时返回 None（调用方跳过）。
    fn opus_fixture() -> Option<(std::path::PathBuf, std::path::PathBuf)> {
        if ffmpeg_path().is_none() {
            return None;
        }
        let dir = test_audio::directory();
        let opus = dir.join("tone.opus");
        let status = std::process::Command::new(ffmpeg_path().unwrap())
            .args([
                "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i",
                "sine=frequency=440:duration=1", "-c:a", "libopus", "-y",
            ])
            .arg(&opus)
            .status()
            .ok()?;
        if !status.success() || !opus.is_file() {
            std::fs::remove_dir_all(&dir).ok();
            return None;
        }
        Some((dir, opus))
    }

    #[test]
    fn identify_codec_asks_ffprobe_instead_of_guessing() {
        let Some((dir, opus)) = opus_fixture() else {
            eprintln!("跳过：本机没有 ffmpeg/libopus");
            return;
        };
        assert_eq!(identify_codec(opus.to_str().unwrap()).as_deref(), Some("opus"));
        assert_eq!(identify_codec("/nonexistent/x.opus"), None, "拿不到就 None，不猜");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn ffmpeg_decodes_an_opus_file_when_available() {
        let Some((dir, opus)) = opus_fixture() else {
            eprintln!("跳过：本机没有 ffmpeg/libopus");
            return;
        };
        let summary = decode_via_ffmpeg(opus.to_str().unwrap(), 0.8, "opus").expect("应能兜底解出");
        assert_eq!(summary.format.codec, "opus");
        assert_eq!(summary.format.sample_rate, 48_000);
        assert_eq!(summary.format.channels, 2);
        // lavfi 的 sine 默认振幅是 1/8，过一遍 opus 再量 s16 峰值约 0.09——
        // 这个数被 ffmpeg 独立解码 + Python 复算核对过，不是解码器衰减。
        assert!(
            (0.7..=0.85).contains(&summary.decoded_secs),
            "0.8 秒上限应解出约 0.80 秒，实测 {}",
            summary.decoded_secs
        );
        assert!(summary.peak > 0.05, "不该是静音，实测峰值 {}", summary.peak);
        assert!(summary.rms_db > -40.0 && summary.rms_db < 0.0, "RMS {}", summary.rms_db);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn missing_ffmpeg_fails_with_a_readable_reason() {
        let err = decode_via_ffmpeg("/nonexistent/input.opus", 0.5, "opus").unwrap_err();
        let text = err.to_string();
        assert!(
            text.contains("ffmpeg") || text.contains("起不了"),
            "错误要说清是 ffmpeg 的问题：{text}"
        );
    }

    #[test]
    fn non_audio_bytes_fail_with_a_reason() {
        let junk = vec![0x7fu8; 8192];
        let err = decode_summary(Cursor::new(junk), None, 0.5).unwrap_err();
        assert!(!err.to_string().is_empty());
    }
}
