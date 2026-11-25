//! 古典的四个维度，在**专架层**从标签解析，不动 `Track` schema。
//!
//! 这是 2026-11-25 拍板的方案："不拆 schema，先解析"。理由写在计划 6.4：
//! 解析错了只影响一个页面的排序，改回来是改代码；拆进 schema 走错一步就是数据迁移。
//!
//! 解析规则只有三条，且都不猜：
//! 1. 作品号白名单：`Op. / BWV / KV / K. / Hob. / D. / RV / HWV / WoO / S.`
//!    （前九种是 2026-11-25 的第一版；HWV 与 WoO 与 S. 是本次按真实写法补的）；
//! 2. 作曲家优先取专辑名 `作曲家: 作品` 的冒号前半段（中英文冒号都认），
//!    其次 `album_artist`（且必须与演奏者不同），最后才查 [`COMPOSERS`] 词典；
//! 3. 三条都拿不到就返回 None——宁可这张专辑按普通曲目显示，也不编一个作曲家。
//!
//! 词典兜底为什么不算"猜"：它是一张写死的名字表，命中就是命中、没命中就是没命中，
//! 没有"看起来像"的判断。它的作用是补上真实标签里最常见的一种：
//! `album_artist` 与 `artist` 都是演奏者（`Wiener Philharmoniker`），
//! 作曲家只写在 `artist` 的多值串里（`Beethoven; Wiener Philharmoniker`）。

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

/// 作品号白名单。加一种前缀必须同时加一条语料到 `Tools/classical_corpus.json`。
///
/// 为什么 `K.` / `D.` / `Hob.` 的点可有可无：真实标签里 `D 899` 与 `D. 899`
/// 几乎一样常见（不同抓轨工具、不同人的习惯），只认带点的写法会漏掉一半舒伯特。
fn catalogue_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"(?i)\b(op\.?\s*\d{1,3}(?:\s*(?:no\.?)?\s*\d{1,3})?|bwv\s*\d{1,4}|kv\.?\s*\d{1,3}|k\.?\s*\d{1,3}|hob\.?\s*[ivxlc]+(?::\s*\d{1,3})?|d\.?\s*\d{1,4}|rv\s*\d{1,3}|hwv\s*\d{1,4}|woo\s*\d{1,3}|s\.\s*\d{1,4})\b",
        )
        .expect("作品号正则必须可编译")
    })
}

/// 常见古典作曲家的姓/中文名，用于"作曲家只写在 artist 多值串里"这种真实标签。
///
/// 只放**高频**的：名单越长，误判越多，而误判的代价是把流行专辑当成作品。
/// 匹配是"整段包含"（`ludwig van beethoven` 命中 `beethoven`），不做模糊。
const COMPOSERS: &[&str] = &[
    "Bach", "Beethoven", "Mozart", "Haydn", "Handel", "Schubert", "Schumann", "Brahms",
    "Wagner", "Verdi", "Chopin", "Liszt", "Mendelssohn", "Mahler", "Bruckner", "Debussy",
    "Ravel", "Satie", "Faure", "Fauré", "Sibelius", "Grieg", "Dvorak", "Dvořák", "Tchaikovsky",
    "Rachmaninoff", "Mussorgsky", "Rimsky-Korsakov", "Prokofiev", "Shostakovich", "Stravinsky",
    "Bartok", "Bartók", "Vivaldi", "Telemann", "Scarlatti", "Monteverdi", "Palestrina",
    "Purcell", "Elgar", "Vaughan Williams", "Holst", "Britten", "Schoenberg", "Berg", "Webern",
    "Janacek", "Janáček", "Smetana", "Borodin", "Glinka", "Massenet", "Saint-Saens",
    "Saint-Saëns", "Bizet", "Poulenc", "Franck", "Albeniz", "Albéniz", "Granados", "Sarasate",
    "Paganini", "Boccherini", "Corelli", "Couperin", "Rameau", "Lully", "Charpentier",
    "布鲁克纳", "贝多芬", "巴赫", "莫扎特", "海顿", "亨德尔", "舒伯特", "舒曼", "勃拉姆斯",
    "瓦格纳", "威尔第", "肖邦", "李斯特", "门德尔松", "马勒", "德彪西", "拉威尔", "萨蒂",
    "福雷", "西贝柳斯", "格里格", "德沃夏克", "柴可夫斯基", "拉赫玛尼诺夫", "穆索尔斯基",
    "普罗科菲耶夫", "肖斯塔科维奇", "斯特拉文斯基", "巴托克", "维瓦尔第", "泰勒曼",
    "斯卡拉蒂", "蒙特威尔第", "帕莱斯特里那", "普赛尔", "埃尔加", "霍尔斯特", "布里顿",
    "勋伯格", "贝尔格", "韦伯恩", "雅纳切克", "斯美塔那", "鲍罗丁", "格林卡", "圣桑", "比才",
];

/// 一段文本里是否点名了某位作曲家（查表，不做模糊匹配）。
///
/// 返回的是**表里的规范写法**（`Ludwig van Beethoven` → `Beethoven`），
/// 不是原片段：原片段可能是 `Beethoven; Wiener Philharmoniker` 整串，
/// 直接当作曲家显示会又长又不对。
fn names_a_composer(text: &str) -> Option<String> {
    let lowered = text.to_lowercase();
    // 多值标签的分隔符：真实标签里这几个都常见。
    for piece in lowered.split([';', '/', '&', ',', '·', '|']) {
        let piece = piece.trim();
        if piece.is_empty() {
            continue;
        }
        if let Some(found) = COMPOSERS.iter().find(|name| piece.contains(&name.to_lowercase())) {
            return Some((*found).to_string());
        }
    }
    None
}

/// 体裁词：出现在"作曲家"位置上就说明它其实是作品名，不是人名。
/// 这是一条**可判定的排除**，不是"看起来像不像人"的猜测。
const GENRE_WORDS: &[&str] = &[
    "symphony", "symphonies", "concerto", "concertos", "sonata", "sonatas", "quartet",
    "quartets", "quintet", "trio", "suite", "suites", "requiem", "mass", "prelude", "fugue",
    "variations", "nocturne", "waltz", "etude", "étude", "overture", "rhapsody", "cantata",
    "oratorio", "symphonie", "konzert", "交响曲", "协奏曲", "奏鸣曲", "变奏曲", "组曲",
    "安魂曲", "弥撒", "四重奏", "三重奏", "序曲", "狂想曲", "练习曲", "前奏曲", "赋格", "康塔塔",
];

/// 标签里的占位符，不是人名。`Various Artists: Greatest Hits` 这种写法到处都是，
/// 不排掉就会冒出一位叫 "Various Artists" 的作曲家。
const PLACEHOLDERS: &[&str] = &[
    "various artists", "various", "va", "v.a.", "unknown", "unknown artist",
    "群星", "合辑", "未知", "未知艺术家", "佚名",
];

/// 冒号前半段像不像作曲家名。**只排除明显不是的结构**，不判断"像不像人"：
/// 是占位符、有阿拉伯数字（作品号在冒号后面）、含体裁词、词数 > 5、过长。
fn looks_like_composer(head: &str) -> bool {
    let head = head.trim();
    if head.is_empty() || head.chars().count() > 48 {
        return false;
    }
    let lowered = head.to_lowercase();
    if PLACEHOLDERS.iter().any(|slot| lowered == *slot) {
        return false;
    }
    if head.chars().any(|c| c.is_ascii_digit()) {
        return false;
    }
    if GENRE_WORDS.iter().any(|word| lowered.contains(word)) {
        return false;
    }
    // 中文名不会长到十几个字；"贝多芬第五交响曲全集"那种是作品名。
    if head.chars().filter(|c| !c.is_ascii()).count() > 10 {
        return false;
    }
    head.split_whitespace().count() <= 5
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
        "hwv" => "HWV",
        "woo" => "WoO",
        "s." | "s" => "S.",
        _ => "Op.",
    }
    .to_string()
}

/// 从专辑名与曲名解析作品。返回 None 表示"这不像能确定的作品"，不猜。
pub fn parse(album: &str, title: &str, artist: &str, album_artist: &str) -> Option<ParsedWork> {
    let album_text = album.trim();

    // 作曲家：专辑名的「作曲家: 作品」结构。全角冒号也认——中文库里写的是「贝多芬：第五交响曲」。
    let (composer_from_album, title_from_album) = match album_text.split_once([':', '：']) {
        Some((head, tail))
            if !head.trim().is_empty() && !tail.trim().is_empty() && looks_like_composer(head) =>
        {
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

    // 顺序是有讲究的：先查词典（准），再退回"album_artist 与 artist 不同"（旧行为）。
    // 反过来会把 `Wiener Philharmoniker` 这种乐团名当成作曲家——真实库里到处都是。
    let composer = composer_from_album.or_else(|| {
        names_a_composer(artist)
            .or_else(|| names_a_composer(album_artist))
            .or_else(|| names_a_composer(album_text))
            .or_else(|| {
                let album_artist = album_artist.trim();
                let artist = artist.trim();
                if !album_artist.is_empty() && album_artist != artist {
                    Some(album_artist.to_string())
                } else {
                    None
                }
            })
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

    /// 语料用例。`known_gap` 的不计入命中率——它是"已知会错，先记下来"，
    /// 不是"这样算对"。取消 `known_gap` 就是宣布这个缺口补上了。
    #[derive(Debug, serde::Deserialize)]
    struct CorpusCase {
        album: String,
        title: String,
        artist: String,
        album_artist: String,
        want_composer: Option<String>,
        want_catalogue: Option<String>,
        #[serde(default)]
        note: String,
        #[serde(default)]
        known_gap: bool,
    }

    fn corpus_cases() -> Vec<CorpusCase> {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Tools/classical_corpus.json");
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("读不到语料 {}：{error}", path.display()));
        serde_json::from_str(&text).expect("语料必须是合法 JSON 数组")
    }

    fn composer_ok(got: &Option<String>, want: &Option<String>) -> bool {
        match (got, want) {
            (None, None) => true,
            (Some(g), Some(w)) => g.to_lowercase() == w.to_lowercase(),
            _ => false,
        }
    }

    /// 在 `Tools/classical_corpus.json` 上量命中率。
    ///
    /// 这份语料是**常见写法的重建**，不是任何人的真实曲库——所以它证明的是
    /// "解析器覆盖了哪些写法"，不是"用户的库里能命中多少"。
    /// 真实数字要拿 `awake-cli classical-check <library.json>` 在自己的库上跑。
    ///
    /// 输出用 `cargo test -- --nocapture classical_corpus` 看。
    #[test]
    fn classical_corpus_hit_rate_is_measured_not_guessed() {
        let cases = corpus_cases();
        assert!(cases.len() >= 25, "语料少于 25 条就没有统计意义，当前 {}", cases.len());

        let mut hits = 0usize;
        let mut misses: Vec<String> = Vec::new();
        let mut gaps: Vec<String> = Vec::new();
        for case in &cases {
            let parsed = parse(&case.album, &case.title, &case.artist, &case.album_artist);
            let got_composer = parsed.as_ref().and_then(|p| p.composer.clone());
            let got_catalogue = parsed
                .as_ref()
                .and_then(|p| p.catalogue.as_ref().map(catalogue_label));
            let ok = composer_ok(&got_composer, &case.want_composer)
                && got_catalogue == case.want_catalogue;
            let line = format!(
                "{} :: {}（{}）期望 {}/{:?}，实际 {}/{:?}",
                case.album,
                case.title,
                case.note,
                case.want_composer.as_deref().unwrap_or("无作曲家"),
                case.want_catalogue,
                got_composer.as_deref().unwrap_or("无作曲家"),
                got_catalogue
            );
            if ok {
                hits += 1;
            } else if case.known_gap {
                gaps.push(line);
            } else {
                misses.push(line);
            }
        }

        let total = cases.len();
        let scored = total - gaps.len();
        println!();
        println!("古典语料 {total} 条：命中 {hits}，未命中 {}，已知缺口 {}", misses.len(), gaps.len());
        println!(
            "命中率 {:.1}%（{hits} / {scored}，已知缺口不计入分母）",
            100.0 * hits as f64 / scored as f64
        );
        for miss in &misses {
            println!("  未命中: {miss}");
        }
        for gap in &gaps {
            println!("  已知缺口: {gap}");
        }

        assert!(misses.is_empty(), "有未命中用例，明细见上面的输出");
        assert!(
            hits as f64 / scored as f64 >= 0.90,
            "命中率低于 90%：{hits}/{scored}"
        );
    }
}

