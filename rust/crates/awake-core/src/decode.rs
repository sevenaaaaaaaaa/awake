//! 解码层：把任意受支持格式统一成 f32 交错采样。
//!
//! 覆盖范围（与 README 一致的部分）：
//! FLAC / ALAC / WAV / AIFF / CAF / MP3 / AAC / OGG-Vorbis —— 由 symphonia 直接解码。
//! DSD（.dsf/.dff）与 APE 不在 symphonia 范围内，由 `fallback` 模块借 ffmpeg 转码兜底。

use anyhow::{anyhow, Context, Result};
use std::fs::File;
use std::path::{Path, PathBuf};

use symphonia::core::audio::AudioBufferRef;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

/// 一首曲目的格式描述。
#[derive(Debug, Clone)]
pub struct TrackFormat {
    pub path: PathBuf,
    pub sample_rate: u32,
    pub channels: usize,
    pub codec: String,
    /// 源文件位深（若可知）
    pub bits_per_sample: Option<u32>,
    pub duration_secs: Option<f64>,
}

impl TrackFormat {
    pub fn is_hires(&self) -> bool {
        self.sample_rate > 48_000 || self.bits_per_sample.map(|b| b > 16).unwrap_or(false)
    }
}

/// 已解码的一整首歌（内存版，便于 EQ 与频谱分析）。
pub struct DecodedAudio {
    pub format: TrackFormat,
    /// 交错排列，长度 = frames * channels
    pub samples: Vec<f32>,
}

impl DecodedAudio {
    pub fn frames(&self) -> usize {
        if self.format.channels == 0 {
            0
        } else {
            self.samples.len() / self.format.channels
        }
    }

    pub fn duration_secs(&self) -> f64 {
        self.frames() as f64 / self.format.sample_rate as f64
    }

    /// 峰值（线性），用于限幅判断。
    pub fn peak(&self) -> f32 {
        self.samples.iter().fold(0.0f32, |acc, s| acc.max(s.abs()))
    }
}

fn open_probe(path: &Path) -> Result<Box<dyn symphonia::core::formats::FormatReader>> {
    let file = File::open(path).with_context(|| format!("打不开文件: {}", path.display()))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .context("无法识别音频格式（可能是不受支持的编码）")?;

    Ok(probed.format)
}

/// 只读文件头，拿到格式信息，不解码全部音频。
pub fn probe_format(path: impl AsRef<Path>) -> Result<TrackFormat> {
    let path = path.as_ref();
    let mut reader = open_probe(path)?;

    let track = reader
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| anyhow!("文件里没有可解码的音轨"))?;

    let params = &track.codec_params;
    let sample_rate = params.sample_rate.unwrap_or(44_100);
    let channels = params.channels.map(|c| c.count()).unwrap_or(2);
    let bits = params.bits_per_sample;
    let duration = params
        .n_frames
        .map(|n| n as f64 / sample_rate as f64)
        .or_else(|| {
            track
                .codec_params
                .time_base
                .zip(params.n_frames)
                .map(|(tb, n)| tb.calc_time(n).seconds as f64)
        });

    let codec = symphonia::default::get_codecs()
        .get_codec(params.codec)
        .map(|d| d.short_name.to_string())
        .unwrap_or_else(|| "unknown".to_string());

    Ok(TrackFormat {
        path: path.to_path_buf(),
        sample_rate,
        channels,
        codec,
        bits_per_sample: bits,
        duration_secs: duration,
    })
}

/// 完整解码到内存。演示曲库 9 首、单首几分钟，内存足以支撑。
pub fn decode_file(path: impl AsRef<Path>) -> Result<DecodedAudio> {
    let path = path.as_ref();
    let mut reader = open_probe(path)?;

    let track = reader
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| anyhow!("文件里没有可解码的音轨"))?
        .clone();

    let track_id = track.id;
    let params = track.codec_params.clone();
    let sample_rate = params.sample_rate.unwrap_or(44_100);
    let channels = params.channels.map(|c| c.count()).unwrap_or(2);
    let bits = params.bits_per_sample;

    let mut decoder = symphonia::default::get_codecs()
        .make(&params, &DecoderOptions::default())
        .context("找不到对应的解码器")?;

    let codec = symphonia::default::get_codecs()
        .get_codec(params.codec)
        .map(|d| d.short_name.to_string())
        .unwrap_or_else(|| "unknown".to_string());

    let mut samples: Vec<f32> = Vec::new();
    let mut scratch: Vec<f32> = Vec::new();

    loop {
        let packet = match reader.next_packet() {
            Ok(p) => p,
            Err(symphonia::core::errors::Error::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(symphonia::core::errors::Error::ResetRequired) => break,
            Err(e) => return Err(anyhow!("读取音频包失败: {e}")),
        };

        if packet.track_id() != track_id {
            continue;
        }

        match decoder.decode(&packet) {
            Ok(buf) => append_interleaved(&buf, &mut samples, &mut scratch),
            Err(symphonia::core::errors::Error::DecodeError(msg)) => {
                log::warn!("跳过损坏的包: {msg}");
                continue;
            }
            Err(e) => return Err(anyhow!("解码失败: {e}")),
        }
    }

    if samples.is_empty() {
        return Err(anyhow!("解码结果为空: {}", path.display()));
    }

    let format = TrackFormat {
        path: path.to_path_buf(),
        sample_rate,
        channels,
        codec,
        bits_per_sample: bits,
        duration_secs: Some(samples.len() as f64 / channels as f64 / sample_rate as f64),
    };

    Ok(DecodedAudio { format, samples })
}

fn append_interleaved(buf: &AudioBufferRef<'_>, out: &mut Vec<f32>, scratch: &mut Vec<f32>) {
    let spec = *buf.spec();
    let frames = buf.frames();
    let channels = spec.channels.count();

    // 复用同一块缓冲，避免每包都重新分配
    scratch.clear();
    scratch.resize(frames * channels, 0.0);

    let mut sb = symphonia::core::audio::SampleBuffer::<f32>::new(frames as u64, spec);
    sb.copy_interleaved_ref(buf.clone());
    out.extend_from_slice(sb.samples());
}

impl TrackFormat {
    /// 是否属于需要 ffmpeg 兜底的格式（DSD / APE）。
    pub fn needs_fallback(path: &Path) -> bool {
        matches!(
            path.extension().and_then(|e| e.to_str()).map(|s| s.to_ascii_lowercase()).as_deref(),
            Some("dsf") | Some("dff") | Some("ape") | Some("wv")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn demo_file() -> Option<PathBuf> {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../DemoMusic");
        let entries = std::fs::read_dir(dir).ok()?;
        for e in entries.flatten() {
            let p = e.path();
            if p.extension().and_then(|x| x.to_str()) == Some("flac") {
                return Some(p);
            }
        }
        None
    }

    #[test]
    fn probes_demo_flac() {
        let Some(path) = demo_file() else {
            eprintln!("跳过：演示曲库尚未生成");
            return;
        };
        let fmt = probe_format(&path).expect("应能读出格式");
        assert_eq!(fmt.channels, 2, "演示曲应为立体声");
        assert_eq!(fmt.sample_rate, 96_000, "演示曲为 96 kHz，实测 {}", fmt.sample_rate);
        assert!(fmt.is_hires(), "24bit/96k 应判定为 hires");
    }

    #[test]
    fn decodes_demo_flac_to_pcm() {
        let Some(path) = demo_file() else {
            eprintln!("跳过：演示曲库尚未生成");
            return;
        };
        let audio = decode_file(&path).expect("应能解码");
        assert!(audio.frames() > 96_000, "至少 1 秒音频，实测 {} 帧", audio.frames());
        assert_eq!(audio.samples.len(), audio.frames() * audio.format.channels);
        assert!(audio.peak() > 0.001, "不应全是静音");
    }
}
