//! 曲库数据模型 —— 与 Swift 版 `Track` / `MediaSource` / `Album` 一一对应。

use serde::{Deserialize, Serialize};

/// 曲库来源类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SourceKind {
    Local,
    Smb,
    Webdav,
    Plex,
    Telegram,
}

impl SourceKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            SourceKind::Local => "local",
            SourceKind::Smb => "smb",
            SourceKind::Webdav => "webdav",
            SourceKind::Plex => "plex",
            SourceKind::Telegram => "telegram",
        }
    }

    pub fn title(&self) -> &'static str {
        match self {
            SourceKind::Local => "本地文件夹",
            SourceKind::Smb => "SMB / NAS",
            SourceKind::Webdav => "WebDAV",
            SourceKind::Plex => "Plex",
            SourceKind::Telegram => "Telegram 个人媒体库",
        }
    }
}

/// 一个曲库来源。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaSource {
    pub id: String,
    pub kind: SourceKind,
    pub name: String,
    /// 本地路径，或 smb/webdav/plex 的服务器地址
    pub url: String,
    pub username: String,
    /// 钥匙串键名（Rust 侧写入系统钥匙串）
    pub password_key: String,
    pub token: String,
    pub enabled: bool,
    /// Unix 毫秒
    pub last_scan: Option<i64>,
    pub track_count: usize,
    /// 仅此来源放宽 HTTPS 证书校验（自签名 NAS）。默认关闭；不要对公网地址开启。
    #[serde(default)]
    pub trust_self_signed: bool,
    /// Plex 音乐库分区 key（空表示整个服务器的全部音乐分区）。
    #[serde(default)]
    pub section: String,
    /// 「本地文件」来源的显式文件清单；为空表示按 url 目录递归扫描。
    #[serde(default)]
    pub files: Vec<String>,
}

impl MediaSource {
    pub fn new(kind: SourceKind, name: impl Into<String>, url: impl Into<String>) -> Self {
        let id = new_id();
        let password_key = format!("awake.{id}");
        Self {
            id,
            kind,
            name: name.into(),
            url: url.into(),
            username: String::new(),
            password_key,
            token: String::new(),
            enabled: true,
            last_scan: None,
            track_count: 0,
            trust_self_signed: false,
            section: String::new(),
            files: Vec::new(),
        }
    }
}

/// 一首曲目。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Track {
    pub id: String,
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
    pub source_id: String,
    /// 本地为相对来源根目录的路径；远程为 provider key
    pub locator: String,
    pub file_size: i64,
    /// Unix 毫秒
    pub modified: i64,
    pub artwork_path: Option<String>,
    pub play_count: u32,
    pub favorite: bool,
    pub last_played: Option<i64>,
    pub added_at: i64,
    pub is_remote: bool,
    /// Original Telegram message URL; old libraries remain readable.
    #[serde(default)]
    pub origin_url: Option<String>,
    #[serde(default)]
    pub comment: String,
    #[serde(default)]
    pub lyrics: String,
    #[serde(default)]
    pub media_info: Option<crate::media_info::MediaInfo>,
}

impl Track {
    /// 专辑归并键：album_artist（空则 artist）| album，全小写。
    pub fn album_key(&self) -> String {
        let aa = if self.album_artist.is_empty() {
            &self.artist
        } else {
            &self.album_artist
        };
        format!("{}|{}", aa.to_lowercase(), self.album.to_lowercase())
    }

    pub fn is_hires(&self) -> bool {
        self.sample_rate > 48_000 || self.bit_depth > 16
    }

    /// 品质标签，与 Swift `qualityLabel` 同规则。
    pub fn quality_label(&self) -> String {
        if self.sample_rate == 0 {
            return if self.codec.is_empty() {
                "待解析".into()
            } else {
                format!("{} 待解析", self.codec)
            };
        }
        if self.codec.eq_ignore_ascii_case("DSD") {
            let multiple = (self.sample_rate as f64 / 44_100.0).round() as i32;
            let mhz = self.sample_rate as f64 / 1_000_000.0;
            let mut label = if multiple > 0 {
                format!("DSD{multiple} 1-bit/{mhz:.1} MHz")
            } else {
                format!("DSD 1-bit/{mhz:.1} MHz")
            };
            if self.channels > 2 {
                label.push_str(&format!(" {}ch", self.channels));
            }
            return label;
        }
        let khz = if self.sample_rate >= 1000 {
            format!("{:.1}", self.sample_rate as f64 / 1000.0)
        } else {
            self.sample_rate.to_string()
        };
        let codec = if self.codec.is_empty() {
            "PCM"
        } else {
            &self.codec
        };
        let mut label = format!("{codec} {}-bit / {khz} kHz", self.bit_depth);
        if self.channels > 2 {
            label.push_str(&format!(" {}ch", self.channels));
        }
        label
    }

    /// 稳定 ID：sha256(source_id|locator) 取前 16 位十六进制。
    pub fn make_id(source_id: &str, locator: &str) -> String {
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(format!("{source_id}|{locator}").as_bytes());
        let digest = hasher.finalize();
        digest.iter().take(8).map(|b| format!("{b:02x}")).collect()
    }
}

/// 专辑（由曲目聚合而成）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Album {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub year: Option<i32>,
    pub artwork_path: Option<String>,
    pub tracks: Vec<Track>,
}

impl Album {
    pub fn duration(&self) -> f64 {
        self.tracks.iter().map(|t| t.duration).sum()
    }

    pub fn is_hires(&self) -> bool {
        self.tracks.iter().any(|t| t.is_hires())
    }
}

/// 曲库快照（落盘格式）。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LibrarySnapshot {
    pub tracks: Vec<Track>,
    pub sources: Vec<MediaSource>,
    pub scanned_at: Option<i64>,
}

/// 生成 UUID v4。使用系统随机源，避免并发任务依赖墙上时钟产生相同 ID。
pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// 当前 Unix 毫秒。
pub fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 按专辑分组并按碟/轨排序，与 Swift `Array<Track>.albums` 同规则。
pub fn group_albums(tracks: &[Track]) -> Vec<Album> {
    use std::collections::HashMap;
    let mut buckets: HashMap<String, Vec<Track>> = HashMap::new();
    for t in tracks {
        buckets.entry(t.album_key()).or_default().push(t.clone());
    }

    let mut albums: Vec<Album> = buckets
        .into_iter()
        .map(|(key, mut list)| {
            list.sort_by(|a, b| {
                let da = a.disc_number.unwrap_or(1);
                let db = b.disc_number.unwrap_or(1);
                if da != db {
                    return da.cmp(&db);
                }
                let ta = a.track_number.unwrap_or(0);
                let tb = b.track_number.unwrap_or(0);
                if ta != tb {
                    return ta.cmp(&tb);
                }
                a.title.to_lowercase().cmp(&b.title.to_lowercase())
            });
            let first = list.first().cloned();
            Album {
                id: key,
                title: first
                    .as_ref()
                    .map(|t| {
                        if t.album.is_empty() {
                            "未命名专辑".to_string()
                        } else {
                            t.album.clone()
                        }
                    })
                    .unwrap_or_else(|| "未命名专辑".into()),
                artist: first
                    .as_ref()
                    .map(|t| t.album_artist.clone())
                    .unwrap_or_default(),
                year: first.as_ref().and_then(|t| t.year),
                artwork_path: list.iter().find_map(|t| t.artwork_path.clone()),
                tracks: list,
            }
        })
        .collect();

    albums.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    albums
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_track() -> Track {
        Track {
            id: "x".into(),
            title: "曲".into(),
            artist: "歌手".into(),
            album_artist: "".into(),
            album: "专辑".into(),
            genre: "".into(),
            year: Some(2024),
            track_number: Some(1),
            disc_number: None,
            duration: 200.0,
            sample_rate: 96_000,
            bit_depth: 24,
            channels: 2,
            codec: "flac".into(),
            source_id: "src".into(),
            locator: "a.flac".into(),
            file_size: 1,
            modified: 0,
            artwork_path: None,
            play_count: 0,
            favorite: false,
            last_played: None,
            added_at: 0,
            is_remote: false,
            origin_url: None,
            comment: String::new(),
            lyrics: String::new(),
            media_info: None,
        }
    }

    #[test]
    fn album_key_falls_back_to_artist() {
        let t = sample_track();
        assert_eq!(t.album_key(), "歌手|专辑");
    }

    #[test]
    fn quality_label_matches_swift() {
        let t = sample_track();
        assert_eq!(t.quality_label(), "flac 24-bit / 96.0 kHz");
        assert!(t.is_hires());
    }

    #[test]
    fn track_id_is_stable_and_short() {
        let a = Track::make_id("src1", "dir/a.flac");
        let b = Track::make_id("src1", "dir/a.flac");
        let c = Track::make_id("src1", "dir/b.flac");
        assert_eq!(a, b, "同输入必须同 ID");
        assert_ne!(a, c);
        assert_eq!(a.len(), 16, "ID 应为 16 位十六进制");
    }

    #[test]
    fn old_sources_load_without_the_trust_flag() {
        let json = r#"{"id":"x","kind":"webdav","name":"NAS","url":"https://nas.local/dav/","username":"u","password_key":"k","token":"","enabled":true,"last_scan":null,"track_count":0}"#;
        let source: MediaSource = serde_json::from_str(json).unwrap();
        assert!(!source.trust_self_signed, "旧曲库默认严格校验证书");
        let newer = MediaSource::new(SourceKind::Webdav, "NAS", "https://nas.local/dav/");
        assert!(!newer.trust_self_signed);
    }

    #[test]
    fn groups_albums_and_sorts_tracks() {
        let mut t1 = sample_track();
        t1.track_number = Some(3);
        let mut t2 = sample_track();
        t2.track_number = Some(1);
        let albums = group_albums(&[t1, t2]);
        assert_eq!(albums.len(), 1);
        assert_eq!(albums[0].tracks[0].track_number, Some(1), "轨号应升序");
    }
}
