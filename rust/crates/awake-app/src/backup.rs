//! 端到端加密备份/恢复。格式见 docs/backup-format.md（v1）。
//!
//! 文件是 UTF-8 JSON envelope：PBKDF2-HMAC-SHA256(310000) 派生密钥，
//! AES-256-GCM 加密 payload，data = base64(nonce || ciphertext || tag)。
//! 密码、明文与钥匙串内容都不离开设备；音频文件不进入备份。
use crate::AppState;
use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use awake_core::models::{now_ms, LibrarySnapshot};
use awake_core::taste::Taste;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use pbkdf2::pbkdf2_hmac;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::path::{Path, PathBuf};
use tauri::State;

const FORMAT: &str = "awake-e2e";
const VERSION: u32 = 1;
const KDF: &str = "pbkdf2-hmac-sha256";
/// 与 iOS 端共用同一组参数；改这个值等于换格式。
const ITERATIONS: u32 = 310_000;
const CIPHER: &str = "aes-256-gcm";
const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
const KEY_LEN: usize = 32;
const MIN_PASSWORD: usize = 8;
/// 读入上限：base64 后仍然宽裕，防止误选巨大文件把内存吃满。
const MAX_BACKUP_BYTES: u64 = 256 * 1024 * 1024;

const SCHEMA_MACOS: &str = "awake.backup.macos";
const SCHEMA_IOS: &str = "awake.backup.ios";
const SCHEMA_PREFIX: &str = "awake.backup.";

/// 解密失败（密码错误/篡改/结构损坏）统一文案，不泄露细节。
const ERR_PASSWORD: &str = "密码错误或备份已损坏";
const ERR_FORMAT: &str = "备份文件格式无法识别";

#[derive(Debug, Clone, Serialize)]
pub struct BackupPreview {
    pub schema: String,
    pub version: u32,
    pub exported_at_ms: i64,
    pub device: String,
    pub tracks: usize,
    pub playlists: usize,
    pub favorites: usize,
    pub bytes: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct BackupRestoreResult {
    pub schema: String,
    pub tracks: usize,
    pub playlists: usize,
    pub favorites: usize,
    pub safety_copy: Option<String>,
}

/// 容器外层：只有加密参数，没有任何时间/设备元数据。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Envelope {
    format: String,
    version: u32,
    kdf: String,
    iterations: u32,
    salt: String,
    cipher: String,
    data: String,
}

/// 解密后的明文 payload。iOS 备份没有 taste，旧备份可能没有 playback。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct BackupPayload {
    schema: String,
    version: u32,
    exported_at_ms: i64,
    device: String,
    #[serde(default)]
    app_version: String,
    library: LibrarySnapshot,
    #[serde(default)]
    taste: Option<Taste>,
    #[serde(default)]
    playback: Option<PlaybackSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PlaybackSnapshot {
    title: String,
    artist: String,
    album: String,
    duration: f64,
    position: f64,
}

// ---------------------------------------------------------------------------
// 加密
// ---------------------------------------------------------------------------

/// PBKDF2-HMAC-SHA256(password, salt, 310000) -> 32 字节密钥。
fn derive_key(password: &str, salt: &[u8]) -> [u8; KEY_LEN] {
    let mut key = [0u8; KEY_LEN];
    pbkdf2_hmac::<Sha256>(password.as_bytes(), salt, ITERATIONS, &mut key);
    key
}

/// 加密并返回 nonce || ciphertext || tag。
fn seal(password: &str, salt: &[u8], nonce: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, String> {
    if salt.len() != SALT_LEN || nonce.len() != NONCE_LEN {
        return Err(ERR_FORMAT.into());
    }
    let key = derive_key(password, salt);
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| ERR_FORMAT.to_string())?;
    let ciphertext = cipher
        .encrypt(Nonce::from_slice(nonce), plaintext)
        .map_err(|_| "加密失败".to_string())?;
    let mut out = Vec::with_capacity(NONCE_LEN + ciphertext.len());
    out.extend_from_slice(nonce);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

/// 解密 nonce || ciphertext || tag，任何失败都折叠成同一句文案。
fn open(password: &str, salt: &[u8], data: &[u8]) -> Result<Vec<u8>, String> {
    if salt.len() != SALT_LEN || data.len() < NONCE_LEN + TAG_LEN {
        return Err(ERR_PASSWORD.into());
    }
    let key = derive_key(password, salt);
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| ERR_PASSWORD.to_string())?;
    let (nonce, ciphertext) = data.split_at(NONCE_LEN);
    cipher
        .decrypt(Nonce::from_slice(nonce), ciphertext)
        .map_err(|_| ERR_PASSWORD.to_string())
}

fn parse_envelope(text: &str) -> Result<Envelope, String> {
    let text = text.trim_start_matches('\u{feff}');
    let envelope: Envelope = serde_json::from_str(text).map_err(|_| ERR_FORMAT.to_string())?;
    if envelope.format != FORMAT
        || envelope.version != VERSION
        || envelope.kdf != KDF
        || envelope.iterations != ITERATIONS
        || envelope.cipher != CIPHER
    {
        return Err(ERR_FORMAT.into());
    }
    Ok(envelope)
}

fn open_envelope(password: &str, envelope: &Envelope) -> Result<Vec<u8>, String> {
    let salt = BASE64
        .decode(envelope.salt.as_bytes())
        .map_err(|_| ERR_PASSWORD.to_string())?;
    let data = BASE64
        .decode(envelope.data.as_bytes())
        .map_err(|_| ERR_PASSWORD.to_string())?;
    open(password, &salt, &data)
}

fn envelope_text(
    password: &str,
    salt: &[u8],
    nonce: &[u8],
    payload: &[u8],
) -> Result<String, String> {
    let data = seal(password, salt, nonce, payload)?;
    let envelope = Envelope {
        format: FORMAT.into(),
        version: VERSION,
        kdf: KDF.into(),
        iterations: ITERATIONS,
        salt: BASE64.encode(salt),
        cipher: CIPHER.into(),
        data: BASE64.encode(data),
    };
    serde_json::to_string_pretty(&envelope).map_err(|e| e.to_string())
}

/// 密码规则只在导出时强制；解密端不区分“太短”和“错误”，避免泄露信息。
fn require_password(password: &str) -> Result<(), String> {
    if password.chars().count() < MIN_PASSWORD {
        return Err(format!("密码至少需要 {MIN_PASSWORD} 个字符"));
    }
    Ok(())
}

fn random_bytes(out: &mut [u8]) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::io::Read;
        let mut file =
            std::fs::File::open("/dev/urandom").map_err(|_| "无法获取随机数".to_string())?;
        file.read_exact(out)
            .map_err(|_| "无法获取随机数".to_string())?;
        Ok(())
    }
    #[cfg(not(unix))]
    {
        // 非 Unix 兜底：没有额外依赖可用，用多个熵源混合。macOS 走上面的系统随机源。
        use sha2::Digest;
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let mut hasher = Sha256::new();
        hasher.update(std::process::id().to_le_bytes());
        hasher.update(COUNTER.fetch_add(1, Ordering::Relaxed).to_le_bytes());
        hasher.update(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(0)
                .to_le_bytes(),
        );
        let digest = hasher.finalize();
        for (slot, byte) in out.iter_mut().zip(digest.iter().cycle()) {
            *slot = *byte;
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// payload 组装与校验
// ---------------------------------------------------------------------------

/// 导出前清掉凭据：钥匙串里的密码本来就不在 snapshot 里，但 token 是明文的。
fn sanitize_snapshot(snapshot: &LibrarySnapshot) -> LibrarySnapshot {
    let mut out = snapshot.clone();
    for source in &mut out.sources {
        source.token.clear();
    }
    out
}

fn playback_snapshot(state: &AppState) -> Option<PlaybackSnapshot> {
    let status = state.player.status();
    let id = status.current.clone()?;
    let track = {
        state
            .library
            .lock()
            .snapshot
            .tracks
            .iter()
            .find(|t| t.id == id)
            .cloned()?
    };
    let title = if status.tags.title.is_empty() {
        track.title.clone()
    } else {
        status.tags.title.clone()
    };
    let artist = if status.tags.artist.is_empty() {
        track.artist.clone()
    } else {
        status.tags.artist.clone()
    };
    let album = if status.tags.album.is_empty() {
        track.album
    } else {
        status.tags.album
    };
    let duration = if status.duration > 0.0 {
        status.duration
    } else {
        track.duration
    };
    let position = if status.position.is_finite() && status.position >= 0.0 {
        status.position.min(duration.max(0.0))
    } else {
        0.0
    };
    Some(PlaybackSnapshot {
        title,
        artist,
        album,
        duration,
        position,
    })
}

fn export_payload(state: &AppState) -> BackupPayload {
    let library = sanitize_snapshot(&state.library.lock().snapshot);
    // 锁顺序统一为 library -> taste，避免与其它命令交叉加锁。
    let taste = state.taste.lock().clone();
    BackupPayload {
        schema: SCHEMA_MACOS.into(),
        version: VERSION,
        exported_at_ms: now_ms(),
        device: crate::handoff::host_name(),
        app_version: env!("CARGO_PKG_VERSION").into(),
        library,
        taste: Some(taste),
        playback: playback_snapshot(state),
    }
}

fn platform_label(schema: &str) -> &'static str {
    match schema {
        SCHEMA_IOS => "iPhone",
        SCHEMA_MACOS => "Mac",
        _ => "其他平台",
    }
}

/// 跨平台只支持歌单导入，整体覆盖只在 macOS 内部进行。
fn validate_restore_payload(payload: &BackupPayload) -> Result<(), String> {
    if payload.version != VERSION {
        return Err("备份格式版本不受支持".into());
    }
    if payload.schema == SCHEMA_MACOS {
        return Ok(());
    }
    if payload.schema.starts_with(SCHEMA_PREFIX) {
        return Err(format!(
            "这是{}的备份，请在{}上恢复；跨平台只支持歌单导入",
            platform_label(&payload.schema),
            platform_label(&payload.schema)
        ));
    }
    Err(ERR_FORMAT.into())
}

/// file 既可能是备份 JSON 文本（前端读文件后传入），也可能是磁盘路径。
fn read_backup(file: &str) -> Result<(String, usize), String> {
    let trimmed = file.trim_start_matches('\u{feff}');
    let text = if trimmed.trim_start().starts_with('{') {
        trimmed.to_string()
    } else {
        let path = PathBuf::from(file.trim());
        let meta = std::fs::metadata(&path).map_err(|_| "找不到备份文件".to_string())?;
        if meta.len() > MAX_BACKUP_BYTES {
            return Err("备份文件过大，无法读取".into());
        }
        std::fs::read_to_string(&path).map_err(|_| "无法读取备份文件".to_string())?
    };
    let bytes = text.len();
    if bytes as u64 > MAX_BACKUP_BYTES {
        return Err("备份文件过大，无法读取".into());
    }
    Ok((text, bytes))
}

fn decode_payload(file: &str, password: &str) -> Result<(BackupPayload, usize), String> {
    let (text, bytes) = read_backup(file)?;
    let envelope = parse_envelope(&text)?;
    let plaintext = open_envelope(password, &envelope)?;
    let payload: BackupPayload =
        serde_json::from_slice(&plaintext).map_err(|_| ERR_PASSWORD.to_string())?;
    Ok((payload, bytes))
}

// ---------------------------------------------------------------------------
// 恢复：安全副本 + 原子替换
// ---------------------------------------------------------------------------

/// 先把当前 library.json / taste.json 复制到 backups/restore-<ms>/，再原子替换。
/// 任一步失败都会把 library.json 还原成调用前的内容，不留下半份状态。
fn restore_files(
    data_dir: &Path,
    snapshot: &LibrarySnapshot,
    taste: &Taste,
) -> Result<PathBuf, String> {
    // 先序列化并回读：结构不合法时根本不会碰磁盘。
    let library_json =
        serde_json::to_vec_pretty(snapshot).map_err(|_| "备份内容无法读取".to_string())?;
    let taste_json =
        serde_json::to_vec_pretty(taste).map_err(|_| "备份内容无法读取".to_string())?;
    serde_json::from_slice::<LibrarySnapshot>(&library_json)
        .map_err(|_| "备份里的曲库结构不受支持".to_string())?;
    serde_json::from_slice::<Taste>(&taste_json)
        .map_err(|_| "备份里的听歌档案结构不受支持".to_string())?;

    std::fs::create_dir_all(data_dir).map_err(|_| "无法创建数据目录".to_string())?;
    let stamp = now_ms();
    let safety_dir = data_dir.join("backups").join(format!("restore-{stamp}"));
    std::fs::create_dir_all(&safety_dir).map_err(|_| "无法创建安全副本目录".to_string())?;
    for name in ["library.json", "taste.json"] {
        let source = data_dir.join(name);
        if source.is_file() {
            std::fs::copy(&source, safety_dir.join(name))
                .map_err(|_| "无法写入安全副本".to_string())?;
        }
    }

    let library_path = data_dir.join("library.json");
    let taste_path = data_dir.join("taste.json");
    let previous_library = std::fs::read(&library_path).ok();

    // 两份新内容都先落到临时文件，再逐个 rename 提交。
    let library_tmp = data_dir.join(format!("library.json.restore-{stamp}.tmp"));
    let taste_tmp = data_dir.join(format!("taste.json.restore-{stamp}.tmp"));
    std::fs::write(&library_tmp, &library_json).map_err(|_| "写入曲库失败".to_string())?;
    if let Err(e) = std::fs::write(&taste_tmp, &taste_json) {
        let _ = std::fs::remove_file(&library_tmp);
        return Err(format!("写入听歌档案失败：{e}"));
    }

    if std::fs::rename(&library_tmp, &library_path).is_err() {
        let _ = std::fs::remove_file(&library_tmp);
        let _ = std::fs::remove_file(&taste_tmp);
        return Err("提交曲库失败".into());
    }
    if std::fs::rename(&taste_tmp, &taste_path).is_err() {
        let _ = std::fs::remove_file(&taste_tmp);
        // 回滚曲库：保证失败后看到的仍是恢复前的曲库。
        let rolled_back = match &previous_library {
            Some(bytes) => std::fs::write(&library_path, bytes).is_ok(),
            None => std::fs::remove_file(&library_path).is_ok(),
        };
        if rolled_back {
            return Err("提交听歌档案失败，曲库已回滚".into());
        }
        return Err("提交听歌档案失败，且曲库回滚失败，请用安全副本手动恢复".into());
    }
    Ok(safety_dir)
}

// ---------------------------------------------------------------------------
// 命令
// ---------------------------------------------------------------------------

#[tauri::command]
pub fn backup_export(password: String, state: State<'_, AppState>) -> Result<String, String> {
    require_password(&password)?;
    let payload = export_payload(state.inner());
    let plaintext = serde_json::to_vec(&payload).map_err(|e| e.to_string())?;
    let mut salt = [0u8; SALT_LEN];
    let mut nonce = [0u8; NONCE_LEN];
    random_bytes(&mut salt)?;
    random_bytes(&mut nonce)?;
    envelope_text(&password, &salt, &nonce, &plaintext)
}

/// 导出并直接写入用户的 Downloads 目录，返回文件路径。
/// WebView 的 Blob 下载在部分 macOS WebView 配置下会被静默取消，所以提供这条更可靠的路径。
#[tauri::command]
pub fn backup_export_file(password: String, state: State<'_, AppState>) -> Result<String, String> {
    let text = backup_export(password, state)?;
    let home = std::env::var("HOME").map_err(|_| "找不到用户目录".to_string())?;
    let dir = std::path::PathBuf::from(home).join("Downloads");
    std::fs::create_dir_all(&dir).map_err(|_| "无法写入下载目录".to_string())?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let path = dir.join(format!("awake-backup-{stamp}.awake-backup"));
    std::fs::write(&path, text).map_err(|_| "写入备份文件失败".to_string())?;
    Ok(path.display().to_string())
}

#[tauri::command]
pub fn backup_inspect(file: String, password: String) -> Result<BackupPreview, String> {
    let (payload, bytes) = decode_payload(&file, &password)?;
    if payload.version != VERSION {
        return Err("备份格式版本不受支持".into());
    }
    if !payload.schema.starts_with(SCHEMA_PREFIX) {
        return Err(ERR_FORMAT.into());
    }
    let tracks = payload.library.tracks.len();
    let taste = payload.taste.unwrap_or_default();
    Ok(BackupPreview {
        schema: payload.schema,
        version: payload.version,
        exported_at_ms: payload.exported_at_ms,
        device: payload.device,
        tracks,
        playlists: taste.playlists.len(),
        favorites: taste.favorites.len(),
        bytes,
    })
}

#[tauri::command]
pub fn backup_restore(
    file: String,
    password: String,
    state: State<'_, AppState>,
) -> Result<BackupRestoreResult, String> {
    let (payload, _) = decode_payload(&file, &password)?;
    validate_restore_payload(&payload)?;
    let snapshot = payload.library;
    // 旧备份可能没有 taste：那时保留本机现有档案，避免把歌单/收藏清空。
    let taste = match payload.taste {
        Some(taste) => taste,
        None => state.taste.lock().clone(),
    };
    let tracks = snapshot.tracks.len();
    let playlists = taste.playlists.len();
    let favorites = taste.favorites.len();

    let safety = restore_files(&state.data_dir, &snapshot, &taste)?;
    // 文件已经提交成功，再同步内存态；内存更新不会失败。
    state.library.lock().snapshot = snapshot;
    *state.taste.lock() = taste;
    Ok(BackupRestoreResult {
        schema: payload.schema,
        tracks,
        playlists,
        favorites,
        safety_copy: Some(safety.to_string_lossy().to_string()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use awake_core::models::{MediaSource, SourceKind};
    use awake_core::taste::Playlist;
    use std::fs;
    use std::path::PathBuf;

    const VECTOR_PASSWORD: &str = "Awake-test-123";
    const VECTOR_SALT: &str = "ABEiM0RVZneImaq7zN3u/w==";
    const VECTOR_NONCE: &str = "AAECAwQFBgcICQoL";
    const VECTOR_PAYLOAD: &str =
        r#"{"schema":"awake.backup.test","version":1,"message":"hello awake"}"#;
    const VECTOR_DATA: &str = "AAECAwQFBgcICQoLMDUgbWvLP74LSIE1AHPmaA34YUNnvVlMUkQDFj6kqNJ0zcnVswbSGa/h5HZ9nsjMCIJ/ZjcqhNOdQr2LPyrW8m07aRH3SdS5BTGbL2IdoFVX8g==";

    fn b64(text: &str) -> Vec<u8> {
        BASE64.decode(text).unwrap()
    }

    fn sample_track(id: &str, title: &str, artist: &str) -> awake_core::Track {
        serde_json::from_value(serde_json::json!({
            "id": id, "title": title, "artist": artist, "album_artist": artist,
            "album": "测试专辑", "genre": "ambient", "year": 2024,
            "track_number": 1, "disc_number": 1, "duration": 225.0,
            "sample_rate": 48000, "bit_depth": 24, "channels": 2, "codec": "flac",
            "source_id": "src", "locator": format!("{id}.flac"), "file_size": 1,
            "modified": 0, "artwork_path": null, "play_count": 0, "favorite": false,
            "last_played": null, "added_at": 0, "is_remote": false
        }))
        .unwrap()
    }

    fn test_payload() -> BackupPayload {
        let mut snapshot = LibrarySnapshot::default();
        snapshot
            .tracks
            .push(sample_track("t1", "Yellow", "Coldplay"));
        snapshot
            .sources
            .push(MediaSource::new(SourceKind::Local, "本地", "/music"));
        let mut taste = Taste::default();
        taste.playlists.push(Playlist {
            id: "p1".into(),
            name: "通勤".into(),
            prompt: String::new(),
            source_ids: vec![],
            track_ids: vec!["t1".into()],
            smart: false,
            entries: Vec::new(),
        });
        taste.favorites.insert("t1".into());
        BackupPayload {
            schema: SCHEMA_MACOS.into(),
            version: VERSION,
            exported_at_ms: 1_790_000_000_000,
            device: "MacBook".into(),
            app_version: "0.7.0".into(),
            library: snapshot,
            taste: Some(taste),
            playback: Some(PlaybackSnapshot {
                title: "Yellow".into(),
                artist: "Coldplay".into(),
                album: "Parachutes".into(),
                duration: 225.0,
                position: 42.5,
            }),
        }
    }

    fn temp_dir(name: &str) -> PathBuf {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "awake-backup-{name}-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn fixed_vector_encrypts_and_decrypts_like_the_ios_side() {
        let salt = b64(VECTOR_SALT);
        let nonce = b64(VECTOR_NONCE);
        let expected = b64(VECTOR_DATA);
        let sealed = seal(VECTOR_PASSWORD, &salt, &nonce, VECTOR_PAYLOAD.as_bytes()).unwrap();
        assert_eq!(sealed, expected, "同一 salt/nonce 必须得到同一 ciphertext");
        let opened = open(VECTOR_PASSWORD, &salt, &expected).unwrap();
        assert_eq!(String::from_utf8(opened).unwrap(), VECTOR_PAYLOAD);
    }

    #[test]
    fn documented_envelope_decrypts_to_the_documented_payload() {
        let envelope = Envelope {
            format: FORMAT.into(),
            version: VERSION,
            kdf: KDF.into(),
            iterations: ITERATIONS,
            salt: VECTOR_SALT.into(),
            cipher: CIPHER.into(),
            data: VECTOR_DATA.into(),
        };
        let text = serde_json::to_string_pretty(&envelope).unwrap();
        let parsed = parse_envelope(&text).unwrap();
        let plaintext = open_envelope(VECTOR_PASSWORD, &parsed).unwrap();
        assert_eq!(String::from_utf8(plaintext).unwrap(), VECTOR_PAYLOAD);
        assert_eq!(parsed.iterations, 310_000);
        assert_eq!(parsed.format, "awake-e2e");
    }

    #[test]
    fn envelope_roundtrip_keeps_library_taste_and_playback() {
        let payload = test_payload();
        let plaintext = serde_json::to_vec(&payload).unwrap();
        let salt = [7u8; SALT_LEN];
        let nonce = [9u8; NONCE_LEN];
        let text = envelope_text(VECTOR_PASSWORD, &salt, &nonce, &plaintext).unwrap();
        let envelope = parse_envelope(&text).unwrap();
        let decrypted = open_envelope(VECTOR_PASSWORD, &envelope).unwrap();
        let restored: BackupPayload = serde_json::from_slice(&decrypted).unwrap();
        assert_eq!(restored.schema, SCHEMA_MACOS);
        assert_eq!(restored.library.tracks.len(), 1);
        assert_eq!(restored.library.tracks[0].title, "Yellow");
        let taste = restored.taste.unwrap();
        assert_eq!(taste.playlists.len(), 1);
        assert_eq!(taste.favorites.len(), 1);
        assert_eq!(restored.playback.unwrap().position, 42.5);
    }

    #[test]
    fn wrong_password_and_tampering_share_one_safe_error() {
        let salt = [1u8; SALT_LEN];
        let nonce = [2u8; NONCE_LEN];
        let data = seal(VECTOR_PASSWORD, &salt, &nonce, b"secret").unwrap();
        assert_eq!(
            open("Awake-test-124", &salt, &data).unwrap_err(),
            ERR_PASSWORD
        );
        let mut tampered = data.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 0x01;
        assert_eq!(
            open(VECTOR_PASSWORD, &salt, &tampered).unwrap_err(),
            ERR_PASSWORD
        );
        assert_eq!(
            open(VECTOR_PASSWORD, &salt, &data[..10]).unwrap_err(),
            ERR_PASSWORD
        );
        assert_eq!(parse_envelope("not a backup").unwrap_err(), ERR_FORMAT);
        let wrong_iterations = parse_envelope(
            &serde_json::to_string(&Envelope {
                format: FORMAT.into(),
                version: VERSION,
                kdf: KDF.into(),
                iterations: 1,
                salt: VECTOR_SALT.into(),
                cipher: CIPHER.into(),
                data: VECTOR_DATA.into(),
            })
            .unwrap(),
        );
        assert_eq!(wrong_iterations.unwrap_err(), ERR_FORMAT);
        assert_eq!(
            parse_envelope("{\"format\":\"awake-e2e\"}").unwrap_err(),
            ERR_FORMAT
        );
    }

    #[test]
    fn cross_platform_schema_is_rejected_with_a_clear_message() {
        let mut payload = test_payload();
        payload.schema = SCHEMA_IOS.into();
        let error = validate_restore_payload(&payload).unwrap_err();
        assert!(error.contains("iPhone"), "{error}");
        assert!(error.contains("请在"), "{error}");
        assert!(error.contains("歌单导入"), "{error}");
        payload.schema = SCHEMA_MACOS.into();
        assert!(validate_restore_payload(&payload).is_ok());
        payload.schema = "unknown.format".into();
        assert_eq!(validate_restore_payload(&payload).unwrap_err(), ERR_FORMAT);
        payload.schema = SCHEMA_MACOS.into();
        payload.version = 2;
        assert!(validate_restore_payload(&payload).is_err());
    }

    #[test]
    fn export_never_carries_source_tokens() {
        let mut snapshot = LibrarySnapshot::default();
        let mut source = MediaSource::new(SourceKind::Telegram, "频道", "https://t.me/x");
        source.token = "secret-token".into();
        source.username = "me".into();
        snapshot.sources.push(source);
        let clean = sanitize_snapshot(&snapshot);
        assert!(clean.sources[0].token.is_empty());
        assert_eq!(clean.sources[0].username, "me");
        assert_eq!(snapshot.sources[0].token, "secret-token");
    }

    #[test]
    fn restore_writes_safety_copy_then_replaces_both_files() {
        let dir = temp_dir("restore");
        let old_library: &[u8] = br#"{"tracks":[],"sources":[],"scanned_at":null}"#;
        let old_taste: &[u8] =
            br#"{"events":[],"favorites":[],"playlists":[],"sound_profiles":{},"briefs":[]}"#;
        fs::write(dir.join("library.json"), old_library).unwrap();
        fs::write(dir.join("taste.json"), old_taste).unwrap();
        let payload = test_payload();
        let taste = payload.taste.clone().unwrap();
        let safety = restore_files(&dir, &payload.library, &taste).unwrap();
        assert!(safety.starts_with(dir.join("backups")));
        assert_eq!(fs::read(safety.join("library.json")).unwrap(), old_library);
        assert_eq!(fs::read(safety.join("taste.json")).unwrap(), old_taste);
        let restored: LibrarySnapshot =
            serde_json::from_slice(&fs::read(dir.join("library.json")).unwrap()).unwrap();
        assert_eq!(restored.tracks.len(), 1);
        let restored_taste: Taste =
            serde_json::from_slice(&fs::read(dir.join("taste.json")).unwrap()).unwrap();
        assert_eq!(restored_taste.playlists.len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn failed_restore_rolls_the_library_back() {
        let dir = temp_dir("rollback");
        let old_library: &[u8] = br#"{"tracks":[],"sources":[],"scanned_at":null}"#;
        fs::write(dir.join("library.json"), old_library).unwrap();
        // taste.json 是目录：rename 无法覆盖，模拟提交阶段失败。
        fs::create_dir(dir.join("taste.json")).unwrap();
        let payload = test_payload();
        let taste = payload.taste.clone().unwrap();
        let error = restore_files(&dir, &payload.library, &taste).unwrap_err();
        assert!(error.contains("回滚"), "{error}");
        assert_eq!(fs::read(dir.join("library.json")).unwrap(), old_library);
        let _ = fs::remove_dir_all(&dir);
    }
}
