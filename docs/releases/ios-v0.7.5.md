# Awake iOS 0.7.5

Awake 的原生 iPhone / iPad 测试版，最低 **iOS 17**。

**下载 Assets 中的 `Awake-0.7.5-ios-arm64-unsigned.ipa`。这是未签名的真机 ARM64 Release 包，需要自行重签后安装。** 本次通过 GitHub 分发，不属于 App Store / TestFlight 分发包。

## 整理封面、歌词与乐评

- 长按曲目，或从正在播放页进入“整理封面、歌词与乐评”。
- 封面：读取内嵌图片、同名图片和目录封面，可手动导入图片；缺少图片时按标题稳定生成抽象配图，可选夜色、山林、琥珀、暮色风格。
- 歌词：支持内嵌歌词、同名 `.lrc`、`.lyrics.txt`、UTF-8 文本导入和手动修正；同步歌词可在播放页点击跳转。
- 听众乐评：接入 CritiqueBrainz 公开 API，区分单曲与专辑乐评，保留作者、平台、原链接和许可；也可导入自己的评论 JSON。
- 名称与来源：编辑显示名称、艺人、专辑、来源说明和文件名建议，清理音质标记并保留 Live / Remix 等版本信息；支持恢复原始信息。
- 保存后重新扫描仍保留确认过的资料；真实来源 ID、原始位置和音频文件不变，不回写标签、不重命名文件。

在线查询只在用户主动操作时发起，使用 MusicBrainz、Cover Art Archive、LRCLIB 和 CritiqueBrainz 的公开 API；不上传音频、原始路径或来源凭据。MusicBrainz 暂不可用时回退到独立的歌词候选，不会用未确认的结果替换已有封面和乐评。

## 个人媒体库（0.7.4 起）

设置 → 添加 Telegram 个人媒体库，通过用户自托管连接器选择收藏夹、指定频道或聊天文件夹中的频道；支持 JSON/XML/TXT 个人连接配置导入，配置导入只填表，密码与令牌另存钥匙串。iPhone 首次播放先下载并校验，再进入统一 EQ 链路；另支持一次性导入本地或 Telegram 已下载的音频文件夹。

连接器必须由用户在自己的电脑或 NAS 上运行，iPhone 不能使用电脑的 `127.0.0.1` 地址。[连接器说明](../../Tools/telegram_connector/README.md)。

## 安装、升级与验证

- 请保留并备份自己的曲库与配置；重签时保持 Bundle ID、签名及安装方式一致，能否保留沙盒数据取决于所用工具。
- 27 项 iOS 单元检查通过（1 项需要连接器夹具的旧测试跳过），“编辑资料 → 保存 → 继续播放原音频”的界面流程通过；IPA 的版本、架构、资源、CRC 与 SHA-256 已校验。
- 未做实体 iPhone 蓝牙 / 长期后台 / 触觉反馈验收；未使用真实 Telegram 账号、付费 AI 或真实 NAS。真实接口联调时 MusicBrainz 返回 503，已按回退流程处理，完整真实专辑的封面匹配仍受服务可用性影响。
- 桌面版同步发布 0.6.2，详见 [桌面发行说明](v0.6.2.md)。

[安装与功能说明](https://github.com/sevenaaaaaaaaa/awake/blob/ios-v0.7.5/ios/README.md) · [资料整理说明](https://github.com/sevenaaaaaaaaa/awake/blob/ios-v0.7.5/docs/media-information.md) · [验证记录](https://github.com/sevenaaaaaaaaa/awake/blob/ios-v0.7.5/docs/validation-media-information.log)

Assets 同时提供 `SHA256SUMS`。下载到同一目录后可运行 `shasum -a 256 -c SHA256SUMS` 验证。
