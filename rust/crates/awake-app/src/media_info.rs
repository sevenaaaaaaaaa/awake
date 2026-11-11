use crate::AppState;
use awake_core::{
    media_info::{MediaInfo, Review},
    models::{now_ms, SourceKind},
    Track,
};
use reqwest::{blocking::Client, Url};
use serde::{Deserialize, Serialize};
#[cfg(test)]
use serde_json::json;
use serde_json::Value;
use std::{
    io::Read,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant},
};
use tauri::State;

const AGENT: &str = "Awake/0.6.2 (https://github.com/sevenaaaaaaaaa/awake)";
static LAST_REQUEST: Mutex<Option<Instant>> = Mutex::new(None);
fn json_get(url: Url) -> Result<Value, String> {
    let mut last = LAST_REQUEST.lock().map_err(|_| "资料服务繁忙")?;
    if let Some(at) = *last {
        std::thread::sleep(Duration::from_millis(1100).saturating_sub(at.elapsed()));
    }
    *last = Some(Instant::now());
    let client = Client::builder()
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(AGENT)
        .build()
        .map_err(|e| e.to_string())?;
    let response = client.get(url).send().map_err(|_| "资料服务连接失败")?;
    if response.status().as_u16() == 404 {
        return Ok(Value::Null);
    }
    if !response.status().is_success() {
        return Err(format!(
            "资料服务 HTTP {}，请稍后重试",
            response.status().as_u16()
        ));
    }
    let mut bytes = vec![];
    response
        .take(2 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "资料读取失败")?;
    if bytes.len() > 2 * 1024 * 1024 {
        return Err("资料响应过大".into());
    }
    serde_json::from_slice(&bytes).map_err(|_| "资料 JSON 无效".into())
}
fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.chars().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == '-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Candidate {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub release_id: String,
    pub group_id: String,
    pub duration: f64,
    pub score: i64,
}
pub fn parse_candidates(value: &Value) -> Vec<Candidate> {
    value["recordings"]
        .as_array()
        .into_iter()
        .flatten()
        .take(10)
        .filter_map(|r| {
            let id = r["id"].as_str()?;
            if !uuid(id) {
                return None;
            }
            let release = &r["releases"][0];
            Some(Candidate {
                id: id.into(),
                title: r["title"].as_str().unwrap_or("").into(),
                artist: r["artist-credit"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|a| {
                        format!(
                            "{}{}",
                            a["name"]
                                .as_str()
                                .or(a["artist"]["name"].as_str())
                                .unwrap_or(""),
                            a["joinphrase"].as_str().unwrap_or("")
                        )
                    })
                    .collect(),
                album: release["title"].as_str().unwrap_or("").into(),
                release_id: release["id"]
                    .as_str()
                    .filter(|id| uuid(id))
                    .unwrap_or("")
                    .into(),
                group_id: release["release-group"]["id"]
                    .as_str()
                    .filter(|id| uuid(id))
                    .unwrap_or("")
                    .into(),
                duration: r["length"].as_f64().unwrap_or(0.0) / 1000.0,
                score: r["score"].as_i64().unwrap_or(0),
            })
        })
        .collect()
}
#[tauri::command]
pub async fn search_media_info(title: String, artist: String) -> Result<Vec<Candidate>, String> {
    if title.trim().is_empty() || title.len() > 500 || artist.len() > 500 {
        return Err("请输入不超过 500 字节的曲名与艺人".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let escape = |s: &str| s.replace('\\', " ").replace('"', " ");
        let query = if artist.trim().is_empty() {
            format!("recording:\"{}\"", escape(&title))
        } else {
            format!(
                "recording:\"{}\" AND artist:\"{}\"",
                escape(&title),
                escape(&artist)
            )
        };
        let mut url = Url::parse("https://musicbrainz.org/ws/2/recording/").unwrap();
        url.query_pairs_mut()
            .append_pair("query", &query)
            .append_pair("fmt", "json")
            .append_pair("limit", "10");
        if let Ok(value) = json_get(url) {
            let candidates = parse_candidates(&value);
            if !candidates.is_empty() {
                return Ok(candidates);
            }
        }
        let mut url = Url::parse("https://lrclib.net/api/search").unwrap();
        url.query_pairs_mut().append_pair("track_name", &title);
        if !artist.trim().is_empty() {
            url.query_pairs_mut().append_pair("artist_name", &artist);
        }
        let value = json_get(url)?;
        Ok(value
            .as_array()
            .into_iter()
            .flatten()
            .take(10)
            .filter_map(|v| {
                Some(Candidate {
                    id: format!("lrclib:{}", v["id"].as_u64()?),
                    title: v["trackName"].as_str()?.into(),
                    artist: v["artistName"].as_str().unwrap_or("").into(),
                    album: v["albumName"].as_str().unwrap_or("").into(),
                    duration: v["duration"].as_f64().unwrap_or(0.0),
                    score: 0,
                    release_id: String::new(),
                    group_id: String::new(),
                })
            })
            .collect())
    })
    .await
    .map_err(|e| e.to_string())?
}
#[derive(Default, Serialize)]
pub struct Resources {
    pub artwork_path: Option<String>,
    pub lyrics: String,
    pub reviews: Vec<Review>,
    pub credits: Vec<String>,
    pub warnings: Vec<String>,
}
pub fn parse_reviews(value: &Value, scope: &str) -> Vec<Review> {
    value["reviews"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| {
            let license = r["license"]["id"].as_str()?;
            if ![
                "CC0",
                "CC0 1.0",
                "CC BY 3.0",
                "CC BY 4.0",
                "CC BY-SA 3.0",
                "CC BY-SA 4.0",
            ]
            .contains(&license)
            {
                return None;
            }
            let id = r["id"].as_str()?;
            let text = r["text"].as_str()?;
            if !uuid(id) || text.is_empty() || text.len() > 20000 {
                return None;
            }
            Some(Review {
                author: r["user"]["display_name"]
                    .as_str()
                    .unwrap_or("未署名")
                    .into(),
                text: text.into(),
                source: "CritiqueBrainz".into(),
                url: format!("https://critiquebrainz.org/review/{id}"),
                scope: scope.into(),
                license: license.into(),
                license_url: r["license"]["info_url"].as_str().unwrap_or("").into(),
            })
        })
        .take(10)
        .collect()
}
fn image_extension(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("png")
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        Some("jpg")
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        Some("webp")
    } else {
        None
    }
}
fn persist_cover(bytes: &[u8], key: &str, data_dir: &Path) -> Result<String, String> {
    if bytes.is_empty() || bytes.len() > 8 * 1024 * 1024 {
        return Err("封面需要为 8 MB 以内的图片".into());
    }
    let ext = image_extension(bytes).ok_or("请选择 JPEG、PNG 或 WebP 图片")?;
    let dir = data_dir.join("artwork");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = dir.join(format!(
        "info-{}-{}.{}",
        Track::make_id("cover", key),
        now_ms(),
        ext
    ));
    std::fs::write(&path, bytes).map_err(|e| e.to_string())?;
    Ok(path.to_string_lossy().into_owned())
}
fn cover(release: &str, data_dir: &Path) -> Result<Option<String>, String> {
    if !uuid(release) {
        return Ok(None);
    }
    let client = Client::builder()
        .timeout(Duration::from_secs(25))
        .user_agent(AGENT)
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            let u = attempt.url();
            let host = u.host_str().unwrap_or("");
            if attempt.previous().len() < 5
                && u.scheme() == "https"
                && (host == "coverartarchive.org"
                    || host == "archive.org"
                    || host.ends_with(".archive.org"))
            {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .get(format!(
            "https://coverartarchive.org/release/{release}/front-500"
        ))
        .send()
        .map_err(|_| "封面读取失败")?;
    if response.status().as_u16() == 404 {
        return Ok(None);
    }
    if !response.status().is_success() {
        return Err("封面暂不可用".into());
    }
    let mut bytes = vec![];
    response
        .take(8 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "封面读取失败")?;
    persist_cover(&bytes, release, data_dir).map(Some)
}
#[tauri::command]
pub async fn fetch_media_resources(
    candidate: Candidate,
    state: State<'_, AppState>,
) -> Result<Resources, String> {
    let lyric_id = candidate
        .id
        .strip_prefix("lrclib:")
        .and_then(|s| s.parse::<u64>().ok());
    if !uuid(&candidate.id) && lyric_id.is_none() {
        return Err("候选记录 ID 无效".into());
    }
    let dir = state.data_dir.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut result = Resources::default();
        if let Some(id) = lyric_id {
            let value = json_get(Url::parse(&format!("https://lrclib.net/api/get/{id}")).unwrap())?;
            result.lyrics = value["syncedLyrics"]
                .as_str()
                .filter(|s| !s.is_empty())
                .or(value["plainLyrics"].as_str())
                .unwrap_or("")
                .chars()
                .take(60000)
                .collect();
            result
                .credits
                .push(format!("LRCLIB · https://lrclib.net/api/get/{id}"));
            result
                .warnings
                .push("歌词库候选未确认 MusicBrainz 身份，封面与乐评保持原样".into());
            return Ok(result);
        }
        result.credits.push(format!(
            "MusicBrainz · https://musicbrainz.org/recording/{}",
            candidate.id
        ));
        match cover(&candidate.release_id, &dir) {
            Ok(path) => {
                result.artwork_path = path;
                if result.artwork_path.is_some() {
                    result.credits.push(format!(
                        "Cover Art Archive · https://coverartarchive.org/release/{}",
                        candidate.release_id
                    ));
                }
            }
            Err(e) => result.warnings.push(e),
        }
        let mut lyrics = Url::parse("https://lrclib.net/api/get").unwrap();
        lyrics
            .query_pairs_mut()
            .append_pair("track_name", &candidate.title)
            .append_pair("artist_name", &candidate.artist)
            .append_pair("album_name", &candidate.album);
        if candidate.duration > 0.0 && candidate.duration <= 3600.0 {
            lyrics
                .query_pairs_mut()
                .append_pair("duration", &candidate.duration.round().to_string());
        }
        match json_get(lyrics) {
            Ok(v) => {
                result.lyrics = v["syncedLyrics"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .or(v["plainLyrics"].as_str())
                    .unwrap_or("")
                    .chars()
                    .take(60000)
                    .collect();
                if let Some(id) = v["id"].as_u64() {
                    result
                        .credits
                        .push(format!("LRCLIB · https://lrclib.net/api/get/{id}"));
                }
            }
            Err(e) => result.warnings.push(format!("歌词：{e}")),
        }
        for (scope, id) in [
            ("recording", candidate.id.as_str()),
            ("release_group", candidate.group_id.as_str()),
        ] {
            if !uuid(id) {
                continue;
            }
            let mut url = Url::parse("https://critiquebrainz.org/ws/1/review/").unwrap();
            url.query_pairs_mut()
                .append_pair("entity_id", id)
                .append_pair("entity_type", scope)
                .append_pair("limit", "10");
            match json_get(url) {
                Ok(v) => result.reviews.extend(parse_reviews(&v, scope)),
                Err(e) => result.warnings.push(format!("乐评：{e}")),
            }
        }
        Ok(result)
    })
    .await
    .map_err(|e| e.to_string())?
}
#[derive(Serialize)]
pub struct Inspection {
    pub track: Track,
    pub source_name: String,
    pub source_kind: String,
    pub suggestion: awake_core::media_info::NameSuggestion,
}
#[tauri::command]
pub fn inspect_media(id: String, state: State<'_, AppState>) -> Result<Inspection, String> {
    let lib = state.library.lock();
    let mut track = lib
        .snapshot
        .tracks
        .iter()
        .find(|t| t.id == id)
        .cloned()
        .ok_or("曲目不存在")?;
    let source = lib
        .snapshot
        .sources
        .iter()
        .find(|s| s.id == track.source_id)
        .ok_or("来源不存在")?;
    if matches!(source.kind, SourceKind::Local | SourceKind::Smb) && track.lyrics.is_empty() {
        let path = Path::new(&source.url)
            .join(&track.locator)
            .with_extension("lrc");
        if std::fs::metadata(&path).is_ok_and(|m| m.len() <= 131072) {
            track.lyrics = std::fs::read_to_string(path).unwrap_or_default();
        }
    }
    let suggestion =
        awake_core::media_info::suggest_name(&track.locator, &track.title, &track.artist);
    Ok(Inspection {
        track,
        source_name: source.name.clone(),
        source_kind: source.kind.as_str().into(),
        suggestion,
    })
}
#[derive(Deserialize)]
pub struct SaveRequest {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub comment: String,
    pub lyrics: String,
    pub artwork_path: Option<String>,
    pub info: MediaInfo,
}
#[tauri::command]
pub fn save_media_info(mut req: SaveRequest, state: State<'_, AppState>) -> Result<(), String> {
    awake_core::media_info::validate(
        &req.title,
        &req.artist,
        &req.album,
        &req.comment,
        &req.lyrics,
        &req.info,
    )?;
    let mut lib = state.library.lock();
    let previous = lib.snapshot.clone();
    let track = lib
        .snapshot
        .tracks
        .iter_mut()
        .find(|t| t.id == req.id)
        .ok_or("曲目不存在")?;
    let original = track.media_info.clone().unwrap_or_else(|| MediaInfo {
        original_title: track.title.clone(),
        original_artist: track.artist.clone(),
        original_album_artist: track.album_artist.clone(),
        original_album: track.album.clone(),
        original_artwork: track.artwork_path.clone(),
        original_comment: track.comment.clone(),
        original_lyrics: track.lyrics.clone(),
        ..Default::default()
    });
    req.info.original_title = original.original_title;
    req.info.original_artist = original.original_artist;
    req.info.original_album_artist = original.original_album_artist;
    req.info.original_album = original.original_album;
    req.info.original_artwork = original.original_artwork.clone();
    req.info.original_comment = original.original_comment;
    req.info.original_lyrics = original.original_lyrics;
    if let Some(path) = &req.artwork_path {
        if Some(path) != original.original_artwork.as_ref() {
            let p = PathBuf::from(path)
                .canonicalize()
                .map_err(|_| "封面文件不可用")?;
            let root = state
                .data_dir
                .join("artwork")
                .canonicalize()
                .map_err(|_| "封面缓存不可用")?;
            if !p.starts_with(root) {
                return Err("请通过封面导入选择图片".into());
            }
        }
    }
    track.title = req.title.trim().into();
    track.artist = req.artist.trim().into();
    track.album_artist = track.artist.clone();
    track.album = req.album.trim().into();
    track.comment = req.comment;
    track.lyrics = req.lyrics;
    track.artwork_path = if !["original", "auto"].contains(&req.info.cover_style.as_str()) {
        None
    } else {
        req.artwork_path
    };
    track.media_info = Some(req.info);
    lib.snapshot.scanned_at = Some(now_ms());
    if let Err(e) = lib.save() {
        lib.snapshot = previous;
        return Err(e.to_string());
    }
    Ok(())
}
#[tauri::command]
pub fn reset_media_info(id: String, state: State<'_, AppState>) -> Result<(), String> {
    let mut lib = state.library.lock();
    let previous = lib.snapshot.clone();
    let track = lib
        .snapshot
        .tracks
        .iter_mut()
        .find(|t| t.id == id)
        .ok_or("曲目不存在")?;
    if let Some(info) = track.media_info.take() {
        track.title = info.original_title;
        track.artist = info.original_artist;
        track.album_artist = info.original_album_artist;
        track.album = info.original_album;
        track.artwork_path = info.original_artwork;
        track.comment = info.original_comment;
        track.lyrics = info.original_lyrics;
    }
    lib.snapshot.scanned_at = Some(now_ms());
    if let Err(e) = lib.save() {
        lib.snapshot = previous;
        return Err(e.to_string());
    }
    Ok(())
}
#[derive(Serialize)]
pub struct Attachment {
    pub artwork_path: Option<String>,
    pub text: String,
}
#[tauri::command]
pub async fn import_media_attachment(
    kind: String,
    state: State<'_, AppState>,
) -> Result<Option<Attachment>, String> {
    let dir = state.data_dir.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let output = std::process::Command::new("osascript")
            .args([
                "-e",
                "POSIX path of (choose file with prompt \"选择封面、歌词或评论资料\")",
            ])
            .output()
            .map_err(|e| e.to_string())?;
        if !output.status.success() {
            return Ok(None);
        }
        let path = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
        let size = std::fs::metadata(&path).map_err(|e| e.to_string())?.len();
        let limit = if kind == "cover" {
            8 * 1024 * 1024
        } else {
            512 * 1024
        };
        if size > limit {
            return Err("资料文件超过大小限制".into());
        }
        let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
        if kind == "cover" {
            return Ok(Some(Attachment {
                artwork_path: Some(persist_cover(&bytes, &path.to_string_lossy(), &dir)?),
                text: String::new(),
            }));
        }
        Ok(Some(Attachment {
            artwork_path: None,
            text: String::from_utf8(bytes).map_err(|_| "文本需要为 UTF-8 编码")?,
        }))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn candidates_and_reviews_preserve_identity_and_license_scope() {
        let id = "12345678-1234-1234-1234-123456789012";
        let v = json!({"recordings":[{"id":id,"title":"Title","artist-credit":[{"name":"Artist"}],"length":200000,"score":95,"releases":[]}]});
        let c = parse_candidates(&v);
        assert_eq!(c[0].artist, "Artist");
        assert_eq!(c[0].duration, 200.0);
        let r = json!({"reviews":[{"id":id,"text":"A real licensed review","user":{"display_name":"Listener"},"license":{"id":"CC BY-SA 3.0","info_url":"https://creativecommons.org/licenses/by-sa/3.0/"}}]});
        let parsed = parse_reviews(&r, "release_group");
        assert_eq!(parsed[0].scope, "release_group");
        assert_eq!(parsed[0].author, "Listener");
        let mut denied = r;
        denied["reviews"][0]["license"]["id"] = json!("All rights reserved");
        assert!(parse_reviews(&denied, "recording").is_empty());
    }
}
