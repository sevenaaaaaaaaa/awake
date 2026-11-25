//! 只读的曲库洞察命令：专架、适配队列、艺人画像。
//!
//! 三个命令都**不写任何状态**，所以它们可以在任何页面被反复调用。
//! 聚合逻辑全在 `awake-core` 里（有单测），这里只做"取状态 + 转手"。

use crate::AppState;
use awake_core::adapt::{queue, AdaptQueue};
use awake_core::artist::{profiles, ArtistProfile};
use awake_core::shelf::{overview, ShelfGroup};
use std::collections::HashSet;
use tauri::State;

/// 专架：古典 / 轻音乐 / 现场各有多少首、凭什么进来的。
#[tauri::command]
pub fn shelf_overview(state: State<'_, AppState>) -> Vec<ShelfGroup> {
    let library = state.library.lock();
    overview(&library.snapshot.tracks)
}

/// 报告卡的数字：多少首还没有曲线、分成几批、被什么卡住。
#[tauri::command]
pub fn adapt_queue(state: State<'_, AppState>) -> AdaptQueue {
    let library = state.library.lock();
    let curves = state.song_curves.lock();
    let taste = state.taste.lock();

    let curved: HashSet<String> = curves.curves.keys().cloned().collect();
    // 参照物 = 导入过的听感先验，或任何一份耳机档案。缺了它，拟合就是猜。
    let has_reference = curves.prior.is_some() || !taste.headphone_profiles.is_empty();
    queue(&library.snapshot.tracks, &curved, has_reference)
}

/// 艺人画像：只用本地数据（播放事件 + 曲库），不联网。
#[tauri::command]
pub fn artist_profiles(state: State<'_, AppState>) -> Vec<ArtistProfile> {
    let library = state.library.lock();
    let taste = state.taste.lock();
    profiles(&library.snapshot.tracks, &taste.events)
}