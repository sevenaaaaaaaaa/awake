//! 独特内容的归类：古典 / 轻音乐 / 现场。
//!
//! 规则来自 `docs/plan-v1-sources-home-adaptation.md` 第 6 节：
//! **古典至少两个信号同时成立才归类**，因为错分比不分更伤信任。
//! 轻音乐只有流派标签一个信号，所以它是"可选专架"（`Light` 可以被用户关掉）。
//!
//! 这里只做元数据判断，不碰音频。频谱类的第二个信号留到二期。

use crate::models::Track;
use regex::Regex;
use serde::Serialize;
use std::sync::OnceLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum Shelf {
    Classical,
    Light,
    Live,
    None,
}

impl Shelf {
    /// 落库/聚合用的稳定键。
    pub fn key(self) -> &'static str {
        match self {
            Shelf::Classical => "classical",
            Shelf::Light => "light",
            Shelf::Live => "live",
            Shelf::None => "none",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Shelf::Classical => "古典",
            Shelf::Light => "轻音乐",
            Shelf::Live => "现场",
            Shelf::None => "",
        }
    }
}

/// 一次归类的结果。`signals` 是给界面看的"为什么在这里"。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Classification {
    pub shelf: Shelf,
    pub signals: Vec<&'static str>,
}

/// 专辑上下文：结构信号要它，单首曲目看不出来。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AlbumContext {
    pub track_count: usize,
    pub average_seconds: f64,
}

/// 各专架的默认 EQ 取向。数值来自计划第 6.3 节，是可覆盖的起点。
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct ShelfEq {
    /// 低频搁架允许的最大上抬（dB）。
    pub low_shelf_max_db: f32,
    /// 高频搁架的默认值（dB，负数为衰减）。
    pub high_shelf_db: f32,
    /// 限幅阈值相对默认抬高多少（dB），用来保住古典的弱奏。
    pub limiter_headroom_db: f32,
}

pub fn default_eq(shelf: Shelf) -> ShelfEq {
    match shelf {
        Shelf::Classical => ShelfEq { low_shelf_max_db: 1.0, high_shelf_db: 0.0, limiter_headroom_db: 3.0 },
        Shelf::Light => ShelfEq { low_shelf_max_db: 0.0, high_shelf_db: -1.2, limiter_headroom_db: 0.0 },
        Shelf::Live => ShelfEq { low_shelf_max_db: 0.0, high_shelf_db: 0.0, limiter_headroom_db: 0.0 },
        Shelf::None => ShelfEq { low_shelf_max_db: 0.0, high_shelf_db: 0.0, limiter_headroom_db: 0.0 },
    }
}

const CLASSICAL_TAGS: &[&str] = &["classical", "古典", "baroque", "巴洛克", "opera", "歌剧", "chamber", "室内乐"];
const LIGHT_TAGS: &[&str] = &["轻音乐", "easy listening", "new age", "ambient", "chill", "lounge", "放松"];
const LIVE_TAGS: &[&str] = &["live", "现场", "演唱会", "unplugged"];

fn work_number_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)\b(?:op\.?\s?\d{1,3}|bwv\s?\d{1,4}|kv\.?\s?\d{1,3}|k\.\s?\d{1,3}|hob\.[^ ]{0,6}|d\.\s?\d{1,4}|rv\s?\d{1,3})\b")
            .expect("作品号正则必须可编译")
    })
}

fn any_tag(haystack: &str, tags: &[&'static str]) -> Option<&'static str> {
    let low = haystack.to_lowercase();
    tags.iter().copied().find(|t| low.contains(t))
}

/// 归类。`album` 为 None 时结构信号缺席——这也是为什么古典需要两个信号。
pub fn classify(track: &Track, album: Option<AlbumContext>) -> Classification {
    let mut signals: Vec<&'static str> = Vec::new();

    if any_tag(&track.album, LIVE_TAGS).is_some() {
        // 现场优先：它的默认 EQ 与录音室不同，误判代价低（只是不额外处理）。
        return Classification { shelf: Shelf::Live, signals: vec!["album:live"] };
    }

    if any_tag(&track.genre, CLASSICAL_TAGS).is_some() {
        signals.push("genre:classical");
    }
    let title_album = format!("{} {}", track.title, track.album);
    if work_number_re().is_match(&title_album) {
        signals.push("work-number");
    }
    if let Some(ctx) = album {
        if ctx.track_count >= 3 && ctx.average_seconds >= 240.0 {
            signals.push("structure:multi-movement");
        }
    }

    if signals.len() >= 2 {
        return Classification { shelf: Shelf::Classical, signals };
    }

    if any_tag(&track.genre, LIGHT_TAGS).is_some() {
        return Classification { shelf: Shelf::Light, signals: vec!["genre:light"] };
    }

    Classification { shelf: Shelf::None, signals: Vec::new() }
}

/// 一个专架在界面上的样子。`reasons` 只留前三条不同的信号，够解释就行。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ShelfGroup {
    pub key: &'static str,
    pub label: &'static str,
    pub count: usize,
    pub track_ids: Vec<String>,
    pub reasons: Vec<&'static str>,
    /// 只有古典专架会填：按 作曲家 + 作品号 + 曲名 聚合（见 `classical::works`）。
    /// 四个维度留在这一层，不写进 `Track` schema。
    #[serde(default)]
    pub works: Vec<crate::classical::ClassicalWork>,
}

/// 把曲库按专架分组。专辑上下文（曲目数/平均时长）在这里从曲目自己算，
/// 不让调用方传——否则界面和后端会各算一套，专架里的东西对不上。
pub fn overview(tracks: &[Track]) -> Vec<ShelfGroup> {
    use std::collections::HashMap;

    // 专辑键：同一张专辑的曲目共享结构信号。
    let mut albums: HashMap<String, (usize, f64)> = HashMap::new();
    for track in tracks {
        let key = format!("{}||{}", track.album_artist, track.album);
        let entry = albums.entry(key).or_insert((0, 0.0));
        entry.0 += 1;
        entry.1 += track.duration;
    }
    let context = |track: &Track| -> Option<AlbumContext> {
        let key = format!("{}||{}", track.album_artist, track.album);
        albums.get(&key).map(|(count, total)| AlbumContext {
            track_count: *count,
            average_seconds: if *count == 0 { 0.0 } else { total / *count as f64 },
        })
    };

    let mut groups: HashMap<&'static str, ShelfGroup> = HashMap::new();
    for track in tracks {
        let c = classify(track, context(track));
        if c.shelf == Shelf::None {
            continue;
        }
        let group = groups.entry(c.shelf.key()).or_insert_with(|| ShelfGroup {
            key: c.shelf.key(),
            label: c.shelf.label(),
            count: 0,
            track_ids: Vec::new(),
            reasons: Vec::new(),
            works: Vec::new(),
        });
        group.count += 1;
        group.track_ids.push(track.id.clone());
        for signal in c.signals {
            if group.reasons.len() < 3 && !group.reasons.contains(&signal) {
                group.reasons.push(signal);
            }
        }
    }

    let mut out: Vec<ShelfGroup> = groups.into_values().collect();
    for group in &mut out {
        group.track_ids.sort();
    }
    // 古典专架额外给"作品视图"：作曲家/作品/乐章在这一层解析，不动 schema。
    if let Some(classical) = out.iter_mut().find(|g| g.key == "classical") {
        let ids: std::collections::HashSet<&str> =
            classical.track_ids.iter().map(String::as_str).collect();
        let members: Vec<Track> = tracks
            .iter()
            .filter(|track| ids.contains(track.id.as_str()))
            .cloned()
            .collect();
        classical.works = crate::classical::works(&members);
    }
    // 顺序固定：古典 → 轻音乐 → 现场（按 key 排序也稳定，但语义顺序更可读）。
    out.sort_by_key(|g| match g.key {
        "classical" => 0,
        "light" => 1,
        _ => 2,
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(genre: &str, album: &str, title: &str, duration: f64) -> Track {
        serde_json::from_value(serde_json::json!({
            "id": title, "title": title, "artist": "A", "album_artist": "A", "album": album,
            "genre": genre, "year": null, "track_number": null, "disc_number": null,
            "duration": duration, "sample_rate": 48000, "bit_depth": 24, "channels": 2,
            "codec": "flac", "source_id": "s", "locator": title, "file_size": 1, "modified": 0,
            "artwork_path": null, "play_count": 0, "favorite": false, "last_played": null,
            "added_at": 0, "is_remote": false
        }))
        .expect("测试曲目必须可构造")
    }

    #[test]
    fn classical_needs_two_signals() {
        let with_number = track("Classical", "Bach: Goldberg Variations BWV 988", "Aria", 300.0);
        let c = classify(&with_number, Some(AlbumContext { track_count: 32, average_seconds: 180.0 }));
        assert_eq!(c.shelf, Shelf::Classical);
        assert!(c.signals.contains(&"genre:classical"));
        assert!(c.signals.contains(&"work-number"));

        let genre_only = track("古典", "某合集", "第一首", 200.0);
        let c = classify(&genre_only, None);
        assert_eq!(c.shelf, Shelf::None, "只有流派一个信号，不许进古典专架");
        assert!(c.signals.len() < 2);
    }

    #[test]
    fn pop_title_with_op_is_not_classical() {
        let pop = track("Pop", "Greatest Hits", "Op. 1 (Remastered)", 210.0);
        let c = classify(&pop, Some(AlbumContext { track_count: 12, average_seconds: 210.0 }));
        assert_eq!(c.shelf, Shelf::None, "作品号单独出现不算古典");
    }

    #[test]
    fn long_album_plus_genre_is_enough() {
        let t = track("Classical", "Chopin: Nocturnes", "Nocturne in E-flat", 270.0);
        let c = classify(&t, Some(AlbumContext { track_count: 21, average_seconds: 280.0 }));
        assert_eq!(c.shelf, Shelf::Classical);
        assert!(c.signals.contains(&"structure:multi-movement"));
    }

    #[test]
    fn live_wins_before_everything_else() {
        let t = track("Classical", "Bach: Live in Leipzig", "Aria", 300.0);
        let c = classify(&t, None);
        assert_eq!(c.shelf, Shelf::Live);
        assert_eq!(c.signals, vec!["album:live"]);
    }

    #[test]
    fn light_music_is_its_own_shelf() {
        let t = track("轻音乐", "雨天钢琴", "窗边", 180.0);
        let c = classify(&t, None);
        assert_eq!(c.shelf, Shelf::Light);
        assert_eq!(c.signals, vec!["genre:light"]);
    }

    #[test]
    fn default_eq_numbers_match_the_plan() {
        let c = default_eq(Shelf::Classical);
        assert_eq!((c.low_shelf_max_db, c.high_shelf_db, c.limiter_headroom_db), (1.0, 0.0, 3.0));
        let l = default_eq(Shelf::Light);
        assert_eq!((l.low_shelf_max_db, l.high_shelf_db), (0.0, -1.2));
        for s in [Shelf::Live, Shelf::None] {
            let e = default_eq(s);
            assert_eq!((e.low_shelf_max_db, e.high_shelf_db, e.limiter_headroom_db), (0.0, 0.0, 0.0));
        }
    }

    #[test]
    fn overview_groups_three_shelves_and_never_invents_reasons() {
        let tracks = vec![
            track("Classical", "Bach: Goldberg Variations BWV 988", "Aria", 300.0),
            track("Classical", "Bach: Goldberg Variations BWV 988", "Variatio 1", 280.0),
            track("Classical", "Bach: Goldberg Variations BWV 988", "Variatio 2", 260.0),
            track("轻音乐", "雨天钢琴", "窗边", 180.0),
            track("", "某个现场", "Live 版", 200.0),
            track("Pop", "Greatest Hits", "Op. 1", 210.0),
        ];
        let groups = overview(&tracks);
        let keys: Vec<&str> = groups.iter().map(|g| g.key).collect();
        assert_eq!(keys, vec!["classical", "light", "live"], "顺序固定，未知内容不占位");

        let classical = &groups[0];
        assert_eq!(classical.count, 3);
        assert_eq!(classical.label, "古典");
        assert!(classical.reasons.contains(&"genre:classical"));
        assert!(classical.track_ids.len() == 3);

        let light = &groups[1];
        assert_eq!(light.count, 1);
        assert_eq!(light.reasons, vec!["genre:light"]);

        // 古典专架带作品视图：作曲家与作品号从标签来，不来自 schema。
        assert_eq!(classical.works.len(), 1);
        assert_eq!(classical.works[0].composer, "Bach");
        assert_eq!(classical.works[0].catalogue, "BWV 988");
        assert_eq!(classical.works[0].movement_count, 3);
    }

    #[test]
    fn unknown_content_stays_none_with_no_signals() {
        let t = track("", "", "untitled", 120.0);
        let c = classify(&t, None);
        assert_eq!(c.shelf, Shelf::None);
        assert!(c.signals.is_empty());
    }
}
