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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use tauri::State;

/// 全局状态。
pub struct AppState {
    pub library: Mutex<Library>,
    pub player: Arc<PlayerHandle>,
    pub data_dir: PathBuf,
}

impl AppState {
    pub fn new() -> Self {
        let data_dir = default_data_dir();
        let store = data_dir.join("library.json");
        std::fs::create_dir_all(&data_dir).ok();
        Self {
            library: Mutex::new(Library::open(store)),
            player: Arc::new(PlayerHandle::new()),
            data_dir,
        }
    }
}

fn default_data_dir() -> PathBuf {
    // macOS: ~/Library/Application Support/Awake
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join("Library/Application Support/Awake")
}

/// 播放控制句柄。
pub struct PlayerHandle {
    stop_flag: Arc<AtomicBool>,
    playing: Arc<AtomicBool>,
    current_id: Arc<Mutex<Option<String>>>,
    started_at: Arc<AtomicU64>,
}

impl PlayerHandle {
    fn new() -> Self {
        Self {
            stop_flag: Arc::new(AtomicBool::new(false)),
            playing: Arc::new(AtomicBool::new(false)),
            current_id: Arc::new(Mutex::new(None)),
            started_at: Arc::new(AtomicU64::new(0)),
        }
    }

    fn stop(&self) {
        self.stop_flag.store(true, Ordering::SeqCst);
    }
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
}

#[tauri::command]
fn scan_library(req: ScanRequest, state: State<'_, AppState>) -> Result<ScanResult, String> {
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
    let tracks = library::scan_local_source(
        &root,
        &source_id,
        &existing,
        Some(&artwork_dir),
        |_, _, _| {},
    )
    .map_err(|e| e.to_string())?;

    let albums = group_albums(&tracks);

    {
        let mut lib = state.library.lock();
        lib.replace_source_tracks(&source_id, tracks.clone());

        let name = req
            .name
            .clone()
            .or_else(|| {
                root.file_name()
                    .map(|n| n.to_string_lossy().to_string())
            })
            .unwrap_or_else(|| "曲库".into());

        let mut source = MediaSource::new(SourceKind::Local, name, req.path.clone());
        source.id = source_id;
        source.track_count = tracks.len();
        source.last_scan = Some(awake_core::models::now_ms());
        lib.snapshot.sources.retain(|s| s.id != source.id);
        lib.add_source(source);
        lib.snapshot.scanned_at = Some(awake_core::models::now_ms());
        lib.save().map_err(|e| e.to_string())?;
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
        sources: lib.snapshot.sources.clone(),
    }
}

#[derive(Deserialize)]
pub struct PlayRequest {
    pub source_id: String,
    pub locator: String,
    /// 31 段增益（dB），空则用平坦曲线
    pub gains: Option<Vec<f32>>,
}

#[tauri::command]
fn play_track(req: PlayRequest, state: State<'_, AppState>) -> Result<String, String> {
    let player = state.player.clone();
    player.stop();
    std::thread::sleep(std::time::Duration::from_millis(80));

    let source_root = {
        let lib = state.library.lock();
        lib.snapshot
            .sources
            .iter()
            .find(|s| s.id == req.source_id)
            .map(|s| s.url.clone())
            .ok_or_else(|| "找不到曲目来源".to_string())?
    };

    let full_path = PathBuf::from(&source_root).join(&req.locator);
    if !full_path.is_file() {
        return Err(format!("文件不存在: {}", full_path.display()));
    }

    let gains = req.gains.unwrap_or_else(|| vec![0.0; 31]);
    let stopped = Arc::new(AtomicBool::new(false));
    let playing = Arc::new(AtomicBool::new(false));

    // 更新句柄，让 stop 能打到这条流
    {
        let mut guard = state.player.current_id.lock();
        *guard = Some(req.locator.clone());
    }
    state.player.stop_flag.store(false, Ordering::SeqCst);

    let path = full_path.clone();
    let stop_clone = stopped.clone();
    let playing_clone = playing.clone();
    let parent_stop = state.player.stop_flag.clone();
    let parent_playing = state.player.playing.clone();

    std::thread::spawn(move || {
        match play_audio(&path, &gains, stop_clone.clone(), playing_clone.clone(), &parent_stop, &parent_playing) {
            Ok(()) => log::info!("播放结束: {}", path.display()),
            Err(e) => log::error!("播放失败: {e}"),
        }
    });

    Ok(req.locator)
}

#[tauri::command]
fn stop_playback(state: State<'_, AppState>) {
    state.player.stop();
    state.player.playing.store(false, Ordering::SeqCst);
}

#[derive(Serialize)]
pub struct PlaybackStatus {
    pub playing: bool,
    pub current: Option<String>,
}

#[tauri::command]
fn playback_status(state: State<'_, AppState>) -> PlaybackStatus {
    PlaybackStatus {
        playing: state.player.playing.load(Ordering::SeqCst),
        current: state.player.current_id.lock().clone(),
    }
}

#[derive(Deserialize)]
pub struct EqRequest {
    pub gains: Vec<f32>,
    pub preamp: f32,
}

#[tauri::command]
fn set_eq_curve(req: EqRequest, state: State<'_, AppState>) -> String {
    // 曲线在播放时应用；这里只校验并回报归一化结果
    let curve = eq::EqCurve::new(&req.gains, req.preamp).headroom(1.0);
    {
        let guard = state.player.current_id.lock();
        let _ = &guard;
    }
    format!(
        "曲线已接受：preamp {:.1} dB，最大提升 {:.1} dB",
        curve.preamp,
        curve.max_gain()
    )
}

#[derive(Serialize)]
pub struct Analysis {
    pub bands: Vec<f32>,
    pub peak: f32,
    pub duration: f64,
    pub sample_rate: u32,
}

#[tauri::command]
fn analyze_track(source_id: String, locator: String, state: State<'_, AppState>) -> Result<Analysis, String> {
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
    let audio = decode::decode_file(&path).map_err(|e| e.to_string())?;
    let mono = awake_core::to_mono(&audio.samples, audio.format.channels);
    let mut analyzer = awake_core::SpectrumAnalyzer::new(8192, audio.format.sample_rate as f32);
    let profile = analyzer.profile(&mono, audio.format.sample_rate as f32);
    Ok(Analysis {
        bands: profile.bands.to_vec(),
        peak: audio.peak(),
        duration: audio.duration_secs(),
        sample_rate: audio.format.sample_rate,
    })
}

/// 实际播放：解码 → EQ → cpal 输出（自动重采样到设备格式）。
fn play_audio(
    path: &std::path::Path,
    gains: &[f32],
    stopped: Arc<AtomicBool>,
    playing: Arc<AtomicBool>,
    parent_stop: &Arc<AtomicBool>,
    parent_playing: &Arc<AtomicBool>,
) -> anyhow::Result<()> {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

    let mut audio = decode::decode_file(path)?;
    let src_rate = audio.format.sample_rate;
    let channels = audio.format.channels;

    let curve = eq::EqCurve::new(gains, 0.0).headroom(1.0);
    let mut equalizer = eq::Equalizer::new(src_rate as f32, channels);
    equalizer.apply_curve(&curve);
    equalizer.process_interleaved(&mut audio.samples);

    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or_else(|| anyhow::anyhow!("没有可用的音频输出设备"))?;

    // 优先原生采样率
    let mut chosen = None;
    if let Ok(configs) = device.supported_output_configs() {
        for range in configs {
            if range.channels() as usize == channels
                && range.min_sample_rate().0 <= src_rate
                && src_rate <= range.max_sample_rate().0
            {
                chosen = Some(range.with_sample_rate(cpal::SampleRate(src_rate)));
                break;
            }
        }
    }
    let config = match chosen {
        Some(c) => c,
        None => device.default_output_config()?,
    };
    let out_rate = config.sample_rate().0;
    let out_channels = config.channels() as usize;

    let data = if out_rate != src_rate {
        awake_core::resample_interleaved(&audio.samples, channels, src_rate, out_rate)?
    } else {
        audio.samples.clone()
    };

    let total = data.len() / channels.max(1);
    let mut pos = 0usize;
    playing.store(true, Ordering::SeqCst);
    parent_playing.store(true, Ordering::SeqCst);

    let data_arc = Arc::new(data);
    let data_ref = data_arc.clone();
    let stopped_flag = stopped.clone();

    let stream = device.build_output_stream(
        &config.config(),
        move |output: &mut [f32], _| {
            output.fill(0.0);
            if stopped_flag.load(Ordering::SeqCst) {
                return;
            }
            let frames = output.len() / out_channels;
            for f in 0..frames {
                if pos >= total {
                    return;
                }
                for c in 0..out_channels {
                    let src_c = c.min(channels - 1);
                    output[f * out_channels + c] = data_ref[pos * channels + src_c];
                }
                pos += 1;
            }
        },
        move |err| log::error!("音频流错误: {err}"),
        None,
    )?;

    stream.play()?;

    // 等播放结束或被外部停止
    while pos < total {
        if parent_stop.load(Ordering::SeqCst) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }

    playing.store(false, Ordering::SeqCst);
    parent_playing.store(false, Ordering::SeqCst);
    drop(stream);
    Ok(())
}

pub fn run() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    tauri::Builder::default()
        .setup(|app| {
            // 诊断：打印窗口实际加载的 URL 与前端资源解析结果
            tauri::Manager::get_webview_window(app, "main").map(|w| {
                println!("[awake] WINDOW_URL={:?}", w.url());
                let _ = w.eval("console.log('window ready', location.href)");
            });
            Ok(())
        })
        .manage(AppState::new())
        .invoke_handler(tauri::generate_handler![
            scan_library,
            set_traffic_lights,
            frontend_ready,
            load_library,
            play_track,
            stop_playback,
            playback_status,
            set_eq_curve,
            analyze_track
        ])
        .run(tauri::generate_context!())
        .expect("启动 Awake 失败");
}
