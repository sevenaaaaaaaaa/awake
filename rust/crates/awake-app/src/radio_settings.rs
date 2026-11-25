//! 电台解码设置：目前只有一项——"用 ffmpeg 兜底播放 Opus"。
//!
//! 开关默认**关**：兜底会引入外部二进制与首播延迟，只在用户明确要的时候才付这个代价。
//! 判定逻辑不在这里，在 `awake_core::radio::plan`（有测试）；这里只负责存与读，
//! 并把"本机到底有没有 ffmpeg"照实报给界面。

use crate::AppState;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tauri::State;

const STORE_FILE: &str = "radio-settings.json";

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RadioSettings {
    #[serde(default)]
    pub ffmpeg_fallback: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct RadioSettingsView {
    pub ffmpeg_fallback: bool,
    /// 本机 ffmpeg 的路径；空表示没找到。
    pub ffmpeg_path: String,
    /// 今天只有 opus 需要兜底；留着这个字段是为了以后加编码时界面不用改。
    pub needs_ffmpeg_for: Vec<String>,
}

fn store_path(dir: &std::path::Path) -> PathBuf {
    dir.join(STORE_FILE)
}

fn load(dir: &std::path::Path) -> RadioSettings {
    std::fs::read_to_string(store_path(dir))
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn view(settings: RadioSettings) -> RadioSettingsView {
    RadioSettingsView {
        ffmpeg_fallback: settings.ffmpeg_fallback,
        ffmpeg_path: awake_core::stream::ffmpeg_path()
            .map(|path| path.display().to_string())
            .unwrap_or_default(),
        needs_ffmpeg_for: vec!["opus".to_string()],
    }
}

#[tauri::command]
pub fn get_radio_settings(state: State<'_, AppState>) -> RadioSettingsView {
    let settings = load(&state.data_dir);
    view(settings)
}

#[tauri::command]
pub fn set_ffmpeg_fallback(enabled: bool, state: State<'_, AppState>) -> Result<RadioSettingsView, String> {
    let settings = RadioSettings { ffmpeg_fallback: enabled };
    let path = store_path(&state.data_dir);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    let text = serde_json::to_string_pretty(&settings).map_err(|error| error.to_string())?;
    let temp = path.with_extension("json.tmp");
    std::fs::write(&temp, text).map_err(|error| format!("写不了设置：{error}"))?;
    std::fs::rename(&temp, &path).map_err(|error| format!("保存设置失败：{error}"))?;
    Ok(view(settings))
}
