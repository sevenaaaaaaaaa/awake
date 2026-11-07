//! 元数据读取 —— 对应 Swift `TagReader`。用 lofty 读取内嵌标签与封面。

use crate::models::Track;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::prelude::Accessor;
use std::path::Path;

/// 从文件读出的标签集合，与 Swift `AudioTags` 字段对应。
#[derive(Debug, Clone, Default)]
pub struct AudioTags {
    pub title: String,
    pub artist: String,
    pub album_artist: String,
    pub album: String,
    pub genre: String,
    pub year: Option<i32>,
    pub track_number: Option<u32>,
    pub disc_number: Option<u32>,
    pub duration: f64,
    pub sample_rate: u32,
    pub bit_depth: u32,
    pub channels: u16,
    pub codec: String,
    pub artwork: Option<Vec<u8>>,
}

/// 由扩展名推断编码名，与 Swift `codecLabel` 同规则。
pub fn codec_label(ext: &str) -> String {
    match ext.to_ascii_lowercase().as_str() {
        "flac" => "FLAC",
        "m4a" | "m4b" => "ALAC",
        "alac" => "ALAC",
        "mp3" => "MP3",
        "aac" => "AAC",
        "wav" => "WAV",
        "aiff" | "aif" => "AIFF",
        "caf" => "CAF",
        "ogg" | "opus" => "Vorbis",
        "dsf" | "dff" => "DSD",
        "ape" => "APE",
        "wv" => "WavPack",
        _ => "PCM",
    }
    .to_string()
}

/// 读取一首曲目的标签。失败时返回只带扩展名信息的默认值，不中断扫描。
pub fn read_tags(path: &Path) -> AudioTags {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    let mut tags = AudioTags {
        codec: codec_label(&ext),
        ..Default::default()
    };

    let tagged = match lofty::read_from_path(path) {
        Ok(t) => t,
        Err(e) => {
            log::debug!("读取标签失败 {}: {e}", path.display());
            // 退回文件名当标题，保证条目不空
            tags.title = path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("未知曲目")
                .to_string();
            return tags;
        }
    };

    // 音频属性（时长/采样率/位深/声道）
    let props = tagged.properties();
    tags.duration = props.duration().as_secs_f64();
    tags.sample_rate = props.sample_rate().unwrap_or(0);
    tags.bit_depth = props.bit_depth().map(|b| b as u32).unwrap_or(0);
    tags.channels = props.channels().unwrap_or(2) as u16;

    // 标签
    if let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) {
        tags.title = tag.title().map(|s| s.to_string()).unwrap_or_default();
        tags.artist = tag.artist().map(|s| s.to_string()).unwrap_or_default();
        tags.album = tag.album().map(|s| s.to_string()).unwrap_or_default();
        tags.genre = tag.genre().map(|s| s.to_string()).unwrap_or_default();
        tags.year = tag.year().map(|y| y as i32);
        tags.track_number = tag.track();
        tags.disc_number = tag.disk();
        tags.album_artist = tag
            .get_string(&lofty::tag::ItemKey::AlbumArtist)
            .map(|s| s.to_string())
            .unwrap_or_default();

        // 内嵌封面取第一张
        if let Some(pic) = tag.pictures().first() {
            let data = pic.data();
            if !data.is_empty() {
                tags.artwork = Some(data.to_vec());
            }
        }
    }

    if tags.title.trim().is_empty() {
        tags.title = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("未知曲目")
            .to_string();
    }
    if tags.album_artist.trim().is_empty() {
        tags.album_artist = tags.artist.clone();
    }
    if tags.sample_rate == 0 {
        tags.sample_rate = 44_100;
    }
    if tags.bit_depth == 0 {
        tags.bit_depth = 16;
    }

    tags
}

/// 用标签补全一条由文件名建立的占位曲目，与 Swift `Track.applying(_:)` 同规则。
pub fn apply_tags(track: &mut Track, tags: &AudioTags) {
    macro_rules! fill {
        ($field:ident, $src:expr) => {
            let v: &str = $src;
            if !v.trim().is_empty() {
                track.$field = v.trim().to_string();
            }
        };
    }
    fill!(title, &tags.title);
    fill!(artist, &tags.artist);
    fill!(album_artist, &tags.album_artist);
    fill!(album, &tags.album);
    fill!(genre, &tags.genre);
    fill!(codec, &tags.codec);

    if tags.year.is_some() {
        track.year = tags.year;
    }
    if tags.track_number.is_some() {
        track.track_number = tags.track_number;
    }
    if tags.disc_number.is_some() {
        track.disc_number = tags.disc_number;
    }
    if tags.duration > 0.0 {
        track.duration = tags.duration;
    }
    if tags.sample_rate > 0 {
        track.sample_rate = tags.sample_rate;
    }
    if tags.bit_depth > 0 {
        track.bit_depth = tags.bit_depth;
    }
    if tags.channels > 0 {
        track.channels = tags.channels;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn demo_file() -> Option<PathBuf> {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../DemoMusic");
        for entry in std::fs::read_dir(dir).ok()?.flatten() {
            let p = entry.path();
            if p.is_dir() {
                for e2 in std::fs::read_dir(&p).ok()?.flatten() {
                    let f = e2.path();
                    if f.extension().and_then(|x| x.to_str()) == Some("flac") {
                        return Some(f);
                    }
                }
            }
        }
        None
    }

    #[test]
    fn reads_title_and_audio_properties() {
        let Some(path) = demo_file() else {
            eprintln!("跳过：演示曲库未生成");
            return;
        };
        let tags = read_tags(&path);
        assert!(!tags.title.is_empty(), "标题不应为空");
        assert_eq!(tags.sample_rate, 96_000, "演示曲为 96 kHz");
        assert_eq!(tags.bit_depth, 24, "演示曲为 24-bit");
        assert_eq!(tags.channels, 2);
        assert!(tags.duration > 10.0, "时长应被读出");
        assert_eq!(tags.codec, "FLAC");
    }

    #[test]
    fn reads_embedded_artwork() {
        let Some(path) = demo_file() else {
            eprintln!("跳过：演示曲库未生成");
            return;
        };
        let tags = read_tags(&path);
        assert!(tags.artwork.is_some(), "演示曲应带内嵌封面");
        assert!(tags.artwork.unwrap().len() > 1000, "封面应有实际内容");
    }
}
