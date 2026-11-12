# Awake iOS 0.7.6

Awake 的原生 iPhone / iPad 测试版，最低 **iOS 17**。

**下载 Assets 中的 `Awake-0.7.6-ios-arm64-unsigned.ipa`。这是未签名的真机 ARM64 Release 包，需要自行重签后安装。** 本次通过 GitHub 分发，不属于 App Store / TestFlight 分发包。

## 本地导入与打开方式

- 修复设置页“导入本地 / Telegram 下载文件夹”点击无反应：同一页面存在两个文件选择器导致冲突，现已为每个按钮绑定独立的文件选择器。
- 曲库工具栏新增“导入文件夹”，与“导入文件”并列；设置页新增“导入音频文件”。
- 从文件 App 选择“用 Awake 打开”音频时会直接导入（新增音频文档类型与 onOpenURL 处理）。
- iCloud Drive / 文件提供者的文件先用 `NSFileCoordinator` 触发下载再复制，减少“文件不存在 / 无权限”的导入失败。
- 导入时显示进度；成功后提示“已导入 N 首”，失败时给出具体文件与原因，不再静默。

## NAS / WebDAV 连接

- 局域网地址放行 HTTP：单段主机名（如 `http://diskstation:5005/dav`）、`.local`、私有 IPv4 与 IPv6 ULA 均可直接添加，不必先配 HTTPS。
- 跟随同源 301/302/307/308 重定向（最多 3 跳），跨站重定向仍拒绝，凭据不会带出服务器。
- 支持 Digest 认证（`qop=auth`、无 qop、MD5 / SHA-256），部分 NAS 默认使用 Digest。
- 新增“允许自签名 HTTPS 证书”开关，只对当前来源的主机生效，默认关闭；使用自签证书的 NAS 打开后即可连接。
- 单个条目或子目录返回 403/404 时跳过并继续；根目录失败、空目录、返回网页（非 WebDAV）都会给出明确中文提示和地址，不再只显示“来源返回 HTTP xxx”。
- 密码与 Token 仍只保存在钥匙串，只进入请求头。

## Plex 账号登录

- Plex 来源新增“用 Plex 账号登录”：在 Safari 中完成 Plex 授权（PIN 流程），自动获取 Token 与服务器列表，选中后填入服务器地址与 Token。
- Token 存入钥匙串；手动填写 Token 仍保留为兜底。
- 服务器优先选择 HTTPS，其次本地连接，最后中继。

## 文件 App 中的 NAS / 网盘

iOS 没有可直接挂载 SMB 的公开接口。请在文件 App 中连接服务器（“连接服务器” → `smb://NAS`），然后在 Awake 中导入该共享目录；导入后的文件保存在本机，进入统一 EQ 播放链路。

## 安装、升级与验证

- 请保留并备份自己的曲库与配置；重签时保持 Bundle ID、签名及安装方式一致。
- 本轮验证：iOS 单元测试与界面测试通过；WebDAV 行为矩阵（Basic / Digest / 同源重定向 / HTML 返回 / 部分 403 / 自签名 TLS）通过；自签名开关在未勾选时仍按系统默认拒绝证书。
- 未验证：真实 NAS 的 Digest + 自签名 + 重定向组合、真实 Plex 账号的完整服务器发现、实体 iPhone 上的 SMB 共享导入。
- 桌面版同步发布 0.6.3，详见 [桌面发行说明](v0.6.3.md)。

[安装与功能说明](https://github.com/sevenaaaaaaaaa/awake/blob/ios-v0.7.6/ios/README.md) · [验证记录](https://github.com/sevenaaaaaaaaa/awake/blob/ios-v0.7.6/docs/validation-ios-v0.7.6.log)

Assets 同时提供 `SHA256SUMS`。下载到同一目录后可运行 `shasum -a 256 -c SHA256SUMS` 验证。
