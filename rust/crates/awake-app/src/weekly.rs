//! 本周总结：只读取本地收听记录，不做云端推断。

use crate::AppState;
use awake_core::{taste::Taste, Track};
use serde::Serialize;
use std::collections::HashMap;
use tauri::State;

#[derive(Serialize)]
pub struct WeeklyTrack {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub seconds: f64,
    pub plays: usize,
}

#[derive(Serialize)]
pub struct WeeklyArtist {
    pub artist: String,
    pub seconds: f64,
    pub plays: usize,
}

#[derive(Serialize)]
pub struct WeeklyDay {
    pub index: usize,
    pub seconds: f64,
}

#[derive(Serialize)]
pub struct WeeklySummary {
    pub since: i64,
    pub until: i64,
    pub seconds: f64,
    pub plays: usize,
    pub completed: usize,
    pub skipped: usize,
    pub track_count: usize,
    pub artist_count: usize,
    pub new_tracks: usize,
    pub favorites: usize,
    pub books: usize,
    pub top_tracks: Vec<WeeklyTrack>,
    pub top_artists: Vec<WeeklyArtist>,
    pub days: Vec<WeeklyDay>,
    pub lines: Vec<String>,
}

fn qualified(event: &awake_core::taste::ListenEvent, track: &Track) -> bool {
    Taste::qualified(event, track)
}

pub fn summarize(
    tracks: &[Track],
    taste: &Taste,
    since: i64,
    until: i64,
) -> WeeklySummary {
    let by_id: HashMap<&str, &Track> = tracks.iter().map(|t| (t.id.as_str(), t)).collect();
    let mut seconds = 0.0;
    let mut plays = 0;
    let mut completed = 0;
    let mut skipped = 0;
    let mut per_track: HashMap<&str, (usize, f64)> = HashMap::new();
    let mut per_artist: HashMap<&str, (usize, f64)> = HashMap::new();
    let mut days = vec![0.0_f64; 7];
    for event in taste.events.iter().filter(|e| e.at >= since && e.at < until) {
        let Some(track) = by_id.get(event.track_id.as_str()) else {
            continue;
        };
        seconds += event.seconds;
        if qualified(event, track) {
            plays += 1;
        }
        if event.completed {
            completed += 1;
        }
        if event.skipped && event.seconds < 30.0 {
            skipped += 1;
        }
        let entry = per_track.entry(track.id.as_str()).or_insert((0, 0.0));
        entry.0 += 1;
        entry.1 += event.seconds;
        if !track.artist.is_empty() {
            let artist = per_artist.entry(track.artist.as_str()).or_insert((0, 0.0));
            artist.0 += 1;
            artist.1 += event.seconds;
        }
        let index = ((event.at - since) / 86_400_000).clamp(0, 6) as usize;
        days[index] += event.seconds;
    }
    let track_count = per_track.len();
    let mut top: Vec<WeeklyTrack> = per_track
        .into_iter()
        .filter_map(|(id, (plays, seconds))| {
            let track = by_id.get(id)?;
            Some(WeeklyTrack {
                id: (*id).to_string(),
                title: track.title.clone(),
                artist: track.artist.clone(),
                seconds,
                plays,
            })
        })
        .collect();
    top.sort_by(|a, b| b.plays.cmp(&a.plays).then_with(|| b.seconds.total_cmp(&a.seconds)));
    top.truncate(5);

    let mut artists: Vec<WeeklyArtist> = per_artist
        .into_iter()
        .map(|(artist, (plays, seconds))| WeeklyArtist {
            artist: artist.to_string(),
            seconds,
            plays,
        })
        .collect();
    artists.sort_by(|a, b| b.seconds.total_cmp(&a.seconds));
    artists.truncate(5);

    let new_tracks = tracks
        .iter()
        .filter(|t| t.added_at >= since && t.added_at < until)
        .count();
    let books = taste
        .books
        .values()
        .filter(|state| state.updated_at >= since && state.updated_at < until && !state.finished)
        .count()
        + taste
            .books
            .values()
            .filter(|state| state.updated_at >= since && state.finished)
            .count();

    let minutes = (seconds / 60.0).round() as i64;
    let mut lines = Vec::new();
    if plays == 0 && seconds < 60.0 {
        lines.push("这周还没有完整的聆听记录。放一首喜欢的歌，下周的总结会从这里开始。".into());
    } else {
        lines.push(format!("这周你听了 {minutes} 分钟，完整听完 {plays} 首。"));
        if let Some(first) = top.first() {
            lines.push(format!(
                "最常播放的是《{}》，来自 {}。",
                first.title, first.artist
            ));
        }
        if let Some(artist) = artists.first() {
            lines.push(format!("{} 陪你最久，共 {} 分钟。", artist.artist, (artist.seconds / 60.0).round() as i64));
        }
        if completed > 0 {
            lines.push(format!("有 {completed} 次播放自然播完，说明它们经得起完整聆听。"));
        }
        if skipped > 0 {
            lines.push(format!("主动跳过 {skipped} 次；下一次会少推这类曲目。"));
        }
        if books > 0 {
            lines.push(format!("还有 {books} 本书在进行中，记得回来接着听。"));
        }
        if new_tracks > 0 {
            lines.push(format!("曲库新增 {new_tracks} 首，等你慢慢发现。"));
        }
    }
    WeeklySummary {
        since,
        until,
        seconds,
        plays,
        completed,
        skipped,
        track_count,
        artist_count: artists.len(),
        new_tracks,
        favorites: taste.favorites.len(),
        books,
        top_tracks: top,
        top_artists: artists,
        days: days
            .into_iter()
            .enumerate()
            .map(|(index, seconds)| WeeklyDay { index, seconds })
            .collect(),
        lines,
    }
}

#[tauri::command]
pub fn weekly_summary(
    since: i64,
    until: i64,
    state: State<'_, AppState>,
) -> Result<WeeklySummary, String> {
    if since <= 0 || until <= since || until - since > 40 * 86_400_000 {
        return Err("总结时间范围无效".into());
    }
    let tracks = state.library.lock().snapshot.tracks.clone();
    let taste = state.taste.lock().clone();
    Ok(summarize(&tracks, &taste, since, until))
}

#[cfg(test)]
mod tests {
    use super::*;
    use awake_core::taste::{ListenEvent, Taste};
    use serde_json::json;

    fn track(id: &str, artist: &str) -> Track {
        serde_json::from_value(json!({
            "id": id, "title": id, "artist": artist, "album_artist": artist,
            "album": "album", "genre": "", "year": null, "track_number": null,
            "disc_number": null, "duration": 200.0, "sample_rate": 44100,
            "bit_depth": 16, "channels": 2, "codec": "flac", "source_id": "s",
            "locator": id, "file_size": 1, "modified": 0, "artwork_path": null,
            "play_count": 0, "favorite": false, "last_played": null,
            "added_at": 0, "is_remote": false
        }))
        .unwrap()
    }

    #[test]
    fn aggregates_only_the_requested_window() {
        let tracks = vec![track("a", "A"), track("b", "B")];
        let mut taste = Taste::default();
        for (id, at, seconds, completed) in [("a", 1000, 150.0, true), ("b", 500, 150.0, false)] {
            taste.events.push(ListenEvent {
                track_id: id.into(),
                seconds,
                completed,
                skipped: false,
                at,
            });
        }
        let summary = summarize(&tracks, &taste, 1000, 2000);
        assert_eq!(summary.plays, 1);
        assert_eq!(summary.seconds, 150.0);
        assert_eq!(summary.top_tracks[0].id, "a");
        assert!(!summary.lines.is_empty());
    }
}
