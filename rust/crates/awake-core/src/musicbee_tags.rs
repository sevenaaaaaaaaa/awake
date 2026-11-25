//! MusicBee 标签码 → 字段名，以及"真实文件里到底出现了哪些码"的普查。
//!
//! ## 来源（B 级）
//!
//! 官方插件 SDK 的 `public enum MetaDataType`，原文 `MusicBeeInterface.cs` 第 391–466 行：
//! `<https://www.getmusicbee.com/download/plugins/MusicBeeInterface.cs>`。
//! 该地址对脚本返回 403，实际取的是内容相同的 GitHub 镜像
//! （`cqjjjzr/MusicBee-NeteaseLyrics` 的 `MusicBeeInterface.cs`，39976 字节），
//! 取回后用脚本按 `Name = 数字` 解析成下表，**没有手抄**，所以不会出现抄错一位的数字。
//!
//! ## 验证状态：推断，未用真实 `.mbl` 验证
//!
//! 依据是两条公开事实：插件 API 自 v3.1 起向后兼容；MusicBee 内部标签存储只有一套枚举。
//! **这不足以当 A 级证据**——反证条件写在下面，一条命令就能验：
//!
//! ```sh
//! awake-cli mbl tags /path/to/MusicBeeLibrary.mbl
//! ```
//!
//! 输出是每个实际出现的 code、表里对应的名字、出现次数、三个去重样例值。
//! 判定规则只有一条：**样例值的语义必须和名字对得上**。
//! 对不上就是这张表错了，改这里，不要改调用方。
//! 表里没有的 code 会显示为 `unknown(code=N)`——那就是真实文件里有、我们还没收进表的标签。
//!
//! ## 两项在 `.mbl` 的 tags 段里不会出现
//!
//! - `Artwork = 40`：封面走每条记录自己的 artwork 段，不进 tags；
//! - `HasLyrics = 63`：布尔，MusicBee 不把它写成字符串标签。
//!
//! 保留在表里是为了让"这个 code 是不是已知标签"的判断准确，不是为了在 tags 里找它们。

use crate::musicbee::MblRecord;
use serde::Serialize;

/// `(码, MusicBee 枚举名, 规范化字段名)`，按码升序。
///
/// 由 SDK 枚举生成，不要手改；要加自定义标签也在这里加，并补一条测试说明来处。
pub const TAG_CODES: &[(u8, &str, &str)] = &[
    (19, "PrimaryArtist", "primary_artist"),
    (30, "Album", "album"),
    (31, "AlbumArtist", "album_artist"),
    (32, "Artist", "artist"),
    (33, "MultiArtist", "multi_artist"),
    (34, "AlbumArtistRaw", "album_artist_raw"),
    (40, "Artwork", "artwork"),
    (41, "BeatsPerMin", "beats_per_min"),
    (43, "Composer", "composer"),
    (44, "Comment", "comment"),
    (45, "Conductor", "conductor"),
    (46, "Custom1", "custom1"),
    (47, "Custom2", "custom2"),
    (48, "Custom3", "custom3"),
    (49, "Custom4", "custom4"),
    (50, "Custom5", "custom5"),
    (52, "DiscNo", "disc_no"),
    (54, "DiscCount", "disc_count"),
    (55, "Encoder", "encoder"),
    (59, "Genre", "genre"),
    (60, "GenreCategory", "genre_category"),
    (61, "Grouping", "grouping"),
    (62, "Lyricist", "lyricist"),
    (63, "HasLyrics", "has_lyrics"),
    (64, "Mood", "mood"),
    (65, "TrackTitle", "track_title"),
    (66, "Occasion", "occasion"),
    (67, "Origin", "origin"),
    (73, "Publisher", "publisher"),
    (74, "Quality", "quality"),
    (75, "Rating", "rating"),
    (76, "RatingLove", "rating_love"),
    (84, "Keywords", "keywords"),
    (85, "Tempo", "tempo"),
    (86, "TrackNo", "track_no"),
    (87, "TrackCount", "track_count"),
    (88, "Year", "year"),
    (89, "MultiComposer", "multi_composer"),
    (96, "Custom6", "custom6"),
    (97, "Custom7", "custom7"),
    (98, "Custom8", "custom8"),
    (99, "Custom9", "custom9"),
    (104, "RatingAlbum", "rating_album"),
    (109, "Virtual1", "virtual1"),
    (110, "Virtual2", "virtual2"),
    (111, "Virtual3", "virtual3"),
    (112, "Virtual4", "virtual4"),
    (113, "Virtual5", "virtual5"),
    (114, "Lyrics", "lyrics"),
    (122, "Virtual6", "virtual6"),
    (123, "Virtual7", "virtual7"),
    (124, "Virtual8", "virtual8"),
    (125, "Virtual9", "virtual9"),
    (128, "Custom10", "custom10"),
    (129, "Custom11", "custom11"),
    (130, "Custom12", "custom12"),
    (131, "Custom13", "custom13"),
    (132, "Custom14", "custom14"),
    (133, "Custom15", "custom15"),
    (134, "Custom16", "custom16"),
    (135, "Virtual10", "virtual10"),
    (136, "Virtual11", "virtual11"),
    (137, "Virtual12", "virtual12"),
    (138, "Virtual13", "virtual13"),
    (139, "Virtual14", "virtual14"),
    (140, "Virtual15", "virtual15"),
    (141, "Virtual16", "virtual16"),
    (143, "Genres", "genres"),
    (144, "Artists", "artists"),
    (145, "ArtistsWithArtistRole", "artists_with_artist_role"),
    (146, "ArtistsWithPerformerRole", "artists_with_performer_role"),
    (147, "ArtistsWithGuestRole", "artists_with_guest_role"),
    (148, "ArtistsWithRemixerRole", "artists_with_remixer_role"),
];

/// 码 → MusicBee 枚举名（`TrackTitle` 这种，和 MusicBee 界面/插件文档对得上）。
pub fn enumerate(code: u8) -> Option<&'static str> {
    TAG_CODES.iter().find(|(c, _, _)| *c == code).map(|(_, name, _)| *name)
}

/// 码 → 规范化字段名（`track_title` 这种，给 JSON 与界面用）。
pub fn field(code: u8) -> Option<&'static str> {
    TAG_CODES.iter().find(|(c, _, _)| *c == code).map(|(_, _, field)| *field)
}

/// 规范化字段名 → 码。查不到就是 None，不猜"最像的那个"。
pub fn code_for(field: &str) -> Option<u8> {
    let wanted = field.trim();
    TAG_CODES
        .iter()
        .find(|(_, name, f)| *f == wanted || *name == wanted)
        .map(|(code, _, _)| *code)
}

/// 一个 code 在整份库里的实际情况。`name` / `field` 为 None 表示表里没有这个码。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TagStat {
    pub code: u8,
    pub name: Option<&'static str>,
    pub field: Option<&'static str>,
    /// 带这个码的记录数（不是值出现的次数）。
    pub records: usize,
    /// 最多三个去重样例值，按首次出现顺序。空值不计入样例，但计入 `empty_values`。
    pub samples: Vec<String>,
    /// 空值出现的次数。同一条记录里同一个码出现两次且都为空时算两次——
    /// 重复码本身是病态数据，这里如实计数而不是判断"这条记录算不算空"。
    pub empty_values: usize,
}

impl TagStat {
    /// 一条给人看的行；`unknown` 必须显眼，否则缺码会被当成正常。
    pub fn line(&self) -> String {
        self.line_with(None)
    }

    /// 带名字覆盖的同一行。`override_name` 来自 `--tag 65=Xxx`，
    /// 显式标 `(覆盖)`——否则改了名却看不出改过，下一次又会被当成 SDK 的结论。
    pub fn line_with(&self, override_name: Option<&str>) -> String {
        let name = match override_name {
            Some(name) => format!("{name} (覆盖)"),
            None => match (self.name, self.field) {
                (Some(name), Some(field)) => format!("{name} ({field})"),
                _ => format!("unknown(code={})", self.code),
            },
        };
        let samples = if self.samples.is_empty() {
            "—".to_string()
        } else {
            self.samples.iter().map(|s| format!("`{s}`")).collect::<Vec<_>>().join(" / ")
        };
        format!(
            "{:>3}  {:<34} {:>6} 条{}  例: {}",
            self.code,
            name,
            self.records,
            if self.empty_values > 0 {
                format!("（其中 {} 个空值）", self.empty_values)
            } else {
                String::new()
            },
            samples
        )
    }
}

/// 普查：整份库里每个 code 出现了多少次、样例值是什么。
///
/// 按码升序；只列真实出现过的码。这是"验证映射表"的唯一手段——
/// 不推断语义，只把事实摆出来让人一眼判断。
pub fn census(records: &[MblRecord]) -> Vec<TagStat> {
    let mut stats: Vec<TagStat> = Vec::new();
    for record in records {
        // 同一条记录里同一个码可能重复出现（病态数据）；"带这个码的记录数"只算一次。
        let mut counted: Vec<u8> = Vec::new();
        for (code, value) in &record.tags {
            let slot = match stats.iter().position(|s| s.code == *code) {
                Some(index) => index,
                None => {
                    stats.push(TagStat {
                        code: *code,
                        name: enumerate(*code),
                        field: field(*code),
                        records: 0,
                        samples: Vec::new(),
                        empty_values: 0,
                    });
                    stats.len() - 1
                }
            };
            let stat = &mut stats[slot];
            if !counted.contains(code) {
                stat.records += 1;
                counted.push(*code);
            }
            let trimmed = value.trim();
            if trimmed.is_empty() {
                stat.empty_values += 1;
            } else if stat.samples.len() < 3 && !stat.samples.iter().any(|s| s == trimmed) {
                stat.samples.push(trimmed.to_string());
            }
        }
    }
    stats.sort_by_key(|s| s.code);
    stats
}

/// 表里有、但这份库里一次都没出现的码。用来区分"映射错了"和"这份库没这个标签"。
pub fn absent(records: &[MblRecord]) -> Vec<(u8, &'static str)> {
    TAG_CODES
        .iter()
        .filter(|(code, _, _)| !records.iter().any(|r| r.tags.iter().any(|(c, _)| c == code)))
        .map(|(code, name, _)| (*code, *name))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::musicbee::MblArtwork;

    #[test]
    fn table_is_sorted_and_has_no_duplicate_codes() {
        let codes: Vec<u8> = TAG_CODES.iter().map(|(c, _, _)| *c).collect();
        let mut sorted = codes.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(codes, sorted, "表必须按码升序且没有重复码");
    }

    #[test]
    fn table_has_no_duplicate_names_or_fields() {
        let mut names: Vec<&str> = TAG_CODES.iter().map(|(_, n, _)| *n).collect();
        let len = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), len, "枚举名不许重复");

        let mut fields: Vec<&str> = TAG_CODES.iter().map(|(_, _, f)| *f).collect();
        let len = fields.len();
        fields.sort_unstable();
        fields.dedup();
        assert_eq!(fields.len(), len, "规范化字段名不许重复");
    }

    #[test]
    fn the_five_fields_a_player_cannot_do_without_are_where_we_think() {
        assert_eq!(code_for("track_title"), Some(65));
        assert_eq!(code_for("album"), Some(30));
        assert_eq!(code_for("artist"), Some(32));
        assert_eq!(code_for("album_artist"), Some(31));
        assert_eq!(code_for("year"), Some(88));
        assert_eq!(enumerate(65), Some("TrackTitle"));
        assert_eq!(field(88), Some("year"));
    }

    #[test]
    fn lookup_accepts_both_enum_name_and_snake_name() {
        assert_eq!(code_for("TrackTitle"), Some(65));
        assert_eq!(code_for("track_title"), Some(65));
        assert_eq!(code_for("nope"), None, "查不到就是 None，不猜最像的");
    }

    fn record(tags: &[(u8, &str)]) -> MblRecord {
        MblRecord {
            designation: 2,
            status: 0,
            play_count: 0,
            skip_count: 0,
            last_played_ms: None,
            added_ms: None,
            modified_ms: None,
            path: "F:\\Music\\a.flac".to_string(),
            file_size: 1,
            sample_rate: 44_100,
            channel_mode: 1,
            bitrate_type: 0,
            bitrate_raw: 320,
            track_length_raw: 200,
            artwork: Vec::<MblArtwork>::new(),
            tags_type: 0,
            tags: tags.iter().map(|(c, v)| (*c, v.to_string())).collect(),
            cue: Vec::new(),
        }
    }

    #[test]
    fn census_counts_records_not_values_and_keeps_three_samples() {
        let records = vec![
            record(&[(65, "一"), (65, "一")]),
            record(&[(65, "二")]),
            record(&[(65, "三")]),
            record(&[(65, "四")]),
        ];
        let stats = census(&records);
        let title = stats.iter().find(|s| s.code == 65).expect("必须统计到 65");
        assert_eq!(title.records, 4, "四条记录都带 65");
        assert_eq!(title.samples, vec!["一", "二", "三"], "样例最多三个，且去重");
        assert_eq!(title.name, Some("TrackTitle"));
    }

    #[test]
    fn unknown_codes_are_listed_without_a_name() {
        let records = vec![record(&[(200, "怪东西")])];
        let stats = census(&records);
        assert_eq!(stats.len(), 1);
        assert_eq!(stats[0].code, 200);
        assert_eq!(stats[0].name, None);
        assert!(stats[0].line().contains("unknown(code=200)"), "{}", stats[0].line());
    }

    #[test]
    fn empty_values_count_as_records_but_not_as_samples() {
        let records = vec![record(&[(65, "  "), (65, "有值")])];
        let stats = census(&records);
        assert_eq!(stats[0].records, 1);
        assert_eq!(stats[0].empty_values, 1);
        assert_eq!(stats[0].samples, vec!["有值"]);
    }

    #[test]
    fn absent_lists_table_codes_this_library_never_used() {
        let records = vec![record(&[(65, "一")])];
        let missing = absent(&records);
        assert!(!missing.iter().any(|(c, _)| *c == 65));
        assert!(missing.iter().any(|(c, _)| *c == 88));
        assert_eq!(missing.len(), TAG_CODES.len() - 1);
    }
}
