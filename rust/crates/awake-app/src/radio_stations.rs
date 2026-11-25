//! 电台台站列表：发现服务器 → 拉目录 → 去重 → 按"我们自己的"可播性判定分组。
//!
//! 分工写死，避免又变成一坨：
//! - 解析/去重/缓存/判定全在 `awake_core::radio`（有测试，不联网）；
//! - 这里只做网络与磁盘：`reqwest` 拉 JSON、`ProbeCache` 读写、`curl` 起一次探测。
//!
//! **不猜编码**：列表里标"可播"必须有据——要么缓存里有新鲜探测结果，
//! 要么台站声明的编码落在 `codec_support` 的 Yes 里。其余一律写"未探测/未验证"。

use crate::AppState;
use awake_core::radio::{self, Playable, PlaybackPlan, ProbeCache, ProbeRecord};
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::time::Duration;
use tauri::State;

const CACHE_FILE: &str = "radio-probe-cache.json";
const SETTINGS_FILE: &str = "radio-settings.json";
/// 目录默认上限。用户要更多就自己调 limit——但一次一万条界面也吃不下。
const DEFAULT_LIMIT: usize = 120;

#[derive(Debug, Clone, Serialize)]
pub struct StationView {
    pub uuid: String,
    pub name: String,
    pub url: String,
    pub homepage: String,
    pub favicon: String,
    pub tags: Vec<String>,
    pub country: String,
    pub codec: String,
    pub bitrate: u32,
    pub votes: i64,
    pub clicks: i64,
    /// `yes` / `unverified` / `no`——来自 `codec_support`，不是台站自述。
    pub support: &'static str,
    /// 一句话结论，界面直接显示，不在这里拼第二遍。
    pub verdict: String,
    /// 现在点下去能不能出声（按开关与二进制算过）。
    pub can_play: bool,
    /// 卡在"没打开兜底"或"没装 ffmpeg"上时给界面一个可点的入口。
    pub needs_ffmpeg: bool,
    /// 缓存里那次探测的时间；0 表示没探过。
    pub probed_at_ms: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct StationList {
    pub server: String,
    pub fetched: usize,
    pub shown: usize,
    /// 编码明确解不了、被挡在列表外的条数。
    pub hidden: usize,
    pub stations: Vec<StationView>,
    /// 给人看的一句状态：用了哪台服务器、有没有退回默认。
    pub note: String,
}

#[derive(Debug, Deserialize)]
struct ServerEntry {
    #[serde(default)]
    name: String,
}

fn support_label(playable: Playable) -> &'static str {
    match playable {
        Playable::Yes => "yes",
        Playable::Unverified => "unverified",
        Playable::No => "no",
    }
}

fn cache_path(dir: &std::path::Path) -> std::path::PathBuf {
    dir.join(CACHE_FILE)
}

fn load_cache(dir: &std::path::Path) -> ProbeCache {
    std::fs::read_to_string(cache_path(dir))
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn save_cache(dir: &std::path::Path, cache: &ProbeCache) -> Result<(), String> {
    let path = cache_path(dir);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    let text = serde_json::to_string_pretty(cache).map_err(|error| error.to_string())?;
    let temp = path.with_extension("json.tmp");
    std::fs::write(&temp, text).map_err(|error| format!("写不了台站缓存：{error}"))?;
    std::fs::rename(&temp, &path).map_err(|error| format!("保存台站缓存失败：{error}"))
}

/// ffmpeg 兜底开关。与 `radio_settings` 读同一个文件、同一个字段——
/// 两处各读一份就会有一处落后，判定结果跟着不一致。
fn ffmpeg_enabled(dir: &std::path::Path) -> bool {
    std::fs::read_to_string(dir.join(SETTINGS_FILE))
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .and_then(|value| value.get("ffmpeg_fallback").and_then(|v| v.as_bool()))
        .unwrap_or(false)
}

fn client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .user_agent(radio::user_agent())
        .timeout(Duration::from_secs(12))
        .build()
        .map_err(|error| format!("建不了 HTTP 客户端：{error}"))
}

/// 按官方约定发现服务器：先问 `all.api.radio-browser.info` 要列表，失败就用固定的一台。
///
/// 不写死一堆域名：列表会变，写死的那个迟早失效，而失效时的报错会像是"网络坏了"。
fn resolve_server() -> (String, String) {
    let fallback = "https://de1.api.radio-browser.info".to_string();
    let probe = match client() {
        Ok(client) => client,
        Err(_) => return (fallback, "建不了客户端，用默认服务器".to_string()),
    };
    let url = format!("https://{}/json/servers", radio::discovery_host());
    let servers = probe
        .get(&url)
        .send()
        .and_then(|response| response.error_for_status())
        .and_then(|response| response.json::<Vec<ServerEntry>>());
    match servers {
        Ok(list) => {
            let name = list
                .iter()
                .map(|entry| entry.name.trim())
                .find(|name| !name.is_empty())
                .map(|name| format!("https://{name}"))
                .unwrap_or_else(|| fallback.clone());
            let note = if name == fallback {
                "服务器列表为空，用默认服务器".to_string()
            } else {
                format!("按官方服务器列表连到 {name}")
            };
            (name, note)
        }
        Err(error) => (fallback, format!("服务器列表取不到（{error}），用默认服务器")),
    }
}

fn verdict_for(
    plan: Option<&PlaybackPlan>,
    support: Playable,
    codec: &str,
) -> (String, bool, bool, i64) {
    match plan {
        Some(PlaybackPlan::Direct) => (
            format!("可播（探测为 {}）", if codec.is_empty() { "未知编码" } else { codec }),
            true,
            false,
            0,
        ),
        Some(PlaybackPlan::ViaFfmpeg) => ("可播（走 ffmpeg 兜底）".to_string(), true, false, 0),
        Some(PlaybackPlan::Blocked { reason, can_enable_ffmpeg }) => {
            (reason.clone(), false, *can_enable_ffmpeg, 0)
        }
        None => match support {
            Playable::Yes => (
                format!("未探测（声明 {}，解码器支持）", if codec.is_empty() { "未知" } else { codec }),
                true,
                false,
                0,
            ),
            Playable::Unverified => (
                format!("编码未验证（{}）", if codec.is_empty() { "未知" } else { codec }),
                true,
                false,
                0,
            ),
            Playable::No => (
                format!("解码器不支持（{}）", if codec.is_empty() { "未知" } else { codec }),
                false,
                false,
                0,
            ),
        },
    }
}

#[tauri::command]
pub fn list_radio_stations(
    query: Option<String>,
    limit: Option<usize>,
    state: State<'_, AppState>,
) -> Result<StationList, String> {
    let (server, note) = resolve_server();
    let client = client()?;
    let limit = limit.unwrap_or(DEFAULT_LIMIT).clamp(1, 500);
    let search = query.unwrap_or_default().trim().to_string();

    let mut url = format!(
        "{server}/json/stations/search?hidebroken=true&order=clickcount&reverse=true&limit={limit}"
    );
    if !search.is_empty() {
        url.push_str("&name=");
        url.push_str(&encode_component(&search));
    }
    // 直接拿文本再交给 core 解：core 的 parse_stations 是唯一入口，
    // 这里再用 serde 解一遍就会变成两套解析、两套默认值。
    let body = client
        .get(&url)
        .send()
        .and_then(|response| response.error_for_status())
        .and_then(|response| response.text())
        .map_err(|error| format!("拉台站目录失败（{server}）：{error}"))?;
    let raw = radio::parse_stations(&body).map_err(|error| format!("台站字段解析失败：{error}"))?;
    let fetched_count = raw.len();
    let deduped = radio::dedupe(raw);

    let now = awake_core::models::now_ms();
    let cache = load_cache(&state.data_dir);
    let enabled = ffmpeg_enabled(&state.data_dir);
    let present = awake_core::stream::ffmpeg_path().is_some();

    let mut stations = Vec::new();
    let mut hidden = 0usize;
    for station in &deduped {
        let support = radio::codec_support(&station.codec);
        if !radio::is_listable(station) {
            hidden += 1;
            continue;
        }
        let plan = cache.decide(station, now, enabled, present);
        let probed_at = cache
            .fresh(&radio::station_key(station), now)
            .map(|record| record.probed_at_ms)
            .unwrap_or(0);
        let (verdict, can_play, needs_ffmpeg, _) = verdict_for(plan.as_ref(), support, &station.codec);
        stations.push(StationView {
            uuid: station.uuid.clone(),
            name: station.name.clone(),
            url: station.url.clone(),
            homepage: station.homepage.clone(),
            favicon: station.favicon.clone(),
            tags: station.tags.clone(),
            country: station.country.clone(),
            codec: station.codec.clone(),
            bitrate: station.bitrate,
            votes: station.votes,
            clicks: station.click_count,
            support: support_label(support),
            verdict,
            can_play,
            needs_ffmpeg,
            probed_at_ms: probed_at,
        });
    }

    // 能放的排前面：用户打开这个页就是要听，不是要看清单。
    stations.sort_by(|a, b| {
        b.can_play
            .cmp(&a.can_play)
            .then_with(|| b.votes.cmp(&a.votes))
            .then_with(|| b.bitrate.cmp(&a.bitrate))
    });

    Ok(StationList {
        server,
        fetched: fetched_count,
        shown: stations.len(),
        hidden,
        stations,
        note,
    })
}

/// 极简 percent-encoding：只处理 `& = ? # % + 空格` 与非 ASCII。
/// 不引第三方库——这里只有搜索词一个入口，多一个依赖不值得。
fn encode_component(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// 让 `ChildStdout` 满足 `decode_summary` 要求的 `Sync`：加一层互斥。
struct LockedReader<R>(std::sync::Mutex<R>);

impl<R: Read> Read for LockedReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.0
            .lock()
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::Other, "读锁被污染"))?
            .read(buf)
    }
}

/// 真探一次：连上去解 4 秒，报编码/采样率/声道，并把结论写进缓存。
///
/// 失败时**不写缓存**——"这次没探成"和"这个编码不行"是两件事，
/// 写进缓存就再也分不开了，下次播放会拿旧结论挡住一个其实能播的台。
#[tauri::command]
pub async fn probe_radio_station(
    uuid: String,
    url: String,
    state: State<'_, AppState>,
) -> Result<ProbeRecord, String> {
    let data_dir = state.data_dir.clone();
    let label = url.split('?').next().unwrap_or(&url).to_string();
    let hint = ["mp3", "aac", "ogg", "opus", "flac"]
        .iter()
        .find(|ext| label.to_lowercase().ends_with(&format!(".{ext}")))
        .map(|ext| ext.to_string());

    // 闭包要 move，但下面写缓存还要用原 url：探的那份单独拿一个。
    let probe_url = url.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        let mut child = std::process::Command::new("curl")
            .args([
                "-sS",
                "--max-time",
                "14",
                "-A",
                &radio::user_agent(),
                &probe_url,
            ])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|error| format!("起不了 curl：{error}"))?;
        let stdout = child.stdout.take().ok_or_else(|| "curl 没有输出".to_string())?;
        let decoded = awake_core::stream::decode_summary(
            LockedReader(std::sync::Mutex::new(stdout)),
            hint.as_deref(),
            4.0,
        );
        child.kill().ok();
        child.wait().ok();
        decoded.map_err(|error| format!("探测失败：{error}"))
    })
    .await
    .map_err(|_| "探测线程失败".to_string())??;

    let record = ProbeRecord::from_probe(
        &result.format.codec,
        result.format.sample_rate,
        result.format.channels,
        awake_core::models::now_ms(),
    );
    let mut cache = load_cache(&data_dir);
    cache.record(radio::key_for(&uuid, &url), record.clone());
    save_cache(&data_dir, &cache)?;
    Ok(record)
}
