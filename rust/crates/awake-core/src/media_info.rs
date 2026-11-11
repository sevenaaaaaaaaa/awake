//! User-confirmed presentation metadata, independent of file paths and source identity.
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Review {
    pub author: String,
    pub text: String,
    pub source: String,
    pub url: String,
    pub scope: String,
    pub license: String,
    pub license_url: String,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct MediaInfo {
    pub original_title: String,
    pub original_artist: String,
    pub original_album_artist: String,
    pub original_album: String,
    pub original_artwork: Option<String>,
    pub original_comment: String,
    pub original_lyrics: String,
    pub source_note: String,
    pub suggested_filename: String,
    pub cover_style: String,
    pub credits: Vec<String>,
    pub reviews: Vec<Review>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NameSuggestion {
    pub title: String,
    pub artist: String,
    pub filename: String,
}
pub fn suggest_name(filename: &str, title: &str, artist: &str) -> NameSuggestion {
    let leaf = filename.rsplit(['/', '\\']).next().unwrap_or(filename);
    let (stem, ext) = leaf.rsplit_once('.').unwrap_or((leaf, ""));
    let raw = if title.trim().is_empty() || title == stem {
        stem
    } else {
        title
    };
    let mut clean = raw.replace('_', " ");
    for marker in [
        "[FLAC]",
        "[MP3]",
        "[WAV]",
        "[无损]",
        "【无损】",
        "[320kbps]",
        "[24bit]",
        "[16bit]",
        "[Hi-Res]",
    ] {
        clean = clean.replace(marker, "");
    }
    let bracket = regex::Regex::new(r"[\[【]([^\]】]{1,80})[\]】]").unwrap();
    let quality = regex::Regex::new(
        r"(?i)(flac|mp3|alac|hi-res|无损|高品质|\d+(?:\.\d+)?\s*(?:kbps|khz|bit))",
    )
    .unwrap();
    let version = regex::Regex::new(r"(?i)(live|remix|acoustic|现场)").unwrap();
    clean = bracket
        .replace_all(&clean, |captures: &regex::Captures<'_>| {
            if quality.is_match(&captures[1]) && !version.is_match(&captures[1]) {
                "".to_string()
            } else {
                captures[0].to_string()
            }
        })
        .into_owned();
    clean = clean.split_whitespace().collect::<Vec<_>>().join(" ");
    let prefix = clean.chars().take_while(|c| c.is_ascii_digit()).count();
    if (1..=3).contains(&prefix) {
        let rest = &clean[prefix..];
        if rest.starts_with(". ") || rest.starts_with(" - ") {
            clean = rest.trim_start_matches(['.', ' ', '-']).into();
        }
    }
    let mut performer = artist.trim().to_string();
    if performer.is_empty() || performer == "未知艺人" {
        if let Some((a, b)) = clean.split_once(" - ") {
            if !a.trim().is_empty() && !b.trim().is_empty() {
                performer = a.trim().into();
                clean = b.trim().into();
            }
        }
    }
    if clean.trim().is_empty() {
        clean = "未命名音频".into();
    }
    let combined = if performer.is_empty() || performer == "未知艺人" {
        clean.clone()
    } else {
        format!("{performer} - {clean}")
    };
    let safe: String = combined
        .chars()
        .take(120)
        .map(|c| {
            if c.is_control() || "<>:\"/\\|?*".contains(c) {
                '_'
            } else {
                c
            }
        })
        .collect();
    let safe = safe.trim_matches(['.', ' ']);
    let filename =
        if ext.is_empty() || ext.len() > 8 || !ext.chars().all(|c| c.is_ascii_alphanumeric()) {
            safe.into()
        } else {
            format!("{safe}.{}", ext.to_lowercase())
        };
    NameSuggestion {
        title: clean,
        artist: performer,
        filename,
    }
}

pub fn validate(
    title: &str,
    artist: &str,
    album: &str,
    comment: &str,
    lyrics: &str,
    info: &MediaInfo,
) -> Result<(), String> {
    if title.trim().is_empty()
        || title.len() > 1000
        || artist.len() > 1000
        || album.len() > 1000
        || comment.len() > 16000
        || lyrics.len() > 131072
        || info.source_note.len() > 4000
        || info.suggested_filename.len() > 1000
    {
        return Err("资料字段为空或超过支持长度".into());
    }
    if !["auto", "original", "nocturne", "forest", "amber", "rose"]
        .contains(&info.cover_style.as_str())
        || info.reviews.len() > 50
        || info.credits.len() > 30
    {
        return Err("封面风格或评论数量无效".into());
    }
    for r in &info.reviews {
        if r.text.len() > 20000
            || r.author.len() > 1000
            || r.url.len() > 2000
            || r.source.len() > 1000
            || !["recording", "release_group", "imported"].contains(&r.scope.as_str())
        {
            return Err("评论格式或适用对象无效".into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn filename_cleanup_keeps_version_and_never_changes_locator() {
        let s = suggest_name("01. 王菲 - 红豆 (Live) [FLAC].flac", "", "");
        assert_eq!(s.title, "红豆 (Live)");
        assert_eq!(s.artist, "王菲");
        assert_eq!(s.filename, "王菲 - 红豆 (Live).flac");
        assert_eq!(
            suggest_name("Artist - Night [FLAC 24bit 96kHz].flac", "", "").title,
            "Night"
        );
        assert_eq!(
            suggest_name("Artist - Night [Live FLAC].flac", "", "").title,
            "Night [Live FLAC]"
        );
        let r = suggest_name("录音_2026_11_11.wav", "", "");
        assert_eq!(r.artist, "");
        assert_eq!(r.title, "录音 2026 11 11");
    }
}
