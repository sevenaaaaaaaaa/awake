//! 库里艺人画像：只用本地数据，不联网。
//!
//! 这是"歌手维度"的 A 方案实现（画像主语 = 你库里的艺人）：
//! 数据来自 `Taste.events`（每次播放都有一条）与 `Track.artist`，不依赖任何外部目录。
//! 判定"算不算一次听"复用 `Taste::qualified`——一个仓库里只允许一套口径，
//! 否则推荐与画像会给出两个不一样的答案。
//!
//! 明确不做：不抓百科、不猜国籍/流派归属、不把"跳过一次"解释成"不喜欢这个艺人"。

use crate::models::Track;
use crate::taste::{ListenEvent, Taste};
use serde::Serialize;
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ArtistProfile {
    pub artist: String,
    /// 库里这个艺人的曲目数。
    pub tracks: usize,
    /// 达到合格阈值的播放次数（不含跳过）。
    pub plays: usize,
    pub completions: usize,
    pub skips: usize,
    /// 合格播放累计秒数。
    pub seconds: f64,
    pub last_played_ms: Option<i64>,
    /// 库里这个艺人最常见的流派（最多两个，来自曲目标签而不是听歌行为）。
    pub top_genres: Vec<String>,
    /// 合格播放落在哪些 UTC 小时（0..24）。界面负责换算本地时区。
    pub hours_utc: [u32; 24],
    pub completion_rate: f32,
    pub skip_rate: f32,
    /// 一句话画像。数字必须与上面的字段同源。
    pub line: String,
}

const HOUR_MS: i64 = 3_600_000;

/// 按艺人聚合。顺序固定：播放次数 → 累计秒数 → 名字，便于断言与回放。
pub fn profiles(tracks: &[Track], events: &[ListenEvent]) -> Vec<ArtistProfile> {
    let by_id: HashMap<&str, &Track> = tracks.iter().map(|t| (t.id.as_str(), t)).collect();

    let mut library_tracks: HashMap<&str, usize> = HashMap::new();
    let mut genres: HashMap<&str, HashMap<&str, usize>> = HashMap::new();
    for track in tracks {
        let artist = track.artist.trim();
        if artist.is_empty() {
            continue;
        }
        *library_tracks.entry(artist).or_default() += 1;
        let genre = track.genre.trim();
        if !genre.is_empty() {
            *genres.entry(artist).or_default().entry(genre).or_default() += 1;
        }
    }

    struct Acc {
        plays: usize,
        completions: usize,
        skips: usize,
        seconds: f64,
        last: Option<i64>,
        hours: [u32; 24],
    }
    let mut acc: HashMap<&str, Acc> = HashMap::new();
    for event in events {
        let Some(track) = by_id.get(event.track_id.as_str()) else {
            continue; // 曲目已不在库里：事件留着，但不进画像
        };
        let artist = track.artist.trim();
        if artist.is_empty() {
            continue;
        }
        let entry = acc.entry(artist).or_insert(Acc {
            plays: 0,
            completions: 0,
            skips: 0,
            seconds: 0.0,
            last: None,
            hours: [0; 24],
        });
        entry.last = Some(entry.last.map_or(event.at, |last| last.max(event.at)));
        if event.skipped {
            entry.skips += 1;
            continue;
        }
        if !Taste::qualified(event, track) {
            continue;
        }
        entry.plays += 1;
        if event.completed {
            entry.completions += 1;
        }
        entry.seconds += event.seconds;
        let hour = (event.at / HOUR_MS).rem_euclid(24) as usize;
        entry.hours[hour] += 1;
    }

    let mut out: Vec<ArtistProfile> = library_tracks
        .iter()
        .map(|(artist, count)| {
            let (plays, completions, skips, seconds, last, hours) = match acc.get(artist) {
                Some(a) => (a.plays, a.completions, a.skips, a.seconds, a.last, a.hours),
                None => (0, 0, 0, 0.0, None, [0u32; 24]),
            };
            let mut top: Vec<(String, usize)> = genres
                .get(artist)
                .map(|m| m.iter().map(|(g, c)| (g.to_string(), *c)).collect())
                .unwrap_or_default();
            top.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
            let top_genres: Vec<String> = top.into_iter().take(2).map(|(g, _)| g).collect();

            let attempts = plays + skips;
            let completion_rate = if plays == 0 { 0.0 } else { completions as f32 / plays as f32 };
            let skip_rate = if attempts == 0 { 0.0 } else { skips as f32 / attempts as f32 };

            let line = if plays == 0 {
                format!("库里 {count} 首，还没认真听过")
            } else {
                let peak = hours
                    .iter()
                    .enumerate()
                    .max_by_key(|(_, count)| **count)
                    .map(|(hour, _)| hour as i64)
                    .unwrap_or(0);
                format!(
                    "听了 {plays} 次 · 完成率 {:.0}% · 常在 {} 点（UTC）· 库里 {count} 首",
                    completion_rate * 100.0,
                    peak
                )
            };

            ArtistProfile {
                artist: artist.to_string(),
                tracks: *count,
                plays,
                completions,
                skips,
                seconds,
                last_played_ms: last,
                top_genres,
                hours_utc: hours,
                completion_rate,
                skip_rate,
                line,
            }
        })
        .collect();

    out.sort_by(|a, b| {
        b.plays
            .cmp(&a.plays)
            .then(b.seconds.partial_cmp(&a.seconds).unwrap_or(std::cmp::Ordering::Equal))
            .then(a.artist.cmp(&b.artist))
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(id: &str, artist: &str, genre: &str, duration: f64) -> Track {
        serde_json::from_value(serde_json::json!({
            "id": id, "title": id, "artist": artist, "album_artist": artist, "album": "al",
            "genre": genre, "year": null, "track_number": null, "disc_number": null,
            "duration": duration, "sample_rate": 48000, "bit_depth": 24, "channels": 2,
            "codec": "flac", "source_id": "s", "locator": id, "file_size": 1, "modified": 0,
            "artwork_path": null, "play_count": 0, "favorite": false, "last_played": null,
            "added_at": 0, "is_remote": false
        }))
        .expect("测试曲目必须可构造")
    }

    fn event(track_id: &str, seconds: f64, completed: bool, skipped: bool, at: i64) -> ListenEvent {
        ListenEvent { track_id: track_id.to_string(), seconds, completed, skipped, at }
    }

    #[test]
    fn plays_count_only_qualified_listens() {
        let tracks = vec![track("t1", "A", "rock", 200.0)];
        // 200 秒的曲子：阈值 = min(100,120) = 100 秒
        let events = vec![
            event("t1", 120.0, false, false, 1_760_000_000_000),
            event("t1", 5.0, false, false, 1_760_000_100_000), // 太短，不算
            event("t1", 180.0, true, false, 1_760_000_200_000),
        ];
        let p = profiles(&tracks, &events);
        assert_eq!(p.len(), 1);
        assert_eq!(p[0].plays, 2);
        assert_eq!(p[0].completions, 1);
        assert_eq!(p[0].seconds, 300.0);
        assert!((p[0].completion_rate - 0.5).abs() < 1e-6);
    }

    #[test]
    fn skips_are_counted_but_never_become_plays() {
        let tracks = vec![track("t1", "A", "rock", 200.0)];
        let events = vec![event("t1", 8.0, false, true, 1_760_000_000_000)];
        let p = profiles(&tracks, &events);
        assert_eq!(p[0].plays, 0);
        assert_eq!(p[0].skips, 1);
        assert_eq!(p[0].seconds, 0.0);
        assert!((p[0].skip_rate - 1.0).abs() < 1e-6);
    }

    #[test]
    fn unknown_tracks_and_blank_artists_are_ignored() {
        let tracks = vec![track("t1", "", "rock", 200.0)];
        let events = vec![event("ghost", 200.0, true, false, 1), event("t1", 200.0, true, false, 1)];
        assert!(profiles(&tracks, &events).is_empty(), "空艺人名不进画像");
    }

    #[test]
    fn top_genres_come_from_the_library_and_stop_at_two() {
        let tracks = vec![
            track("t1", "A", "rock", 200.0),
            track("t2", "A", "rock", 200.0),
            track("t3", "A", "jazz", 200.0),
            track("t4", "A", "pop", 200.0),
        ];
        let p = profiles(&tracks, &[]);
        assert_eq!(p[0].tracks, 4);
        assert_eq!(p[0].top_genres, vec!["rock".to_string(), "jazz".to_string()]);
        assert_eq!(p[0].line, "库里 4 首，还没认真听过");
    }

    #[test]
    fn hour_histogram_is_utc_and_line_matches_fields() {
        let tracks = vec![track("t1", "A", "rock", 200.0)];
        // 1_760_000_000_000 ms → UTC 08 点
        let events = vec![event("t1", 200.0, true, false, 1_760_000_000_000)];
        let p = profiles(&tracks, &events);
        assert_eq!(p[0].hours_utc[8], 1);
        assert!(p[0].line.contains("听了 1 次"), "{}", p[0].line);
        assert!(p[0].line.contains("常在 8 点"), "{}", p[0].line);
    }

    #[test]
    fn order_is_deterministic_by_plays_then_seconds_then_name() {
        let tracks = vec![track("t1", "B", "rock", 200.0), track("t2", "C", "rock", 200.0), track("t3", "A", "rock", 200.0)];
        let events = vec![
            event("t2", 200.0, true, false, 1_760_000_000_000),
            event("t1", 200.0, true, false, 1_760_000_000_000),
            event("t3", 200.0, true, false, 1_760_000_000_000),
        ];
        let p = profiles(&tracks, &events);
        assert_eq!(p.iter().map(|x| x.artist.as_str()).collect::<Vec<_>>(), vec!["A", "B", "C"]);
    }

    #[test]
    fn last_played_uses_the_latest_event_even_if_it_was_skipped() {
        let tracks = vec![track("t1", "A", "rock", 200.0)];
        let events = vec![
            event("t1", 200.0, true, false, 1_700_000_000_000),
            event("t1", 3.0, false, true, 1_760_000_000_000),
        ];
        let p = profiles(&tracks, &events);
        assert_eq!(p[0].last_played_ms, Some(1_760_000_000_000));
        assert_eq!(p[0].plays, 1);
    }

    #[test]
    fn empty_input_gives_empty_output() {
        assert!(profiles(&[], &[]).is_empty());
    }
}
