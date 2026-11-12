# Awake iOS 0.7.7

Awake 的原生 iPhone / iPad 测试版，最低 **iOS 17**。

**下载 Assets 中的 `Awake-0.7.7-ios-arm64-unsigned.ipa`。这是未签名的真机 ARM64 Release 包，需要自行重签后安装。** 本次通过 GitHub 分发，不属于 App Store / TestFlight 分发包。

## 刷音乐（只在正在播放页进入）

- 正在播放页新增「刷音乐」，不是底部主页面入口；没有正在播放的曲目时不会出现。
- **上下模式**：上滑下一首、下滑上一首；轻点暂停/继续。
- **卡片模式**：卡片叠放，右滑「喜欢」并切到下一首，左滑「跳过」，上滑下一首、下滑上一首；拖动时显示喜欢/跳过标记。
- 两种模式都显示进度、收藏和暂停；尊重系统「减少动态效果」。
- 队列来自本地推荐排序并包含当前曲目；远程曲目在切换时先缓存到本机再播放。

## 导入其他平台歌单

设置路径：曲库 →「导入歌单」。流程是**只取歌单元数据 → 与本地曲库匹配 → 生成歌单**，不下载或播放平台版权音频。

- **网易云音乐**：走 `/api/v6/playlist/detail` 取全量 `trackIds`，再分批读 `/api/song/detail`（旧版接口只给 10 首且曲目数会虚报，已避开）。
- **QQ 音乐**：公开歌单接口（需要 Referer；隐私歌单会明确提示 subcode 4000）。
- **YouTube / YouTube Music**：使用 `www.youtube.com` 页面，适配新版 `lockupViewModel`，并可用续页令牌翻完（实测 100 + 47）；视频标题会清洗括号、Official/Video 等后缀，并尽量拆出艺人。
- **Apple Music**：读取公开歌单页的 `serialized-server-data`，支持曲目、艺人、专辑（去掉 “ - Single/EP/Album” 后缀）与时长；页面被地区重定向时会明确提示。
- **Spotify**：读取公开嵌入页（上限 100 首；该主机可能限流，失败时提示改用粘贴文本）。
- **文件**：M3U / M3U8 / PLS / CSV / JSON / TXT。
- **粘贴文本**：每行「艺人 - 歌名」，适合在任何平台导出或复制后使用。
- 匹配按标题、艺人、时长打分，分为高置信度 / 较可能 / 低置信度；**未匹配的条目会列出**，可逐条手动从本地曲库选择，再创建歌单。
- 创建后的歌单显示在曲库顶部，点击播放，长按删除。

## CUE 整轨

- 解析 `FILE` / `TRACK` / `TITLE` / `PERFORMER` / `INDEX 01 mm:ss:ff`（75 帧/秒），按下一轨起点切分，末轨用整轨时长补齐。
- 需要整轨音频已经在曲库中；创建的是同一文件的虚拟分轨，不复制、不转码原文件。
- **APE 无法在 iOS 上解码**：会直接提示先用 FLAC / ALAC / WAV 转码；MP3 / AAC 的分轨有帧级误差。

## 验证

- 单元测试覆盖：文本 / M3U / CSV / JSON 解析、CUE 段落与末轨时长、匹配评分与未匹配提示、YouTube 标题清洗与时长解析、歌单与曲目片段持久化。
- 在线集成（`AWAKE_PLAYLIST_INTEGRATION=1`）：网易云公开歌单取到全量曲目（>10，验证 trackIds 路径）、QQ、YouTube、Apple Music 均返回曲目并通过断言。
- 界面测试：正在播放 →「刷音乐」进入、上下/卡片切换与滑动、关闭回到播放页；曲库 →「导入歌单」打开与关闭。
- 全量 iOS 测试 48 项通过（** TEST SUCCEEDED **），另含 WebDAV 行为矩阵回归。

## 限制

- 平台公开数据可能变动或限流：Spotify 会触发主机级限流；Apple Music 跨区链接会被重定向；YouTube 渲染结构仍在变化。
- 所有平台公开响应都没有 ISRC，匹配只能靠曲名/艺人/时长。
- 未使用任何平台账号 Cookie 或 Token；私密歌单需要用户自行公开或改用粘贴文本。
- 未在实体 iPhone 上验证 SMB 共享导入、蓝牙与后台长播。

[安装与功能说明](https://github.com/sevenaaaaaaaaa/awake/blob/ios-v0.7.7/ios/README.md) · [验证记录](https://github.com/sevenaaaaaaaaa/awake/blob/ios-v0.7.7/docs/validation-ios-v0.7.7.log) · [0.7.6 发行说明](ios-v0.7.6.md)

Assets 同时提供 `SHA256SUMS`。下载到同一目录后可运行 `shasum -a 256 -c SHA256SUMS` 验证。
