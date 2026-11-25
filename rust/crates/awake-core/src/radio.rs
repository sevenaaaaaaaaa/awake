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

pub(crate) fn url_key(url: &str) -> String {
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

/// 探测结果缓存多久算新鲜。7 天：台站换编码不是天天发生，但也不能永远信旧结论。
pub const PROBE_TTL_MS: i64 = 7 * 24 * 60 * 60 * 1000;

/// 一次真实探测的结果。`playable` 是**解码器**的结论，不是台站自述。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProbeRecord {
    pub codec: String,
    pub sample_rate: u32,
    pub channels: usize,
    pub playable: bool,
    pub probed_at_ms: i64,
    #[serde(default)]
    pub note: String,
}

impl ProbeRecord {
    pub fn from_probe(codec: &str, sample_rate: u32, channels: usize, now_ms: i64) -> Self {
        let support = codec_support(codec);
        Self {
            codec: codec.trim().to_lowercase(),
            sample_rate,
            channels,
            playable: support == Playable::Yes,
            probed_at_ms: now_ms,
            note: match support {
                Playable::Yes => "解码器支持".to_string(),
                Playable::Unverified => "编码未验证".to_string(),
                Playable::No => "解码器不支持".to_string(),
            },
        }
    }
}

/// 台站缓存：键是 stationuuid，没有就退化成可播地址。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ProbeCache {
    #[serde(default)]
    pub stations: std::collections::BTreeMap<String, ProbeRecord>,
}

/// 缓存键：有 uuid 用 uuid，没有就用归一化后的可播地址。
/// 单独暴露成函数，是为了让 CLI 在没有 `Station` 的情况下也能用同一套键。
pub fn key_for(uuid: &str, url: &str) -> String {
    if !uuid.trim().is_empty() {
        uuid.trim().to_string()
    } else {
        url_key(url)
    }
}

pub fn station_key(station: &Station) -> String {
    key_for(&station.uuid, &station.url)
}

impl ProbeCache {
    /// 新鲜的探测记录；过期或没有就是 None。
    pub fn fresh(&self, key: &str, now_ms: i64) -> Option<&ProbeRecord> {
        self.stations
            .get(key)
            .filter(|record| now_ms.saturating_sub(record.probed_at_ms) < PROBE_TTL_MS)
    }

    pub fn record(&mut self, key: String, record: ProbeRecord) {
        self.stations.insert(key, record);
    }
}

/// 播放前的那一步：有新鲜结论就直接用，没有就探一次并记下来。
///
/// 返回**记录**而不是"能不能放"：能不能放还要看开关与本机二进制，那是 `plan` 的事。
/// 这样"探测"和"判决"各管一件事，开关改了不需要重新探测。
///
/// `prober` 返回 `None` 表示"这次没探成"——此时**不写缓存**，也不假装知道（下次播放再试）。
pub fn ensure_probed<F>(
    cache: &mut ProbeCache,
    station: &Station,
    now_ms: i64,
    prober: F,
) -> Option<ProbeRecord>
where
    F: FnOnce(&Station) -> Option<ProbeRecord>,
{
    let key = station_key(station);
    if let Some(record) = cache.fresh(&key, now_ms) {
        return Some(record.clone());
    }
    let record = prober(station)?;
    cache.record(key, record.clone());
    Some(record)
}

/// 一条流"怎么放"。这是开关与提醒的唯一判定处：界面只管显示 reason。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlaybackPlan {
    /// symphonia 直接解。
    Direct,
    /// 走 ffmpeg 兜底（用户打开了开关，且本机确实有 ffmpeg）。
    ViaFfmpeg,
    /// 放不了。`can_enable_ffmpeg` 为 true 时，界面应该给"去打开兜底"的入口。
    Blocked { reason: String, can_enable_ffmpeg: bool },
}

/// 判定规则（全部有测试钉住）：
/// - 解码器支持、或只是"未验证"（AAC+ 之类）→ 直接放，不预设失败；
/// - 支持不了（今天只有 Opus）→ 看开关与二进制：没开就提醒去开，开了没装就说缺什么，都具备才兜底。
pub fn plan(codec: &str, ffmpeg_enabled: bool, ffmpeg_present: bool) -> PlaybackPlan {
    let normalized = codec.trim().to_lowercase();
    match codec_support(&normalized) {
        Playable::Yes | Playable::Unverified => PlaybackPlan::Direct,
        Playable::No => {
            // 探测没给出编码时不要写"unknown 需要…"，那句话对用户没有信息量。
            let subject = if normalized.is_empty() || normalized == "unknown" {
                "这个编码".to_string()
            } else {
                normalized.clone()
            };
            if ffmpeg_enabled && ffmpeg_present {
                PlaybackPlan::ViaFfmpeg
            } else if ffmpeg_enabled && !ffmpeg_present {
                PlaybackPlan::Blocked {
                    reason: format!(
                        "{subject} 需要 ffmpeg 兜底，但本机找不到 ffmpeg（brew install ffmpeg）"
                    ),
                    can_enable_ffmpeg: false,
                }
            } else if ffmpeg_present {
                PlaybackPlan::Blocked {
                    reason: format!("{subject} 需要打开「用 ffmpeg 兜底」才能播放"),
                    can_enable_ffmpeg: true,
                }
            } else {
                PlaybackPlan::Blocked {
                    reason: format!(
                        "{subject} 需要 ffmpeg 兜底：先在设置里打开它，再装 ffmpeg（brew install ffmpeg）"
                    ),
                    can_enable_ffmpeg: true,
                }
            }
        }
    }
}

impl ProbeCache {
    /// 有新鲜结论时，直接给出"这条流该怎么放"的结论（含开关与二进制的判断）。
    /// `None` 表示还没探过——调用方应该先 probe 一次。
    pub fn decide(
        &self,
        station: &Station,
        now_ms: i64,
        ffmpeg_enabled: bool,
        ffmpeg_present: bool,
    ) -> Option<PlaybackPlan> {
        let record = self.fresh(&station_key(station), now_ms)?;
        Some(plan(&record.codec, ffmpeg_enabled, ffmpeg_present))
    }
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

    fn station(uuid: &str, url: &str, codec: &str) -> Station {
        Station {
            uuid: uuid.to_string(),
            name: "台".to_string(),
            url: url.to_string(),
            homepage: String::new(),
            favicon: String::new(),
            tags: Vec::new(),
            country: String::new(),
            codec: codec.to_string(),
            bitrate: 128,
            votes: 0,
            click_count: 0,
        }
    }

    #[test]
    fn fresh_cache_short_circuits_the_prober() {
        let mut cache = ProbeCache::default();
        let s = station("u1", "https://a.example/live", "opus");
        cache.record(
            station_key(&s),
            ProbeRecord::from_probe("mp3", 44_100, 2, 1_000),
        );
        let record = ensure_probed(&mut cache, &s, 2_000, |_| panic!("不该再探一次"));
        assert_eq!(record.expect("缓存新鲜就要返回记录").codec, "mp3", "缓存新鲜就以缓存为准");
    }

    #[test]
    fn stale_cache_probes_once_and_updates() {
        let mut cache = ProbeCache::default();
        let s = station("u1", "https://a.example/live", "mp3");
        cache.record(station_key(&s), ProbeRecord::from_probe("mp3", 44_100, 2, 0));

        let mut calls = 0;
        let record = ensure_probed(&mut cache, &s, PROBE_TTL_MS + 1, |_| {
            calls += 1;
            Some(ProbeRecord::from_probe("aac", 48_000, 2, PROBE_TTL_MS + 1))
        });
        assert_eq!(calls, 1, "过期要重新探，且只探一次");
        assert_eq!(record.expect("应返回新记录").codec, "aac");
        assert_eq!(cache.stations[&station_key(&s)].codec, "aac", "结论要被写回缓存");
    }

    #[test]
    fn failed_probe_writes_nothing_and_asks_again_next_time() {
        let mut cache = ProbeCache::default();
        let s = station("u1", "https://a.example/live", "mp3");
        let record = ensure_probed(&mut cache, &s, 5_000, |_| None);
        assert!(record.is_none(), "没探成就是 None");
        assert!(cache.stations.is_empty(), "没探成就不许写缓存");
    }

    #[test]
    fn probed_codec_beats_what_the_station_claims() {
        // 台站声明 opus（我们放不了），实测是 mp3（能放）——按实测走。
        let mut cache = ProbeCache::default();
        let s = station("u1", "https://a.example/live", "opus");
        let record = ensure_probed(&mut cache, &s, 1_000, |_| {
            Some(ProbeRecord::from_probe("mp3", 44_100, 2, 1_000))
        });
        assert_eq!(record.expect("应记录实测编码").codec, "mp3", "实测 mp3 压过声明的 opus");

        let mut cache2 = ProbeCache::default();
        let liar = station("u2", "https://b.example/live", "mp3");
        let record2 = ensure_probed(&mut cache2, &liar, 1_000, |_| {
            Some(ProbeRecord::from_probe("opus", 48_000, 2, 1_000))
        });
        let recorded = record2.expect("应记录实测编码");
        assert_eq!(recorded.codec, "opus");
        assert!(!recorded.playable, "声明 mp3 但实测 opus，要拦下来");
    }

    #[test]
    fn cached_opus_turns_into_a_plan_not_a_dead_end() {
        let mut cache = ProbeCache::default();
        let s = station("u1", "https://a.example/live", "opus");
        cache.record(station_key(&s), ProbeRecord::from_probe("opus", 48_000, 2, 1_000));

        // 开关关着：给出口，而不是"不能放"。
        match cache.decide(&s, 2_000, false, true).unwrap() {
            PlaybackPlan::Blocked { can_enable_ffmpeg, .. } => assert!(can_enable_ffmpeg),
            other => panic!("应是 Blocked，实际 {other:?}"),
        }
        // 开关开着且二进制在：走兜底。
        assert_eq!(
            cache.decide(&s, 2_000, true, true).unwrap(),
            PlaybackPlan::ViaFfmpeg
        );
        // 没探过：不编结论。
        assert_eq!(cache.decide(&s, 2_000, true, true), Some(PlaybackPlan::ViaFfmpeg));
        let empty = ProbeCache::default();
        assert!(empty.decide(&s, 2_000, true, true).is_none());
    }

    #[test]
    fn cache_key_falls_back_to_the_url_without_a_uuid() {
        let s = station("", "https://A.example/live/", "mp3");
        assert_eq!(station_key(&s), "https://a.example/live");
    }

    #[test]
    fn cache_round_trips_through_json() {
        let mut cache = ProbeCache::default();
        cache.record(
            "u1".to_string(),
            ProbeRecord::from_probe("aac", 44_100, 2, 1_234),
        );
        let text = serde_json::to_string(&cache).expect("缓存必须可序列化");
        let back: ProbeCache = serde_json::from_str(&text).expect("缓存必须可读回");
        assert_eq!(back, cache);
    }

    #[test]
    fn supported_codecs_go_direct_regardless_of_the_switch() {
        for codec in ["mp3", "aac", "flac", "ogg", "aac+"] {
            assert_eq!(
                plan(codec, false, false),
                PlaybackPlan::Direct,
                "{codec} 不该因为开关而改变"
            );
        }
    }

    #[test]
    fn opus_without_the_switch_asks_the_user_to_turn_it_on() {
        match plan("opus", false, true) {
            PlaybackPlan::Blocked { reason, can_enable_ffmpeg } => {
                assert!(can_enable_ffmpeg, "界面要给出口");
                assert!(reason.contains("打开"), "{reason}");
                assert!(reason.contains("ffmpeg"), "{reason}");
            }
            other => panic!("应该是 Blocked，实际 {other:?}"),
        }
    }

    #[test]
    fn opus_with_switch_but_no_binary_says_what_is_missing() {
        match plan("opus", true, false) {
            PlaybackPlan::Blocked { reason, can_enable_ffmpeg } => {
                assert!(!can_enable_ffmpeg, "开关已开，问题不在开关");
                assert!(reason.contains("找不到 ffmpeg"), "{reason}");
                assert!(reason.contains("brew install ffmpeg"), "{reason}");
            }
            other => panic!("应该是 Blocked，实际 {other:?}"),
        }
    }

    #[test]
    fn opus_with_switch_and_binary_goes_through_ffmpeg() {
        assert_eq!(plan("opus", true, true), PlaybackPlan::ViaFfmpeg);
        assert_eq!(plan("OPUS", true, true), PlaybackPlan::ViaFfmpeg, "大小写不影响");
    }

    #[test]
    fn unknown_label_does_not_read_like_a_codec_name() {
        match plan("unknown", false, true) {
            PlaybackPlan::Blocked { reason, .. } => {
                assert!(!reason.contains("unknown"), "别把 unknown 当编码念给用户：{reason}");
                assert!(reason.contains("ffmpeg"), "{reason}");
            }
            other => panic!("应是 Blocked，实际 {other:?}"),
        }
    }

    #[test]
    fn unknown_codec_is_blocked_and_offers_the_switch() {
        match plan("wmav2", false, false) {
            PlaybackPlan::Blocked { reason, can_enable_ffmpeg } => {
                assert!(can_enable_ffmpeg);
                assert!(reason.contains("wmav2"), "{reason}");
            }
            other => panic!("应该是 Blocked，实际 {other:?}"),
        }
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
