//! Tauri 后端：把 Rust 音频核心暴露给前端。
//!
//! 命令面：
//! - `scan_library`  扫描目录，返回曲目与专辑
//! - `load_library`  读取已落盘的曲库
//! - `play_track`    播放一首（带 EQ）
//! - `stop_playback` 停止
//! - `playback_status` 当前播放状态
//! - `set_eq_curve`  设置 31 段 EQ
//! - `analyze_track` 返回一首的频谱画像

use awake_core::{
    decode, eq, group_albums, library, models::SourceKind, Library, MediaSource, Track,
};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use tauri::{Manager, State};

mod connections;
mod devices;
mod experience;
mod feeds;
mod headphone_catalog;
mod intelligence;
mod playback;
mod remote;
mod vault;

/// 全局状态。
pub struct AppState {
    pub library: Arc<Mutex<Library>>,
    pub services: Mutex<intelligence::Services>,
    pub source_status: Arc<Mutex<std::collections::HashMap<String, connections::RefreshStatus>>>,
    pub alive: Arc<std::sync::atomic::AtomicBool>,
    pub generation_running: Arc<std::sync::atomic::AtomicBool>,
    pub generation_cancels:
        Arc<Mutex<std::collections::HashMap<String, Arc<std::sync::atomic::AtomicBool>>>>,
    pub player: Arc<playback::Player>,
    pub taste: Arc<Mutex<awake_core::taste::Taste>>,
    pub data_dir: PathBuf,
}

impl AppState {
    pub fn new() -> Self {
        let data_dir = default_data_dir();
        let store = data_dir.join("library.json");
        std::fs::create_dir_all(&data_dir).ok();
        Self {
            library: Arc::new(Mutex::new(Library::open(store))),
            services: Mutex::new(intelligence::load(&data_dir)),
            source_status: Arc::new(Mutex::new(std::collections::HashMap::new())),
            alive: Arc::new(std::sync::atomic::AtomicBool::new(true)),
            generation_running: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            generation_cancels: Arc::new(Mutex::new(std::collections::HashMap::new())),
            player: Arc::new(playback::Player::new()),
            taste: Arc::new(Mutex::new(experience::load(&data_dir))),
            data_dir,
        }
    }
}

fn default_data_dir() -> PathBuf {
    // macOS: ~/Library/Application Support/com.seven.awake
    //
    // 刻意不用 "Awake": Swift 版 v0.2 的曲库缓存就写在那里 (library.json 用 camelCase,
    // 和这边的 snake_case 不是同一个 schema)。两个应用共用一份 store 会互相覆盖,
    // 谁后存谁赢 —— 所以 Rust 版用自己的 bundle id 作为目录名。
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join("Library/Application Support/com.seven.awake")
}

/// 扫描结果，直接给前端用。
#[derive(Serialize)]
pub struct ScanResult {
    pub tracks: Vec<Track>,
    pub albums: Vec<awake_core::Album>,
    pub elapsed_ms: u128,
}

#[derive(Deserialize)]
pub struct ScanRequest {
    pub path: String,
    pub name: Option<String>,
    pub kind: Option<SourceKind>,
}

#[tauri::command]
async fn scan_library(req: ScanRequest, state: State<'_, AppState>) -> Result<ScanResult, String> {
    let started = std::time::Instant::now();
    let root = PathBuf::from(&req.path);

    let source_id = {
        let lib = state.library.lock();
        // 已存在同路径来源就复用其 ID
        lib.snapshot
            .sources
            .iter()
            .find(|s| s.url == req.path)
            .map(|s| s.id.clone())
            .unwrap_or_else(awake_core::models::new_id)
    };

    let existing = {
        let lib = state.library.lock();
        lib.tracks_by_locator(&source_id)
    };

    let artwork_dir = state.data_dir.join("artwork");
    let scan_root = root.clone();
    let scan_id = source_id.clone();
    let tracks = tauri::async_runtime::spawn_blocking(move || {
        library::scan_local_source(
            &scan_root,
            &scan_id,
            &existing,
            Some(&artwork_dir),
            |_, _, _| {},
        )
        .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())??;

    let albums = group_albums(&tracks);

    {
        let mut lib = state.library.lock();
        let previous = lib.snapshot.clone();
        lib.replace_source_tracks(&source_id, tracks.clone());

        let name = req
            .name
            .clone()
            .or_else(|| root.file_name().map(|n| n.to_string_lossy().to_string()))
            .unwrap_or_else(|| "曲库".into());

        let mut source = MediaSource::new(
            req.kind.unwrap_or(SourceKind::Local),
            name,
            req.path.clone(),
        );
        source.id = source_id;
        source.track_count = tracks.len();
        source.last_scan = Some(awake_core::models::now_ms());
        lib.snapshot.sources.retain(|s| s.id != source.id);
        lib.add_source(source);
        lib.snapshot.scanned_at = Some(awake_core::models::now_ms());
        if let Err(e) = lib.save() {
            lib.snapshot = previous;
            return Err(e.to_string());
        }
    }

    Ok(ScanResult {
        tracks,
        albums,
        elapsed_ms: started.elapsed().as_millis(),
    })
}

#[derive(Serialize)]
pub struct LibraryView {
    pub tracks: Vec<Track>,
    pub albums: Vec<awake_core::Album>,
    pub sources: Vec<MediaSource>,
}

/// 控制 macOS 交通灯（红黄绿）显隐。
/// 默认隐藏，鼠标靠近窗口顶部时由前端唤出 —— 顶栏不再恒占一条。
#[tauri::command]
fn set_traffic_lights(visible: bool, window: tauri::Window) {
    #[cfg(target_os = "macos")]
    {
        use objc2_app_kit::{NSWindow, NSWindowButton};
        if let Ok(ptr) = window.ns_window() {
            unsafe {
                let ns_window: &NSWindow = &*(ptr as *const NSWindow);
                for button in [
                    NSWindowButton::NSWindowCloseButton,
                    NSWindowButton::NSWindowMiniaturizeButton,
                    NSWindowButton::NSWindowZoomButton,
                ] {
                    if let Some(b) = ns_window.standardWindowButton(button) {
                        b.setHidden(!visible);
                    }
                }
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (visible, window);
    }
}

/// 前端挂载完成时调用：证明 WebView 加载 + Vue 挂载 + IPC 通道全部通了。
#[tauri::command]
fn frontend_ready(version: String, tracks: usize) -> String {
    // 写标记文件：这是「前端真的渲染成功」的硬证据，.app 里拿不到 stdout 时靠它验收
    let marker = default_data_dir().join("frontend_ready.txt");
    std::fs::create_dir_all(default_data_dir()).ok();
    let _ = std::fs::write(
        &marker,
        format!(
            "version={version}
tracks={tracks}
at_ms={}
",
            awake_core::models::now_ms()
        ),
    );
    log::info!("FRONTEND_READY version={version} tracks={tracks}");
    println!("[awake] 前端已挂载 version={version} tracks={tracks}");
    "ok".into()
}

#[tauri::command]
fn load_library(state: State<'_, AppState>) -> LibraryView {
    let lib = state.library.lock();
    LibraryView {
        tracks: lib.snapshot.tracks.clone(),
        albums: lib.albums(),
        sources: lib
            .snapshot
            .sources
            .iter()
            .cloned()
            .map(|mut source| {
                source.token.clear();
                source
            })
            .collect(),
    }
}

#[derive(Deserialize)]
pub struct PlayRequest {
    pub source_id: String,
    pub locator: String,
    /// 31 段增益（dB），空则用平坦曲线
    pub gains: Option<Vec<f32>>,
    #[serde(default)]
    pub continuation: bool,
    #[serde(default)]
    pub queue: Vec<QueueReference>,
}
#[derive(Deserialize)]
pub struct QueueReference {
    pub source_id: String,
    pub locator: String,
}

#[tauri::command]
fn play_track(req: PlayRequest, state: State<'_, AppState>) -> Result<String, String> {
    if let Some(gains) = req.gains {
        let current = state.player.curve.lock().clone();
        let curve = experience::with_correction(
            &gains,
            &current,
            match state.player.status().output_rate {
                0 => 48000,
                rate => rate,
            },
        )?;
        *state.player.curve.lock() = curve;
    }
    let mut references = vec![QueueReference {
        source_id: req.source_id.clone(),
        locator: req.locator.clone(),
    }];
    references.extend(req.queue.into_iter().take(9999));
    let queued = {
        let lib = state.library.lock();
        let mut access_cache = std::collections::HashMap::new();
        references
            .into_iter()
            .map(|r| {
                let track = lib
                    .snapshot
                    .tracks
                    .iter()
                    .find(|t| t.source_id == r.source_id && t.locator == r.locator)
                    .ok_or("队列曲目不存在")?;
                let source = lib
                    .snapshot
                    .sources
                    .iter()
                    .find(|s| s.id == r.source_id)
                    .ok_or("队列来源不存在")?;
                let remote = matches!(source.kind, SourceKind::Webdav | SourceKind::Plex);
                let path = if remote {
                    PathBuf::new()
                } else {
                    PathBuf::from(&source.url).join(&track.locator)
                };
                if !remote && !path.is_file() {
                    return Err(format!("文件不存在：{}", path.display()));
                }
                let opener = if remote {
                    if !access_cache.contains_key(&source.id) {
                        access_cache.insert(source.id.clone(), connections::access(source)?);
                    }
                    Some(
                        access_cache
                            .get(&source.id)
                            .unwrap()
                            .factory(track.locator.clone()),
                    )
                } else {
                    None
                };
                Ok(playback::QueueTrack {
                    id: track.id.clone(),
                    path,
                    opener,
                    duration: track.duration,
                    sample_rate: track.sample_rate,
                })
            })
            .collect::<Result<Vec<_>, String>>()?
    };
    let taste = state.taste.clone();
    let data_dir = state.data_dir.clone();
    state.player.play_queue(
        queued,
        !req.continuation,
        move |id, seconds, completed, skipped| {
            if let Err(e) =
                experience::record_session(&taste, &data_dir, id, seconds, completed, skipped)
            {
                log::error!("收听历史保存失败：{e}");
            }
        },
    )?;
    Ok(req.locator)
}

#[tauri::command]
fn stop_playback(state: State<'_, AppState>) {
    state.player.stop();
}

#[tauri::command]
fn pause_playback(paused: bool, state: State<'_, AppState>) {
    state.player.pause(paused);
}

#[tauri::command]
fn seek_playback(seconds: f64, state: State<'_, AppState>) -> Result<(), String> {
    state.player.seek(seconds)
}

#[tauri::command]
fn set_volume(volume: f32, state: State<'_, AppState>) -> Result<(), String> {
    if !volume.is_finite() {
        return Err("无效的音量".into());
    }
    *state.player.volume.lock() = volume.clamp(0.0, 1.0);
    Ok(())
}

#[tauri::command]
fn playback_status(state: State<'_, AppState>) -> playback::Status {
    let status = state.player.status();
    if status.source_rate > 0 && status.duration > 0.0 {
        if let Some(id) = &status.current {
            let mut lib = state.library.lock();
            let changed = if let Some(track) = lib.snapshot.tracks.iter_mut().find(|t| t.id == *id)
            {
                let mut changed = false;
                if track.duration <= 0.0 || track.sample_rate == 0 {
                    track.duration = status.duration;
                    track.sample_rate = status.source_rate;
                    changed = true;
                }
                if track.is_remote {
                    for (value, incoming) in [
                        (&mut track.title, &status.tags.title),
                        (&mut track.artist, &status.tags.artist),
                        (&mut track.album, &status.tags.album),
                        (&mut track.album_artist, &status.tags.album_artist),
                        (&mut track.genre, &status.tags.genre),
                    ] {
                        if !incoming.is_empty() && *value != *incoming {
                            *value = incoming.clone();
                            changed = true;
                        }
                    }
                    if status.source_bits > 0 && track.bit_depth != status.source_bits {
                        track.bit_depth = status.source_bits;
                        changed = true;
                    }
                }
                changed
            } else {
                false
            };
            if changed {
                lib.snapshot.scanned_at = Some(awake_core::models::now_ms());
                if let Err(e) = lib.save() {
                    log::warn!("曲目规格缓存未保存：{e}");
                }
            }
        }
    }
    status
}

#[derive(Deserialize)]
pub struct EqRequest {
    pub gains: Vec<f32>,
    pub preamp: f32,
}

#[tauri::command]
fn set_eq_curve(req: EqRequest, state: State<'_, AppState>) -> Result<eq::EqCurve, String> {
    if !req.preamp.is_finite() {
        return Err("无效的前级增益".into());
    }
    let current = state.player.curve.lock().clone();
    let mut curve = experience::with_correction(
        &req.gains,
        &current,
        match state.player.status().output_rate {
            0 => 48000,
            rate => rate,
        },
    )?;
    curve.preamp = curve.preamp.min(req.preamp.clamp(-40.0, 0.0));
    *state.player.curve.lock() = curve.clone();
    Ok(curve)
}

#[derive(Serialize)]
pub struct Analysis {
    pub bands: Vec<f32>,
    pub peak: f32,
    pub duration: f64,
    pub sample_rate: u32,
}

#[tauri::command]
async fn analyze_track(
    source_id: String,
    locator: String,
    state: State<'_, AppState>,
) -> Result<Analysis, String> {
    let root = {
        let lib = state.library.lock();
        lib.snapshot
            .sources
            .iter()
            .find(|s| s.id == source_id)
            .map(|s| s.url.clone())
            .ok_or_else(|| "找不到来源".to_string())?
    };
    let path = PathBuf::from(root).join(&locator);
    tauri::async_runtime::spawn_blocking(move || {
        let mut decoder = decode::StreamDecoder::open(&path).map_err(|e| e.to_string())?;
        let rate = decoder.format.sample_rate;
        let channels = decoder.format.channels;
        let duration = decoder.format.duration_secs.unwrap_or(0.0);
        let mut analyzer = awake_core::SpectrumAnalyzer::new(8192, rate as f32);
        let mut bands = [0.0_f32; 32];
        let mut peak = 0.0_f32;
        let mut count = 0;
        for fraction in [0.15, 0.45, 0.75] {
            if duration > 0.0 {
                decoder
                    .seek(duration * fraction)
                    .map_err(|e| e.to_string())?;
            }
            let mut mono = Vec::new();
            while mono.len() < (rate as usize * 2) {
                let Some(packet) = decoder.next_packet().map_err(|e| e.to_string())? else {
                    break;
                };
                peak = packet.iter().fold(peak, |a, b| a.max(b.abs()));
                mono.extend(awake_core::to_mono(&packet, channels));
            }
            if !mono.is_empty() {
                let profile = analyzer.profile(&mono, rate as f32);
                for i in 0..32 {
                    bands[i] += profile.bands[i];
                }
                count += 1;
            }
            if duration == 0.0 {
                break;
            }
        }
        if count > 0 {
            for b in &mut bands {
                *b /= count as f32;
            }
        }
        Ok(Analysis {
            bands: bands.to_vec(),
            peak,
            duration,
            sample_rate: rate,
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
fn load_lyrics(
    source_id: String,
    locator: String,
    state: State<'_, AppState>,
) -> Result<Vec<awake_core::lyrics::Line>, String> {
    let root = state
        .library
        .lock()
        .snapshot
        .sources
        .iter()
        .find(|s| s.id == source_id)
        .map(|s| s.url.clone())
        .ok_or("找不到来源")?;
    let path = PathBuf::from(root).join(locator).with_extension("lrc");
    if !path.is_file() {
        return Ok(Vec::new());
    }
    let input = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    Ok(awake_core::lyrics::parse(&input))
}

#[tauri::command]
async fn pick_music_folder() -> Result<Option<String>, String> {
    tauri::async_runtime::spawn_blocking(|| {
        #[cfg(target_os = "macos")]
        {
            let output = std::process::Command::new("osascript")
                .args([
                    "-e",
                    "POSIX path of (choose folder with prompt \"选择你的音乐文件夹\")",
                ])
                .output()
                .map_err(|e| e.to_string())?;
            if !output.status.success() {
                let error = String::from_utf8_lossy(&output.stderr);
                if error.contains("-128") {
                    return Ok(None);
                }
                return Err(error.into_owned());
            }
            Ok(Some(
                String::from_utf8_lossy(&output.stdout).trim().to_string(),
            ))
        }
        #[cfg(not(target_os = "macos"))]
        {
            Err("请直接填写音乐文件夹路径".into())
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

pub fn run() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    tauri::Builder::default()
        .setup(|app| {
            let state = app.state::<AppState>();
            connections::start_refresh_worker(
                state.library.clone(),
                state.source_status.clone(),
                state.alive.clone(),
                state.data_dir.clone(),
                state.taste.clone(),
            );
            // 诊断：打印窗口实际加载的 URL 与前端资源解析结果
            tauri::Manager::get_webview_window(app, "main").map(|w| {
                println!("[awake] WINDOW_URL={:?}", w.url());
                let _ = w.eval("console.log('window ready', location.href)");
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::CloseRequested { .. }) {
                window.state::<AppState>().player.stop_and_flush();
            }
        })
        .manage(AppState::new())
        .invoke_handler(tauri::generate_handler![
            scan_library,
            intelligence::get_services,
            intelligence::generate_skin,
            intelligence::save_service,
            intelligence::curate_music,
            intelligence::start_generation,
            intelligence::cancel_generation,
            intelligence::reveal_generation,
            feeds::subscribe_feed,
            connections::connect_source,
            connections::refresh_remote_source,
            connections::source_refresh_status,
            connections::set_source_auto_refresh,
            connections::library_revision,
            set_traffic_lights,
            frontend_ready,
            load_library,
            play_track,
            stop_playback,
            pause_playback,
            seek_playback,
            set_volume,
            experience::get_taste,
            experience::import_headphone_profile,
            experience::select_correction,
            experience::restore_correction,
            experience::record_listen,
            experience::toggle_favorite,
            experience::recommend,
            experience::save_playlist,
            experience::delete_playlist,
            experience::save_sound_profile,
            experience::save_creation_brief,
            experience::output_device,
            devices::listening_context,
            devices::save_listening_chain,
            devices::activate_listening_chain,
            headphone_catalog::search_headphones,
            headphone_catalog::ai_match_headphone,
            headphone_catalog::preview_headphone_eq,
            playback_status,
            set_eq_curve,
            analyze_track,
            load_lyrics,
            pick_music_folder
        ])
        .build(tauri::generate_context!())
        .expect("启动 Awake 失败")
        .run(|app, event| {
            if matches!(event, tauri::RunEvent::ExitRequested { .. }) {
                let state = app.state::<AppState>();
                state
                    .alive
                    .store(false, std::sync::atomic::Ordering::Release);
                state.player.stop_and_flush();
            }
        });
}

#[cfg(test)]
#[path = "../../awake-core/src/test_audio.rs"]
pub(crate) mod test_audio;

#[cfg(test)]
mod allocation_audit;
#[cfg(test)]
#[global_allocator]
static TEST_ALLOCATOR: allocation_audit::Audited = allocation_audit::Audited;
