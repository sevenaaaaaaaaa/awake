//! 凭据存储：应用自己的文件（0600）为主，系统钥匙串为镜像。
//!
//! 为什么不能只写钥匙串：macOS 把钥匙串条目的 ACL 绑在「访问者」的代码签名上。
//! Awake 用 `codesign --force --deep --sign -` 打 ad-hoc 签名，每次重新构建
//! cdhash 都会变，上一版写进去的条目对新版本来说就是「别的程序」的条目 ——
//! 用户看到的就是「每次装完，Plex 登录和来源密码都没了」。
//!
//! 所以：真正的主存储是 `<data_dir>/credentials.json`（权限 0600，位于用户自己的
//! Application Support 目录），钥匙串能写就再写一份镜像。读的时候文件优先；
//! 文件没有再看钥匙串，并把从钥匙串读到的旧值顺手迁移进文件。
//!
//! 这条链路只碰两个地方：数据目录里的一个 JSON 文件，和钥匙串里 service 为
//! `com.seven.awake` 的条目。凭据从不出现在 library.json、日志或前端响应里。
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

const SERVICE: &str = "com.seven.awake";
const STORE: &str = "credentials.json";

static ROOT: Mutex<Option<PathBuf>> = Mutex::new(None);
/// 串行化写入，避免两个来源同时连接时互相覆盖文件。
static WRITE_LOCK: Mutex<()> = Mutex::new(());
static KEYCHAIN_MIRROR: AtomicBool = AtomicBool::new(true);

/// 指定凭据文件所在的数据目录。启动时调用一次；测试里可以改指临时目录。
pub fn init(dir: &Path) {
    if let Ok(mut root) = ROOT.lock() {
        *root = Some(dir.to_path_buf());
    }
}

/// 关闭/开启钥匙串镜像。测试里关掉，避免在无人值守的环境里弹系统授权框。
#[cfg(test)]
pub fn set_keychain_mirror(enabled: bool) {
    KEYCHAIN_MIRROR.store(enabled, Ordering::Relaxed);
}

fn keychain_enabled() -> bool {
    KEYCHAIN_MIRROR.load(Ordering::Relaxed)
}

fn store_path() -> Option<PathBuf> {
    ROOT.lock().ok()?.as_ref().map(|dir| dir.join(STORE))
}

/// 读出整个凭据表。文件缺失、损坏都当空表处理 —— 宁可让用户重连一次，
/// 也不要把已经存在的文件删掉。
fn read_store() -> BTreeMap<String, String> {
    let Some(path) = store_path() else {
        return BTreeMap::new();
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return BTreeMap::new();
    };
    serde_json::from_str::<BTreeMap<String, String>>(&text).unwrap_or_default()
}

fn write_store(map: &BTreeMap<String, String>) -> Result<(), String> {
    let Some(path) = store_path() else {
        return Err("凭据存储尚未初始化".into());
    };
    let _guard = WRITE_LOCK.lock().map_err(|_| "凭据存储繁忙".to_string())?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|_| "无法创建凭据目录".to_string())?;
    }
    let json = serde_json::to_string_pretty(map).map_err(|_| "凭据序列化失败".to_string())?;
    let tmp = path.with_extension("json.tmp");
    {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&tmp)
            .map_err(|_| "无法写入凭据文件".to_string())?;
        use std::io::Write;
        file.write_all(json.as_bytes())
            .map_err(|_| "无法写入凭据文件".to_string())?;
        file.sync_all().ok();
    }
    std::fs::rename(&tmp, &path).map_err(|_| "无法提交凭据文件".to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn keychain_set(account: &str, secret: &str) -> Result<(), String> {
    security_framework::passwords::set_generic_password(SERVICE, account, secret.as_bytes())
        .map_err(|_| "无法写入系统钥匙串".to_string())
}

#[cfg(target_os = "macos")]
fn keychain_get(account: &str) -> Result<String, String> {
    security_framework::passwords::get_generic_password(SERVICE, account)
        .map_err(|_| "钥匙串里没有这条凭据".to_string())
        .and_then(|bytes| String::from_utf8(bytes).map_err(|_| "凭据编码无效".into()))
}

#[cfg(target_os = "macos")]
fn keychain_remove(account: &str) {
    let _ = security_framework::passwords::delete_generic_password(SERVICE, account);
}

#[cfg(not(target_os = "macos"))]
fn keychain_set(_: &str, _: &str) -> Result<(), String> {
    Err("当前平台尚未配置系统凭据存储".into())
}
#[cfg(not(target_os = "macos"))]
fn keychain_get(_: &str) -> Result<String, String> {
    Err("当前平台尚未配置系统凭据存储".into())
}
#[cfg(not(target_os = "macos"))]
fn keychain_remove(_: &str) {}

/// 保存一条凭据。返回 Err 只在「文件也写不进去」时发生；钥匙串写失败不算失败，
/// 因为主存储是文件。
pub fn set(account: &str, secret: &str) -> Result<(), String> {
    let mut map = read_store();
    map.insert(account.to_string(), secret.to_string());
    write_store(&map)?;
    if keychain_enabled() {
        let _ = keychain_set(account, secret);
    }
    Ok(())
}

/// 读取一条凭据：文件优先，其次钥匙串（并把旧值迁移进文件）。
pub fn get(account: &str) -> Result<String, String> {
    if let Some(secret) = read_store().get(account) {
        if !secret.is_empty() {
            return Ok(secret.clone());
        }
    }
    if keychain_enabled() {
        if let Ok(secret) = keychain_get(account) {
            if !secret.is_empty() {
                // 迁移：下一次重装之后这条凭据仍然可用。
                let mut map = read_store();
                map.insert(account.to_string(), secret.clone());
                let _ = write_store(&map);
                return Ok(secret);
            }
        }
    }
    Err("来源凭据不可用，请重新连接来源".to_string())
}

/// 这条凭据是否存在（不读出内容）。
pub fn has(account: &str) -> bool {
    read_store()
        .get(account)
        .is_some_and(|secret| !secret.is_empty())
}

pub fn remove(account: &str) -> Result<(), String> {
    let mut map = read_store();
    if map.remove(account).is_some() {
        write_store(&map)?;
    }
    if keychain_enabled() {
        keychain_remove(account);
    }
    Ok(())
}

/// 测试串行闸门：凭据存储是进程级的单例，多个用例并行跑会互相改指向。
#[cfg(test)]
pub(crate) fn test_guard() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "awake-vault-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn credentials_survive_a_restart_without_the_keychain() {
        // 这条用例守着「重装后登录丢失」的根因：把钥匙串整个关掉，
        // 凭据仍然必须能从数据目录读回来。
        let _guard = test_guard();
        set_keychain_mirror(false);
        let dir = temp_dir("restart");
        init(&dir);
        set("awake.test-source", "secret-token").unwrap();
        assert_eq!(get("awake.test-source").unwrap(), "secret-token");
        assert!(has("awake.test-source"));
        // 模拟重启：重新 init 到同一个目录，内存里什么都不留。
        init(&dir);
        assert_eq!(get("awake.test-source").unwrap(), "secret-token");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn credential_file_is_private() {
        let _guard = test_guard();
        set_keychain_mirror(false);
        let dir = temp_dir("perms");
        init(&dir);
        set("awake.test-perm", "x").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(dir.join(STORE)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600, "凭据文件的权限必须是 0600");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn remove_and_missing_keys_are_reported() {
        let _guard = test_guard();
        set_keychain_mirror(false);
        let dir = temp_dir("remove");
        init(&dir);
        set("awake.test-gone", "y").unwrap();
        remove("awake.test-gone").unwrap();
        assert!(!has("awake.test-gone"));
        assert!(get("awake.test-gone").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_corrupt_store_does_not_panic_or_delete_peers() {
        let _guard = test_guard();
        set_keychain_mirror(false);
        let dir = temp_dir("corrupt");
        init(&dir);
        std::fs::write(dir.join(STORE), b"not json").unwrap();
        assert!(get("awake.test-x").is_err());
        set("awake.test-y", "z").unwrap();
        assert_eq!(get("awake.test-y").unwrap(), "z");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
