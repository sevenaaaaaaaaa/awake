//! 听感档案（ListeningProfile）在桌面侧的落地：解析、校验、跨端键匹配、先验叠加。
//!
//! iOS 的 `ListeningProfile`（R4，version 1）把「校准先验 + 每首歌曲线」导出一份 JSON。
//! 桌面拿到它之后要先解决一件事：**两端的歌曲 id 不通用**。
//! iOS 的 `Song.id` 是 `UUID().uuidString`，桌面用曲库 track id，
//! 档案里唯一能对上的只有 `titles`（iOS id → 曲名）。
//! 所以这里按曲名归一化匹配；同名多首时**不猜**，把候选数交回界面让用户选。
//!
//! 这一段是纯逻辑：不碰文件、不碰 Tauri，`cargo test -p awake-core` 就能验证。
//! 它同时也是 S2「两端自检」的第一块地基——这里的每条规则都能单独断言。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt;

use crate::eq::BAND_COUNT;

/// 增益限幅，与 iOS `applyingPrior` 的 ±12 dB 逐段一致。
pub const MAX_GAIN_DB: f32 = 12.0;

/// 当前能读的档案版本。将来加字段（按设备先验等）时在这里加分支，
/// 未知版本必须明确报错，不能当成空档案静默导入。
pub const SUPPORTED_VERSION: u32 = 1;

/// 一条曲线凭什么成立——三段，缺一段就说缺（与 iOS `CurveBasis` 同构）。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct CurveBasis {
    /// 耳机或输出设备：iOS 侧取 AVAudioSession 路由名。
    #[serde(default)]
    pub headphone: String,
    /// 曲目侧的可核对指纹 + 这次调音的由头。
    #[serde(default)]
    pub track: String,
    /// 个人先验：校准版本号，没有校准时为「暂无校准」。
    #[serde(default)]
    pub prior: String,
}

/// 一首歌的曲线。存完整快照而不是差分：差分一旦基线变了就会算错。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SongCurve {
    pub gains: [f32; BAND_COUNT],
    #[serde(default)]
    pub apo: String,
    /// 保留 iOS 原值：manual / imported / measurement / ai。
    /// 桌面不解释它，只原样存与显示，避免两端枚举各自漂移。
    #[serde(default)]
    pub origin: String,
    #[serde(default)]
    pub source: String,
    /// ISO-8601 原样保留。跨端只用于显示，不参与计算，所以不解析成时间戳。
    #[serde(default)]
    pub updated_at: String,
    #[serde(default)]
    pub basis: Option<String>,
    #[serde(default)]
    pub basis_detail: Option<CurveBasis>,
}

impl Default for SongCurve {
    fn default() -> Self {
        Self {
            gains: [0.0; BAND_COUNT],
            apo: String::new(),
            origin: String::new(),
            source: String::new(),
            updated_at: String::new(),
            basis: None,
            basis_detail: None,
        }
    }
}

/// 个人先验（校准产出）。`headphone` 现在可能为空——R4 导出的档案没有这个字段，
/// S3 才会把它写成按设备分组的键，所以这里全程 Option，不能假定存在。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct EarPrior {
    pub version: u32,
    pub gains: [f32; BAND_COUNT],
    #[serde(default)]
    pub headphone: Option<String>,
    /// 这份先验来自哪台设备（档案顶层的 device 字段）。
    #[serde(default)]
    pub source_device: String,
    #[serde(default)]
    pub updated_at: String,
}

/// 一条被拒绝的曲线：不静默丢，带着原因交回界面。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RejectedCurve {
    pub id: String,
    pub title: String,
    pub reason: RejectReason,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RejectReason {
    /// 段数不是 31，套上去会错位。
    BandCount(usize),
    /// 出现 NaN / 无穷，写进 EQ 会把整条链路弄坏。
    NotFinite,
}

impl fmt::Display for RejectReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BandCount(n) => write!(f, "只有 {n} 段，不是 31 段"),
            Self::NotFinite => write!(f, "含非法数值"),
        }
    }
}

/// 解析后的听感档案。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ListeningProfile {
    pub version: u32,
    pub device: String,
    pub created_at: String,
    pub prior: Option<EarPrior>,
    /// key 是 iOS 的歌曲 id（UUID），只在档案内部有效。
    pub curves: HashMap<String, SongCurve>,
    /// iOS id → 曲名。跨端匹配的全部依据。
    pub titles: HashMap<String, String>,
    /// 段数或数值非法、被跳过的曲线。
    pub rejected: Vec<RejectedCurve>,
}

/// 档案解析失败的原因。全部可显示，不含内部细节。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileError {
    Json(String),
    UnsupportedVersion(u32),
    Empty,
}

impl fmt::Display for ProfileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Json(e) => write!(f, "档案不是合法的 JSON：{e}"),
            Self::UnsupportedVersion(v) => {
                write!(f, "档案版本 {v} 太新，这个版本只认到 {SUPPORTED_VERSION}")
            }
            Self::Empty => write!(f, "档案里既没有先验也没有按歌曲线"),
        }
    }
}

impl std::error::Error for ProfileError {}

// ---- 原始 DTO：iOS 的 JSON 是 camelCase + ISO-8601 字符串，和桌面存储的 snake_case 分开 ----

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawProfile {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    device: String,
    #[serde(default)]
    created_at: Option<String>,
    #[serde(default)]
    prior: Option<RawPrior>,
    #[serde(default)]
    curves: HashMap<String, RawCurve>,
    #[serde(default)]
    titles: HashMap<String, String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawPrior {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    gains: Vec<f32>,
    #[serde(default)]
    headphone: Option<String>,
    #[serde(default)]
    updated_at: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawCurve {
    #[serde(default)]
    gains: Vec<f32>,
    #[serde(default)]
    apo: String,
    #[serde(default)]
    origin: Option<String>,
    #[serde(default)]
    source: String,
    #[serde(default)]
    updated_at: Option<String>,
    #[serde(default)]
    basis: Option<String>,
    #[serde(default)]
    basis_detail: Option<RawBasis>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawBasis {
    #[serde(default)]
    headphone: String,
    #[serde(default)]
    track: String,
    #[serde(default)]
    prior: String,
}

/// 把 31 段浮点收成定长数组；段数不对或数值非法都返回 None，由调用方决定怎么报。
fn to_gains(values: &[f32]) -> Option<[f32; BAND_COUNT]> {
    if values.len() != BAND_COUNT {
        return None;
    }
    if !values.iter().all(|value| value.is_finite()) {
        return None;
    }
    let mut gains = [0.0f32; BAND_COUNT];
    gains.copy_from_slice(values);
    Some(gains)
}

/// 解析一份 iOS 导出的听感档案。
///
/// 段数不对的单条曲线会被跳过并记进 `rejected`，不废掉整份档案——
/// 一份档案里坏一条，不该让另外二十条也没法用。
pub fn parse_profile(json: &str) -> Result<ListeningProfile, ProfileError> {
    let raw: RawProfile =
        serde_json::from_str(json).map_err(|error| ProfileError::Json(error.to_string()))?;
    if raw.version != SUPPORTED_VERSION {
        return Err(ProfileError::UnsupportedVersion(raw.version));
    }

    // 先验坏掉时整份不采用：先验会被叠加到每一首歌上，算错的面积太大。
    let prior = match raw.prior {
        None => None,
        Some(raw_prior) => {
            let gains = to_gains(&raw_prior.gains).ok_or(ProfileError::Empty)?;
            Some(EarPrior {
                version: raw_prior.version,
                gains,
                headphone: raw_prior.headphone.filter(|name| !name.trim().is_empty()),
                source_device: raw.device.clone(),
                updated_at: raw_prior.updated_at.unwrap_or_default(),
            })
        }
    };

    let titles = raw.titles;
    let mut curves = HashMap::new();
    let mut rejected = Vec::new();
    // 排序后再遍历：档案是 HashMap，报错清单的顺序必须稳定，否则界面上一会儿一变。
    let mut ids: Vec<&String> = raw.curves.keys().collect();
    ids.sort();
    for id in ids {
        let raw_curve = &raw.curves[id];
        let title = titles.get(id).cloned().unwrap_or_default();
        let Some(gains) = to_gains(&raw_curve.gains) else {
            let reason = if raw_curve.gains.len() != BAND_COUNT {
                RejectReason::BandCount(raw_curve.gains.len())
            } else {
                RejectReason::NotFinite
            };
            rejected.push(RejectedCurve {
                id: id.clone(),
                title,
                reason,
            });
            continue;
        };
        curves.insert(
            id.clone(),
            SongCurve {
                gains,
                apo: raw_curve.apo.clone(),
                origin: raw_curve.origin.clone().unwrap_or_default(),
                source: raw_curve.source.clone(),
                updated_at: raw_curve.updated_at.clone().unwrap_or_default(),
                basis: raw_curve.basis.clone(),
                basis_detail: raw_curve
                    .basis_detail
                    .as_ref()
                    .map(|basis| CurveBasis {
                        headphone: basis.headphone.clone(),
                        track: basis.track.clone(),
                        prior: basis.prior.clone(),
                    }),
            },
        );
    }

    if curves.is_empty() && prior.is_none() {
        return Err(ProfileError::Empty);
    }

    Ok(ListeningProfile {
        version: raw.version,
        device: raw.device,
        created_at: raw.created_at.unwrap_or_default(),
        prior,
        curves,
        titles,
        rejected,
    })
}

/// 桌面曲库里的候选曲目：匹配只需要这几个字段，不把整个 `Track` 拖进来。
#[derive(Debug, Clone, PartialEq)]
pub struct TrackRef {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub duration: f64,
}

/// 一条落到桌面曲目上的曲线。
#[derive(Debug, Clone, PartialEq)]
pub struct CurveMatch {
    pub ios_id: String,
    pub desktop_id: String,
    pub title: String,
    pub curve: SongCurve,
}

/// 没能落地的曲线，带原因。
#[derive(Debug, Clone, PartialEq)]
pub struct Unmatched {
    pub ios_id: String,
    pub title: String,
    pub reason: UnmatchedReason,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnmatchedReason {
    /// 档案里没有这首歌的曲名，无从匹配。
    NoTitle,
    /// 桌面曲库里没有这个曲名。
    NotFound,
    /// 同名多首：**不猜**，让用户选。
    Ambiguous { candidates: usize },
}

impl fmt::Display for UnmatchedReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoTitle => write!(f, "档案里缺曲名"),
            Self::NotFound => write!(f, "曲库里没有这首"),
            Self::Ambiguous { candidates } => write!(f, "曲库里同名 {candidates} 首，要你选一首"),
        }
    }
}

/// 一次导入的落地结果。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MatchReport {
    pub matched: Vec<CurveMatch>,
    pub unmatched: Vec<Unmatched>,
    pub rejected: Vec<RejectedCurve>,
}

impl MatchReport {
    /// 能直接落库的条数。
    pub fn matched_count(&self) -> usize {
        self.matched.len()
    }

    /// 需要人处理（选曲或补曲名）的条数。
    pub fn needs_choice(&self) -> usize {
        self.unmatched.len()
    }
}

/// 曲名归一化：大小写、首尾空白、连续空白、全角空格都不该让同一首歌对不上。
///
/// 刻意不做「去掉 (Live) / (Remastered) 后缀」这类猜测：那会在同名不同版之间
/// 悄悄选错一首，而错配的曲线比没配上更难发现。
pub fn normalize_title(title: &str) -> String {
    let mut out = String::with_capacity(title.len());
    let mut last_space = true;
    for ch in title.chars() {
        let ch = match ch {
            '\u{3000}' => ' ',
            other => other,
        };
        if ch.is_whitespace() {
            if !last_space {
                out.push(' ');
                last_space = true;
            }
            continue;
        }
        last_space = false;
        for lower in ch.to_lowercase() {
            out.push(lower);
        }
    }
    out.trim().to_string()
}

/// 把档案里的曲线逐条对到桌面曲目上。顺序稳定（按曲名排序），可直接产出界面清单。
pub fn match_curves(profile: &ListeningProfile, tracks: &[TrackRef]) -> MatchReport {
    let mut index: HashMap<String, Vec<&TrackRef>> = HashMap::new();
    for track in tracks {
        index
            .entry(normalize_title(&track.title))
            .or_default()
            .push(track);
    }

    let mut ids: Vec<&String> = profile.curves.keys().collect();
    ids.sort();
    let mut matched = Vec::new();
    let mut unmatched = Vec::new();
    for id in ids {
        let curve = &profile.curves[id];
        let title = profile.titles.get(id).map(|t| t.trim()).unwrap_or("");
        if title.is_empty() {
            unmatched.push(Unmatched {
                ios_id: id.clone(),
                title: String::new(),
                reason: UnmatchedReason::NoTitle,
            });
            continue;
        }
        match index.get(&normalize_title(title)) {
            None => unmatched.push(Unmatched {
                ios_id: id.clone(),
                title: title.to_string(),
                reason: UnmatchedReason::NotFound,
            }),
            Some(candidates) if candidates.len() == 1 => {
                matched.push(CurveMatch {
                    ios_id: id.clone(),
                    desktop_id: candidates[0].id.clone(),
                    title: title.to_string(),
                    curve: curve.clone(),
                });
            }
            Some(candidates) => unmatched.push(Unmatched {
                ios_id: id.clone(),
                title: title.to_string(),
                reason: UnmatchedReason::Ambiguous {
                    candidates: candidates.len(),
                },
            }),
        }
    }

    MatchReport {
        matched,
        unmatched,
        rejected: profile.rejected.clone(),
    }
}

/// 把先验逐段叠加到一条曲线上，限幅 ±12 dB；关闭叠加或没有先验时原样返回。
///
/// 与 iOS `applyingPrior` 同一口径：先加成、后限幅，不是先限幅再加成。
pub fn apply_prior(
    gains: &[f32; BAND_COUNT],
    prior: Option<&EarPrior>,
    enabled: bool,
) -> [f32; BAND_COUNT] {
    let mut out = *gains;
    if !enabled {
        return out;
    }
    let Some(prior) = prior else {
        return out;
    };
    for (index, value) in out.iter_mut().enumerate() {
        *value = (*value + prior.gains[index]).clamp(-MAX_GAIN_DB, MAX_GAIN_DB);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn curve_json(gains: &str) -> String {
        format!(
            r#"{{"version":1,"device":"seven-iphone","createdAt":"2026-11-20T10:00:00Z",
            "prior":{{"version":3,"gains":[{}],"updatedAt":"2026-11-20T09:00:00Z"}},
            "curves":{{"UUID-A":{{"gains":[{}],"origin":"ai","source":"一句话调音",
            "updatedAt":"2026-11-20T09:30:00Z",
            "basisDetail":{{"headphone":"AirPods Pro","track":"3:42 · 44 kHz · 专辑 · 人声太远",
            "prior":"校准 v3"}}}}}},
            "titles":{{"UUID-A":"夜航"}}}}"#,
            vec!["1.0"; 31].join(","),
            gains
        )
    }

    #[test]
    fn parses_camel_case_profile_with_basis() {
        let profile = parse_profile(&curve_json(&vec!["2.0"; 31].join(","))).expect("应能解析");
        assert_eq!(profile.device, "seven-iphone");
        assert_eq!(profile.version, 1);
        let prior = profile.prior.expect("档案带先验");
        assert_eq!(prior.version, 3);
        assert_eq!(prior.source_device, "seven-iphone");
        assert!(prior.headphone.is_none(), "R4 档案没有 headphone 字段");
        let curve = profile.curves.get("UUID-A").expect("应有一条曲线");
        assert_eq!(curve.gains[0], 2.0);
        assert_eq!(curve.origin, "ai");
        let basis = curve.basis_detail.as_ref().expect("应带三段依据");
        assert_eq!(basis.headphone, "AirPods Pro");
        assert_eq!(basis.prior, "校准 v3");
        assert!(basis.track.contains("人声太远"));
    }

    #[test]
    fn rejects_unknown_version_instead_of_importing_empty() {
        let json = r#"{"version":9,"curves":{},"titles":{}}"#;
        assert_eq!(
            parse_profile(json),
            Err(ProfileError::UnsupportedVersion(9))
        );
    }

    #[test]
    fn skips_bad_curve_but_keeps_the_rest() {
        let json = r#"{"version":1,"curves":{
            "A":{"gains":[1.0,2.0]},"B":{"gains":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}},
            "titles":{"A":"短了","B":"正常"}}"#;
        let profile = parse_profile(json).expect("有一条好曲线就应接受整份档案");
        assert_eq!(profile.curves.len(), 1, "坏的跳过，好的留下");
        assert_eq!(profile.rejected.len(), 1);
        assert_eq!(profile.rejected[0].title, "短了");
        assert_eq!(profile.rejected[0].reason, RejectReason::BandCount(2));
    }

    #[test]
    fn non_finite_gains_are_rejected_at_the_array_boundary() {
        // 这条不能靠 JSON 触发：serde_json 自己就拒绝 NaN 与超范围指数（number out of range）。
        // 所以这层是给「以后从别的路径进 EQ」兜底的防御，必须单独断言。
        let mut nan = [1.0f32; BAND_COUNT];
        nan[7] = f32::NAN;
        assert!(to_gains(&nan).is_none(), "NaN 不能进 EQ");
        let mut infinite = [1.0f32; BAND_COUNT];
        infinite[0] = f32::INFINITY;
        assert!(to_gains(&infinite).is_none(), "无穷不能进 EQ");
        let short = [1.0f32; BAND_COUNT - 1];
        assert!(to_gains(&short).is_none(), "段数不对不能进 EQ");
    }

    #[test]
    fn empty_profile_is_an_error_not_a_silent_noop() {
        let json = r#"{"version":1,"curves":{},"titles":{}}"#;
        assert_eq!(parse_profile(json), Err(ProfileError::Empty));
    }

    fn track(id: &str, title: &str) -> TrackRef {
        TrackRef {
            id: id.into(),
            title: title.into(),
            artist: "某艺人".into(),
            duration: 222.0,
        }
    }

    fn profile_with(title: &str) -> ListeningProfile {
        let mut titles = HashMap::new();
        titles.insert("UUID-A".to_string(), title.to_string());
        let mut curves = HashMap::new();
        curves.insert("UUID-A".to_string(), SongCurve::default());
        ListeningProfile {
            version: 1,
            titles,
            curves,
            ..Default::default()
        }
    }

    #[test]
    fn matches_single_title_ignoring_case_and_spaces() {
        let profile = profile_with("  夜航  ");
        let tracks = vec![track("t1", "夜航"), track("t2", "别的歌")];
        let report = match_curves(&profile, &tracks);
        assert_eq!(report.matched.len(), 1);
        assert_eq!(report.matched[0].desktop_id, "t1");
        assert_eq!(report.unmatched.len(), 0);
    }

    #[test]
    fn same_title_twice_is_ambiguous_and_not_guessed() {
        let profile = profile_with("夜航");
        let tracks = vec![track("t1", "夜航"), track("t2", "夜航")];
        let report = match_curves(&profile, &tracks);
        assert!(report.matched.is_empty(), "同名不猜");
        assert_eq!(
            report.unmatched[0].reason,
            UnmatchedReason::Ambiguous { candidates: 2 }
        );
    }

    #[test]
    fn missing_title_and_missing_track_are_reported_separately() {
        let mut titles = HashMap::new();
        titles.insert("UUID-A".to_string(), String::new());
        let mut curves = HashMap::new();
        curves.insert("UUID-A".to_string(), SongCurve::default());
        let report = match_curves(
            &ListeningProfile {
                version: 1,
                titles,
                curves,
                ..Default::default()
            },
            &[track("t1", "夜航")],
        );
        assert_eq!(report.unmatched[0].reason, UnmatchedReason::NoTitle);

        let report = match_curves(&profile_with("不存在的歌"), &[track("t1", "夜航")]);
        assert_eq!(report.unmatched[0].reason, UnmatchedReason::NotFound);
    }

    #[test]
    fn prior_adds_then_clamps() {
        let gains = [10.0f32; BAND_COUNT];
        let prior = EarPrior {
            version: 2,
            gains: [5.0f32; BAND_COUNT],
            ..Default::default()
        };
        let out = apply_prior(&gains, Some(&prior), true);
        assert_eq!(out[0], 12.0, "10 + 5 应限幅到 12");
        let off = apply_prior(&gains, Some(&prior), false);
        assert_eq!(off[0], 10.0, "关闭叠加应原样返回");
        let none = apply_prior(&gains, None, true);
        assert_eq!(none[0], 10.0, "没有先验应原样返回");
    }
}

/// 依据里「曲目」那一段：可核对的指纹 + 这次调音的由头。
///
/// 放进 core 是因为两端要写出同一句话——iOS 的 `CurveBasis.make` 与本函数逐字一致，
/// 否则同一首歌在手机上写「3:42 · 44 kHz」，在桌面上写「222 秒」，依据就没法对照。
pub fn track_fingerprint(duration: f64, sample_rate: u32, album: &str, trigger: &str) -> String {
    let mut parts: Vec<String> = Vec::new();
    if duration > 0.0 {
        let total = duration as i64;
        parts.push(format!("{}:{:02}", total / 60, total % 60));
    }
    if sample_rate > 0 {
        parts.push(format!("{} kHz", sample_rate / 1000));
    }
    if !album.trim().is_empty() {
        parts.push(album.trim().to_string());
    }
    if !trigger.trim().is_empty() {
        parts.push(trigger.trim().to_string());
    }
    parts.join(" · ")
}

/// 依据里的耳机名还成立吗：大小写、空白、型号包含关系都容忍；
/// 任意一边为空时不判失效——不知道的事不能当成不符。
pub fn same_device(saved: &str, now: &str) -> bool {
    let saved = saved.trim().to_lowercase();
    let now = now.trim().to_lowercase();
    if saved.is_empty() || now.is_empty() {
        return true;
    }
    saved == now || saved.contains(&now) || now.contains(&saved)
}

/// 依据失效时给人看的一句话。成立时返回空串（界面据此不显示）。
///
/// 只解释「为什么失效」，不编造差多少 dB——那要等目标曲线库算得出来才写（S3 的正题）。
pub fn stale_hint(saved: &str, now: &str) -> String {
    if same_device(saved, now) {
        return String::new();
    }
    format!(
        "依据里记的是「{}」，现在用的是「{}」",
        saved.trim(),
        now.trim()
    )
}

#[cfg(test)]
mod basis_tests {
    use super::*;

    #[test]
    fn fingerprint_matches_ios_shape() {
        assert_eq!(
            track_fingerprint(222.0, 44100, "夜航", "人声太远"),
            "3:42 · 44 kHz · 夜航 · 人声太远"
        );
        assert_eq!(track_fingerprint(0.0, 0, "", ""), "");
        assert_eq!(track_fingerprint(65.0, 0, "", "自定义"), "1:05 · 自定义");
    }

    #[test]
    fn device_judgement_tolerates_case_and_model_containment() {
        assert!(same_device("AirPods Pro", "airpods pro"));
        assert!(same_device("AirPods Pro", "AirPods Pro (2nd generation)"));
        assert!(!same_device("AirPods Pro", "监听耳机"));
        assert!(same_device("", "AirPods Pro"), "不知道保存的是哪副");
        assert!(same_device("AirPods Pro", ""), "读不到当前设备");
    }

    #[test]
    fn stale_hint_names_both_sides_and_stays_empty_when_valid() {
        assert_eq!(stale_hint("AirPods Pro", "airpods pro"), "");
        assert_eq!(stale_hint("", "AirPods Pro"), "");
        let hint = stale_hint("AirPods Pro", "监听耳机");
        assert!(hint.contains("AirPods Pro"));
        assert!(hint.contains("监听耳机"));
        assert!(hint.starts_with("依据里记的是"), "文案要能直接显示");
    }
}
