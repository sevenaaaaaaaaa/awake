use crate::{remote::Access, vault, AppState};
use awake_core::{models::SourceKind, MediaSource, Track};
use parking_lot::Mutex;
use serde::Deserialize;
use tauri::State;

#[derive(Deserialize)]
pub struct ConnectionRequest {
    pub name: String,
    pub kind: SourceKind,
    pub url: String,
    pub username: String,
    pub secret: String,
    /// 仅对该来源放宽 HTTPS 证书校验（自签名 NAS），默认关闭。
    #[serde(default)]
    pub trust_self_signed: bool,
    /// Plex 音乐库分区 key；留空则扫描整个服务器的全部音乐分区。
    #[serde(default)]
    pub section: String,
}
pub fn access(source: &MediaSource) -> Result<Access, String> {
    let secret = if source.username.is_empty()
        && !matches!(source.kind, SourceKind::Plex | SourceKind::Telegram)
    {
        String::new()
    } else {
        vault::get(&source.password_key)?
    };
    Ok(Access::new(source.clone(), secret))
}
fn save(source: MediaSource, mut tracks: Vec<Track>, state: &AppState) -> Result<(), String> {
    let mut lib = state.library.lock();
    let previous = lib.snapshot.clone();
    let old = lib.tracks_by_locator(&source.id);
    for track in &mut tracks {
        if let Some(t) = old.get(&track.locator) {
            track.favorite = t.favorite;
            track.play_count = t.play_count;
            track.last_played = t.last_played;
            track.added_at = t.added_at;
        }
    }
    lib.replace_source_tracks(&source.id, tracks);
    lib.snapshot.sources.retain(|s| s.id != source.id);
    lib.add_source(source);
    lib.snapshot.scanned_at = Some(awake_core::models::now_ms());
    if let Err(e) = lib.save() {
        lib.snapshot = previous;
        return Err(e.to_string());
    }
    Ok(())
}
#[tauri::command]
pub async fn connect_source(
    req: ConnectionRequest,
    state: State<'_, AppState>,
) -> Result<usize, String> {
    if !matches!(
        req.kind,
        SourceKind::Webdav | SourceKind::Plex | SourceKind::Telegram
    ) {
        return Err("NAS 与网盘请先挂载，再选择挂载目录".into());
    }
    let mut source = {
        let lib = state.library.lock();
        lib.snapshot
            .sources
            .iter()
            .find(|s| {
                s.kind == req.kind && s.url.trim_end_matches('/') == req.url.trim_end_matches('/')
            })
            .cloned()
            .unwrap_or_else(|| {
                MediaSource::new(
                    req.kind,
                    if req.name.trim().is_empty() {
                        req.kind.title()
                    } else {
                        req.name.trim()
                    },
                    req.url.trim(),
                )
            })
    };
    source.username = req.username;
    source.trust_self_signed = req.trust_self_signed;
    if req.kind == SourceKind::Plex {
        let section = req.section.trim().to_string();
        if !section.is_empty() && !section.chars().all(|c| c.is_ascii_digit()) {
            return Err("Plex 音乐库编号无效，请重新选择".into());
        }
        source.section = section;
    }
    source.token.clear();
    if !req.name.trim().is_empty() {
        source.name = req.name.trim().into();
    }
    let secret = if req.secret.is_empty()
        && (!source.username.is_empty()
            || matches!(source.kind, SourceKind::Plex | SourceKind::Telegram))
    {
        vault::get(&source.password_key)?
    } else {
        req.secret
    };
    let access = Access::new(source.clone(), secret.clone());
    access.base().map_err(|e| e.to_string())?;
    let tracks =
        tauri::async_runtime::spawn_blocking(move || access.scan().map_err(|e| e.to_string()))
            .await
            .map_err(|e| e.to_string())??;
    if !secret.is_empty() {
        vault::set(&source.password_key, &secret)?;
    }
    source.track_count = tracks.len();
    source.last_scan = Some(awake_core::models::now_ms());
    let count = tracks.len();
    save(source, tracks, &state)?;
    Ok(count)
}
#[tauri::command]
pub async fn refresh_remote_source(
    id: String,
    state: State<'_, AppState>,
) -> Result<usize, String> {
    let mut source = state
        .library
        .lock()
        .snapshot
        .sources
        .iter()
        .find(|s| s.id == id)
        .cloned()
        .ok_or("来源不存在")?;
    let access = access(&source)?;
    let tracks =
        tauri::async_runtime::spawn_blocking(move || access.scan().map_err(|e| e.to_string()))
            .await
            .map_err(|e| e.to_string())??;
    source.track_count = tracks.len();
    source.last_scan = Some(awake_core::models::now_ms());
    let count = tracks.len();
    save(source, tracks, &state)?;
    Ok(count)
}

#[derive(Clone, Default, serde::Serialize)]
pub struct RefreshStatus {
    pub refreshing: bool,
    pub attempted_at: i64,
    pub succeeded_at: Option<i64>,
    pub error: Option<String>,
}
#[tauri::command]
pub fn source_refresh_status(
    state: State<'_, AppState>,
) -> std::collections::HashMap<String, RefreshStatus> {
    state.source_status.lock().clone()
}
#[tauri::command]
pub fn set_source_auto_refresh(
    id: String,
    enabled: bool,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let mut lib = state.library.lock();
    let old = lib.snapshot.clone();
    lib.snapshot
        .sources
        .iter_mut()
        .find(|s| s.id == id)
        .ok_or("来源不存在")?
        .enabled = enabled;
    if let Err(e) = lib.save() {
        lib.snapshot = old;
        return Err(e.to_string());
    }
    Ok(())
}
#[tauri::command]
pub fn library_revision(state: State<'_, AppState>) -> Option<i64> {
    state.library.lock().snapshot.scanned_at
}
pub fn start_refresh_worker(
    library: std::sync::Arc<parking_lot::Mutex<awake_core::Library>>,
    statuses: std::sync::Arc<parking_lot::Mutex<std::collections::HashMap<String, RefreshStatus>>>,
    alive: std::sync::Arc<std::sync::atomic::AtomicBool>,
    data_dir: std::path::PathBuf,
    profile: std::sync::Arc<Mutex<awake_core::taste::Taste>>,
) {
    std::thread::spawn(move || {
        while alive.load(std::sync::atomic::Ordering::Acquire) {
            let now = awake_core::models::now_ms();
            let sources = library.lock().snapshot.sources.clone();
            for source in sources {
                if !alive.load(std::sync::atomic::Ordering::Acquire) {
                    return;
                }
                if !source.enabled || source.id == "awake-generated" {
                    continue;
                }
                let last_attempt = statuses
                    .lock()
                    .get(&source.id)
                    .map(|s| s.attempted_at)
                    .unwrap_or(0);
                if now - source.last_scan.unwrap_or(0).max(last_attempt) < 15 * 60 * 1000 {
                    continue;
                }
                statuses.lock().insert(
                    source.id.clone(),
                    RefreshStatus {
                        refreshing: true,
                        attempted_at: now,
                        ..RefreshStatus::default()
                    },
                );
                let old_scan = source.last_scan;
                let result = (|| {
                    let mut tracks = if matches!(
                        source.kind,
                        SourceKind::Webdav | SourceKind::Plex | SourceKind::Telegram
                    ) {
                        access(&source)?.scan().map_err(|e| e.to_string())?
                    } else {
                        let existing = library.lock().tracks_by_locator(&source.id);
                        if source.files.is_empty() {
                            awake_core::scan_local_source(
                                std::path::Path::new(&source.url),
                                &source.id,
                                &existing,
                                Some(&data_dir.join("artwork")),
                                |_, _, _| {},
                            )
                            .map_err(|e| e.to_string())?
                        } else {
                            let files: Vec<std::path::PathBuf> = source
                                .files
                                .iter()
                                .map(std::path::PathBuf::from)
                                .filter(|p| p.is_file())
                                .collect();
                            if files.is_empty() {
                                return Err("手动导入的文件已不存在".into());
                            }
                            awake_core::scan_local_files(
                                &files,
                                &source.id,
                                &existing,
                                Some(&data_dir.join("artwork")),
                            )
                            .map_err(|e| e.to_string())?
                        }
                    };
                    let mut lib = library.lock();
                    let current = lib
                        .snapshot
                        .sources
                        .iter()
                        .find(|s| s.id == source.id)
                        .ok_or("来源已移除")?;
                    if current.last_scan != old_scan || !current.enabled {
                        return Err("来源已被更新，本次后台结果已放弃".into());
                    }
                    let previous = lib.snapshot.clone();
                    let old = lib.tracks_by_locator(&source.id);
                    for track in &mut tracks {
                        if let Some(t) = old.get(&track.locator) {
                            track.favorite = t.favorite;
                            track.play_count = t.play_count;
                            track.last_played = t.last_played;
                            track.added_at = t.added_at;
                            if track.is_remote && t.duration > 0.0 {
                                track.duration = t.duration;
                                track.sample_rate = t.sample_rate;
                                track.bit_depth = t.bit_depth;
                                track.channels = t.channels;
                            }
                        }
                    }
                    let count = tracks.len();
                    lib.replace_source_tracks(&source.id, tracks);
                    let source = lib
                        .snapshot
                        .sources
                        .iter_mut()
                        .find(|s| s.id == source.id)
                        .unwrap();
                    source.track_count = count;
                    source.last_scan = Some(awake_core::models::now_ms());
                    lib.snapshot.scanned_at = source.last_scan;
                    if let Err(e) = lib.save() {
                        lib.snapshot = previous;
                        return Err(e.to_string());
                    }
                    Ok::<(), String>(())
                })();
                let mut status = statuses.lock();
                let entry = status.entry(source.id).or_default();
                entry.refreshing = false;
                match result {
                    Ok(()) => {
                        entry.succeeded_at = Some(awake_core::models::now_ms());
                        entry.error = None;
                    }
                    Err(e) => entry.error = Some(e),
                }
            }
            crate::feeds::refresh_due(&profile, &library, &data_dir);
            for _ in 0..30 {
                if !alive.load(std::sync::atomic::Ordering::Acquire) {
                    return;
                }
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn background_scan_updates_revision_and_failure_preserves_old_library() {
        for fail in [false, true] {
            let dir = crate::test_audio::directory();
            let music = dir.join("music");
            std::fs::create_dir(&music).unwrap();
            crate::test_audio::wav(&music.join("song.wav"), 48000, 2, &vec![0; 960]);
            let mut source = MediaSource::new(SourceKind::Smb, "mounted", music.to_string_lossy());
            source.id = "mounted".into();
            source.last_scan = Some(0);
            let tracks = awake_core::scan_local_source(
                &music,
                &source.id,
                &std::collections::HashMap::new(),
                None,
                |_, _, _| {},
            )
            .unwrap();
            if fail {
                source.url = dir.join("unmounted").to_string_lossy().into_owned();
            }
            let mut lib = awake_core::Library::open(dir.join("library.json"));
            if fail {
                lib.snapshot.tracks = tracks.clone();
            }
            lib.add_source(source.clone());
            lib.save().unwrap();
            let library = std::sync::Arc::new(Mutex::new(lib));
            let statuses = std::sync::Arc::new(Mutex::new(std::collections::HashMap::new()));
            let alive = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
            start_refresh_worker(
                library.clone(),
                statuses.clone(),
                alive.clone(),
                dir.clone(),
                std::sync::Arc::new(Mutex::new(awake_core::taste::Taste::default())),
            );
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
            loop {
                if let Some(status) = statuses.lock().get("mounted") {
                    if !status.refreshing {
                        break;
                    }
                }
                assert!(std::time::Instant::now() < deadline);
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            alive.store(false, std::sync::atomic::Ordering::Release);
            let snapshot = library.lock().snapshot.clone();
            assert_eq!(snapshot.tracks.len(), 1);
            let status = statuses.lock().get("mounted").unwrap().clone();
            if fail {
                assert!(status.error.is_some());
                assert_eq!(snapshot.sources[0].last_scan, Some(0));
            } else {
                assert!(status.error.is_none());
                assert!(snapshot.scanned_at.is_some());
                assert_eq!(snapshot.sources[0].track_count, 1);
            }
            std::fs::remove_dir_all(dir).unwrap();
        }
    }
}
