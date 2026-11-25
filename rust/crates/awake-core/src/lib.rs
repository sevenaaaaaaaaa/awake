//! Awake 的 Rust 音频核心。
//!
//! Swift 版 `AwakeCore` 的等价迁移，数值与行为均可验证：
//! - `decode`：统一解码到 f32 交错采样
//! - `eq`：31 段 ISO 1/3 倍频程图形 EQ + 参数 EQ + 自动余量
//! - `analyze`：32 段频谱与整曲画像
//! - `resample`：设备不支持原生采样率时的兜底
//! - `models` / `metadata` / `library`：曲库、标签与扫描

pub mod adapt;
pub mod analyze;
pub mod artist;
pub mod books;
pub mod classical;
pub mod decode;
pub mod eq;
pub mod feedmeta;
pub mod library;
pub mod listening;
pub mod lyrics;
pub mod media_info;
pub mod metadata;
pub mod models;
pub mod musicbee;
pub mod musicbee_import;
pub mod musicbee_tags;
pub mod parametric;
pub mod pipeline;
pub mod radio;
pub mod resample;
pub mod shelf;
pub mod stream;
pub mod taste;

pub use analyze::{to_mono, Spectrum, SpectrumAnalyzer};
pub use decode::{decode_file, probe_format, DecodedAudio, TrackFormat};
pub use eq::{EqCurve, Equalizer, BAND_COUNT, EQ_BAND_FREQUENCIES};
pub use library::{collect_audio_files, scan_local_files, scan_local_source, Library};
pub use listening::{
    apply_prior, match_curves, normalize_title, parse_profile, same_device, stale_hint,
    track_fingerprint, CurveBasis, CurveMatch, EarPrior, ListeningProfile, MatchReport,
    ProfileError, RejectReason, RejectedCurve, SongCurve, TrackRef, Unmatched, UnmatchedReason,
};
pub use metadata::{read_tags, AudioTags};
pub use models::{group_albums, Album, LibrarySnapshot, MediaSource, SourceKind, Track};
pub use resample::resample_interleaved;

#[cfg(test)]
pub(crate) mod test_audio;

pub use symphonia::core::io as symphonia_source;

pub mod chain;
