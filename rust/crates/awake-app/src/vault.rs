//! Credentials remain in the OS vault, never in library.json or frontend responses.
#[cfg(target_os = "macos")]
pub fn set(account: &str, secret: &str) -> Result<(), String> {
    security_framework::passwords::set_generic_password(
        "com.seven.awake",
        account,
        secret.as_bytes(),
    )
    .map_err(|_| "无法写入系统钥匙串".into())
}
#[cfg(target_os = "macos")]
pub fn get(account: &str) -> Result<String, String> {
    security_framework::passwords::get_generic_password("com.seven.awake", account)
        .map_err(|_| "来源凭据不可用，请重新连接来源".to_string())
        .and_then(|s| String::from_utf8(s).map_err(|_| "凭据编码无效".into()))
}
#[cfg(not(target_os = "macos"))]
pub fn set(_: &str, _: &str) -> Result<(), String> {
    Err("当前平台尚未配置系统凭据存储".into())
}
#[cfg(not(target_os = "macos"))]
pub fn get(_: &str) -> Result<String, String> {
    Err("当前平台尚未配置系统凭据存储".into())
}
