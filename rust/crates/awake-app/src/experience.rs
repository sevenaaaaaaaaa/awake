use crate::AppState;
use awake_core::{
    eq::EqCurve,
    taste::{CreationBrief, ListenEvent, Playlist, PlaylistEntry, Recommendation, Taste},
};
use serde::Serialize;
use tauri::State;

pub fn load(dir: &std::path::Path) -> Taste {
    let path = dir.join("taste.json");
    match std::fs::read(&path) {
        Ok(bytes) => serde_json::from_slice::<Taste>(&bytes)
            .map(|mut taste| {
                for job in &mut taste.generations {
                    if matches!(job.state.as_str(), "queued" | "running") {
                        job.state = "interrupted".into();
                        job.error = Some("应用已重启，任务中断。不会自动重复提交生成请求。".into());
                    }
                }
                taste
            })
            .unwrap_or_else(|e| {
                // Preserve a corrupt profile for recovery instead of silently overwriting it.
                let _ = std::fs::copy(
                    &path,
                    dir.join(format!(
                        "taste-corrupt-{}.json",
                        awake_core::models::now_ms()
                    )),
                );
                log::error!("听歌档案读取失败：{e}");
                Taste::default()
            }),
        Err(_) => Taste::default(),
    }
}

fn mutate<T>(
    state: &AppState,
    f: impl FnOnce(&mut Taste) -> Result<T, String>,
) -> Result<T, String> {
    mutate_profile(&state.taste, &state.data_dir, f)
}

pub(crate) fn mutate_profile<T>(
    profile: &parking_lot::Mutex<Taste>,
    dir: &std::path::Path,
    f: impl FnOnce(&mut Taste) -> Result<T, String>,
) -> Result<T, String> {
    let mut taste = profile.lock();
    let mut next = taste.clone();
    let result = f(&mut next)?;
    let bytes = serde_json::to_vec_pretty(&next).map_err(|e| e.to_string())?;
    let temp = dir.join("taste.json.tmp");
    std::fs::write(&temp, bytes).map_err(|e| e.to_string())?;
    std::fs::rename(temp, dir.join("taste.json")).map_err(|e| e.to_string())?;
    *taste = next;
    Ok(result)
}

pub fn record_session(
    profile: &parking_lot::Mutex<Taste>,
    dir: &std::path::Path,
    track_id: String,
    seconds: f64,
    completed: bool,
    skipped: bool,
) -> Result<(), String> {
    mutate_profile(profile, dir, |taste| {
        taste
            .record(ListenEvent {
                track_id,
                seconds: seconds.min(86400.0),
                completed,
                skipped,
                at: awake_core::models::now_ms(),
            })
            .map_err(str::to_string)
    })
}

pub fn validated_curve(gains: &[f32]) -> Result<EqCurve, String> {
    if gains.len() != 31 || gains.iter().any(|g| !g.is_finite() || g.abs() > 12.0) {
        return Err("EQ 需要 31 个 -12 到 +12 dB 的有限增益值".into());
    }
    let mut curve = EqCurve::new(gains, 0.0);
    if !curve.is_flat() {
        // Adjacent peaking filters overlap. Measure the cascade rather than assuming max(band) is enough.
        let mut eq = awake_core::Equalizer::new(192000.0, 1);
        eq.apply_curve(&curve);
        let max_response = (0..512)
            .map(|i| eq.response_db(20.0 * 1000_f32.powf(i as f32 / 511.0)))
            .fold(0.0_f32, f32::max);
        curve.preamp = -(max_response + 1.0);
    }
    Ok(curve)
}

pub const FOR_YOU_ID: &str = "awake-for-you";

fn norm(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_lowercase()
}

/// 确保内置的「为你生成」歌单存在；不会覆盖用户改过的同名歌单。
fn ensure_for_you(state: &AppState) {
    if state
        .taste
        .lock()
        .playlists
        .iter()
        .any(|p| p.id == FOR_YOU_ID)
    {
        return;
    }
    let _ = mutate(state, |taste| {
        if taste.playlists.iter().all(|p| p.id != FOR_YOU_ID) {
            taste.playlists.insert(
                0,
                Playlist {
                    id: FOR_YOU_ID.into(),
                    name: "为你生成".into(),
                    prompt: String::new(),
                    source_ids: Vec::new(),
                    track_ids: Vec::new(),
                    smart: true,
                    entries: Vec::new(),
                },
            );
        }
        Ok(())
    });
}

/// 把导入歌单里的条目重新匹配到当前曲库；匹配不到时保留条目信息。
fn resolve_entries(taste: &mut Taste, tracks: &[awake_core::Track]) {
    use std::collections::HashMap;
    let mut exact: HashMap<(String, String), String> = HashMap::new();
    let mut by_title: HashMap<String, Option<String>> = HashMap::new();
    for track in tracks {
        exact.insert((norm(&track.title), norm(&track.artist)), track.id.clone());
        let key = norm(&track.title);
        by_title
            .entry(key)
            .and_modify(|value| *value = None)
            .or_insert_with(|| Some(track.id.clone()));
    }
    let ids: std::collections::HashSet<&str> =
        tracks.iter().map(|t| t.id.as_str()).collect();
    for playlist in &mut taste.playlists {
        for entry in &mut playlist.entries {
            if entry.title.trim().is_empty() && entry.track_id.is_none() {
                continue;
            }
            let current_valid = entry
                .track_id
                .as_deref()
                .is_some_and(|id| ids.contains(id));
            if current_valid {
                continue;
            }
            let found = exact
                .get(&(norm(&entry.title), norm(&entry.artist)))
                .cloned()
                .or_else(|| by_title.get(&norm(&entry.title)).cloned().flatten());
            entry.track_id = found;
        }
        // 旧数据只有 track_ids：补齐条目，让页面能同时展示未匹配曲目。
        if playlist.entries.is_empty() {
            playlist.entries = playlist
                .track_ids
                .iter()
                .map(|id| {
                    let track = tracks.iter().find(|t| &t.id == id);
                    PlaylistEntry {
                        track_id: Some(id.clone()),
                        title: track.map(|t| t.title.clone()).unwrap_or_default(),
                        artist: track.map(|t| t.artist.clone()).unwrap_or_default(),
                        album: track.map(|t| t.album.clone()).unwrap_or_default(),
                    }
                })
                .collect();
        }
    }
}

#[tauri::command]
pub fn get_taste(state: State<'_, AppState>) -> Taste {
    ensure_for_you(&state);
    let tracks = state.library.lock().snapshot.tracks.clone();
    let mut taste = state.taste.lock().clone();
    resolve_entries(&mut taste, &tracks);
    for playlist in &mut taste.playlists {
        if playlist.smart {
            playlist.track_ids = state
                .taste
                .lock()
                .recommend(&tracks, &playlist.prompt, &playlist.source_ids, 30)
                .into_iter()
                .map(|r| r.track.id)
                .collect();
            playlist.entries = playlist
                .track_ids
                .iter()
                .map(|id| {
                    let track = tracks.iter().find(|t| &t.id == id);
                    PlaylistEntry {
                        track_id: Some(id.clone()),
                        title: track.map(|t| t.title.clone()).unwrap_or_default(),
                        artist: track.map(|t| t.artist.clone()).unwrap_or_default(),
                        album: track.map(|t| t.album.clone()).unwrap_or_default(),
                    }
                })
                .collect();
        }
    }
    taste
}

#[tauri::command]
pub fn record_listen(mut event: ListenEvent, state: State<'_, AppState>) -> Result<(), String> {
    let track = state
        .library
        .lock()
        .snapshot
        .tracks
        .iter()
        .find(|t| t.id == event.track_id)
        .cloned()
        .ok_or("找不到曲目")?;
    if track.duration > 0.0 && event.seconds > track.duration + 2.0 {
        return Err("收听时长超过曲目长度".into());
    }
    event.at = awake_core::models::now_ms();
    mutate(&state, |taste| taste.record(event).map_err(str::to_string))
}

#[tauri::command]
pub fn toggle_favorite(track_id: String, state: State<'_, AppState>) -> Result<bool, String> {
    if !state
        .library
        .lock()
        .snapshot
        .tracks
        .iter()
        .any(|t| t.id == track_id)
    {
        return Err("找不到曲目".into());
    }
    mutate(&state, |taste| {
        if taste.favorites.remove(&track_id) {
            Ok(false)
        } else {
            taste.favorites.insert(track_id);
            Ok(true)
        }
    })
}

#[tauri::command]
pub fn recommend(
    prompt: String,
    source_ids: Vec<String>,
    state: State<'_, AppState>,
) -> Vec<Recommendation> {
    let tracks = state.library.lock().snapshot.tracks.clone();
    state
        .taste
        .lock()
        .recommend(&tracks, &prompt, &source_ids, 30)
}

#[tauri::command]
pub fn save_playlist(
    mut playlist: Playlist,
    state: State<'_, AppState>,
) -> Result<Playlist, String> {
    playlist.name = playlist.name.trim().chars().take(80).collect();
    if playlist.name.is_empty() {
        return Err("请给歌单起一个名字".into());
    }
    if playlist.track_ids.len() > 5000 || playlist.entries.len() > 5000 {
        return Err("歌单最多保存 5000 首".into());
    }
    let mut seen = std::collections::HashSet::new();
    playlist.track_ids.retain(|id| seen.insert(id.clone()));
    for entry in &mut playlist.entries {
        entry.title = entry.title.trim().chars().take(200).collect();
        entry.artist = entry.artist.trim().chars().take(200).collect();
        entry.album = entry.album.trim().chars().take(200).collect();
    }
    if playlist.track_ids.is_empty() && playlist.entries.is_empty() {
        return Err("歌单里还没有曲目".into());
    }
    if playlist.id.is_empty() {
        playlist.id = awake_core::models::new_id();
    }
    mutate(&state, |taste| {
        taste.playlists.retain(|p| p.id != playlist.id);
        taste.playlists.push(playlist.clone());
        Ok(playlist)
    })
}

#[tauri::command]
pub fn delete_playlist(id: String, state: State<'_, AppState>) -> Result<(), String> {
    mutate(&state, |taste| {
        taste.playlists.retain(|p| p.id != id);
        taste.feeds.retain(|feed| feed.playlist_id != id);
        Ok(())
    })
}

#[tauri::command]
pub fn save_sound_profile(
    device: String,
    gains: Vec<f32>,
    state: State<'_, AppState>,
) -> Result<(), String> {
    validated_curve(&gains)?;
    mutate(&state, |taste| {
        taste.sound_profiles.insert(device, gains);
        Ok(())
    })
}

#[tauri::command]
pub fn save_creation_brief(
    prompt: String,
    state: State<'_, AppState>,
) -> Result<CreationBrief, String> {
    if prompt.trim().is_empty() {
        return Err("请描述想创作的音乐".into());
    }
    let brief = CreationBrief {
        id: awake_core::models::new_id(),
        prompt,
        created_at: awake_core::models::now_ms(),
    };
    mutate(&state, |taste| {
        taste.briefs.push(brief.clone());
        Ok(brief)
    })
}

#[derive(Serialize)]
pub struct DeviceInfo {
    name: String,
    sample_rate: u32,
    channels: u16,
}

#[tauri::command]
pub fn output_device() -> Result<DeviceInfo, String> {
    use cpal::traits::{DeviceTrait, HostTrait};
    let device = cpal::default_host()
        .default_output_device()
        .ok_or("没有可用的输出设备")?;
    let config = device.default_output_config().map_err(|e| e.to_string())?;
    Ok(DeviceInfo {
        name: device.name().map_err(|e| e.to_string())?,
        sample_rate: config.sample_rate().0,
        channels: config.channels(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn overlapping_filters_have_enough_headroom_and_flat_is_unmodified() {
        assert_eq!(validated_curve(&[0.0; 31]).unwrap().preamp, 0.0);
        let curve = validated_curve(&[3.0; 31]).unwrap();
        assert!(curve.preamp < -4.0);
        assert!(validated_curve(&[f32::NAN; 31]).is_err());
        assert!(validated_curve(&[0.0; 30]).is_err());
    }
    #[test]
    fn imported_entries_remap_to_library_and_keep_pending() {
        let track: awake_core::Track = serde_json::from_value(serde_json::json!({
            "id": "t1", "title": "夜空中最亮的星", "artist": "逃跑计划",
            "album_artist": "逃跑计划", "album": "世界", "genre": "",
            "year": null, "track_number": null, "disc_number": null,
            "duration": 252.0, "sample_rate": 44100, "bit_depth": 16,
            "channels": 2, "codec": "flac", "source_id": "s", "locator": "a.flac",
            "file_size": 1, "modified": 0, "artwork_path": null,
            "play_count": 0, "favorite": false, "last_played": null,
            "added_at": 0, "is_remote": false
        }))
        .unwrap();
        let mut taste = Taste::default();
        taste.playlists.push(Playlist {
            id: "p".into(),
            name: "导入".into(),
            prompt: String::new(),
            source_ids: Vec::new(),
            track_ids: Vec::new(),
            smart: false,
            entries: vec![
                PlaylistEntry {
                    track_id: None,
                    title: "夜空中最亮的星 ".into(),
                    artist: "逃跑计划".into(),
                    album: String::new(),
                },
                PlaylistEntry {
                    track_id: None,
                    title: "曲库里没有".into(),
                    artist: "某艺人".into(),
                    album: String::new(),
                },
            ],
        });
        resolve_entries(&mut taste, std::slice::from_ref(&track));
        assert_eq!(taste.playlists[0].entries[0].track_id.as_deref(), Some("t1"));
        assert!(taste.playlists[0].entries[1].track_id.is_none());
    }

    #[test]
    fn profile_persists_and_failed_save_does_not_change_memory() {
        let dir = std::env::temp_dir().join(format!(
            "awake-profile-test-{}",
            awake_core::models::new_id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let profile = parking_lot::Mutex::new(Taste::default());
        mutate_profile(&profile, &dir, |taste| {
            taste.favorites.insert("song".into());
            Ok(())
        })
        .unwrap();
        assert!(load(&dir).favorites.contains("song"));
        let missing = dir.join("missing");
        let result = mutate_profile(&profile, &missing, |taste| {
            taste.favorites.clear();
            Ok(())
        });
        assert!(result.is_err());
        assert!(profile.lock().favorites.contains("song"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}

pub fn with_correction(gains: &[f32], current: &EqCurve, rate: u32) -> Result<EqCurve, String> {
    let mut curve = validated_curve(gains)?;
    curve.filters = current.filters;
    curve.filter_count = current.filter_count;
    curve.correction_preamp = current.correction_preamp;
    curve.preamp = curve.correction_preamp;
    protect(&mut curve, rate);
    Ok(curve)
}
fn protect(curve: &mut EqCurve, rate: u32) {
    if curve.is_flat() {
        return;
    }
    let rate = rate.max(8000) as f32;
    let mut equalizer = awake_core::Equalizer::new(rate, 1);
    equalizer.apply_curve(curve);
    let upper = (rate * 0.49).min(20000.0);
    let peak = (0..1024)
        .map(|i| equalizer.response_db(20.0 * (upper / 20.0).powf(i as f32 / 1023.0)))
        .fold(0.0_f32, f32::max);
    curve.preamp = curve.preamp.min(-peak - 1.0);
}
#[tauri::command]
pub fn import_headphone_profile(
    name: String,
    measurement_source: String,
    target: String,
    text: String,
    device: String,
    state: State<'_, AppState>,
) -> Result<awake_core::parametric::Profile, String> {
    if name.trim().is_empty() || measurement_source.trim().is_empty() || target.trim().is_empty() {
        return Err("请填写耳机名称、测量来源和目标曲线".into());
    }
    if text.len() > 65536 {
        return Err("参数 EQ 配置过长".into());
    }
    let (preamp, filters) = awake_core::parametric::parse(&text)?;
    let profile = awake_core::parametric::Profile {
        id: awake_core::models::new_id(),
        name,
        measurement_source,
        target,
        preamp,
        filters,
    };
    mutate(&state, |taste| {
        taste.headphone_profiles.push(profile.clone());
        taste
            .active_corrections
            .insert(device.clone(), profile.id.clone());
        Ok(())
    })?;
    restore_correction(device, state)?;
    Ok(profile)
}
#[tauri::command]
pub fn select_correction(
    device: String,
    profile_id: Option<String>,
    state: State<'_, AppState>,
) -> Result<EqCurve, String> {
    mutate(&state, |taste| {
        if let Some(id) = profile_id {
            if !taste.headphone_profiles.iter().any(|p| p.id == id) {
                return Err("校正配置不存在".into());
            }
            taste.active_corrections.insert(device.clone(), id);
        } else {
            taste.active_corrections.remove(&device);
        }
        Ok(())
    })?;
    restore_correction(device, state)
}
#[tauri::command]
pub fn restore_correction(device: String, state: State<'_, AppState>) -> Result<EqCurve, String> {
    let profile = {
        let taste = state.taste.lock();
        taste
            .active_corrections
            .get(&device)
            .and_then(|id| taste.headphone_profiles.iter().find(|p| p.id == *id))
            .cloned()
    };
    let mut current = state.player.curve.lock().clone();
    current.filters = [awake_core::parametric::Filter::default(); 16];
    current.filter_count = 0;
    current.correction_preamp = 0.0;
    if let Some(profile) = profile {
        if profile.filters.len() > 16
            || profile.filters.is_empty()
            || !profile.preamp.is_finite()
            || !(-40.0..=0.0).contains(&profile.preamp)
            || profile.filters.iter().any(|f| {
                !f.frequency.is_finite()
                    || !(10.0..=22000.0).contains(&f.frequency)
                    || !f.gain_db.is_finite()
                    || f.gain_db.abs() > 18.0
                    || !f.q.is_finite()
                    || !(0.1..=20.0).contains(&f.q)
            })
        {
            return Err("保存的校正配置无效，请重新导入".into());
        }
        current.filter_count = profile.filters.len();
        current.filters[..profile.filters.len()].copy_from_slice(&profile.filters);
        current.correction_preamp = profile.preamp;
    }
    let curve = with_correction(
        &current.gains,
        &current,
        match state.player.status().output_rate {
            0 => 48000,
            rate => rate,
        },
    )?;
    *state.player.curve.lock() = curve.clone();
    Ok(curve)
}
