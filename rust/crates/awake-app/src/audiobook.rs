//! 听书书架与进度。

use crate::{experience, AppState};
use awake_core::{books, taste::BookState};
use tauri::State;

#[tauri::command]
pub fn audiobook_shelf(
    include_all: Option<bool>,
    state: State<'_, AppState>,
) -> Vec<books::Book> {
    let snapshot = state.library.lock().snapshot.clone();
    let states = state.taste.lock().books.clone();
    books::shelf(
        &snapshot.tracks,
        &states,
        &snapshot.sources,
        include_all.unwrap_or(false),
    )
}

#[tauri::command]
pub fn audiobook_progress(
    book_id: String,
    track_id: String,
    position: f64,
    finished: bool,
    state: State<'_, AppState>,
) -> Result<(), String> {
    if !position.is_finite() || position < 0.0 || position > 864_000.0 {
        return Err("听书进度无效".into());
    }
    if book_id.trim().is_empty() || book_id.len() > 200 {
        return Err("书目标识无效".into());
    }
    experience::mutate_profile(&state.taste, &state.data_dir, |taste| {
        taste.books.insert(
            book_id,
            BookState {
                track_id: Some(track_id),
                position,
                finished,
                updated_at: awake_core::models::now_ms(),
            },
        );
        Ok(())
    })
}

#[tauri::command]
pub fn audiobook_forget(book_id: String, state: State<'_, AppState>) -> Result<(), String> {
    experience::mutate_profile(&state.taste, &state.data_dir, |taste| {
        taste.books.remove(&book_id);
        Ok(())
    })
}
