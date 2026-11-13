# Awake 0.8.1

**让好音乐，越来越合拍。** macOS 本地播放器：流式音频、后端连续队列、自有音乐来源、可解释的偏好学习，以及用户主动触发的 AI 策展和创作。

当前主线：Rust / Tauri 2 / Vue 3。Swift 实现保留作历史参考。

## 下载

- **[macOS 0.8.1 通用版（Apple 芯片 + Intel，ad-hoc 签名）](https://github.com/sevenaaaaaaaaa/awake/releases/tag/v0.8.1)**：同一个安装包同时支持 Apple Silicon 与 Intel Mac；解压后拖入“应用程序”，首次打开需在“隐私与安全性”中允许。[发行说明](docs/releases/v0.8.1.md)
- **[iOS 0.7.8 测试版（iOS 17+）](https://github.com/sevenaaaaaaaaa/awake/releases/tag/ios-v0.7.8)**：未签名 IPA，需自行重签安装。[发行说明](docs/releases/ios-v0.7.8.md)

## 0.8.1 · macOS 通用安装包与书架修复

安装包改为 **arm64 + x86_64 通用二进制**，Intel Mac 与 Apple Silicon 共用一个 Awake.app；构建脚本默认双架构编译并用 lipo 校验。修复 0.8.0 的书架遗漏：没有专辑标签的有声书按文件夹归并，应用自己生成的有声书 / 广播剧按来源归并，标题去掉任务 UUID 前缀。其余内容与 0.8.0 相同。详见 [0.8.1 发行说明](docs/releases/v0.8.1.md)。

## 0.8.0 · 听书、AI 拆书、新闻播报与本周总结

修复三条“看不到结果”的路径：Plex 授权后会列出服务器的全部线路（本地 / 远程 / 中继）并逐条探测，选中音乐库连接后直接显示曲目数；本地音乐支持原生多选文件、拖放导入、扫描进度与跳过原因；歌单导入的未匹配曲目会保存为待匹配条目，并在歌单页展示、随后自动重新匹配。

新增「听书与播报」：按书归并本地 / WebDAV / Plex / Telegram 的长音频，章节自然排序，记住每本书的章节与位置；AI 拆书 / 拆剧把文本分成章节，用 macOS 系统语音离线合成有声书或分角色广播剧；新闻链接、正文与 .eml 邮件可导入并生成 AI 新闻播报。另新增「本周总结」（时长 / 完整播放 / 艺人 / 每日柱状图 / 可解释文字）与固定的「为你生成」每日歌单。详见 [0.8.0 发行说明](docs/releases/v0.8.0.md)。

## 0.7.1 / iOS 0.7.8 · 播放接力与加密备份

手机正在播放时点「接力到电脑」，电脑在底部播放条的「数据与接力」里点「接收接力」，输入 6 位配对码即可在同一 Wi-Fi 下继续播放：电脑匹配本地曲目并沿用当前音量/EQ、seek 到手机进度。只传曲目元数据与进度，不传音频、账号或 Token；配对码 10 分钟过期、错 5 次换码。

双端新增端到端加密备份：PBKDF2-HMAC-SHA256（310,000 次）+ AES-256-GCM，密码不保存；备份曲库元数据、歌单、收藏、配置和上次播放进度（不含音频文件与钥匙串密码/Token）。桌面导出直接写入下载目录，恢复前自动保留安全副本；只接受本平台备份，跨平台只支持歌单导入。格式见 [备份格式](docs/backup-format.md)，接力协议见 [接力协议](docs/handoff-protocol.md)。

## 0.7.0 · 刷音乐与歌单导入（桌面）

底部播放条有当前曲目时出现「刷音乐」：上下模式用滚轮 / ↑↓ / 拖动切换，卡片模式用指针拖动左右抽卡（右滑喜欢、左滑跳过）。侧栏「我的歌单」新增导入：支持网易云、QQ 音乐、YouTube、Apple Music、Spotify、M3U / PLS / CSV / JSON / TXT 与 CUE；只取元数据并与本地曲库匹配，可勾选、只看未匹配、手动指定后创建歌单。在线实测网易云 305 首、QQ 76 首、YouTube 147 首（续页）、Apple Music 74 首、Spotify 50 首。CUE 已解析分段元数据，桌面分轨播放留待下一版（iOS 0.7.7 已支持）。详见 [桌面发行说明](docs/releases/v0.7.0.md)。

## iOS 0.7.7 · 刷音乐与平台歌单导入

正在播放页新增「刷音乐」：上滑下一首、下滑上一首，或切换成卡片模式左右抽卡（右滑喜欢、左滑跳过）；不是底部主页面入口。曲库新增「导入歌单」：支持网易云、QQ 音乐、YouTube、Apple Music、Spotify 公开页面，以及 M3U / PLS / CSV / JSON / TXT 与 CUE；只取元数据并与本地曲库匹配，未匹配条目可逐条手动指定，不下载平台音频。CUE 需要整轨已在曲库，APE 需先转 FLAC / ALAC。详见 [iOS 发行说明](docs/releases/ios-v0.7.7.md)。

## 0.6.3 / iOS 0.7.6 · 来源连接与 Plex 登录

修复 iOS 设置页“导入本地 / Telegram 下载文件夹”点击无反应：同一页面两个文件选择器冲突，现已拆成每个按钮独立选择器；曲库新增“导入文件夹”，并支持从文件 App 用 Awake 打开音频。导入显示进度、成功条数与失败原因，iCloud / 文件提供者先下载再复制。

NAS / WebDAV 现在接受局域网 HTTP（单段主机名、`.local`、私有 IP、IPv6 ULA），跟随同源重定向，支持 Digest 认证与“允许自签名 HTTPS 证书”开关（仅当前来源）；401/403/404/405 与返回网页都有可读提示，子目录 403 会跳过。Plex 支持账号登录（PIN + 浏览器授权）自动获取服务器与 Token，手动 Token 保留兜底。iOS 的 SMB 共享请先在文件 App 连接服务器再导入。详见 [iOS 发行说明](docs/releases/ios-v0.7.6.md) 与 [桌面发行说明](docs/releases/v0.6.3.md)。

## 0.6.2 / iOS 0.7.5 · 封面、歌词与乐评

新增“整理这份声音”：读取内嵌和相邻封面/歌词，手动导入图片和评论 JSON，预览在线候选，保存显示名称、来源说明及听众乐评。缺封面的录音使用可选风格的抽象配图；没有专辑信息的录音不再错误共用其他文件的封面。

在线资料通过 MusicBrainz、Cover Art Archive、LRCLIB 和 CritiqueBrainz 的公开 API 查询，用户主动触发，不上传音频或来源凭据。单曲与专辑乐评分开展示并保留署名、原链接及许可。编辑可恢复，重新扫描保留确认过的资料；文件名为整理建议，不直接重命名或回写原文件。[使用说明与边界](docs/media-information.md)。

## 0.6.1 / iOS 0.7.4 · 个人媒体源

桌面和 iOS 新增 Telegram 个人媒体库，通过用户自托管连接器选择收藏夹、指定频道或聊天文件夹中的频道；支持 JSON/XML/TXT 个人连接配置导入。桌面使用 HTTP Range 流式读取，iOS 首次下载到本机后进入原生 EQ。iOS 另支持一次性导入本地或 Telegram 已下载的音频文件夹。

连接器在用户自己的电脑或 NAS 上登录，播放器只保存其访问令牌。只读取显式选择的最近消息范围，不提供公共频道目录，不绕过内容保护；Telegram 曲目元数据排除在云端 AI 请求外。频道文字赞助消息可展示，带照片/媒体的赞助消息尚不支持，遇到时会明确拒绝远程接入。

[连接器部署、配置格式与当前限制](Tools/telegram_connector/README.md) · [本轮实现与验证](docs/telegram-media-libraries.md)。真实 Telegram 登录、用户 NAS 和频道授权仍需对应账号验收；本地协议夹具不代表真实服务验证。

## 历史：iOS 0.7.3

**[iOS 0.7.3 测试版发布页](https://github.com/sevenaaaaaaaaa/awake/releases/tag/ios-v0.7.3)**：iOS 17+，未签名 IPA，需自行重签安装。[发布说明](docs/releases/ios-v0.7.3.md)。

原生 iPhone / iPad 工程与可重签真机 IPA 已加入，包含文件导入、系统音频、链路 EQ、社区参数、主观评分、A/B、本地软件跑分、设备参数/调音倾向/场景建议和 AI 服务接口。详情、安装与移动端边界见 [iOS 说明](ios/README.md)。桌面版本仍为 0.6，iOS 不是桌面功能全部迁移完成的声明。

## 0.6 外观与聆听链路

“外观与皮肤”提供中性黑色、白色和玻璃三种主题、跟随系统及自定义皮肤。可调整 8 个语义颜色、圆角、密度、标题字体和模糊；导入/导出 `design.md`，最多保存 30 份社区皮肤，校验颜色和文字对比度。模板见 [design.md](design.md)。自由文字设计稿可主动调用已配置 AI 转为皮肤，结果先校验与预览，不执行模型返回的代码。

“声音实验室”新增聆听链路：按 CoreAudio UID 和传输方式识别输出，为耳机、连接模式、前端、ANC、耳套/耳垫分别记忆 EQ。支持在线查找 AutoEq 与已收录社区 PEQ、预览、绑定及 AI 比较。系统未公开的无线编码如实显示未知，编码偏好不代表强制切换。具体支持、用户常用型号核对和来源见[聆听链路说明](docs/listening-chains-v0.6.md)。

本轮实际读取了当前蓝牙输出的 UID/传输方式，并从公开来源下载解析 AirPods Pro 2、Pro 3、Galaxy Buds2 Pro 参数；没有使用付费 AI 服务。AI 解读皮肤与候选比较仍需配置真实账号后验收。上一轮五分钟音频验收记录保留于下方；本轮另做短声卡回归，不重复宣称五分钟测试已重新运行。

## 启动

```bash
npm ci --prefix ui
./Tools/build_rust_app.sh
open dist-rust/Awake.app
```

要求 macOS 14+、Rust/Cargo、Node/npm、Python 3 和 Xcode Command Line Tools。本地构建产物在 `dist-rust/Awake.app`，使用 ad-hoc 签名。构建脚本默认生成 **arm64 + x86_64 通用包**；需要安装 rustup 的 `x86_64-apple-darwin` 标准库（`rustup target add x86_64-apple-darwin`），并会自动显式使用 rustup stable 的 rustc（避免 Homebrew rust 只有宿主架构的问题）。

浏览器预览：`npm run dev --prefix ui`，访问 `http://127.0.0.1:1420`。浏览器可导入真实音频、播放、EQ 和本地歌单；原生流式队列、服务器连接、系统钥匙串、参数耳机校正和云端服务调用由桌面后端提供。浏览器导入音频仅存在于当前会话。

## 按计划实施的能力

| 阶段 | 本轮实现 | 验收边界 |
| --- | --- | --- |
| 长音轨 | 按包解码、分块 sinc 重采样、固定容量 SPSC PCM 环形缓冲，音频回调不做磁盘/网络读取 | 两小时稀疏 WAV 的首块和末尾跳转；五分钟实际 CoreAudio 静音输出与内存检查 |
| 连续播放 | 后端拥有完整队列，提前解码下一首，同一输出流接续；相同输入采样率共享重采样历史 | 连续 PCM 拆成两文件，在 44.1/48/96 kHz 输出下与整段逐样本比较；未做 DAC 硬件回环测量 |
| 声音处理 | 31 段 EQ、20ms 双滤波器交叉切换、音量渐变、级联余量；直接执行最多 16 个 PK/LS/HS 参数滤波器 | 参数响应和回调零分配测试；测量来源由用户提供，不自动认证耳机测量真实性 |
| 自有来源 | 本地目录、NAS/网盘挂载目录、WebDAV、Plex；远程文件使用 HTTP Range 按需读取 | WebDAV/认证/中文路径/Range/长文件跳转及 Plex 分页由本地协议服务验收，未使用用户真实服务器账号 |
| 来源刷新 | 应用运行时每 15 分钟后台更新，来源可关闭自动更新；失败保留旧索引，提交原子写入 | 自动目录更新、失败保留原曲库的回归测试 |
| 元数据订阅 | 用户填写 RSS/Atom，读取标题并匹配现有曲库，保存播放列表并定期更新 | 不跟随 enclosure/音频链接，不添加外部音频；歧义或没有匹配的条目留空 |
| AI 策展 | 可配置支持 Chat Completions JSON 输出的服务；发送有限候选和精简偏好，过滤虚构/重复 ID，HTTP/解析失败回退本地 | 本地 HTTP 契约测试；真实服务需用户自行配置模型和密钥 |
| AI 创作 | ElevenLabs Music HTTP 适配，描述/时长/纯音乐/风格偏好、任务状态、停止接收、音频验证、持久化和自动入库播放 | 已用本地 HTTP 音频响应验证保存和重播；未调用真实付费账号生成作品 |

这是一轮实现与软件验收，不代表已完成主观听感评测、所有真实 NAS/网盘产品适配或外部服务账号验收。

## 接入你自己的音乐

在“音乐来源 → 添加音乐来源”选择：

- **本地文件夹**：递归扫描内嵌标签与封面。
- **NAS / 已挂载网盘**：先在 Finder 或网盘客户端挂载，再选择 `/Volumes/...` 等目录。当前没有原生网盘 OAuth、网盘分享链接解析或 SMB 自动挂载。
- **WebDAV**：填写根目录 URL、账号和密码。支持 UTF-8、DAV 命名空间、目录递归和认证；服务器必须支持正确的 HTTP `206` / `Content-Range`。不支持 Range 的服务会明确报错，可改用挂载目录。
- **Plex**：填写自己的服务器地址与 Token；只扫描音乐资料库，分页读取曲目，用令牌请求原始文件。Token 放在请求头，不拼入资源 URL。
- **RSS / Atom 元数据匹配**：填写自己的订阅 URL 和名称，可选账号密码。只用标题与艺人信息匹配当前曲库，不下载其中的音频，不按音频链接扩展曲库。重名版本不自动猜测。删除生成的歌单也会取消对应订阅。

来源 URL 不接受内嵌账号、密码或查询参数；认证使用专用字段。远程请求不自动跨站重定向。后台失败显示在来源页面，已有曲目保留。

**产品边界**：只连接用户自行配置的来源，不提供公共源目录、社区源推荐或分享入口。请确认拥有来源与内容的使用权限，在授权范围内个人使用；不要制造、上传或传播侵权内容，请支持正版音乐。上述提示不把“个人使用”视为版权授权的替代。

## 耳机测量校正

“声音实验室 → 耳机测量校正 → 导入参数校正”：

1. 填写耳机型号、测量者/数据集出处、目标曲线。
2. 导入 AutoEQ / Equalizer APO 的参数文本，例如 `Filter 1: ON PK Fc 1000 Hz Gain -2 dB Q 1`。
3. 应用到当前设备，或在设备校正列表中切换/关闭。

支持 PK、LS、HS，最多 16 段；滤波器直接参与输出，不先粗略换成 31 段图形 EQ。无效频率、增益、Q、非有限值和未知滤波类型会被拒绝。当前按**设备 UID 与聆听链路**恢复听感；公开测量候选可查找和人工/AI 比较。测量数据独立认证、独占输出和响度匹配 A/B 仍未完成。曲线改善与否需要对应耳机和实际听感验证。

## AI 策展

在“听歌搭子”底部配置云端服务 Base URL、模型 ID、API 密钥。接口采用 Chat Completions JSON 输出；例如 Base URL 形式为 `https://api.openai.com/v1`，不要包含 `/chat/completions`。

勾选“本次使用云端策展”并主动点击选曲后，发送最多 80 个候选的曲名/艺人/专辑/风格、候选 ID 和精简偏好。**不发送来源服务器地址、文件路径、凭据或音频文件。**模型只能返回当前候选 ID；未知和重复 ID 被移除。HTTP/JSON/无有效候选失败时使用本地选曲，并显示回退提示。

日常收藏、来源刷新和反馈更新继续使用本地排序，避免自动产生付费请求。云端策展结果可存为静态歌单；如果改存动态歌单，后续自动更新由本地引擎执行，云端仅在主动选曲时调用。

接口依据 [OpenAI 官方 Chat Completions 文档](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) 实现。模型与 JSON 模式的可用性以用户配置的服务为准。

## AI 音乐创作

在“灵感工作室”配置 ElevenLabs Music 服务地址、模型和密钥。默认接口为 `https://api.elevenlabs.io/v1/music`；账号需具有对应音乐 API 权限。

用户主动点击“生成并保存音乐”后提交描述、时长（30/60/120/180 秒）、纯音乐选项和可选的实际听歌风格标签。生成可能按服务商规则收费；应用不会自动重试生成请求。

- 一次只运行一个生成任务；状态为 queued / running / completed / failed / cancelled / interrupted。
- 接收真实音频，限制大小，先写 `.part`，验证可解码，再提交音频文件。
- 成功作品加入“AI 原创作品”本地来源，可通过同一播放器试听、收藏、选入歌单。
- 保存 provider、模型、描述、文件路径和曲目 ID，保留作品来源。
- “停止接收”可停止本地接收与提交；已发送到服务端的请求仍可能执行和计费。
- 退出应用会中断尚未完成的生成；重启后标记 interrupted，不自动重复请求。当前不恢复服务端尚未返回的任务。

依据 [ElevenLabs Compose music 官方接口](https://elevenlabs.io/docs/api-reference/music/compose) 适配。未配置账号时保留真实的“未配置”状态；契约测试中的音频夹具不会写入用户作品库，也不会冒充生成作品。

## 音频与反馈结构

```text
本地文件 / 已配置服务器的 HTTP Range
    → 后台按包解码
    → 小块声道映射与 sinc 重采样（同采样率曲目共享历史）
    → 固定容量 SPSC PCM 队列，包含曲目边界和跳转代次
    → 音频回调：EQ / 参数校正 / 交叉切换 / 音量
    → cpal / 当前输出设备
```

- 本地 PCM 队列约 0.5 秒，远程最多约 2 秒，并有容量上限；内存不随曲目时长线性增长。解码包另有限制，重采样以小块输入处理。
- 同一队列保持输出设备格式；异采样率曲目转换到该格式。不能把文件采样率当作 DAC 实际输出规格。
- 音频回调使用非阻塞队列与 `try_lock`；不解码、不发 HTTP、不写文件、不分配堆内存。
- 跳转代次使旧缓冲失效，暂停和跳转不依赖前端计时器。
- 跳转后先丢弃旧代次 PCM，等待预缓冲就绪再恢复；接近 EOF 的短尾部不必凑足缓冲时长。远程首次启动预缓冲约 0.5 秒。
- 缓冲不足计数区分“中途等待后继续输出音频”的事件与正常 EOF 后的静音尾部。
- 频谱改为 3 个位置各约 2 秒的抽样分析，避免进入歌词舞台又把长音轨完整加载到内存。
- 收听时长依据实际送出的帧数；拖到末尾不会虚增时长，也不会仅凭“到达末尾”就学习偏好。有效收听阈值为曲长一半、最高 120 秒；未知时长使用 30 秒。

## 数据与凭据

目录：`~/Library/Application Support/com.seven.awake/`

- `library.json`：曲库；`artwork/`：本地封面。
- `taste.json`：最近 5,000 条收听事件、收藏、歌单、设备偏好、测量校正、订阅、创作任务与简报。
- `services.json`：服务地址、模型和系统凭据引用，**没有 API 密钥**。
- 外观和自定义皮肤保存在 WebView 本机存储；可用 `design.md` 导出备份。
- `generated/`：已经校验并保存的作品音频。

密码与 API 密钥写入 macOS 系统钥匙串；不会通过查询曲库/配置接口回传到前端。曲库和档案先写临时文件再原子替换；后台来源更新失败保留旧内容。损坏的听歌档案会保留恢复副本。

## 验证

0.8.1 本轮（桌面）：安装包改为 arm64 + x86_64 通用二进制，`lipo -info` 与 `codesign --verify` 通过；arm64 启动冒烟 `frontend_ready version=0.8.1`，x86_64 切片在 Rosetta + 独立 HOME 下启动冒烟同样通过；awake-core 42 项 + awake-app 73 项在发布工具链（Rust 1.95）下通过。详见[0.8.1 验证记录](docs/validation-v0.8.1.log)。

0.8.0 本轮（桌面）：听书书架 / 续听、AI 拆书与拆剧（系统语音离线合成 + 解码验证）、新闻与 .eml 播报、本周总结、Plex 多线路与分区、显式文件导入、歌单待匹配条目；awake-core 42 项 + awake-app 73 项通过（10 项按需忽略），前端生产构建与打包启动冒烟通过。详见[0.8.0 验证记录](docs/validation-v0.8.0.log)。

0.7.0 本轮（桌面）：刷音乐全窗口两种模式、平台歌单导入与本地匹配；离线 51 + 37 项测试通过，在线 5 个平台真实歌单全部通过（网易云 305 / QQ 76 / YouTube 147 / Apple 74 / Spotify 50）。详见[桌面 0.7.0 验证记录](docs/validation-v0.7.0.log)。CUE 分轨播放在桌面留待下一版。

0.7.7 本轮（iOS）：刷音乐两种模式、平台歌单导入与本地匹配、CUE 虚拟分轨；单元测试覆盖解析/匹配/CUE，在线集成测试验证网易云全量曲目、QQ、YouTube、Apple Music 返回结果。详见[iOS 0.7.7 验证记录](docs/validation-ios-v0.7.7.log)。

0.6.3 / iOS 0.7.6 本轮：新增 WebDAV 行为矩阵（Basic / Digest / 同源重定向 / HTML 返回 / 部分 403 / 自签名 TLS）与 Plex 协议单元测试；Rust `awake-app` 31 项、`awake-core` 37 项通过，iOS 单元与界面测试通过（含四个导入选择器的呈现回归）。详见[iOS 验证记录](docs/validation-ios-v0.7.6.log)与[桌面验证记录](docs/validation-v0.6.3.log)。

0.6.2 / iOS 0.7.5 本轮：54 项 Rust 普通回归通过（awake-app 18 + awake-core 36，5 项真实声卡 / 长音轨测试按需单独运行），Vue / TypeScript 生产构建通过；iOS 27 项单元检查通过（1 项依赖连接器夹具的旧测试跳过），编辑资料后继续播放原音频的界面流程通过。详见[资料整理验证日志](docs/validation-media-information.log)与[个人媒体源验证日志](docs/validation-telegram.log)。

0.6 本轮：49 项普通回归通过（含本机 9 首演示音频），另行通过本地/远程真实输出、CoreAudio UID/传输读取及公开社区参数下载解析。外观已检查黑/白/玻璃、设计导入/导出、保存与重载、非法颜色拦截和 375px 页面溢出。详见 [0.6 验证日志](docs/validation-v0.6.log)。

```bash
npm run build --prefix ui
cargo test --manifest-path rust/Cargo.toml -p awake-core -p awake-app --lib

# 真实声卡回归：本地队列 + loopback HTTP Range，音量为零
cargo test --manifest-path rust/Cargo.toml -p awake-app --lib real_output -- --ignored --nocapture --test-threads=1

# 五分钟长音轨实际输出与 RSS 内存检查，音量为零
cargo test --manifest-path rust/Cargo.toml -p awake-app --lib five_minute_long_track -- --ignored --nocapture
```

本轮新增音频测试使用自生成 WAV、稀疏长音轨和本地 HTTP 服务，不依赖可选 DemoMusic。0.5 普通回归共 46 项通过；原有标签/FLAC 测试使用本机已有的 9 首演示音频实际运行。单独运行的真实声卡测试覆盖本地队列、暂停/跳转和 loopback HTTP Range 远程跳转，音量为零。原有标签/FLAC 测试在 DemoMusic 不存在时会提前返回，其他环境不应把这种返回算作真实格式验收。

0.5 的五分钟独立音频测试：实际输出 300.3 秒，首帧 445ms，0 次缓冲不足，进程 RSS 峰值 18,256KB，播放期间峰值增长 0KB。该数字属于独立测试进程，不能当作完整桌面应用、远程 TLS、所有格式和所有设备的通用指标。完整记录见[本轮验证日志](docs/validation-v0.5.log)。

最终构建与验收结果以本次任务输出为准。真实用户 NAS/Plex、各网盘原生 API、真实 AI 服务权限/费用和实际耳机听感仍需对应环境验收；本轮不会用模拟响应替代这些结论。

## 源码入口

- `rust/crates/awake-core/src/decode.rs`：流式解码和定位。
- `rust/crates/awake-core/src/pipeline.rs`：有界队列渲染和连续重采样。
- `rust/crates/awake-app/src/playback.rs`：输出回调、队列、遥测、暂停/定位。
- `rust/crates/awake-core/src/parametric.rs`：参数校正解析与滤波器响应。
- `rust/crates/awake-app/src/remote.rs`、`connections.rs`：来源、Range、自动刷新。
- `rust/crates/awake-app/src/feeds.rs`、`awake-core/src/feedmeta.rs`：元数据订阅与匹配。
- `rust/crates/awake-app/src/intelligence.rs`：云端策展、生成任务和作品入库。
- `ui/src/useAwake.ts`：真实状态同步和前端队列；`App.vue`：产品页面。

历史：[0.4 本地重建说明](docs/local-v0.4.md) · [0.3 历史说明](docs/legacy-v0.3.md)。
