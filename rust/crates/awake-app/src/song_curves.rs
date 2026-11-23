//! 桌面侧「按歌记忆」与听感档案落地（S1）。
//!
//! 三个动作刻意分开，是为了让「导入」和「生效」解耦：
//! - 导入 = 落库（`song_curves.json` 里的按歌曲线 + 一份先验），**不动当前播放曲线**；
//! - 生效 = 切歌时按曲查询：有记忆就用记忆，没有就回落链路曲线；
//! - 所以连点两次导入不会叠加两次（R4 启发 17 的坑，从结构上避开，而不是靠弹窗提醒）。
//!
//! 一条明确的取舍，写在这里免得以后当成 bug：
//! **先验只叠加到「这首歌的记忆曲线」上，不叠加链路曲线。** 因为桌面运行态的
//! `gains` 就是用户此刻听到的一切，再叠一次先验会重复。要让先验作用于所有歌，
//! 得先把「链路基线」从运行态里独立出来——那是 S3「叠加过程可见」的正题。

use crate::experience;
use crate::AppState;
use awake_core::eq::BAND_COUNT;
use awake_core::listening::{
    apply_prior, match_curves, normalize_title, parse_profile, same_device, stale_hint,
    track_fingerprint, CurveBasis, EarPrior, SongCurve, TrackRef, UnmatchedReason,
};
use awake_core::models::{now_ms, Track};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use tauri::State;

const STORE_FILE: &str = "song_curves.json";

/// 桌面侧的按歌记忆 + 一份先验。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SongCurveStore {
    /// 桌面 track id → 曲线。
    #[serde(default)]
    pub curves: HashMap<String, SongCurve>,
    /// 最近一次导入的先验。S3 才按耳机分组，现在只有一份。
    #[serde(default)]
    pub prior: Option<EarPrior>,
    /// 这份记忆是从哪来的，界面要写明。
    #[serde(default)]
    pub imported: Option<ImportSource>,
    /// 导入了但没能对上本地曲目的曲线。留着不是垃圾：用户指定一首之后就能落库。
    #[serde(default)]
    pub pending: Vec<PendingCurve>,
}

/// 一条等待指定的曲线。曲线本身必须留着——只记「有一首没匹配」等于丢掉它。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PendingCurve {
    pub ios_id: String,
    pub title: String,
    /// 导入当时的判断，原样保留，界面照实说。
    pub reason: String,
    /// 导入当时同名几首（0 = 找不到）。
    pub candidates: usize,
    pub imported_at: String,
    pub curve: SongCurve,
}

/// 一条候选曲目。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CandidateView {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub duration: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct PendingView {
    pub ios_id: String,
    pub title: String,
    pub reason: String,
    pub candidates: Vec<CandidateView>,
}

/// 同名优先；同名没有时退一步用「标题互相包含」，这样
/// iOS 的「夜航 (Live)」还能对上桌面的「夜航」。
/// 仍然不猜：只是把候选摆出来，点哪首由人来定。
fn candidates_for(title: &str, tracks: &[TrackRef]) -> Vec<CandidateView> {
    let key = normalize_title(title);
    if key.is_empty() {
        return Vec::new();
    }
    // 精确同名在前；包含关系（「夜航」↔「夜航 (Live)」）接在后。
    // 两者都摆出来，是因为 iOS 与桌面常把同一首歌写成不同长度，只给「精确」反而选不到。
    let mut hits: Vec<&TrackRef> = tracks
        .iter()
        .filter(|track| normalize_title(&track.title) == key)
        .collect();
    let mut loose: Vec<&TrackRef> = tracks
        .iter()
        .filter(|track| {
            let candidate = normalize_title(&track.title);
            !candidate.is_empty()
                && candidate != key
                && (candidate.contains(&key) || key.contains(&candidate))
        })
        .collect();
    loose.sort_by_key(|track| (normalize_title(&track.title).len() as i64 - key.len() as i64).abs());
    hits.extend(loose);
    hits.into_iter()
        .take(8)
        .map(|track| CandidateView {
            id: track.id.clone(),
            title: track.title.clone(),
            artist: track.artist.clone(),
            duration: track.duration,
        })
        .collect()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportSource {
    pub device: String,
    /// ISO-8601，和档案里的时间同一形态。
    pub at: String,
    pub curves: usize,
}

/// 读盘。坏文件不静默覆盖：先留一份副本，再从空库起步。
pub fn load(dir: &Path) -> SongCurveStore {
    let path = dir.join(STORE_FILE);
    match std::fs::read(&path) {
        Ok(bytes) => match serde_json::from_slice::<SongCurveStore>(&bytes) {
            Ok(store) => store,
            Err(error) => {
                let backup = dir.join(format!("song-curves-corrupt-{}.json", now_ms()));
                let _ = std::fs::copy(&path, &backup);
                log::error!(
                    "按歌曲线读取失败：{error}；原文件已留到 {}",
                    backup.display()
                );
                SongCurveStore::default()
            }
        },
        Err(_) => SongCurveStore::default(),
    }
}

/// 原子写：先写临时文件再改名，进程中途退出也不会留下半份 JSON。
fn save(dir: &Path, store: &SongCurveStore) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(store).map_err(|error| error.to_string())?;
    let temp = dir.join(format!("{STORE_FILE}.tmp"));
    std::fs::write(&temp, bytes).map_err(|error| error.to_string())?;
    std::fs::rename(&temp, dir.join(STORE_FILE)).map_err(|error| error.to_string())
}

/// 读-改-存。写完才更新内存，写失败时内存与磁盘保持一致。
fn mutate<T>(
    state: &AppState,
    f: impl FnOnce(&mut SongCurveStore) -> Result<T, String>,
) -> Result<T, String> {
    let mut store = state.song_curves.lock();
    let mut next = store.clone();
    let result = f(&mut next)?;
    save(&state.data_dir, &next)?;
    *store = next;
    Ok(result)
}

fn to_bands(values: &[f32]) -> Result<[f32; BAND_COUNT], String> {
    if values.len() != BAND_COUNT {
        return Err(format!("需要 {BAND_COUNT} 段，收到 {} 段", values.len()));
    }
    if !values.iter().all(|value| value.is_finite()) {
        return Err("曲线里有非法数值".into());
    }
    let mut bands = [0.0f32; BAND_COUNT];
    bands.copy_from_slice(values);
    Ok(bands)
}

fn output_name() -> String {
    experience::output_device_name()
}

fn iso_now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

// 指纹与「依据是否成立」的判定都在 core（`listening::track_fingerprint` /
// `listening::same_device`）：两端必须写出同一句话，判定也必须同一套规则。

// ---- 命令 ----

#[derive(Debug, Serialize)]
pub struct UnmatchedView {
    pub title: String,
    pub reason: String,
}

#[derive(Debug, Serialize)]
pub struct RejectedView {
    pub title: String,
    pub reason: String,
}

#[derive(Debug, Serialize)]
pub struct PriorView {
    pub version: u32,
    pub device: String,
    pub headphone: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ImportOutcome {
    pub device: String,
    /// 档案里一共有多少首（含落不下来的）。
    pub curves_total: usize,
    pub matched: usize,
    pub unmatched: Vec<UnmatchedView>,
    pub rejected: Vec<RejectedView>,
    pub prior: Option<PriorView>,
    /// 当前正在播放的歌如果命中了，前端据此立刻套用；否则只落库。
    pub applied_track: Option<String>,
    /// 一句可直接显示的中文说明。
    pub note: String,
}

/// 导入一份 iOS 导出的听感档案：按曲落到本地曲目，不碰当前播放曲线。
#[tauri::command]
pub fn import_listening_profile(
    json: String,
    state: State<'_, AppState>,
) -> Result<ImportOutcome, String> {
    let profile = parse_profile(&json).map_err(|error| error.to_string())?;
    let tracks: Vec<TrackRef> = {
        let library = state.library.lock();
        library
            .snapshot
            .tracks
            .iter()
            .map(|track| TrackRef {
                id: track.id.clone(),
                title: track.title.clone(),
                artist: track.artist.clone(),
                duration: track.duration,
            })
            .collect()
    };
    let report = match_curves(&profile, &tracks);

    let current = state.player.status().current;
    let applied_track = current.and_then(|id| {
        report
            .matched
            .iter()
            .find(|item| item.desktop_id == id)
            .map(|item| item.desktop_id.clone())
    });

    let device = profile.device.clone();
    let curves_total = profile.curves.len();
    let prior_view = profile.prior.as_ref().map(|prior| PriorView {
        version: prior.version,
        device: device.clone(),
        headphone: prior.headphone.clone(),
    });
    let matched_count = report.matched.len();
    let unmatched: Vec<UnmatchedView> = report
        .unmatched
        .iter()
        .map(|item| UnmatchedView {
            title: if item.title.trim().is_empty() {
                "（档案里没有曲名）".to_string()
            } else {
                item.title.clone()
            },
            reason: item.reason.to_string(),
        })
        .collect();
    let rejected: Vec<RejectedView> = report
        .rejected
        .iter()
        .map(|item| RejectedView {
            title: if item.title.trim().is_empty() {
                "（未知曲目）".to_string()
            } else {
                item.title.clone()
            },
            reason: item.reason.to_string(),
        })
        .collect();

    let source = ImportSource {
        device: device.clone(),
        at: iso_now(),
        curves: matched_count,
    };
    // 落不下来的曲线整条留着，等用户指定。
    let pending: Vec<PendingCurve> = report
        .unmatched
        .iter()
        .map(|item| PendingCurve {
            ios_id: item.ios_id.clone(),
            title: item.title.clone(),
            reason: item.reason.to_string(),
            candidates: match item.reason {
                UnmatchedReason::Ambiguous { candidates } => candidates,
                _ => 0,
            },
            imported_at: iso_now(),
            curve: profile.curves.get(&item.ios_id).cloned().unwrap_or_default(),
        })
        .collect();
    let curves = report.matched;
    let had_curves = mutate(state.inner(), |store| {
        let before = store.curves.len();
        for item in curves {
            store.curves.insert(item.desktop_id, item.curve);
        }
        if let Some(prior) = profile.prior.clone() {
            store.prior = Some(prior);
        }
        store.imported = Some(source);
        // 一次导入就是一份完整档案，待指定清单整体替换，不做跨档案合并。
        // 否则两次导入的「同一个 iOS id」该听谁的，会变成没人能解释的问题。
        store.pending = pending;
        Ok(before)
    })?;

    let mut note = format!("《{device}》的档案：{matched_count}/{curves_total} 首落到本地曲目");
    if had_curves == 0 {
        note.push_str("（此前没有记忆）");
    }
    if !unmatched.is_empty() {
        note.push_str(&format!("，{} 首待指定", unmatched.len()));
    }
    if !rejected.is_empty() {
        note.push_str(&format!("，{} 首不合格已跳过", rejected.len()));
    }
    if prior_view.is_some() {
        note.push_str("；先验已记录，播放时叠加");
    }

    Ok(ImportOutcome {
        device,
        curves_total,
        matched: matched_count,
        unmatched,
        rejected,
        prior: prior_view,
        applied_track,
        note,
    })
}

#[derive(Debug, Serialize)]
pub struct CurveResolution {
    pub track_id: String,
    pub title: String,
    /// "song" = 这首歌有记忆；"chain" = 回落链路曲线。
    pub source: String,
    /// 最终要写进 EQ 的 31 段（有记忆时已叠加先验并限幅）。
    pub gains: Vec<f32>,
    /// 这首歌记忆的原始 31 段（没有记忆时为空）。
    pub base: Option<Vec<f32>>,
    pub basis: Option<CurveBasis>,
    /// 依据里的耳机名与当前输出对不上。
    pub basis_stale: bool,
    /// 失效时可直接显示的一句话；成立时为空串。
    pub stale_hint: String,
    pub headphone_now: String,
    pub headphone_saved: Option<String>,
    pub prior_applied: bool,
    /// 「校准 v3」或「暂无校准」。
    pub prior_display: String,
}

/// 切歌时问一句：这首歌该用什么曲线。
#[tauri::command]
pub fn curve_for_track(
    track_id: String,
    chain_gains: Vec<f32>,
    apply_prior_enabled: bool,
    state: State<'_, AppState>,
) -> Result<CurveResolution, String> {
    let chain = to_bands(&chain_gains)?;
    let title = state
        .library
        .lock()
        .snapshot
        .tracks
        .iter()
        .find(|track| track.id == track_id)
        .map(|track| track.title.clone())
        .unwrap_or_default();
    let (song, prior) = {
        let store = state.song_curves.lock();
        (store.curves.get(&track_id).cloned(), store.prior.clone())
    };
    let headphone_now = output_name();
    let prior_display = prior
        .as_ref()
        .map(|prior| format!("校准 v{}", prior.version))
        .unwrap_or_else(|| "暂无校准".to_string());

    // 没有记忆时原样返回链路曲线：链路曲线就是用户此刻听到的声音，
    // 再叠一次先验会重复（见文件头的取舍说明）。
    let Some(song) = song else {
        return Ok(CurveResolution {
            track_id,
            title,
            source: "chain".to_string(),
            gains: chain.to_vec(),
            base: None,
            basis: None,
            basis_stale: false,
            stale_hint: String::new(),
            headphone_now,
            headphone_saved: None,
            prior_applied: false,
            prior_display,
        });
    };

    let gains = apply_prior(&song.gains, prior.as_ref(), apply_prior_enabled);
    let headphone_saved = song
        .basis_detail
        .as_ref()
        .map(|basis| basis.headphone.clone())
        .filter(|name| !name.trim().is_empty());
    let basis_stale = headphone_saved
        .as_ref()
        .map(|saved| !same_device(saved, &headphone_now))
        .unwrap_or(false);
    let hint = headphone_saved
        .as_ref()
        .map(|saved| stale_hint(saved, &headphone_now))
        .unwrap_or_default();

    Ok(CurveResolution {
        track_id,
        title,
        source: "song".to_string(),
        gains: gains.to_vec(),
        base: Some(song.gains.to_vec()),
        basis: song.basis_detail.clone(),
        basis_stale,
        stale_hint: hint,
        headphone_now,
        headphone_saved,
        prior_applied: apply_prior_enabled && prior.is_some(),
        prior_display,
    })
}

/// 「记住这首歌」：把当前曲线连同三段依据写到这首歌上。
#[tauri::command]
pub fn remember_song_curve(
    track_id: String,
    gains: Vec<f32>,
    trigger: String,
    state: State<'_, AppState>,
) -> Result<CurveBasis, String> {
    let bands = to_bands(&gains)?;
    let track: Track = {
        let library = state.library.lock();
        library
            .snapshot
            .tracks
            .iter()
            .find(|track| track.id == track_id)
            .cloned()
            .ok_or("曲库里没有这首歌")?
    };
    let headphone = output_name();
    let prior_text = state
        .song_curves
        .lock()
        .prior
        .as_ref()
        .map(|prior| format!("校准 v{}", prior.version))
        .unwrap_or_else(|| "暂无校准".to_string());
    let basis = CurveBasis {
        headphone,
        track: track_fingerprint(track.duration, track.sample_rate, &track.album, &trigger),
        prior: prior_text,
    };
    let source = if trigger.trim().is_empty() {
        "桌面手动".to_string()
    } else {
        trigger.trim().to_string()
    };
    let curve = SongCurve {
        gains: bands,
        apo: String::new(),
        origin: "manual".to_string(),
        source,
        updated_at: iso_now(),
        basis: None,
        basis_detail: Some(basis.clone()),
    };
    mutate(state.inner(), |store| {
        store.curves.insert(track_id, curve);
        Ok(())
    })?;
    Ok(basis)
}

/// 忘掉这首歌的记忆，回到链路曲线。
#[tauri::command]
pub fn forget_song_curve(track_id: String, state: State<'_, AppState>) -> Result<bool, String> {
    mutate(state.inner(), |store| Ok(store.curves.remove(&track_id).is_some()))
}

/// 列出等待指定的曲线，候选每次现算（曲库会变）。
#[tauri::command]
pub fn pending_curves(state: State<'_, AppState>) -> Vec<PendingView> {
    let tracks: Vec<TrackRef> = {
        let library = state.library.lock();
        library
            .snapshot
            .tracks
            .iter()
            .map(|track| TrackRef {
                id: track.id.clone(),
                title: track.title.clone(),
                artist: track.artist.clone(),
                duration: track.duration,
            })
            .collect()
    };
    let store = state.song_curves.lock();
    store
        .pending
        .iter()
        .map(|item| PendingView {
            ios_id: item.ios_id.clone(),
            title: item.title.clone(),
            reason: item.reason.clone(),
            candidates: candidates_for(&item.title, &tracks),
        })
        .collect()
}

/// 把一条待指定的曲线搬进记忆。纯逻辑，命令与测试共用同一条路径。
fn assign_pending(
    store: &mut SongCurveStore,
    ios_id: &str,
    track_id: &str,
) -> Result<(), String> {
    let Some(index) = store.pending.iter().position(|item| item.ios_id == ios_id) else {
        return Err("这条待指定已经处理过了".into());
    };
    let item = store.pending.remove(index);
    store.curves.insert(track_id.to_string(), item.curve);
    Ok(())
}

/// 把一条待指定的曲线落到用户点的那首曲目上。
#[tauri::command]
pub fn assign_pending_curve(
    ios_id: String,
    track_id: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let exists = state
        .library
        .lock()
        .snapshot
        .tracks
        .iter()
        .any(|track| track.id == track_id);
    if !exists {
        return Err("曲库里没有这首歌".into());
    }
    mutate(state.inner(), |store| {
        assign_pending(store, &ios_id, &track_id)
    })
}

/// 放弃一条待指定的曲线（用户确认「这首不要了」）。
#[tauri::command]
pub fn drop_pending_curve(ios_id: String, state: State<'_, AppState>) -> Result<bool, String> {
    mutate(state.inner(), |store| {
        let before = store.pending.len();
        store.pending.retain(|item| item.ios_id != ios_id);
        Ok(before != store.pending.len())
    })
}

#[derive(Debug, Serialize)]
pub struct CurvesSummary {
    pub count: usize,
    pub pending: usize,
    pub prior: Option<PriorView>,
    pub imported: Option<ImportSource>,
}

/// 记忆总览：界面上「记住 N 首」这类文案用它，避免前端自己拼。
#[tauri::command]
pub fn song_curves_summary(state: State<'_, AppState>) -> CurvesSummary {
    let store = state.song_curves.lock();
    CurvesSummary {
        count: store.curves.len(),
        pending: store.pending.len(),
        prior: store.prior.as_ref().map(|prior| PriorView {
            version: prior.version,
            device: prior.source_device.clone(),
            headphone: prior.headphone.clone(),
        }),
        imported: store.imported.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn to_bands_rejects_wrong_shape_instead_of_padding() {
        assert!(to_bands(&[0.0; 31]).is_ok());
        assert!(to_bands(&[0.0; 30]).is_err());
        let mut bad = [0.0f32; 31];
        bad[3] = f32::NAN;
        assert!(to_bands(&bad).is_err());
    }

    /// 落库的往返：写盘能读回；坏文件留副本、不静默覆盖。
    #[test]
    fn store_round_trips_and_keeps_a_copy_of_corruption() {
        let dir = std::env::temp_dir().join(format!("awake-song-curves-{}", now_ms()));
        std::fs::create_dir_all(&dir).expect("建临时目录");
        let mut store = SongCurveStore::default();
        store.curves.insert("t1".to_string(), SongCurve::default());
        store.prior = Some(EarPrior {
            version: 2,
            ..Default::default()
        });
        store.pending.push(PendingCurve {
            ios_id: "UUID-A".to_string(),
            title: "夜航".to_string(),
            reason: "曲库里同名 2 首，要你选一首".to_string(),
            candidates: 2,
            imported_at: "2026-11-23T00:00:00Z".to_string(),
            curve: SongCurve::default(),
        });
        save(&dir, &store).expect("写盘");

        let loaded = load(&dir);
        assert_eq!(loaded.curves.len(), 1, "曲线应读回");
        assert_eq!(loaded.prior.as_ref().map(|p| p.version), Some(2));
        assert_eq!(loaded.pending.len(), 1, "待指定的曲线不能丢");
        assert_eq!(loaded.pending[0].title, "夜航");

        std::fs::write(dir.join(STORE_FILE), b"{not json").expect("写坏文件");
        let broken = load(&dir);
        assert!(broken.curves.is_empty(), "坏文件不能当成有数据");
        let backups = std::fs::read_dir(&dir)
            .expect("读目录")
            .filter_map(|entry| entry.ok())
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("song-curves-corrupt-")
            })
            .count();
        assert_eq!(backups, 1, "坏文件必须留一份副本");
        std::fs::remove_dir_all(&dir).ok();
    }

    fn track(id: &str, title: &str) -> TrackRef {
        TrackRef {
            id: id.to_string(),
            title: title.to_string(),
            artist: "某艺人".to_string(),
            duration: 200.0,
        }
    }

    #[test]
    fn candidates_prefer_exact_title_then_fall_back_to_containment() {
        let tracks = vec![
            track("a", "夜航"),
            track("b", "夜航 (Live)"),
            track("c", "别的歌"),
        ];
        let exact = candidates_for("夜航", &tracks);
        assert_eq!(exact[0].id, "a", "精确同名排第一");
        assert_eq!(exact.len(), 2, "Live 版作为次选也列出，不藏起来");

        let fuzzy = candidates_for("夜航 (Live)", &tracks);
        assert_eq!(fuzzy[0].id, "b", "精确同名排第一");
        assert!(
            fuzzy.iter().any(|item| item.id == "a"),
            "包含关系也进候选，用户还能选对"
        );
        assert!(candidates_for("完全不存在的歌", &tracks).is_empty());
        assert!(candidates_for("   ", &tracks).is_empty(), "空标题不给候选");
    }

    #[test]
    fn assigning_a_pending_curve_moves_it_into_memory() {
        let mut store = SongCurveStore::default();
        store.pending.push(PendingCurve {
            ios_id: "UUID-A".to_string(),
            title: "夜航".to_string(),
            reason: "曲库里同名 2 首，要你选一首".to_string(),
            candidates: 2,
            imported_at: "2026-11-23T00:00:00Z".to_string(),
            curve: SongCurve {
                gains: [3.0f32; BAND_COUNT],
                ..Default::default()
            },
        });
        assign_pending(&mut store, "UUID-A", "local-9").expect("应能接上");
        assert!(store.pending.is_empty(), "接上之后不能还留在待指定里");
        assert_eq!(store.curves["local-9"].gains[0], 3.0, "曲线本身要原样搬过去");
        assert!(
            assign_pending(&mut store, "UUID-A", "local-9").is_err(),
            "重复点同一张卡应明确报错，而不是悄悄再建一条"
        );
    }

    /// 从 iOS 档案到「这首歌该用哪条曲线」的整条纯逻辑链：
    /// 曲名匹配 → 落库形状 → 叠先验 → 限幅。
    #[test]
    fn profile_lands_on_local_track_and_resolves_with_prior() {
        let json = format!(
            r#"{{"version":1,"device":"seven-iphone","createdAt":"2026-11-20T10:00:00Z",
            "prior":{{"version":3,"gains":[{}]}},
            "curves":{{
              "UUID-A":{{"gains":[{}],"origin":"ai","basisDetail":{{"headphone":"AirPods Pro","track":"3:42 · 44 kHz","prior":"校准 v3"}}}},
              "UUID-B":{{"gains":[{}]}}
            }},
            "titles":{{"UUID-A":"夜航","UUID-B":"曲库里没有的歌"}}}}"#,
            vec!["5.0"; 31].join(","),
            vec!["9.0"; 31].join(","),
            vec!["1.0"; 31].join(",")
        );
        let profile = parse_profile(&json).expect("解析档案");
        let tracks = vec![TrackRef {
            id: "local-1".to_string(),
            title: "夜航".to_string(),
            artist: "某艺人".to_string(),
            duration: 222.0,
        }];
        let report = match_curves(&profile, &tracks);
        assert_eq!(report.matched.len(), 1, "只有一首能落地");
        assert_eq!(report.matched[0].desktop_id, "local-1");
        assert_eq!(report.unmatched.len(), 1, "另一首要报「曲库里没有」");

        let resolved = apply_prior(
            &report.matched[0].curve.gains,
            profile.prior.as_ref(),
            true,
        );
        assert_eq!(resolved[0], 12.0, "9 + 5 应限幅到 12");
        let without = apply_prior(
            &report.matched[0].curve.gains,
            profile.prior.as_ref(),
            false,
        );
        assert_eq!(without[0], 9.0, "关掉先验应只剩记忆曲线");
    }
}
