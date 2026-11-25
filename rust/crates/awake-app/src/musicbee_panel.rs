//! macOS 桌面的 MusicBee 导入面板：选文件 → 预览 → 落库。
//!
//! 与 `awake-cli mbl apply` 同一套核心（`awake_core::musicbee_import`），区别只有两处：
//! - 来源根不用手填：曲库里已有的本地来源（url 是绝对路径）就是映射目标；
//! - 落库前后都要动 `AppState`，所以这里负责备份、保存与错误文案。
//!
//! 面板**只读 `.mbl`**，不写回；重复点"应用"是安全的（播放次数只增不减）。

use crate::AppState;
use awake_core::musicbee;
use awake_core::musicbee_import::{apply, plan, SourceRoot};
use serde::Serialize;
use tauri::State;

#[derive(Debug, Clone, Serialize)]
pub struct LocalSourceView {
    pub id: String,
    pub name: String,
    pub root: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct MblPreview {
    pub path: String,
    pub bytes: u64,
    pub version: u8,
    pub declared: u32,
    pub parsed: usize,
    /// 第一条记录的原始 Windows 路径，用来给"Windows 根"填空提示。
    pub first_path: String,
    pub suggested_win_root: String,
    pub sources: Vec<LocalSourceView>,
    pub library_total: usize,
    pub matched: usize,
    pub changed: usize,
    pub case_insensitive: usize,
    /// 最多 20 条，免得一次塞上万条给界面。
    pub unmatched: Vec<String>,
    pub unmatched_total: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct MblApplied {
    pub updated: usize,
    pub play_count_raised: usize,
    pub last_played_moved: usize,
    pub added_at_filled: usize,
    pub backup: Option<String>,
}

/// 从 `.mbl` 的第一条路径猜一个"Windows 根"（只作预填，用户可以改）。
fn suggest_win_root(path: &str) -> String {
    if path.starts_with(r"\\") {
        let parts: Vec<&str> = path.trim_start_matches('\\').split('\\').collect();
        if parts.len() >= 2 && !parts[1].is_empty() {
            return format!("\\\\{}\\{}", parts[0], parts[1]);
        }
        return path.to_string();
    }
    let parts: Vec<&str> = path.split('\\').collect();
    // 三段以上才有"目录"可猜：F:\Music\01.flac → F:\Music；F:\01.flac → F:（那是盘根）
    if parts.len() >= 3 && !parts[0].is_empty() && !parts[1].is_empty() {
        format!("{}\\{}", parts[0], parts[1])
    } else if !parts.is_empty() && !parts[0].is_empty() {
        parts[0].to_string()
    } else {
        String::new()
    }
}

fn local_sources(state: &AppState) -> (Vec<LocalSourceView>, Vec<(String, String)>) {
    let library = state.library.lock();
    let mut views = Vec::new();
    let mut roots = Vec::new();
    for source in &library.snapshot.sources {
        if !source.enabled || !source.url.starts_with('/') {
            continue;
        }
        views.push(LocalSourceView {
            id: source.id.clone(),
            name: source.name.clone(),
            root: source.url.clone(),
        });
        roots.push((source.id.clone(), source.url.clone()));
    }
    (views, roots)
}

#[tauri::command]
pub fn musicbee_preview(
    path: String,
    win_root: String,
    state: State<'_, AppState>,
) -> Result<MblPreview, String> {
    let bytes = std::fs::read(&path).map_err(|error| format!("读不到 {path}：{error}"))?;
    let library = musicbee::parse(&bytes).map_err(|error| format!(".mbl 解析失败：{error}"))?;

    let (sources, roots) = local_sources(&state);
    let refs: Vec<SourceRoot> = roots
        .iter()
        .map(|(id, root)| SourceRoot { source_id: id.as_str(), root: root.as_str() })
        .collect();

    let first_path = library.records.first().map(|r| r.path.clone()).unwrap_or_default();
    let suggested_win_root = suggest_win_root(&first_path);
    let effective = if win_root.trim().is_empty() {
        suggested_win_root.clone()
    } else {
        win_root.trim().to_string()
    };

    let store = state.library.lock();
    let plan = plan(&library, &store.snapshot.tracks, &refs, &effective);
    let unmatched_total = plan.unmatched.len();
    Ok(MblPreview {
        path,
        bytes: bytes.len() as u64,
        version: library.version,
        declared: library.declared,
        parsed: library.records.len(),
        first_path,
        suggested_win_root,
        sources,
        library_total: store.snapshot.tracks.len(),
        matched: plan.matched.len(),
        changed: plan.changed,
        case_insensitive: plan.case_insensitive,
        unmatched: plan.unmatched.iter().take(20).cloned().collect(),
        unmatched_total,
    })
}

#[tauri::command]
pub fn musicbee_apply(
    path: String,
    win_root: String,
    state: State<'_, AppState>,
) -> Result<MblApplied, String> {
    let bytes = std::fs::read(&path).map_err(|error| format!("读不到 {path}：{error}"))?;
    let library = musicbee::parse(&bytes).map_err(|error| format!(".mbl 解析失败：{error}"))?;

    let (_, roots) = local_sources(&state);
    if roots.is_empty() {
        return Err("曲库里还没有本地来源（url 是绝对路径）。先把音乐文件夹加成本地来源，再来导入。".into());
    }
    let refs: Vec<SourceRoot> = roots
        .iter()
        .map(|(id, root)| SourceRoot { source_id: id.as_str(), root: root.as_str() })
        .collect();

    let mut store = state.library.lock();
    let plan = plan(&library, &store.snapshot.tracks, &refs, win_root.trim());
    if plan.changed == 0 {
        return Ok(MblApplied {
            updated: 0,
            play_count_raised: 0,
            last_played_moved: 0,
            added_at_filled: 0,
            backup: None,
        });
    }

    let report = apply(&mut store.snapshot.tracks, &plan);

    // 写库前先留一份：与 CLI 用的目录约定一致（data_dir/backups/musicbee-<ms>/）。
    let dir = state
        .data_dir
        .join("backups")
        .join(format!("musicbee-{}", awake_core::models::now_ms()));
    std::fs::create_dir_all(&dir).ok();
    std::fs::copy(state.data_dir.join("library.json"), dir.join("library.json")).ok();
    store.save().map_err(|error| format!("写入曲库失败：{error}"))?;

    Ok(MblApplied {
        updated: report.updated,
        play_count_raised: report.play_count_raised,
        last_played_moved: report.last_played_moved,
        added_at_filled: report.added_at_filled,
        backup: Some(dir.display().to_string()),
    })
}

/// 选 `.mbl`：用 osascript 的系统文件选择器，与 `pick_music_files` 同一套路子。
#[cfg(test)]
mod tests {
    use super::suggest_win_root;

    #[test]
    fn suggests_a_root_from_the_first_record() {
        assert_eq!(suggest_win_root(r"F:\Music\Artist\01.flac"), r"F:\Music");
        assert_eq!(suggest_win_root(r"F:\01.flac"), r"F:");
        assert_eq!(suggest_win_root(r"\\NAS\music\x.flac"), r"\\NAS\music");
        assert_eq!(suggest_win_root(""), "");
    }
}

#[tauri::command]
pub async fn pick_musicbee_library() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(|| {
        #[cfg(target_os = "macos")]
        {
            let output = std::process::Command::new("osascript")
                .args([
                    "-e",
                    "set chosen to choose file with prompt \"选择 MusicBee 曲库文件（MusicBeeLibrary.mbl）\" of type {\"mbl\"}",
                    "-e",
                    "return POSIX path of chosen",
                ])
                .output()
                .map_err(|_| "无法打开文件选择器".to_string())?;
            if !output.status.success() {
                let error = String::from_utf8_lossy(&output.stderr);
                if error.contains("-128") {
                    return Ok(String::new());
                }
                return Err(format!(
                    "文件选择器没有完成：{}",
                    error.trim().chars().take(160).collect::<String>()
                ));
            }
            Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
        }
        #[cfg(not(target_os = "macos"))]
        {
            Err("这条命令只在 macOS 桌面版可用".to_string())
        }
    })
    .await
    .map_err(|_| "文件选择器线程失败".to_string())?
}
