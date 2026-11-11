use crate::{experience, vault, AppState};
use awake_core::{
    feedmeta::Subscription,
    taste::{Playlist, Taste},
    Library,
};
use parking_lot::Mutex;
use serde::Deserialize;
use std::{io::Read, path::Path, time::Duration};
use tauri::State;
#[derive(Deserialize)]
pub struct FeedRequest {
    pub name: String,
    pub url: String,
    pub username: String,
    pub secret: String,
    pub source_ids: Vec<String>,
}
fn titles(bytes: &[u8]) -> Result<Vec<String>, String> {
    let text = std::str::from_utf8(bytes).map_err(|_| "订阅需要 UTF-8 XML")?;
    let doc = roxmltree::Document::parse(text).map_err(|_| "订阅 XML 格式无效")?;
    let root = doc.root_element().tag_name().name();
    if !matches!(root, "rss" | "feed" | "RDF") {
        return Err("仅识别 RSS / Atom 元数据订阅".into());
    }
    Ok(doc
        .descendants()
        .filter(|n| matches!(n.tag_name().name(), "item" | "entry"))
        .take(2000)
        .filter_map(|n| {
            n.children()
                .find(|n| n.tag_name().name() == "title")
                .and_then(|n| n.text())
                .map(|s| s.chars().take(1000).collect())
        })
        .collect())
}
fn read(feed: &Subscription, secret: &str) -> Result<Vec<String>, String> {
    let url = reqwest::Url::parse(&feed.url).map_err(|_| "订阅地址无效")?;
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("订阅地址应为 HTTP(S)，凭据请使用账号密码字段".into());
    }
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "无法连接订阅")?;
    let mut req = client.get(url);
    if !feed.username.is_empty() {
        req = req.basic_auth(&feed.username, Some(secret));
    }
    let response = req.send().map_err(|_| "订阅连接失败")?;
    if !response.status().is_success() {
        return Err(format!("订阅返回 HTTP {}", response.status().as_u16()));
    }
    let mut bytes = Vec::new();
    response
        .take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "订阅读取失败")?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err("订阅超过 4 MB 限制".into());
    }
    titles(&bytes)
}
fn apply(
    profile: &Mutex<Taste>,
    dir: &Path,
    mut feed: Subscription,
    entries: Vec<String>,
    tracks: &[awake_core::Track],
) -> Result<Subscription, String> {
    let require_existing = feed.attempted_at != 0;
    let ids = awake_core::feedmeta::match_entries(&entries, tracks, &feed.source_ids);
    feed.matched = ids.len();
    feed.total = entries.len();
    feed.refreshed_at = Some(awake_core::models::now_ms());
    feed.attempted_at = feed.refreshed_at.unwrap();
    feed.error = None;
    experience::mutate_profile(profile, dir, |taste| {
        if require_existing && !taste.feeds.iter().any(|f| f.id == feed.id) {
            return Err("订阅已删除，旧刷新结果已放弃".into());
        }
        let playlist = Playlist {
            id: feed.playlist_id.clone(),
            name: feed.name.clone(),
            prompt: "RSS / Atom 元数据匹配，仅包含自己的曲库".into(),
            source_ids: feed.source_ids.clone(),
            track_ids: ids,
            smart: false,
        };
        taste.playlists.retain(|p| p.id != playlist.id);
        taste.playlists.push(playlist);
        taste.feeds.retain(|f| f.id != feed.id);
        taste.feeds.push(feed.clone());
        Ok(feed)
    })
}
#[tauri::command]
pub async fn subscribe_feed(
    req: FeedRequest,
    state: State<'_, AppState>,
) -> Result<Subscription, String> {
    if req.name.trim().is_empty() {
        return Err("请填写订阅名称".into());
    }
    let id = awake_core::models::new_id();
    let feed = Subscription {
        id: id.clone(),
        name: req.name,
        url: req.url,
        username: req.username,
        source_ids: req.source_ids,
        playlist_id: format!("feed-{id}"),
        attempted_at: 0,
        refreshed_at: None,
        matched: 0,
        total: 0,
        error: None,
    };
    let source = feed.clone();
    let secret = req.secret.clone();
    let entries = tauri::async_runtime::spawn_blocking(move || read(&source, &secret))
        .await
        .map_err(|e| e.to_string())??;
    if !req.secret.is_empty() {
        vault::set(&format!("feed.{id}"), &req.secret)?;
    }
    let tracks = state.library.lock().snapshot.tracks.clone();
    apply(&state.taste, &state.data_dir, feed, entries, &tracks)
}
pub fn refresh_due(profile: &Mutex<Taste>, library: &Mutex<Library>, dir: &Path) {
    let feeds = profile.lock().feeds.clone();
    let now = awake_core::models::now_ms();
    for mut feed in feeds {
        if now - feed.attempted_at < 15 * 60 * 1000 {
            continue;
        }
        feed.attempted_at = now;
        let result = (|| {
            let secret = if feed.username.is_empty() {
                String::new()
            } else {
                vault::get(&format!("feed.{}", feed.id))?
            };
            read(&feed, &secret)
        })();
        match result {
            Ok(entries) => {
                let tracks = library.lock().snapshot.tracks.clone();
                if let Err(e) = apply(profile, dir, feed, entries, &tracks) {
                    log::warn!("订阅结果未保存：{e}");
                }
            }
            Err(error) => {
                feed.error = Some(error);
                let _ = experience::mutate_profile(profile, dir, |taste| {
                    if let Some(current) = taste.feeds.iter_mut().find(|f| f.id == feed.id) {
                        *current = feed;
                    }
                    Ok(())
                });
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rss_and_atom_match_metadata_without_following_links() {
        let rss=titles(br#"<rss><channel><item><title>Artist - Song</title><enclosure url="https://not-contacted.invalid/track.mp3"/></item><item><title>Missing</title></item></channel></rss>"#).unwrap();
        let atom=titles(br#"<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Artist - Song</title></entry></feed>"#).unwrap();
        assert_eq!(rss[0], atom[0]);
        let dir = crate::test_audio::directory();
        crate::test_audio::wav(&dir.join("Song.wav"), 48000, 2, &vec![0; 960]);
        let mut tracks = awake_core::scan_local_source(
            &dir,
            "one",
            &std::collections::HashMap::new(),
            None,
            |_, _, _| {},
        )
        .unwrap();
        tracks[0].artist = "Artist".into();
        assert_eq!(
            awake_core::feedmeta::match_entries(&rss, &tracks, &[]),
            vec![tracks[0].id.clone()]
        );
        let mut duplicate = tracks[0].clone();
        duplicate.id = "duplicate".into();
        tracks.push(duplicate);
        assert!(awake_core::feedmeta::match_entries(&rss, &tracks, &[]).is_empty());
        assert!(titles(b"<html>not a feed</html>").is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
