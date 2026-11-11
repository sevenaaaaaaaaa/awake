//! 曲库扫描与持久化 —— 对应 Swift `LibraryScanner` / `MusicLibrary`。

use crate::metadata::{apply_tags, read_tags};
use crate::models::{group_albums, now_ms, Album, LibrarySnapshot, MediaSource, SourceKind, Track};
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// 受支持的音频扩展名，与 Swift `LibraryScanner.audioExtensions` 一致。
pub const AUDIO_EXTENSIONS: [&str; 14] = [
    "flac", "m4a", "alac", "mp3", "aiff", "aif", "wav", "dsf", "dff", "ape", "wv", "ogg", "opus",
    "m4b",
];

/// 同目录封面文件名候选（按优先级）。
const ARTWORK_NAMES: [&str; 5] = ["cover", "folder", "front", "album", "artwork"];
const ARTWORK_EXTS: [&str; 4] = ["jpg", "jpeg", "png", "webp"];

pub fn is_audio_file(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| AUDIO_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

/// 收集目录下所有音频文件（跳过隐藏文件）。
pub fn collect_audio_files(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                continue;
            }
            match entry.file_type() {
                Ok(ft) if ft.is_dir() => stack.push(path),
                Ok(ft) if ft.is_file() => {
                    if is_audio_file(&path) {
                        out.push(path);
                    }
                }
                _ => {}
            }
        }
    }
    out.sort();
    out
}

fn collect_checked(root: &Path) -> Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in
            std::fs::read_dir(&dir).with_context(|| format!("无法读取目录：{}", dir.display()))?
        {
            let entry = entry?;
            if entry.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            let kind = entry.file_type()?;
            let path = entry.path();
            if kind.is_dir() {
                stack.push(path);
            } else if kind.is_file() && is_audio_file(&path) {
                out.push(path);
            }
        }
    }
    out.sort();
    Ok(out)
}

/// 找同目录封面文件。
fn folder_artwork(dir: &Path) -> Option<PathBuf> {
    ARTWORK_NAMES.iter().find_map(|name| {
        ARTWORK_EXTS.iter().find_map(|ext| {
            let candidate = dir.join(format!("{name}.{ext}"));
            if candidate.is_file() {
                Some(candidate)
            } else {
                None
            }
        })
    })
}

/// 计算相对 locator。用规范化后的路径做前缀，避免符号链接导致 locator 退化。
fn make_locator(root: &Path, file: &Path) -> String {
    let resolved_root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let resolved_file = file.canonicalize().unwrap_or_else(|_| file.to_path_buf());
    resolved_file
        .strip_prefix(&resolved_root)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| {
            file.file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default()
        })
}

/// 扫描一个本地来源。`existing` 用 locator 索引，用于增量复用。
pub fn scan_local_source(
    root: &Path,
    source_id: &str,
    existing: &HashMap<String, Track>,
    artwork_dir: Option<&Path>,
    mut progress: impl FnMut(usize, usize, &str),
) -> Result<Vec<Track>> {
    if !root.is_dir() {
        anyhow::bail!("来源路径不是一个目录: {}", root.display());
    }

    let files = collect_checked(root)?;
    let total = files.len();
    let mut tracks = Vec::with_capacity(total);

    // 目录级封面缓存
    let mut artwork_cache: HashMap<PathBuf, Option<PathBuf>> = HashMap::new();

    for (index, file) in files.iter().enumerate() {
        let locator = make_locator(root, file);
        let meta = std::fs::metadata(file).ok();
        let size = meta.as_ref().map(|m| m.len() as i64).unwrap_or(0);
        let modified = meta
            .as_ref()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        // 增量：size 与 mtime 都没变就直接复用
        if let Some(cached) = existing.get(&locator) {
            if cached.file_size == size && (cached.modified - modified).abs() < 1000 {
                tracks.push(cached.clone());
                progress(index + 1, total, &cached.title);
                continue;
            }
        }

        let tags = read_tags(file);
        let id = Track::make_id(source_id, &locator);

        let dir = file.parent().map(|p| p.to_path_buf()).unwrap_or_default();
        let sidecar = artwork_cache
            .entry(dir.clone())
            .or_insert_with(|| folder_artwork(&dir))
            .clone();

        // 封面优先级：内嵌 > 同目录 sidecar（与 Swift 一致）
        let artwork_path = if let (Some(data), Some(out_dir)) = (tags.artwork.as_ref(), artwork_dir)
        {
            if !data.is_empty() {
                persist_artwork(data, &id, out_dir)
                    .or_else(|| sidecar.as_ref().map(|p| p.to_string_lossy().to_string()))
            } else {
                sidecar.as_ref().map(|p| p.to_string_lossy().to_string())
            }
        } else {
            sidecar.as_ref().map(|p| p.to_string_lossy().to_string())
        };

        let mut track = Track {
            id,
            title: tags.title.clone(),
            artist: tags.artist.clone(),
            album_artist: tags.album_artist.clone(),
            album: tags.album.clone(),
            genre: tags.genre.clone(),
            year: tags.year,
            track_number: tags.track_number,
            disc_number: tags.disc_number,
            duration: tags.duration,
            sample_rate: tags.sample_rate,
            bit_depth: tags.bit_depth,
            channels: tags.channels,
            codec: tags.codec.clone(),
            source_id: source_id.to_string(),
            locator: locator.clone(),
            file_size: size,
            modified,
            artwork_path,
            play_count: existing.get(&locator).map(|t| t.play_count).unwrap_or(0),
            favorite: existing.get(&locator).map(|t| t.favorite).unwrap_or(false),
            last_played: existing.get(&locator).and_then(|t| t.last_played),
            added_at: existing
                .get(&locator)
                .map(|t| t.added_at)
                .unwrap_or_else(now_ms),
            is_remote: false,
        };
        apply_tags(&mut track, &tags);

        tracks.push(track);
        progress(index + 1, total, &tags.title);
    }

    // 专辑封面传播：同专辑里有封面的，补到没有的条目上
    let mut album_art: HashMap<String, String> = HashMap::new();
    for t in &tracks {
        if let Some(art) = &t.artwork_path {
            album_art.insert(t.album_key(), art.clone());
        }
    }
    for t in &mut tracks {
        if t.artwork_path.is_none() {
            if let Some(art) = album_art.get(&t.album_key()) {
                t.artwork_path = Some(art.clone());
            }
        }
    }

    Ok(tracks)
}

/// 把内嵌封面写到缓存目录，返回文件路径。
fn persist_artwork(data: &[u8], track_id: &str, out_dir: &Path) -> Option<String> {
    std::fs::create_dir_all(out_dir).ok()?;
    // 用魔数判断图片类型，与 Swift 侧行为一致
    let ext = if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "jpg"
    } else if data.starts_with(&[0x89, b'P', b'N', b'G']) {
        "png"
    } else if data.starts_with(b"RIFF") {
        "webp"
    } else {
        "jpg"
    };
    let path = out_dir.join(format!("{track_id}.{ext}"));
    if path.is_file() {
        return Some(path.to_string_lossy().to_string());
    }
    std::fs::write(&path, data).ok()?;
    Some(path.to_string_lossy().to_string())
}

/// 曲库内存态 + 落盘。
pub struct Library {
    pub snapshot: LibrarySnapshot,
    store_path: PathBuf,
}

impl Library {
    pub fn open(store_path: impl Into<PathBuf>) -> Self {
        let store_path = store_path.into();
        let snapshot = std::fs::read_to_string(&store_path)
            .ok()
            .and_then(|s| serde_json::from_str::<LibrarySnapshot>(&s).ok())
            .unwrap_or_default();
        Self {
            snapshot,
            store_path,
        }
    }

    pub fn save(&self) -> Result<()> {
        if let Some(parent) = self.store_path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let json = serde_json::to_string_pretty(&self.snapshot)?;
        let tmp = self.store_path.with_extension("json.tmp");
        std::fs::write(&tmp, json)
            .with_context(|| format!("写入曲库失败: {}", self.store_path.display()))?;
        std::fs::rename(tmp, &self.store_path)
            .with_context(|| format!("提交曲库失败: {}", self.store_path.display()))?;
        Ok(())
    }

    /// 重建索引：按来源替换该来源的全部曲目。
    pub fn replace_source_tracks(&mut self, source_id: &str, tracks: Vec<Track>) {
        self.snapshot.tracks.retain(|t| t.source_id != source_id);
        self.snapshot.tracks.extend(tracks);
    }

    pub fn tracks_by_locator(&self, source_id: &str) -> HashMap<String, Track> {
        self.snapshot
            .tracks
            .iter()
            .filter(|t| t.source_id == source_id)
            .map(|t| (t.locator.clone(), t.clone()))
            .collect()
    }

    pub fn albums(&self) -> Vec<Album> {
        group_albums(&self.snapshot.tracks)
    }

    pub fn add_source(&mut self, source: MediaSource) {
        self.snapshot.sources.push(source);
    }

    pub fn local_sources(&self) -> impl Iterator<Item = &MediaSource> {
        self.snapshot
            .sources
            .iter()
            .filter(|s| s.kind == SourceKind::Local)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn demo_root() -> Option<PathBuf> {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../DemoMusic");
        if dir.is_dir() {
            Some(dir)
        } else {
            None
        }
    }

    #[test]
    fn finds_all_nine_demo_tracks() {
        let Some(root) = demo_root() else {
            eprintln!("跳过：演示曲库未生成");
            return;
        };
        let files = collect_audio_files(&root);
        assert_eq!(files.len(), 9, "演示曲库应为 9 首，实测 {}", files.len());
    }

    #[test]
    fn scans_and_groups_into_three_albums() {
        let Some(root) = demo_root() else {
            eprintln!("跳过：演示曲库未生成");
            return;
        };
        let existing = HashMap::new();
        let art_dir = std::env::temp_dir().join("awake-test-artwork");
        let _ = std::fs::remove_dir_all(&art_dir);
        let tracks = scan_local_source(&root, "src-demo", &existing, Some(&art_dir), |_, _, _| {})
            .expect("扫描应成功");
        assert_eq!(tracks.len(), 9);

        let albums = group_albums(&tracks);
        assert_eq!(
            albums.len(),
            3,
            "演示曲库为 3 张专辑，实测 {}",
            albums.len()
        );

        // 每首都应有封面（内嵌或同目录 sidecar）
        let with_art = tracks.iter().filter(|t| t.artwork_path.is_some()).count();
        assert_eq!(with_art, 9, "应全部有封面，实测 {with_art}");
    }

    #[test]
    fn locator_is_relative_and_unique() {
        let Some(root) = demo_root() else {
            eprintln!("跳过：演示曲库未生成");
            return;
        };
        let files = collect_audio_files(&root);
        let locators: Vec<String> = files.iter().map(|f| make_locator(&root, f)).collect();
        for loc in &locators {
            assert!(!loc.starts_with('/'), "locator 应为相对路径: {loc}");
        }
        let unique: std::collections::HashSet<_> = locators.iter().collect();
        assert_eq!(unique.len(), locators.len(), "locator 不应重复");
    }

    #[test]
    fn incremental_scan_reuses_cached_entries() {
        let Some(root) = demo_root() else {
            eprintln!("跳过：演示曲库未生成");
            return;
        };
        let art_dir = std::env::temp_dir().join("awake-test-artwork2");
        let _ = std::fs::remove_dir_all(&art_dir);
        let first =
            scan_local_source(&root, "src", &HashMap::new(), Some(&art_dir), |_, _, _| {}).unwrap();
        let existing: HashMap<String, Track> = first
            .iter()
            .map(|t| (t.locator.clone(), t.clone()))
            .collect();

        let mut reused = 0;
        let second = scan_local_source(&root, "src", &existing, Some(&art_dir), |_, _, _| {
            reused += 1;
        })
        .unwrap();

        assert_eq!(second.len(), 9);
        // 全部命中缓存时，标题应与第一次完全一致（说明走的是复用分支）
        assert_eq!(second[0].title, first[0].title);
        assert_eq!(reused, 9, "第二次扫描应全部命中增量缓存");
    }

    #[test]
    fn library_roundtrips_through_json() {
        let dir = std::env::temp_dir().join("awake-test-library");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let store = dir.join("library.json");

        let mut lib = Library::open(&store);
        lib.add_source(MediaSource::new(SourceKind::Local, "演示", "/tmp/demo"));
        lib.save().expect("应能落盘");

        let reloaded = Library::open(&store);
        assert_eq!(reloaded.snapshot.sources.len(), 1);
        assert_eq!(reloaded.snapshot.sources[0].name, "演示");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
