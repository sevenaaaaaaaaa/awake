//! 电脑 → 手机播放接力。协议见 docs/handoff-protocol.md（v2）。
//!
//! 电脑只做发送端：浏览 `_awake._tcp` 里手机接收端（实例名 `AwakePhone-…`、TXT `to=phone`），
//! 用户输入手机上显示的 6 位配对码后 `POST /handoff`。不监听端口、不做广播，
//! 也不保存配对码、凭据或任何账号信息。
use crate::AppState;
use mdns_sd::{ServiceDaemon, ServiceEvent};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::{Duration, Instant};
use tauri::State;

const SERVICE_TYPE: &str = "_awake._tcp.local.";
/// 手机接收端的实例名前缀，与 iOS 端一致。
const PHONE_PREFIX: &str = "AwakePhone-";
/// 浏览时长：够拿到地址与端口，又不至于让用户等太久。
const SCAN_WINDOW: Duration = Duration::from_millis(2500);
/// 发送超时，与手机端发送者一致。
const SEND_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_CODE_LEN: usize = 6;
const MAX_TEXT_FIELD: usize = 200;
const MAX_POSITION: f64 = 24.0 * 3600.0;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PhoneDevice {
    /// Bonjour 实例名，例如 `AwakePhone-张三的-iPhone`。
    pub name: String,
    pub host: String,
    pub port: u16,
    /// 形如 `192.168.1.8:8737`，用于手动输入兜底与界面展示。
    pub address: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PhoneHandoffResult {
    pub ok: bool,
    pub matched: bool,
    pub title: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct TrackPayload {
    title: String,
    artist: String,
    album: String,
    duration: f64,
}

#[derive(Debug, Clone, Serialize)]
struct HandoffPayload {
    code: String,
    track: TrackPayload,
    position: f64,
    playing: bool,
}

/// 手机回的响应体。
#[derive(Debug, Clone, Deserialize, Default)]
struct PhoneReply {
    ok: Option<bool>,
    matched: Option<bool>,
    title: Option<String>,
    error: Option<String>,
    message: Option<String>,
}

/// 当前曲目：从播放器与曲库里取，供发送使用。
#[derive(Debug, Clone, PartialEq)]
struct CurrentTrack {
    id: String,
    title: String,
    artist: String,
    album: String,
    duration: f64,
    position: f64,
    playing: bool,
}

fn sanitize_code(code: &str) -> String {
    code.chars()
        .filter(|c| c.is_ascii_digit())
        .take(MAX_CODE_LEN)
        .collect()
}

fn clip(text: &str) -> String {
    text.trim().chars().take(MAX_TEXT_FIELD).collect()
}

/// 是不是手机接收端：实例名前缀优先，其次看 TXT 的 `to=phone`。
fn is_phone_service(instance: &str, txt: &HashMap<String, String>) -> bool {
    let tx = txt
        .get("to")
        .map(|value| value.eq_ignore_ascii_case("phone"))
        .unwrap_or(false);
    instance.starts_with(PHONE_PREFIX) || tx
}

fn build_device(instance: &str, host: String, port: u16) -> PhoneDevice {
    let label = instance
        .strip_prefix(PHONE_PREFIX)
        .unwrap_or(instance)
        .to_string();
    let address = if host.contains(':') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    };
    PhoneDevice {
        name: label,
        host,
        port,
        address,
    }
}

fn build_payload(
    code: &str,
    track: &CurrentTrack,
    position: f64,
    playing: bool,
) -> HandoffPayload {
    HandoffPayload {
        code: sanitize_code(code),
        track: TrackPayload {
            title: clip(&track.title),
            artist: clip(&track.artist),
            album: clip(&track.album),
            duration: if track.duration.is_finite() {
                track.duration.max(0.0)
            } else {
                0.0
            },
        },
        position: if position.is_finite() {
            position.clamp(0.0, MAX_POSITION)
        } else {
            0.0
        },
        playing,
    }
}

/// 把手机回的响应翻译成可展示的结果；失败信息不含路径或网络细节。
fn read_reply(status: u16, body: &str, device: &str) -> PhoneHandoffResult {
    let reply: PhoneReply = serde_json::from_str(body).unwrap_or_default();
    let ok = reply.ok.unwrap_or(false);
    let matched = reply.matched.unwrap_or(false);
    let title = reply.title.unwrap_or_default().trim().to_string();
    let error = reply.error.unwrap_or_default().trim().to_string();
    let message = reply.message.unwrap_or_default().trim().to_string();
    let name = if device.trim().is_empty() {
        "手机"
    } else {
        device.trim()
    };
    let (success, text) = match status {
        200 if ok && matched => (true, format!("已接力到 {name}")),
        200 => (
            false,
            if !error.is_empty() {
                error
            } else if !message.is_empty() {
                message
            } else {
                "手机曲库没有找到这首歌".to_string()
            },
        ),
        401 => (false, "配对码不对，请再确认手机上显示的 6 位数字".into()),
        429 => (false, "尝试次数太多，请等手机换一组配对码后再试".into()),
        400 => (
            false,
            if error.is_empty() {
                "手机没看懂这次请求，请再试一次".into()
            } else {
                error
            },
        ),
        other => (false, format!("手机返回了意外的状态（{other}），请再试一次")),
    };
    PhoneHandoffResult {
        ok: success,
        matched,
        title,
        text,
    }
}

/// 浏览局域网内的手机接收端。阻塞到浏览窗口结束，调用方负责放到后台线程。
fn scan_blocking() -> Result<Vec<PhoneDevice>, String> {
    let daemon = ServiceDaemon::new().map_err(|_| "无法启动局域网发现".to_string())?;
    let receiver = daemon
        .browse(SERVICE_TYPE)
        .map_err(|_| "无法启动局域网发现".to_string())?;
    let deadline = Instant::now() + SCAN_WINDOW;
    let mut found: Vec<PhoneDevice> = Vec::new();
    let mut seen: HashMap<String, ()> = HashMap::new();
    while Instant::now() < deadline {
        let wait = deadline.saturating_duration_since(Instant::now());
        match receiver.recv_timeout(wait) {
            Ok(ServiceEvent::ServiceResolved(info)) => {
                let txt: HashMap<String, String> = info
                    .get_properties()
                    .iter()
                    .map(|property| {
                        (
                            property.key().to_ascii_lowercase(),
                            property.val_str().to_string(),
                        )
                    })
                    .collect();
                let instance = info
                    .get_fullname()
                    .split('.')
                    .next()
                    .unwrap_or_default()
                    .to_string();
                if !is_phone_service(&instance, &txt) {
                    continue;
                }
                let host = info
                    .get_addresses()
                    .iter()
                    .find(|address| address.is_ipv4())
                    .or_else(|| info.get_addresses().iter().next())
                    .map(|address| address.to_string());
                let Some(host) = host else { continue };
                let device = build_device(&instance, host, info.get_port());
                let key = format!("{}:{}", device.host, device.port);
                if seen.insert(key, ()).is_none() {
                    found.push(device);
                }
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    let _ = daemon.shutdown();
    found.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(found)
}

pub fn scan_phones() -> Result<Vec<PhoneDevice>, String> {
    scan_blocking()
}

/// 发送一次接力请求；不重试、不保存配对码。
fn send_blocking(
    device: &PhoneDevice,
    payload: &HandoffPayload,
) -> Result<PhoneHandoffResult, String> {
    let scheme = "http";
    let host = if device.host.contains(':') {
        format!("[{}]", device.host)
    } else {
        device.host.clone()
    };
    let url = format!("{scheme}://{host}:{}/handoff", device.port);
    let body = serde_json::to_string(payload).map_err(|_| "无法生成接力请求".to_string())?;
    if body.len() > 8 * 1024 {
        return Err("曲目信息过长，无法接力".into());
    }
    let client = reqwest::blocking::Client::builder()
        .timeout(SEND_TIMEOUT)
        .build()
        .map_err(|_| "无法启动接力请求".to_string())?;
    let response = client
        .post(&url)
        .header("Content-Type", "application/json")
        .header("Accept", "application/json")
        .body(body)
        .send()
        .map_err(|_| format!("连不上 {}，请确认手机点过「接收接力」且在同一 Wi-Fi", device.name))?;
    let status = response.status().as_u16();
    let text = response.text().unwrap_or_default();
    Ok(read_reply(status, &text, &device.name))
}

fn current_track(state: &AppState) -> Option<CurrentTrack> {
    let status = state.player.status();
    let id = status.current.clone()?;
    let library = state.library.lock();
    let track = library.snapshot.tracks.iter().find(|track| track.id == id)?;
    Some(CurrentTrack {
        id: track.id.clone(),
        title: track.title.clone(),
        artist: track.artist.clone(),
        album: track.album.clone(),
        duration: track.duration,
        position: status.position.max(0.0),
        playing: status.state == "playing",
    })
}

/// 列出局域网内正在等待接力的手机。
#[tauri::command]
pub async fn handoff_scan_phones() -> Result<Vec<PhoneDevice>, String> {
    tauri::async_runtime::spawn_blocking(scan_phones)
        .await
        .map_err(|_| "无法扫描手机".to_string())?
}

/// 把当前曲目与进度接力到指定手机。code 由用户在界面上输入。
#[tauri::command]
pub async fn handoff_send_to_phone(
    state: State<'_, AppState>,
    host: String,
    port: u16,
    name: String,
    code: String,
) -> Result<PhoneHandoffResult, String> {
    let clean = sanitize_code(&code);
    if clean.len() != MAX_CODE_LEN {
        return Err("配对码是手机上显示的 6 位数字".into());
    }
    if host.trim().is_empty() || port == 0 {
        return Err("这个地址不可用，请重新选择手机或手动输入 IP:端口".into());
    }
    let Some(track) = current_track(&state) else {
        return Err("当前没有正在播放的曲目，先播放一首再接力".into());
    };
    let payload = build_payload(&clean, &track, track.position, track.playing);
    let instance = format!("{PHONE_PREFIX}{name}");
    let device = build_device(&instance, host.trim().to_string(), port);
    tauri::async_runtime::spawn_blocking(move || send_blocking(&device, &payload))
        .await
        .map_err(|_| "无法发送接力请求".to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track() -> CurrentTrack {
        CurrentTrack {
            id: "t1".into(),
            title: "晴天".into(),
            artist: "周杰伦".into(),
            album: "叶惠美".into(),
            duration: 269.5,
            position: 42.5,
            playing: true,
        }
    }

    #[test]
    fn code_is_digits_only_and_six_long() {
        assert_eq!(sanitize_code(" 12-34 56 "), "123456");
        assert_eq!(sanitize_code("1234567"), "123456");
        assert_eq!(sanitize_code("abc"), "");
    }

    #[test]
    fn phone_service_detected_by_prefix_or_txt() {
        let empty = HashMap::new();
        assert!(is_phone_service("AwakePhone-阿七的-iPhone", &empty));
        assert!(!is_phone_service("Awake-Mac", &empty));
        let mut txt = HashMap::new();
        txt.insert("to".to_string(), "phone".to_string());
        assert!(is_phone_service("Awake-Mac", &txt));
        let mut desktop = HashMap::new();
        desktop.insert("to".to_string(), "desktop".to_string());
        assert!(!is_phone_service("Awake-Mac", &desktop));
    }

    #[test]
    fn device_strips_prefix_and_formats_address() {
        let device = build_device("AwakePhone-阿七的-iPhone", "192.168.1.8".into(), 8737);
        assert_eq!(device.name, "阿七的-iPhone");
        assert_eq!(device.address, "192.168.1.8:8737");
        let v6 = build_device("AwakePhone-x", "fe80::1".into(), 9);
        assert_eq!(v6.address, "[fe80::1]:9");
    }

    #[test]
    fn payload_matches_protocol_and_has_no_private_fields() {
        let payload = build_payload("12 34 56", &track(), 42.5, true);
        let text = serde_json::to_string(&payload).unwrap();
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["code"], "123456");
        assert_eq!(value["position"], 42.5);
        assert_eq!(value["playing"], true);
        assert_eq!(value["track"]["title"], "晴天");
        assert_eq!(value["track"]["duration"], 269.5);
        let lower = text.to_lowercase();
        for banned in ["path", "token", "password", "secret", "account", "audio"] {
            assert!(!lower.contains(banned), "请求体不应包含 {banned}");
        }
        assert!(text.len() <= 8 * 1024);
    }

    #[test]
    fn payload_clamps_bad_position() {
        let payload = build_payload("123456", &track(), f64::NAN, false);
        assert_eq!(payload.position, 0.0);
        let payload = build_payload("123456", &track(), 1e9, true);
        assert_eq!(payload.position, MAX_POSITION);
    }

    #[test]
    fn reply_translation_covers_every_status() {
        let ok = read_reply(200, r#"{"ok":true,"matched":true,"title":"晴天"}"#, "iPhone");
        assert!(ok.ok && ok.matched);
        assert_eq!(ok.title, "晴天");
        assert_eq!(ok.text, "已接力到 iPhone");

        let unmatched = read_reply(200, r#"{"ok":false,"matched":false,"error":"手机曲库没有找到这首歌"}"#, "iPhone");
        assert!(!unmatched.ok);
        assert_eq!(unmatched.text, "手机曲库没有找到这首歌");

        assert_eq!(read_reply(401, "{}", "iPhone").text, "配对码不对，请再确认手机上显示的 6 位数字");
        assert!(read_reply(429, "{}", "iPhone").text.contains("尝试次数太多"));
        assert_eq!(read_reply(400, r#"{"error":"请求格式错误"}"#, "iPhone").text, "请求格式错误");
        assert!(read_reply(500, "", "iPhone").text.contains("500"));
    }

    /// 真发一次 HTTP：用本地 tiny_http 假手机验证路径、请求体与响应解析。
    #[test]
    fn send_posts_protocol_to_phone_and_reads_reply() {
        use std::io::Read;

        let server = tiny_http::Server::http("127.0.0.1:0").expect("启动假手机");
        let port = server
            .server_addr()
            .to_ip()
            .expect("本地端口")
            .port();
        let handle = std::thread::spawn(move || {
            let mut request = server.recv().expect("收到请求");
            let path = request.url().to_string();
            let mut body = String::new();
            request.as_reader().read_to_string(&mut body).expect("读请求体");
            let header: tiny_http::Header = "Content-Type: application/json".parse().unwrap();
            let response = tiny_http::Response::from_string(
                r#"{"ok":true,"matched":true,"title":"晴天","message":"已开始播放"}"#,
            )
            .with_status_code(200)
            .with_header(header);
            request.respond(response).expect("回响应");
            (path, body)
        });

        let device = build_device("AwakePhone-iPhone", "127.0.0.1".into(), port);
        let payload = build_payload("123456", &track(), 42.5, true);
        let result = send_blocking(&device, &payload).expect("发送");
        let (path, body) = handle.join().expect("假手机线程");

        assert_eq!(path, "/handoff");
        let sent: serde_json::Value = serde_json::from_str(&body).expect("请求体是 JSON");
        assert_eq!(sent["code"], "123456");
        assert_eq!(sent["track"]["title"], "晴天");
        assert_eq!(sent["position"], 42.5);
        assert!(result.ok && result.matched);
        assert_eq!(result.text, "已接力到 iPhone");
    }

    #[test]
    fn reply_without_device_name_uses_generic_label() {
        let ok = read_reply(200, r#"{"ok":true,"matched":true,"title":"x"}"#, "  ");
        assert_eq!(ok.text, "已接力到 手机");
    }
}
