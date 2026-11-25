//! MusicBee 注解导入与刷新（D5–D6 的核心逻辑）。
//!
//! 三条硬规则，来自计划第 2.4 与 2.5 节：
//! 1. **只读**：不写回 `.mbl`，任何"同步"都只发生在 Awake 自己的库里。
//! 2. **只增不减**：播放次数取较大值、上次播放取较晚值——绝不把用户刚在 Awake 里听的冲掉。
//! 3. **失败保留旧库**：`.mbl` 读不出来（共享盘掉线、正在被写）时，调用方保留上一份解析结果，
//!    这里只提供"要不要重读"的判断，不提供"读失败就当空库"。
//!
//! 匹配靠"来源根 + locator"拼出的绝对路径与 `.mbl` 里的路径对齐；
//! 大小写不一致时退一步再匹配一次，并在报告里计数（macOS 常见，不能悄悄吞掉）。

use crate::musicbee::{map_windows_path, MblLibrary, Mount};
use crate::models::Track;
use serde::Serialize;

/// `.mbl` 的身份：大小 + 修改时间。任一变化就要整份重读。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Snapshot {
    pub len: u64,
    pub modified_ms: i64,
}

impl Snapshot {
    pub fn needs_reload(&self, current: Snapshot) -> bool {
        self.len != current.len || self.modified_ms != current.modified_ms
    }
}

/// 从 `.mbl` 带到曲目上的判断。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Annotations {
    pub play_count: u32,
    pub skip_count: u32,
    pub last_played_ms: Option<i64>,
    pub added_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Matched {
    pub track_id: String,
    pub posix_path: String,
    pub annotations: Annotations,
    /// 这条记录会不会真的改变曲目（不做无意义写入）。
    pub changed: bool,
    /// 靠忽略大小写才匹配上的。
    pub case_insensitive: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct ImportPlan {
    pub matched: Vec<Matched>,
    pub changed: usize,
    pub unchanged: usize,
    /// `.mbl` 里有、库里没有（换过机器、改了挂载名、文件被删）。
    pub unmatched: Vec<String>,
    /// 库里有的曲目数——只作为分母，不做任何删除。
    pub library_only: usize,
    pub case_insensitive: usize,
}

impl ImportPlan {
    pub fn is_empty(&self) -> bool {
        self.matched.is_empty()
    }

    pub fn headline(&self) -> String {
        format!(
            "曲库 {} 首 · 可对上 {} 首（改变 {}）· 对不上 {} 条",
            self.library_only,
            self.matched.len(),
            self.changed,
            self.unmatched.len()
        )
    }
}

/// 一个来源的根：locator 是相对它存的。
#[derive(Debug, Clone, Copy)]
pub struct SourceRoot<'a> {
    pub source_id: &'a str,
    pub root: &'a str,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct ApplyReport {
    pub updated: usize,
    pub play_count_raised: usize,
    pub last_played_moved: usize,
    pub added_at_filled: usize,
}

fn normalize(path: &str) -> String {
    let replaced = path.replace('\\', "/");
    let mut out = String::with_capacity(replaced.len());
    let mut last_slash = false;
    for ch in replaced.chars() {
        if ch == '/' {
            if last_slash {
                continue;
            }
            last_slash = true;
        } else {
            last_slash = false;
        }
        out.push(ch);
    }
    while out.ends_with('/') && out.len() > 1 {
        out.pop();
    }
    out
}

fn track_absolute(root: &str, locator: &str) -> String {
    if locator.starts_with('/') {
        return normalize(locator);
    }
    normalize(&format!("{}/{}", root.trim_end_matches('/'), locator.trim_start_matches('/')))
}

/// 合并规则：只增不减。返回"合并后应该是什么样"。
fn merge_annotation(track: &Track, annotations: &Annotations) -> Annotations {
    let play_count = track.play_count.max(annotations.play_count);
    let last_played_ms = match (track.last_played, annotations.last_played_ms) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (Some(a), None) => Some(a),
        (None, Some(b)) => Some(b),
        (None, None) => None,
    };
    let added_ms = annotations.added_ms.filter(|_| track.added_at == 0);
    Annotations { play_count, skip_count: annotations.skip_count, last_played_ms, added_ms }
}

/// 单盘入口：一个 Windows 根 × 曲库里每个本地来源的根。
///
/// 这就是面板一直用的那种情形（`.mbl` 全部在 `F:\Music` 下）。
/// 跨盘时用 [`plan_multi`]。
pub fn plan(lib: &MblLibrary, tracks: &[Track], roots: &[SourceRoot<'_>], win_root: &str) -> ImportPlan {
    let mounts: Vec<Mount<'_>> =
        roots.iter().map(|r| Mount::new(win_root, r.root)).collect();
    plan_multi(lib, tracks, roots, &mounts)
}

/// 跨多个 Windows 盘根落库：每个 `Mount` 是「一个盘根 → 一个本机挂载点」。
///
/// 真实曲库常跨盘（`F:\Music` 与 `G:\Archive`），一个 `win_root` 装不下。
/// 同一条记录可能被多个 `Mount` 命中——那很正常（同一个盘挂了两处），
/// 只要**任意一个**候选路径在库里存在就算匹配，与原实现的"逐个试"一致。
pub fn plan_multi(
    lib: &MblLibrary,
    tracks: &[Track],
    roots: &[SourceRoot<'_>],
    mounts: &[Mount<'_>],
) -> ImportPlan {
    let mut result = ImportPlan { library_only: tracks.len(), ..ImportPlan::default() };

    // 每条曲目在磁盘上的绝对路径：来源根 + locator（绝对 locator 原样用）。
    let mut by_path: Vec<(String, usize)> = Vec::new();
    for (index, track) in tracks.iter().enumerate() {
        let Some(source) = roots.iter().find(|r| r.source_id == track.source_id) else {
            continue;
        };
        by_path.push((track_absolute(source.root, &track.locator), index));
    }

    for record in &lib.records {
        // 每个 Mount 独立试，任何一个对上就算匹配。跨盘就是多个 Mount。
        let candidates: Vec<String> = mounts
            .iter()
            .filter_map(|m| map_windows_path(&record.path, m.win_root, m.posix_root))
            .collect();
        if candidates.is_empty() {
            result.unmatched.push(record.path.clone());
            continue;
        }

        let annotations = Annotations {
            play_count: record.play_count,
            skip_count: record.skip_count,
            last_played_ms: record.last_played_ms,
            added_ms: record.added_ms,
        };

        let hit = by_path
            .iter()
            .find(|(path, _)| candidates.iter().any(|c| c == path))
            .map(|(path, index)| (path.clone(), *index, false))
            .or_else(|| {
                by_path
                    .iter()
                    .find(|(path, _)| candidates.iter().any(|c| path.eq_ignore_ascii_case(c)))
                    .map(|(path, index)| (path.clone(), *index, true))
            });
        let Some((posix_path, index, case_insensitive)) = hit else {
            result.unmatched.push(record.path.clone());
            continue;
        };

        let track = &tracks[index];
        let merged = merge_annotation(track, &annotations);
        // 只有真会落库的三个字段才算"改变"；两边都没有日期时不算改。
        let changed = merged.play_count != track.play_count
            || merged.last_played_ms != track.last_played
            || (track.added_at == 0 && merged.added_ms.is_some());
        if changed {
            result.changed += 1;
        } else {
            result.unchanged += 1;
        }
        if case_insensitive {
            result.case_insensitive += 1;
        }
        result.matched.push(Matched {
            track_id: track.id.clone(),
            posix_path,
            annotations,
            changed,
            case_insensitive,
        });
    }

    result
}
/// 落库。只碰三个字段：play_count / last_played / added_at（且只增不减）。
pub fn apply(tracks: &mut [Track], plan: &ImportPlan) -> ApplyReport {
    let mut report = ApplyReport::default();
    for item in &plan.matched {
        if !item.changed {
            continue;
        }
        let Some(track) = tracks.iter_mut().find(|t| t.id == item.track_id) else {
            continue;
        };
        let before = (track.play_count, track.last_played, track.added_at);
        let merged = merge_annotation(track, &item.annotations);
        track.play_count = merged.play_count;
        if let Some(last) = merged.last_played_ms {
            track.last_played = Some(last);
        }
        if let Some(added) = merged.added_ms {
            track.added_at = added;
        }
        let mut touched = false;
        if track.play_count != before.0 {
            report.play_count_raised += 1;
            touched = true;
        }
        if track.last_played != before.1 {
            report.last_played_moved += 1;
            touched = true;
        }
        if track.added_at != before.2 {
            report.added_at_filled += 1;
            touched = true;
        }
        if touched {
            report.updated += 1;
        }
    }
    report
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::musicbee::{MblRecord, MblArtwork};

    fn record(path: &str, play: u32, last: Option<i64>, added: Option<i64>) -> MblRecord {
        MblRecord {
            designation: 2,
            status: 0,
            play_count: play,
            skip_count: 0,
            last_played_ms: last,
            added_ms: added,
            modified_ms: None,
            path: path.to_string(),
            file_size: 1,
            sample_rate: 44_100,
            channel_mode: 1,
            bitrate_type: 0,
            bitrate_raw: 320,
            track_length_raw: 200,
            artwork: Vec::<MblArtwork>::new(),
            tags_type: 0,
            tags: Vec::new(),
            cue: Vec::new(),
        }
    }

    fn library(records: Vec<MblRecord>) -> MblLibrary {
        MblLibrary { version: 8, declared: records.len() as u32, records, trailing_bytes: 0 }
    }

    fn track(id: &str, source: &str, locator: &str, play: u32, last: Option<i64>, added: i64) -> Track {
        serde_json::from_value(serde_json::json!({
            "id": id, "title": id, "artist": "A", "album_artist": "A", "album": "al",
            "genre": "rock", "year": null, "track_number": null, "disc_number": null,
            "duration": 200.0, "sample_rate": 48000, "bit_depth": 24, "channels": 2,
            "codec": "flac", "source_id": source, "locator": locator, "file_size": 1,
            "modified": 0, "artwork_path": null, "play_count": play, "favorite": false,
            "last_played": last, "added_at": added, "is_remote": false
        }))
        .expect("测试曲目必须可构造")
    }

    #[test]
    fn exact_path_match_raises_play_count_but_never_lowers_it() {
        let lib = library(vec![
            record("F:\\Music\\A\\01.flac", 12, Some(1_760_000_000_000), Some(1_700_000_000_000)),
            record("F:\\Music\\A\\02.flac", 1, None, None),
        ]);
        let tracks = vec![
            track("t1", "s1", "A/01.flac", 3, Some(1_700_000_000_000), 0),
            track("t2", "s1", "A/02.flac", 9, None, 1_650_000_000_000),
        ];
        let roots = [SourceRoot { source_id: "s1", root: "/mnt/music" }];
        let plan = plan(&lib, &tracks, &roots, "F:\\Music");
        assert_eq!(plan.matched.len(), 2);
        assert_eq!(plan.changed, 1, "只有 01 会变：播放次数 3→12、上次播放前移；02 的 9 不能被拉回 1");

        let mut applied = tracks.clone();
        let report = apply(&mut applied, &plan);
        assert_eq!(applied[0].play_count, 12);
        assert_eq!(applied[0].last_played, Some(1_760_000_000_000));
        assert_eq!(applied[0].added_at, 1_700_000_000_000, "库里没有入库时间时才补");
        assert_eq!(applied[1].play_count, 9, "只增不减");
        assert_eq!(applied[1].added_at, 1_650_000_000_000, "已有入库时间不许改");
        assert_eq!(report.updated, 1);
    }

    #[test]
    fn tracks_outside_the_root_are_unmatched_not_deleted() {
        let lib = library(vec![record("G:\\Other\\x.flac", 5, None, None)]);
        let tracks = vec![track("t1", "s1", "A/01.flac", 0, None, 0)];
        let roots = [SourceRoot { source_id: "s1", root: "/mnt/music" }];
        let plan = plan(&lib, &tracks, &roots, "F:\\Music");
        assert!(plan.matched.is_empty());
        assert_eq!(plan.unmatched, vec!["G:\\Other\\x.flac".to_string()]);
        assert_eq!(plan.library_only, 1, "库里有的曲目只作为分母");
    }

    #[test]
    fn case_mismatch_still_matches_and_is_reported() {
        let lib = library(vec![record("F:\\Music\\A\\Track.FLAC", 4, None, None)]);
        let tracks = vec![track("t1", "s1", "a/track.flac", 0, None, 0)];
        let roots = [SourceRoot { source_id: "s1", root: "/mnt/music" }];
        let plan = plan(&lib, &tracks, &roots, "F:\\Music");
        assert_eq!(plan.matched.len(), 1);
        assert!(plan.matched[0].case_insensitive);
        assert_eq!(plan.case_insensitive, 1);
    }

    #[test]
    fn absolute_locators_are_used_as_is() {
        let lib = library(vec![record("F:\\Music\\A\\01.flac", 2, None, None)]);
        let tracks = vec![track("t1", "s1", "/mnt/music/A/01.flac", 0, None, 0)];
        let roots = [SourceRoot { source_id: "s1", root: "/mnt/music" }];
        let plan = plan(&lib, &tracks, &roots, "F:\\Music");
        assert_eq!(plan.matched.len(), 1);
    }

    #[test]
    fn empty_library_plans_nothing_and_applies_nothing() {
        let lib = library(vec![]);
        let tracks = vec![track("t1", "s1", "A/01.flac", 7, None, 1)];
        let roots = [SourceRoot { source_id: "s1", root: "/mnt/music" }];
        let plan = plan(&lib, &tracks, &roots, "F:\\Music");
        assert!(plan.is_empty());
        assert_eq!(plan.changed, 0);
        let mut applied = tracks.clone();
        let report = apply(&mut applied, &plan);
        assert_eq!(report.updated, 0);
        assert_eq!(applied[0].play_count, 7);
    }

    #[test]
    fn second_mount_of_the_same_windows_root_still_matches() {
        let lib = library(vec![record("F:\\Music\\B\\02.flac", 6, None, None)]);
        let tracks = vec![track("t2", "s2", "B/02.flac", 0, None, 0)];
        let roots = [
            SourceRoot { source_id: "s1", root: "/mnt/a" },
            SourceRoot { source_id: "s2", root: "/mnt/b" },
        ];
        let plan = plan(&lib, &tracks, &roots, "F:\\Music");
        assert_eq!(plan.matched.len(), 1, "第一个挂载点对不上时，要试下一个，而不是直接判未匹配");
        assert_eq!(plan.matched[0].posix_path, "/mnt/b/B/02.flac");
    }

    #[test]
    fn missing_dates_on_both_sides_are_not_a_change() {
        let lib = library(vec![record("F:\\Music\\A\\01.flac", 0, None, None)]);
        let tracks = vec![track("t1", "s1", "A/01.flac", 0, None, 0)];
        let roots = [SourceRoot { source_id: "s1", root: "/mnt/music" }];
        let plan = plan(&lib, &tracks, &roots, "F:\\Music");
        assert_eq!(plan.matched.len(), 1);
        assert!(!plan.matched[0].changed, "两边都没有这个时间，就不该算改变");
        assert_eq!(plan.changed, 0);

        let mut applied = tracks.clone();
        let report = apply(&mut applied, &plan);
        assert_eq!(report.updated, 0, "报告说会变、实际没变，就是数字不自洽");
    }

    #[test]
    fn two_windows_drives_import_with_two_mounts() {
        let lib = library(vec![
            record("F:\\Music\\A\\01.flac", 5, None, None),
            record("G:\\Archive\\B\\02.flac", 3, None, None),
        ]);
        let tracks = vec![
            track("t1", "s1", "A/01.flac", 0, None, 0),
            track("t2", "s2", "B/02.flac", 0, None, 0),
        ];
        let roots = [
            SourceRoot { source_id: "s1", root: "/Volumes/F" },
            SourceRoot { source_id: "s2", root: "/Volumes/G" },
        ];
        let mounts = [
            Mount::new("F:\\Music", "/Volumes/F"),
            Mount::new("G:\\Archive", "/Volumes/G"),
        ];
        let plan = plan_multi(&lib, &tracks, &roots, &mounts);
        assert_eq!(plan.matched.len(), 2, "两个盘都要对上，不能被单根挡住");
        assert_eq!(plan.changed, 2);
        assert!(plan.unmatched.is_empty());
    }

    #[test]
    fn a_drive_without_a_mount_is_reported_unmatched_not_silently_dropped() {
        let lib = library(vec![
            record("F:\\Music\\A\\01.flac", 5, None, None),
            record("Z:\\Backup\\C\\03.flac", 2, None, None),
        ]);
        let tracks = vec![track("t1", "s1", "A/01.flac", 0, None, 0)];
        let roots = [SourceRoot { source_id: "s1", root: "/Volumes/F" }];
        let mounts = [Mount::new("F:\\Music", "/Volumes/F")];
        let plan = plan_multi(&lib, &tracks, &roots, &mounts);
        assert_eq!(plan.matched.len(), 1);
        assert_eq!(plan.unmatched, vec!["Z:\\Backup\\C\\03.flac".to_string()]);
    }

    #[test]
    fn snapshot_detects_rewrites_by_size_or_time() {
        let a = Snapshot { len: 100, modified_ms: 1_000 };
        assert!(!a.needs_reload(Snapshot { len: 100, modified_ms: 1_000 }));
        assert!(a.needs_reload(Snapshot { len: 101, modified_ms: 1_000 }));
        assert!(a.needs_reload(Snapshot { len: 100, modified_ms: 2_000 }));
    }

    #[test]
    fn headline_numbers_come_from_the_same_plan() {
        let lib = library(vec![
            record("F:\\Music\\A\\01.flac", 12, None, None),
            record("F:\\Music\\A\\09.flac", 1, None, None),
        ]);
        let tracks = vec![
            track("t1", "s1", "A/01.flac", 0, None, 0),
            track("t2", "s1", "A/02.flac", 0, None, 0),
        ];
        let roots = [SourceRoot { source_id: "s1", root: "/mnt/music" }];
        let plan = plan(&lib, &tracks, &roots, "F:\\Music");
        let line = plan.headline();
        assert!(line.contains("曲库 2 首"), "{line}");
        assert!(line.contains("可对上 1 首"), "{line}");
        assert!(line.contains("对不上 1 条"), "{line}");
    }
}
