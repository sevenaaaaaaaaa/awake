//! Plex 账号登录（PIN 授权）、服务器发现与音乐库列表。
//!
//! 只使用 Plex 官方公开接口。账号 Token 只放进请求头，不拼进 URL、日志或错误信息。
use reqwest::{
    blocking::{Client, RequestBuilder, Response},
    header, Url,
};
use serde::Serialize;
use serde_json::Value;
use std::{io::Read, time::Duration};

const PLEX_TV: &str = "https://plex.tv";
const PRODUCT: &str = "Awake";
const MAX_BODY: usize = 1024 * 1024;

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

/// 优先 https → 本地 → 非中继；任何带账号信息或非 http(s) 的连接都丢弃。
fn best_connection(connections: &[Value]) -> Option<PlexConnection> {
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
    candidates.into_iter().next()
}

fn parse_resources(value: &Value, account_token: &str) -> Vec<PlexServer> {
    let Some(items) = value.as_array() else {
        return Vec::new();
    };
    let mut servers = Vec::new();
    for item in items {
        if !provides_server(&item["provides"]) {
            continue;
        }
        let Some(connections) = item["connections"].as_array() else {
            continue;
        };
        let Some(best) = best_connection(connections) else {
            continue;
        };
        let token = item["accessToken"]
            .as_str()
            .filter(|token| !token.is_empty())
            .unwrap_or(account_token);
        servers.push(PlexServer {
            name: item["name"].as_str().unwrap_or("Plex 服务器").to_string(),
            client_identifier: item["clientIdentifier"].as_str().unwrap_or("").to_string(),
            url: best.url.trim_end_matches('/').to_string(),
            token: token.to_string(),
            local: best.local,
            relay: best.relay,
        });
    }
    servers.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    servers.dedup_by(|a, b| a.url == b.url);
    servers
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
                .filter(|directory| directory["type"].as_str() == Some("artist"))
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

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(servers.len(), 2, "只保留提供 server 能力的设备");
        let living = servers.iter().find(|s| s.name == "客厅").unwrap();
        assert!(living.url.starts_with("https://"), "优先使用 https 连接");
        assert_eq!(living.token, "account-token");
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
