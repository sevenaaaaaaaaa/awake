//! 古典的四个维度，在**专架层**从标签解析，不动 `Track` schema。
//!
//! 这是 2026-11-25 拍板的方案："不拆 schema，先解析"。理由写在计划 6.4：
//! 解析错了只影响一个页面的排序，改回来是改代码；拆进 schema 走错一步就是数据迁移。
//!
//! 解析规则只有两条，且都不猜：
//! 1. 必须能识别出**作品号**（Op./BWV/K./KV/Hob./D./RV），或专辑名里有 `作曲家: 作品` 的冒号结构；
//! 2. 作曲家优先取冒号前半段，其次取 `album_artist`（且必须与演奏者不同）。
//! 两条都拿不到就返回 None——宁可这张专辑按普通曲目显示，也不编一个作曲家。

use crate::models::Track;
use regex::Regex;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Catalogue {
    /// 归一化后的前缀：`Op.` / `BWV` / `K.` / `Hob.` / `D.` / `RV`
    pub prefix: String,
    /// 原样保留的编号（可能有 `9 No. 2` 这种复合）。
    pub number: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ParsedWork {
    pub composer: Option<String>,
    /// 去掉作曲家前缀、去掉作品号之后的曲名。空字符串表示"只知道作品号"。
    pub title: String,
    pub catalogue: Option<Catalogue>,
    /// 乐章标记（`I` / `Var. 3` / `No. 2`），拿不到就是 None。
    pub movement: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ClassicalWork {
    pub composer: String,
    pub work: String,
    pub catalogue: String,
    pub movement_count: usize,
    pub track_ids: Vec<String>,
}

fn catalogue_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"(?i)\b(op\.?\s*\d{1,3}(?:\s*(?:no\.?)?\s*\d{1,3})?|bwv\s*\d{1,4}|kv\.?\s*\d{1,3}|k\.\s*\d{1,3}|hob\.\s*[ivxlc]+(?::\s*\d{1,3})?|d\.\s*\d{1,4}|rv\s*\d{1,3})\b",
        )
        .expect("作品号正则必须可编译")
    })
}

fn movement_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)^\s*(?:([ivxlcdm]+)\s*[.、]|(var\.?|variation)\s*(\d+)|(no\.?)\s*(\d+)|(\d{1,2})\s*[.、])")
            .expect("乐章正则必须可编译")
    })
}

fn normalize_prefix(raw: &str) -> String {
    let lower = raw.to_lowercase();
    let head = lower.split_whitespace().next().unwrap_or(&lower);
    match head {
        "op." | "op" => "Op.",
        "bwv" => "BWV",
        "kv." | "kv" => "K.",
        "k." | "k" => "K.",
        "hob." | "hob" => "Hob.",
        "d." | "d" => "D.",
        "rv" => "RV",
        _ => "Op.",
    }
    .to_string()
}

/// 从专辑名与曲名解析作品。返回 None 表示"这不像能确定的作品"，不猜。
pub fn parse(album: &str, title: &str, artist: &str, album_artist: &str) -> Option<ParsedWork> {
    let album_text = album.trim();

    // 作曲家：专辑名的「作曲家: 作品」结构
    let (composer_from_album, title_from_album) = match album_text.split_once(':') {
        Some((head, tail)) if !head.trim().is_empty() && !tail.trim().is_empty() => {
            (Some(head.trim().to_string()), tail.trim().to_string())
        }
        _ => (None, album_text.to_string()),
    };

    let catalogue = catalogue_re().find(album_text).or_else(|| catalogue_re().find(title)).map(|m| {
        let raw = m.as_str().to_string();
        let mut parts = raw.splitn(2, char::is_whitespace);
        let prefix = normalize_prefix(parts.next().unwrap_or(""));
        let number = parts.next().unwrap_or("").trim().to_string();
        Catalogue { prefix, number }
    });

    let composer = composer_from_album.or_else(|| {
        let album_artist = album_artist.trim();
        let artist = artist.trim();
        if !album_artist.is_empty() && album_artist != artist {
            Some(album_artist.to_string())
        } else {
            None
        }
    });

    // 两条依据都没有 → 不归为"作品"。
    if catalogue.is_none() && composer.is_none() {
        return None;
    }

    let work_title = if title_from_album.is_empty() {
        String::new()
    } else {
        catalogue_re()
            .replace_all(&title_from_album, "")
            .trim_matches(|c: char| c.is_whitespace() || c == ',' || c == '-' || c == '(' || c == ')')
            .to_string()
    };

    let movement = movement_re().find(title.trim()).map(|m| {
        m.as_str()
            .trim()
            .trim_end_matches(['.', '、'])
            .to_string()
    });

    Some(ParsedWork { composer, title: work_title, catalogue, movement })
}

fn catalogue_label(catalogue: &Catalogue) -> String {
    if catalogue.number.is_empty() {
        catalogue.prefix.clone()
    } else {
        format!("{} {}", catalogue.prefix, catalogue.number)
    }
}

/// 按"作曲家 + 作品号 + 曲名"聚合，供专架页按作品浏览。
///
/// 两条取舍：
/// - **必须有作曲家**才进作品视图。没有作曲家的条目只会聚成一堆"未知作曲家"，是噪音；
/// - 没有作品号也能成组（用曲名当键）——"Symphony No. 5" 这种专辑是常态。
///
/// 调用方只应传已经归入古典的曲目（`shelf::overview` 就是这么用的）。
pub fn works(tracks: &[Track]) -> Vec<ClassicalWork> {
    let mut grouped: HashMap<(String, String, String), ClassicalWork> = HashMap::new();
    for track in tracks {
        let Some(parsed) = parse(&track.album, &track.title, &track.artist, &track.album_artist) else {
            continue;
        };
        let Some(composer) = parsed.composer.clone() else {
            continue;
        };
        let catalogue_text = parsed
            .catalogue
            .as_ref()
            .map(catalogue_label)
            .unwrap_or_default();
        let work_key = if parsed.title.is_empty() {
            catalogue_text.clone()
        } else {
            parsed.title.clone()
        };
        let key = (composer.clone(), work_key.clone(), catalogue_text.clone());
        grouped
            .entry(key)
            .and_modify(|work| {
                work.movement_count += 1;
                work.track_ids.push(track.id.clone());
            })
            .or_insert_with(|| ClassicalWork {
                composer,
                work: if work_key.is_empty() {
                    "（未标注曲名）".to_string()
                } else {
                    work_key.clone()
                },
                catalogue: catalogue_text.clone(),
                movement_count: 1,
                track_ids: vec![track.id.clone()],
            });
    }

    let mut out: Vec<ClassicalWork> = grouped.into_values().collect();
    for work in &mut out {
        work.track_ids.sort();
    }
    // 顺序固定：先按作曲家，再按作品号文本（BWV 988 < BWV 1048 这类差异由用户自己看）
    out.sort_by(|a, b| {
        a.composer
            .cmp(&b.composer)
            .then(a.catalogue.cmp(&b.catalogue))
            .then(a.work.cmp(&b.work))
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(id: &str, album: &str, title: &str, artist: &str, album_artist: &str) -> Track {
        serde_json::from_value(serde_json::json!({
            "id": id, "title": title, "artist": artist, "album_artist": album_artist,
            "album": album, "genre": "Classical", "year": null, "track_number": null,
            "disc_number": null, "duration": 300.0, "sample_rate": 96000, "bit_depth": 24,
            "channels": 2, "codec": "flac", "source_id": "s", "locator": id, "file_size": 1,
            "modified": 0, "artwork_path": null, "play_count": 0, "favorite": false,
            "last_played": null, "added_at": 0, "is_remote": false
        }))
        .expect("测试曲目必须可构造")
    }

    #[test]
    fn composer_work_and_catalogue_come_from_the_album() {
        let parsed = parse(
            "Bach: Goldberg Variations, BWV 988",
            "Aria",
            "Glenn Gould",
            "Glenn Gould",
        )
        .expect("应能解析");
        assert_eq!(parsed.composer.as_deref(), Some("Bach"));
        assert_eq!(parsed.title, "Goldberg Variations");
        assert_eq!(parsed.catalogue.unwrap().prefix, "BWV");
    }

    #[test]
    fn opus_number_and_movement_come_from_the_track() {
        let parsed = parse(
            "Beethoven: Symphony No. 5",
            "I. Allegro con brio",
            "Wiener Philharmoniker",
            "Wiener Philharmoniker",
        )
        .expect("应能解析");
        assert_eq!(parsed.composer.as_deref(), Some("Beethoven"));
        assert_eq!(parsed.movement.as_deref(), Some("I"));
    }

    #[test]
    fn hoboken_and_schubert_forms_are_recognized() {
        let hob = parse("Haydn: Sonata", "Hob. XVI:52 - Allegro", "A", "A").unwrap();
        assert_eq!(hob.catalogue.as_ref().unwrap().prefix, "Hob.");

        let schubert = parse("Schubert: Impromptus", "D. 899 No. 3", "A", "A").unwrap();
        assert_eq!(schubert.catalogue.as_ref().unwrap().prefix, "D.");
    }

    #[test]
    fn parse_reports_a_catalogue_but_does_not_decide_classicalness() {
        // 解析器只负责"读出有什么"：作品号能读到，作曲家读不到。
        let parsed = parse("Greatest Hits", "Op. 1 (Remastered)", "Some Band", "Some Band")
            .expect("能读到作品号就返回 Some");
        assert_eq!(parsed.composer, None);
        assert_eq!(parsed.catalogue.unwrap().number, "1");
    }

    #[test]
    fn works_skip_tracks_without_a_composer() {
        // 决定"算不算作品"的是 works()：没有作曲家就不进作品视图。
        let tracks = vec![track("p1", "Greatest Hits", "Op. 1 (Remastered)", "Some Band", "Some Band")];
        assert!(works(&tracks).is_empty());
    }

    #[test]
    fn works_group_by_composer_and_catalogue() {
        let tracks = vec![
            track("t1", "Bach: Goldberg Variations, BWV 988", "Aria", "Gould", "Gould"),
            track("t2", "Bach: Goldberg Variations, BWV 988", "Variatio 1", "Gould", "Gould"),
            track("t3", "Beethoven: Symphony No. 5", "I. Allegro", "VPO", "VPO"),
            track("t4", "Some Pop Album", "Song", "Band", "Band"),
        ];
        let works = works(&tracks);
        assert_eq!(works.len(), 2, "没有作曲家的流行曲不进作品视图");

        let bach = works.iter().find(|w| w.composer == "Bach").expect("Bach 应在");
        assert_eq!(bach.movement_count, 2);
        assert_eq!(bach.catalogue, "BWV 988");
        assert_eq!(bach.work, "Goldberg Variations");

        let beethoven = works.iter().find(|w| w.composer == "Beethoven").expect("Beethoven 应在");
        assert_eq!(beethoven.catalogue, "", "专辑里没有作品号，就不编一个");
        assert_eq!(beethoven.work, "Symphony No. 5");
    }
}
