//! 曲库洞察：听歌覆盖度与成就。
//!
//! 全部本地计算，不发网络请求，不读曲库以外的东西。
//! 「听过」的定义写在一处（[`HEARD_SECONDS`]），前端与成就都用同一个口径。

use std::collections::{BTreeMap, HashSet};

use awake_core::taste::ListenEvent;
use awake_core::Track;
use serde::Serialize;
use tauri::State;

use crate::AppState;

/// 一次收听达到这个秒数（或听完）就算「碰过」这首歌。
pub const HEARD_SECONDS: f64 = 30.0;

/// 一个分组的覆盖情况，例如某个艺人 / 年代 / 流派。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Bucket {
    pub label: String,
    pub total: usize,
    pub heard: usize,
}

impl Bucket {
    /// 没碰过的曲目数。饱和相减，避免脏数据下出现负数。
    pub fn unheard(&self) -> usize {
        self.total.saturating_sub(self.heard)
    }
}

/// 整个曲库的覆盖度。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Coverage {
    pub total: usize,
    pub heard: usize,
    pub unheard: usize,
    /// 0–100，保留一位小数。
    pub percent: f64,
    pub by_artist: Vec<Bucket>,
    pub by_decade: Vec<Bucket>,
    pub by_genre: Vec<Bucket>,
}

/// 一个成就。`progress / target` 决定进度条，`unlocked` 由后端算好，前端不重复判断。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Achievement {
    pub id: String,
    pub title: String,
    pub detail: String,
    pub progress: f64,
    pub target: f64,
    pub unlocked: bool,
    pub punchline: String,
}

/// 听过哪些曲目：听完算，听到 30 秒也算。
pub fn heard_ids(events: &[ListenEvent]) -> HashSet<&str> {
    events
        .iter()
        .filter(|event| event.completed || event.seconds >= HEARD_SECONDS)
        .map(|event| event.track_id.as_str())
        .collect()
}

fn bucketize<F>(tracks: &[Track], heard: &HashSet<&str>, key: F) -> Vec<Bucket>
where
    F: Fn(&Track) -> String,
{
    let mut map: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for track in tracks {
        let slot = map.entry(key(track)).or_insert((0, 0));
        slot.0 += 1;
        if heard.contains(track.id.as_str()) {
            slot.1 += 1;
        }
    }
    let mut buckets: Vec<Bucket> = map
        .into_iter()
        .map(|(label, (total, heard))| Bucket {
            label,
            total,
            heard,
        })
        .collect();
    // 曲目多的排前面；同数量按名字排，保证输出稳定（测试可以断言顺序）。
    buckets.sort_by(|a, b| b.total.cmp(&a.total).then_with(|| a.label.cmp(&b.label)));
    buckets
}

fn artist_label(track: &Track) -> String {
    let artist = track.artist.trim();
    let album_artist = track.album_artist.trim();
    let value = if artist.is_empty() { album_artist } else { artist };
    if value.is_empty() {
        "未知艺人".to_string()
    } else {
        value.to_string()
    }
}

fn decade_label(track: &Track) -> String {
    match track.year {
        Some(year) if year > 0 => format!("{}s", (year / 10) * 10),
        _ => "未标注年代".to_string(),
    }
}

fn genre_label(track: &Track) -> String {
    let genre = track.genre.trim();
    if genre.is_empty() {
        "未标注流派".to_string()
    } else {
        genre.to_string()
    }
}

/// 覆盖度：总数、听过、没碰过，以及按艺人 / 年代 / 流派切开的分布。
pub fn coverage(tracks: &[Track], events: &[ListenEvent]) -> Coverage {
    let heard = heard_ids(events);
    let total = tracks.len();
    // 只统计真实存在的曲目：事件里可能有已经被删掉的歌。
    let heard_count = tracks
        .iter()
        .filter(|track| heard.contains(track.id.as_str()))
        .count();
    let percent = if total == 0 {
        0.0
    } else {
        ((heard_count as f64) * 1000.0 / (total as f64)).round() / 10.0
    };
    let mut by_artist = bucketize(tracks, &heard, artist_label);
    by_artist.truncate(12);
    let mut by_genre = bucketize(tracks, &heard, genre_label);
    by_genre.truncate(12);
    Coverage {
        total,
        heard: heard_count,
        unheard: total.saturating_sub(heard_count),
        percent,
        by_artist,
        by_decade: bucketize(tracks, &heard, decade_label),
        by_genre,
    }
}

/// 同一张专辑听完的比例，取所有专辑的平均。
fn album_completion(tracks: &[Track], heard: &HashSet<&str>) -> f64 {
    let mut albums: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for track in tracks {
        let album = track.album.trim();
        if album.is_empty() {
            continue;
        }
        let slot = albums.entry(album.to_string()).or_insert((0, 0));
        slot.0 += 1;
        if heard.contains(track.id.as_str()) {
            slot.1 += 1;
        }
    }
    if albums.is_empty() {
        return 0.0;
    }
    let sum: f64 = albums
        .values()
        .map(|(total, heard)| *heard as f64 / *total as f64)
        .sum();
    sum / albums.len() as f64
}

/// 事件序列里同一个艺人连续出现的最长长度。
fn longest_artist_run(tracks: &[Track], events: &[ListenEvent]) -> (String, usize) {
    let by_id: BTreeMap<&str, &Track> = tracks.iter().map(|t| (t.id.as_str(), t)).collect();
    let mut events: Vec<&ListenEvent> = events.iter().collect();
    events.sort_by_key(|event| event.at);
    let mut best = (String::new(), 0usize);
    let mut current = (String::new(), 0usize);
    for event in events {
        let Some(track) = by_id.get(event.track_id.as_str()) else {
            continue;
        };
        let artist = artist_label(track);
        if artist == current.0 {
            current.1 += 1;
        } else {
            current = (artist, 1);
        }
        if current.1 > best.1 {
            best = current.clone();
        }
    }
    best
}

/// 每天推的成就。全是本地能算出来的，不需要任何外部服务。
pub fn achievements(tracks: &[Track], events: &[ListenEvent]) -> Vec<Achievement> {
    let heard = heard_ids(events);
    let total = tracks.len();
    let heard_count = tracks
        .iter()
        .filter(|track| heard.contains(track.id.as_str()))
        .count();
    let artists: HashSet<String> = tracks
        .iter()
        .filter(|track| heard.contains(track.id.as_str()))
        .map(artist_label)
        .collect();
    let album = album_completion(tracks, &heard);
    let (run_artist, run_len) = longest_artist_run(tracks, events);

    let mut out = Vec::new();

    // 1. 门票欠账：听过的艺人越多，越像欠了一堆演出票。
    out.push(Achievement {
        id: "ticket-debt".into(),
        title: "门票欠账".into(),
        detail: format!("你已经听过 {} 位艺人的歌", artists.len()),
        progress: artists.len() as f64,
        target: 50.0,
        unlocked: artists.len() >= 50,
        punchline: "按这个进度，Livehouse 门口该给你留个专属欠条位".into(),
    });

    // 2. 宝藏未拆：曲库里还有多少首一次都没碰过。
    out.push(Achievement {
        id: "unopened".into(),
        title: "宝藏未拆".into(),
        detail: format!("{total} 首里有 {} 首还没碰过", total.saturating_sub(heard_count)),
        progress: heard_count as f64,
        target: total.max(1) as f64,
        unlocked: total > 0 && heard_count == total,
        punchline: "别让它们只是硬盘上的装饰品".into(),
    });

    // 3. 专辑完成度：平均听完多少。
    out.push(Achievement {
        id: "album-completion".into(),
        title: "专辑完成度".into(),
        detail: format!("平均听完 {:.0}%", album * 100.0),
        progress: (album * 100.0 * 10.0).round() / 10.0,
        target: 80.0,
        unlocked: album >= 0.8,
        punchline: "整张听完的人才配讨论 B 面第 3 首".into(),
    });

    // 4. 同温层警报：连续听同一个艺人太狠。
    out.push(Achievement {
        id: "comfort-zone".into(),
        title: "同温层警报".into(),
        detail: if run_len == 0 {
            "还没有连续收听记录".to_string()
        } else {
            format!("最长连续 {run_len} 首都是{run_artist}")
        },
        progress: run_len as f64,
        target: 10.0,
        unlocked: run_len >= 10,
        punchline: "连续十首同一个人的歌，算法都替你着急".into(),
    });

    // 5. 深夜档：0–5 点还在听的次数。
    let night = events
        .iter()
        .filter(|event| {
            let seconds = if event.at > 1_000_000_000_000 {
                event.at / 1000
            } else {
                event.at
            };
            seconds > 0 && matches!((seconds % 86_400) / 3_600, 0 | 1 | 2 | 3 | 4)
        })
        .count();
    out.push(Achievement {
        id: "night-shift".into(),
        title: "深夜档".into(),
        detail: format!("0–5 点还在听的次数：{night}"),
        progress: night as f64,
        target: 20.0,
        unlocked: night >= 20,
        punchline: "耳朵的加班费，我们记账上了".into(),
    });

    out
}

#[tauri::command]
pub fn library_coverage(state: State<'_, AppState>) -> Coverage {
    let tracks = state.library.lock().snapshot.tracks.clone();
    let events = state.taste.lock().events.clone();
    coverage(&tracks, &events)
}

#[tauri::command]
pub fn listening_achievements(state: State<'_, AppState>) -> Vec<Achievement> {
    let tracks = state.library.lock().snapshot.tracks.clone();
    let events = state.taste.lock().events.clone();
    achievements(&tracks, &events)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(id: &str, artist: &str, album: &str, genre: &str, year: Option<i32>) -> Track {
        serde_json::from_value(serde_json::json!({
            "id": id, "title": id, "artist": artist, "album_artist": artist,
            "album": album, "genre": genre, "year": year, "track_number": null,
            "disc_number": null, "duration": 200.0, "sample_rate": 44100,
            "bit_depth": 16, "channels": 2, "codec": "flac", "source_id": "s",
            "locator": "a.flac", "file_size": 1, "modified": 0,
            "artwork_path": null, "play_count": 0, "favorite": false,
            "last_played": null, "added_at": 0, "is_remote": false
        }))
        .unwrap()
    }

    fn event(id: &str, seconds: f64, completed: bool, at: i64) -> ListenEvent {
        ListenEvent {
            track_id: id.into(),
            seconds,
            completed,
            skipped: false,
            at,
        }
    }

    #[test]
    fn heard_requires_thirty_seconds_or_completion() {
        let events = vec![
            event("a", 29.9, false, 1),
            event("b", 30.0, false, 2),
            event("c", 5.0, true, 3),
        ];
        let heard = heard_ids(&events);
        assert!(!heard.contains("a"), "29.9 秒不算碰过");
        assert!(heard.contains("b"), "满 30 秒算碰过");
        assert!(heard.contains("c"), "听完算碰过，哪怕只听了 5 秒");
    }

    #[test]
    fn coverage_splits_buckets_and_rounds_percent() {
        let tracks = vec![
            track("a", "甲", "专辑一", "摇滚", Some(1998)),
            track("b", "甲", "专辑一", "摇滚", Some(1998)),
            track("c", "乙", "专辑二", "爵士", Some(2011)),
            track("d", "", "", "", None),
        ];
        let events = vec![event("a", 40.0, false, 1), event("c", 200.0, true, 2)];
        let result = coverage(&tracks, &events);
        assert_eq!(result.total, 4);
        assert_eq!(result.heard, 2);
        assert_eq!(result.unheard, 2);
        assert_eq!(result.percent, 50.0);
        assert_eq!(result.by_artist[0].label, "甲");
        assert_eq!(result.by_artist[0].total, 2);
        assert_eq!(result.by_artist[0].heard, 1);
        assert_eq!(result.by_artist[0].unheard(), 1);
        // 空艺人 / 空年代 / 空流派落到「未标注」桶，而不是空字符串。
        assert!(result.by_artist.iter().any(|b| b.label == "未知艺人"));
        assert!(result.by_decade.iter().any(|b| b.label == "未标注年代"));
        assert!(result.by_genre.iter().any(|b| b.label == "未标注流派"));
        assert!(result.by_decade.iter().any(|b| b.label == "1990s"));
    }

    #[test]
    fn empty_library_has_no_nan_and_zero_percent() {
        let result = coverage(&[], &[]);
        assert_eq!(result.total, 0);
        assert_eq!(result.percent, 0.0);
        assert!(result.percent.is_finite());
        assert!(result.by_artist.is_empty());
    }

    #[test]
    fn events_for_deleted_tracks_do_not_inflate_coverage() {
        let tracks = vec![track("a", "甲", "专辑一", "摇滚", Some(2001))];
        let events = vec![event("a", 40.0, false, 1), event("ghost", 300.0, true, 2)];
        let result = coverage(&tracks, &events);
        assert_eq!(result.heard, 1, "被删掉的曲目不该算进覆盖度");
        assert_eq!(result.percent, 100.0);
    }

    #[test]
    fn album_completion_averages_per_album() {
        let tracks = vec![
            track("a", "甲", "一", "", None),
            track("b", "甲", "一", "", None),
            track("c", "甲", "二", "", None),
        ];
        let events = [event("a", 40.0, false, 1)];
        let heard = heard_ids(&events);
        // 专辑一 1/2，专辑二 0/1 → 平均 0.25
        assert!((album_completion(&tracks, &heard) - 0.25).abs() < 1e-9);
    }

    #[test]
    fn longest_run_follows_time_order() {
        let tracks = vec![
            track("a", "甲", "", "", None),
            track("b", "乙", "", "", None),
            track("c", "甲", "", "", None),
        ];
        // 按时间排：甲、甲、乙 → 最长是 2（第一首与第三首不相邻）
        let events = vec![
            event("a", 40.0, false, 1),
            event("c", 40.0, false, 2),
            event("b", 40.0, false, 3),
        ];
        let (artist, len) = longest_artist_run(&tracks, &events);
        assert_eq!(artist, "甲");
        assert_eq!(len, 2);
    }

    #[test]
    fn achievements_unlock_on_real_thresholds() {
        let tracks: Vec<Track> = (0..8)
            .map(|index| track(&format!("t{index}"), "甲", "一", "", None))
            .collect();
        let events: Vec<ListenEvent> = tracks
            .iter()
            .enumerate()
            .map(|(index, track)| event(&track.id, 200.0, true, index as i64))
            .collect();
        let list = achievements(&tracks, &events);
        assert_eq!(list.len(), 5);
        let by_id = |id: &str| list.iter().find(|a| a.id == id).cloned().unwrap();
        assert!(by_id("unopened").unlocked, "全部听完，宝藏已拆完");
        assert!(by_id("album-completion").unlocked, "整张听完应解锁");
        assert!(!by_id("ticket-debt").unlocked, "只有 1 位艺人，够不到 50");
        assert!(!by_id("comfort-zone").unlocked, "连续 8 首还没到 10");
    }

    #[test]
    fn comfort_zone_unlocks_at_ten_in_a_row() {
        let tracks: Vec<Track> = (0..12)
            .map(|index| track(&format!("t{index}"), "甲", "一", "", None))
            .collect();
        let events: Vec<ListenEvent> = tracks
            .iter()
            .enumerate()
            .map(|(index, track)| event(&track.id, 40.0, false, index as i64))
            .collect();
        let list = achievements(&tracks, &events);
        let comfort = list.iter().find(|a| a.id == "comfort-zone").unwrap();
        assert!(comfort.unlocked);
        assert_eq!(comfort.progress, 12.0);
    }

    #[test]
    fn night_shift_counts_both_second_and_millisecond_timestamps() {
        let tracks = vec![track("a", "甲", "一", "", None)];
        // 0:30 UTC 与 毫秒形式的 0:30 UTC 各一次
        // 同一个瞬间的两种写法，都落在 UTC 01:00（真实量级，避免被当成秒）
        let epoch_seconds = 86_400 * 20_000 + 3_600; // 01:00
        let epoch_millis = epoch_seconds * 1_000;
        let events = vec![
            event("a", 40.0, false, epoch_seconds),
            event("a", 40.0, false, epoch_millis),
        ];
        let list = achievements(&tracks, &events);
        let night = list.iter().find(|a| a.id == "night-shift").unwrap();
        assert_eq!(night.progress, 2.0);
    }
}
