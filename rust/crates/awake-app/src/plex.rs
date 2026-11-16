//! Plex 账号登录（PIN 授权）、服务器发现与音乐库列表。
//!
//! 只使用 Plex 官方公开接口。账号 Token 只放进请求头，不拼进 URL、日志或错误信息。
//!
//! 账号登录是**持久化**的：PIN 授权拿到的 Token 立刻写进凭据存储（vault），
//! 服务器地址与所选音乐库写进 `plex-account.json`。下次启动不用再点一次
//! 「用 Plex 账号登录」，打开「音乐来源」就能看到上次连的服务器和音乐库。
use reqwest::{
    blocking::{Client, RequestBuilder, Response},
    header, Url,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    io::Read,
    path::{Path, PathBuf},
    time::Duration,
};

use crate::vault;

const PLEX_TV: &str = "https://plex.tv";
const PRODUCT: &str = "Awake";
const MAX_BODY: usize = 1024 * 1024;
/// 账号 Token 在凭据存储里的键名（不是来源的 password_key）。
const ACCOUNT_KEY: &str = "plex.account";
const ACCOUNT_FILE: &str = "plex-account.json";

#[derive(Debug, Serialize)]
pub struct PlexPin {
    pub id: u64,
    pub code: String,
    pub auth_token: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PlexServer {
    pub name: String,
    pub client_identifier: String,
    pub url: String,
    pub token: String,
    pub local: bool,
    pub relay: bool,
    /// 线路说明（本地 / 远程 / 中继 + HTTPS），方便在连不上时换一条。
    pub connection: String,
}

#[derive(Debug, Serialize)]
pub struct PlexSection {
    pub key: String,
    pub title: String,
}

fn client(timeout: Duration) -> Result<Client, String> {
    Client::builder()
        .connect_timeout(Duration::from_secs(8))
        .timeout(timeout)
        .build()
        .map_err(|_| "无法初始化 Plex 网络客户端".to_string())
}

fn validate_client_id(client_id: &str) -> Result<(), String> {
    let valid = (8..=128).contains(&client_id.len())
        && client_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if valid {
        Ok(())
    } else {
        Err("Plex 客户端标识无效，请重新开始登录".into())
    }
}

fn validate_token(token: &str) -> Result<(), String> {
    let token = token.trim();
    if token.is_empty() || token.len() > 512 || token.chars().any(char::is_control) {
        return Err("Plex Token 无效，请重新登录 Plex 账号".into());
    }
    Ok(())
}

fn plex_headers(request: RequestBuilder, client_id: &str) -> RequestBuilder {
    request
        .header("X-Plex-Client-Identifier", client_id)
        .header("X-Plex-Product", PRODUCT)
        .header(header::ACCEPT, "application/json")
}

fn plex_network_error(error: reqwest::Error) -> String {
    if error.is_timeout() {
        "连接 Plex 超时：请检查网络后重试".into()
    } else if error.is_connect() {
        "无法连接 Plex：请检查网络或代理设置".into()
    } else {
        "Plex 请求失败，请稍后重试".into()
    }
}

fn plex_status_error(status: u16) -> String {
    match status {
        401 => "Plex 返回 HTTP 401：账号授权已失效，请重新登录 Plex 账号".into(),
        403 => "Plex 返回 HTTP 403：该账号没有访问权限".into(),
        404 => "Plex 返回 HTTP 404：服务器地址或登录码已失效，请重试".into(),
        429 => "Plex 请求过于频繁，请稍后再试（HTTP 429）".into(),
        500..=599 => format!("Plex 服务器暂时不可用（HTTP {status}），请稍后重试"),
        other => format!("Plex 返回 HTTP {other}，请稍后重试"),
    }
}

fn read_body(response: Response) -> Result<String, String> {
    let status = response.status();
    let mut body = String::new();
    response
        .take(MAX_BODY as u64 + 1)
        .read_to_string(&mut body)
        .map_err(|_| "读取 Plex 响应失败，请检查网络".to_string())?;
    if body.len() > MAX_BODY {
        return Err("Plex 响应过大，已停止读取".into());
    }
    if !status.is_success() {
        return Err(plex_status_error(status.as_u16()));
    }
    Ok(body)
}

fn parse_json(body: &str, what: &str) -> Result<Value, String> {
    if body.trim_start().starts_with('<') {
        return Err(format!(
            "{what}返回了 HTML 页面而不是 JSON：请确认服务器地址与 Token（地址可能指向了登录页）"
        ));
    }
    serde_json::from_str(body).map_err(|_| format!("{what}返回的 JSON 格式无效"))
}

#[tauri::command]
pub async fn plex_pin_create(client_id: String) -> Result<PlexPin, String> {
    validate_client_id(&client_id)?;
    tauri::async_runtime::spawn_blocking(move || create_pin(&client_id))
        .await
        .map_err(|_| "Plex 登录任务中断，请重试".to_string())?
}

fn create_pin(client_id: &str) -> Result<PlexPin, String> {
    let response = plex_headers(
        client(Duration::from_secs(8))?.post(format!("{PLEX_TV}/api/v2/pins?strong=true")),
        client_id,
    )
    .send()
    .map_err(plex_network_error)?;
    let value = parse_json(&read_body(response)?, "创建 Plex 登录码时")?;
    Ok(PlexPin {
        id: value["id"].as_u64().ok_or("Plex 登录码缺少 id，请重试")?,
        code: value["code"]
            .as_str()
            .filter(|code| !code.is_empty())
            .ok_or("Plex 登录码缺少 code，请重试")?
            .to_string(),
        auth_token: value["authToken"]
            .as_str()
            .filter(|token| !token.is_empty())
            .map(str::to_string),
    })
}

#[tauri::command]
pub async fn plex_pin_poll(
    client_id: String,
    id: u64,
    code: Option<String>,
) -> Result<PlexPin, String> {
    validate_client_id(&client_id)?;
    if id == 0 {
        return Err("Plex 登录码无效，请重新开始登录".into());
    }
    if let Some(code) = &code {
        if code.is_empty() || code.len() > 32 || !code.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Err("Plex 登录码无效，请重新开始登录".into());
        }
    }
    tauri::async_runtime::spawn_blocking(move || poll_pin(&client_id, id, code.as_deref()))
        .await
        .map_err(|_| "Plex 登录任务中断，请重试".to_string())?
}

fn poll_pin(client_id: &str, id: u64, code: Option<&str>) -> Result<PlexPin, String> {
    let mut url = Url::parse(&format!("{PLEX_TV}/api/v2/pins/{id}"))
        .map_err(|_| "Plex 登录码无效，请重新开始登录".to_string())?;
    if let Some(code) = code {
        url.query_pairs_mut().append_pair("code", code);
    }
    let response = plex_headers(client(Duration::from_secs(8))?.get(url), client_id)
        .send()
        .map_err(plex_network_error)?;
    let value = parse_json(&read_body(response)?, "查询 Plex 登录状态时")?;
    Ok(PlexPin {
        id: value["id"].as_u64().unwrap_or(id),
        code: value["code"]
            .as_str()
            .or(code)
            .unwrap_or_default()
            .to_string(),
        auth_token: value["authToken"]
            .as_str()
            .filter(|token| !token.is_empty())
            .map(str::to_string),
    })
}

/// 让用户在浏览器完成 Plex 账号授权。只允许打开 Plex 官方的 https 授权页。
#[tauri::command]
pub async fn plex_open_auth(client_id: String, code: String) -> Result<(), String> {
    validate_client_id(&client_id)?;
    if code.is_empty() || code.len() > 32 || !code.chars().all(|c| c.is_ascii_alphanumeric()) {
        return Err("Plex 登录码无效，请重新开始登录".into());
    }
    let url = format!(
        "https://app.plex.tv/auth#?clientID={client_id}&code={code}&context%5Bdevice%5D%5Bproduct%5D=Awake"
    );
    crate::telegram::open_telegram_link(url).await
}

#[tauri::command]
pub async fn plex_resources(client_id: String, token: String) -> Result<Vec<PlexServer>, String> {
    validate_client_id(&client_id)?;
    validate_token(&token)?;
    tauri::async_runtime::spawn_blocking(move || resources(&client_id, &token))
        .await
        .map_err(|_| "Plex 服务器查询中断，请重试".to_string())?
}

fn resources(client_id: &str, token: &str) -> Result<Vec<PlexServer>, String> {
    let response = plex_headers(
        client(Duration::from_secs(25))?.get(format!(
            "{PLEX_TV}/api/v2/resources?includeHttps=1&includeRelay=1"
        )),
        client_id,
    )
    .header("X-Plex-Token", token)
    .send()
    .map_err(plex_network_error)?;
    let value = parse_json(&read_body(response)?, "读取 Plex 服务器列表时")?;
    Ok(parse_resources(&value, token))
}

struct PlexConnection {
    url: String,
    local: bool,
    relay: bool,
    https: bool,
}

fn provides_server(value: &Value) -> bool {
    let contains = |text: &str| text.split(',').any(|part| part.trim() == "server");
    match value {
        Value::String(text) => contains(text),
        Value::Array(items) => items.iter().any(|item| item.as_str().is_some_and(contains)),
        _ => false,
    }
}

/// 解析全部可用线路（本地 / 远程 / 中继、HTTP / HTTPS）。
///
/// 只保留 http(s) 且不含账号信息的连接；按 https → 本地 → 非中继排序，
/// 第一条即默认线路。保留多条是为了在某条线路（例如 plex.direct）不可达时能换线。
fn parse_resources(value: &Value, account_token: &str) -> Vec<PlexServer> {
    let servers = collect_resources(value, account_token, true);
    if servers.is_empty() {
        // 某些 Plex 版本对共享服务器的 provides 标注不完整；保底再尝试一次。
        return collect_resources(value, account_token, false);
    }
    servers
}

fn collect_resources(value: &Value, account_token: &str, require_server: bool) -> Vec<PlexServer> {
    let Some(items) = value.as_array() else {
        return Vec::new();
    };
    let mut servers = Vec::new();
    for item in items {
        if require_server && !provides_server(&item["provides"]) {
            continue;
        }
        let Some(connections) = item["connections"].as_array() else {
            continue;
        };
        let mut candidates: Vec<PlexConnection> = connections
            .iter()
            .filter_map(|connection| {
                let uri = connection["uri"].as_str()?;
                let parsed = Url::parse(uri).ok()?;
                if !matches!(parsed.scheme(), "http" | "https")
                    || parsed.host_str().is_none()
                    || !parsed.username().is_empty()
                    || parsed.password().is_some()
                {
                    return None;
                }
                Some(PlexConnection {
                    url: uri.to_string(),
                    local: connection["local"].as_bool().unwrap_or(false),
                    relay: connection["relay"].as_bool().unwrap_or(false),
                    https: parsed.scheme() == "https",
                })
            })
            .collect();
        candidates.sort_by_key(|connection| (!connection.https, !connection.local, connection.relay));
        let token = item["accessToken"]
            .as_str()
            .filter(|token| !token.is_empty())
            .unwrap_or(account_token);
        for connection in candidates {
            let label = if connection.relay {
                "中继"
            } else if connection.local {
                "本地"
            } else {
                "远程"
            };
            servers.push(PlexServer {
                name: item["name"].as_str().unwrap_or("Plex 服务器").to_string(),
                client_identifier: item["clientIdentifier"]
                    .as_str()
                    .unwrap_or("")
                    .to_string(),
                url: connection.url.trim_end_matches('/').to_string(),
                token: token.to_string(),
                local: connection.local,
                relay: connection.relay,
                connection: format!(
                    "{label} · {}",
                    if connection.https { "HTTPS" } else { "HTTP" }
                ),
            });
        }
    }
    // 稳定排序：同名的多条线路保持 https → 本地 → 非中继 的优先顺序。
    servers.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    servers.dedup_by(|a, b| a.url == b.url);
    servers
}

#[tauri::command]
pub async fn plex_probe(url: String, token: String) -> Result<bool, String> {
    validate_token(&token)?;
    let base = validate_server_url(&url)?;
    tauri::async_runtime::spawn_blocking(move || probe(&token, &base))
        .await
        .map_err(|_| "Plex 连通性检查中断".to_string())?
}

fn probe(token: &str, base: &str) -> Result<bool, String> {
    let response = client(Duration::from_secs(6))?
        .get(format!("{base}/identity"))
        .header("X-Plex-Token", token)
        .header(header::ACCEPT, "application/json")
        .send()
        .map_err(|_| "这条线路连不上 Plex 服务器".to_string())?;
    Ok(response.status().is_success())
}

#[tauri::command]
pub async fn plex_sections(token: String, url: String) -> Result<Vec<PlexSection>, String> {
    validate_token(&token)?;
    let base = validate_server_url(&url)?;
    tauri::async_runtime::spawn_blocking(move || sections(&token, &base))
        .await
        .map_err(|_| "Plex 音乐库查询中断，请重试".to_string())?
}

fn validate_server_url(url: &str) -> Result<String, String> {
    let parsed = Url::parse(url.trim()).map_err(|_| "Plex 服务器地址无效".to_string())?;
    if !matches!(parsed.scheme(), "http" | "https")
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err("Plex 服务器地址无效：请只填写 http(s) 地址".into());
    }
    Ok(url.trim().trim_end_matches('/').to_string())
}

fn sections(token: &str, base: &str) -> Result<Vec<PlexSection>, String> {
    let response = client(Duration::from_secs(25))?
        .get(format!("{base}/library/sections"))
        .header("X-Plex-Token", token)
        .header("X-Plex-Product", PRODUCT)
        .header(header::ACCEPT, "application/json")
        .send()
        .map_err(plex_network_error)?;
    let value = parse_json(&read_body(response)?, "读取 Plex 音乐库时")?;
    Ok(parse_sections(&value))
}

fn parse_sections(value: &Value) -> Vec<PlexSection> {
    value["MediaContainer"]["Directory"]
        .as_array()
        .map(|directories| {
            directories
                .iter()
                .filter(|directory| matches!(directory["type"].as_str(), Some("artist") | Some("music")))
                .filter_map(|directory| {
                    let key = directory["key"].as_str().filter(|key| !key.is_empty())?;
                    Some(PlexSection {
                        key: key.to_string(),
                        title: directory["title"].as_str().unwrap_or("音乐库").to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}


// ---------------------------------------------------------------------------
// 账号记忆：PIN 授权一次，之后每次启动都还能看到服务器与音乐库
// ---------------------------------------------------------------------------

/// 已记住的 Plex 账号定位信息。Token 不在这个文件里，它在凭据存储（vault）里。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct PlexAccountFile {
    #[serde(default)]
    client_id: String,
    #[serde(default)]
    server_url: String,
    #[serde(default)]
    server_name: String,
    #[serde(default)]
    section_key: String,
    #[serde(default)]
    section_title: String,
    #[serde(default)]
    saved_at: i64,
}

/// 前端拿到的账号状态。token 用来直接列出服务器，和 plex_resources 的敏感级别一致。
#[derive(Debug, Serialize)]
pub struct PlexAccountView {
    pub signed_in: bool,
    pub client_id: String,
    pub token: String,
    pub server_url: String,
    pub server_name: String,
    pub section_key: String,
    pub section_title: String,
    pub saved_at: i64,
}

fn account_path(data_dir: &Path) -> PathBuf {
    data_dir.join(ACCOUNT_FILE)
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn load_account(data_dir: &Path) -> PlexAccountFile {
    std::fs::read_to_string(account_path(data_dir))
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn write_account(data_dir: &Path, file: &PlexAccountFile) -> Result<(), String> {
    std::fs::create_dir_all(data_dir).map_err(|_| "无法创建数据目录".to_string())?;
    let path = account_path(data_dir);
    let tmp = path.with_extension("json.tmp");
    let json = serde_json::to_string_pretty(file)
        .map_err(|_| "Plex 账号状态序列化失败".to_string())?;
    std::fs::write(&tmp, json).map_err(|_| "无法写入 Plex 账号状态".to_string())?;
    std::fs::rename(&tmp, &path).map_err(|_| "无法保存 Plex 账号状态".to_string())
}

fn sanitize_text(value: &str, limit: usize) -> String {
    value
        .trim()
        .chars()
        .filter(|c| !c.is_control())
        .take(limit)
        .collect()
}

fn sanitize_url(value: &str) -> String {
    validate_server_url(value).unwrap_or_default()
}

/// 记住这次授权：Token 进凭据存储，其余定位信息进 plex-account.json。
pub fn remember(
    data_dir: &Path,
    client_id: &str,
    token: Option<&str>,
    server_url: &str,
    server_name: &str,
    section_key: &str,
    section_title: &str,
) -> Result<(), String> {
    let mut file = load_account(data_dir);
    if !client_id.trim().is_empty() {
        validate_client_id(client_id.trim())?;
        file.client_id = client_id.trim().to_string();
    }
    if let Some(token) = token.map(str::trim).filter(|token| !token.is_empty()) {
        validate_token(token)?;
        vault::set(ACCOUNT_KEY, token)?;
    }
    let url = sanitize_url(server_url);
    if !url.is_empty() {
        file.server_url = url;
    }
    let name = sanitize_text(server_name, 120);
    if !name.is_empty() {
        file.server_name = name;
    }
    file.section_key = section_key
        .trim()
        .chars()
        .filter(|c| c.is_ascii_digit())
        .take(16)
        .collect();
    let title = sanitize_text(section_title, 120);
    if !title.is_empty() || file.section_key.is_empty() {
        file.section_title = title;
    }
    file.saved_at = now_ms();
    write_account(data_dir, &file)
}

/// 读账号状态。Token 取不到时只算「记得服务器」，不算已登录。
pub fn account_view(data_dir: &Path) -> PlexAccountView {
    let file = load_account(data_dir);
    let token = vault::get(ACCOUNT_KEY).unwrap_or_default();
    PlexAccountView {
        signed_in: vault::has(ACCOUNT_KEY) && !token.is_empty(),
        client_id: file.client_id,
        token,
        server_url: file.server_url,
        server_name: file.server_name,
        section_key: file.section_key,
        section_title: file.section_title,
        saved_at: file.saved_at,
    }
}

/// 退出登录：Token 与定位信息一起清掉，但不动已经连上的音乐来源。
pub fn forget(data_dir: &Path) -> Result<(), String> {
    vault::remove(ACCOUNT_KEY)?;
    let path = account_path(data_dir);
    if path.exists() {
        std::fs::remove_file(&path).map_err(|_| "无法清除 Plex 账号状态".to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub fn plex_account_get(state: tauri::State<'_, crate::AppState>) -> PlexAccountView {
    account_view(&state.data_dir)
}

#[tauri::command]
pub fn plex_account_save(
    client_id: String,
    token: Option<String>,
    server_url: String,
    server_name: String,
    section_key: String,
    section_title: String,
    state: tauri::State<'_, crate::AppState>,
) -> Result<PlexAccountView, String> {
    remember(
        &state.data_dir,
        &client_id,
        token.as_deref(),
        &server_url,
        &server_name,
        &section_key,
        &section_title,
    )?;
    Ok(account_view(&state.data_dir))
}

#[tauri::command]
pub fn plex_account_forget(state: tauri::State<'_, crate::AppState>) -> Result<(), String> {
    forget(&state.data_dir)
}
#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("awake-plex-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn account_survives_a_restart_and_keeps_the_token_out_of_the_metadata_file() {
        let _guard = crate::vault::test_guard();
        crate::vault::set_keychain_mirror(false);
        let dir = temp_dir("account");
        crate::vault::init(&dir);
        remember(
            &dir,
            "abc-123-xyz",
            Some("token-1"),
            "https://nas.local:32400/",
            "客厅",
            "3",
            "音乐",
        )
        .unwrap();
        let view = account_view(&dir);
        assert!(view.signed_in, "授权过就应该算已登录");
        assert_eq!(view.server_url, "https://nas.local:32400");
        assert_eq!(view.section_key, "3");
        assert_eq!(view.section_title, "音乐");
        let raw = std::fs::read_to_string(dir.join(ACCOUNT_FILE)).unwrap();
        assert!(!raw.contains("token-1"), "Token 只应该待在凭据存储里");
        assert_eq!(account_view(&dir).token, "token-1", "重启后仍然读得到 Token");
        forget(&dir).unwrap();
        assert!(!account_view(&dir).signed_in, "退出登录后不再算已登录");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn account_rejects_a_bad_token_and_sanitizes_the_section() {
        let _guard = crate::vault::test_guard();
        crate::vault::set_keychain_mirror(false);
        let dir = temp_dir("account-bad");
        crate::vault::init(&dir);
        assert!(remember(&dir, "abc-123-xyz", Some("bad\ntoken"), "", "", "", "").is_err());
        remember(
            &dir,
            "abc-123-xyz",
            Some("good-token"),
            "https://nas.local:32400",
            "客厅",
            "3; rm -rf /",
            "音乐",
        )
        .unwrap();
        assert_eq!(account_view(&dir).section_key, "3");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn resources_prefer_https_and_keep_shared_tokens() {
        let value: Value = serde_json::from_str(
            r#"[
              {"name":"客厅","clientIdentifier":"abc","provides":"server","accessToken":null,
               "connections":[{"uri":"http://192.168.1.5:32400","local":true,"relay":false},
                              {"uri":"https://192-168-1-5.hash.plex.direct:32400","local":true,"relay":false}]},
              {"name":"朋友的服务器","clientIdentifier":"def","provides":"server","accessToken":"shared-token",
               "connections":[{"uri":"https://relay.plex.direct:443","local":false,"relay":true}]},
              {"name":"手机","clientIdentifier":"ghi","provides":"client",
               "connections":[{"uri":"https://phone.plex.direct:443","local":false,"relay":false}]}
            ]"#,
        )
        .unwrap();
        let servers = parse_resources(&value, "account-token");
        assert_eq!(servers.len(), 3, "保留客厅的两条线路，排除手机客户端");
        let living = servers.iter().find(|s| s.name == "客厅").unwrap();
        assert!(living.url.starts_with("https://"), "优先使用 https 连接");
        assert_eq!(living.token, "account-token");
        assert!(servers
            .iter()
            .any(|s| s.name == "客厅" && s.url.starts_with("http://")), "同时保留 HTTP 备用线路");
        let shared = servers.iter().find(|s| s.name == "朋友的服务器").unwrap();
        assert_eq!(
            shared.token, "shared-token",
            "共享服务器使用资源里的 accessToken"
        );
        assert!(shared.relay);
    }

    #[test]
    fn sections_keep_only_music_libraries() {
        let value: Value = serde_json::from_str(
            r#"{"MediaContainer":{"Directory":[
                {"key":"1","title":"音乐","type":"artist"},
                {"key":"2","title":"电影","type":"movie"},
                {"key":"3","title":"有声书","type":"artist"}]}}"#,
        )
        .unwrap();
        let sections = parse_sections(&value);
        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0].key, "1");
        assert_eq!(sections[1].title, "有声书");
    }

    #[test]
    fn server_urls_and_tokens_are_validated() {
        assert!(validate_server_url("https://192.168.1.5:32400/").is_ok());
        assert_eq!(
            validate_server_url("https://192.168.1.5:32400/").unwrap(),
            "https://192.168.1.5:32400"
        );
        for url in [
            "https://nas.local/?X-Plex-Token=secret",
            "https://user:pass@nas.local:32400",
            "file:///tmp/library",
            "not a url",
        ] {
            assert!(validate_server_url(url).is_err(), "{url}");
        }
        assert!(validate_token("").is_err());
        assert!(validate_token("token\nnext").is_err());
        assert!(validate_token("good-token").is_ok());
    }

    #[test]
    fn html_login_page_is_reported_as_such() {
        let error =
            parse_json("<html><body>login</body></html>", "读取 Plex 音乐库时").unwrap_err();
        assert!(error.contains("HTML"), "{error}");
    }
}
