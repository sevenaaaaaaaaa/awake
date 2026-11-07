//! Awake 的 Rust 音频核心。
//!
//! Swift 版 `AwakeCore` 的等价迁移，数值与行为均可验证：
//! - `decode`：统一解码到 f32 交错采样
//! - `eq`：31 段 ISO 1/3 倍频程图形 EQ + 参数 EQ + 自动余量
//! - `analyze`：32 段频谱与整曲画像
//! - `resample`：设备不支持原生采样率时的兜底
//! - `models` / `metadata` / `library`：曲库、标签与扫描

pub mod analyze;
pub mod decode;
pub mod eq;
pub mod library;
pub mod metadata;
pub mod models;
pub mod resample;

pub use analyze::{to_mono, Spectrum, SpectrumAnalyzer};
pub use decode::{decode_file, probe_format, DecodedAudio, TrackFormat};
pub use eq::{EqCurve, Equalizer, EQ_BAND_FREQUENCIES, BAND_COUNT};
pub use library::{collect_audio_files, scan_local_source, Library};
pub use metadata::{read_tags, AudioTags};
pub use models::{group_albums, Album, LibrarySnapshot, MediaSource, SourceKind, Track};
pub use resample::resample_interleaved;
