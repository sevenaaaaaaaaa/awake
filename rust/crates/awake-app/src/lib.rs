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
//! - `playlist_import_*` 抓取或解析歌单，并与本地曲库匹配

use awake_core::{
    decode, eq, group_albums, library, models::SourceKind, Library, MediaSource, Track,
};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use tauri::{Emitter, Manager, State};

mod audiobook;
mod backup;
mod connections;
mod devices;
mod handoff;
mod handoff_send;
mod experience;
mod feeds;
mod headphone_catalog;
mod insight;
mod intelligence;
mod media_info;
mod news;
mod playback;
mod playlist_import;
mod plugin;
mod preset;
mod plex;
mod remote;
mod speech;
mod telegram;
mod vault;
mod weekly;

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
    /// 有声书 / 新闻播报的合成任务进度。
    pub speech_jobs: Arc<Mutex<std::collections::HashMap<String, speech::SpeechJob>>>,
}

impl AppState {
    pub fn new() -> Self {
        let data_dir = default_data_dir();
        let store = data_dir.join("library.json");
        std::fs::create_dir_all(&data_dir).ok();
        // 凭据存储（凭据文件 + 钥匙串镜像）必须先指到数据目录，
        // 否则来源密码与 Plex Token 会被写到无处可寻的默认位置。
        vault::init(&data_dir);
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
            speech_jobs: Arc::new(Mutex::new(std::collections::HashMap::new())),
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
    /// 未能导入的路径（最多 20 条），用于给用户明确反馈。
    pub skipped: Vec<String>,
}

#[derive(Deserialize)]
pub struct ScanRequest {
    pub path: String,
    pub name: Option<String>,
    pub kind: Option<SourceKind>,
}

async fn scan_folder(
    path: String,
    name: Option<String>,
    kind: SourceKind,
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<ScanResult, String> {
    if !matches!(kind, SourceKind::Local | SourceKind::Smb) {
        return Err("远程媒体库请使用连接来源功能".into());
    }
    let started = std::time::Instant::now();
    let root = PathBuf::from(&path);
    if !root.is_dir() {
        return Err(format!("文件夹不存在或无法读取：{path}"));
    }

    let source_id = {
        let lib = state.library.lock();
        lib.snapshot
            .sources
            .iter()
            .find(|s| s.url == path)
            .map(|s| s.id.clone())
            .unwrap_or_else(awake_core::models::new_id)
    };
    let existing = state.library.lock().tracks_by_locator(&source_id);
    let artwork_dir = state.data_dir.join("artwork");
    let scan_root = root.clone();
    let scan_id = source_id.clone();
    let tracks = tauri::async_runtime::spawn_blocking(move || {
        let previous = std::sync::atomic::AtomicUsize::new(0);
        library::scan_local_source(
            &scan_root,
            &scan_id,
            &existing,
            Some(&artwork_dir),
            |done, total, title| {
                let last = previous.load(std::sync::atomic::Ordering::Relaxed);
                if done == total || done.saturating_sub(last) >= 25 {
                    previous.store(done, std::sync::atomic::Ordering::Relaxed);
                    let _ = app.emit(
                        "awake://scan-progress",
                        serde_json::json!({"done": done, "total": total, "title": title}),
                    );
                }
            },
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
        let name = name
            .or_else(|| root.file_name().map(|n| n.to_string_lossy().to_string()))
            .unwrap_or_else(|| "曲库".into());
        let mut source = MediaSource::new(kind, name, path);
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
        skipped: Vec::new(),
    })
}

/// 「本地文件」来源：逐个文件导入，不复制、不移动用户的文件。
fn collect_audio_files(dir: &std::path::Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_audio_files(&path, out);
        } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            if matches!(
                ext.to_ascii_lowercase().as_str(),
                "flac" | "mp3" | "m4a" | "wav" | "aif" | "aiff" | "alac" | "ogg"
            ) {
                out.push(path);
            }
        }
    }
}

async fn scan_files(
    paths: Vec<String>,
    append: bool,
    name: Option<String>,
    state: State<'_, AppState>,
) -> Result<ScanResult, String> {
    let started = std::time::Instant::now();
    let source_id = "local-files".to_string();
    let mut skipped = Vec::new();
    let mut files: Vec<PathBuf> = Vec::new();
    for raw in &paths {
        let raw = &normalize_music_path(raw).unwrap_or_else(|_| raw.trim().to_string());
        let path = PathBuf::from(raw);
        if path.is_dir() {
            files.extend(library::collect_audio_files(&path));
        } else if path.is_file() {
            if library::is_audio_file(&path) {
                files.push(path);
            } else if skipped.len() < 20 {
                skipped.push(format!("不是音频：{}", path.display()));
            }
        } else if skipped.len() < 20 {
            skipped.push(format!("找不到：{raw}"));
        }
    }
    let previous_source = state
        .library
        .lock()
        .snapshot
        .sources
        .iter()
        .find(|s| s.id == source_id)
        .cloned();
    if append {
        if let Some(source) = &previous_source {
            for path in &source.files {
                let path = PathBuf::from(path);
                if path.is_file() {
                    files.push(path);
                }
            }
        }
    }
    let mut seen = std::collections::HashSet::new();
    files.retain(|path| {
        let key = path.canonicalize().unwrap_or_else(|_| path.clone());
        seen.insert(key)
    });
    if files.is_empty() {
        return Err("没有读到可导入的音频文件（支持 FLAC / ALAC / MP3 / AAC / WAV / AIFF / OGG / M4B）".into());
    }
    let existing = state.library.lock().tracks_by_locator(&source_id);
    let artwork_dir = state.data_dir.join("artwork");
    let scan_id = source_id.clone();
    let scan_files = files.clone();
    let tracks = tauri::async_runtime::spawn_blocking(move || {
        library::scan_local_files(&scan_files, &scan_id, &existing, Some(&artwork_dir))
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())??;
    if tracks.is_empty() {
        return Err("这些文件都无法读取为音频，请确认格式与访问权限".into());
    }
    let albums = group_albums(&tracks);
    {
        let mut lib = state.library.lock();
        let previous = lib.snapshot.clone();
        lib.replace_source_tracks(&source_id, tracks.clone());
        let mut source = MediaSource::new(
            SourceKind::Local,
            name.unwrap_or_else(|| "本地文件".into()),
            "手动导入的文件",
        );
        source.id = source_id;
        source.files = files.iter().map(|p| p.to_string_lossy().to_string()).collect();
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
        skipped,
    })
}

#[tauri::command]
async fn scan_library(
    req: ScanRequest,
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<ScanResult, String> {
    let kind = req.kind.unwrap_or(SourceKind::Local);
    let raw = req.path.trim().to_string();
    if raw.is_empty() {
        return Err("请填写音乐文件夹路径".into());
    }
    // 本地来源先把路径收拾干净（引号 / file:// / ~ / 末尾斜杠），
    // 否则 is_dir() 判假，用户看到的是「选好了文件夹却扫不出东西」。
    let path = if matches!(kind, SourceKind::Local | SourceKind::Smb) {
        normalize_music_path(&raw)?
    } else {
        raw
    };
    if PathBuf::from(&path).is_file() {
        return scan_files(vec![path], true, req.name, state).await;
    }
    scan_folder(path, req.name, kind, app, state).await
}

#[tauri::command]
async fn import_local_files(
    paths: Vec<String>,
    name: Option<String>,
    append: Option<bool>,
    state: State<'_, AppState>,
) -> Result<ScanResult, String> {
    if paths.is_empty() {
        return Err("没有选择任何文件".into());
    }
    if paths.len() > 5000 {
        return Err("一次最多导入 5000 个文件".into());
    }
    scan_files(paths, append.unwrap_or(true), name, state).await
}

#[derive(Serialize)]
pub struct BuiltinDemoStatus {
    pub available: usize,
    pub imported: usize,
    pub seeded: bool,
}

/// 本地内置版：包内示例音频数量、当前已入库的本地曲目数、是否已经播种过。
#[tauri::command]
fn builtin_demo_status(app: tauri::AppHandle, state: State<'_, AppState>) -> BuiltinDemoStatus {
    let mut available = 0;
    if let Ok(resource) = app.path().resource_dir() {
        let mut paths = Vec::new();
        collect_audio_files(&resource.join("DemoMusic"), &mut paths);
        available = paths.len();
    }
    let imported = state
        .library
        .lock()
        .snapshot
        .tracks
        .iter()
        .filter(|track| track.source_id == "local-files")
        .count();
    let seeded = state.data_dir.join(".builtin-demo-imported").exists();
    BuiltinDemoStatus {
        available,
        imported,
        seeded,
    }
}

/// 重新导入包内的示例曲库（幂等：已入库的文件会被 scan_files 去重）。
#[tauri::command]
async fn builtin_demo_install(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<usize, String> {
    let resource = app.path().resource_dir().map_err(|e| e.to_string())?;
    let mut paths = Vec::new();
    collect_audio_files(&resource.join("DemoMusic"), &mut paths);
    if paths.is_empty() {
        return Err("包内没有找到示例音频（Contents/Resources/DemoMusic）".into());
    }
    let args: Vec<String> = paths.iter().map(|p| p.to_string_lossy().to_string()).collect();
    let result = scan_files(args, true, Some("内置示例".into()), state.clone()).await?;
    let _ = std::fs::write(state.data_dir.join(".builtin-demo-imported"), b"1");
    Ok(result.tracks.len())
}

/// 只移除包内示例那一批曲目（按 locator 前缀匹配 DemoMusic 目录），其余本地导入保留。
#[tauri::command]
fn builtin_demo_remove(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<usize, String> {
    let resource = app.path().resource_dir().map_err(|e| e.to_string())?;
    let dir = resource.join("DemoMusic");
    let prefix = dir.canonicalize().unwrap_or(dir).to_string_lossy().to_string();
    let mut lib = state.library.lock();
    let before = lib.snapshot.tracks.len();
    lib.snapshot
        .tracks
        .retain(|track| !track.locator.starts_with(&prefix));
    let removed = before - lib.snapshot.tracks.len();
    let remaining_local = lib
        .snapshot
        .tracks
        .iter()
        .filter(|track| track.source_id == "local-files")
        .count();
    if let Some(source) = lib
        .snapshot
        .sources
        .iter_mut()
        .find(|source| source.id == "local-files")
    {
        source.files.retain(|file| !file.starts_with(&prefix));
        source.track_count = remaining_local;
    }
    if remaining_local == 0 {
        lib.snapshot
            .sources
            .retain(|source| source.id != "local-files");
    }
    lib.save().map_err(|e| e.to_string())?;
    drop(lib);
    let _ = std::fs::remove_file(state.data_dir.join(".builtin-demo-imported"));
    Ok(removed)
}

/// 清空本地添加的记录：删掉本机导入来源（含内置示例）及其曲目，保留远程来源与设置。
#[tauri::command]
fn local_records_clear(state: State<'_, AppState>) -> Result<usize, String> {
    let mut lib = state.library.lock();
    let removed = lib
        .snapshot
        .tracks
        .iter()
        .filter(|track| track.source_id == "local-files")
        .count();
    lib.snapshot.tracks.retain(|track| track.source_id != "local-files");
    lib.snapshot.sources.retain(|source| source.id != "local-files");
    lib.save().map_err(|e| e.to_string())?;
    drop(lib);
    let _ = std::fs::remove_file(state.data_dir.join(".builtin-demo-imported"));
    Ok(removed)
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
    /// 插件来源的曲目：前端沙箱先用 getMediaSource 解析出地址与请求头，
    /// key 是曲目 id。别的来源忽略这个字段。
    #[serde(default)]
    pub resolved: std::collections::HashMap<String, plugin::ResolvedTrack>,
}
#[derive(Deserialize)]
pub struct QueueReference {
    pub source_id: String,
    pub locator: String,
}

#[tauri::command]
fn play_track(req: PlayRequest, state: State<'_, AppState>) -> Result<String, String> {
    let PlayRequest {
        source_id,
        locator: play_locator,
        gains,
        continuation,
        queue,
        resolved,
    } = req;
    if let Some(gains) = gains {
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
        source_id: source_id.clone(),
        locator: play_locator.clone(),
    }];
    references.extend(queue.into_iter().take(9999));
    let queued = {
        let lib = state.library.lock();
        let mut access_cache = std::collections::HashMap::new();
        let mut tracks = Vec::new();
        for (index, r) in references.into_iter().enumerate() {
            let track = match lib
                .snapshot
                .tracks
                .iter()
                .find(|t| t.source_id == r.source_id && t.locator == r.locator)
            {
                Some(track) => track,
                None => return Err("队列曲目不存在".into()),
            };
            let source = match lib
                .snapshot
                .sources
                .iter()
                .find(|s| s.id == r.source_id)
            {
                Some(source) => source,
                None => return Err("队列来源不存在".into()),
            };
            // 插件来源：地址由前端沙箱解析，随请求传来；拿不到解析结果就跳过队列条目，
            // 第一首（用户点的那首）拿不到则直接报错，让用户回到搜索页重试。
            if source.kind == SourceKind::Plugin {
                let Some(resolved) = resolved.get(&track.id) else {
                    if index == 0 {
                        return Err(format!(
                            "《{}》还没有解析出播放地址：回到这个插件来源里重新搜索一次",
                            track.title
                        ));
                    }
                    log::warn!("跳过没有解析地址的插件曲目：{}", track.title);
                    continue;
                };
                let resolved = resolved.clone().validated()?;
                tracks.push(playback::QueueTrack {
                    id: track.id.clone(),
                    path: PathBuf::new(),
                    opener: Some(remote::direct_factory(
                        resolved.url,
                        resolved.headers,
                        source.trust_self_signed,
                    )),
                    duration: track.duration,
                    sample_rate: track.sample_rate,
                });
                continue;
            }
            let remote = matches!(
                source.kind,
                SourceKind::Webdav | SourceKind::Plex | SourceKind::Telegram
            );
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
            tracks.push(playback::QueueTrack {
                id: track.id.clone(),
                path,
                opener,
                duration: track.duration,
                sample_rate: track.sample_rate,
            });
        }
        tracks
    };
    if queued.is_empty() {
        return Err("队列里没有可播放的曲目".into());
    }
    let taste = state.taste.clone();
    let data_dir = state.data_dir.clone();
    state.player.play_queue(
        queued,
        !continuation,
        move |id, seconds, completed, skipped| {
            if let Err(e) =
                experience::record_session(&taste, &data_dir, id, seconds, completed, skipped)
            {
                log::error!("收听历史保存失败：{e}");
            }
        },
    )?;
    Ok(play_locator)
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
                    if track.media_info.is_none() {
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
    let (kind, root) = {
        let lib = state.library.lock();
        let source = lib
            .snapshot
            .sources
            .iter()
            .find(|s| s.id == source_id)
            .ok_or_else(|| "找不到来源".to_string())?;
        (source.kind, source.url.clone())
    };
    if kind == SourceKind::Plugin {
        // 插件曲目的音频地址是每次播放按需解析的，频谱画像不做额外解析请求。
        return Err("网络插件来源暂不支持频谱分析，播放不受影响".into());
    }
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
    let lib = state.library.lock();
    let track = lib
        .snapshot
        .tracks
        .iter()
        .find(|t| t.source_id == source_id && t.locator == locator)
        .ok_or("曲目不存在")?;
    if !track.lyrics.is_empty() {
        return Ok(awake_core::lyrics::parse(&track.lyrics));
    }
    let source = lib
        .snapshot
        .sources
        .iter()
        .find(|s| s.id == source_id)
        .ok_or("找不到来源")?;
    if !matches!(source.kind, SourceKind::Local | SourceKind::Smb) {
        return Ok(vec![]);
    }
    let path = PathBuf::from(&source.url)
        .join(locator)
        .with_extension("lrc");
    if !path.is_file() {
        return Ok(vec![]);
    }
    if std::fs::metadata(&path).map_err(|e| e.to_string())?.len() > 131072 {
        return Err("歌词文件超过 128 KB".into());
    }
    let input = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    Ok(awake_core::lyrics::parse(&input))
}


/// 路径规范化：菜单/输入框里粘进来的路径形态不统一 —— 带引号、带 file:// 前缀、
/// 带 ~、末尾多一个斜杠，都会让 is_dir() 判假，用户看到的就是「选好文件夹也扫不出东西」。
pub fn normalize_music_path(raw: &str) -> Result<String, String> {
    let mut text = raw.trim().to_string();
    // Finder 的「拷贝为路径名」不会带引号，但从终端复制的常带。
    while text.len() >= 2 {
        let first = text.chars().next().unwrap_or(' ');
        let last = text.chars().last().unwrap_or(' ');
        if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
            text = text[1..text.len() - 1].trim().to_string();
        } else {
            break;
        }
    }
    if let Some(rest) = text.strip_prefix("file://") {
        // file:///Users/x/My%20Music -> /Users/x/My Music
        let rest = rest.strip_prefix("localhost").unwrap_or(rest);
        text = percent_decode(rest);
    }
    if text == "~" || text.starts_with("~/") {
        let home = std::env::var("HOME").unwrap_or_default();
        if !home.is_empty() {
            text = format!("{home}{}", &text[1..]);
        }
    }
    while text.len() > 1 && text.ends_with('/') {
        text.pop();
    }
    if text.trim().is_empty() {
        return Err("请选一个音乐文件夹".into());
    }
    Ok(text)
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok();
            if let Some(value) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(value);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

/// 连接之前先看一眼：这个路径到底有没有音乐、能不能读。
#[derive(Serialize)]
pub struct MusicPathProbe {
    /// directory | file | missing | unreadable
    pub kind: String,
    pub path: String,
    pub audio_count: usize,
    pub sample: Vec<String>,
    pub message: String,
}

fn probe_music_dir(path: &std::path::Path) -> MusicPathProbe {
    match std::fs::read_dir(path) {
        Ok(_) => {
            let files = library::collect_audio_files(path);
            let sample: Vec<String> = files
                .iter()
                .take(5)
                .map(|f| {
                    f.file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_default()
                })
                .collect();
            let message = if files.is_empty() {
                "这个文件夹里没有找到音频文件（支持 FLAC / ALAC / MP3 / AAC / WAV / AIFF / OGG / M4B）"
                    .to_string()
            } else {
                format!("找到 {} 个音频文件", files.len())
            };
            MusicPathProbe {
                kind: "directory".into(),
                path: path.to_string_lossy().to_string(),
                audio_count: files.len(),
                sample,
                message,
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => MusicPathProbe {
            kind: "unreadable".into(),
            path: path.to_string_lossy().to_string(),
            audio_count: 0,
            sample: Vec::new(),
            message: "系统不允许 Awake 读这个文件夹：打开「系统设置 → 隐私与安全性 → 文件与文件夹」给 Awake 打开权限，或把音乐放到「音乐」文件夹再选".into(),
        },
        Err(_) => MusicPathProbe {
            kind: "unreadable".into(),
            path: path.to_string_lossy().to_string(),
            audio_count: 0,
            sample: Vec::new(),
            message: "这个文件夹读不出来：检查它是否还在、是否已挂载".into(),
        },
    }
}

fn probe_music_path_blocking(raw: &str) -> MusicPathProbe {
    let path = match normalize_music_path(raw) {
        Ok(path) => path,
        Err(message) => {
            return MusicPathProbe {
                kind: "missing".into(),
                path: String::new(),
                audio_count: 0,
                sample: Vec::new(),
                message,
            }
        }
    };
    let resolved = std::path::PathBuf::from(&path);
    if resolved.is_dir() {
        return probe_music_dir(&resolved);
    }
    if resolved.is_file() {
        let supported = library::is_audio_file(&resolved);
        return MusicPathProbe {
            kind: "file".into(),
            path,
            audio_count: usize::from(supported),
            sample: resolved
                .file_name()
                .map(|n| vec![n.to_string_lossy().to_string()])
                .unwrap_or_default(),
            message: if supported {
                "这是一个音频文件，会单独作为一首导入".to_string()
            } else {
                "这个文件不是受支持的音频格式".to_string()
            },
        };
    }
    MusicPathProbe {
        kind: "missing".into(),
        path,
        audio_count: 0,
        sample: Vec::new(),
        message: "这个路径不存在：确认文件夹还在，或重新选一次".into(),
    }
}

#[tauri::command]
async fn probe_music_path(path: String) -> Result<MusicPathProbe, String> {
    tauri::async_runtime::spawn_blocking(move || probe_music_path_blocking(&path))
        .await
        .map_err(|_| "检查路径时被打断，请重试".to_string())
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

#[tauri::command]
async fn pick_music_files() -> Result<Vec<String>, String> {
    tauri::async_runtime::spawn_blocking(|| {
        #[cfg(target_os = "macos")]
        {
            let output = std::process::Command::new("osascript")
                .args([
                    "-e",
                    "set chosen to choose file with prompt \"选择要导入的音频文件（可多选）\" with multiple selections allowed",
                    "-e",
                    "set out to \"\"",
                    "-e",
                    "repeat with f in chosen",
                    "-e",
                    "set out to out & POSIX path of f & linefeed",
                    "-e",
                    "end repeat",
                    "-e",
                    "return out",
                ])
                .output()
                .map_err(|_| "无法打开文件选择器".to_string())?;
            if !output.status.success() {
                let error = String::from_utf8_lossy(&output.stderr);
                if error.contains("-128") {
                    return Ok(Vec::new());
                }
                return Err(format!(
                    "文件选择器没有完成：{}",
                    error.trim().chars().take(160).collect::<String>()
                ));
            }
            Ok(String::from_utf8_lossy(&output.stdout)
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(str::to_string)
                .collect())
        }
        #[cfg(not(target_os = "macos"))]
        {
            Ok(Vec::new())
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
            // 本地版：首次运行时把打进包的示例曲库（Contents/Resources/DemoMusic）导入。
            // 不联网、不依赖来源配置；标记文件落盘后不再重复。
            {
                let handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    let state = handle.state::<AppState>();
                    let marker = state.data_dir.join(".builtin-demo-imported");
                    if marker.exists() {
                        return;
                    }
                    let Ok(resource) = handle.path().resource_dir() else {
                        return;
                    };
                    let dir = resource.join("DemoMusic");
                    let mut paths = Vec::new();
                    collect_audio_files(&dir, &mut paths);
                    if paths.is_empty() {
                        return;
                    }
                    let args: Vec<String> =
                        paths.iter().map(|p| p.to_string_lossy().to_string()).collect();
                    if scan_files(args, true, Some("内置示例".into()), state).await.is_ok() {
                        let _ = std::fs::write(&marker, b"1");
                    }
                });
            }
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
            intelligence::suggest_curve,
            builtin_demo_status,
            builtin_demo_install,
            builtin_demo_remove,
            local_records_clear,
            media_info::inspect_media,
            media_info::search_media_info,
            media_info::fetch_media_resources,
            media_info::save_media_info,
            media_info::reset_media_info,
            media_info::import_media_attachment,
            telegram::telegram_catalog,
            telegram::open_telegram_link,
            telegram::telegram_collection,
            telegram::telegram_sponsored,
            telegram::telegram_ad_viewed,
            telegram::parse_source_configuration,
            intelligence::get_services,
            intelligence::generate_skin,
            intelligence::save_service,
            intelligence::curate_music,
            intelligence::start_generation,
            intelligence::cancel_generation,
            intelligence::reveal_generation,
            feeds::subscribe_feed,
            connections::connect_source,
            plex::plex_pin_create,
            plex::plex_pin_poll,
            plex::plex_open_auth,
            plex::plex_resources,
            plex::plex_probe,
            plex::plex_sections,
            plex::plex_account_get,
            plex::plex_account_save,
            plex::plex_account_forget,
            connections::remove_source,
            probe_music_path,
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
            pick_music_folder,
            playlist_import::playlist_import_fetch,
            playlist_import::playlist_import_file,
            playlist_import::playlist_import_match,
            playlist_import::playlist_import_gaps,
            insight::library_coverage,
            insight::listening_achievements,
            preset::ai_presets,
            import_local_files,
            pick_music_files,
            plugin::import_plugin,
            plugin::read_plugin_source,
            plugin::save_plugin_tracks,
            plugin::plugin_http,
            audiobook::audiobook_shelf,
            audiobook::audiobook_progress,
            audiobook::audiobook_forget,
            weekly::weekly_summary,
            news::news_add,
            news::news_list,
            news::news_delete,
            news::news_plan,
            speech::speech_voices,
            speech::speech_plan,
            speech::speech_render,
            speech::speech_status,
            backup::backup_export,
            backup::backup_export_file,
            backup::backup_inspect,
            backup::backup_restore,
            handoff::handoff_start,
            handoff::handoff_status,
            handoff::handoff_stop,
            handoff_send::handoff_scan_phones,
            handoff_send::handoff_send_to_phone
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
mod path_tests {
    use super::*;

    fn scratch(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("awake-path-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn paths_from_every_clipboard_shape_resolve_to_one_folder() {
        assert_eq!(normalize_music_path("  /Users/x/Music/  ").unwrap(), "/Users/x/Music");
        assert_eq!(
            normalize_music_path("\"/Users/x/My Music/\"").unwrap(),
            "/Users/x/My Music"
        );
        assert_eq!(
            normalize_music_path("file:///Users/x/My%20Music").unwrap(),
            "/Users/x/My Music"
        );
        assert!(normalize_music_path("   ").is_err());
    }

    #[test]
    fn a_picked_folder_is_checked_before_it_is_connected() {
        let dir = scratch("probe");
        std::fs::write(dir.join("one.mp3"), b"x").unwrap();
        std::fs::write(dir.join("two.FLAC"), b"x").unwrap();
        std::fs::write(dir.join("notes.txt"), b"x").unwrap();
        let probe = probe_music_path_blocking(&dir.to_string_lossy());
        assert_eq!(probe.kind, "directory");
        assert_eq!(probe.audio_count, 2, "只数音频文件，大小写都算");
        assert_eq!(probe.sample.len(), 2);
        assert!(probe.message.contains('2'));
        let single = probe_music_path_blocking(&dir.join("one.mp3").to_string_lossy());
        assert_eq!(single.kind, "file");
        assert_eq!(single.audio_count, 1);
        let missing = probe_music_path_blocking(&dir.join("nope").to_string_lossy());
        assert_eq!(missing.kind, "missing");
        assert!(missing.message.contains("不存在"));
        let empty = scratch("probe-empty");
        let none = probe_music_path_blocking(&empty.to_string_lossy());
        assert_eq!(none.audio_count, 0);
        assert!(none.message.contains("没有找到"));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&empty);
    }

    #[test]
    fn an_unreadable_folder_says_so_instead_of_zero_tracks() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let dir = scratch("probe-denied");
            std::fs::write(dir.join("a.mp3"), b"x").unwrap();
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o000)).unwrap();
            let probe = probe_music_path_blocking(&dir.to_string_lossy());
            assert_eq!(probe.kind, "unreadable", "读不到就直说读不到，不要报 0 首");
            assert!(probe.message.contains("隐私与安全性"));
            // 收尾：权限先恢复，才删得掉。
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
            let _ = std::fs::remove_dir_all(&dir);
        }
    }
}
#[cfg(test)]
mod allocation_audit;
#[cfg(test)]
#[global_allocator]
static TEST_ALLOCATOR: allocation_audit::Audited = allocation_audit::Audited;
