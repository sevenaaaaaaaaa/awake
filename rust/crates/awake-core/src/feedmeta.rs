//! RSS/Atom metadata can select existing playable library items, never create audio sources.
use crate::Track;
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Subscription {
    pub id: String,
    pub name: String,
    pub url: String,
    pub username: String,
    pub source_ids: Vec<String>,
    pub playlist_id: String,
    pub attempted_at: i64,
    pub refreshed_at: Option<i64>,
    pub matched: usize,
    pub total: usize,
    pub error: Option<String>,
}
fn normalized(value: &str) -> String {
    value
        .chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}
pub fn match_entries(entries: &[String], tracks: &[Track], sources: &[String]) -> Vec<String> {
    let prepared: Vec<_> = tracks
        .iter()
        .filter(|t| sources.is_empty() || sources.contains(&t.source_id))
        .map(|t| (t, normalized(&t.title), normalized(&t.artist)))
        .collect();
    let mut ids = Vec::new();
    let mut used = std::collections::HashSet::new();
    for entry in entries {
        let text = normalized(entry);
        let candidates: Vec<_> = prepared
            .iter()
            .filter(|(_, title, artist)| {
                title.chars().count() >= 2
                    && (text == *title
                        || !artist.is_empty()
                            && text.contains(title.as_str())
                            && text.contains(artist.as_str()))
            })
            .take(2)
            .map(|(track, _, _)| *track)
            .collect();
        if candidates.len() == 1 && used.insert(candidates[0].id.clone()) {
            ids.push(candidates[0].id.clone());
        }
    }
    ids
}
