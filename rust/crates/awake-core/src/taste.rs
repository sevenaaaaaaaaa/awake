//! Explainable, local-first ranking. No model or network is implied by these scores.
use crate::Track;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListenEvent {
    pub track_id: String,
    pub seconds: f64,
    pub completed: bool,
    pub skipped: bool,
    pub at: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Taste {
    #[serde(default)]
    pub device_migrations: HashSet<String>,
    #[serde(default)]
    pub listening_chains: Vec<crate::chain::ListeningChain>,
    #[serde(default)]
    pub active_chains: HashMap<String, String>,
    pub events: Vec<ListenEvent>,
    pub favorites: HashSet<String>,
    pub playlists: Vec<Playlist>,
    pub sound_profiles: HashMap<String, Vec<f32>>,
    pub briefs: Vec<CreationBrief>,
    #[serde(default)]
    pub headphone_profiles: Vec<crate::parametric::Profile>,
    #[serde(default)]
    pub active_corrections: HashMap<String, String>,
    #[serde(default)]
    pub generations: Vec<Generation>,
    #[serde(default)]
    pub feeds: Vec<crate::feedmeta::Subscription>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Generation {
    pub id: String,
    pub prompt: String,
    pub state: String,
    pub model: String,
    pub provider: String,
    pub created_at: i64,
    pub track_id: Option<String>,
    pub file_path: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreationBrief {
    pub id: String,
    pub prompt: String,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Playlist {
    pub id: String,
    pub name: String,
    pub prompt: String,
    pub source_ids: Vec<String>,
    pub track_ids: Vec<String>,
    /// Smart lists are re-resolved against the current library on every read.
    pub smart: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct Recommendation {
    pub track: Track,
    pub reason: String,
    pub score: f64,
}

impl Taste {
    pub fn record(&mut self, event: ListenEvent) -> Result<(), &'static str> {
        if !event.seconds.is_finite() || event.seconds < 0.0 || event.seconds > 86400.0 {
            return Err("无效的收听时长");
        }
        self.events.push(event);
        if self.events.len() > 5000 {
            self.events.drain(..self.events.len() - 5000);
        }
        Ok(())
    }

    pub fn qualified(event: &ListenEvent, track: &Track) -> bool {
        let threshold = if track.duration > 0.0 {
            (track.duration * 0.5).min(120.0).max(0.1)
        } else {
            30.0
        };
        event.seconds.is_finite() && event.seconds >= threshold
    }
    pub fn recommend(
        &self,
        tracks: &[Track],
        prompt: &str,
        sources: &[String],
        limit: usize,
    ) -> Vec<Recommendation> {
        let by_id: HashMap<_, _> = tracks.iter().map(|t| (t.id.as_str(), t)).collect();
        let mut artist_scores: HashMap<String, f64> = HashMap::new();
        let mut genre_scores: HashMap<String, f64> = HashMap::new();
        let mut counts: HashMap<&str, usize> = HashMap::new();
        let mut skips: HashMap<&str, f64> = HashMap::new();
        for (i, event) in self.events.iter().enumerate() {
            let Some(t) = by_id.get(event.track_id.as_str()) else {
                continue;
            };
            // Recent explicit skips outweigh an accidental early exit.
            let recency = 1.0 / (1.0 + (self.events.len() - i - 1) as f64 / 60.0);
            let qualified = Self::qualified(event, t);
            if qualified {
                if !t.artist.is_empty() {
                    *artist_scores.entry(t.artist.to_lowercase()).or_default() += recency;
                }
                if !t.genre.is_empty() {
                    *genre_scores.entry(t.genre.to_lowercase()).or_default() += recency;
                }
                *counts.entry(t.id.as_str()).or_default() += 1;
            }
            if event.skipped && event.seconds < 30.0 {
                *skips.entry(t.id.as_str()).or_default() += 4.0 * recency;
            }
        }
        for id in &self.favorites {
            if let Some(t) = by_id.get(id.as_str()) {
                if !t.artist.is_empty() {
                    *artist_scores.entry(t.artist.to_lowercase()).or_default() += 2.0;
                }
                if !t.genre.is_empty() {
                    *genre_scores.entry(t.genre.to_lowercase()).or_default() += 1.0;
                }
            }
        }
        let query = prompt.to_lowercase();
        let tokens: Vec<_> = query
            .split(|c: char| c.is_whitespace() || "，、,。".contains(c))
            .filter(|s| !s.is_empty())
            .collect();
        let discovery =
            query.contains("探索") || query.contains("新鲜") || query.contains("discover");
        let focus = query.contains("专注") || query.contains("focus");
        let mut ranked: Vec<_> = tracks
            .iter()
            .filter(|t| sources.is_empty() || sources.contains(&t.source_id))
            .map(|t| {
                let artist = artist_scores
                    .get(&t.artist.to_lowercase())
                    .copied()
                    .unwrap_or(0.0);
                let genre = genre_scores
                    .get(&t.genre.to_lowercase())
                    .copied()
                    .unwrap_or(0.0);
                let favorite = self.favorites.contains(&t.id) || t.favorite;
                let played = counts.get(t.id.as_str()).copied().unwrap_or(0);
                let haystack =
                    format!("{} {} {} {}", t.title, t.artist, t.album, t.genre).to_lowercase();
                let matches = tokens.iter().filter(|s| haystack.contains(**s)).count();
                let focus_match = focus
                    && [
                        "ambient",
                        "classical",
                        "instrumental",
                        "氛围",
                        "古典",
                        "纯音乐",
                    ]
                    .iter()
                    .any(|g| haystack.contains(g));
                let score = artist * 1.5
                    + genre
                    + if favorite { 3.0 } else { 0.0 }
                    + matches as f64 * 5.0
                    + if focus_match { 4.0 } else { 0.0 }
                    + if discovery && played == 0 { 4.0 } else { 0.0 }
                    - played as f64 * 0.35
                    - skips.get(t.id.as_str()).copied().unwrap_or(0.0);
                let reason = if matches > 0 {
                    "匹配你的描述"
                } else if focus_match {
                    "曲库标签适合专注"
                } else if discovery && played == 0 {
                    "还没完整听过，换一点新鲜感"
                } else if favorite {
                    "你收藏过这首歌"
                } else if artist > 0.0 {
                    "你最近常听这位艺人"
                } else if genre > 0.0 {
                    "接近你喜欢的音乐风格"
                } else {
                    "先从你的曲库认识你"
                };
                Recommendation {
                    track: t.clone(),
                    score,
                    reason: reason.into(),
                }
            })
            .collect();
        ranked.sort_by(|a, b| {
            b.score
                .total_cmp(&a.score)
                .then_with(|| a.track.id.cmp(&b.track.id))
        });
        // Interleave albums without excluding smaller libraries or breaking requested length.
        let mut out = Vec::new();
        while !ranked.is_empty() && out.len() < limit.min(100) {
            let previous = out.last().map(|r: &Recommendation| r.track.album_key());
            let index = ranked
                .iter()
                .position(|r| Some(r.track.album_key()) != previous)
                .unwrap_or(0);
            out.push(ranked.remove(index));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn track(id: &str, artist: &str, source: &str) -> Track {
        serde_json::from_value(serde_json::json!({
            "id":id,"title":id,"artist":artist,"album_artist":artist,"album":id,
            "genre":"ambient","year":null,"track_number":null,"disc_number":null,
            "duration":180.0,"sample_rate":48000,"bit_depth":24,"channels":2,"codec":"flac",
            "source_id":source,"locator":id,"file_size":1,"modified":0,"artwork_path":null,
            "play_count":0,"favorite":false,"last_played":null,"added_at":0,"is_remote":false
        }))
        .unwrap()
    }
    #[test]
    fn learns_artist_from_qualified_listen_and_respects_source() {
        let tracks = vec![
            track("a", "A", "one"),
            track("b", "B", "two"),
            track("c", "A", "two"),
        ];
        let mut taste = Taste::default();
        taste
            .record(ListenEvent {
                track_id: "a".into(),
                seconds: 150.0,
                completed: false,
                skipped: false,
                at: 0,
            })
            .unwrap();
        let results = taste.recommend(&tracks, "", &["two".into()], 20);
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].track.id, "c");
        assert_eq!(results[0].reason, "你最近常听这位艺人");
    }
    #[test]
    fn skip_lowers_rank_and_history_round_trips() {
        let mut taste = Taste::default();
        taste
            .record(ListenEvent {
                track_id: "a".into(),
                seconds: 2.0,
                completed: false,
                skipped: true,
                at: 0,
            })
            .unwrap();
        let taste: Taste = serde_json::from_str(&serde_json::to_string(&taste).unwrap()).unwrap();
        assert_eq!(
            taste.recommend(&[track("a", "A", "s"), track("b", "B", "s")], "", &[], 10)[0]
                .track
                .id,
            "b"
        );
    }
    #[test]
    fn rejects_bad_events_and_handles_empty_library() {
        let mut taste = Taste::default();
        assert!(taste
            .record(ListenEvent {
                track_id: "a".into(),
                seconds: f64::NAN,
                completed: false,
                skipped: false,
                at: 0
            })
            .is_err());
        assert!(taste.recommend(&[], "", &[], 10).is_empty());
    }
    #[test]
    fn seeking_to_eof_does_not_count_as_a_qualified_listen() {
        let track = track("a", "Artist", "one");
        let event = ListenEvent {
            track_id: "a".into(),
            seconds: 2.0,
            completed: true,
            skipped: false,
            at: 0,
        };
        assert!(!Taste::qualified(&event, &track));
    }
}
