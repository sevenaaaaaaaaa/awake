//! 歌单导入：从平台公开页面抓取，或解析用户粘贴的文件，再与本地曲库匹配。
//!
//! 三个命令只读：不写曲库、不落盘。抓取用阻塞 reqwest，由 async command 包进
//! spawn_blocking，避免阻塞 UI 线程。全程不使用 Cookie，也不读取账号凭据；
//! 错误信息里不出现 token 或密钥。

use awake_core::models::Track;
use reqwest::{
    blocking::{Client, Response},
    header, Url,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    io::Read,
    time::Duration,
};
use tauri::State;

use crate::AppState;

/// 单页/单文件正文上限：超过就停，防止异常响应吃满内存。
const MAX_BODY: u64 = 12 * 1024 * 1024;
/// 单个歌单的曲目上限。
const MAX_TRACKS: usize = 5000;
/// YouTube 续页请求上限（首屏之外最多再翻 8 页）。
const MAX_PAGES: usize = 8;
/// Spotify 嵌入页最多给 100 首。
const SPOTIFY_LIMIT: usize = 100;
/// 网易云歌曲详情接口单批上限。
const NETEASE_BATCH: usize = 200;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const TOTAL_TIMEOUT: Duration = Duration::from_secs(20);
const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

const TITLE_WEIGHT: f64 = 0.72;
const ARTIST_WEIGHT: f64 = 0.22;
const DURATION_WEIGHT: f64 = 0.06;
/// 时长容差：±4 秒内算同一次录音。
const DURATION_TOLERANCE: f64 = 4.0;
const MATCH_THRESHOLD: f64 = 0.62;

/// 导入曲目。字段与前端约定为 snake_case。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportedTrack {
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub album: String,
    /// 秒；未知为 0。
    #[serde(default)]
    pub duration: f64,
    /// CUE / M3U 里指向的音频文件。
    #[serde(default)]
    pub file_name: Option<String>,
    /// CUE 分段起点（秒，相对同一音频文件）。
    #[serde(default)]
    pub segment_start: Option<f64>,
    /// CUE 分段终点；末轨为 None。
    #[serde(default)]
    pub segment_end: Option<f64>,
    #[serde(default)]
    pub number: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportedPlaylist {
    pub name: String,
    pub source: String,
    pub tracks: Vec<ImportedTrack>,
    #[serde(default)]
    pub note: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportMatch {
    pub track: ImportedTrack,
    pub song_id: Option<String>,
    pub score: f64,
    pub reason: String,
}

/// 从平台抓取歌单。input 可以是链接、纯 ID，text 时则是整段粘贴内容。
#[tauri::command]
pub async fn playlist_import_fetch(
    source: String,
    input: String,
) -> Result<ImportedPlaylist, String> {
    let source = source.trim().to_ascii_lowercase();
    let input = input.trim().to_string();
    if input.is_empty() {
        return Err("请先填写歌单链接、ID 或粘贴曲目文本".into());
    }
    if !matches!(
        source.as_str(),
        "netease" | "qq" | "youtube" | "apple" | "spotify" | "text"
    ) {
        return Err(format!("不支持的歌单来源：{source}"));
    }
    tauri::async_runtime::spawn_blocking(move || fetch_playlist(&source, &input))
        .await
        .map_err(|error| format!("歌单抓取任务异常：{error}"))?
}

/// 解析用户选择的歌单文件；内容由前端读出后传入。
#[tauri::command]
pub async fn playlist_import_file(
    file_name: String,
    content: String,
) -> Result<ImportedPlaylist, String> {
    tauri::async_runtime::spawn_blocking(move || parse_file(&file_name, &content))
        .await
        .map_err(|error| format!("歌单文件解析任务异常：{error}"))?
}

/// 把导入曲目与当前曲库匹配。只读曲库，不改任何状态。
#[tauri::command]
pub async fn playlist_import_match(
    tracks: Vec<ImportedTrack>,
    state: State<'_, AppState>,
) -> Result<Vec<ImportMatch>, String> {
    if tracks.len() > MAX_TRACKS {
        return Err(format!("一次最多匹配 {MAX_TRACKS} 首"));
    }
    let library = state.library.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let library = library.lock();
        Ok::<Vec<ImportMatch>, String>(match_tracks(&tracks, &library.snapshot.tracks))
    })
    .await
    .map_err(|error| format!("歌单匹配任务异常：{error}"))?
}

fn fetch_playlist(source: &str, input: &str) -> Result<ImportedPlaylist, String> {
    match source {
        "text" => parse_text(input),
        "netease" => fetch_netease(input),
        "qq" => fetch_qq(input),
        "youtube" => fetch_youtube(input),
        "apple" => fetch_apple(input),
        "spotify" => fetch_spotify(input),
        _ => Err(format!("不支持的歌单来源：{source}")),
    }
}

// ---------------------------------------------------------------- 网络基础

fn http_client() -> Result<Client, String> {
    Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(TOTAL_TIMEOUT)
        .redirect(reqwest::redirect::Policy::limited(6))
        .build()
        .map_err(|_| "无法初始化网络客户端".to_string())
}

struct Page {
    url: Url,
    body: String,
}

fn network_error(error: reqwest::Error) -> String {
    if error.is_timeout() {
        "请求超时：请检查网络或代理后重试".into()
    } else if error.is_connect() {
        "无法连接平台服务器：请检查网络或代理设置".into()
    } else {
        "网络请求失败，请稍后重试".into()
    }
}

fn url_error() -> String {
    "平台地址无效".into()
}

fn status_error(status: reqwest::StatusCode) -> String {
    match status.as_u16() {
        401 | 403 => format!("平台拒绝访问（HTTP {status}）：歌单可能需要登录"),
        404 => format!("歌单不存在或已删除（HTTP {status}）"),
        429 => format!("请求过于频繁，平台限流（HTTP {status}）：请稍后再试"),
        _ => format!("平台返回异常状态（HTTP {status}）"),
    }
}

fn finish(response: Response) -> Result<Page, String> {
    let status = response.status();
    let url = response.url().clone();
    if !status.is_success() {
        return Err(status_error(status));
    }
    let mut body = Vec::new();
    response
        .take(MAX_BODY + 1)
        .read_to_end(&mut body)
        .map_err(|_| "读取歌单内容失败：网络中断".to_string())?;
    if body.len() as u64 > MAX_BODY {
        return Err("歌单内容超过 12 MB，已停止抓取".into());
    }
    let body = String::from_utf8(body).map_err(|_| "歌单页面不是 UTF-8 文本".to_string())?;
    Ok(Page { url, body })
}

fn get_page(
    client: &Client,
    url: Url,
    referer: Option<&str>,
    headers: &[(&str, &str)],
) -> Result<Page, String> {
    let mut request = client.get(url).header(header::USER_AGENT, USER_AGENT);
    if let Some(referer) = referer {
        request = request.header(header::REFERER, referer);
    }
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    finish(request.send().map_err(network_error)?)
}

fn post_youtube_json(client: &Client, url: Url, body: &Value) -> Result<Page, String> {
    let request = client
        .post(url)
        .header(header::USER_AGENT, USER_AGENT)
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::ACCEPT, "application/json")
        .header(header::ORIGIN, "https://www.youtube.com")
        .header(header::REFERER, "https://www.youtube.com/")
        .json(body);
    finish(request.send().map_err(network_error)?)
}

fn parse_json(body: &str, label: &str) -> Result<Value, String> {
    serde_json::from_str(body)
        .map_err(|_| format!("{label}返回的不是 JSON：可能触发了验证页，或接口已变更"))
}

fn append_note(note: &mut String, extra: &str) {
    if !note.is_empty() {
        note.push('；');
    }
    note.push_str(extra);
}

fn cap_tracks(tracks: &mut Vec<ImportedTrack>, note: &mut String) {
    if tracks.len() > MAX_TRACKS {
        tracks.truncate(MAX_TRACKS);
        append_note(note, &format!("曲目超过 {MAX_TRACKS} 首，已截断"));
    }
}

fn imported(title: impl Into<String>, artist: impl Into<String>, duration: f64) -> ImportedTrack {
    ImportedTrack {
        title: title.into(),
        artist: artist.into(),
        album: String::new(),
        duration: duration.max(0.0),
        file_name: None,
        segment_start: None,
        segment_end: None,
        number: 0,
    }
}

/// 从链接或纯 ID 里取出平台 ID。
fn id_candidate(input: &str, key: &str) -> String {
    let text = input.trim();
    let needle = format!("{key}=");
    if let Some(position) = text.find(&needle) {
        let value: String = text[position + needle.len()..]
            .chars()
            .take_while(|ch| ch.is_ascii_alphanumeric() || *ch == '-' || *ch == '_')
            .collect();
        if !value.is_empty() {
            return value;
        }
    }
    let without_query = text.split(['?', '#']).next().unwrap_or("").trim();
    without_query
        .rsplit(['/', ':'])
        .next()
        .unwrap_or(without_query)
        .trim()
        .to_string()
}

fn playlist_id(
    input: &str,
    keys: &[&str],
    digits_only: bool,
    label: &str,
) -> Result<String, String> {
    let candidate = keys
        .iter()
        .map(|key| id_candidate(input, key))
        .find(|value| !value.is_empty())
        .unwrap_or_default();
    if candidate.is_empty() {
        return Err(format!("请填写{label} ID 或完整链接"));
    }
    if candidate.len() > 128 {
        return Err(format!("{label} ID 过长"));
    }
    let valid = candidate.chars().all(|ch| {
        if digits_only {
            ch.is_ascii_digit()
        } else {
            ch.is_ascii_alphanumeric() || ch == '-' || ch == '_'
        }
    });
    if !valid {
        return Err(format!("{label} ID 格式不正确：{candidate}"));
    }
    Ok(candidate)
}

// ---------------------------------------------------------------- 网易云

fn fetch_netease(input: &str) -> Result<ImportedPlaylist, String> {
    let id = playlist_id(input, &["id"], true, "网易云歌单")?;
    let client = http_client()?;
    let mut url =
        Url::parse("https://music.163.com/api/v6/playlist/detail").map_err(|_| url_error())?;
    url.query_pairs_mut()
        .append_pair("id", &id)
        .append_pair("n", "1000")
        .append_pair("s", "0");
    let page = get_page(&client, url, Some("https://music.163.com/"), &[])?;
    let detail = parse_json(&page.body, "网易云")?;
    let (name, mut ids) = parse_netease_detail(&detail)?;

    let mut note = String::new();
    if ids.len() > MAX_TRACKS {
        ids.truncate(MAX_TRACKS);
        append_note(&mut note, &format!("歌单超过 {MAX_TRACKS} 首，已截断"));
    }

    let mut songs: HashMap<String, ImportedTrack> = HashMap::new();
    for (batch, chunk) in ids.chunks(NETEASE_BATCH).enumerate() {
        let joined = format!("[{}]", chunk.join(","));
        let mut url =
            Url::parse("https://music.163.com/api/song/detail").map_err(|_| url_error())?;
        // query_pairs 会对方括号和逗号做 percent-encode，接口才认。
        url.query_pairs_mut().append_pair("ids", &joined);
        let page = get_page(&client, url, Some("https://music.163.com/"), &[])
            .map_err(|error| format!("网易云第 {} 批歌曲详情抓取失败：{error}", batch + 1))?;
        let value = parse_json(&page.body, "网易云歌曲详情")?;
        parse_netease_songs(&value, &mut songs)?;
    }

    let mut tracks = Vec::new();
    for (index, id) in ids.iter().enumerate() {
        if let Some(mut track) = songs.remove(id.as_str()) {
            track.number = index as u32 + 1;
            tracks.push(track);
        }
    }
    if tracks.is_empty() {
        return Err("网易云歌曲详情没有返回任何曲目：接口可能已变更，或该歌单需要登录".into());
    }
    let missing = ids.len().saturating_sub(tracks.len());
    if missing > 0 {
        append_note(
            &mut note,
            &format!("有 {missing} 首在歌曲详情接口里缺失，已跳过"),
        );
    }
    Ok(ImportedPlaylist {
        name,
        source: "netease".into(),
        tracks,
        note,
    })
}

fn parse_netease_detail(value: &Value) -> Result<(String, Vec<String>), String> {
    let playlist = value
        .get("playlist")
        .filter(|playlist| !playlist.is_null())
        .ok_or_else(|| "网易云没有返回歌单内容：歌单可能不存在、已删除或需要登录".to_string())?;
    let name = playlist
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .ok_or_else(|| "网易云歌单详情里缺少歌单名：接口结构可能已变化".to_string())?
        .to_string();
    let track_ids = playlist
        .get("trackIds")
        .and_then(Value::as_array)
        .ok_or_else(|| "网易云歌单详情里缺少 trackIds：接口结构可能已变化".to_string())?;
    let ids: Vec<String> = track_ids
        .iter()
        .filter_map(|item| item.get("id").and_then(id_text))
        .collect();
    if ids.is_empty() {
        return Err("网易云歌单里没有歌曲：歌单可能是空的".into());
    }
    Ok((name, ids))
}

fn parse_netease_songs(
    value: &Value,
    out: &mut HashMap<String, ImportedTrack>,
) -> Result<(), String> {
    if let Some(code) = value.get("code").and_then(Value::as_i64) {
        if code != 200 {
            return Err(format!("网易云歌曲详情返回错误码 {code}"));
        }
    }
    let songs = value
        .get("songs")
        .and_then(Value::as_array)
        .ok_or_else(|| "网易云歌曲详情里缺少 songs 字段：接口结构可能已变化".to_string())?;
    for song in songs {
        let Some(id) = song.get("id").and_then(id_text) else {
            continue;
        };
        let title = song
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string();
        if title.is_empty() {
            continue;
        }
        let artist = song
            .get("artists")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(|artist| artist.get("name").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("/")
            })
            .unwrap_or_default();
        let album = song
            .get("album")
            .and_then(|album| album.get("name"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let duration = song.get("duration").and_then(Value::as_f64).unwrap_or(0.0) / 1000.0;
        let mut track = imported(title, artist, duration);
        track.album = album;
        out.insert(id, track);
    }
    Ok(())
}

fn id_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

// ---------------------------------------------------------------- QQ 音乐

fn fetch_qq(input: &str) -> Result<ImportedPlaylist, String> {
    let id = playlist_id(input, &["disstid", "id"], true, "QQ 音乐歌单")?;
    let client = http_client()?;
    let mut url = Url::parse("https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg")
        .map_err(|_| url_error())?;
    url.query_pairs_mut()
        .append_pair("type", "1")
        .append_pair("json", "1")
        .append_pair("utf8", "1")
        .append_pair("disstid", &id)
        .append_pair("format", "json");
    let page = get_page(&client, url, Some("https://y.qq.com/"), &[])?;
    let value = parse_json(&page.body, "QQ 音乐")?;
    parse_qq(&value)
}

fn parse_qq(value: &Value) -> Result<ImportedPlaylist, String> {
    let code = value.get("code").and_then(Value::as_i64).unwrap_or(0);
    let subcode = value.get("subcode").and_then(Value::as_i64).unwrap_or(0);
    if code == 10 {
        return Err("QQ 音乐歌单不存在或已删除".into());
    }
    if subcode == 4000 {
        return Err("QQ 音乐歌单是隐私或受限歌单，无法直接读取".into());
    }
    if code != 0 {
        return Err(format!(
            "QQ 音乐返回错误码 {code}：歌单可能不存在或接口已变更"
        ));
    }
    let cd = value
        .get("cdlist")
        .and_then(Value::as_array)
        .and_then(|list| list.first())
        .ok_or_else(|| "QQ 音乐没有返回歌单内容：歌单可能不存在或需要登录".to_string())?;
    let name = cd
        .get("dissname")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .ok_or_else(|| "QQ 音乐歌单详情里缺少歌单名：接口结构可能已变化".to_string())?
        .to_string();
    let songs = cd
        .get("songlist")
        .and_then(Value::as_array)
        .ok_or_else(|| "QQ 音乐歌单详情里缺少 songlist：接口结构可能已变化".to_string())?;

    let mut tracks = Vec::new();
    let mut skipped = 0usize;
    for (index, song) in songs.iter().enumerate() {
        let title = song
            .get("songname")
            .or_else(|| song.get("name"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string();
        if title.is_empty() {
            skipped += 1;
            continue;
        }
        let artist = song
            .get("singer")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(|singer| singer.get("name").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("/")
            })
            .unwrap_or_default();
        let album = song
            .get("albumname")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let duration = song
            .get("interval")
            .and_then(|interval| {
                interval
                    .as_f64()
                    .or_else(|| interval.as_str().and_then(|text| text.parse().ok()))
            })
            .unwrap_or(0.0);
        let mut track = imported(title, artist, duration);
        track.album = album;
        track.number = index as u32 + 1;
        tracks.push(track);
    }
    if tracks.is_empty() {
        return Err("QQ 音乐歌单里没有可用曲目（歌名全部缺失或歌单为空）".into());
    }
    let mut note = String::new();
    if skipped > 0 {
        append_note(&mut note, &format!("有 {skipped} 首缺少歌名，已跳过"));
    }
    cap_tracks(&mut tracks, &mut note);
    Ok(ImportedPlaylist {
        name,
        source: "qq".into(),
        tracks,
        note,
    })
}

// ---------------------------------------------------------------- YouTube

fn fetch_youtube(input: &str) -> Result<ImportedPlaylist, String> {
    let id = playlist_id(input, &["list"], false, "YouTube 播放列表")?;
    let client = http_client()?;
    let mut url = Url::parse("https://www.youtube.com/playlist").map_err(|_| url_error())?;
    url.query_pairs_mut()
        .append_pair("list", &id)
        .append_pair("hl", "zh-CN");
    let page = get_page(
        &client,
        url,
        Some("https://www.youtube.com/"),
        &[("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")],
    )?;

    let initial_text = extract_json_after(&page.body, "ytInitialData")
        .ok_or_else(|| "YouTube 页面结构已变化：找不到 ytInitialData".to_string())?;
    let initial: Value = serde_json::from_str(&initial_text)
        .map_err(|_| "YouTube 的 ytInitialData 不是合法 JSON：页面可能触发了验证".to_string())?;

    let mut tracks = Vec::new();
    let mut seen = HashSet::new();
    collect_youtube_tracks(&initial, &mut tracks, &mut seen);
    let mut note = String::new();

    let api_key = json_string_field(&page.body, "INNERTUBE_API_KEY");
    let client_version = json_string_field(&page.body, "INNERTUBE_CLIENT_VERSION");
    let token = youtube_continuation_token(&initial);

    match (api_key, client_version, token) {
        (Some(api_key), Some(client_version), Some(mut token)) => {
            for _ in 0..MAX_PAGES {
                if tracks.len() >= MAX_TRACKS {
                    break;
                }
                let body = serde_json::json!({
                    "context": {
                        "client": {
                            "clientName": "WEB",
                            "clientVersion": client_version,
                            "hl": "zh-CN"
                        }
                    },
                    "continuation": token
                });
                let mut url = Url::parse("https://www.youtube.com/youtubei/v1/browse")
                    .map_err(|_| url_error())?;
                url.query_pairs_mut()
                    .append_pair("key", &api_key)
                    .append_pair("prettyPrint", "false");
                let page = post_youtube_json(&client, url, &body)
                    .map_err(|error| format!("YouTube 续页抓取失败：{error}"))?;
                let value = parse_json(&page.body, "YouTube 续页")?;
                let before = tracks.len();
                collect_youtube_tracks(&value, &mut tracks, &mut seen);
                let next = youtube_continuation_token(&value);
                if tracks.len() == before || next.as_deref() == Some(token.as_str()) {
                    break;
                }
                let Some(next) = next else { break };
                token = next;
            }
        }
        _ => append_note(&mut note, "只抓到首屏曲目：页面缺少续页参数"),
    }

    if tracks.is_empty() {
        return Err("YouTube 歌单里没有解析到曲目：歌单可能为空、私享，或页面结构已变化".into());
    }
    cap_tracks(&mut tracks, &mut note);
    Ok(ImportedPlaylist {
        name: youtube_name(&page.body, &initial),
        source: "youtube".into(),
        tracks,
        note,
    })
}

fn collect_youtube_tracks(value: &Value, out: &mut Vec<ImportedTrack>, seen: &mut HashSet<String>) {
    match value {
        Value::Object(map) => {
            if let Some(lockup) = map.get("lockupViewModel") {
                if let Some((key, mut track)) = youtube_lockup_track(lockup) {
                    if seen.insert(key) {
                        track.number = out.len() as u32 + 1;
                        out.push(track);
                    }
                }
                return;
            }
            if let Some(video) = map.get("playlistVideoRenderer") {
                if let Some((key, mut track)) = youtube_video_track(video) {
                    if seen.insert(key) {
                        track.number = out.len() as u32 + 1;
                        out.push(track);
                    }
                }
                return;
            }
            for child in map.values() {
                collect_youtube_tracks(child, out, seen);
            }
        }
        Value::Array(list) => {
            for child in list {
                collect_youtube_tracks(child, out, seen);
            }
        }
        _ => {}
    }
}

/// 新版页面：lockupViewModel。
fn youtube_lockup_track(value: &Value) -> Option<(String, ImportedTrack)> {
    let raw_title = value
        .pointer("/metadata/lockupMetadataViewModel/title/content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if raw_title.is_empty() {
        return None;
    }
    let artist = value
        .pointer("/metadata/lockupMetadataViewModel/metadataRows/0/metadataParts/0/text/content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    let duration = deep_find(value, "badges")
        .and_then(Value::as_array)
        .and_then(|badges| {
            badges.iter().find_map(|badge| {
                badge
                    .get("thumbnailBadgeViewModel")
                    .and_then(|badge| badge.get("text"))
                    .and_then(Value::as_str)
            })
        })
        .or_else(|| {
            deep_find(value, "thumbnailBadgeViewModel")
                .and_then(|badge| badge.get("text"))
                .and_then(Value::as_str)
        })
        .map(parse_duration_text)
        .unwrap_or(0.0);
    let (title, artist) = youtube_clean_title(raw_title, &artist);
    let key = value
        .get("contentId")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| format!("{title}|{artist}"));
    Some((key, imported(title, artist, duration)))
}

/// 旧版页面：playlistVideoRenderer，字段映射与 lockup 一致。
fn youtube_video_track(value: &Value) -> Option<(String, ImportedTrack)> {
    let raw_title = value
        .pointer("/title/runs/0/text")
        .or_else(|| value.pointer("/title/simpleText"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if raw_title.is_empty() {
        return None;
    }
    let artist = value
        .pointer("/shortBylineText/runs/0/text")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    let duration = value
        .pointer("/lengthText/simpleText")
        .and_then(Value::as_str)
        .map(parse_duration_text)
        .unwrap_or(0.0);
    let (title, artist) = youtube_clean_title(raw_title, &artist);
    let key = value
        .get("videoId")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| format!("{title}|{artist}"));
    Some((key, imported(title, artist, duration)))
}

/// 去括号与 official/video/lyrics/audio 等噪音；标题里带艺人前缀时拆出来。
fn youtube_clean_title(raw: &str, artist: &str) -> (String, String) {
    let mut cleaned = strip_brackets(raw);
    cleaned = strip_noise_words(&cleaned);
    let mut title = cleaned.trim().to_string();
    let mut artist = artist.trim().to_string();
    if let Some((left, right)) = split_artist_title(&title) {
        let artist_norm = normalize(&artist);
        if artist.is_empty() {
            artist = left.clone();
            title = right;
        } else if !artist_norm.is_empty() && similarity(&normalize(&left), &artist_norm) >= 0.8 {
            title = right;
        } else if !artist_norm.is_empty() && similarity(&normalize(&right), &artist_norm) >= 0.8 {
            // 少数标题写成 "歌名 - 艺人"。
            title = left;
        }
    }
    if title.is_empty() {
        title = raw.trim().to_string();
    }
    (title, artist)
}

fn strip_brackets(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut depth = 0u32;
    for ch in text.chars() {
        match ch {
            '(' | '[' | '【' | '（' | '〔' => depth += 1,
            ')' | ']' | '】' | '）' | '〕' => depth = depth.saturating_sub(1),
            _ if depth > 0 => {}
            _ => out.push(ch),
        }
    }
    out
}

fn strip_noise_words(text: &str) -> String {
    const NOISE: [&str; 14] = [
        "official",
        "video",
        "lyrics",
        "lyric",
        "audio",
        "mv",
        "m/v",
        "hd",
        "4k",
        "高清",
        "官方",
        "完整版",
        "超清",
        "高音质",
    ];
    let tokens: Vec<&str> = text
        .split_whitespace()
        .filter(|token| {
            let normalized = token
                .trim_matches(|ch: char| !ch.is_alphanumeric())
                .to_lowercase();
            if normalized.is_empty() {
                // 保留 " - " 分隔符，后面还要靠它拆艺人。
                return matches!(*token, "-" | "–" | "—");
            }
            !NOISE.contains(&normalized.as_str())
        })
        .collect();
    tokens.join(" ")
}

fn split_artist_title(text: &str) -> Option<(String, String)> {
    for separator in [" - ", " – ", " — ", "－"] {
        if let Some((left, right)) = text.split_once(separator) {
            let left = left.trim();
            let right = right.trim();
            if !left.is_empty() && !right.is_empty() {
                return Some((left.to_string(), right.to_string()));
            }
        }
    }
    None
}

/// "4:05" / "1:02:33" → 秒。
fn parse_duration_text(text: &str) -> f64 {
    let parts: Vec<&str> = text.trim().split(':').collect();
    if parts.is_empty() || parts.len() > 3 {
        return 0.0;
    }
    let mut seconds = 0.0;
    for part in parts {
        let Ok(value) = part.trim().parse::<f64>() else {
            return 0.0;
        };
        seconds = seconds * 60.0 + value;
    }
    seconds.max(0.0)
}

fn youtube_name(html: &str, initial: &Value) -> String {
    let title = initial
        .pointer("/header/pageHeaderRenderer/pageTitle")
        .and_then(text_value)
        .or_else(|| meta_content(html, "og:title"))
        .unwrap_or_else(|| "YouTube 歌单".to_string());
    let trimmed = trim_music_suffix(&title);
    if trimmed.is_empty() {
        "YouTube 歌单".into()
    } else {
        trimmed
    }
}

fn text_value(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Object(map) => map
            .get("content")
            .and_then(Value::as_str)
            .or_else(|| map.get("simpleText").and_then(Value::as_str))
            .or_else(|| {
                map.get("runs")
                    .and_then(Value::as_array)
                    .and_then(|runs| runs.first())
                    .and_then(|run| run.get("text"))
                    .and_then(Value::as_str)
            })
            .map(str::to_string),
        _ => None,
    }
}

fn trim_music_suffix(name: &str) -> String {
    let mut out = name.trim().to_string();
    for suffix in [
        " - Apple Music",
        " on Apple Music",
        " - YouTube Music",
        " - YouTube",
        " | Spotify",
    ] {
        if let Some(rest) = out.strip_suffix(suffix) {
            out = rest.trim_end().to_string();
        }
    }
    out
}

fn meta_content(html: &str, key: &str) -> Option<String> {
    let mut cursor = 0usize;
    while let Some(position) = html[cursor..].find("<meta") {
        let start = cursor + position;
        let end = start + html[start..].find('>')?;
        let tag = &html[start..end];
        let matches = tag.contains(&format!("property=\"{key}\""))
            || tag.contains(&format!("name=\"{key}\""));
        if matches {
            if let Some(content) = tag.find("content=\"") {
                let value = &tag[content + 9..];
                if let Some(quote) = value.find('"') {
                    return Some(html_unescape(&value[..quote]));
                }
            }
        }
        cursor = end + 1;
    }
    None
}

fn html_unescape(text: &str) -> String {
    text.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

// ---------------------------------------------------------------- Apple Music

fn fetch_apple(input: &str) -> Result<ImportedPlaylist, String> {
    let url = Url::parse(input.trim())
        .map_err(|_| "Apple Music 链接格式不正确：请粘贴 music.apple.com 的完整链接".to_string())?;
    let host = url.host_str().unwrap_or("");
    if !host.ends_with("music.apple.com") {
        return Err("请粘贴 music.apple.com 的歌单链接".into());
    }
    if url.path().trim_end_matches('/').ends_with("/new") {
        return Err(
            "这个链接指向 Apple Music 的「新建歌单」页，无法导入：请打开具体歌单后复制链接".into(),
        );
    }
    let client = http_client()?;
    let page = get_page(
        &client,
        url,
        Some("https://music.apple.com/"),
        &[("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")],
    )?;
    if page.url.path().trim_end_matches('/').ends_with("/new") {
        return Err(
            "链接被重定向到 Apple Music 的「新建歌单」页，无法导入：请打开具体歌单后复制链接"
                .into(),
        );
    }
    parse_apple(&page.body)
}

fn parse_apple(html: &str) -> Result<ImportedPlaylist, String> {
    let blocks = script_json_blocks(html, "serialized-server-data");
    if blocks.is_empty() {
        return Err(
            "Apple Music 页面结构已变化：找不到 serialized-server-data，请改用「粘贴文本」导入"
                .into(),
        );
    }
    let mut name = String::new();
    let mut tracks = Vec::new();
    let mut seen = HashSet::new();
    let mut parsed = false;
    for block in blocks {
        let Ok(value) = serde_json::from_str::<Value>(&block) else {
            continue;
        };
        parsed = true;
        apple_collect(&value, &mut name, &mut tracks, &mut seen);
    }
    if !parsed {
        return Err("Apple Music 页面数据不是合法 JSON，请改用「粘贴文本」导入".into());
    }
    if tracks.is_empty() {
        return Err(
            "Apple Music 页面里没有解析到曲目：链接可能不是歌单、所在地区不可用，或页面结构已变化"
                .into(),
        );
    }
    if name.is_empty() {
        name = meta_content(html, "og:title")
            .map(|title| trim_music_suffix(&title))
            .filter(|title| !title.is_empty())
            .unwrap_or_else(|| "Apple Music 歌单".into());
    }
    let mut note = String::new();
    cap_tracks(&mut tracks, &mut note);
    Ok(ImportedPlaylist {
        name,
        source: "apple".into(),
        tracks,
        note,
    })
}

fn apple_collect(
    value: &Value,
    name: &mut String,
    tracks: &mut Vec<ImportedTrack>,
    seen: &mut HashSet<String>,
) {
    for section in apple_sections(value) {
        let item_kind = section
            .get("itemKind")
            .and_then(Value::as_str)
            .unwrap_or("");
        let Some(items) = section.get("items").and_then(Value::as_array) else {
            continue;
        };
        match item_kind {
            "containerDetailHeaderLockup" => {
                if name.is_empty() {
                    if let Some(title) = items
                        .first()
                        .and_then(|item| item.get("title"))
                        .and_then(Value::as_str)
                    {
                        *name = title.trim().to_string();
                    }
                }
            }
            "trackLockup" => {
                for item in items {
                    let title = item
                        .get("title")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .trim();
                    if title.is_empty() {
                        continue;
                    }
                    let artist = item
                        .get("artistName")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let duration =
                        item.get("duration").and_then(Value::as_f64).unwrap_or(0.0) / 1000.0;
                    let album = item
                        .get("tertiaryLinks")
                        .and_then(Value::as_array)
                        .and_then(|links| links.first())
                        .and_then(|link| link.get("title"))
                        .and_then(Value::as_str)
                        .map(trim_album_suffix)
                        .unwrap_or_default();
                    let key = format!("{title}|{artist}");
                    if !seen.insert(key) {
                        continue;
                    }
                    let mut track = imported(title, artist, duration);
                    track.album = album;
                    track.number = tracks.len() as u32 + 1;
                    tracks.push(track);
                }
            }
            _ => {}
        }
    }
}

fn apple_sections(value: &Value) -> &[Value] {
    const EMPTY: &[Value] = &[];
    let page_data = match value {
        Value::Array(list) => list.first().and_then(|entry| entry.get("data")),
        Value::Object(map) => map
            .get("data")
            .and_then(Value::as_array)
            .and_then(|list| list.first())
            .and_then(|entry| entry.get("data")),
        _ => None,
    };
    page_data
        .and_then(|data| data.get("sections"))
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(EMPTY)
}

fn trim_album_suffix(title: &str) -> String {
    let title = title.trim();
    for suffix in [" - Single", " - EP", " - Album"] {
        if let Some(rest) = title.strip_suffix(suffix) {
            return rest.trim_end().to_string();
        }
    }
    title.to_string()
}

// ---------------------------------------------------------------- Spotify

fn fetch_spotify(input: &str) -> Result<ImportedPlaylist, String> {
    let id = playlist_id(input, &["playlist"], false, "Spotify 歌单")?;
    let client = http_client()?;
    let mut url =
        Url::parse("https://open.spotify.com/embed/playlist/").map_err(|_| url_error())?;
    url.path_segments_mut().map_err(|_| url_error())?.push(&id);
    // 该主机限流时会直接 RST，不做重试。
    let page = get_page(&client, url, Some("https://open.spotify.com/"), &[]).map_err(|_| {
        "Spotify 公开页面打不开（可能被限流或需要登录），请改用「粘贴文本」导入".to_string()
    })?;
    let Some(script) = script_json_block(&page.body, "__NEXT_DATA__") else {
        return Err("Spotify 页面结构已变化：找不到 __NEXT_DATA__，请改用「粘贴文本」导入".into());
    };
    let value: Value = serde_json::from_str(&script)
        .map_err(|_| "Spotify 页面数据不是合法 JSON，请改用「粘贴文本」导入".to_string())?;
    parse_spotify(&value)
}

fn parse_spotify(value: &Value) -> Result<ImportedPlaylist, String> {
    let entity = find_spotify_entity(value).ok_or_else(|| {
        "Spotify 嵌入页里没有歌单数据：歌单可能为空或私享，请改用「粘贴文本」导入".to_string()
    })?;
    let name = entity
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .unwrap_or("Spotify 歌单")
        .to_string();
    let list = entity
        .get("trackList")
        .and_then(Value::as_array)
        .ok_or_else(|| "Spotify 嵌入页缺少 trackList，请改用「粘贴文本」导入".to_string())?;
    let mut tracks = Vec::new();
    let mut skipped = 0usize;
    for item in list.iter().take(SPOTIFY_LIMIT) {
        let title = item
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if title.is_empty() {
            skipped += 1;
            continue;
        }
        let artist = item
            .get("subtitle")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let duration = item.get("duration").and_then(Value::as_f64).unwrap_or(0.0) / 1000.0;
        let mut track = imported(title, artist, duration);
        track.number = tracks.len() as u32 + 1;
        tracks.push(track);
    }
    if tracks.is_empty() {
        return Err(
            "Spotify 嵌入页没有返回曲目：歌单可能为空或私享，请改用「粘贴文本」导入".into(),
        );
    }
    let mut note = if list.len() > SPOTIFY_LIMIT {
        format!("Spotify 公开嵌入页最多提供 {SPOTIFY_LIMIT} 首，超出部分不会导入")
    } else {
        String::new()
    };
    if skipped > 0 {
        append_note(&mut note, &format!("有 {skipped} 首缺少歌名，已跳过"));
    }
    Ok(ImportedPlaylist {
        name,
        source: "spotify".into(),
        tracks,
        note,
    })
}

fn find_spotify_entity(value: &Value) -> Option<&Value> {
    match value {
        Value::Object(map) => {
            if map.get("trackList").is_some_and(Value::is_array) && map.contains_key("name") {
                return Some(value);
            }
            map.values().find_map(find_spotify_entity)
        }
        Value::Array(list) => list.iter().find_map(find_spotify_entity),
        _ => None,
    }
}

// ---------------------------------------------------------------- 页面脚本工具

/// 取 script 标签（按 id）里的 JSON，取第一个。
fn script_json_block(html: &str, id: &str) -> Option<String> {
    script_json_blocks(html, id).into_iter().next()
}

fn script_json_blocks(html: &str, id: &str) -> Vec<String> {
    let marker = format!("id=\"{id}\"");
    let mut blocks = Vec::new();
    let mut cursor = 0usize;
    while let Some(position) = html[cursor..].find("<script") {
        let start = cursor + position;
        let Some(relative_end) = html[start..].find('>') else {
            break;
        };
        let end = start + relative_end;
        let tag = &html[start..end];
        if tag.contains(&marker) {
            let body_start = end + 1;
            if let Some(relative_close) = html[body_start..].find("</script>") {
                let body_end = body_start + relative_close;
                let body = html[body_start..body_end].trim();
                if !body.is_empty() {
                    blocks.push(body.to_string());
                }
                cursor = body_end + "</script>".len();
                continue;
            }
        }
        cursor = end + 1;
    }
    blocks
}

fn extract_json_after(text: &str, marker: &str) -> Option<String> {
    let start = text.find(marker)?;
    let brace = text[start..].find('{')? + start;
    balanced_json(text, brace).map(str::to_string)
}

/// 从 start 处的左花括号起按括号配对切出完整 JSON（跳过字符串里的括号）。
fn balanced_json(text: &str, start: usize) -> Option<&str> {
    let bytes = text.as_bytes();
    if bytes.get(start) != Some(&b'{') {
        return None;
    }
    let mut depth = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    for (offset, &byte) in bytes.iter().enumerate().skip(start) {
        if in_string {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                in_string = false;
            }
            continue;
        }
        match byte {
            b'"' => in_string = true,
            b'{' | b'[' => depth += 1,
            b'}' | b']' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return text.get(start..=offset);
                }
            }
            _ => {}
        }
    }
    None
}

/// 在页面源码里找 "KEY":"value"（YouTube 的 INNERTUBE_* 参数）。
fn json_string_field(text: &str, name: &str) -> Option<String> {
    let marker = format!("\"{name}\"");
    let mut cursor = 0usize;
    while let Some(position) = text[cursor..].find(&marker) {
        let after_key = cursor + position + marker.len();
        let after = &text[after_key..];
        if let Some(colon) = after.find(':') {
            let value = after[colon + 1..].trim_start();
            if let Some(rest) = value.strip_prefix('"') {
                if let Some(quote) = rest.find('"') {
                    return Some(rest[..quote].to_string());
                }
            }
        }
        cursor = after_key;
    }
    None
}

/// 续页 token 的实际位置随页面版本变化：
/// 新版 continuationItemViewModel.continuationCommand.innertubeCommand.continuationCommand.token，
/// 旧版 continuationItemRenderer.continuationEndpoint.continuationCommand.token。
/// 两种都在内层才带 token，所以只认带 token 的那个 continuationCommand。
fn youtube_continuation_token(value: &Value) -> Option<String> {
    fn walk(value: &Value) -> Option<String> {
        match value {
            Value::Object(map) => {
                if let Some(token) = map
                    .get("continuationCommand")
                    .and_then(|command| command.get("token"))
                    .and_then(Value::as_str)
                    .filter(|token| !token.is_empty())
                {
                    return Some(token.to_string());
                }
                map.values().find_map(walk)
            }
            Value::Array(list) => list.iter().find_map(walk),
            _ => None,
        }
    }
    walk(value)
}

fn deep_find<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    match value {
        Value::Object(map) => {
            if let Some(found) = map.get(key) {
                return Some(found);
            }
            map.values().find_map(|child| deep_find(child, key))
        }
        Value::Array(list) => list.iter().find_map(|child| deep_find(child, key)),
        _ => None,
    }
}

// ---------------------------------------------------------------- 文本 / 文件

fn parse_text(content: &str) -> Result<ImportedPlaylist, String> {
    let mut tracks = parse_text_tracks(content);
    if tracks.is_empty() {
        return Err("没有解析到任何曲目：请每行写「艺人 - 歌名」".into());
    }
    let mut note = String::new();
    cap_tracks(&mut tracks, &mut note);
    Ok(ImportedPlaylist {
        name: "粘贴的歌单".into(),
        source: "text".into(),
        tracks,
        note,
    })
}

fn parse_text_tracks(content: &str) -> Vec<ImportedTrack> {
    let content = content.trim_start_matches('\u{feff}');
    let mut tracks = Vec::new();
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = strip_line_number(line);
        if line.is_empty() {
            continue;
        }
        let (artist, title) =
            split_artist_title(line).unwrap_or_else(|| (String::new(), line.to_string()));
        let mut track = imported(title, artist, 0.0);
        track.number = tracks.len() as u32 + 1;
        tracks.push(track);
        if tracks.len() >= MAX_TRACKS {
            break;
        }
    }
    tracks
}

/// 去掉 "1. " / "2、" / "[3] " 这类行号前缀；不碰 "7 Rings" 这种以数字开头的歌名。
fn strip_line_number(line: &str) -> &str {
    let trimmed = line.trim_start();
    if let Some(rest) = trimmed.strip_prefix('[') {
        let digits_end = rest
            .find(|ch: char| !ch.is_ascii_digit())
            .unwrap_or(rest.len());
        if digits_end > 0 && rest[digits_end..].starts_with(']') {
            return rest[digits_end + 1..].trim_start();
        }
    }
    let digits_end = trimmed
        .find(|ch: char| !ch.is_ascii_digit())
        .unwrap_or(trimmed.len());
    if digits_end == 0 {
        return trimmed;
    }
    let rest = &trimmed[digits_end..];
    for separator in [".", "、", ")", "]", ":"] {
        if let Some(stripped) = rest.strip_prefix(separator) {
            return stripped.trim_start();
        }
    }
    trimmed
}

fn parse_file(file_name: &str, content: &str) -> Result<ImportedPlaylist, String> {
    let content = content.trim_start_matches('\u{feff}');
    if content.len() as u64 > MAX_BODY {
        return Err("歌单文件超过 12 MB，请拆分后再导入".into());
    }
    if content.trim().is_empty() {
        return Err("歌单文件是空的".into());
    }
    let name = file_stem(file_name);
    let extension = file_name
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
        .unwrap_or_default();
    match extension.as_str() {
        "m3u" | "m3u8" => parse_m3u(content, &name),
        "pls" => parse_pls(content, &name),
        "csv" => parse_csv(content, ',', &name),
        "tsv" => parse_csv(content, '\t', &name),
        "json" => parse_json_playlist(content, &name),
        "cue" => parse_cue(content, &name),
        "txt" => {
            let mut tracks = parse_text_tracks(content);
            if tracks.is_empty() {
                return Err("文本里没有解析到曲目：请每行写「艺人 - 歌名」".into());
            }
            let mut note = String::new();
            cap_tracks(&mut tracks, &mut note);
            Ok(ImportedPlaylist {
                name,
                source: "text".into(),
                tracks,
                note,
            })
        }
        _ => Err(format!(
            "不支持的文件类型：.{extension}，可用 m3u/m3u8、pls、csv/tsv、json、cue、txt"
        )),
    }
}

fn file_stem(path: &str) -> String {
    let base = path
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(path)
        .trim()
        .split(['?', '#'])
        .next()
        .unwrap_or(path);
    match base.rsplit_once('.') {
        Some((stem, extension)) if !stem.is_empty() && extension.len() <= 8 => stem.to_string(),
        _ => base.to_string(),
    }
}

fn parse_m3u(content: &str, name: &str) -> Result<ImportedPlaylist, String> {
    let mut tracks = Vec::new();
    let mut pending: Option<(f64, Option<String>)> = None;
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("#EXTINF:") {
            let (duration, title) = match rest.split_once(',') {
                Some((duration, title)) => (
                    duration.trim().parse::<f64>().unwrap_or(0.0),
                    Some(title.trim().to_string()).filter(|title| !title.is_empty()),
                ),
                None => (rest.trim().parse::<f64>().unwrap_or(0.0), None),
            };
            pending = Some((duration.max(0.0), title));
            continue;
        }
        if line.starts_with('#') {
            continue;
        }
        let mut track = imported(String::new(), String::new(), 0.0);
        track.file_name = Some(line.to_string());
        if let Some((duration, title)) = pending.take() {
            track.duration = duration.max(0.0);
            if let Some(title) = title {
                let (artist, title) = split_artist_title(&title)
                    .unwrap_or_else(|| (String::new(), title.to_string()));
                track.artist = artist;
                track.title = title;
            }
        }
        if track.title.is_empty() {
            track.title = file_stem(line);
        }
        if track.title.is_empty() {
            continue;
        }
        track.number = tracks.len() as u32 + 1;
        tracks.push(track);
        if tracks.len() >= MAX_TRACKS {
            break;
        }
    }
    if tracks.is_empty() {
        return Err("M3U 里没有解析到曲目：请确认文件包含 #EXTINF 或路径行".into());
    }
    let mut tracks = tracks;
    let mut note = String::new();
    cap_tracks(&mut tracks, &mut note);
    Ok(ImportedPlaylist {
        name: name.to_string(),
        source: "m3u".into(),
        tracks,
        note,
    })
}

fn parse_pls(content: &str, name: &str) -> Result<ImportedPlaylist, String> {
    let mut files: HashMap<u32, String> = HashMap::new();
    let mut titles: HashMap<u32, String> = HashMap::new();
    let mut lengths: HashMap<u32, f64> = HashMap::new();
    for raw in content.lines() {
        let line = raw.trim();
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim().to_ascii_lowercase();
        let value = value.trim();
        if let Some(index) = key
            .strip_prefix("file")
            .and_then(|suffix| suffix.parse::<u32>().ok())
        {
            files.insert(index, value.to_string());
        } else if let Some(index) = key
            .strip_prefix("title")
            .and_then(|suffix| suffix.parse::<u32>().ok())
        {
            if !value.is_empty() {
                titles.insert(index, value.to_string());
            }
        } else if let Some(index) = key
            .strip_prefix("length")
            .and_then(|suffix| suffix.parse::<u32>().ok())
        {
            lengths.insert(index, value.parse::<f64>().unwrap_or(0.0).max(0.0));
        }
    }
    let mut entries: Vec<(u32, String)> = files.into_iter().collect();
    entries.sort_by_key(|(index, _)| *index);
    let mut tracks = Vec::new();
    for (index, file) in entries {
        let mut track = imported(String::new(), String::new(), 0.0);
        track.file_name = Some(file.clone());
        track.duration = lengths.get(&index).copied().unwrap_or(0.0);
        match titles.remove(&index) {
            Some(title) => {
                let (artist, title) = split_artist_title(&title)
                    .unwrap_or_else(|| (String::new(), title.to_string()));
                track.artist = artist;
                track.title = title;
            }
            None => track.title = file_stem(&file),
        }
        if track.title.is_empty() {
            continue;
        }
        track.number = tracks.len() as u32 + 1;
        tracks.push(track);
        if tracks.len() >= MAX_TRACKS {
            break;
        }
    }
    if tracks.is_empty() {
        return Err("PLS 里没有解析到曲目：请确认文件包含 File1= 行".into());
    }
    let mut tracks = tracks;
    let mut note = String::new();
    cap_tracks(&mut tracks, &mut note);
    Ok(ImportedPlaylist {
        name: name.to_string(),
        source: "pls".into(),
        tracks,
        note,
    })
}

fn parse_csv(content: &str, delimiter: char, name: &str) -> Result<ImportedPlaylist, String> {
    let mut rows: Vec<Vec<String>> = content
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| split_delimited(line, delimiter))
        .collect();
    if rows.is_empty() {
        return Err("CSV 是空的".into());
    }
    let header = rows[0].clone();
    let column = |names: &[&str]| -> Option<usize> {
        header.iter().position(|cell| {
            let cell = cell.trim().to_ascii_lowercase();
            names.contains(&cell.as_str())
        })
    };
    let title_column = column(&["title", "name", "songname", "song", "歌名", "标题"]);
    let artist_column = column(&[
        "artist",
        "artistname",
        "singer",
        "performer",
        "艺人",
        "歌手",
    ]);
    let album_column = column(&["album", "albumname", "专辑"]);
    let duration_column = column(&["duration", "length", "seconds", "时长"]);
    let duration_ms_column = column(&["duration_ms", "durationms"]);
    let has_header = title_column.is_some() || artist_column.is_some() || album_column.is_some();
    let (title_column, artist_column, album_column, duration_column, duration_ms_column) =
        if has_header {
            rows.remove(0);
            (
                title_column.unwrap_or(0),
                artist_column,
                album_column,
                duration_column,
                duration_ms_column,
            )
        } else {
            (0, Some(1), Some(2), Some(3), None)
        };

    let cell = |row: &[String], index: usize| -> String {
        row.get(index)
            .map(|value| value.trim().to_string())
            .unwrap_or_default()
    };
    let mut tracks = Vec::new();
    for row in rows {
        let title = cell(&row, title_column);
        if title.is_empty() {
            continue;
        }
        let artist = artist_column
            .map(|index| cell(&row, index))
            .unwrap_or_default();
        let album = album_column
            .map(|index| cell(&row, index))
            .unwrap_or_default();
        let duration = if let Some(index) = duration_ms_column {
            cell(&row, index).parse::<f64>().unwrap_or(0.0) / 1000.0
        } else if let Some(index) = duration_column {
            let value = cell(&row, index).parse::<f64>().unwrap_or(0.0);
            // 没写单位的列：超过 5.5 小时的数值只可能是毫秒。
            if value > 20_000.0 {
                value / 1000.0
            } else {
                value
            }
        } else {
            0.0
        };
        let mut track = imported(title, artist, duration);
        track.album = album;
        track.number = tracks.len() as u32 + 1;
        tracks.push(track);
        if tracks.len() >= MAX_TRACKS {
            break;
        }
    }
    if tracks.is_empty() {
        return Err("CSV 里没有解析到曲目：请确认首行是表头或列顺序为 歌名,艺人,专辑,时长".into());
    }
    let mut tracks = tracks;
    let mut note = String::new();
    cap_tracks(&mut tracks, &mut note);
    Ok(ImportedPlaylist {
        name: name.to_string(),
        source: if delimiter == '\t' { "tsv" } else { "csv" }.into(),
        tracks,
        note,
    })
}

fn split_delimited(line: &str, delimiter: char) -> Vec<String> {
    let mut fields = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        if quoted {
            if ch == '"' {
                if chars.peek() == Some(&'"') {
                    chars.next();
                    field.push('"');
                } else {
                    quoted = false;
                }
            } else {
                field.push(ch);
            }
        } else if ch == '"' {
            quoted = true;
        } else if ch == delimiter {
            fields.push(field.trim().to_string());
            field.clear();
        } else {
            field.push(ch);
        }
    }
    fields.push(field.trim().to_string());
    fields
}

fn parse_json_playlist(content: &str, name: &str) -> Result<ImportedPlaylist, String> {
    let value: Value =
        serde_json::from_str(content).map_err(|error| format!("JSON 解析失败：{error}"))?;
    let (list, listed_name) = match &value {
        Value::Array(items) => (items.as_slice(), None),
        Value::Object(map) => {
            let list = map
                .get("tracks")
                .or_else(|| map.get("songs"))
                .or_else(|| map.get("items"))
                .and_then(Value::as_array)
                .ok_or_else(|| {
                    "JSON 里找不到曲目数组：需要顶层数组，或 tracks / songs / items 字段"
                        .to_string()
                })?;
            let listed_name = map
                .get("name")
                .or_else(|| map.get("title"))
                .and_then(Value::as_str)
                .map(str::to_string);
            (list.as_slice(), listed_name)
        }
        _ => return Err("JSON 结构不正确：需要数组或包含曲目数组的对象".into()),
    };
    let mut tracks = Vec::new();
    for (index, item) in list.iter().enumerate() {
        let title =
            json_any_string(item, &["title", "name", "songname", "song"]).unwrap_or_default();
        let title = title.trim().to_string();
        if title.is_empty() {
            continue;
        }
        let artist = json_artist(item);
        let album = json_any_string(item, &["album", "albumname", "albumName"]).unwrap_or_default();
        let duration = json_duration(item);
        let mut track = imported(title, artist, duration);
        track.album = album;
        track.file_name = json_any_string(item, &["file_name", "filename", "file", "path"]);
        track.segment_start = json_number(item, &["segment_start"]);
        track.segment_end = json_number(item, &["segment_end"]);
        track.number = json_number(item, &["number", "track_number"])
            .map(|number| number.max(0.0) as u32)
            .unwrap_or(index as u32 + 1);
        tracks.push(track);
        if tracks.len() >= MAX_TRACKS {
            break;
        }
    }
    if tracks.is_empty() {
        return Err("JSON 里没有可用曲目：每条记录至少要有 title / name".into());
    }
    let mut tracks = tracks;
    let mut note = String::new();
    cap_tracks(&mut tracks, &mut note);
    Ok(ImportedPlaylist {
        name: listed_name.unwrap_or_else(|| name.to_string()),
        source: "json".into(),
        tracks,
        note,
    })
}

fn json_any_string(value: &Value, keys: &[&str]) -> Option<String> {
    let map = value.as_object()?;
    keys.iter().find_map(|key| {
        map.get(*key).and_then(|value| match value {
            Value::String(text) => Some(text.clone()),
            Value::Number(number) => Some(number.to_string()),
            _ => None,
        })
    })
}

fn json_number(value: &Value, keys: &[&str]) -> Option<f64> {
    let map = value.as_object()?;
    keys.iter().find_map(|key| {
        map.get(*key).and_then(|value| {
            value
                .as_f64()
                .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
        })
    })
}

fn json_artist(value: &Value) -> String {
    let Some(map) = value.as_object() else {
        return String::new();
    };
    for key in [
        "artist",
        "artistName",
        "artistname",
        "performer",
        "singer",
        "singers",
        "artists",
    ] {
        let Some(entry) = map.get(key) else {
            continue;
        };
        if let Some(text) = entry.as_str() {
            if !text.trim().is_empty() {
                return text.trim().to_string();
            }
        }
        if let Some(list) = entry.as_array() {
            let names: Vec<String> = list
                .iter()
                .filter_map(|item| {
                    item.as_str()
                        .map(str::to_string)
                        .or_else(|| item.get("name").and_then(Value::as_str).map(str::to_string))
                })
                .collect();
            if !names.is_empty() {
                return names.join("/");
            }
        }
    }
    String::new()
}

fn json_duration(value: &Value) -> f64 {
    if let Some(milliseconds) = json_number(value, &["duration_ms", "durationMs"]) {
        return (milliseconds / 1000.0).max(0.0);
    }
    for key in ["duration", "length", "seconds", "duration_secs"] {
        if let Some(number) = json_number(value, &[key]) {
            // 无单位字段：超过 5.5 小时的数值按毫秒算。
            return if number > 20_000.0 {
                (number / 1000.0).max(0.0)
            } else {
                number.max(0.0)
            };
        }
    }
    0.0
}

// ---------------------------------------------------------------- CUE

struct CueEntry {
    number: u32,
    title: String,
    performer: String,
    file: Option<String>,
    start: f64,
}

fn parse_cue(content: &str, name: &str) -> Result<ImportedPlaylist, String> {
    let mut entries: Vec<CueEntry> = Vec::new();
    let mut current_file: Option<String> = None;
    let mut album_title = String::new();
    let mut album_performer = String::new();

    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let tokens = cue_tokens(line);
        let Some(keyword) = tokens.first().map(|token| token.to_ascii_uppercase()) else {
            continue;
        };
        match keyword.as_str() {
            "FILE" => current_file = tokens.get(1).cloned(),
            "TRACK" => {
                let number = tokens
                    .get(1)
                    .and_then(|token| token.parse::<u32>().ok())
                    .unwrap_or(entries.len() as u32 + 1);
                entries.push(CueEntry {
                    number,
                    title: String::new(),
                    performer: String::new(),
                    file: current_file.clone(),
                    start: 0.0,
                });
            }
            "TITLE" => {
                let Some(text) = tokens.get(1) else { continue };
                match entries.last_mut() {
                    Some(entry) => entry.title = text.clone(),
                    None => album_title = text.clone(),
                }
            }
            "PERFORMER" => {
                let Some(text) = tokens.get(1) else { continue };
                match entries.last_mut() {
                    Some(entry) => entry.performer = text.clone(),
                    None => album_performer = text.clone(),
                }
            }
            "INDEX" => {
                if tokens.get(1).map(String::as_str) != Some("01") {
                    continue;
                }
                let Some(stamp) = tokens.get(2) else { continue };
                let Some(seconds) = cue_time(stamp) else {
                    return Err(format!(
                        "CUE 时间码无法解析：{stamp}（应为 mm:ss:ff，ff 是 75 进制）"
                    ));
                };
                if let Some(entry) = entries.last_mut() {
                    entry.start = seconds;
                }
            }
            _ => {}
        }
    }

    if entries.is_empty() {
        return Err("CUE 里没有 TRACK 行，无法导入".into());
    }
    if entries.iter().all(|entry| entry.file.is_none()) {
        return Err("CUE 缺少 FILE 行，无法确定对应的整轨音频".into());
    }

    let mut tracks = Vec::new();
    for (index, entry) in entries.iter().enumerate() {
        let next_start = entries[index + 1..]
            .iter()
            .find(|next| next.file == entry.file)
            .map(|next| next.start);
        let end = next_start.filter(|end| *end > entry.start);
        let performer = if entry.performer.is_empty() {
            album_performer.clone()
        } else {
            entry.performer.clone()
        };
        tracks.push(ImportedTrack {
            title: if entry.title.is_empty() {
                format!("曲目 {}", entry.number)
            } else {
                entry.title.clone()
            },
            artist: performer,
            album: album_title.clone(),
            duration: end.map(|end| (end - entry.start).max(0.0)).unwrap_or(0.0),
            file_name: entry.file.clone(),
            segment_start: Some(entry.start),
            segment_end: end,
            number: entry.number,
        });
    }

    let playlist_name = if album_title.trim().is_empty() {
        name.to_string()
    } else {
        album_title
    };
    Ok(ImportedPlaylist {
        name: playlist_name,
        source: "cue".into(),
        tracks,
        note: "桌面版暂不支持 CUE 分轨播放，整轨需在库中；APE 需转 FLAC/ALAC".into(),
    })
}

fn cue_tokens(line: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    for ch in line.chars() {
        match ch {
            '"' => quoted = !quoted,
            ch if ch.is_whitespace() && !quoted => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            ch => current.push(ch),
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

/// mm:ss:ff（ff 为 75 帧/秒）→ 秒。
fn cue_time(stamp: &str) -> Option<f64> {
    let parts: Vec<&str> = stamp.split(':').collect();
    if parts.len() < 2 || parts.len() > 3 {
        return None;
    }
    let minutes: u32 = parts[0].parse().ok()?;
    let seconds: f64 = parts[1].parse().ok()?;
    let frames: f64 = if parts.len() == 3 {
        parts[2].parse().ok()?
    } else {
        0.0
    };
    if seconds >= 60.0 || frames >= 75.0 {
        return None;
    }
    Some(minutes as f64 * 60.0 + seconds + frames / 75.0)
}

// ---------------------------------------------------------------- 匹配

fn match_tracks(imported_tracks: &[ImportedTrack], library: &[Track]) -> Vec<ImportMatch> {
    let mut used: HashSet<String> = HashSet::new();
    let mut result = Vec::new();
    for imported_track in imported_tracks {
        let title = normalize(&imported_track.title);
        let artist = normalize(&imported_track.artist);
        let mut scored: Vec<(usize, f64)> = library
            .iter()
            .enumerate()
            .map(|(index, song)| {
                let title_similarity = similarity(&title, &normalize(&song.title));
                let artist_similarity = if artist.is_empty() {
                    0.0
                } else {
                    similarity(&artist, &normalize(&song.artist))
                };
                let duration_score = if imported_track.duration > 0.0
                    && song.duration > 0.0
                    && (imported_track.duration - song.duration).abs() <= DURATION_TOLERANCE
                {
                    1.0
                } else {
                    0.0
                };
                let score = TITLE_WEIGHT * title_similarity
                    + ARTIST_WEIGHT * artist_similarity
                    + DURATION_WEIGHT * duration_score;
                (index, round_score(score))
            })
            .collect();
        scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        let best = scored.first().copied();
        let chosen = scored.iter().copied().find(|(index, score)| {
            *score >= MATCH_THRESHOLD && !used.contains(&library[*index].id)
        });

        match chosen {
            Some((index, score)) => {
                let song = &library[index];
                used.insert(song.id.clone());
                result.push(ImportMatch {
                    track: imported_track.clone(),
                    song_id: Some(song.id.clone()),
                    score,
                    reason: confidence_reason(score).to_string(),
                });
            }
            None => {
                let reason = if library.is_empty() {
                    "未匹配：曲库为空，请先扫描本地音乐".to_string()
                } else if let Some((index, score)) = best {
                    let song = &library[index];
                    if score >= MATCH_THRESHOLD {
                        format!(
                            "未匹配：最接近的《{}》— {} 已被前面的曲目占用",
                            song.title, song.artist
                        )
                    } else {
                        format!(
                            "未匹配：最接近的是《{}》— {}（{:.2} 分，低于 {:.2}）",
                            song.title, song.artist, score, MATCH_THRESHOLD
                        )
                    }
                } else {
                    "未匹配：曲库里没有可比对的曲目".to_string()
                };
                result.push(ImportMatch {
                    track: imported_track.clone(),
                    song_id: None,
                    score: best.map(|(_, score)| score).unwrap_or(0.0),
                    reason,
                });
            }
        }
    }
    result
}

fn confidence_reason(score: f64) -> &'static str {
    if score >= 0.85 {
        "高置信度"
    } else if score >= 0.72 {
        "较可能"
    } else {
        "低置信度"
    }
}

fn round_score(score: f64) -> f64 {
    (score.clamp(0.0, 1.0) * 1000.0).round() / 1000.0
}

/// 去 feat 之后内容、括号内容、标点与大小写，供相似度比较。
fn normalize(text: &str) -> String {
    let lower = text.to_lowercase();
    let without_brackets = strip_brackets(&lower);
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
    const NOISE: [&str; 15] = [
        "official",
        "video",
        "lyrics",
        "lyric",
        "audio",
        "mv",
        "hd",
        "4k",
        "remaster",
        "remastered",
        "version",
        "live",
        "高清",
        "官方",
        "完整版",
    ];
    tokens
        .into_iter()
        .filter(|token| !NOISE.contains(token))
        .collect::<Vec<_>>()
        .join(" ")
}

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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn track(id: &str, title: &str, artist: &str, duration: f64) -> Track {
        Track {
            id: id.into(),
            title: title.into(),
            artist: artist.into(),
            album_artist: String::new(),
            album: String::new(),
            genre: String::new(),
            year: None,
            track_number: None,
            disc_number: None,
            duration,
            sample_rate: 44_100,
            bit_depth: 16,
            channels: 2,
            codec: "flac".into(),
            source_id: "src".into(),
            locator: format!("{id}.flac"),
            file_size: 0,
            modified: 0,
            artwork_path: None,
            play_count: 0,
            favorite: false,
            last_played: None,
            added_at: 0,
            is_remote: false,
            origin_url: None,
            comment: String::new(),
            lyrics: String::new(),
            media_info: None,
        }
    }

    #[test]
    fn text_parses_artist_title_and_line_numbers() {
        let content =
            "1. 周杰伦 - 晴天\n2、陈奕迅 - 十年\n[3] Adele - Hello\n\n# 注释行\n7 Rings\n";
        let playlist = parse_text(content).unwrap();
        assert_eq!(playlist.source, "text");
        assert_eq!(playlist.tracks.len(), 4, "注释与空行应跳过");
        assert_eq!(playlist.tracks[0].artist, "周杰伦");
        assert_eq!(playlist.tracks[0].title, "晴天");
        assert_eq!(playlist.tracks[1].artist, "陈奕迅");
        assert_eq!(playlist.tracks[2].artist, "Adele");
        assert_eq!(
            playlist.tracks[3].title, "7 Rings",
            "以数字开头的歌名不能被削掉"
        );
        assert_eq!(playlist.tracks[3].artist, "");
    }

    #[test]
    fn m3u_parses_extinf_and_files() {
        let content = "#EXTM3U\n#EXTINF:213,歌手 - 歌名\n/path/a.flac\n#EXTINF:-1,Radio\nhttps://example.com/stream\n";
        let playlist = parse_m3u(content, "我的 M3U").unwrap();
        assert_eq!(playlist.tracks.len(), 2);
        assert_eq!(playlist.tracks[0].artist, "歌手");
        assert_eq!(playlist.tracks[0].title, "歌名");
        assert_eq!(playlist.tracks[0].duration, 213.0);
        assert_eq!(
            playlist.tracks[0].file_name.as_deref(),
            Some("/path/a.flac")
        );
        assert_eq!(playlist.tracks[1].title, "Radio", "流媒体时长 -1 应归零");
        assert_eq!(playlist.tracks[1].duration, 0.0);
    }

    #[test]
    fn csv_parses_header_and_quoted_fields() {
        let content = "title,artist,album,duration\n\"Yellow, Pt. 1\",Coldplay,Parachutes,266\nFix You,Coldplay,X&Y,295\n";
        let playlist = parse_csv(content, ',', "my.csv").unwrap();
        assert_eq!(playlist.tracks.len(), 2);
        assert_eq!(playlist.tracks[0].title, "Yellow, Pt. 1");
        assert_eq!(playlist.tracks[0].artist, "Coldplay");
        assert_eq!(playlist.tracks[0].duration, 266.0);
        assert_eq!(playlist.tracks[1].album, "X&Y");
    }

    #[test]
    fn json_parses_wrapped_tracks() {
        let content = r#"{"name":"我的歌单","tracks":[{"title":"Yellow","artist":"Coldplay","duration":266},{"name":"Fix You","artist":"Coldplay","duration_ms":295000}]}"#;
        let playlist = parse_json_playlist(content, "x.json").unwrap();
        assert_eq!(playlist.name, "我的歌单");
        assert_eq!(playlist.tracks.len(), 2);
        assert_eq!(playlist.tracks[0].duration, 266.0);
        assert_eq!(playlist.tracks[1].title, "Fix You");
        assert_eq!(playlist.tracks[1].duration, 295.0);
    }

    #[test]
    fn cue_parses_75fps_and_next_track_end() {
        let content = "REM GENRE \"Rock\"\nPERFORMER \"专辑艺人\"\nTITLE \"专辑名\"\nFILE \"album.ape\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"第一首\"\n    PERFORMER \"歌手甲\"\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    TITLE \"第二首\"\n    INDEX 01 03:15:37\n";
        let playlist = parse_cue(content, "album.cue").unwrap();
        assert_eq!(playlist.name, "专辑名");
        assert_eq!(playlist.tracks.len(), 2);
        assert_eq!(playlist.tracks[0].file_name.as_deref(), Some("album.ape"));
        assert_eq!(playlist.tracks[0].segment_start, Some(0.0));
        let end = playlist.tracks[0].segment_end.unwrap();
        assert!(
            (end - (195.0 + 37.0 / 75.0)).abs() < 1e-6,
            "75 帧制换算错误：{end}"
        );
        assert!((playlist.tracks[0].duration - end).abs() < 1e-6);
        assert_eq!(playlist.tracks[1].segment_start, Some(end));
        assert_eq!(playlist.tracks[1].segment_end, None, "末轨没有终点");
        assert_eq!(
            playlist.tracks[1].artist, "专辑艺人",
            "缺 PERFORMER 时回退专辑艺人"
        );
        assert!(
            playlist.note.contains("CUE 分轨"),
            "应说明暂不支持 CUE 分轨"
        );
    }

    #[test]
    fn cue_requires_file_and_track() {
        assert!(parse_cue("TITLE \"x\"\n", "x.cue").is_err());
        assert!(parse_cue("FILE \"a.flac\" WAVE\n", "x.cue").is_err());
        assert!(parse_cue(
            "FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:99:00\n",
            "x.cue"
        )
        .is_err());
    }

    #[test]
    fn match_exact_track() {
        let library = vec![
            track("a", "Yellow", "Coldplay", 266.0),
            track("b", "Fix You", "Coldplay", 295.0),
        ];
        let matches = match_tracks(&[imported("Yellow", "Coldplay", 266.0)], &library);
        assert_eq!(matches[0].song_id.as_deref(), Some("a"));
        assert!((matches[0].score - 1.0).abs() < 1e-9);
        assert_eq!(matches[0].reason, "高置信度");
    }

    #[test]
    fn match_fuzzy_ignores_case_live_and_feat() {
        let library = vec![track("a", "Yellow", "Coldplay", 266.0)];
        let matches = match_tracks(
            &[imported(
                "YELLOW (Live) [Remastered]",
                "Coldplay feat. Rihanna",
                267.0,
            )],
            &library,
        );
        assert_eq!(matches[0].song_id.as_deref(), Some("a"));
        assert!(
            matches[0].score >= 0.99,
            "归一化后应几乎满分：{}",
            matches[0].score
        );
    }

    #[test]
    fn match_unmatched_reports_reason() {
        let library = vec![track("a", "Yellow", "Coldplay", 266.0)];
        let matches = match_tracks(&[imported("完全不同", "Nobody", 10.0)], &library);
        assert!(matches[0].song_id.is_none());
        assert!(
            matches[0].reason.contains("未匹配"),
            "{}",
            matches[0].reason
        );
        assert!(!matches[0].reason.is_empty());
    }

    #[test]
    fn match_empty_library_explains_scan_first() {
        let matches = match_tracks(&[imported("Yellow", "Coldplay", 266.0)], &[]);
        assert!(matches[0].song_id.is_none());
        assert!(
            matches[0].reason.contains("曲库为空"),
            "{}",
            matches[0].reason
        );
        assert_eq!(matches[0].score, 0.0);
    }

    #[test]
    fn match_does_not_reuse_same_song() {
        let library = vec![
            track("a", "Yellow", "Coldplay", 266.0),
            track("b", "Yellow", "Coldplay", 266.0),
        ];
        let matches = match_tracks(
            &[
                imported("Yellow", "Coldplay", 266.0),
                imported("Yellow", "Coldplay", 266.0),
            ],
            &library,
        );
        let first = matches[0].song_id.clone().unwrap();
        let second = matches[1].song_id.clone().unwrap();
        assert_ne!(first, second, "同一曲目不应被复用");
    }

    #[test]
    fn youtube_cleans_title_and_duration() {
        let (title, artist) = youtube_clean_title("Coldplay - Yellow (Official Video)", "Coldplay");
        assert_eq!(title, "Yellow");
        assert_eq!(artist, "Coldplay");
        let (title, artist) = youtube_clean_title("Hello - Adele", "Adele");
        assert_eq!(title, "Hello", "标题写成 歌名 - 艺人 也要认出来");
        assert_eq!(artist, "Adele");
        assert_eq!(parse_duration_text("4:05"), 245.0);
        assert_eq!(parse_duration_text("1:02:33"), 3753.0);

        let lockup = json!({
            "contentId": "abc",
            "metadata": {
                "lockupMetadataViewModel": {
                    "title": { "content": "Adele - Hello (Lyrics)" },
                    "metadataRows": [{
                        "metadataParts": [{ "text": { "content": "Adele" } }]
                    }]
                }
            },
            "contentImage": {
                "thumbnailViewModel": {
                    "overlays": [{
                        "thumbnailOverlayBadgeViewModel": {
                            "thumbnailBadges": [{
                                "thumbnailBadgeViewModel": { "text": "4:55" }
                            }]
                        }
                    }]
                }
            }
        });
        let (key, track) = youtube_lockup_track(&lockup).unwrap();
        assert_eq!(key, "abc");
        assert_eq!(track.title, "Hello");
        assert_eq!(track.artist, "Adele");
        assert_eq!(track.duration, 295.0);
    }

    #[test]
    fn youtube_collects_nested_lockups() {
        let data = json!({
            "contents": {
                "twoColumnBrowseResultsRenderer": {
                    "tabs": [{
                        "tabRenderer": {
                            "content": {
                                "sectionListRenderer": {
                                    "contents": [{
                                        "itemSectionRenderer": {
                                            "contents": [{
                                                "lockupViewModel": {
                                                    "contentId": "v1",
                                                    "metadata": {
                                                        "lockupMetadataViewModel": {
                                                            "title": { "content": "Song One" },
                                                            "metadataRows": [{
                                                                "metadataParts": [{ "text": { "content": "Artist" } }]
                                                            }]
                                                        }
                                                    }
                                                }
                                            }]
                                        }
                                    }]
                                }
                            }
                        }
                    }]
                }
            }
        });
        let mut tracks = Vec::new();
        let mut seen = HashSet::new();
        collect_youtube_tracks(&data, &mut tracks, &mut seen);
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].title, "Song One");
        assert_eq!(tracks[0].artist, "Artist");
        assert_eq!(tracks[0].number, 1, "曲目序号应从 1 开始");
    }

    #[test]
    fn youtube_continuation_token_reads_nested_command() {
        let data = json!({
            "contents": [{
                "itemSectionRenderer": {
                    "contents": [
                        { "lockupViewModel": { "contentId": "x" } },
                        {
                            "continuationItemViewModel": {
                                "continuationCommand": {
                                    "innertubeCommand": {
                                        "continuationCommand": { "token": "TOKEN" }
                                    }
                                }
                            }
                        }
                    ]
                }
            }]
        });
        assert_eq!(
            youtube_continuation_token(&data).as_deref(),
            Some("TOKEN"),
            "新版页面的 token 在 innertubeCommand 里"
        );
        assert_eq!(youtube_continuation_token(&json!({})), None);
        let legacy = json!({
            "continuationItemRenderer": {
                "continuationEndpoint": {
                    "continuationCommand": { "token": "OLD" }
                }
            }
        });
        assert_eq!(youtube_continuation_token(&legacy).as_deref(), Some("OLD"));
    }

    #[test]
    fn apple_parses_header_and_tracks() {
        let value = json!([{
            "data": {
                "sections": [
                    {
                        "itemKind": "containerDetailHeaderLockup",
                        "items": [{ "title": "我的 Apple 歌单" }]
                    },
                    {
                        "itemKind": "trackLockup",
                        "items": [{
                            "title": "Yellow",
                            "artistName": "Coldplay",
                            "duration": 266000,
                            "tertiaryLinks": [{ "title": "Parachutes - Album" }]
                        }]
                    }
                ]
            }
        }]);
        let mut name = String::new();
        let mut tracks = Vec::new();
        let mut seen = HashSet::new();
        apple_collect(&value, &mut name, &mut tracks, &mut seen);
        assert_eq!(name, "我的 Apple 歌单");
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].duration, 266.0);
        assert_eq!(tracks[0].album, "Parachutes");
        assert_eq!(trim_album_suffix("X - Single"), "X");
        assert_eq!(trim_album_suffix("Y - EP"), "Y");
    }

    #[test]
    fn spotify_parses_entity() {
        let value = json!({
            "props": {
                "pageProps": {
                    "state": {
                        "data": {
                            "entity": {
                                "name": "我的 Spotify 歌单",
                                "trackList": [{
                                    "title": "Yellow",
                                    "subtitle": "Coldplay",
                                    "duration": 266000
                                }]
                            }
                        }
                    }
                }
            }
        });
        let playlist = parse_spotify(&value).unwrap();
        assert_eq!(playlist.name, "我的 Spotify 歌单");
        assert_eq!(playlist.tracks.len(), 1);
        assert_eq!(playlist.tracks[0].duration, 266.0);
    }

    #[test]
    fn netease_parses_detail_and_songs() {
        let detail = json!({
            "playlist": {
                "name": "网易歌单",
                "trackIds": [{ "id": 1 }, { "id": 2 }]
            }
        });
        let (name, ids) = parse_netease_detail(&detail).unwrap();
        assert_eq!(name, "网易歌单");
        assert_eq!(ids, vec!["1".to_string(), "2".to_string()]);

        let songs = json!({
            "code": 200,
            "songs": [{
                "id": 1,
                "name": "晴天",
                "artists": [{ "name": "周杰伦" }],
                "album": { "name": "叶惠美" },
                "duration": 269000
            }]
        });
        let mut collected = HashMap::new();
        parse_netease_songs(&songs, &mut collected).unwrap();
        let song = collected.get("1").unwrap();
        assert_eq!(song.title, "晴天");
        assert_eq!(song.artist, "周杰伦");
        assert_eq!(song.album, "叶惠美");
        assert_eq!(song.duration, 269.0);
    }

    #[test]
    fn qq_reports_privacy_and_missing_playlist() {
        let private = json!({ "code": 0, "subcode": 4000, "cdlist": [] });
        let error = parse_qq(&private).unwrap_err();
        assert!(error.contains("隐私"), "{error}");

        let missing = json!({ "code": 10 });
        let error = parse_qq(&missing).unwrap_err();
        assert!(error.contains("不存在"), "{error}");

        let ok = json!({
            "code": 0,
            "cdlist": [{
                "dissname": "QQ 歌单",
                "songlist": [{
                    "songname": "晴天",
                    "singer": [{ "name": "周杰伦" }],
                    "albumname": "叶惠美",
                    "interval": 269
                }]
            }]
        });
        let playlist = parse_qq(&ok).unwrap();
        assert_eq!(playlist.name, "QQ 歌单");
        assert_eq!(playlist.tracks[0].artist, "周杰伦");
        assert_eq!(playlist.tracks[0].duration, 269.0);
    }

    #[test]
    fn cue_time_rejects_invalid_frames() {
        assert_eq!(cue_time("00:00:00"), Some(0.0));
        assert!((cue_time("01:02:38").unwrap() - 62.506666).abs() < 1e-5);
        assert_eq!(cue_time("00:00:75"), None, "75 帧已进位，不是合法帧号");
        assert_eq!(cue_time("00:60:00"), None);
        assert_eq!(cue_time("bad"), None);
    }

    #[test]
    fn normalize_strips_brackets_feat_and_punctuation() {
        assert_eq!(normalize("Yellow (Live) [Remastered]"), "yellow");
        assert_eq!(normalize("Coldplay feat. Rihanna"), "coldplay");
        assert_eq!(normalize("Fix You!!"), "fix you");
    }

    // ------------------------------------------------------------ 在线测试
    // 默认不跑：cargo test -p awake-app --lib playlist_import -- --ignored

    #[test]
    #[ignore = "在线测试：需要外网"]
    fn online_netease_playlist_fields() {
        let playlist = fetch_netease("2195404116").expect("网易云歌单抓取失败");
        println!(
            "[netease] name={} tracks={} note={}",
            playlist.name,
            playlist.tracks.len(),
            playlist.note
        );
        for track in playlist.tracks.iter().take(3) {
            println!(
                "[netease] {} / {} / {}s",
                track.title, track.artist, track.duration
            );
        }
        assert!(
            playlist.tracks.len() > 10,
            "应有 >10 首，实际 {}",
            playlist.tracks.len()
        );
        assert!(!playlist.name.trim().is_empty(), "歌单名缺失");
        assert!(playlist
            .tracks
            .iter()
            .all(|track| !track.title.trim().is_empty()));
        assert!(
            playlist
                .tracks
                .iter()
                .filter(|track| track.duration > 0.0)
                .count()
                * 2
                > playlist.tracks.len(),
            "过半曲目应有正时长，说明 duration 字段解析正确"
        );
    }

    #[test]
    #[ignore = "在线测试：需要外网"]
    fn online_qq_playlist_fields() {
        let playlist = fetch_qq("7011264340").expect("QQ 音乐歌单抓取失败");
        println!(
            "[qq] name={} tracks={} note={}",
            playlist.name,
            playlist.tracks.len(),
            playlist.note
        );
        for track in playlist.tracks.iter().take(3) {
            println!(
                "[qq] {} / {} / {}s",
                track.title, track.artist, track.duration
            );
        }
        assert!(!playlist.tracks.is_empty(), "QQ 歌单不应为空");
        assert!(!playlist.name.trim().is_empty(), "歌单名缺失");
        assert!(playlist
            .tracks
            .iter()
            .all(|track| !track.title.trim().is_empty()));
    }

    #[test]
    #[ignore = "在线测试：需要外网"]
    fn online_youtube_playlist_and_continuation() {
        let url = "https://www.youtube.com/playlist?list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI";
        let playlist = fetch_youtube(url).expect("YouTube 歌单抓取失败");
        println!(
            "[youtube] name={} tracks={} note={}",
            playlist.name,
            playlist.tracks.len(),
            playlist.note
        );
        for track in playlist.tracks.iter().take(3) {
            println!(
                "[youtube] {} / {} / {}s",
                track.title, track.artist, track.duration
            );
        }
        if playlist.tracks.len() > 100 {
            println!(
                "[youtube] 抓到 {} 首（超过首屏 100 首）→ 续页生效",
                playlist.tracks.len()
            );
        }
        assert!(!playlist.tracks.is_empty(), "YouTube 歌单不应为空");
        assert!(playlist
            .tracks
            .iter()
            .all(|track| !track.title.trim().is_empty()));
    }

    #[test]
    #[ignore = "在线测试：需要外网"]
    fn online_apple_playlist_fields() {
        let url = "https://music.apple.com/cn/playlist/%E4%BB%8A%E6%97%A5%E7%83%AD%E9%97%A8/pl.f4d106fed2bd41149aaacabb233eb5eb";
        let playlist = fetch_apple(url).expect("Apple Music 歌单抓取失败");
        println!(
            "[apple] name={} tracks={} note={}",
            playlist.name,
            playlist.tracks.len(),
            playlist.note
        );
        for track in playlist.tracks.iter().take(3) {
            println!(
                "[apple] {} / {} / {}s / album={}",
                track.title, track.artist, track.duration, track.album
            );
        }
        assert!(!playlist.tracks.is_empty(), "Apple 歌单不应为空");
        assert!(!playlist.name.trim().is_empty(), "歌单名缺失");
        assert!(
            playlist
                .tracks
                .iter()
                .filter(|track| track.duration > 0.0)
                .count()
                * 2
                > playlist.tracks.len(),
            "过半曲目应有正时长，说明 duration 字段解析正确"
        );
    }

    #[test]
    #[ignore = "在线测试：需要外网"]
    fn online_spotify_embed_or_readable_failure() {
        match fetch_spotify("37i9dQZF1DXcBWIGoYBM5M") {
            Ok(playlist) => {
                println!(
                    "[spotify] 成功 name={} tracks={}",
                    playlist.name,
                    playlist.tracks.len()
                );
                assert!(!playlist.tracks.is_empty(), "Spotify 成功时至少应有一首");
            }
            Err(error) => {
                println!("[spotify] 抓取失败（允许）：{error}");
                assert!(
                    error.contains("粘贴文本") || error.contains("Spotify"),
                    "错误信息应可读并指向替代方案：{error}"
                );
            }
        }
    }
}

// ---------------------------------------------------------------- 缺口聚合

/// 一个没匹配上的艺人缺口：谁、缺几首、缺哪些。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MatchGap {
    pub artist: String,
    pub missing: usize,
    pub titles: Vec<String>,
}

/// 一份歌单匹配之后的缺口汇总，用来决定「要不要再扫一个文件夹」。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MatchGaps {
    pub total: usize,
    pub matched: usize,
    pub missing: usize,
    /// 按缺得多的排前面；最多 20 组。
    pub artists: Vec<MatchGap>,
}

fn gap_artist(track: &ImportedTrack) -> String {
    let artist = track.artist.trim();
    if artist.is_empty() {
        "未知艺人".to_string()
    } else {
        artist.to_string()
    }
}

/// 把没匹配上的曲目按艺人聚合成缺口。
pub fn match_gaps(matches: &[ImportMatch]) -> MatchGaps {
    let total = matches.len();
    let matched = matches.iter().filter(|item| item.song_id.is_some()).count();
    let mut groups: std::collections::BTreeMap<String, (usize, Vec<String>)> =
        std::collections::BTreeMap::new();
    for item in matches.iter().filter(|item| item.song_id.is_none()) {
        let artist = gap_artist(&item.track);
        let slot = groups.entry(artist).or_insert((0, Vec::new()));
        slot.0 += 1;
        if slot.1.len() < 5 {
            let title = item.track.title.trim();
            if !title.is_empty() {
                slot.1.push(title.to_string());
            }
        }
    }
    let mut artists: Vec<MatchGap> = groups
        .into_iter()
        .map(|(artist, (missing, titles))| MatchGap {
            artist,
            missing,
            titles,
        })
        .collect();
    artists.sort_by(|a, b| {
        b.missing
            .cmp(&a.missing)
            .then_with(|| a.artist.cmp(&b.artist))
    });
    artists.truncate(20);
    MatchGaps {
        total,
        matched,
        missing: total.saturating_sub(matched),
        artists,
    }
}

/// 只做聚合，不碰曲库、不联网：前端拿到结果后自己决定要不要引导用户去扫文件夹。
#[tauri::command]
pub fn playlist_import_gaps(matches: Vec<ImportMatch>) -> MatchGaps {
    match_gaps(&matches)
}

#[cfg(test)]
mod gap_tests {
    use super::*;

    fn imported(title: &str, artist: &str) -> ImportedTrack {
        ImportedTrack {
            title: title.into(),
            artist: artist.into(),
            album: String::new(),
            duration: 0.0,
            file_name: None,
            segment_start: None,
            segment_end: None,
            number: 0,
        }
    }

    fn hit(item: ImportedTrack) -> ImportMatch {
        ImportMatch {
            track: item,
            song_id: Some("local".into()),
            score: 0.95,
            reason: "高可信".into(),
        }
    }

    fn miss(item: ImportedTrack) -> ImportMatch {
        ImportMatch {
            track: item,
            song_id: None,
            score: 0.1,
            reason: "没有匹配".into(),
        }
    }

    #[test]
    fn empty_input_produces_zeroes_not_a_panic() {
        let gaps = match_gaps(&[]);
        assert_eq!(gaps.total, 0);
        assert_eq!(gaps.matched, 0);
        assert_eq!(gaps.missing, 0);
        assert!(gaps.artists.is_empty());
    }

    #[test]
    fn groups_only_the_missing_ones_by_artist() {
        let matches = vec![
            hit(imported("晴天", "周杰伦")),
            miss(imported("稻香", "周杰伦")),
            miss(imported("七里香", "周杰伦")),
            miss(imported("Yellow", "Coldplay")),
        ];
        let gaps = match_gaps(&matches);
        assert_eq!(gaps.total, 4);
        assert_eq!(gaps.matched, 1);
        assert_eq!(gaps.missing, 3);
        assert_eq!(gaps.artists.len(), 2);
        // 缺得多的排前面
        assert_eq!(gaps.artists[0].artist, "周杰伦");
        assert_eq!(gaps.artists[0].missing, 2);
        assert_eq!(gaps.artists[0].titles, vec!["稻香".to_string(), "七里香".to_string()]);
        assert_eq!(gaps.artists[1].artist, "Coldplay");
        assert_eq!(gaps.artists[1].missing, 1);
    }

    #[test]
    fn blank_artist_falls_back_and_titles_are_capped() {
        let matches: Vec<ImportMatch> = (0..9)
            .map(|index| miss(imported(&format!("曲{index}"), "  ")))
            .collect();
        let gaps = match_gaps(&matches);
        assert_eq!(gaps.artists.len(), 1);
        assert_eq!(gaps.artists[0].artist, "未知艺人");
        assert_eq!(gaps.artists[0].missing, 9);
        assert_eq!(gaps.artists[0].titles.len(), 5, "每组的曲名只留 5 个，够提示就行");
    }

    #[test]
    fn all_matched_means_no_suggestion_to_scan() {
        let matches = vec![hit(imported("晴天", "周杰伦")), hit(imported("Yellow", "Coldplay"))];
        let gaps = match_gaps(&matches);
        assert_eq!(gaps.missing, 0);
        assert!(gaps.artists.is_empty());
    }
}
