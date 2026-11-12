# Awake iOS 0.7.8

Awake 的原生 iPhone / iPad 测试版，最低 **iOS 17**。

**下载 Assets 中的 Awake-0.7.8-ios-arm64-unsigned.ipa。这是未签名的真机 ARM64 Release 包，需要自行重签后安装。** 本次通过 GitHub 分发，不属于 App Store / TestFlight 分发包。

## 接力到电脑

- 正在播放页新增「接力到电脑」：手机会发现同一 Wi-Fi 下正在接收的电脑（也可手动输入 host:port）。
- 在电脑端「数据与接力 → 手机接力」点「接收接力」，会显示 6 位配对码；手机输入后发送曲目与当前进度。
- 电脑匹配本地曲目后沿用当前音量与 EQ，并 seek 到手机上的进度继续播放；只传曲名/艺人/专辑/时长与进度，不传音频、账号或 Token。
- 配对码只存在内存、成功后清空；仅局域网；电脑端 10 分钟无请求自动过期。

## 加密备份与恢复

- 设置 →「备份与恢复」：创建端到端加密备份（密码 ≥8 两次一致），文件可存入文件 App / iCloud Drive；恢复时选择备份、输入密码、预览设备/时间/曲目/歌单/收藏，再确认。
- 加密：PBKDF2-HMAC-SHA256（310,000 次）+ AES-256-GCM；密码不保存。备份包含曲库元数据、歌单、收藏、配置与上次播放进度；不包含音频文件与钥匙串里的密码/Token。
- 恢复前自动保留当前 library.json 的 .before-restore 副本；只接受 iOS 备份，桌面备份会提示到桌面恢复（跨平台只支持歌单导入）。
- 恢复后显示“上次播放（m:ss）”，可点「继续播放」在匹配曲目上 seek，不自动播放。

## 验证

- 单元测试 64 项通过（新增备份 7 项、接力 11 项）：固定加密向量与桌面端逐字节一致、roundtrip/恢复、错误密码与篡改统一报错、schema 拒绝、失败恢复不破坏曲库；接力请求体 ≤8 KB、仅局域网、响应 401/429/未匹配文案、发送契约。
- 未签名 IPA 0.7.8（build 15）构建通过，需自行重签。

## 未验证

- 真实 iPhone + Mac 的 mDNS 发现、Local Network 授权弹窗与真实 HTTP 往返；电脑端需点开「接收接力」配合验证。
- 真机上的分享面板、文件选择器、恢复预览与「继续播放」点击流程；浅色皮肤/大字号下的布局。
- 不支持把平台受保护音频（Apple Music DRM 等）纳入备份或播放。

[0.7.7 发行说明](ios-v0.7.7.md) · [安装与功能说明](https://github.com/sevenaaaaaaaaa/awake/blob/ios-v0.7.8/ios/README.md) · [备份格式](https://github.com/sevenaaaaaaaaa/awake/blob/ios-v0.7.8/docs/backup-format.md)

Assets 同时提供 SHA256SUMS。下载到同一目录后可运行 shasum -a 256 -c SHA256SUMS 验证。
