//! 手机 → 电脑播放接力。协议见 docs/handoff-protocol.md（v1）。
//!
//! 电脑端在用户点击「接收接力」后启动：mDNS 发布 _awake._tcp，HTTP 监听临时端口，
//! 6 位配对码是唯一授权凭据；10 分钟无请求自动过期，停止后端口与 mDNS 注销。
//! 只接受局域网内的 POST /handoff，不保存任何凭据，也不开放公网。
use crate::AppState;
use awake_core::models::SourceKind;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Read;
use std::net::{Ipv4Addr, TcpListener, UdpSocket};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tauri::{Emitter, State};

use mdns_sd::{ServiceDaemon, ServiceInfo};
use tiny_http::{Header, Method, Request, Response, Server, StatusCode};

const SERVICE_TYPE: &str = "_awake._tcp.local.";
const SERVICE_VERSION: &str = "2";
/// 10 分钟无请求自动过期。
const SESSION_TTL: Duration = Duration::from_secs(10 * 60);
/// 每 2 秒最多处理 1 个请求。
const MIN_INTERVAL: Duration = Duration::from_millis(2000);
/// 配对码最多错 5 次，超过则换新码。
const MAX_WRONG: u8 = 5;
/// 请求体上限 8 KB。
const MAX_BODY: usize = 8 * 1024;
const MATCH_THRESHOLD: f64 = 0.62;
const DURATION_TOLERANCE: f64 = 5.0;
const MAX_POSITION: f64 = 24.0 * 3600.0;
const MAX_TEXT_FIELD: usize = 512;
const MAX_CODE_LEN: usize = 16;

#[derive(Debug, Clone, Serialize)]
pub struct HandoffSession {
    pub code: String,
    pub port: u16,
    pub name: String,
    pub url_hint: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct HandoffStatus {
    pub active: bool,
    pub code: String,
    pub port: u16,
    pub name: String,
    pub last_message: String,
}

#[derive(Debug, Clone, Deserialize)]
struct HandoffTrack {
    title: String,
    artist: String,
    album: String,
    duration: f64,
}

#[derive(Debug, Clone, Deserialize)]
struct HandoffRequest {
    code: String,
    track: HandoffTrack,
    position: f64,
    #[serde(default)]
    playing: bool,
}

/// 发给前端的 payload：{title, position, matched}。
#[derive(Debug, Clone, Serialize)]
struct HandoffEvent {
    title: String,
    position: f64,
    matched: bool,
}

/// 配对码状态机。所有判断都只依赖传入的时间，便于单测。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Verdict {
    Expired,
    TooSoon,
    Wrong,
    Rotated,
    Accepted,
}

#[derive(Debug)]
struct Gate {
    code: String,
    wrong: u8,
    last_request: Option<Instant>,
    expires_at: Instant,
}

impl Gate {
    fn new(code: String, now: Instant) -> Self {
        Self {
            code,
            wrong: 0,
            last_request: None,
            expires_at: now + SESSION_TTL,
        }
    }

    fn code(&self) -> &str {
        &self.code
    }

    fn expired(&self, now: Instant) -> bool {
        now >= self.expires_at
    }

    fn evaluate(&mut self, now: Instant, supplied: &str) -> Verdict {
        if now >= self.expires_at {
            return Verdict::Expired;
        }
        if let Some(last) = self.last_request {
            if now.saturating_duration_since(last) < MIN_INTERVAL {
                return Verdict::TooSoon;
            }
        }
        // 无论码对错都占用这一次窗口，避免用错码暴力猜。
        self.last_request = Some(now);
        self.expires_at = now + SESSION_TTL;
        if supplied.trim() != self.code {
            self.wrong = self.wrong.saturating_add(1);
            if self.wrong >= MAX_WRONG {
                self.wrong = 0;
                self.code = random_code();
                return Verdict::Rotated;
            }
            return Verdict::Wrong;
        }
        self.wrong = 0;
        Verdict::Accepted
    }
}

fn random_code() -> String {
    let mut bytes = [0u8; 8];
    if std::fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .is_err()
    {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0);
        bytes = nanos.to_le_bytes();
    }
    format!("{:06}", u64::from_le_bytes(bytes) % 1_000_000)
}

/// 主机名：优先 macOS 的 LocalHostName，失败再退回环境变量。
pub(crate) fn host_name() -> String {
    if let Ok(output) = std::process::Command::new("scutil")
        .args(["--get", "LocalHostName"])
        .output()
    {
        if output.status.success() {
            let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !name.is_empty() {
                return name;
            }
        }
    }
    for key in ["HOSTNAME", "COMPUTERNAME"] {
        if let Ok(value) = std::env::var(key) {
            let name = value.trim().to_string();
            if !name.is_empty() {
                return name;
            }
        }
    }
    "Awake".into()
}

/// DNS-SD 实例名/主机名只保留安全字符。
fn mdns_label(name: &str) -> String {
    let label: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect();
    let trimmed = label.trim_matches('-').to_string();
    if trimmed.is_empty() {
        "Awake".into()
    } else {
        trimmed
    }
}

/// 局域网 IPv4，仅用于给界面显示可手动输入的地址；不做任何外部连接。
fn local_ipv4() -> Option<Ipv4Addr> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    // UDP connect 不发包，只让系统选一张出口网卡。
    socket.connect("192.0.2.1:9").ok()?;
    match socket.local_addr().ok()?.ip() {
        std::net::IpAddr::V4(ip) => Some(ip),
        std::net::IpAddr::V6(_) => None,
    }
}

// ---------------------------------------------------------------------------
// 曲库匹配（纯函数，便于单测）
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct Candidate {
    id: String,
    title: String,
    artist: String,
    album: String,
    duration: f64,
    /// 本地可播放路径；远程来源没有直接文件路径。
    path: Option<PathBuf>,
    sample_rate: u32,
}

/// 去掉括号内容、feat 之后内容、标点与大小写，供 bigram 相似度比较。
fn normalize(text: &str) -> String {
    let lower = text.to_lowercase();
    let mut depth = 0usize;
    let mut without_brackets = String::with_capacity(lower.len());
    for ch in lower.chars() {
        match ch {
            '(' | '[' | '{' | '（' | '【' | '〔' => {
                depth += 1;
            }
            ')' | ']' | '}' | '）' | '】' | '〕' => {
                depth = depth.saturating_sub(1);
            }
            _ if depth > 0 => {}
            _ => without_brackets.push(ch),
        }
    }
    let mut filtered = String::with_capacity(without_brackets.len());
    for ch in without_brackets.chars() {
        if ch.is_alphanumeric() || ch.is_whitespace() {
            filtered.push(ch);
        } else {
            filtered.push(' ');
        }
    }
    let mut tokens: Vec<&str> = filtered.split_whitespace().collect();
    if let Some(position) = tokens
        .iter()
        .position(|token| matches!(*token, "feat" | "ft" | "featuring"))
    {
        tokens.truncate(position);
    }
    const NOISE: [&str; 12] = [
        "official",
        "video",
        "lyrics",
        "lyric",
        "audio",
        "hd",
        "4k",
        "remaster",
        "remastered",
        "version",
        "高清",
        "官方",
    ];
    tokens
        .into_iter()
        .filter(|token| !NOISE.contains(token))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shingles(text: &str) -> HashMap<String, usize> {
    let chars: Vec<char> = text.chars().collect();
    let mut map: HashMap<String, usize> = HashMap::new();
    if chars.len() < 2 {
        if let Some(ch) = chars.first() {
            map.insert(ch.to_string(), 1);
        }
        return map;
    }
    for window in chars.windows(2) {
        let gram: String = window.iter().collect();
        *map.entry(gram).or_insert(0) += 1;
    }
    map
}

/// 字符 bigram Dice 系数，0..=1。
fn similarity(left: &str, right: &str) -> f64 {
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    if left == right {
        return 1.0;
    }
    let left_shingles = shingles(left);
    let right_shingles = shingles(right);
    let left_total: usize = left_shingles.values().sum();
    let right_total: usize = right_shingles.values().sum();
    if left_total == 0 || right_total == 0 {
        return 0.0;
    }
    let mut intersection = 0usize;
    for (gram, count) in &left_shingles {
        if let Some(other) = right_shingles.get(gram) {
            intersection += (*count).min(*other);
        }
    }
    2.0 * intersection as f64 / (left_total + right_total) as f64
}

/// 曲名 0.55 + 艺人 0.35 + 专辑 0.10（手机没给某项时按剩余权重归一），
/// 再叠加时长接近度。时长差超过 ±5s 直接淘汰。
fn score_candidate(query: &HandoffTrack, candidate: &Candidate) -> Option<f64> {
    if query.duration > 0.0 && candidate.duration > 0.0 {
        let diff = (query.duration - candidate.duration).abs();
        if diff > DURATION_TOLERANCE {
            return None;
        }
    }
    let title = similarity(&normalize(&query.title), &normalize(&candidate.title));
    let mut weighted = 0.55 * title;
    let mut total = 0.55;
    if !query.artist.trim().is_empty() {
        let artist = similarity(&normalize(&query.artist), &normalize(&candidate.artist));
        weighted += 0.35 * artist;
        total += 0.35;
    }
    if !query.album.trim().is_empty() {
        let album = similarity(&normalize(&query.album), &normalize(&candidate.album));
        weighted += 0.10 * album;
        total += 0.10;
    }
    let mut score = weighted / total;
    if query.duration > 0.0 && candidate.duration > 0.0 {
        let diff = (query.duration - candidate.duration).abs();
        score += 0.05 * (1.0 - diff / DURATION_TOLERANCE);
    }
    Some(score.clamp(0.0, 1.0))
}

/// 返回分数最高的“本地文件存在”的候选；远程度假候选不会遮挡本地曲目。
fn best_match(query: &HandoffTrack, candidates: &[Candidate]) -> Option<(usize, f64)> {
    let mut ranked: Vec<(usize, f64)> = candidates
        .iter()
        .enumerate()
        .filter_map(|(index, candidate)| {
            score_candidate(query, candidate)
                .filter(|score| *score >= MATCH_THRESHOLD)
                .map(|score| (index, score))
        })
        .collect();
    ranked.sort_by(|left, right| {
        right
            .1
            .total_cmp(&left.1)
            .then_with(|| left.0.cmp(&right.0))
    });
    for (index, score) in ranked {
        if candidates[index]
            .path
            .as_ref()
            .is_some_and(|path| path.is_file())
        {
            return Some((index, score));
        }
    }
    None
}

fn build_candidates(library: &awake_core::Library) -> Vec<Candidate> {
    let snapshot = &library.snapshot;
    snapshot
        .tracks
        .iter()
        .map(|track| {
            let path = snapshot
                .sources
                .iter()
                .find(|source| source.id == track.source_id)
                .and_then(|source| match source.kind {
                    SourceKind::Local | SourceKind::Smb => {
                        Some(PathBuf::from(&source.url).join(&track.locator))
                    }
                    _ => None,
                });
            Candidate {
                id: track.id.clone(),
                title: track.title.clone(),
                artist: track.artist.clone(),
                album: track.album.clone(),
                duration: track.duration,
                path,
                sample_rate: track.sample_rate,
            }
        })
        .collect()
}

// ---------------------------------------------------------------------------
// HTTP 请求解析（纯函数，便于单测）
// ---------------------------------------------------------------------------

fn parse_request(body: &[u8]) -> Result<HandoffRequest, String> {
    let request: HandoffRequest =
        serde_json::from_slice(body).map_err(|_| "请求格式错误".to_string())?;
    if request.code.trim().is_empty() || request.code.len() > MAX_CODE_LEN {
        return Err("请求格式错误".into());
    }
    if request.track.title.trim().is_empty() {
        return Err("请求格式错误".into());
    }
    for field in [
        &request.track.title,
        &request.track.artist,
        &request.track.album,
    ] {
        if field.chars().count() > MAX_TEXT_FIELD {
            return Err("请求格式错误".into());
        }
    }
    if !request.track.duration.is_finite() || request.track.duration < 0.0 {
        return Err("请求格式错误".into());
    }
    if !request.position.is_finite() || request.position < 0.0 || request.position > MAX_POSITION {
        return Err("请求格式错误".into());
    }
    Ok(request)
}

enum BodyError {
    TooLarge,
    Unreadable,
}

fn read_body(request: &mut Request, limit: usize) -> Result<Vec<u8>, BodyError> {
    let mut body = Vec::new();
    let mut reader = request.as_reader().take(limit as u64 + 1);
    reader
        .read_to_end(&mut body)
        .map_err(|_| BodyError::Unreadable)?;
    if body.len() > limit {
        return Err(BodyError::TooLarge);
    }
    Ok(body)
}

fn respond_json(request: Request, status: u16, value: serde_json::Value) {
    let content_type = Header::from_bytes("Content-Type", "application/json; charset=utf-8")
        .expect("static header");
    let connection = Header::from_bytes("Connection", "close").expect("static header");
    let response = Response::from_string(value.to_string())
        .with_status_code(StatusCode(status))
        .with_header(content_type)
        .with_header(connection);
    let _ = request.respond(response);
}

fn error_body(error: &str) -> serde_json::Value {
    serde_json::json!({"ok": false, "matched": false, "error": error})
}

// ---------------------------------------------------------------------------
// 会话状态与 HTTP 处理
// ---------------------------------------------------------------------------

struct PlayOutcome {
    matched: bool,
    title: String,
}

struct Shared {
    gate: Mutex<Gate>,
    app: Option<tauri::AppHandle>,
    player: Option<Arc<crate::playback::Player>>,
    library: Option<Arc<parking_lot::Mutex<awake_core::Library>>>,
    last_message: Mutex<String>,
    stopped: AtomicBool,
}

impl Shared {
    fn message(&self) -> String {
        self.last_message
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn set_message(&self, text: impl Into<String>) {
        let text = text.into();
        *self
            .last_message
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = text.clone();
        *LAST_MESSAGE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = text;
    }

    fn play(&self, requested: &HandoffTrack, position: f64, playing: bool) -> PlayOutcome {
        let unmatched = || PlayOutcome {
            matched: false,
            title: requested.title.clone(),
        };
        let (Some(library), Some(player)) = (self.library.as_ref(), self.player.as_ref()) else {
            return unmatched();
        };
        let candidates = {
            let library = library.lock();
            build_candidates(&library)
        };
        let Some((index, _score)) = best_match(requested, &candidates) else {
            return unmatched();
        };
        let candidate = &candidates[index];
        let Some(path) = candidate.path.clone() else {
            return unmatched();
        };
        let queue = crate::playback::QueueTrack {
            id: candidate.id.clone(),
            path,
            opener: None,
            duration: candidate.duration,
            sample_rate: candidate.sample_rate,
        };
        if player
            .play_queue(vec![queue], true, |_, _, _, _| {})
            .is_err()
        {
            return unmatched();
        }
        if !playing {
            player.pause(true);
        }
        seek_when_ready(player, &candidate.id, position);
        PlayOutcome {
            matched: true,
            title: candidate.title.clone(),
        }
    }
}

/// 等输出设备就绪后再 seek；播放器起流是异步的，这里最多等 5 秒。
fn seek_when_ready(player: &Arc<crate::playback::Player>, id: &str, position: f64) {
    let player = player.clone();
    let id = id.to_string();
    std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            let status = player.status();
            if status.current.as_deref() == Some(id.as_str()) {
                if status.state == "error" {
                    return;
                }
                if status.output_rate > 0 {
                    let _ = player.seek(position);
                    return;
                }
            }
            std::thread::sleep(Duration::from_millis(40));
        }
    });
}

fn handle_request(mut request: Request, shared: &Shared) {
    let path = request.url().split('?').next().unwrap_or("").to_string();
    if !matches!(request.method(), Method::Post) || path != "/handoff" {
        respond_json(request, 404, error_body("未找到"));
        return;
    }
    let content_type = request
        .headers()
        .iter()
        .find(|header| header.field.equiv("Content-Type"))
        .map(|header| header.value.as_str().to_string())
        .unwrap_or_default();
    if !content_type
        .to_ascii_lowercase()
        .starts_with("application/json")
    {
        shared.set_message("请求格式错误");
        respond_json(request, 400, error_body("请求格式错误"));
        return;
    }
    let body = match read_body(&mut request, MAX_BODY) {
        Ok(body) => body,
        Err(_) => {
            shared.set_message("请求格式错误");
            respond_json(request, 400, error_body("请求格式错误"));
            return;
        }
    };
    let parsed = match parse_request(&body) {
        Ok(parsed) => parsed,
        Err(_) => {
            shared.set_message("请求格式错误");
            respond_json(request, 400, error_body("请求格式错误"));
            return;
        }
    };
    let verdict = {
        let mut gate = shared
            .gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        gate.evaluate(Instant::now(), &parsed.code)
    };
    match verdict {
        Verdict::Expired => {
            shared.set_message("接收已过期（10 分钟无请求）");
            respond_json(request, 401, error_body("配对码错误"));
        }
        Verdict::TooSoon => {
            shared.set_message("请求过于频繁");
            respond_json(request, 429, error_body("请求过于频繁"));
        }
        Verdict::Wrong => {
            shared.set_message("配对码错误");
            respond_json(request, 401, error_body("配对码错误"));
        }
        Verdict::Rotated => {
            shared.set_message("尝试次数过多，配对码已更换");
            respond_json(request, 429, error_body("尝试次数过多，配对码已更换"));
        }
        Verdict::Accepted => {
            let outcome = shared.play(&parsed.track, parsed.position, parsed.playing);
            if let Some(app) = &shared.app {
                let _ = app.emit(
                    "handoff://received",
                    HandoffEvent {
                        title: outcome.title.clone(),
                        position: parsed.position,
                        matched: outcome.matched,
                    },
                );
            }
            if outcome.matched {
                shared.set_message(format!("已接力：{}", outcome.title));
                respond_json(
                    request,
                    200,
                    serde_json::json!({
                        "ok": true,
                        "matched": true,
                        "title": outcome.title,
                        "message": "已开始播放"
                    }),
                );
            } else {
                shared.set_message(format!("收到接力，但曲库里没有：{}", outcome.title));
                respond_json(request, 200, error_body("电脑曲库没有找到这首歌"));
            }
        }
    }
}

fn serve(shared: Arc<Shared>, server: Arc<Server>, mdns: Arc<ServiceDaemon>, id: u64) {
    loop {
        if shared.stopped.load(Ordering::Acquire) {
            break;
        }
        let expired = {
            let gate = shared
                .gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            gate.expired(Instant::now())
        };
        if expired {
            shared.set_message("接收已过期（10 分钟无请求）");
            break;
        }
        match server.recv_timeout(Duration::from_millis(300)) {
            Ok(Some(request)) => handle_request(request, &shared),
            Ok(None) => {}
            Err(_) => break,
        }
    }
    shared.stopped.store(true, Ordering::Release);
    let _ = mdns.shutdown();
    let mut slot = active_lock();
    if slot.as_ref().is_some_and(|active| active.id == id) {
        let _ = slot.take();
    }
}

struct Active {
    id: u64,
    shared: Arc<Shared>,
    server: Arc<Server>,
    mdns: Arc<ServiceDaemon>,
    thread: Option<std::thread::JoinHandle<()>>,
    name: String,
    port: u16,
}

static ACTIVE: Mutex<Option<Active>> = Mutex::new(None);
static LAST_MESSAGE: Mutex<String> = Mutex::new(String::new());
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static START_LOCK: Mutex<()> = Mutex::new(());

fn active_lock() -> MutexGuard<'static, Option<Active>> {
    ACTIVE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn set_last_message(text: &str) {
    *LAST_MESSAGE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = text.to_string();
}

/// 关掉当前会话：停线程、关端口、注销 mDNS。
fn stop_active() {
    let active = { active_lock().take() };
    let Some(mut active) = active else {
        return;
    };
    active.shared.stopped.store(true, Ordering::Release);
    active.server.unblock();
    let _ = active.mdns.shutdown();
    if let Some(thread) = active.thread.take() {
        let _ = thread.join();
    }
}

// ---------------------------------------------------------------------------
// 命令
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn handoff_start(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<HandoffSession, String> {
    let _start = START_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    stop_active();
    let name = host_name();
    let code = random_code();
    let listener = TcpListener::bind(("0.0.0.0", 0)).map_err(|_| "无法启动接收服务".to_string())?;
    let port = listener
        .local_addr()
        .map_err(|_| "无法启动接收服务".to_string())?
        .port();
    let server =
        Server::from_listener(listener, None).map_err(|_| "无法启动接收服务".to_string())?;
    let server = Arc::new(server);
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let shared = Arc::new(Shared {
        gate: Mutex::new(Gate::new(code.clone(), Instant::now())),
        app: Some(app),
        player: Some(state.player.clone()),
        library: Some(state.library.clone()),
        last_message: Mutex::new("等待手机连接".into()),
        stopped: AtomicBool::new(false),
    });

    let mdns = Arc::new(ServiceDaemon::new().map_err(|_| "无法启动 mDNS 广播".to_string())?);
    let label = mdns_label(&name);
    let host = format!("{label}.local.");
    let instance = format!("Awake-{label}");
    let properties: Vec<(&str, &str)> = vec![
        ("v", SERVICE_VERSION),
        ("name", name.as_str()),
        ("code_required", "1"),
        // v2：标记这是电脑接收端，手机发送者据此过滤。
        ("to", "desktop"),
    ];
    let service = ServiceInfo::new(
        SERVICE_TYPE,
        &instance,
        &host,
        (),
        port,
        properties.as_slice(),
    )
    .map_err(|_| "无法发布 mDNS 服务".to_string())?
    .enable_addr_auto();
    if mdns.register(service).is_err() {
        let _ = mdns.shutdown();
        return Err("无法发布 mDNS 服务".into());
    }

    let thread_shared = shared.clone();
    let thread_server = server.clone();
    let thread_mdns = mdns.clone();
    let thread = std::thread::Builder::new()
        .name("awake-handoff".into())
        .spawn(move || serve(thread_shared, thread_server, thread_mdns, id))
        .map_err(|_| "无法启动接收线程".to_string())?;
    *active_lock() = Some(Active {
        id,
        shared: shared.clone(),
        server: server.clone(),
        mdns: mdns.clone(),
        thread: Some(thread),
        name: name.clone(),
        port,
    });
    shared.set_message("等待手机连接");
    let url_hint = match local_ipv4() {
        Some(ip) => format!("http://{ip}:{port}"),
        None => format!("http://{host}:{port}"),
    };
    Ok(HandoffSession {
        code,
        port,
        name,
        url_hint,
    })
}

#[tauri::command]
pub async fn handoff_status(state: State<'_, AppState>) -> Result<HandoffStatus, String> {
    let _ = &state;
    let fallback_name = host_name();
    let slot = active_lock();
    match slot.as_ref() {
        Some(active) => {
            let code = {
                let gate = active
                    .shared
                    .gate
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                gate.code().to_string()
            };
            Ok(HandoffStatus {
                active: true,
                code,
                port: active.port,
                name: active.name.clone(),
                last_message: active.shared.message(),
            })
        }
        None => Ok(HandoffStatus {
            active: false,
            code: String::new(),
            port: 0,
            name: fallback_name,
            last_message: LAST_MESSAGE
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .clone(),
        }),
    }
}

#[tauri::command]
pub async fn handoff_stop(state: State<'_, AppState>) -> Result<(), String> {
    let _ = &state;
    stop_active();
    set_last_message("接收已停止");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use awake_core::models::{MediaSource, SourceKind};
    use std::io::Write;

    fn track(
        source_id: &str,
        locator: &str,
        title: &str,
        artist: &str,
        duration: f64,
    ) -> awake_core::Track {
        serde_json::from_value(serde_json::json!({
            "id": format!("{source_id}-{locator}"),
            "title": title,
            "artist": artist,
            "album_artist": artist,
            "album": "Parachutes",
            "genre": "rock",
            "year": 2000,
            "track_number": 1,
            "disc_number": 1,
            "duration": duration,
            "sample_rate": 44100,
            "bit_depth": 16,
            "channels": 2,
            "codec": "flac",
            "source_id": source_id,
            "locator": locator,
            "file_size": 1,
            "modified": 0,
            "artwork_path": null,
            "play_count": 0,
            "favorite": false,
            "last_played": null,
            "added_at": 0,
            "is_remote": false
        }))
        .unwrap()
    }

    fn candidate(
        id: &str,
        title: &str,
        artist: &str,
        album: &str,
        duration: f64,
        path: Option<PathBuf>,
    ) -> Candidate {
        Candidate {
            id: id.into(),
            title: title.into(),
            artist: artist.into(),
            album: album.into(),
            duration,
            path,
            sample_rate: 44100,
        }
    }

    #[test]
    fn gate_enforces_rate_limit_rotation_and_expiry() {
        let start = Instant::now();
        let mut gate = Gate::new("123456".into(), start);
        assert_eq!(gate.evaluate(start, "000000"), Verdict::Wrong);
        // 2 秒窗口内不再处理第二个请求
        assert_eq!(
            gate.evaluate(start + Duration::from_millis(1999), "123456"),
            Verdict::TooSoon
        );
        let mut now = start + Duration::from_millis(2000);
        assert_eq!(gate.evaluate(now, "123456"), Verdict::Accepted);
        assert_eq!(gate.wrong, 0, "配对成功后清零错误计数");

        // 连续错 4 次仍然是 401，第 5 次换码并返回 429
        let old_code = gate.code().to_string();
        for _ in 0..(MAX_WRONG - 1) {
            now += Duration::from_millis(2000);
            assert_eq!(gate.evaluate(now, "999999"), Verdict::Wrong);
        }
        now += Duration::from_millis(2000);
        assert_eq!(gate.evaluate(now, "999999"), Verdict::Rotated);
        assert_ne!(gate.code(), old_code, "第 5 次错码必须换新码");
        assert_eq!(gate.wrong, 0);

        now += Duration::from_millis(2000);
        let fresh = gate.code().to_string();
        assert_eq!(gate.evaluate(now, &fresh), Verdict::Accepted);

        // 10 分钟无请求后过期
        assert_eq!(
            gate.evaluate(now + Duration::from_secs(601), &fresh),
            Verdict::Expired
        );
        assert!(gate.expired(now + Duration::from_secs(601)));
    }

    #[test]
    fn request_parsing_validates_shape_and_bounds() {
        let valid = br#"{"code":"123456","track":{"title":"Yellow","artist":"Coldplay","album":"Parachutes","duration":225.0},"position":42.5,"playing":true}"#;
        let parsed = parse_request(valid).unwrap();
        assert_eq!(parsed.code, "123456");
        assert_eq!(parsed.position, 42.5);
        assert_eq!(parsed.track.title, "Yellow");
        assert!(parsed.playing);

        let minimal = br#"{"code":"123456","track":{"title":"Yellow","artist":"","album":"","duration":0.0},"position":0.0}"#;
        assert!(!parse_request(minimal).unwrap().playing);

        assert!(parse_request(b"not json").is_err());
        assert!(parse_request(br#"{"code":"","track":{"title":"x","artist":"","album":"","duration":1.0},"position":0.0}"#).is_err());
        assert!(parse_request(br#"{"code":"123456","track":{"title":"  ","artist":"","album":"","duration":1.0},"position":0.0}"#).is_err());
        assert!(parse_request(br#"{"code":"123456","track":{"title":"x","artist":"","album":"","duration":1.0},"position":-1.0}"#).is_err());
        assert!(parse_request(br#"{"code":"123456","track":{"title":"x","artist":"","album":"","duration":-1.0},"position":0.0}"#).is_err());
        assert!(parse_request(br#"{"code":"123456","track":{"title":"x","artist":"","album":"","duration":1.0},"position":999999.0}"#).is_err());
        let long_title = "a".repeat(MAX_TEXT_FIELD + 1);
        let long_body = format!(
            r#"{{"code":"123456","track":{{"title":"{long_title}","artist":"","album":"","duration":1.0}},"position":0.0}}"#
        );
        assert!(parse_request(long_body.as_bytes()).is_err());
    }

    #[test]
    fn matching_normalizes_and_prefers_local_files() {
        let dir = crate::test_audio::directory();
        let local = dir.join("yellow.flac");
        std::fs::write(&local, b"fixture").unwrap();
        let remote = candidate("remote", "Yellow", "Coldplay", "Parachutes", 266.0, None);
        let playable = candidate(
            "local",
            "Yellow (Live) [Remastered]",
            "Coldplay feat. Guest",
            "Parachutes",
            267.0,
            Some(local.clone()),
        );
        let other = candidate("other", "Fix You", "Coldplay", "X&Y", 295.0, None);
        let missing = candidate(
            "missing",
            "Yellow",
            "Coldplay",
            "Parachutes",
            266.0,
            Some(dir.join("does-not-exist.flac")),
        );
        let candidates = vec![remote, playable, other, missing];

        let query = HandoffTrack {
            title: "yellow".into(),
            artist: "coldplay".into(),
            album: String::new(),
            duration: 266.0,
        };
        let (index, score) = best_match(&query, &candidates).expect("normalized match");
        assert_eq!(candidates[index].id, "local", "优先本地可播放文件");
        assert!(score >= MATCH_THRESHOLD);

        // 时长差超过 ±5 秒直接淘汰
        let far = HandoffTrack {
            title: "Yellow".into(),
            artist: "Coldplay".into(),
            album: String::new(),
            duration: 400.0,
        };
        assert!(best_match(&far, &candidates).is_none());

        // 完全不同的歌不匹配
        let miss = HandoffTrack {
            title: "Bohemian Rhapsody".into(),
            artist: "Queen".into(),
            album: String::new(),
            duration: 266.0,
        };
        assert!(best_match(&miss, &candidates).is_none());

        // 没有可播放文件时视为未匹配
        let unplayable = vec![candidate(
            "remote",
            "Yellow",
            "Coldplay",
            "Parachutes",
            266.0,
            None,
        )];
        assert!(best_match(&query, &unplayable).is_none());

        assert_eq!(normalize("Yellow (Live) [Remastered]"), "yellow");
        assert_eq!(normalize("Coldplay feat. Someone"), "coldplay");
        assert_eq!(normalize("曲名（高清版）"), "曲名");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn candidates_expose_local_paths_only() {
        let dir = crate::test_audio::directory();
        let mut library = awake_core::Library::open(dir.join("library.json"));
        library
            .snapshot
            .sources
            .push(MediaSource::new(SourceKind::Local, "本地", "/music"));
        library.snapshot.sources.push(MediaSource::new(
            SourceKind::Plex,
            "Plex",
            "http://plex.local",
        ));
        library
            .snapshot
            .tracks
            .push(track("src-local", "a.flac", "A", "X", 200.0));
        library
            .snapshot
            .tracks
            .push(track("src-plex", "b.flac", "B", "Y", 200.0));
        let local_id = library.snapshot.sources[0].id.clone();
        let plex_id = library.snapshot.sources[1].id.clone();
        library.snapshot.tracks[0].source_id = local_id;
        library.snapshot.tracks[1].source_id = plex_id;
        let candidates = build_candidates(&library);
        assert_eq!(
            candidates[0].path,
            Some(PathBuf::from("/music").join("a.flac"))
        );
        assert!(candidates[1].path.is_none(), "远程来源没有本地文件路径");
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn test_shared(code: &str) -> Arc<Shared> {
        Arc::new(Shared {
            gate: Mutex::new(Gate::new(code.into(), Instant::now())),
            app: None,
            player: None,
            library: None,
            last_message: Mutex::new(String::new()),
            stopped: AtomicBool::new(false),
        })
    }

    fn build_request(method: &str, path: &str, content_type: Option<&str>, body: &str) -> String {
        let mut request = format!(
            "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: {}\r\n",
            body.len()
        );
        if let Some(value) = content_type {
            request.push_str(&format!("Content-Type: {value}\r\n"));
        }
        request.push_str("\r\n");
        request.push_str(body);
        request
    }

    fn http_request(port: u16, request: &str) -> String {
        let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        stream.write_all(request.as_bytes()).unwrap();
        let mut response = Vec::new();
        let _ = stream.read_to_end(&mut response);
        String::from_utf8_lossy(&response).to_string()
    }

    #[test]
    fn http_smoke_handles_routing_pairing_and_body_limit() {
        let server = Arc::new(Server::http("127.0.0.1:0").unwrap());
        let port = server.server_addr().to_ip().expect("tcp listener").port();
        let shared = test_shared("123456");
        let thread_shared = shared.clone();
        let thread_server = server.clone();
        let handler = std::thread::spawn(move || {
            for _ in 0..5 {
                match thread_server.recv_timeout(Duration::from_secs(5)) {
                    Ok(Some(request)) => handle_request(request, &thread_shared),
                    _ => break,
                }
            }
        });

        // 只接受 POST /handoff
        let not_found = http_request(port, &build_request("GET", "/handoff", None, ""));
        assert!(not_found.starts_with("HTTP/1.1 404"), "{not_found}");
        assert!(not_found.contains("\"ok\":false"), "{not_found}");

        // 错码 401，且错误信息不含内部细节
        let wrong = http_request(
            port,
            &build_request(
                "POST",
                "/handoff",
                Some("application/json"),
                r#"{"code":"000000","track":{"title":"Yellow","artist":"Coldplay","album":"Parachutes","duration":225.0},"position":42.5,"playing":true}"#,
            ),
        );
        assert!(wrong.starts_with("HTTP/1.1 401"), "{wrong}");
        assert!(wrong.contains("配对码错误"), "{wrong}");
        assert!(!wrong.contains("port"), "{wrong}");

        // 绕过 2 秒窗口后再用正确配对码：测试环境没有曲库，返回未匹配
        shared.gate.lock().unwrap().last_request = None;
        let accepted = http_request(
            port,
            &build_request(
                "POST",
                "/handoff",
                Some("application/json"),
                r#"{"code":"123456","track":{"title":"Yellow","artist":"Coldplay","album":"Parachutes","duration":225.0},"position":42.5,"playing":true}"#,
            ),
        );
        assert!(accepted.starts_with("HTTP/1.1 200"), "{accepted}");
        assert!(accepted.contains("\"matched\":false"), "{accepted}");
        assert!(accepted.contains("电脑曲库没有找到这首歌"), "{accepted}");
        assert!(shared.message().contains("收到接力，但曲库里没有：Yellow"));

        // 其他路径 404
        let other = http_request(
            port,
            &build_request("POST", "/other", Some("application/json"), "{}"),
        );
        assert!(other.starts_with("HTTP/1.1 404"), "{other}");

        // 非 JSON 或超过 8 KB 的请求体一律 400
        let big_body = "x".repeat(MAX_BODY + 10);
        let oversize = http_request(
            port,
            &build_request("POST", "/handoff", Some("application/json"), &big_body),
        );
        assert!(oversize.starts_with("HTTP/1.1 400"), "{oversize}");

        handler.join().unwrap();
    }
}
