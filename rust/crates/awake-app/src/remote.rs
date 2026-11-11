//! User-configured WebDAV and Plex. No source catalog, search index, or sharing endpoint.
use anyhow::{Context, Result};
use awake_core::{
    decode::StreamDecoder,
    models::{now_ms, SourceKind},
    pipeline::DecoderFactory,
    MediaSource, Track,
};
use reqwest::{
    blocking::{Client, RequestBuilder},
    header, Url,
};
use std::{
    io::{Read, Seek, SeekFrom},
    sync::Arc,
    time::Duration,
};

#[derive(Clone)]
pub struct Access {
    pub source: MediaSource,
    pub secret: String,
}
impl Access {
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
            .build()?)
    }
    fn request(&self, client: &Client, method: reqwest::Method, url: Url) -> RequestBuilder {
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
    fn bytes(&self, method: reqwest::Method, url: Url, depth: Option<u8>) -> Result<Vec<u8>> {
        let client = self.client()?;
        let mut request = self.request(&client, method, url);
        if let Some(depth) = depth {
            request = request
                .header("Depth", depth.to_string())
                .body(
                    "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:allprop/></d:propfind>",
                )
                .header(header::CONTENT_TYPE, "application/xml");
        }
        let response = request
            .send()
            .map_err(|_| anyhow::anyhow!("来源连接失败，请检查网络和地址"))?;
        anyhow::ensure!(
            response.status().is_success(),
            "来源返回 HTTP {}",
            response.status().as_u16()
        );
        let mut bytes = Vec::new();
        response
            .take(16 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        anyhow::ensure!(
            bytes.len() <= 16 * 1024 * 1024,
            "来源目录响应过大，请选择更小的根目录"
        );
        Ok(bytes)
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
        while let Some((folder, depth)) = pending.pop() {
            if !seen.insert(folder.to_string()) {
                continue;
            }
            anyhow::ensure!(seen.len() <= 5000 && depth <= 32, "目录层级或数量超出限制");
            let xml = String::from_utf8(self.bytes(
                reqwest::Method::from_bytes(b"PROPFIND")?,
                folder.clone(),
                Some(1),
            )?)?;
            let doc = roxmltree::Document::parse(&xml)?;
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
                let url = folder.join(href)?;
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
                    if url != folder && !seen.contains(url.as_str()) {
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
        Ok(tracks)
    }
    fn plex(&self) -> Result<Vec<Track>> {
        let sections: serde_json::Value = serde_json::from_slice(&self.bytes(
            reqwest::Method::GET,
            self.url("library/sections")?,
            None,
        )?)?;
        let dirs = sections["MediaContainer"]["Directory"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Plex 目录格式无效"))?;
        let mut tracks = Vec::new();
        for section in dirs.iter().filter(|s| s["type"] == "artist") {
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
                let data: serde_json::Value =
                    serde_json::from_slice(&self.bytes(reqwest::Method::GET, url, None)?)?;
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
        let response = self
            .access
            .request(&self.client, reqwest::Method::GET, self.url.clone())
            .header(header::RANGE, format!("bytes={start}-{end}"))
            .header(header::ACCEPT_ENCODING, "identity")
            .send()
            .map_err(|_| anyhow::anyhow!("远程音频读取失败，请检查来源连接"))?;
        anyhow::ensure!(
            response.status() == reqwest::StatusCode::PARTIAL_CONTENT,
            "服务器不支持可定位的 HTTP Range 播放（HTTP {}）；请使用挂载目录",
            response.status().as_u16()
        );
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
                        if !req
                            .to_lowercase()
                            .contains("authorization: basic dxnlcjpwyxnz")
                        {
                            ("401 Unauthorized", "text/plain", vec![], String::new())
                        } else {
                            let href = if target.starts_with("/outside/") {
                                String::from("https://example.invalid/private.wav")
                            } else {
                                String::from("/dav/%E9%9F%B3%E4%B9%90.wav")
                            };
                            ("207 Multi-Status","application/xml",format!("<d:multistatus xmlns:d='DAV:'><d:response><d:href>{href}</d:href><d:propstat><d:prop><d:getcontentlength>1382400044</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>").into_bytes(),String::new())
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
        Access {
            source,
            secret: "pass".into(),
        }
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
}
