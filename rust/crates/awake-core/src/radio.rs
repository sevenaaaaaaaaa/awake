//! 公开电台目录（radio-browser）的**纯逻辑**部分：解析、筛选、去重。
//!
//! 网络请求放在 app 层，这个模块不联网，所以它能被单测穷举。
//! 官方约定（B 级，`https://api.radio-browser.info/`）：
//! - UA 要能读出是谁（不写等于被封）；
//! - 服务器列表用 DNS 查 `all.api.radio-browser.info`，随机起步、失败换下一个；
//! - 用户点播时回报 `/json/url/<stationuuid>`。
//!
//! 编解码的支持度是**我们自己的**判断，不是台站声明的：symphonia 能解的标 Yes，
//! 拿不准的标 Unverified（可以列出来，但默认不播），解不了的标 No（不进目录）。

use serde::{Deserialize, Serialize};

/// 可读的 UA：产品名 + 版本。升级版本后自动变化。
pub fn user_agent() -> String {
    format!("awake/{}", env!("CARGO_PKG_VERSION"))
}

pub fn discovery_host() -> &'static str {
    "all.api.radio-browser.info"
}

/// 点播回报地址。server 传实际响应的那台（例如 https://de1.api.radio-browser.info）。
pub fn click_url(server: &str, station_uuid: &str) -> String {
    format!("{}/json/url/{}", server.trim_end_matches('/'), station_uuid)
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Station {
    pub uuid: String,
    pub name: String,
    /// 实际可播地址（优先 url_resolved）。
    pub url: String,
    pub homepage: String,
    pub favicon: String,
    pub tags: Vec<String>,
    pub country: String,
    pub codec: String,
    pub bitrate: u32,
    pub votes: i64,
    pub click_count: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RadioError {
    Json(String),
    NotAnArray,
}

impl std::fmt::Display for RadioError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RadioError::Json(e) => write!(f, "台站数据不是合法 JSON：{e}"),
            RadioError::NotAnArray => write!(f, "台站数据应该是数组"),
        }
    }
}

impl std::error::Error for RadioError {}

#[derive(Deserialize)]
struct RawStation {
    #[serde(default)]
    stationuuid: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    url_resolved: String,
    #[serde(default)]
    url: String,
    #[serde(default)]
    homepage: String,
    #[serde(default)]
    favicon: String,
    #[serde(default)]
    tags: String,
    #[serde(default)]
    country: String,
    #[serde(default)]
    codec: String,
    #[serde(default)]
    bitrate: u32,
    #[serde(default)]
    votes: i64,
    #[serde(default)]
    clickcount: i64,
}

pub fn parse_stations(json: &str) -> Result<Vec<Station>, RadioError> {
    let raw: Vec<RawStation> =
        serde_json::from_str(json).map_err(|e| RadioError::Json(e.to_string()))?;
    Ok(raw
        .into_iter()
        .filter_map(|r| {
            let url = if !r.url_resolved.trim().is_empty() { r.url_resolved } else { r.url };
            if url.trim().is_empty() || r.name.trim().is_empty() {
                return None;
            }
            Some(Station {
                uuid: r.stationuuid,
                name: r.name.trim().to_string(),
                url,
                homepage: r.homepage,
                favicon: r.favicon,
                tags: r
                    .tags
                    .split(',')
                    .map(|t| t.trim().to_string())
                    .filter(|t| !t.is_empty())
                    .collect(),
                country: r.country,
                codec: r.codec.trim().to_lowercase(),
                bitrate: r.bitrate,
                votes: r.votes,
                click_count: r.clickcount,
            })
        })
        .collect())
}

/// 我们对某个编码的判断，而不是台站的自述。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Playable {
    Yes,
    /// 没验过：可以列出来，但默认不播，界面标"未验证"。
    Unverified,
    No,
}

/// 今天的结论全部来自实测（见 docs 第 10.6 节的表），不是猜的：
/// - mp3 / aac / ogg-vorbis / flac 都真实解出了音频；
/// - **opus 解不了**：symphonia 0.5.5 根本没有 opus 解码器（features 里没有 opus），
///   实测报 `unsupported codec`。要支持得换解码器或走 ffmpeg 兜底，不是换个标记的事。
/// - AAC+ / HE-AAC 仍是未验证（实测样本是普通 ADTS AAC-LC）。
pub fn codec_support(codec: &str) -> Playable {
    match codec.trim().to_lowercase().as_str() {
        "mp3" | "flac" | "ogg" | "vorbis" | "aac" => Playable::Yes,
        "aac+" | "aacp" => Playable::Unverified,
        "opus" => Playable::No,
        _ => Playable::No,
    }
}

/// 能不能进目录（No 的不进，省得用户点了没声）。
pub fn is_listable(station: &Station) -> bool {
    codec_support(&station.codec) != Playable::No
}

fn url_key(url: &str) -> String {
    let mut key = url.trim().to_lowercase();
    while key.ends_with('/') {
        key.pop();
    }
    key
}

/// 按可播地址去重：同一条流只留码率最高、其次票数最高的一条，顺序按首次出现。
pub fn dedupe(stations: Vec<Station>) -> Vec<Station> {
    let mut out: Vec<Station> = Vec::new();
    for station in stations {
        let key = url_key(&station.url);
        match out.iter().position(|s| url_key(&s.url) == key) {
            Some(idx) => {
                let current = &out[idx];
                if (station.bitrate, station.votes) > (current.bitrate, current.votes) {
                    out[idx] = station;
                }
            }
            None => out.push(station),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = r#"[
      {"stationuuid":"u1","name":" 夜晚爵士 ","url_resolved":"https://a.example/live.mp3","url":"https://fallback.example/x","homepage":"https://a.example","favicon":"https://a.example/f.png","tags":"jazz, smooth ,,","country":"US","codec":"MP3","bitrate":128,"votes":10,"clickcount":99},
      {"stationuuid":"u2","name":"古典台","url_resolved":"https://b.example/live","url":"","homepage":"","favicon":"","tags":"classical","country":"DE","codec":"opus","bitrate":192,"votes":5,"clickcount":7},
      {"stationuuid":"u3","name":"无地址台","url_resolved":"","url":"","homepage":"","favicon":"","tags":"","country":"","codec":"mp3","bitrate":0,"votes":0,"clickcount":0},
      {"stationuuid":"u4","name":"同一路流","url_resolved":"https://a.example/live.mp3/","url":"","homepage":"","favicon":"","tags":"jazz","country":"US","codec":"mp3","bitrate":320,"votes":1,"clickcount":1}
    ]"#;

    #[test]
    fn parses_and_normalizes_stations() {
        let stations = parse_stations(FIXTURE).expect("fixture 必须可解析");
        assert_eq!(stations.len(), 3, "没有可播地址的台要被丢掉");
        let first = &stations[0];
        assert_eq!(first.name, "夜晚爵士");
        assert_eq!(first.url, "https://a.example/live.mp3", "优先 url_resolved");
        assert_eq!(first.codec, "mp3", "编码统一小写");
        assert_eq!(first.tags, vec!["jazz".to_string(), "smooth".to_string()]);
        assert_eq!(first.click_count, 99);
    }

    #[test]
    fn broken_json_is_an_error_not_an_empty_list() {
        assert!(matches!(parse_stations("not json"), Err(RadioError::Json(_))));
    }

    #[test]
    fn codec_support_is_our_judgement() {
        assert_eq!(codec_support("mp3"), Playable::Yes);
        assert_eq!(codec_support("FLAC"), Playable::Yes, "实测：OGG 台里装的其实是 FLAC，也解出来了");
        assert_eq!(codec_support("aac"), Playable::Yes, "实测：ADTS AAC 解出 6.01 秒");
        assert_eq!(codec_support("aac+"), Playable::Unverified, "HE-AAC 没有样本，不许装作验过");
        assert_eq!(
            codec_support("opus"),
            Playable::No,
            "实测：symphonia 0.5.5 没有 opus 解码器，报 unsupported codec"
        );
        assert_eq!(codec_support("wmav2"), Playable::No);
    }

    #[test]
    fn dedupe_keeps_the_best_stream_and_the_first_position() {
        let stations = parse_stations(FIXTURE).unwrap();
        let deduped = dedupe(stations);
        assert_eq!(deduped.len(), 2);
        assert_eq!(deduped[0].uuid, "u4", "同一路流保留码率更高的那条");
        assert_eq!(deduped[0].bitrate, 320);
        assert_eq!(deduped[1].uuid, "u2", "顺序按首次出现");
    }

    #[test]
    fn opus_station_is_not_listed_because_there_is_no_decoder() {
        let stations = parse_stations(FIXTURE).unwrap();
        let opus = stations.iter().find(|s| s.uuid == "u2").unwrap();
        assert!(!is_listable(opus), "放了也没声，不如不列");
    }

    #[test]
    fn click_url_and_user_agent_follow_the_contract() {
        assert_eq!(
            click_url("https://de1.api.radio-browser.info/", "abc"),
            "https://de1.api.radio-browser.info/json/url/abc"
        );
        assert!(user_agent().starts_with("awake/"), "UA 要能读出是谁");
        assert_eq!(discovery_host(), "all.api.radio-browser.info");
    }
}
