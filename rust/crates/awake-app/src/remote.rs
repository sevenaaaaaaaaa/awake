//! User-configured WebDAV and Plex. No source catalog, search index, or sharing endpoint.
use anyhow::{Context, Result};
use awake_core::{
    decode::StreamDecoder,
    models::{now_ms, SourceKind},
    pipeline::DecoderFactory,
    MediaSource, Track,
};
use parking_lot::Mutex;
use reqwest::{
    blocking::{Client, RequestBuilder, Response},
    header, Method, StatusCode, Url,
};
use sha2::Digest;
use std::{
    io::{Read, Seek, SeekFrom},
    sync::Arc,
    time::Duration,
};

/// 同源重定向最多跟随的跳数。
const MAX_REDIRECTS: usize = 3;
const PROPFIND_BODY: &str =
    "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:allprop/></d:propfind>";

#[derive(Clone)]
pub struct Access {
    pub source: MediaSource,
    pub secret: String,
    /// Digest 认证的 nonce 与 nc 计数（按连接实例共享）。
    digest: Arc<Mutex<DigestState>>,
}
impl Access {
    pub fn new(source: MediaSource, secret: impl Into<String>) -> Self {
        Self {
            source,
            secret: secret.into(),
            digest: Arc::new(Mutex::new(DigestState::default())),
        }
    }
    pub fn base(&self) -> Result<Url> {
        let mut url = Url::parse(&self.source.url).context("来源地址无效")?;
        anyhow::ensure!(
            matches!(url.scheme(), "http" | "https") && url.host_str().is_some(),
            "来源需要 HTTP / HTTPS 地址"
        );
        anyhow::ensure!(
            url.username().is_empty()
                && url.password().is_none()
                && url.query().is_none()
                && url.fragment().is_none(),
            "请把账号和密钥填写在专用字段，地址中不要包含凭据或查询参数"
        );
        if !url.path().ends_with('/') {
            url.set_path(&(url.path().to_string() + "/"));
        }
        Ok(url)
    }
    fn client(&self) -> Result<Client> {
        Ok(Client::builder()
            .connect_timeout(Duration::from_secs(8))
            .timeout(Duration::from_secs(25))
            .redirect(reqwest::redirect::Policy::none())
            // 只有用户为这个来源明确勾选时才放宽证书校验，且只影响该来源自己的 Client。
            .danger_accept_invalid_certs(self.source.trust_self_signed)
            .build()?)
    }
    fn request(&self, client: &Client, method: Method, url: Url) -> RequestBuilder {
        let req = client.request(method, url);
        if self.source.kind == SourceKind::Plex {
            req.header("X-Plex-Token", &self.secret)
                .header(header::ACCEPT, "application/json")
        } else if self.source.kind == SourceKind::Telegram {
            req.bearer_auth(&self.secret)
        } else if !self.source.username.is_empty() {
            req.basic_auth(&self.source.username, Some(&self.secret))
        } else {
            req
        }
    }
    pub fn url(&self, locator: &str) -> Result<Url> {
        let base = self.base()?;
        let url = base.join(locator)?;
        anyhow::ensure!(
            url.origin() == base.origin() && url.username().is_empty() && url.password().is_none(),
            "资源地址超出已连接服务器"
        );
        if matches!(self.source.kind, SourceKind::Webdav | SourceKind::Telegram) {
            anyhow::ensure!(url.path().starts_with(base.path()), "WebDAV 路径超出根目录");
        }
        anyhow::ensure!(
            url.query().is_none() && url.fragment().is_none(),
            "不支持带查询参数的资源路径"
        );
        Ok(url)
    }
    /// 发送请求并返回响应体与最终 URL（同源 301 / 302 / 307 / 308 最多跟随 3 跳）。
    fn bytes(&self, method: Method, url: Url, depth: Option<u8>) -> Result<(Vec<u8>, Url)> {
        let client = self.client()?;
        let (response, final_url) =
            self.exchange(&client, &method, &url, |client, url, authorization| {
                let mut request = self.request(client, method.clone(), url.clone());
                if let Some(depth) = depth {
                    request = request
                        .header("Depth", depth.to_string())
                        .body(PROPFIND_BODY)
                        .header(header::CONTENT_TYPE, "application/xml; charset=utf-8");
                }
                if let Some(value) = authorization {
                    request = request.header(header::AUTHORIZATION, value);
                }
                request
            })?;
        let status = response.status();
        let content_type = response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or("")
            .to_string();
        let mut bytes = Vec::new();
        response
            .take(16 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        anyhow::ensure!(
            bytes.len() <= 16 * 1024 * 1024,
            "来源目录响应过大，请选择更小的根目录"
        );
        if !status.is_success() {
            return Err(http_error(&final_url, status));
        }
        if looks_like_html(&content_type, &bytes) {
            anyhow::bail!(html_error(&final_url, self.source.kind));
        }
        Ok((bytes, final_url))
    }
    /// 发一次请求；遇到 401 + Digest 挑战时用摘要凭据自动重试一次。
    fn authorized<F>(
        &self,
        client: &Client,
        method: &Method,
        url: &Url,
        build: &mut F,
    ) -> Result<Response>
    where
        F: FnMut(&Client, &Url, Option<String>) -> RequestBuilder,
    {
        // 已缓存过挑战时先带上 Digest，避免每次 Range 都先吃一个 401。
        let cached = self.cached_digest(method, url)?;
        let response = build(client, url, cached)
            .send()
            .map_err(|error| network_error(&error))?;
        if response.status() != StatusCode::UNAUTHORIZED || self.source.username.is_empty() {
            return Ok(response);
        }
        let Some(challenge) = response
            .headers()
            .get(header::WWW_AUTHENTICATE)
            .and_then(|value| value.to_str().ok())
            .and_then(parse_digest_challenge)
        else {
            return Ok(response);
        };
        // nonce 过期或首次认证时，用新挑战重试一次并更新缓存。
        let authorization = self.digest_authorization(&challenge, method, url)?;
        build(client, url, Some(authorization))
            .send()
            .map_err(|error| network_error(&error))
    }
    fn cached_digest(&self, method: &Method, url: &Url) -> Result<Option<String>> {
        let challenge = self.digest.lock().challenge.clone();
        match challenge {
            Some(challenge) => Ok(Some(self.digest_authorization(&challenge, method, url)?)),
            None => Ok(None),
        }
    }
    /// 跟随同源重定向；跨源、带账号信息或非 HTTP(S) 的目标一律拒绝。
    fn exchange<F>(
        &self,
        client: &Client,
        method: &Method,
        start: &Url,
        mut build: F,
    ) -> Result<(Response, Url)>
    where
        F: FnMut(&Client, &Url, Option<String>) -> RequestBuilder,
    {
        let base = self.base()?;
        let mut url = start.clone();
        for _ in 0..=MAX_REDIRECTS {
            let response = self.authorized(client, method, &url, &mut build)?;
            if !is_redirect(response.status()) {
                return Ok((response, url));
            }
            let location = response
                .headers()
                .get(header::LOCATION)
                .and_then(|value| value.to_str().ok())
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "服务器返回 HTTP {} 重定向但缺少 Location（{}）",
                        response.status().as_u16(),
                        safe_url(&url)
                    )
                })?;
            url = redirect_url(&base, &url, location)?;
        }
        anyhow::bail!(
            "服务器重定向次数过多（最多 {MAX_REDIRECTS} 次），请直接填写最终地址：{}",
            safe_url(start)
        )
    }
    /// 为当前请求生成 Digest Authorization；同一连接内 nonce 计数递增。
    fn digest_authorization(
        &self,
        challenge: &DigestChallenge,
        method: &Method,
        url: &Url,
    ) -> Result<String> {
        let mut state = self.digest.lock();
        if state.nonce != challenge.nonce {
            state.nonce = challenge.nonce.clone();
            state.count = 0;
        }
        state.challenge = Some(challenge.clone());
        state.count = state.count.wrapping_add(1).max(1);
        let nc = format!("{:08x}", state.count);
        drop(state);
        let cnonce = awake_core::models::new_id().replace('-', "");
        digest_header(
            challenge,
            &self.source.username,
            &self.secret,
            method.as_str(),
            &request_uri(url),
            &nc,
            &cnonce,
        )
    }
    pub fn decoder(&self, locator: &str) -> Result<StreamDecoder> {
        if self.source.kind == SourceKind::Telegram {
            self.connector_json("sponsored", None)?;
        }
        let url = self.url(locator)?;
        let extension = std::path::Path::new(url.path())
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        let source = HttpSource::open(self.clone(), url)?;
        StreamDecoder::open_source(Box::new(source), &extension)
    }
    pub fn factory(&self, locator: String) -> DecoderFactory {
        let access = self.clone();
        Arc::new(move || access.decoder(&locator))
    }
    pub fn scan(&self) -> Result<Vec<Track>> {
        match self.source.kind {
            SourceKind::Webdav => self.webdav(),
            SourceKind::Plex => self.plex(),
            SourceKind::Telegram => self.telegram(),
            _ => anyhow::bail!("该来源需要挂载为本地目录"),
        }
    }
    pub fn connector_json(
        &self,
        path: &str,
        body: Option<serde_json::Value>,
    ) -> Result<serde_json::Value> {
        let url = self.url(path)?;
        let client = self.client()?;
        let mut request = self
            .request(
                &client,
                if body.is_some() {
                    reqwest::Method::POST
                } else {
                    reqwest::Method::GET
                },
                url,
            )
            .timeout(Duration::from_secs(240));
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request
            .send()
            .map_err(|_| anyhow::anyhow!("连接器连接失败，请检查地址和网络"))?;
        let status = response.status();
        let mut bytes = Vec::new();
        response
            .take(16 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        anyhow::ensure!(bytes.len() <= 16 * 1024 * 1024, "连接器响应过大");
        let value: serde_json::Value =
            serde_json::from_slice(&bytes).context("连接器 JSON 格式无效")?;
        if !status.is_success() {
            anyhow::bail!("{}", value["error"].as_str().unwrap_or("连接器返回错误"));
        }
        Ok(value)
    }
    fn telegram(&self) -> Result<Vec<Track>> {
        crate::telegram::connector(&self.source.url, self.secret.clone())
            .map_err(anyhow::Error::msg)?;
        // Rich sponsored content that this release cannot display causes an explicit failure.
        self.connector_json("sponsored", None)?;
        let value = self.connector_json("tracks", None)?;
        let rows = value["tracks"].as_array().context("连接器缺少曲目列表")?;
        anyhow::ensure!(rows.len() <= 40000, "Telegram 曲目超过上限");
        let mut tracks = Vec::with_capacity(rows.len());
        let mut seen = std::collections::HashSet::new();
        for row in rows {
            let locator = row["locator"].as_str().context("音频缺少文件地址")?;
            anyhow::ensure!(
                locator.starts_with("media/") && seen.insert(locator.to_string()),
                "音频地址无效或重复"
            );
            self.url(locator)?;
            let mut track = empty_track(&self.source, locator);
            track.title = row["title"].as_str().unwrap_or("未命名音频").into();
            track.artist = row["artist"].as_str().unwrap_or("未知艺人").into();
            track.album_artist = track.artist.clone();
            track.album = row["album"].as_str().unwrap_or(&self.source.name).into();
            track.duration = row["duration"]
                .as_f64()
                .filter(|n| n.is_finite() && *n >= 0.0)
                .unwrap_or(0.0);
            track.file_size = row["size"].as_i64().unwrap_or(0);
            track.codec = row["codec"].as_str().unwrap_or("").into();
            track.origin_url = row["origin"]
                .as_str()
                .filter(|value| {
                    reqwest::Url::parse(value).is_ok_and(|u| {
                        u.scheme() == "https"
                            && u.host_str() == Some("t.me")
                            && u.username().is_empty()
                            && u.password().is_none()
                            && u.query().is_none()
                            && u.fragment().is_none()
                    })
                })
                .map(str::to_string);
            tracks.push(track);
        }
        Ok(tracks)
    }
    fn webdav(&self) -> Result<Vec<Track>> {
        let base = self.base()?;
        let mut pending = vec![(base.clone(), 0)];
        let mut seen = std::collections::HashSet::new();
        let mut tracks = Vec::new();
        let mut skipped = 0usize;
        while let Some((folder, depth)) = pending.pop() {
            if !seen.insert(folder.to_string()) {
                continue;
            }
            anyhow::ensure!(seen.len() <= 5000 && depth <= 32, "目录层级或数量超出限制");
            let (xml, folder_url) =
                match self.bytes(Method::from_bytes(b"PROPFIND")?, folder.clone(), Some(1)) {
                    Ok(value) => value,
                    Err(error)
                        if depth > 0 && matches!(status_of(&error), Some(403) | Some(404)) =>
                    {
                        // 单个条目 403 / 404 时跳过，不因一个目录拖垮整个来源。
                        log::info!(
                            "WebDAV 跳过无法读取的目录（HTTP {}）：{}",
                            status_of(&error).unwrap_or_default(),
                            safe_url(&folder)
                        );
                        skipped += 1;
                        continue;
                    }
                    Err(error) => return Err(error),
                };
            let xml =
                String::from_utf8(xml).context("WebDAV 返回的目录信息不是有效的 UTF-8 文本")?;
            let doc = roxmltree::Document::parse(&xml).context(
                "WebDAV 返回的目录信息不是有效的 XML，请确认地址指向 WebDAV 根目录而不是网页",
            )?;
            for response in doc
                .descendants()
                .filter(|n| n.has_tag_name(("DAV:", "response")))
            {
                let href = response
                    .descendants()
                    .find(|n| n.has_tag_name(("DAV:", "href")))
                    .and_then(|n| n.text())
                    .unwrap_or("");
                if href.is_empty() {
                    continue;
                }
                let url = folder_url.join(href)?;
                anyhow::ensure!(
                    url.origin() == base.origin()
                        && url.path().starts_with(base.path())
                        && url.query().is_none(),
                    "WebDAV 返回了根目录以外的地址"
                );
                let ok = response
                    .descendants()
                    .filter(|n| n.has_tag_name(("DAV:", "propstat")))
                    .find(|n| {
                        n.children()
                            .find(|n| n.has_tag_name(("DAV:", "status")))
                            .and_then(|n| n.text())
                            .is_some_and(|s| s.contains(" 200 "))
                    });
                let Some(propstat) = ok else {
                    continue;
                };
                let collection = propstat
                    .descendants()
                    .any(|n| n.has_tag_name(("DAV:", "collection")));
                if collection {
                    if url != folder_url && !seen.contains(url.as_str()) {
                        pending.push((url, depth + 1));
                    }
                    continue;
                }
                let locator = url
                    .path()
                    .strip_prefix(base.path())
                    .unwrap_or("")
                    .to_string();
                if locator.is_empty() {
                    continue;
                }
                let decoded = percent_decode(&locator)?;
                if !awake_core::library::is_audio_file(std::path::Path::new(&decoded)) {
                    continue;
                }
                let size = propstat
                    .descendants()
                    .find(|n| n.has_tag_name(("DAV:", "getcontentlength")))
                    .and_then(|n| n.text())
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0);
                let mut track = empty_track(&self.source, &locator);
                let path = std::path::Path::new(&decoded);
                track.title = path
                    .file_stem()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned();
                track.album = path
                    .parent()
                    .and_then(|p| p.file_name())
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_else(|| self.source.name.clone());
                track.codec = path
                    .extension()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_uppercase();
                track.file_size = size;
                tracks.push(track);
                anyhow::ensure!(tracks.len() <= 100000, "曲目超过单个来源上限");
            }
        }
        tracks.sort_by(|a, b| a.locator.cmp(&b.locator));
        tracks.dedup_by(|a, b| a.locator == b.locator);
        if tracks.is_empty() && skipped > 0 {
            anyhow::bail!(
                "目录可以访问，但所有子目录都返回 403 / 404（{skipped} 个），请检查账号权限或根目录设置"
            );
        }
        Ok(tracks)
    }
    fn plex(&self) -> Result<Vec<Track>> {
        let (data, _) = self.bytes(Method::GET, self.url("library/sections")?, None)?;
        let sections: serde_json::Value = parse_json(&data, "Plex 目录")?;
        let dirs = sections["MediaContainer"]["Directory"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Plex 目录格式无效"))?;
        let wanted = self.source.section.trim();
        let is_music = |s: &&serde_json::Value| {
            matches!(s["type"].as_str(), Some("artist") | Some("music"))
        };
        if !wanted.is_empty()
            && !dirs
                .iter()
                .any(|s| is_music(&s) && s["key"].as_str() == Some(wanted))
        {
            anyhow::bail!("Plex 音乐库分区不存在或已删除，请重新选择音乐库");
        }
        let mut tracks = Vec::new();
        for section in dirs
            .iter()
            .filter(is_music)
            .filter(|s| wanted.is_empty() || s["key"].as_str() == Some(wanted))
        {
            let key = section["key"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("Plex 目录缺少 ID"))?;
            anyhow::ensure!(key.chars().all(|c| c.is_ascii_digit()), "Plex 目录 ID 无效");
            let mut offset = 0;
            loop {
                let mut url = self.url(&format!("library/sections/{key}/all"))?;
                url.query_pairs_mut()
                    .append_pair("type", "10")
                    .append_pair("X-Plex-Container-Start", &offset.to_string())
                    .append_pair("X-Plex-Container-Size", "500");
                let (bytes, _) = self.bytes(Method::GET, url, None)?;
                let data: serde_json::Value = parse_json(&bytes, "Plex 曲目列表")?;
                let rows = data["MediaContainer"]["Metadata"]
                    .as_array()
                    .ok_or_else(|| anyhow::anyhow!("Plex 曲目列表格式无效"))?;
                for row in rows {
                    let Some(part) = row["Media"][0]["Part"][0]["key"].as_str() else {
                        continue;
                    };
                    self.url(part)?;
                    let mut track = empty_track(&self.source, part);
                    let media = &row["Media"][0];
                    track.title = row["title"].as_str().unwrap_or("未命名曲目").into();
                    track.artist = row["grandparentTitle"].as_str().unwrap_or("").into();
                    track.album_artist = track.artist.clone();
                    track.album = row["parentTitle"].as_str().unwrap_or("").into();
                    track.duration = row["duration"].as_f64().unwrap_or(0.0) / 1000.0;
                    track.codec = media["audioCodec"].as_str().unwrap_or("").to_uppercase();
                    track.sample_rate = media["audioSamplingRate"].as_u64().unwrap_or(0) as u32;
                    track.bit_depth = media["audioBitDepth"].as_u64().unwrap_or(0) as u32;
                    track.channels = media["audioChannels"].as_u64().unwrap_or(0) as u16;
                    track.track_number = row["index"].as_u64().map(|n| n as u32);
                    track.year = row["year"].as_i64().map(|n| n as i32);
                    track.file_size = media["Part"][0]["size"].as_i64().unwrap_or(0);
                    tracks.push(track);
                }
                let total = data["MediaContainer"]["totalSize"]
                    .as_u64()
                    .unwrap_or(rows.len() as u64) as usize;
                offset += rows.len();
                if rows.is_empty() || offset >= total {
                    break;
                }
                anyhow::ensure!(tracks.len() <= 100000, "Plex 曲目超过上限");
            }
        }
        Ok(tracks)
    }
}
fn is_redirect(status: StatusCode) -> bool {
    matches!(
        status,
        StatusCode::MOVED_PERMANENTLY
            | StatusCode::FOUND
            | StatusCode::TEMPORARY_REDIRECT
            | StatusCode::PERMANENT_REDIRECT
    )
}

/// 解析同源重定向目标；跨源或带账号信息时拒绝，避免凭据被带出站点。
fn redirect_url(base: &Url, current: &Url, location: &str) -> Result<Url> {
    let target = current
        .join(location)
        .map_err(|_| anyhow::anyhow!("服务器返回了无效的重定向地址，已停止连接"))?;
    anyhow::ensure!(
        target.origin() == base.origin(),
        "服务器重定向到了其他站点（{}），为保护凭据已停止连接",
        safe_url(&target)
    );
    anyhow::ensure!(
        target.username().is_empty() && target.password().is_none(),
        "重定向地址包含账号信息，已停止连接"
    );
    Ok(target)
}

/// 诊断信息里去掉查询参数与账号，避免 Plex token 等进入日志或界面。
fn safe_url(url: &Url) -> String {
    let mut cleaned = url.clone();
    cleaned.set_query(None);
    cleaned.set_fragment(None);
    let _ = cleaned.set_username("");
    let _ = cleaned.set_password(None);
    cleaned.to_string()
}

fn request_uri(url: &Url) -> String {
    match url.query() {
        Some(query) => format!("{}?{query}", url.path()),
        None => url.path().to_string(),
    }
}

fn network_error(error: &reqwest::Error) -> anyhow::Error {
    let location = error
        .url()
        .map(safe_url)
        .unwrap_or_else(|| "来源地址".into());
    let text = error.to_string().to_lowercase();
    if error.is_timeout() {
        anyhow::anyhow!("连接超时：服务器没有在限定时间内响应（{location}），请检查地址与网络")
    } else if text.contains("certificate") || text.contains("tls") || text.contains("handshake") {
        anyhow::anyhow!(
            "HTTPS 证书校验失败（{location}）：如果这是你自己的 NAS，请勾选“允许自签名证书”后重试"
        )
    } else if error.is_connect() {
        anyhow::anyhow!("无法连接服务器（{location}）：请检查地址、端口与网络")
    } else if error.is_body() || error.is_decode() {
        anyhow::anyhow!("读取服务器响应失败（{location}）：请稍后重试")
    } else {
        anyhow::anyhow!("来源连接失败（{location}）：请检查地址与网络")
    }
}

/// 带 HTTP 状态码的错误，便于上层对单个条目 403 / 404 做跳过处理。
#[derive(Debug)]
struct HttpStatusError {
    status: u16,
    message: String,
}
impl std::fmt::Display for HttpStatusError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}
impl std::error::Error for HttpStatusError {}

fn http_error(url: &Url, status: StatusCode) -> anyhow::Error {
    anyhow::Error::new(HttpStatusError {
        status: status.as_u16(),
        message: format!(
            "来源返回 HTTP {}（{}）：{}",
            status.as_u16(),
            safe_url(url),
            status_hint(status)
        ),
    })
}

fn status_of(error: &anyhow::Error) -> Option<u16> {
    error
        .downcast_ref::<HttpStatusError>()
        .map(|error| error.status)
}

fn status_hint(status: StatusCode) -> &'static str {
    match status.as_u16() {
        401 => {
            "需要认证：请检查账号和密码；若服务器启用 Digest 认证，请确认账号密码与服务器设置一致"
        }
        403 => "服务器拒绝访问：请检查该路径是否允许读取，或账号是否有下载权限",
        404 => "路径不存在：请确认 WebDAV 根地址与目录名，并留意结尾斜杠",
        405 => "服务器不接受该请求方法：这个地址可能不是 WebDAV 服务，或服务器禁用了 WebDAV",
        429 => "请求过于频繁，请稍后再试",
        500..=599 => "服务器内部错误，请稍后重试",
        _ => "请检查服务器地址、账号与此来源的连接设置",
    }
}

fn html_error(url: &Url, kind: SourceKind) -> String {
    match kind {
        SourceKind::Webdav => format!(
            "服务器返回了 HTML 页面而不是 WebDAV 目录数据（HTTP 200，{}）：地址可能指向登录页或普通网站，请填写 WebDAV 根地址，例如 https://nas:5006/dav/",
            safe_url(url)
        ),
        SourceKind::Plex => format!(
            "服务器返回了 HTML 页面而不是 Plex 数据（HTTP 200，{}）：请确认服务器地址与 Token，或重新用 Plex 账号登录",
            safe_url(url)
        ),
        _ => format!(
            "服务器返回了 HTML 页面而不是预期的数据（HTTP 200，{}）：请确认地址是否正确",
            safe_url(url)
        ),
    }
}

fn looks_like_html(content_type: &str, body: &[u8]) -> bool {
    if content_type.to_ascii_lowercase().contains("text/html") {
        return true;
    }
    let head = &body[..body.len().min(512)];
    let text = String::from_utf8_lossy(head)
        .trim_start()
        .to_ascii_lowercase();
    text.starts_with("<!doctype html") || text.starts_with("<html")
}

fn parse_json(bytes: &[u8], what: &str) -> Result<serde_json::Value> {
    serde_json::from_slice(bytes)
        .with_context(|| format!("{what}格式无效：请确认服务器地址、Token 与服务器类型"))
}

#[derive(Debug, Default)]
struct DigestState {
    nonce: String,
    count: u32,
    challenge: Option<DigestChallenge>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DigestChallenge {
    realm: String,
    nonce: String,
    opaque: Option<String>,
    qop: Option<String>,
    algorithm: Option<String>,
}

/// 从 WWW-Authenticate 头里取 Digest 挑战（可与其他认证方案同时出现）。
fn parse_digest_challenge(header: &str) -> Option<DigestChallenge> {
    let lower = header.to_ascii_lowercase();
    let bytes = header.as_bytes();
    let mut start = None;
    for (index, _) in lower.match_indices("digest") {
        let boundary = index == 0 || matches!(bytes[index - 1], b' ' | b'\t' | b',');
        if !boundary {
            continue;
        }
        let rest = header[index + "digest".len()..].trim_start();
        let rest_lower = rest.to_ascii_lowercase();
        if rest.starts_with('=')
            || !(rest_lower.contains("realm=") || rest_lower.contains("nonce="))
        {
            continue;
        }
        start = Some(index + "digest".len());
        break;
    }
    let params = parse_auth_params(&header[start?..]);
    let mut realm = None;
    let mut nonce = None;
    let mut opaque = None;
    let mut qop = None;
    let mut algorithm = None;
    for (key, value) in params {
        match key.as_str() {
            "realm" => realm = Some(value),
            "nonce" => nonce = Some(value),
            "opaque" => opaque = Some(value),
            "qop" => qop = Some(value),
            "algorithm" => algorithm = Some(value),
            _ => {}
        }
    }
    Some(DigestChallenge {
        realm: realm?,
        nonce: nonce?,
        opaque,
        qop,
        algorithm,
    })
}

fn parse_auth_params(input: &str) -> Vec<(String, String)> {
    let bytes = input.as_bytes();
    let mut params = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        while index < bytes.len() && matches!(bytes[index], b' ' | b'\t' | b',') {
            index += 1;
        }
        if index >= bytes.len() {
            break;
        }
        let key_start = index;
        while index < bytes.len() && bytes[index] != b'=' && bytes[index] != b',' {
            index += 1;
        }
        if index >= bytes.len() || bytes[index] != b'=' {
            break;
        }
        let key = input[key_start..index].trim().to_ascii_lowercase();
        index += 1;
        while index < bytes.len() && bytes[index] == b' ' {
            index += 1;
        }
        if index < bytes.len() && bytes[index] == b'"' {
            index += 1;
            let value_start = index;
            let mut value_end = None;
            while index < bytes.len() {
                if bytes[index] == b'\\' {
                    index += 2;
                    continue;
                }
                if bytes[index] == b'"' {
                    value_end = Some(index);
                    index += 1;
                    break;
                }
                index += 1;
            }
            let Some(value_end) = value_end else {
                break;
            };
            let value = input[value_start..value_end]
                .replace("\\\"", "\"")
                .replace("\\\\", "\\");
            params.push((key, value));
        } else {
            let value_start = index;
            while index < bytes.len() && bytes[index] != b',' {
                index += 1;
            }
            params.push((key, input[value_start..index].trim().to_string()));
        }
    }
    params
}

fn digest_hex(algorithm: &str, value: &str) -> Result<String> {
    match algorithm {
        "MD5" => Ok(format!("{:x}", md5::Md5::digest(value.as_bytes()))),
        "SHA-256" => Ok(format!("{:x}", sha2::Sha256::digest(value.as_bytes()))),
        _ => anyhow::bail!("不支持的摘要算法"),
    }
}

/// RFC 2617 / 7616 的 response 计算；qop 为 None 时使用旧式无 qop 形式。
fn digest_response(
    algorithm: &str,
    session: bool,
    username: &str,
    password: &str,
    realm: &str,
    nonce: &str,
    method: &str,
    uri: &str,
    qop: Option<&str>,
    nc: &str,
    cnonce: &str,
) -> Result<String> {
    let mut ha1 = digest_hex(algorithm, &format!("{username}:{realm}:{password}"))?;
    if session {
        ha1 = digest_hex(algorithm, &format!("{ha1}:{nonce}:{cnonce}"))?;
    }
    let ha2 = digest_hex(algorithm, &format!("{method}:{uri}"))?;
    match qop {
        Some(qop) => digest_hex(
            algorithm,
            &format!("{ha1}:{nonce}:{nc}:{cnonce}:{qop}:{ha2}"),
        ),
        None => digest_hex(algorithm, &format!("{ha1}:{nonce}:{ha2}")),
    }
}

fn quote_auth(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn digest_header(
    challenge: &DigestChallenge,
    username: &str,
    password: &str,
    method: &str,
    uri: &str,
    nc: &str,
    cnonce: &str,
) -> Result<String> {
    let requested = challenge.algorithm.as_deref().unwrap_or("MD5");
    let (algorithm, session) = match requested.to_ascii_uppercase().as_str() {
        "MD5" => ("MD5", false),
        "SHA-256" => ("SHA-256", false),
        "MD5-SESS" => ("MD5", true),
        "SHA-256-SESS" => ("SHA-256", true),
        other => {
            anyhow::bail!("服务器要求的摘要认证算法不受支持：{other}（当前支持 MD5 / SHA-256）")
        }
    };
    let qop = match challenge.qop.as_deref() {
        None => None,
        Some(value) => {
            let offered: Vec<String> = value
                .split(',')
                .map(|item| item.trim().to_ascii_lowercase())
                .filter(|item| !item.is_empty())
                .collect();
            if offered.iter().any(|item| item == "auth") {
                Some("auth")
            } else if offered.is_empty() {
                None
            } else {
                anyhow::bail!("服务器只支持摘要认证 qop=auth-int，当前连接方式无法使用");
            }
        }
    };
    let response = digest_response(
        algorithm,
        session,
        username,
        password,
        &challenge.realm,
        &challenge.nonce,
        method,
        uri,
        qop,
        nc,
        cnonce,
    )?;
    let mut header = format!(
        "Digest username=\"{}\", realm=\"{}\", nonce=\"{}\", uri=\"{}\", algorithm={}, response=\"{}\"",
        quote_auth(username),
        quote_auth(&challenge.realm),
        quote_auth(&challenge.nonce),
        quote_auth(uri),
        challenge.algorithm.as_deref().unwrap_or("MD5"),
        response
    );
    if let Some(qop) = qop {
        header.push_str(&format!(
            ", qop={qop}, nc={nc}, cnonce=\"{}\"",
            quote_auth(cnonce)
        ));
    }
    if let Some(opaque) = &challenge.opaque {
        header.push_str(&format!(", opaque=\"{}\"", quote_auth(opaque)));
    }
    Ok(header)
}

fn percent_decode(value: &str) -> Result<String> {
    let mut out = Vec::new();
    let bytes = value.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            anyhow::ensure!(i + 2 < bytes.len(), "URL 编码无效");
            out.push(u8::from_str_radix(&value[i + 1..i + 3], 16)?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    Ok(String::from_utf8(out)?)
}
fn empty_track(source: &MediaSource, locator: &str) -> Track {
    Track {
        id: Track::make_id(&source.id, locator),
        title: String::new(),
        artist: String::new(),
        album_artist: String::new(),
        album: source.name.clone(),
        genre: String::new(),
        year: None,
        track_number: None,
        disc_number: None,
        duration: 0.0,
        sample_rate: 0,
        bit_depth: 0,
        channels: 0,
        codec: String::new(),
        source_id: source.id.clone(),
        locator: locator.into(),
        file_size: 0,
        modified: 0,
        artwork_path: None,
        play_count: 0,
        favorite: false,
        last_played: None,
        added_at: now_ms(),
        is_remote: true,
        origin_url: None,
        comment: String::new(),
        lyrics: String::new(),
        media_info: None,
    }
}

/// Seekable HTTP byte ranges. No complete-song download, token URL, or unbounded cache.
struct HttpSource {
    access: Access,
    client: Client,
    url: Url,
    len: u64,
    pos: u64,
    start: u64,
    cache: Vec<u8>,
}
impl HttpSource {
    fn open(access: Access, url: Url) -> Result<Self> {
        let client = access.client()?;
        let mut source = Self {
            access,
            client,
            url,
            len: 0,
            pos: 0,
            start: 0,
            cache: Vec::new(),
        };
        source.fill(0)?;
        Ok(source)
    }
    fn fill(&mut self, start: u64) -> Result<()> {
        let end = start.saturating_add(524287);
        let access = self.access.clone();
        let client = self.client.clone();
        let (response, final_url) = access.exchange(
            &client,
            &Method::GET,
            &self.url,
            |client, url, authorization| {
                let mut request = access
                    .request(client, Method::GET, url.clone())
                    .header(header::RANGE, format!("bytes={start}-{end}"))
                    .header(header::ACCEPT_ENCODING, "identity");
                if let Some(value) = authorization {
                    request = request.header(header::AUTHORIZATION, value);
                }
                request
            },
        )?;
        // 记住重定向后的地址，后续 Range 请求不必重复跳转。
        self.url = final_url.clone();
        let status = response.status();
        if status != StatusCode::PARTIAL_CONTENT {
            let hint = if status == StatusCode::OK {
                "服务器忽略了 Range 请求，无法定位播放；请换用支持 HTTP Range 的 WebDAV 服务或挂载目录"
            } else if status == StatusCode::UNAUTHORIZED {
                "需要认证：请检查账号密码，或服务器启用了 Digest 认证"
            } else if status == StatusCode::FORBIDDEN {
                "服务器拒绝读取该音频：请检查文件权限与账号授权"
            } else {
                "请检查来源连接与文件权限"
            };
            anyhow::bail!(
                "远程音频读取失败（HTTP {}，{}）：{hint}",
                status.as_u16(),
                safe_url(&final_url)
            );
        }
        let range = response
            .headers()
            .get(header::CONTENT_RANGE)
            .and_then(|h| h.to_str().ok())
            .ok_or_else(|| anyhow::anyhow!("来源缺少 Content-Range"))?;
        let (bounds, total) = range
            .strip_prefix("bytes ")
            .and_then(|s| s.split_once('/'))
            .ok_or_else(|| anyhow::anyhow!("Content-Range 无效"))?;
        let (from, to) = bounds
            .split_once('-')
            .ok_or_else(|| anyhow::anyhow!("Content-Range 无效"))?;
        let from: u64 = from.parse()?;
        let to: u64 = to.parse()?;
        let total: u64 = total.parse()?;
        anyhow::ensure!(
            from == start && to >= from && to <= end && to < total,
            "来源返回了错误的字节范围"
        );
        anyhow::ensure!(
            self.len == 0 || self.len == total,
            "远程文件大小已变化，请更新曲库"
        );
        self.len = total;
        let mut cache = Vec::new();
        response.take(524289).read_to_end(&mut cache)?;
        anyhow::ensure!(cache.len() as u64 == to - from + 1, "远程音频返回不完整");
        self.start = start;
        self.cache = cache;
        Ok(())
    }
}
impl Read for HttpSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if buf.is_empty() || self.pos >= self.len {
            return Ok(0);
        }
        if self.pos < self.start || self.pos >= self.start + self.cache.len() as u64 {
            self.fill(self.pos).map_err(std::io::Error::other)?;
        }
        let offset = (self.pos - self.start) as usize;
        let n = buf.len().min(self.cache.len() - offset);
        buf[..n].copy_from_slice(&self.cache[offset..offset + n]);
        self.pos += n as u64;
        Ok(n)
    }
}
impl Seek for HttpSource {
    fn seek(&mut self, to: SeekFrom) -> std::io::Result<u64> {
        let pos = match to {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::Current(n) => self.pos as i128 + n as i128,
            SeekFrom::End(n) => self.len as i128 + n as i128,
        };
        if pos < 0 || pos > self.len as i128 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "字节位置越界",
            ));
        }
        self.pos = pos as u64;
        Ok(self.pos)
    }
}
impl awake_core::symphonia_source::MediaSource for HttpSource {
    fn is_seekable(&self) -> bool {
        true
    }
    fn byte_len(&self) -> Option<u64> {
        Some(self.len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::Write,
        net::TcpListener,
        sync::{
            atomic::{AtomicBool, Ordering},
            Mutex,
        },
    };
    struct Server {
        base: String,
        stop: Arc<AtomicBool>,
        thread: Option<std::thread::JoinHandle<()>>,
        requests: Arc<Mutex<Vec<String>>>,
        dir: std::path::PathBuf,
    }
    impl Server {
        fn new() -> Self {
            let dir = crate::test_audio::directory();
            let path = dir.join("long.wav");
            crate::test_audio::sparse(&path, 48000, 2, 7200);
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let stop = Arc::new(AtomicBool::new(false));
            let flag = stop.clone();
            let requests = Arc::new(Mutex::new(Vec::new()));
            let logs = requests.clone();
            let thread = std::thread::spawn(move || {
                while !flag.load(Ordering::Relaxed) {
                    let (mut socket, _) = match listener.accept() {
                        Ok(s) => s,
                        Err(_) => {
                            std::thread::sleep(Duration::from_millis(1));
                            continue;
                        }
                    };
                    socket.set_nonblocking(false).unwrap();
                    socket
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut bytes = Vec::new();
                    let mut chunk = [0; 4096];
                    while !bytes.windows(4).any(|s| s == b"\r\n\r\n") {
                        let n = socket.read(&mut chunk).unwrap_or(0);
                        if n == 0 {
                            break;
                        }
                        bytes.extend_from_slice(&chunk[..n]);
                        if bytes.len() > 65536 {
                            break;
                        }
                    }
                    if let Some(end) = bytes.windows(4).position(|s| s == b"\r\n\r\n") {
                        let headers = String::from_utf8_lossy(&bytes[..end]);
                        let len = headers
                            .lines()
                            .find_map(|line| {
                                line.to_lowercase()
                                    .strip_prefix("content-length:")
                                    .and_then(|s| s.trim().parse::<usize>().ok())
                            })
                            .unwrap_or(0);
                        while bytes.len() < end + 4 + len {
                            let n = socket.read(&mut chunk).unwrap_or(0);
                            if n == 0 {
                                break;
                            }
                            bytes.extend_from_slice(&chunk[..n]);
                        }
                    }
                    let req = String::from_utf8_lossy(&bytes).to_string();
                    logs.lock().unwrap().push(req.clone());
                    let first = req.lines().next().unwrap_or("");
                    let target = first.split_whitespace().nth(1).unwrap_or("");
                    let (status, content_type, body, extra) = if first.starts_with("PROPFIND") {
                        let lower = req.to_lowercase();
                        let dav_body = |href: &str| {
                            format!("<d:multistatus xmlns:d='DAV:'><d:response><d:href>{href}</d:href><d:propstat><d:prop><d:getcontentlength>1382400044</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>").into_bytes()
                        };
                        if target.starts_with("/moved/") && !target.starts_with("/moved/final/") {
                            (
                                "302 Found",
                                "text/plain",
                                Vec::new(),
                                "Location: /moved/final/\r\n".to_string(),
                            )
                        } else if target.starts_with("/cross/") {
                            (
                                "302 Found",
                                "text/plain",
                                Vec::new(),
                                "Location: https://example.invalid/dav/\r\n".to_string(),
                            )
                        } else if target.starts_with("/html/") {
                            (
                                "200 OK",
                                "text/html",
                                b"<!DOCTYPE html><html>login</html>".to_vec(),
                                String::new(),
                            )
                        } else if target.starts_with("/digest/") {
                            let challenge = "WWW-Authenticate: Digest realm=\"dav\", nonce=\"abc123\", qop=\"auth\", algorithm=MD5, opaque=\"xyz\"\r\n";
                            if !lower.contains("authorization: digest") {
                                (
                                    "401 Unauthorized",
                                    "text/plain",
                                    Vec::new(),
                                    challenge.to_string(),
                                )
                            } else if lower.contains("authorization: digest username=\"user\"")
                                && lower.contains("nc=")
                                && lower.contains("qop=auth")
                                && lower.contains("opaque=\"xyz\"")
                            {
                                (
                                    "207 Multi-Status",
                                    "application/xml",
                                    dav_body("/digest/%E9%9F%B3%E4%B9%90.wav"),
                                    String::new(),
                                )
                            } else {
                                (
                                    "401 Unauthorized",
                                    "text/plain",
                                    Vec::new(),
                                    challenge.to_string(),
                                )
                            }
                        } else if target.starts_with("/skip/locked") {
                            ("403 Forbidden", "text/plain", Vec::new(), String::new())
                        } else if target.starts_with("/skip/") {
                            (
                                "207 Multi-Status",
                                "application/xml",
                                b"<d:multistatus xmlns:d='DAV:'><d:response><d:href>/skip/locked/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response><d:response><d:href>/skip/ok.wav</d:href><d:propstat><d:prop><d:getcontentlength>1234</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>".to_vec(),
                                String::new(),
                            )
                        } else if !lower.contains("authorization: basic dxnlcjpwyxnz") {
                            ("401 Unauthorized", "text/plain", Vec::new(), String::new())
                        } else if target.starts_with("/outside/") {
                            (
                                "207 Multi-Status",
                                "application/xml",
                                dav_body("https://example.invalid/private.wav"),
                                String::new(),
                            )
                        } else if target.starts_with("/moved/") {
                            (
                                "207 Multi-Status",
                                "application/xml",
                                dav_body("/moved/final/%E9%9F%B3%E4%B9%90.wav"),
                                String::new(),
                            )
                        } else {
                            (
                                "207 Multi-Status",
                                "application/xml",
                                dav_body("/dav/%E9%9F%B3%E4%B9%90.wav"),
                                String::new(),
                            )
                        }
                    } else if target.starts_with("/telegram") && target.ends_with("/sponsored") {
                        (
                            "200 OK",
                            "application/json",
                            br#"{"messages":[]}"#.to_vec(),
                            String::new(),
                        )
                    } else if target.starts_with("/telegram") && target.ends_with("/tracks") {
                        let locator = if target.starts_with("/telegram-invalid/") {
                            "../outside.wav"
                        } else {
                            "media/42/7/audio.wav"
                        };
                        ("200 OK", "application/json", format!(r#"{{"tracks":[{{"locator":"{locator}","title":"Own audio","artist":"Owner","album":"Saved","duration":7200,"size":1382400044,"codec":"WAV"}}]}}"#).into_bytes(), String::new())
                    } else if target.starts_with("/library/sections/1/all") {
                        let second = target.contains("Start=1");
                        let id = if second { "2" } else { "1" };
                        ("200 OK","application/json",format!(r#"{{"MediaContainer":{{"totalSize":2,"Metadata":[{{"title":"Track {id}","grandparentTitle":"Artist","parentTitle":"Album","duration":2000,"Media":[{{"audioCodec":"flac","Part":[{{"key":"/audio/{id}.wav"}}]}}]}}]}}}}"#).into_bytes(),String::new())
                    } else if target == "/library/sections" {
                        ("200 OK","application/json",br#"{"MediaContainer":{"Directory":[{"key":"1","type":"artist"},{"key":"2","type":"movie"}]}}"#.to_vec(),String::new())
                    } else if target.starts_with("/bad") {
                        ("200 OK", "audio/wav", vec![0; 10], String::new())
                    } else {
                        let length = std::fs::metadata(&path).unwrap().len();
                        let range = req
                            .lines()
                            .find_map(|line| {
                                line.to_lowercase()
                                    .strip_prefix("range: bytes=")
                                    .map(str::to_string)
                            })
                            .unwrap_or("0-524287".into());
                        let (from, to) = range.trim().split_once('-').unwrap();
                        let start: u64 = from.parse().unwrap();
                        let end = to.parse::<u64>().unwrap().min(length - 1);
                        let mut file = std::fs::File::open(&path).unwrap();
                        file.seek(SeekFrom::Start(start)).unwrap();
                        let mut body = vec![0; (end - start + 1) as usize];
                        file.read_exact(&mut body).unwrap();
                        (
                            "206 Partial Content",
                            "audio/wav",
                            body,
                            format!("Content-Range: bytes {start}-{end}/{length}\r\n"),
                        )
                    };
                    let header=format!("HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\n{extra}Connection: close\r\n\r\n",body.len());
                    let _ = socket.write_all(header.as_bytes());
                    let _ = socket.write_all(&body);
                }
            });
            Self {
                base,
                stop,
                thread: Some(thread),
                requests,
                dir,
            }
        }
    }
    impl Drop for Server {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            let result = self.thread.take().unwrap().join();
            if !std::thread::panicking() {
                assert!(result.is_ok(), "mock server failed");
            }
            std::fs::remove_dir_all(&self.dir).unwrap();
        }
    }
    fn access(server: &Server, kind: SourceKind, path: &str) -> Access {
        let mut source = MediaSource::new(kind, "test", format!("{}{path}", server.base));
        source.username = "user".into();
        Access::new(source, "pass")
    }
    #[test]
    fn authenticated_webdav_ranges_and_seek_are_bounded() {
        let server = Server::new();
        let access = access(&server, SourceKind::Webdav, "/dav/");
        let tracks = access.scan().unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].title, "音乐");
        let mut decoder = access.decoder(&tracks[0].locator).unwrap();
        assert_eq!(decoder.format.duration_secs, Some(7200.0));
        assert!(decoder.next_packet().unwrap().unwrap().len() < 32768);
        decoder.seek(7199.8).unwrap();
        assert!(decoder.next_packet().unwrap().is_some());
        let logs = server.requests.lock().unwrap();
        assert!(logs.iter().filter(|r| r.starts_with("GET")).count() < 12);
        assert!(logs
            .iter()
            .filter(|r| r.starts_with("GET"))
            .all(|r| r.to_lowercase().contains("range: bytes=")));
        assert!(logs
            .iter()
            .all(|r| !r.lines().next().unwrap().contains("pass")));
    }

    #[test]
    fn telegram_audio_uses_authenticated_ranges_and_preserves_source_boundary() {
        let server = Server::new();
        let access = access(&server, SourceKind::Telegram, "/telegram/");
        let tracks = access.scan().unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(
            tracks[0].sample_rate, 0,
            "metadata must not invent Hi-Res quality"
        );
        let mut decoder = access.decoder(&tracks[0].locator).unwrap();
        assert_eq!(decoder.format.duration_secs, Some(7200.0));
        assert!(decoder.next_packet().unwrap().unwrap().len() < 32768);
        decoder.seek(7199.8).unwrap();
        assert!(decoder.next_packet().unwrap().is_some());
        let requests = server.requests.lock().unwrap();
        assert!(requests
            .iter()
            .all(|r| r.to_lowercase().contains("authorization: bearer pass")));
        assert!(requests
            .iter()
            .all(|r| !r.lines().next().unwrap().contains('?')));
        drop(requests);
        assert!(access.url("../outside.wav").is_err());
        assert!(
            super::tests::access(&server, SourceKind::Telegram, "/telegram-invalid/")
                .scan()
                .is_err()
        );
    }
    #[test]
    fn plex_pages_music_only_and_keeps_token_in_header() {
        let server = Server::new();
        let access = access(&server, SourceKind::Plex, "/");
        let tracks = access.scan().unwrap();
        assert_eq!(tracks.len(), 2);
        assert_eq!(tracks[1].title, "Track 2");
        let logs = server.requests.lock().unwrap();
        assert_eq!(logs.len(), 3);
        assert!(logs
            .iter()
            .all(|r| r.to_lowercase().contains("x-plex-token: pass")));
        assert!(logs
            .iter()
            .all(|r| !r.lines().next().unwrap().contains("pass")));
    }
    #[test]
    #[ignore = "uses default CoreAudio silently with a loopback Range server"]
    fn real_output_remote_range_seek() {
        let server = Server::new();
        let access = access(&server, SourceKind::Webdav, "/dav/");
        let tracks = access.scan().unwrap();
        let player = crate::playback::Player::new();
        *player.volume.lock() = 0.0;
        let (tx, rx) = std::sync::mpsc::channel();
        player
            .play_queue(
                vec![crate::playback::QueueTrack {
                    id: "remote".into(),
                    path: std::path::PathBuf::new(),
                    opener: Some(access.factory(tracks[0].locator.clone())),
                    duration: 0.0,
                    sample_rate: 0,
                }],
                true,
                move |_, seconds, completed, _| {
                    tx.send((seconds, completed)).unwrap();
                },
            )
            .unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while player.status().position < 0.1 {
            assert!(
                std::time::Instant::now() < deadline,
                "{:?}",
                player.status().error
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(player.status().duration, 7200.0);
        player.pause(true);
        std::thread::sleep(Duration::from_millis(80));
        player.seek(7199.8).unwrap();
        player.pause(false);
        let (seconds, complete) = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(complete && seconds < 1.0);
        while player.status().state != "ended" {
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(player.status().underruns, 0);
        println!(
            "REMOTE_STREAM_PASS startup={}ms buffer={} frames",
            player.status().startup_ms,
            player.status().buffer_capacity_frames
        );
    }
    #[test]
    fn rejects_auth_failure_cross_origin_and_non_range_servers() {
        let server = Server::new();
        let mut bad = access(&server, SourceKind::Webdav, "/dav/");
        bad.secret = "wrong".into();
        assert!(bad.scan().unwrap_err().to_string().contains("401"));
        assert!(access(&server, SourceKind::Webdav, "/outside/")
            .scan()
            .is_err());
        assert!(access(&server, SourceKind::Webdav, "/bad/")
            .decoder("file.wav")
            .is_err());
        let mut bad = access(&server, SourceKind::Plex, "/");
        bad.source.url = format!("{}/?token=secret", server.base);
        assert!(bad.base().is_err());
    }

    #[test]
    fn digest_challenge_parsing_and_rfc_vector() {
        let challenge = parse_digest_challenge(
            "Basic realm=\"x\", Digest realm=\"testrealm@host.com\", qop=\"auth,auth-int\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\", algorithm=MD5",
        )
        .unwrap();
        assert_eq!(challenge.realm, "testrealm@host.com");
        assert_eq!(challenge.nonce, "dcd98b7102dd2f0e8b11d0f600bfb0c093");
        assert_eq!(challenge.qop.as_deref(), Some("auth,auth-int"));
        assert_eq!(
            challenge.opaque.as_deref(),
            Some("5ccc069c403ebaf9f0171e9517f40e41")
        );
        assert_eq!(challenge.algorithm.as_deref(), Some("MD5"));
        // RFC 2617 §3.5 的 MD5 + qop=auth 示例。
        let response = digest_response(
            "MD5",
            false,
            "Mufasa",
            "Circle Of Life",
            "testrealm@host.com",
            "dcd98b7102dd2f0e8b11d0f600bfb0c093",
            "GET",
            "/dir/index.html",
            Some("auth"),
            "00000001",
            "0a4f113b",
        )
        .unwrap();
        assert_eq!(response, "6629fae49393a05397450978507c4ef1");
        assert_eq!(
            digest_hex("MD5", "abc").unwrap(),
            "900150983cd24fb0d6963f7d28e17f72"
        );
        assert_eq!(
            digest_hex("SHA-256", "abc").unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert!(digest_hex("SHA-1", "abc").is_err());
    }

    #[test]
    fn digest_header_uses_challenge_fields_and_counts_nonces() {
        let mut source =
            MediaSource::new(SourceKind::Webdav, "test", "https://nas.local:5006/dav/");
        source.username = "user".into();
        let access = Access::new(source, "pass");
        let url = Url::parse("https://nas.local:5006/dav/").unwrap();
        let challenge = parse_digest_challenge(
            "Digest realm=\"dav\", nonce=\"n1\", qop=\"auth\", algorithm=SHA-256, opaque=\"op\"",
        )
        .unwrap();
        let first = access
            .digest_authorization(&challenge, &Method::GET, &url)
            .unwrap();
        assert!(first.starts_with("Digest "));
        assert!(first.contains("username=\"user\""));
        assert!(first.contains("algorithm=SHA-256"));
        assert!(first.contains("nc=00000001"));
        assert!(first.contains("qop=auth"));
        assert!(first.contains("opaque=\"op\""));
        let second = access
            .digest_authorization(&challenge, &Method::GET, &url)
            .unwrap();
        assert!(second.contains("nc=00000002"), "nonce 计数需要自增");

        let renewed =
            parse_digest_challenge("Digest realm=\"dav\", nonce=\"n2\", qop=\"auth\"").unwrap();
        let third = access
            .digest_authorization(&renewed, &Method::GET, &url)
            .unwrap();
        assert!(third.contains("nc=00000001"), "新 nonce 应重置计数");

        let legacy = parse_digest_challenge("Digest realm=\"dav\", nonce=\"old\"").unwrap();
        let legacy_header = access
            .digest_authorization(&legacy, &Method::GET, &url)
            .unwrap();
        assert!(
            !legacy_header.contains("qop=") && !legacy_header.contains("nc="),
            "无 qop 的旧式 Digest 不发送 qop / nc"
        );
    }

    #[test]
    fn redirect_targets_must_stay_on_the_same_origin() {
        let base = Url::parse("https://nas.local:5006/dav/").unwrap();
        let current = base.clone();
        assert_eq!(
            redirect_url(&base, &current, "music/").unwrap().as_str(),
            "https://nas.local:5006/dav/music/"
        );
        for location in [
            "https://evil.example/dav/",
            "http://nas.local:5006/dav/",
            "https://user:pass@nas.local:5006/dav/",
            "ftp://nas.local/dav/",
        ] {
            let error = redirect_url(&base, &current, location).unwrap_err();
            assert!(
                error.to_string().contains("其他站点")
                    || error.to_string().contains("账号信息")
                    || error.to_string().contains("无效"),
                "{location}: {error}"
            );
        }
    }

    #[test]
    fn html_and_sensitive_urls_are_recognized() {
        assert!(looks_like_html("text/html; charset=utf-8", b""));
        assert!(looks_like_html(
            "application/xml",
            b"<!DOCTYPE html><html></html>"
        ));
        assert!(!looks_like_html(
            "application/xml",
            b"<?xml version=\"1.0\"?><d:multistatus/>"
        ));
        let url = Url::parse("https://nas.local/dav/?X-Plex-Token=secret").unwrap();
        assert!(!safe_url(&url).contains("secret"));
        assert!(status_hint(StatusCode::FORBIDDEN).contains("权限"));
        assert!(status_hint(StatusCode::METHOD_NOT_ALLOWED).contains("WebDAV"));
    }

    #[test]
    fn follows_same_origin_redirect_for_propfind() {
        let server = Server::new();
        let access = access(&server, SourceKind::Webdav, "/moved/");
        let tracks = access.scan().unwrap();
        assert_eq!(tracks.len(), 1);
        // locator 保持 WebDAV 返回的百分号编码，播放时再拼接到最终 URL。
        assert_eq!(tracks[0].locator, "final/%E9%9F%B3%E4%B9%90.wav");
        let logs = server.requests.lock().unwrap();
        assert!(logs
            .iter()
            .any(|request| request.starts_with("PROPFIND /moved/ ")));
        assert!(logs
            .iter()
            .any(|request| request.starts_with("PROPFIND /moved/final/ ")));
    }

    #[test]
    fn refuses_cross_origin_redirect_without_retrying() {
        let server = Server::new();
        let error = access(&server, SourceKind::Webdav, "/cross/")
            .scan()
            .unwrap_err()
            .to_string();
        assert!(error.contains("其他站点"), "{error}");
        assert_eq!(server.requests.lock().unwrap().len(), 1);
    }

    #[test]
    fn answers_digest_challenge_and_keeps_credentials_in_headers() {
        let server = Server::new();
        let access = access(&server, SourceKind::Webdav, "/digest/");
        assert_eq!(access.scan().unwrap().len(), 1);
        // 第二次扫描应复用缓存的 nonce，首个请求就带 Digest（不再先吃 401）。
        assert_eq!(access.scan().unwrap().len(), 1);
        let logs = server.requests.lock().unwrap();
        let digest = logs
            .iter()
            .filter(|request| request.to_lowercase().contains("authorization: digest"))
            .count();
        assert_eq!(digest, 2, "每次扫描只发一次 Digest 请求");
        assert_eq!(
            logs.len(),
            3,
            "首次扫描先吃 401 再认证；第二次复用 nonce 直接成功"
        );
        assert!(logs
            .iter()
            .all(|request| !request.lines().next().unwrap_or("").contains("pass")));
    }

    #[test]
    fn forbidden_subfolder_is_skipped_and_readable_tracks_survive() {
        let server = Server::new();
        let tracks = access(&server, SourceKind::Webdav, "/skip/")
            .scan()
            .unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].title, "ok");
        assert!(server
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|request| request.starts_with("PROPFIND /skip/locked/ ")));
    }

    #[test]
    fn html_login_page_reports_webdav_hint() {
        let server = Server::new();
        let error = access(&server, SourceKind::Webdav, "/html/")
            .scan()
            .unwrap_err()
            .to_string();
        assert!(error.contains("HTML"), "{error}");
        assert!(error.contains("WebDAV"), "{error}");
    }
}
