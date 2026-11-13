//! 听书：把长音频按书归并、按章节自然排序，并读出上次听到哪里。
//!
//! 完全本地推断：标签 / 文件名 / 时长 / 有声书扩展名。不会上传任何内容。

use crate::models::Track;
use crate::taste::BookState;
use serde::Serialize;
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize)]
pub struct Book {
    pub id: String,
    pub title: String,
    pub author: String,
    pub artwork_path: Option<String>,
    pub chapters: Vec<Track>,
    pub total_seconds: f64,
    pub listened_seconds: f64,
    pub current_track: Option<String>,
    pub position: f64,
    pub finished: bool,
    pub updated_at: i64,
    pub source_id: String,
}

const BOOK_MARKERS: [&str; 14] = [
    "有声",
    "听书",
    "广播剧",
    "评书",
    "小说",
    "朗读",
    "演播",
    "audible",
    "audiobook",
    "audio book",
    "novel",
    "chapter",
    "全集",
    "连载",
];

const AUDIOBOOK_EXTS: [&str; 3] = ["m4b", "aa", "aax"];

fn marker(text: &str) -> bool {
    let lower = text.to_lowercase();
    BOOK_MARKERS.iter().any(|m| lower.contains(m))
}

fn extension(track: &Track) -> String {
    track
        .locator
        .rsplit_once('.')
        .map(|(_, ext)| ext.to_lowercase())
        .unwrap_or_default()
}

fn avg_duration(tracks: &[Track]) -> f64 {
    if tracks.is_empty() {
        return 0.0;
    }
    tracks.iter().map(|t| t.duration).sum::<f64>() / tracks.len() as f64
}

/// 是否像一本有声书（而不是普通音乐专辑）。
pub fn looks_like_book(tracks: &[Track]) -> bool {
    if tracks.is_empty() {
        return false;
    }
    let album = &tracks[0].album;
    if AUDIOBOOK_EXTS.contains(&extension(&tracks[0]).as_str()) {
        return true;
    }
    if tracks.iter().any(|t| marker(&t.title)) || marker(album) {
        return true;
    }
    let avg = avg_duration(tracks);
    if avg >= 480.0 {
        return true;
    }
    tracks.len() >= 3 && avg >= 300.0
}

/// 自然排序：数字按数值比较（第2章 < 第10章）。
pub fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let mut ai = a.char_indices().peekable();
    let mut bi = b.char_indices().peekable();
    loop {
        match (ai.peek(), bi.peek()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, Some(_)) => return std::cmp::Ordering::Less,
            (Some(_), None) => return std::cmp::Ordering::Greater,
            (Some(&(_, ac)), Some(&(_, bc))) => {
                if ac.is_ascii_digit() && bc.is_ascii_digit() {
                    let a_start = ai.peek().unwrap().0;
                    let b_start = bi.peek().unwrap().0;
                    let mut a_end = a_start;
                    let mut b_end = b_start;
                    while let Some(&(i, c)) = ai.peek() {
                        if c.is_ascii_digit() {
                            a_end = i + c.len_utf8();
                            ai.next();
                        } else {
                            break;
                        }
                    }
                    while let Some(&(i, c)) = bi.peek() {
                        if c.is_ascii_digit() {
                            b_end = i + c.len_utf8();
                            bi.next();
                        } else {
                            break;
                        }
                    }
                    let a_num: u128 = a[a_start..a_end].parse().unwrap_or(0);
                    let b_num: u128 = b[b_start..b_end].parse().unwrap_or(0);
                    if a_num != b_num {
                        return a_num.cmp(&b_num);
                    }
                } else {
                    if ac != bc {
                        return ac.to_lowercase().to_string().cmp(&bc.to_lowercase().to_string());
                    }
                    ai.next();
                    bi.next();
                }
            }
        }
    }
}

/// 没有专辑标签时，用同目录名作为一本书；生成的有声书目录带任务 UUID 前缀，需要去掉。
fn folder_title(locator: &str) -> Option<String> {
    let parent = std::path::Path::new(locator).parent()?;
    let name = parent.file_name()?.to_string_lossy().to_string();
    if name.trim().is_empty() {
        return None;
    }
    Some(strip_uuid_prefix(&name))
}

fn strip_uuid_prefix(name: &str) -> String {
    let bytes = name.as_bytes();
    if bytes.len() > 37 && bytes[36] == b'-' {
        let groups = [8, 4, 4, 4, 12];
        let mut offset = 0;
        let mut valid = true;
        for (index, size) in groups.iter().enumerate() {
            for _ in 0..*size {
                if offset >= 36 || !bytes[offset].is_ascii_hexdigit() {
                    valid = false;
                    break;
                }
                offset += 1;
            }
            if !valid {
                break;
            }
            if index < 4 {
                if offset >= 36 || bytes[offset] != b'-' {
                    valid = false;
                    break;
                }
                offset += 1;
            }
        }
        if valid && offset == 36 {
            return name[37..].replace('-', " ");
        }
    }
    name.to_string()
}

fn chapter_order(a: &Track, b: &Track) -> std::cmp::Ordering {
    let da = a.disc_number.unwrap_or(1);
    let db = b.disc_number.unwrap_or(1);
    if da != db {
        return da.cmp(&db);
    }
    match (a.track_number, b.track_number) {
        (Some(ta), Some(tb)) if ta != tb => return ta.cmp(&tb),
        (Some(_), None) => return std::cmp::Ordering::Less,
        (None, Some(_)) => return std::cmp::Ordering::Greater,
        _ => {}
    }
    let an = a.title.trim();
    let bn = b.title.trim();
    natural_cmp(an, bn).then_with(|| natural_cmp(&a.locator, &b.locator))
}

/// 按书归并曲库，返回听书书架。include_all 为真时也包含不像有声书的专辑。
pub fn shelf(tracks: &[Track], states: &HashMap<String, BookState>, include_all: bool) -> Vec<Book> {
    let mut groups: HashMap<String, Vec<Track>> = HashMap::new();
    let mut titles: HashMap<String, String> = HashMap::new();
    for track in tracks {
        let (key, title) = if !track.album.trim().is_empty() {
            (track.album_key(), track.album.clone())
        } else if !track.is_remote {
            match folder_title(&track.locator) {
                Some(folder) => (
                    format!("dir:{}:{}", track.source_id, folder),
                    folder,
                ),
                None if track.duration >= 900.0 => (track.id.clone(), track.title.clone()),
                None => continue,
            }
        } else if track.duration >= 900.0 {
            (track.id.clone(), track.title.clone())
        } else {
            continue;
        };
        titles.entry(key.clone()).or_insert(title);
        groups.entry(key).or_default().push(track.clone());
    }

    let mut books: Vec<Book> = groups
        .into_iter()
        .filter_map(|(id, mut chapters)| {
            let folder = titles.get(&id).cloned().unwrap_or_default();
            // 目录名像有声书，或者是应用自己生成的有声书 / 广播剧，即使单章很短也认。
            let is_book = looks_like_book(&chapters)
                || marker(&folder)
                || chapters
                    .first()
                    .is_some_and(|t| t.source_id.starts_with("book-"));
            if !is_book && !include_all {
                return None;
            }
            chapters.sort_by(chapter_order);
            let total: f64 = chapters.iter().map(|t| t.duration).sum();
            let first = chapters[0].clone();
            let state = states.get(&id);
            let (listened, position, finished, updated_at, current_track) = match state {
                Some(state) => {
                    let index = state
                        .track_id
                        .as_ref()
                        .and_then(|id| chapters.iter().position(|t| &t.id == id))
                        .unwrap_or(0);
                    let before: f64 = chapters.iter().take(index).map(|t| t.duration).sum();
                    (
                        before + state.position.max(0.0),
                        state.position,
                        state.finished,
                        state.updated_at,
                        state.track_id.clone(),
                    )
                }
                None => (0.0, 0.0, false, 0, None),
            };
            let title = if first.album.trim().is_empty() {
                folder.clone()
            } else {
                first.album.clone()
            };
            Some(Book {
                id,
                title,
                author: first.album_artist.trim().to_string(),
                artwork_path: chapters.iter().find_map(|t| t.artwork_path.clone()),
                total_seconds: total,
                listened_seconds: listened.min(total.max(0.0)),
                current_track: current_track.or_else(|| chapters.first().map(|t| t.id.clone())),
                position,
                finished: finished && total > 0.0,
                updated_at,
                source_id: first.source_id.clone(),
                chapters,
            })
        })
        .collect();

    books.sort_by(|a, b| {
        let rank = |book: &Book| {
            if book.finished {
                2
            } else if book.updated_at > 0 || book.listened_seconds > 0.0 {
                0
            } else {
                1
            }
        };
        rank(a)
            .cmp(&rank(b))
            .then_with(|| b.updated_at.cmp(&a.updated_at))
            .then_with(|| natural_cmp(&a.title, &b.title))
    });
    books
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(id: &str, album: &str, title: &str, seconds: f64) -> Track {
        serde_json::from_value(serde_json::json!({
            "id": id, "title": title, "artist": "演播者", "album_artist": "作者",
            "album": album, "genre": "", "year": null, "track_number": null,
            "disc_number": null, "duration": seconds, "sample_rate": 44100,
            "bit_depth": 16, "channels": 2, "codec": "m4a", "source_id": "s",
            "locator": format!("{title}.m4a"), "file_size": 1, "modified": 0,
            "artwork_path": null, "play_count": 0, "favorite": false,
            "last_played": null, "added_at": 0, "is_remote": false
        }))
        .unwrap()
    }

    #[test]
    fn sorts_chapters_naturally_and_resumes() {
        let a = track("a", "三体", "第2章 迷", 1200.0);
        let b = track("b", "三体", "第10章 尾声", 900.0);
        let c = track("c", "三体", "第1章 序", 600.0);
        let tracks = vec![a, b, c];
        let mut states = HashMap::new();
        states.insert(
            "作者|三体".to_string(),
            BookState {
                track_id: Some("a".into()),
                position: 300.0,
                finished: false,
                updated_at: 99,
            },
        );
        let books = shelf(&tracks, &states, false);
        assert_eq!(books.len(), 1);
        let book = &books[0];
        assert_eq!(book.title, "三体");
        let order: Vec<_> = book.chapters.iter().map(|t| t.title.as_str()).collect();
        assert_eq!(order, vec!["第1章 序", "第2章 迷", "第10章 尾声"]);
        assert_eq!(book.listened_seconds, 600.0 + 300.0);
        assert_eq!(book.current_track.as_deref(), Some("a"));
    }

    #[test]
    fn groups_untagged_chapters_by_folder_and_strips_uuid() {
        let mut first = track("a", "", "001-第一章", 5.0);
        first.locator = "27df07d4-8971-4eca-be37-aac39599827b-测试书/001-第一章.m4a".into();
        first.source_id = "book-27df07d4".into();
        let mut second = track("b", "", "002-第二章", 4.0);
        second.locator = "27df07d4-8971-4eca-be37-aac39599827b-测试书/002-第二章.m4a".into();
        second.source_id = "book-27df07d4".into();
        let books = shelf(&[second, first], &HashMap::new(), false);
        assert_eq!(books.len(), 1);
        assert_eq!(books[0].title, "测试书");
        assert_eq!(books[0].chapters.len(), 2);
        assert_eq!(strip_uuid_prefix("abc-普通目录"), "abc-普通目录");
    }

    #[test]
    fn excludes_short_music_but_keeps_long_form() {
        let music: Vec<_> = (0..5)
            .map(|i| track(&format!("m{i}"), "专辑", "歌", 240.0))
            .collect();
        assert!(!looks_like_book(&music));
        let long = vec![track("l", "长音频", "上", 3600.0)];
        assert!(looks_like_book(&long));
        let mut m4b = vec![track("b", "书", "整本", 60.0)];
        m4b[0].locator = "book.m4b".into();
        assert!(looks_like_book(&m4b));
        assert!(shelf(&music, &HashMap::new(), false).is_empty());
        assert_eq!(shelf(&music, &HashMap::new(), true).len(), 1);
    }
}
