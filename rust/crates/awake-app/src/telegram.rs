//! Personal connector protocol. Authentication never appears in resource URLs.
use crate::{remote::Access, AppState};
use awake_core::{models::SourceKind, MediaSource};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::State;

#[derive(Deserialize)]
pub struct BrowseRequest {
    pub url: String,
    pub secret: String,
    #[serde(default)]
    pub chat_ids: Vec<String>,
    #[serde(default = "message_limit")]
    pub message_limit: u32,
}
fn message_limit() -> u32 {
    1000
}

#[tauri::command]
pub async fn open_telegram_link(url: String) -> Result<(), String> {
    let parsed = reqwest::Url::parse(&url).map_err(|_| "链接无效")?;
    if !matches!(parsed.scheme(), "https" | "http" | "tg")
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return Err("只支持网页或 Telegram 链接".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        let mut command = std::process::Command::new("open");
        #[cfg(target_os = "linux")]
        let mut command = std::process::Command::new("xdg-open");
        #[cfg(target_os = "windows")]
        let mut command = {
            let mut c = std::process::Command::new("rundll32.exe");
            c.arg("url.dll,FileProtocolHandler");
            c
        };
        let status = command.arg(url).status().map_err(|_| "无法打开链接")?;
        if status.success() {
            Ok(())
        } else {
            Err("无法打开链接".into())
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

pub fn connector(url: &str, secret: String) -> Result<Access, String> {
    if secret.trim().is_empty() {
        return Err("请输入连接器访问令牌".into());
    }
    let access = Access::new(
        MediaSource::new(SourceKind::Telegram, "Telegram", url.trim()),
        secret,
    );
    let base = access.base().map_err(|e| e.to_string())?;
    let host = base.host_str().unwrap_or("");
    let local = host == "localhost"
        || host.ends_with(".local")
        || host == "[::1]"
        || host
            .parse::<std::net::IpAddr>()
            .map(|ip| match ip {
                std::net::IpAddr::V4(ip) => {
                    ip.is_private() || ip.is_loopback() || ip.is_link_local()
                }
                std::net::IpAddr::V6(ip) => {
                    ip.is_loopback() || ip.is_unique_local() || ip.is_unicast_link_local()
                }
            })
            .unwrap_or(false);
    if base.scheme() != "https" && !local {
        return Err("外部连接器使用 HTTPS；本机和局域网可使用 HTTP".into());
    }
    Ok(access)
}

#[tauri::command]
pub async fn telegram_catalog(req: BrowseRequest) -> Result<Value, String> {
    let access = connector(&req.url, req.secret)?;
    tauri::async_runtime::spawn_blocking(move || {
        access
            .connector_json("v1/catalog", None)
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub async fn telegram_collection(req: BrowseRequest) -> Result<String, String> {
    let access = connector(&req.url, req.secret)?;
    if req.chat_ids.is_empty()
        || req.chat_ids.len() > 20
        || !(100..=2000).contains(&req.message_limit)
    {
        return Err("请选择 1–20 个来源，消息范围为 100–2000 条".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let value = access
            .connector_json(
                "v1/libraries",
                Some(json!({"chat_ids": req.chat_ids, "message_limit": req.message_limit})),
            )
            .map_err(|e| e.to_string())?;
        let path = value["path"].as_str().ok_or("连接器缺少媒体库地址")?;
        let url = access.url(path).map_err(|e| e.to_string())?;
        Ok(url.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn telegram_sponsored(id: String, state: State<'_, AppState>) -> Result<Value, String> {
    let source = state
        .library
        .lock()
        .snapshot
        .sources
        .iter()
        .find(|s| s.id == id && s.kind == SourceKind::Telegram)
        .cloned()
        .ok_or("Telegram 来源不存在")?;
    let access = crate::connections::access(&source)?;
    tauri::async_runtime::spawn_blocking(move || {
        access
            .connector_json("sponsored", None)
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub async fn telegram_ad_viewed(
    id: String,
    ad: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let source = state
        .library
        .lock()
        .snapshot
        .sources
        .iter()
        .find(|s| s.id == id && s.kind == SourceKind::Telegram)
        .cloned()
        .ok_or("Telegram 来源不存在")?;
    let access = crate::connections::access(&source)?;
    tauri::async_runtime::spawn_blocking(move || {
        access
            .connector_json("viewed", Some(json!({"id": ad})))
            .map(|_| ())
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SourceConfiguration {
    pub version: u32,
    pub kind: SourceKind,
    pub name: String,
    pub url: String,
    #[serde(default)]
    pub username: String,
}
pub fn parse_configuration(text: &str, format: &str) -> Result<SourceConfiguration, String> {
    if text.len() > 65536 {
        return Err("配置文件不能超过 64 KB".into());
    }
    let mut fields = serde_json::Map::new();
    let mut insert = |key: &str, value: &str| -> Result<(), String> {
        if !["version", "kind", "name", "url", "username"].contains(&key)
            || fields.contains_key(key)
        {
            return Err("配置包含未知或重复字段；凭据请在应用内填写".into());
        }
        let value = if key == "version" {
            json!(value.parse::<u32>().map_err(|_| "配置版本无效")?)
        } else {
            json!(value)
        };
        fields.insert(key.into(), value);
        Ok(())
    };
    let config: SourceConfiguration = match format {
        "json" => serde_json::from_str(text).map_err(|_| "JSON 配置格式无效，或包含未知字段")?,
        "xml" => {
            let doc = roxmltree::Document::parse(text).map_err(|_| "XML 配置格式无效")?;
            let root = doc.root_element();
            if root.tag_name().name() != "awake-source" || root.attributes().len() != 0 {
                return Err("XML 根节点需要为 awake-source，字段使用子节点".into());
            }
            for node in root.children().filter(|n| n.is_element()) {
                if node.children().any(|n| n.is_element()) || node.attributes().len() != 0 {
                    return Err("配置字段只能包含文本".into());
                }
                insert(node.tag_name().name(), node.text().unwrap_or("").trim())?;
            }
            serde_json::from_value(Value::Object(fields)).map_err(|_| "XML 配置缺少必填字段")?
        }
        "txt" => {
            for line in text
                .lines()
                .map(str::trim)
                .filter(|s| !s.is_empty() && !s.starts_with('#'))
            {
                let (key, value) = line.split_once('=').ok_or("TXT 每行需要为 字段=值")?;
                insert(key.trim(), value.trim())?;
            }
            serde_json::from_value(Value::Object(fields)).map_err(|_| "TXT 配置缺少必填字段")?
        }
        _ => return Err("支持 JSON、XML 或 TXT 配置文件".into()),
    };
    if config.version != 1 || config.name.trim().is_empty() || config.name.len() > 240 {
        return Err("配置版本需要为 1，并填写来源名称".into());
    }
    if !matches!(
        config.kind,
        SourceKind::Webdav | SourceKind::Plex | SourceKind::Telegram
    ) {
        return Err("配置导入支持 WebDAV、Plex 和 Telegram 连接器".into());
    }
    let access = Access::new(
        MediaSource::new(config.kind, &config.name, config.url.trim()),
        String::new(),
    );
    access.base().map_err(|e| e.to_string())?;
    Ok(config)
}
#[tauri::command]
pub fn parse_source_configuration(
    text: String,
    format: String,
) -> Result<SourceConfiguration, String> {
    parse_configuration(&text, &format)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn configuration_formats_and_secrets() {
        for (format, text) in [
            ("json", r#"{"version":1,"kind":"telegram","name":"音乐","url":"https://example.test/v1/libraries/abc/"}"#),
            ("xml", "<awake-source><version>1</version><kind>telegram</kind><name>音乐</name><url>https://example.test/v1/libraries/abc/</url></awake-source>"),
            ("txt", "# Personal library\nversion=1\nkind=telegram\nname=音乐\nurl=https://example.test/v1/libraries/abc/"),
        ] {
            let config = parse_configuration(text, format).unwrap();
            assert_eq!(config.name, "音乐");
            assert_eq!(config.kind, SourceKind::Telegram);
        }
        for text in [
            "version=1\nkind=telegram\nname=a\nurl=https://a.test/\nsecret=x",
            "version=1\nkind=telegram\nname=a\nurl=https://a.test/?token=x",
            "version=1\nkind=telegram\nname=a\nurl=https://a.test/\nname=b",
        ] {
            assert!(parse_configuration(text, "txt").is_err());
        }
        assert!(connector("http://example.com/", "token".into()).is_err());
        assert!(connector("http://127.0.0.1:8765/", "token".into()).is_ok());
    }
}
