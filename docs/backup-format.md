# Awake 加密备份格式（v1）

目标：本地生成、端到端加密的备份文件，用于同一平台的新设备/重装恢复。没有服务器，密码与明文都不离开设备。

## 容器格式

文件是 UTF-8 JSON（建议扩展名 .awake-backup）：

```json
{
  "format": "awake-e2e",
  "version": 1,
  "kdf": "pbkdf2-hmac-sha256",
  "iterations": 310000,
  "salt": "<base64(16 bytes)>",
  "cipher": "aes-256-gcm",
  "data": "<base64(nonce(12) || ciphertext || tag(16))>"
}
```

- 密码：UTF-8；最少 8 个字符（UI 校验）。
- 密钥：PBKDF2-HMAC-SHA256(password, salt, 310000, 32 bytes)。
- 加密：AES-256-GCM，随机 12 字节 nonce，16 字节 tag 追加在密文后；data 整体再 base64。
- 不把时间、设备名等元数据放在容器外层；它们只在解密后的 payload 里。
- 解密失败（密码错误/篡改）统一返回“密码错误或备份已损坏”，不要泄露细节。

## 测试向量（两端必须一致）

见仓库 docs/backup-vector.json：

- password: `Awake-test-123`
- salt(base64): `ABEiM0RVZneImaq7zN3u/w==`
- nonce(base64): `AAECAwQFBgcICQoL`
- iterations: 310000
- payload: `{"schema":"awake.backup.test","version":1,"message":"hello awake"}`
- 期望 data(base64): `AAECAwQFBgcICQoLMDUgbWvLP74LSIE1AHPmaA34YUNnvVlMUkQDFj6kqNJ0zcnVswbSGa/h5HZ9nsjMCIJ/ZjcqhNOdQr2LPyrW8m07aRH3SdS5BTGbL2IdoFVX8g==`

两端测试必须：用固定 salt/nonce 加密上述 payload 得到同一 data；并能解密该 envelope。

## 明文 payload

### iOS（schema = awake.backup.ios）

```json
{
  "schema": "awake.backup.ios",
  "version": 1,
  "exported_at_ms": 1790000000000,
  "device": "iPhone",
  "app_version": "0.7.8",
  "library": { /* 与 Documents/Awake/library.json 同结构 */ },
  "playback": {
    "title": "曲名", "artist": "艺人", "album": "专辑",
    "duration": 225.0, "position": 42.5
  }
}
```

### macOS（schema = awake.backup.macos）

```json
{
  "schema": "awake.backup.macos",
  "version": 1,
  "exported_at_ms": 1790000000000,
  "device": "MacBook",
  "app_version": "0.7.1",
  "library": { /* library.json */ },
  "taste": { /* taste.json */ },
  "playback": { "title": "...", "artist": "...", "album": "...", "duration": 225.0, "position": 42.5 }
}
```

## 恢复规则

- 只接受本平台 schema；其他平台给出“请在对应平台恢复”的明确错误（跨平台只支持歌单导入，不支持整体覆盖）。
- 恢复前先写安全副本（当前 library.json → backups/ 或同名 .before-restore 文件），返回其路径。
- 恢复时校验结构；失败不能破坏当前曲库。
- 不包含钥匙串里的密码/API 密钥/Token；恢复后需用户重新填写。音频文件不进入备份（只备份元数据与配置）。
- 备份文件本身不写入 App 数据目录以外；由用户通过分享/文件保存决定去向。

## 预览

inspect 只解密并返回：schema、version、exported_at_ms、device、tracks、playlists、favorites、bytes；不写入任何状态。
