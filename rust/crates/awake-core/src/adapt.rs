//! 入库即适配：把"新入库的曲子"变成三种判决之一。
//!
//! 规则与阈值来自 `docs/plan-v1-sources-home-adaptation.md` 第 5 节。
//! 这个模块只做判决与聚合，不碰音频、不碰磁盘、不联网：
//! - 判决顺序固定，先排除"不能写"，再判断"能不能自己决定"；
//! - 低置信的曲目按 专架 + 风格 + 原因 聚合成**一批**，界面上一次只问用户一次；
//! - 报告必须自洽（总数 = 自动 + 待定 + 跳过），这是唯一能防"为了好看而编依据"的检查。

use crate::models::Track;
use crate::shelf::Shelf;
use serde::Serialize;
use std::collections::{HashMap, HashSet};

/// 单曲判决。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub enum Decision {
    /// 置信足够：直接写曲线，并带上三段依据。
    Auto,
    /// 需要人听一下：进 pending，按批聚合。
    Pending(PendingReason),
    /// 不写：分析没跑通。宁可没有曲线，也不给一条编出来的依据。
    Skip(SkipReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum PendingReason {
    /// 既没有耳机档案也没有校准先验——没有参照物，拟合就是猜。
    NoReference,
    /// 同风格在库里样本太少，风格层面的判断站不住。
    ThinSamples,
    /// 与已有曲线的距离超出阈值，说明这首"不像你以为的那类"。
    FarFromKnown,
}

impl PendingReason {
    pub fn text(self) -> &'static str {
        match self {
            PendingReason::NoReference => "还没有参照物（耳机档案或校准）",
            PendingReason::ThinSamples => "库里同类太少",
            PendingReason::FarFromKnown => "和已有曲线差得远",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum SkipReason {
    /// 分析没跑通。跳过而不是凑一条曲线。
    AnalysisFailed,
}

impl SkipReason {
    pub fn text(self) -> &'static str {
        match self {
            SkipReason::AnalysisFailed => "分析失败，已跳过",
        }
    }
}

/// 单曲的适配输入。字段全部来自已有结构，不引入新数据源。
#[derive(Debug, Clone, PartialEq)]
pub struct AdaptInput {
    pub track_id: String,
    pub genre: String,
    pub shelf: Shelf,
    /// 频谱分析是否跑通。
    pub analyzed: bool,
    /// 是否有耳机档案或校准先验——没有它，任何"适配"都只是通用曲线。
    pub has_reference: bool,
    /// 同风格且已有曲线的曲目数。
    pub genre_samples: usize,
    /// 与已有曲线的 RMS 距离（dB）。没有可比对象时为 None。
    pub distance_db: Option<f32>,
}

pub const MIN_GENRE_SAMPLES: usize = 3;
pub const MAX_DISTANCE_DB: f32 = 6.0;

pub fn decide(input: &AdaptInput) -> Decision {
    if !input.analyzed {
        return Decision::Skip(SkipReason::AnalysisFailed);
    }
    if !input.has_reference {
        return Decision::Pending(PendingReason::NoReference);
    }
    if input.genre_samples < MIN_GENRE_SAMPLES {
        return Decision::Pending(PendingReason::ThinSamples);
    }
    if let Some(distance) = input.distance_db {
        if distance > MAX_DISTANCE_DB {
            return Decision::Pending(PendingReason::FarFromKnown);
        }
    }
    Decision::Auto
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PendingItem {
    pub track_id: String,
    pub genre: String,
    pub shelf: Shelf,
    pub reason: PendingReason,
}

/// 一批待定：界面上"听一组"的最小单位。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PendingBatch {
    pub key: String,
    pub label: String,
    pub shelf: Shelf,
    pub reason: PendingReason,
    pub track_ids: Vec<String>,
}

/// 聚合。同 专架 + 原因 + 风格 进同一批，顺序固定（可断言）。
pub fn batches(items: &[PendingItem]) -> Vec<PendingBatch> {
    let mut out: Vec<PendingBatch> = Vec::new();
    for item in items {
        let genre_key = if item.genre.trim().is_empty() {
            "未标注".to_string()
        } else {
            item.genre.trim().to_lowercase()
        };
        let key = format!("{}:{}:{}", item.shelf.key(), reason_key(item.reason), genre_key);
        match out.iter_mut().find(|b| b.key == key) {
            Some(batch) => batch.track_ids.push(item.track_id.clone()),
            None => {
                let label = if item.shelf == Shelf::None {
                    format!("{} · 1 首", display_genre(&genre_key))
                } else {
                    format!("{} / {} · 1 首", item.shelf.label(), display_genre(&genre_key))
                };
                out.push(PendingBatch {
                    key,
                    label,
                    shelf: item.shelf,
                    reason: item.reason,
                    track_ids: vec![item.track_id.clone()],
                });
            }
        }
    }
    for batch in &mut out {
        batch.track_ids.sort();
        batch.label = batch.label.replace("· 1 首", &format!("· {} 首", batch.track_ids.len()));
    }
    out.sort_by(|a, b| a.key.cmp(&b.key));
    out
}

fn reason_key(reason: PendingReason) -> &'static str {
    match reason {
        PendingReason::NoReference => "no-reference",
        PendingReason::ThinSamples => "thin-samples",
        PendingReason::FarFromKnown => "far-from-known",
    }
}

fn display_genre(key: &str) -> String {
    if key == "未标注" {
        "未标注风格".to_string()
    } else {
        key.to_string()
    }
}

/// 一次适配的账。数字必须自洽。
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct AdaptReport {
    pub total: usize,
    pub auto: usize,
    pub pending: usize,
    pub skipped: usize,
    pub batches: Vec<PendingBatch>,
}

impl AdaptReport {
    pub fn is_self_consistent(&self) -> bool {
        self.total == self.auto + self.pending + self.skipped
    }

    /// 报告卡上的一行话。数字来自同一份账，不另算。
    pub fn headline(&self) -> String {
        let groups = self.batches.len();
        let mut line = format!(
            "本次入库 {} 首 · 自动适配 {} 首 · {} 首需要你听一下（{} 组）",
            self.total, self.auto, self.pending, groups
        );
        if self.skipped > 0 {
            line.push_str(&format!(" · {} 首分析失败（已跳过，可重试）", self.skipped));
        }
        line
    }
}

pub fn run(inputs: &[AdaptInput]) -> AdaptReport {
    let mut report = AdaptReport { total: inputs.len(), ..AdaptReport::default() };
    let mut pending_items = Vec::new();
    for input in inputs {
        match decide(input) {
            Decision::Auto => report.auto += 1,
            Decision::Skip(_) => report.skipped += 1,
            Decision::Pending(reason) => {
                report.pending += 1;
                pending_items.push(PendingItem {
                    track_id: input.track_id.clone(),
                    genre: input.genre.clone(),
                    shelf: input.shelf,
                    reason,
                });
            }
        }
    }
    report.batches = batches(&pending_items);
    report
}

/// 报告卡里的一批。比 `PendingBatch` 多一句"被什么卡住"。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct QueueBatch {
    pub key: String,
    pub label: String,
    pub shelf: Shelf,
    pub count: usize,
    pub reason: String,
    pub track_ids: Vec<String>,
}

/// 报告卡的全部数字。全部可核对：库里多少首、多少首已有曲线、剩下几批、是不是缺参照物。
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct AdaptQueue {
    pub library_total: usize,
    pub with_curve: usize,
    pub queued: usize,
    /// 没有耳机档案也没有校准先验时为 true——此时所有批次都缺参照物。
    pub blocked_by_reference: bool,
    pub batches: Vec<QueueBatch>,
}

/// 只读地算"还需要适配什么"：不跑分析、不写曲线。
///
/// 界面上不能出现"已自动适配 380 首"这种数字，除非真的跑过分析；
/// 这里只回答三个能核对的问题：多少首没有曲线、分成几批、被什么卡住。
pub fn queue(tracks: &[Track], with_curve: &HashSet<String>, has_reference: bool) -> AdaptQueue {
    let mut genre_with_curve: HashMap<String, usize> = HashMap::new();
    for track in tracks {
        if with_curve.contains(&track.id) {
            *genre_with_curve.entry(track.genre.trim().to_lowercase()).or_default() += 1;
        }
    }

    let mut grouped: HashMap<String, QueueBatch> = HashMap::new();
    let mut with = 0usize;
    for track in tracks {
        if with_curve.contains(&track.id) {
            with += 1;
            continue;
        }
        let genre = if track.genre.trim().is_empty() {
            "未标注".to_string()
        } else {
            track.genre.trim().to_lowercase()
        };
        let shelf = crate::shelf::classify(track, None).shelf;
        let samples = genre_with_curve.get(&genre).copied().unwrap_or(0);
        let reason = if !has_reference {
            "先做一次校准，这批才有参照物".to_string()
        } else if samples < MIN_GENRE_SAMPLES {
            format!("同类样本只有 {samples} 首，先按通用曲线")
        } else {
            "可以自动适配（需要跑一次分析）".to_string()
        };
        let key = format!("{}:{}", shelf.key(), genre);
        grouped
            .entry(key.clone())
            .and_modify(|batch| {
                batch.count += 1;
                batch.track_ids.push(track.id.clone());
            })
            .or_insert_with(|| QueueBatch {
                key: key.clone(),
                label: if shelf == Shelf::None {
                    format!("{genre} · 1 首")
                } else {
                    format!("{} / {genre} · 1 首", shelf.label())
                },
                shelf,
                count: 1,
                reason: reason.clone(),
                track_ids: vec![track.id.clone()],
            });
    }

    let mut batches: Vec<QueueBatch> = grouped.into_values().collect();
    for batch in &mut batches {
        batch.track_ids.sort();
        batch.label = batch.label.replace("· 1 首", &format!("· {} 首", batch.count));
    }
    batches.sort_by(|a, b| b.count.cmp(&a.count).then(a.key.cmp(&b.key)));
    let queued = batches.iter().map(|b| b.count).sum();

    AdaptQueue {
        library_total: tracks.len(),
        with_curve: with,
        queued,
        blocked_by_reference: !has_reference,
        batches,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(id: &str, genre: &str, shelf: Shelf, analyzed: bool, reference: bool, samples: usize, distance: Option<f32>) -> AdaptInput {
        AdaptInput {
            track_id: id.to_string(),
            genre: genre.to_string(),
            shelf,
            analyzed,
            has_reference: reference,
            genre_samples: samples,
            distance_db: distance,
        }
    }

    #[test]
    fn analysis_failure_skips_instead_of_inventing_a_curve() {
        let d = decide(&input("t1", "rock", Shelf::None, false, true, 9, None));
        assert_eq!(d, Decision::Skip(SkipReason::AnalysisFailed));
    }

    #[test]
    fn no_reference_means_pending_not_auto() {
        let d = decide(&input("t1", "rock", Shelf::None, true, false, 9, None));
        assert_eq!(d, Decision::Pending(PendingReason::NoReference));
    }

    #[test]
    fn thin_genre_samples_are_pending() {
        let d = decide(&input("t1", "jazz", Shelf::None, true, true, MIN_GENRE_SAMPLES - 1, None));
        assert_eq!(d, Decision::Pending(PendingReason::ThinSamples));
        let d = decide(&input("t1", "jazz", Shelf::None, true, true, MIN_GENRE_SAMPLES, None));
        assert_eq!(d, Decision::Auto);
    }

    #[test]
    fn far_from_known_curve_is_pending_but_missing_distance_is_not() {
        let far = decide(&input("t1", "jazz", Shelf::None, true, true, 9, Some(MAX_DISTANCE_DB + 0.1)));
        assert_eq!(far, Decision::Pending(PendingReason::FarFromKnown));
        let unknown = decide(&input("t1", "jazz", Shelf::None, true, true, 9, None));
        assert_eq!(unknown, Decision::Auto, "没有可比对象时不能凭空判它远");
    }

    #[test]
    fn report_is_self_consistent_and_headline_matches_numbers() {
        let inputs = vec![
            input("a", "rock", Shelf::None, true, true, 9, None),
            input("b", "rock", Shelf::None, true, true, 9, None),
            input("c", "rock", Shelf::None, true, true, 9, None),
            input("d", "古典", Shelf::Classical, true, true, 1, None),
            input("e", "古典", Shelf::Classical, true, true, 1, None),
            input("f", "rock", Shelf::None, false, true, 9, None),
        ];
        let report = run(&inputs);
        assert_eq!(report.total, 6);
        assert_eq!(report.auto, 3);
        assert_eq!(report.pending, 2);
        assert_eq!(report.skipped, 1);
        assert!(report.is_self_consistent());
        assert_eq!(report.batches.len(), 1, "同专架同原因同风格 = 一批");
        assert_eq!(report.batches[0].track_ids, vec!["d".to_string(), "e".to_string()]);
        let line = report.headline();
        assert!(line.contains("本次入库 6 首"), "{line}");
        assert!(line.contains("自动适配 3 首"), "{line}");
        assert!(line.contains("2 首需要你听一下（1 组）"), "{line}");
        assert!(line.contains("1 首分析失败"), "{line}");
    }

    #[test]
    fn batching_splits_by_shelf_and_genre_deterministically() {
        let items = vec![
            PendingItem { track_id: "z".into(), genre: "古典".into(), shelf: Shelf::Classical, reason: PendingReason::ThinSamples },
            PendingItem { track_id: "a".into(), genre: "古典".into(), shelf: Shelf::Classical, reason: PendingReason::ThinSamples },
            PendingItem { track_id: "m".into(), genre: "".into(), shelf: Shelf::None, reason: PendingReason::NoReference },
        ];
        let batches = batches(&items);
        assert_eq!(batches.len(), 2);
        assert_eq!(batches[0].track_ids, vec!["a".to_string(), "z".to_string()]);
        assert_eq!(batches[0].label, "古典 / 古典 · 2 首");
        assert_eq!(batches[1].label, "未标注风格 · 1 首");
    }

    #[test]
    fn queue_counts_only_tracks_without_curves_and_says_what_blocks_them() {
        fn t(id: &str, title: &str, genre: &str) -> Track {
            serde_json::from_value(serde_json::json!({
                "id": id, "title": title, "artist": "A", "album_artist": "A", "album": "al",
                "genre": genre, "year": null, "track_number": null, "disc_number": null,
                "duration": 200.0, "sample_rate": 48000, "bit_depth": 24, "channels": 2,
                "codec": "flac", "source_id": "s", "locator": id, "file_size": 1,
                "modified": 0, "artwork_path": null, "play_count": 0, "favorite": false,
                "last_played": null, "added_at": 0, "is_remote": false
            }))
            .unwrap()
        }
        let tracks = vec![
            t("r1", "r1", "rock"),
            t("r2", "r2", "rock"),
            // 古典要两个信号才成立：流派 + 作品号
            t("r3", "Symphony No.5 Op. 67", "古典"),
            t("r4", "r4", ""),
            t("c1", "c1", "rock"),
        ];
        let curves: HashSet<String> = ["c1".to_string()].into_iter().collect();

        let blocked = queue(&tracks, &curves, false);
        assert_eq!(blocked.library_total, 5);
        assert_eq!(blocked.with_curve, 1);
        assert_eq!(blocked.queued, 4);
        assert!(blocked.blocked_by_reference);
        assert_eq!(blocked.batches.iter().map(|b| b.count).sum::<usize>(), 4);
        assert!(blocked.batches.iter().all(|b| b.reason.contains("校准")), "缺参照物要说出来");

        let ready = queue(&tracks, &curves, true);
        let rock = ready.batches.iter().find(|b| b.key.contains("rock")).unwrap();
        assert_eq!(rock.count, 2);
        assert!(rock.reason.contains("同类样本只有 1 首"), "{}", rock.reason);
        let classical = ready.batches.iter().find(|b| b.key.starts_with("classical")).unwrap();
        assert_eq!(classical.label, "古典 / 古典 · 1 首");
    }

    #[test]
    fn empty_input_is_a_zero_report() {
        let report = run(&[]);
        assert!(report.is_self_consistent());
        assert_eq!(report.total, 0);
        assert!(report.batches.is_empty());
        assert!(report.headline().starts_with("本次入库 0 首"));
    }
}
