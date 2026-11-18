//! 网络音乐插件（枪弹分离 JS）。
//!
//! 职责划分：插件代码由用户显式导入，保存在数据目录 `plugins/<id>.js`；
//! 搜索与解析在前端沙箱里运行（MusicFree 兼容契约：`search` / `getMediaSource` / …），
//! 后端只做三件受控的事：
//! 1. 保存与读取插件文件；
//! 2. 把沙箱返回的搜索结果落成曲库曲目（locator = 原始 musicItem JSON，播放时要靠它解析）；
//! 3. `plugin_http` —— 沙箱的 fetch 通道（绕过 WebView 的 CORS，但有地址/大小/超时上限）。
//!
//! 播放时前端先用插件 `getMediaSource` 解析出真实地址与请求头，
//! 随 `play_track.resolved` 交给本地 HTTP Range 播放管线（见 remote.rs 的 direct_*）。

use awake_core::{models::now_ms, Library, MediaSource, Track};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use sha2::Digest;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// 单个插件文件上限：真实 MusicFree 插件一般几十 KB。
const MAX_PLUGIN_CODE: usize = 512 * 1024;
/// 单条 musicItem JSON 上限：解析地址需要的字段之外不允许塞入大对象。
const MAX_ITEM_JSON: usize = 32 * 1024;
/// HTTP 通道的响应体上限。
const MAX_HTTP_BODY: u64 = 8 * 1024 * 1024;
/// HTTP 通道的请求体上限。
const MAX_REQUEST_BODY: usize = 2 * 1024 * 1024;

pub type SharedLibrary = Arc<Mutex<Library>>;

fn plugins_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("plugins")
}

fn plugin_path(data_dir: &Path, id: &str) -> Result<PathBuf, String> {
    // id 由本应用生成（UUID）。即便曲库文件被手工改过，这里也只接受安全字符，
    // 绝不把 url 字段当路径拼 —— 路径只从 id 推导。
    if id.is_empty()
        || id.len() > 64
        || !id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("插件标识无效".into());
    }
    Ok(plugins_dir(data_dir).join(format!("{id}.js")))
}

/// 从插件代码里尽力读出 MusicFree 的 `platform` 名，只用于展示。
/// 支持 `platform: "名称"` / `platform: '名称'` / `platform = "名称"` 三种写法。
pub fn platform_name(code: &str) -> Option<String> {
    let key = "platform";
    let mut search_from = 0;
    while let Some(relative) = code[search_from..].find(key) {
        let start = search_from + relative + key.len();
        let rest = &code[start..];
        let rest = rest.trim_start();
        let Some(rest) = rest.strip_prefix(':').or_else(|| rest.strip_prefix('=')) else {
            search_from = start;
            continue;
        };
        let rest = rest.trim_start();
        let quote = rest.chars().next()?;
        if quote != '"' && quote != '\'' {
            search_from = start;
            continue;
        }
        let end = rest[1..].find(quote).map(|i| i + 1)?;
        let name: String = rest[1..end]
            .chars()
            .filter(|c| !c.is_control())
            .take(60)
            .collect();
        if !name.trim().is_empty() {
            return Some(name.trim().to_string());
        }
        search_from = start;
    }
    None
}

fn code_hash(code: &str) -> String {
    format!("{:x}", sha2::Sha256::digest(code.as_bytes()))
}

fn is_plugin(source: &MediaSource) -> bool {
    source.kind == awake_core::models::SourceKind::Plugin
}

/// 导入一个插件：代码落盘，来源入库。
/// 同一份代码重复导入是幂等的（同一个来源）；同名 platform 的新版本代码
/// 覆盖旧文件并保留已有曲目 —— 这就是「更新插件」的路径。
pub fn import_plugin_impl(
    code: &str,
    name: Option<&str>,
    data_dir: &Path,
    library: &SharedLibrary,
) -> Result<MediaSource, String> {
    if code.trim().is_empty() {
        return Err("插件文件是空的".into());
    }
    if code.len() > MAX_PLUGIN_CODE {
        return Err("插件文件超过 512 KB，请确认这是一个音乐插件".into());
    }
    let platform = platform_name(code);
    let hash = code_hash(code);

    let existing = {
        let lib = library.lock();
        lib.snapshot
            .sources
            .iter()
            .find(|s| {
                if !is_plugin(s) {
                    return false;
                }
                plugin_path(data_dir, &s.id)
                    .ok()
                    .and_then(|path| std::fs::read_to_string(path).ok())
                    .map(|old| code_hash(&old) == hash)
                    .unwrap_or(false)
            })
            .or_else(|| {
                platform.as_ref().and_then(|platform| {
                    lib.snapshot.sources.iter().find(|s| {
                        is_plugin(s)
                            && plugin_path(data_dir, &s.id)
                                .ok()
                                .and_then(|path| std::fs::read_to_string(path).ok())
                                .and_then(|old| platform_name(&old))
                                .as_ref()
                                == Some(platform)
                    })
                })
            })
            .cloned()
    };

    let (id, display_name, existed) = if let Some(old) = existing {
        let display = name
            .map(str::trim)
            .filter(|n| !n.is_empty())
            .map(str::to_string)
            .unwrap_or(old.name.clone());
        (old.id, display, true)
    } else {
        let id = awake_core::models::new_id();
        let display = name
            .map(str::trim)
            .filter(|n| !n.is_empty())
            .map(str::to_string)
            .or(platform.clone())
            .unwrap_or_else(|| "网络音乐插件".into());
        (id, display, false)
    };

    let dir = plugins_dir(data_dir);
    std::fs::create_dir_all(&dir).map_err(|e| format!("无法创建插件目录：{e}"))?;
    let path = plugin_path(data_dir, &id)?;
    let tmp = path.with_extension("js.tmp");
    std::fs::write(&tmp, code).map_err(|e| format!("无法写入插件文件：{e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("无法保存插件文件：{e}"))?;

    let mut lib = library.lock();
    let previous = lib.snapshot.clone();
    let mut source = lib
        .snapshot
        .sources
        .iter()
        .find(|s| s.id == id)
        .cloned()
        .unwrap_or_else(|| MediaSource::new(awake_core::models::SourceKind::Plugin, "", ""));
    source.kind = awake_core::models::SourceKind::Plugin;
    // id 必须与插件文件名一致：新建来源时 MediaSource::new 会自带一个随机 id，
    // 不覆盖的话，读取/删除插件文件（按来源 id 定位）就会找不到文件。
    source.id = id.clone();
    source.password_key = format!("awake.{id}");
    source.name = display_name;
    source.url = format!("plugin://{id}");
    if !existed {
        source.track_count = 0;
        source.last_scan = None;
    }
    lib.snapshot.sources.retain(|s| s.id != source.id);
    lib.add_source(source.clone());
    lib.snapshot.scanned_at = Some(now_ms());
    if let Err(e) = lib.save() {
        lib.snapshot = previous;
        return Err(e.to_string());
    }
    source.token.clear();
    Ok(source)
}

/// 读取插件代码，交给前端沙箱实例化。
pub fn read_plugin_source_impl(id: &str, data_dir: &Path, library: &SharedLibrary) -> Result<String, String> {
    let lib = library.lock();
    let source = lib
        .snapshot
        .sources
        .iter()
        .find(|s| s.id == id)
        .ok_or("插件来源不存在")?;
    if !is_plugin(source) {
        return Err("这个来源不是网络音乐插件".into());
    }
    let path = plugin_path(data_dir, &source.id)?;
    let code = std::fs::read_to_string(&path).map_err(|_| "插件文件已丢失，请重新导入".to_string())?;
    if code.len() > MAX_PLUGIN_CODE {
        return Err("插件文件超过大小上限，已拒绝读取".into());
    }
    Ok(code)
}

/// 移除插件来源时连插件文件一起删（connections::remove_source 调用）。
pub fn delete_plugin_files(data_dir: &Path, id: &str) {
    if let Ok(path) = plugin_path(data_dir, id) {
        let _ = std::fs::remove_file(path);
    }
}

/// 前端沙箱返回的一条搜索结果。`item` 是原始 musicItem（播放解析要用）。
#[derive(Debug, Clone, Deserialize)]
pub struct PluginTrackPayload {
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub album: String,
    #[serde(default)]
    pub duration: f64,
    #[serde(default)]
    pub artwork: String,
    pub item: serde_json::Value,
}

fn sanitize_text(value: &str, limit: usize) -> String {
    value
        .trim()
        .chars()
        .filter(|c| !c.is_control())
        .take(limit)
        .collect()
}

fn valid_artwork(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() || value.len() > 1024 {
        return None;
    }
    let parsed = reqwest::Url::parse(value).ok()?;
    if parsed.scheme() != "https" && parsed.scheme() != "http" {
        return None;
    }
    if parsed.host_str().is_none() || !parsed.username().is_empty() || parsed.password().is_some() {
        return None;
    }
    Some(value.to_string())
}

/// 平台侧曲目 id：去重键。musicItem.id 可能是字符串或数字。
fn item_platform_id(item: &serde_json::Value) -> Option<String> {
    item["id"]
        .as_str()
        .map(str::to_string)
        .or_else(|| item["id"].as_i64().map(|n| n.to_string()))
        .or_else(|| item["id"].as_f64().map(|n| n.to_string()))
        .filter(|id| !id.is_empty())
}

/// 把沙箱返回的搜索结果落成曲库曲目；返回本次新增的条数。
/// 已存在（同平台 id 或同 locator）的条目跳过，不重复入库。
pub fn save_plugin_tracks_impl(
    source_id: &str,
    items: Vec<PluginTrackPayload>,
    library: &SharedLibrary,
) -> Result<usize, String> {
    if items.is_empty() {
        return Err("没有要入库的曲目".into());
    }
    if items.len() > 2000 {
        return Err("一次最多入库 2000 首插件曲目".into());
    }
    let mut lib = library.lock();
    let previous = lib.snapshot.clone();
    let source = lib
        .snapshot
        .sources
        .iter()
        .find(|s| s.id == source_id)
        .cloned()
        .ok_or("插件来源不存在")?;
    if !is_plugin(&source) {
        return Err("这个来源不是网络音乐插件".into());
    }

    let mut existing_ids: std::collections::HashSet<String> = lib
        .snapshot
        .tracks
        .iter()
        .filter(|t| t.source_id == source_id)
        .filter_map(|t| {
            serde_json::from_str::<serde_json::Value>(&t.locator)
                .ok()
                .and_then(|item| item_platform_id(&item))
        })
        .collect();
    let mut existing_locators: std::collections::HashSet<String> = lib
        .snapshot
        .tracks
        .iter()
        .filter(|t| t.source_id == source_id)
        .map(|t| t.locator.clone())
        .collect();

    let mut added = 0usize;
    let mut new_tracks = Vec::new();
    for payload in items {
        let title = sanitize_text(&payload.title, 300);
        if title.is_empty() {
            continue;
        }
        let locator = serde_json::to_string(&payload.item)
            .map_err(|_| "曲目数据无法序列化".to_string())?;
        if locator.len() > MAX_ITEM_JSON {
            return Err(format!("《{title}》的曲目数据超过大小上限，已停止入库"));
        }
        let duration = if payload.duration.is_finite() && payload.duration >= 0.0 {
            payload.duration.min(86_400.0)
        } else {
            0.0
        };
        if let Some(id) = item_platform_id(&payload.item) {
            if existing_ids.contains(&id) {
                continue;
            }
            existing_ids.insert(id);
        }
        if !existing_locators.insert(locator.clone()) {
            continue;
        }
        let mut track = Track {
            id: Track::make_id(source_id, &locator),
            title,
            artist: sanitize_text(&payload.artist, 300),
            album_artist: String::new(),
            album: sanitize_text(&payload.album, 300),
            genre: String::new(),
            year: None,
            track_number: None,
            disc_number: None,
            duration,
            sample_rate: 0,
            bit_depth: 0,
            channels: 0,
            codec: String::new(),
            source_id: source_id.to_string(),
            locator,
            file_size: 0,
            modified: 0,
            artwork_path: None,
            play_count: 0,
            favorite: false,
            last_played: None,
            added_at: now_ms(),
            is_remote: true,
            origin_url: valid_artwork(&payload.artwork),
            comment: String::new(),
            lyrics: String::new(),
            media_info: None,
        };
        track.album_artist = track.artist.clone();
        new_tracks.push(track);
        added += 1;
    }
    if added == 0 {
        return Err("这些曲目都已经在曲库里了".into());
    }
    lib.snapshot.tracks.extend(new_tracks);
    let total = lib
        .snapshot
        .tracks
        .iter()
        .filter(|t| t.source_id == source_id)
        .count();
    if let Some(current) = lib
        .snapshot
        .sources
        .iter_mut()
        .find(|s| s.id == source_id)
    {
        current.track_count = total;
        current.last_scan = Some(now_ms());
    }
    lib.snapshot.scanned_at = Some(now_ms());
    if let Err(e) = lib.save() {
        lib.snapshot = previous;
        return Err(e.to_string());
    }
    Ok(added)
}

/// 沙箱 fetch 通道的请求。字段与前端 plugins.ts 的 fetch 封装一一对应。
#[derive(Debug, Deserialize)]
pub struct PluginHttpRequest {
    pub url: String,
    #[serde(default)]
    pub method: Option<String>,
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub body_base64: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PluginHttpResponse {
    pub status: u16,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body_base64: String,
}

fn validate_plugin_url(raw: &str) -> Result<reqwest::Url, String> {
    let url = reqwest::Url::parse(raw.trim()).map_err(|_| "插件请求的地址无效".to_string())?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return Err("插件请求只允许 http(s) 地址".into());
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err("插件请求的地址不允许带账号信息".into());
    }
    Ok(url)
}

fn validate_header(name: &str, value: &str) -> Result<(), String> {
    let lower = name.to_ascii_lowercase();
    // Host / Content-Length 由 HTTP 客户端自己管理；代理凭据不允许注入。
    if matches!(lower.as_str(), "host" | "content-length" | "proxy-authorization") {
        return Err(format!("插件请求不允许设置 {name} 头"));
    }
    if name.is_empty()
        || name.len() > 64
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    {
        return Err("插件请求头名称无效".into());
    }
    if value.len() > 8192 || value.chars().any(char::is_control) {
        return Err("插件请求头内容无效".into());
    }
    Ok(())
}

/// 插件沙箱的 fetch 实现：受限的通用 HTTP 通道。
/// 这是「枪弹分离」的关键一环 —— 插件按自己的协议直连目标站点（WebView 直接 fetch
/// 会被 CORS 挡住），请求由后端发出，地址 / 方法 / 头 / 体都有上限。
pub fn plugin_http_blocking(req: PluginHttpRequest) -> Result<PluginHttpResponse, String> {
    let url = validate_plugin_url(&req.url)?;
    let method = match req
        .method
        .as_deref()
        .unwrap_or("GET")
        .to_ascii_uppercase()
        .as_str()
    {
        "GET" => reqwest::Method::GET,
        "POST" => reqwest::Method::POST,
        "PUT" => reqwest::Method::PUT,
        "DELETE" => reqwest::Method::DELETE,
        "HEAD" => reqwest::Method::HEAD,
        other => return Err(format!("插件请求不支持 {other} 方法")),
    };
    if req.headers.len() > 40 {
        return Err("插件请求头数量超过上限".into());
    }
    for (name, value) in &req.headers {
        validate_header(name, value)?;
    }
    let body: Vec<u8> = if let Some(text) = req.body {
        text.into_bytes()
    } else if let Some(b64) = req.body_base64 {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|_| "插件请求体编码无效".to_string())?
    } else {
        Vec::new()
    };
    if body.len() > MAX_REQUEST_BODY {
        return Err("插件请求体超过 2 MB 上限".into());
    }

    let client = reqwest::blocking::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(8))
        .timeout(std::time::Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::limited(5))
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15")
        .build()
        .map_err(|_| "无法初始化插件网络客户端".to_string())?;
    let mut request = client.request(method, url);
    for (name, value) in &req.headers {
        request = request.header(name, value);
    }
    if !body.is_empty() {
        request = request.body(body);
    }
    let response = request
        .send()
        .map_err(|e| format!("插件请求失败：{}", crate::remote::network_hint(&e)))?;
    let final_url = response.url().clone();
    if !matches!(final_url.scheme(), "http" | "https") {
        return Err("插件请求被重定向到了不支持的地址".into());
    }
    let status = response.status().as_u16();
    let headers: Vec<(String, String)> = response
        .headers()
        .iter()
        .take(64)
        .map(|(name, value)| {
            (
                name.as_str().to_string(),
                String::from_utf8_lossy(value.as_bytes()).to_string(),
            )
        })
        .collect();
    use base64::Engine;
    use std::io::Read;
    let mut bytes = Vec::new();
    response
        .take(MAX_HTTP_BODY + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "读取插件响应失败".to_string())?;
    if bytes.len() as u64 > MAX_HTTP_BODY {
        return Err("插件响应超过 8 MB 上限".into());
    }
    Ok(PluginHttpResponse {
        status,
        url: final_url.to_string(),
        headers,
        body_base64: base64::engine::general_purpose::STANDARD.encode(bytes),
    })
}

/// 播放时前端随 play_track 传来的「已解析地址」。
/// key 是曲目 id；value 是插件 getMediaSource 的结果。
#[derive(Debug, Clone, Deserialize)]
pub struct ResolvedTrack {
    pub url: String,
    #[serde(default)]
    pub headers: Vec<(String, String)>,
}

impl ResolvedTrack {
    /// 播放地址必须是一个可直连的 http(s) 地址；请求头沿用同一套校验。
    pub fn validated(self) -> Result<Self, String> {
        validate_plugin_url(&self.url)?;
        if self.headers.len() > 40 {
            return Err("解析结果的请求头数量超过上限".into());
        }
        for (name, value) in &self.headers {
            validate_header(name, value)?;
        }
        Ok(self)
    }
}

// ---------------------------------------------------------------------------
// Tauri 命令层：只把 State 拆开转给上面的实现函数（实现函数可在单元测试里直接调用）。
// ---------------------------------------------------------------------------

#[tauri::command]
pub fn import_plugin(
    code: String,
    name: Option<String>,
    state: tauri::State<'_, crate::AppState>,
) -> Result<MediaSource, String> {
    import_plugin_impl(&code, name.as_deref(), &state.data_dir, &state.library)
}

#[tauri::command]
pub fn read_plugin_source(
    id: String,
    state: tauri::State<'_, crate::AppState>,
) -> Result<String, String> {
    read_plugin_source_impl(&id, &state.data_dir, &state.library)
}

#[tauri::command]
pub fn save_plugin_tracks(
    source_id: String,
    items: Vec<PluginTrackPayload>,
    state: tauri::State<'_, crate::AppState>,
) -> Result<usize, String> {
    save_plugin_tracks_impl(&source_id, items, &state.library)
}

#[tauri::command]
pub async fn plugin_http(req: PluginHttpRequest) -> Result<PluginHttpResponse, String> {
    tauri::async_runtime::spawn_blocking(move || plugin_http_blocking(req))
        .await
        .map_err(|_| "插件网络请求被中断".to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> (std::path::PathBuf, SharedLibrary) {
        let dir = std::env::temp_dir().join(format!("awake-plugin-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let library = Arc::new(Mutex::new(Library::open(dir.join("library.json"))));
        (dir, library)
    }

    #[test]
    fn platform_name_reads_the_musicfree_field() {
        assert_eq!(
            platform_name(r#"module.exports = { platform: "某平台", version: "1" };"#).as_deref(),
            Some("某平台")
        );
        assert_eq!(
            platform_name("const x = { platform: 'single' };").as_deref(),
            Some("single")
        );
        assert_eq!(
            platform_name("exports.platform = \"assigned\";").as_deref(),
            Some("assigned")
        );
        assert_eq!(platform_name("const aplatform = 1;"), None);
        assert_eq!(platform_name("platform: \"unterminated"), None);
    }

    #[test]
    fn plugin_paths_are_derived_from_safe_ids_only() {
        let dir = Path::new("/tmp/awake-test");
        assert!(plugin_path(dir, "abc-123_DEF").is_ok());
        for bad in ["", "../escape", "a/b", "a\\b", "..", "x;rm"] {
            assert!(plugin_path(dir, bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn http_inputs_are_validated() {
        assert!(validate_plugin_url("https://music.example/api").is_ok());
        for bad in [
            "ftp://example/x",
            "file:///etc/passwd",
            "https://user:pass@example/x",
            "not a url",
            "//example.com/x",
        ] {
            assert!(validate_plugin_url(bad).is_err(), "{bad}");
        }
        assert!(validate_header("Referer", "https://a.example/").is_ok());
        assert!(validate_header("Host", "evil.example").is_err());
        assert!(validate_header("Content-Length", "1").is_err());
        assert!(validate_header("X-Bad\nName", "v").is_err());
        assert!(validate_header("X-Test", "bad\r\nvalue").is_err());

        let resolved = ResolvedTrack {
            url: "https://cdn.example/song.mp3?sign=1".into(),
            headers: vec![("Referer".into(), "https://a.example/".into())],
        };
        assert!(resolved.validated().is_ok());
        let bad = ResolvedTrack {
            url: "file:///tmp/x.mp3".into(),
            headers: vec![],
        };
        assert!(bad.validated().is_err());
    }

    #[test]
    fn payloads_are_sanitized_and_deduped_by_platform_id() {
        assert_eq!(
            item_platform_id(&serde_json::json!({"id": "abc"})).as_deref(),
            Some("abc")
        );
        assert_eq!(
            item_platform_id(&serde_json::json!({"id": 42})).as_deref(),
            Some("42")
        );
        assert!(valid_artwork("https://img.example/a.jpg").is_some());
        assert!(valid_artwork("javascript:alert(1)").is_none());
        assert_eq!(sanitize_text("  歌名 \n", 300), "歌名");
    }

    #[test]
    fn import_read_update_and_track_merge_roundtrip() {
        let (dir, library) = scratch("roundtrip");
        let code = r#"module.exports = { platform: "测试平台", version: "0.1" };"#;
        let imported = import_plugin_impl(code, None, &dir, &library).unwrap();
        assert_eq!(imported.name, "测试平台");
        assert_eq!(imported.kind, awake_core::models::SourceKind::Plugin);
        assert_eq!(imported.url, format!("plugin://{}", imported.id));
        // 幂等：同一份代码再导入，不产生第二个来源。
        let again = import_plugin_impl(code, None, &dir, &library).unwrap();
        assert_eq!(again.id, imported.id);
        assert_eq!(library.lock().snapshot.sources.len(), 1);
        assert_eq!(
            read_plugin_source_impl(&imported.id, &dir, &library).unwrap(),
            code
        );
        // 同 platform 的新版本：覆盖文件、保留来源 id。
        let v2 = r#"module.exports = { platform: "测试平台", version: "0.2" };"#;
        let updated = import_plugin_impl(v2, None, &dir, &library).unwrap();
        assert_eq!(updated.id, imported.id);
        assert_eq!(
            read_plugin_source_impl(&imported.id, &dir, &library).unwrap(),
            v2
        );

        // 入库：两条不同 id + 一条重复 id + 一条同 locator。
        let items = vec![
            PluginTrackPayload {
                title: "第一首".into(),
                artist: "艺人".into(),
                album: "专辑".into(),
                duration: 200.0,
                artwork: "https://img.example/a.jpg".into(),
                item: serde_json::json!({"id": "song-1", "title": "第一首"}),
            },
            PluginTrackPayload {
                title: "第二首".into(),
                artist: "".into(),
                album: "".into(),
                duration: f64::NAN,
                artwork: "".into(),
                item: serde_json::json!({"id": "song-2"}),
            },
            PluginTrackPayload {
                title: "重复".into(),
                artist: "".into(),
                album: "".into(),
                duration: 1.0,
                artwork: "".into(),
                item: serde_json::json!({"id": "song-1"}),
            },
        ];
        let added = save_plugin_tracks_impl(&imported.id, items, &library).unwrap();
        assert_eq!(added, 2, "同平台 id 的重复条目应跳过");
        {
            let lib = library.lock();
            assert_eq!(lib.snapshot.tracks.len(), 2);
            let first = lib
                .snapshot
                .tracks
                .iter()
                .find(|t| t.title == "第一首")
                .unwrap();
            assert!(first.is_remote);
            assert!(first.locator.contains("song-1"), "locator 保存原始 musicItem");
            assert_eq!(first.origin_url.as_deref(), Some("https://img.example/a.jpg"));
            assert_eq!(lib.snapshot.sources[0].track_count, 2);
        }
        // 再来一次，全部重复。
        let dup = vec![PluginTrackPayload {
            title: "第一首".into(),
            artist: "".into(),
            album: "".into(),
            duration: 1.0,
            artwork: "".into(),
            item: serde_json::json!({"id": "song-1"}),
        }];
        assert!(save_plugin_tracks_impl(&imported.id, dup, &library).is_err());

        delete_plugin_files(&dir, &imported.id);
        assert!(read_plugin_source_impl(&imported.id, &dir, &library).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn oversized_plugin_code_is_rejected() {
        let (dir, library) = scratch("oversized");
        let huge = format!("// {}\nmodule.exports = {{ platform: \"x\" }};", "x".repeat(MAX_PLUGIN_CODE));
        assert!(import_plugin_impl(&huge, None, &dir, &library).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
