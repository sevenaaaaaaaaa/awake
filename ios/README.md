# Awake iOS 0.8.1

本轮补齐 0.8.0 与桌面端的差距：Plex 多线路探测与音乐库分区、歌单待匹配条目持久化与详情页、文件夹归并听书、AI 拆书生成 m4a 有声书写入曲库、云端分章与新闻摘要、本周新增曲目/艺人榜。详见 [iOS 0.8.1 发行说明](../docs/releases/ios-v0.8.1.md) 与 [验证记录](../docs/validation-ios-v0.8.1.log)。安装包：`dist-ios/Awake-0.8.1-ios-arm64-unsigned.ipa`。

## 0.7.7 · 刷音乐与歌单导入

本轮新增「刷音乐」（仅从正在播放页进入，支持上下滑动与左右抽卡）与「导入歌单」（网易云 / QQ 音乐 / YouTube / Apple Music / Spotify 公开页面、M3U/PLS/CSV/JSON/TXT、CUE 虚拟分轨，并与本地曲库匹配）。详见[0.7.7 发行说明](../docs/releases/ios-v0.7.7.md)与[验证记录](../docs/validation-ios-v0.7.7.log)。本轮未签名安装包：`dist-ios/Awake-0.7.7-ios-arm64-unsigned.ipa`。

## 0.7.6 · 导入入口与来源连接

本轮修复导入入口并加强来源连接：设置页两个文件选择器冲突导致“导入文件夹”无反应，现改为每个按钮独立选择器；曲库新增“导入文件夹”，并支持从文件 App 用 Awake 打开音频。NAS / WebDAV 支持局域网 HTTP、同源重定向、Digest 认证与来源级“允许自签名证书”，错误提示带状态码与地址；Plex 支持账号登录获取服务器与 Token。详见[0.7.6 发行说明](../docs/releases/ios-v0.7.6.md)与[验证记录](../docs/validation-ios-v0.7.6.log)。

本轮未签名安装包：`dist-ios/Awake-0.7.6-ios-arm64-unsigned.ipa`，需要重签。

## 0.7.5 · 封面、歌词与乐评

长按曲目或在播放页面进入“整理封面、歌词与乐评”。支持内嵌图片/歌词、相邻资料、手动附件导入、公开 API 候选预览、乐评署名与许可、抽象配图、文件名建议和恢复原始信息。真实来源与音频路径保留，在线查询只在用户主动操作时发起。详情见[资料整理说明](../docs/media-information.md)。

## 0.7.4 · 个人媒体库接入

设置 → 添加 WebDAV / Plex / Telegram，新增 Telegram 个人连接器、收藏夹/频道/聊天文件夹选择和 JSON/XML/TXT 连接配置导入。配置导入只填充表单，不自动连接，密码与令牌另存钥匙串。设置中可一次性导入本地或 Telegram 已下载的音频文件夹。

Telegram 连接器由用户在自己的电脑或 NAS 运行，iPhone 使用该设备的地址；登录会话不进入 iPhone 或 Awake 服务器。远程音频首次播放先下载并校验，再进入现有 EQ 链路。支持的范围和部署方法见[连接器说明](../Tools/telegram_connector/README.md)。本版本构建产物为 `dist-ios/Awake-0.7.4-ios-arm64-unsigned.ipa`，须自行重签安装；旧发布记录保留于下方。

## 历史发布：iOS 0.7.3

原生 SwiftUI / AVAudioEngine iPhone 与 iPad 应用，最低 iOS 17。桌面 Rust/Tauri 主线保留。

## IPA

[GitHub 下载与发布说明](https://github.com/sevenaaaaaaaaa/awake/releases/tag/ios-v0.7.3)。公开附件包含未签名 IPA、SHA256SUMS 和安装说明。

交付路径：`../dist-ios/Awake-0.7.3-ios-arm64-unsigned.ipa`。

这是 **iPhoneOS ARM64 Release 真机包，未附带签名与描述文件**，不是模拟器 App。使用自己的重签工具、证书及对应描述文件签名后安装。当前环境有有效 Apple Development 证书，但 Xcode 没有登录开发者账号，未找到 `com.seven.awake.ios` 的 provisioning profile，因此没有把未签名包标为可直接安装。

源工程：`Awake.xcodeproj`，Scheme：`AwakeIOS`，Bundle ID：`com.seven.awake.ios`。

```bash
# 仓库根目录：生成真机归档与可重签 IPA
./Tools/build_ios_app.sh

# Xcode 账号和该 App 的签名配置就绪后，可构建并导出开发签名包
./Tools/build_ios_app.sh signed
```

签名导出的默认方法为 `debugging`，可通过 `AWAKE_IOS_EXPORT_METHOD` 设置为相应分发方式。团队与设备必须和签名描述文件匹配。

## 已实现

- 五个原生页面：为你、曲库、声音、评测、设置；系统原生文件选择、分享、AirPlay 路由选择。
- 文件 App 导入音频，复制到自己的沙盒并读取真实标签/时长/采样率。文件 App 可作为 NAS、iCloud Drive 和网盘入口。
- 长音轨按 AVAudioFile/AVAudioPlayerNode 调度，暂停、跳转、相同格式的连续队列；下一首提前排入同一节点。后台音频模式、锁屏播放信息和远程控制已接入系统 API。
- 31 段图形 EQ 与最多 16 段参数校正分成两个 Audio Unit；解析 PK / LS / LSC / HS / HSC，校验频率、增益、Q、前级和叠加余量。参数 Q 转换为 Apple AU 带宽，不能把它称为已认证的桌面 DSP 逐样本等价实现。
- 根据 AVAudioSession 公开的输出 UID 和端口类型选择链路；为耳机、连接、前端、ANC、耳套/耳垫保存独立配置。改变声学组合新建平直配置，不自动混用其他型号。
- AutoEq 查询与已收录的 Pro 3 社区拟合，保留来源和条件；不把旧款 Max 当作 Max 2，不伪造缺失测量。
- 用户自己的 WebDAV 和 Plex 音乐库扫描。认证使用请求头，凭据存系统钥匙串，拒绝跨站重定向。更新失败保留旧曲库。
- 黑色、白色、玻璃主题和 design.md / JSON 皮肤导入导出。采用和桌面兼容的声明式颜色/材质配置，校验格式与对比度。
- 本地收藏、有效收听累计、候选排序；主动触发的 Chat Completions 策展、反馈分析与 ElevenLabs Music 创作。云端只能选现有候选；失败回退本地，音乐完成后校验并保存。创作任务全局单实例，离开页面不会重复提交，重启中断不自动重试。

## 聆听实验室

### 用户主观反馈

清晰度、低频满意度、舒适度、疲劳感各 1–5 分，并保存文字备注、耳机链路、当时的 EQ 与测量来源和应用内收听累计。评分保存在本机，可主动导出 JSON。

同片段 A/B 随机分配原声与当前 EQ，在提交后揭晓。**未做响度匹配**，结果表示个人偏好，不能作为客观音质排名或严格 ABX 结论。

### 本地软件跑分

实际离线渲染 5 秒 / 48kHz / 双声道多频信号，记录帧数、耗时、实时倍速、峰值、RMS、削波和非有限采样。测试本身不播放声音。它衡量软件渲染和这次运行，不能测量耳机频响、DAC 失真、声压、耳道或蓝牙实际编码。

本地 Agent 根据本链路的反馈和软件结果给出可解释的建议；样本较少时不自动改 EQ。云端分析只在点击后发送型号、条件、评分摘要和软件结果，不发送音频、UID、音乐源凭据或反馈原文。

### 公开网络资料

当前接入的是有限、可追溯的公开测量目录与拟合方案，**不是“全网大数据”、人群统计或实物测量**。数据来源、ANC、耳套、音量与模型版本需要一起核对。同芯片/单元只作为记录了依据的参考试听线索。

来源及条件见 [桌面链路资料说明](../docs/listening-chains-v0.6.md)。

## 设备参数、调音倾向与使用场景（0.7.1）

入口：声音 → 配置耳机与连接 → 参数、调音倾向与使用场景。设置保留原调音、更均衡、人声优先、低频氛围或游戏定位，并记录当前问题。返回后点“保存”提交整个链路，取消会丢弃草稿。

- 原有 0.7.0 档案可直接读取。每次评分保存当前设备上下文快照；更换前端输出口或设备端音效模式会分出独立的平直链路。修改聆听目标与问题保留当前 EQ。
- 首批内置厂商资料：ATH-AD2000X、HD 600、Beats Studio Pro；前端为 FiiO KA13 的单端/平衡 × 桌面模式开/关，以及 DAWN PRO 的两种输出。核对日期 2026-11-11。这是少量来源明确的起始资料，并不代表所有在售型号。
- 型号只接受已列明的别名，不按“铁三角”“Beats”品牌名或同芯片匹配；系统端口名无法证实模拟耳机和前端工作模式。输出参数由用户确认。蓝牙/AirPlay 链路不使用小尾巴推力数据。
- 耳机标称阻抗与前端输出阻抗分别记录；灵敏度严格区分 dB/mW 与 dB/V。手动参数需附来源，任一手动数值填写后整体采用手动资料，避免把互不对应的测量拼接。90 dB SPL 的电压计算仅为工程参考，不是设备实测、音量映射或推荐音量。缺少相同负载/供电/失真条件，不推算最大响度。
- 厂商宣传、社区描述、个人听感分别标注来源。可以记录人声靠前、低频偏多、声场等倾向；这些描述用于形成可比较的建议，不转换为虚构的测量 EQ。未知参数保持未知。
- 本地 Agent 将设备资料、目标、具体问题与反馈结合，给出检查前级衰减、密封、双重音效、低频遮盖、延迟/HRTF 等建议。全部是试听建议，不会自动改系统编码、硬件增益或设备音效。
- 云端仍需主动触发与用户服务配置，新增只发送目标、问题、已核对的型号资料和公开链接；不发送手动来源、私人调音备注、UID 或音频。本轮未调用付费服务。

厂商来源：[FiiO KA13 参数](https://fiio.com/ka13_parameters)、[DAWN PRO](https://moondroplab.com/en/products/dawn-pro)、[ATH-AD2000X](https://www.audio-technica.com/en-us/ath-ad2000x)、[HD 600](https://us.sennheiser-hearing.com/products/hd-600)、[Studio Pro 支持](https://www.beatsbydre.com/support/headphones/studio-pro)。

## 主流耳机适配（0.7.2）

扩展为 75 个型号档案、18 个品牌分组，支持品牌筛选、中文/英文别名搜索、型号对应的音频入口和声学状态。覆盖 Sony、Bose、Sennheiser、Moondrop，以及 Apple、Samsung、Xiaomi/Redmi、Huawei、OPPO、OnePlus、vivo/iQOO、HONOR、realme、Google Pixel、Nothing；保留铁三角和 Beats。

“原道”保留版本登记入口，需进一步填写具体版本与条件。目录覆盖与实测 EQ 覆盖分开，缺失参数不猜测。测量查询已接通明确的型号别名，并检查代际、ANC 与模拟线条件；模拟耳机通过已绑定 USB 小尾巴使用的组合同样支持。

完整型号、来源与适用边界见 [主流耳机目录](../docs/mainstream-headphones-v0.7.2.md)。本轮 18 项原生测试、4 项界面测试通过，并抽查 Sony WH-1000XM6、Huawei FreeBuds Pro 4、Moondrop Chu 2、Redmi Buds 6 Pro 的公开参数文件下载。验证记录见 [0.7.2 验收日志](../docs/validation-ios-v0.7.2.log)。

## 音效动效与播放器标识（0.7.3）

成功应用音效后展示耳机/入耳图标、短波纹、旋转光环与曲线过渡，约 2.6 秒自动收起，不拦截触控。图形曲线与参数校正用于形成视觉示意，明确标注“参数示意”，不是实时频谱、精确滤波器传递函数或声学测量。拖动滑块时实时应用声音，松手后合并为一次动画；重复无变化的请求不反复展示。无效参数保留上一有效音效且不展示成功。

迷你播放器、正在播放页和声音实验室均提供可点开的状态标识：增强开启、暂停已就绪、EQ 旁路、原声。标识读取已配置的 Audio Unit 状态和实际生效频段，而非仅凭选中耳机或连接 AI。点开后可查看来源、前级、图形/校正频段数量，并用“恢复 EQ 增强／临时聆听原声”按钮切换。

来源区分手动、导入、公开测量与 AI。旧链路缺少来源类型时，参数文件按导入处理；来源为空的 AI 声明降为普通 EQ。现有云端反馈是文字建议，不会因为返回建议就显示 AI EQ。AI EQ 标识仅供明确记录 AI 来源且已实际应用的曲线使用，本轮没有新增或调用云端 AI 调参服务。

动效只在当前最上层页面展示，同一事件只播报一次，旧事件的清理不会关闭后来应用的新效果。系统“减少动态效果”时使用静态确认，正常播放标识不运行常驻动效或频谱采样。

本轮验收覆盖 21 项原生测试与 6 个界面流程（含最终播放页流程的针对性重跑）。[音效应用预览](../docs/ios-screenshots/effect-activation.png) · [播放器增强标识](../docs/ios-screenshots/player-enhancement.png) · [0.7.3 验证记录](../docs/validation-ios-v0.7.3.log)。

## 交付边界

- 当前远程文件首次播放先下载到本机，再进入统一 EQ 链路；未实现 iOS 远程即点即流、跨采样率真正无缝或 DSD/APE 转码。
- RSS/Atom 元数据订阅、桌面后台来源定时刷新、桌面档案自动同步尚未迁移到 iOS。当前手机来源由用户主动刷新。
- iOS 不提供这里所需的全部耳机状态；2.4GHz 接收器、模拟耳机、ANC 和佩戴条件需要用户绑定。编码偏好不会强制切换 AAC/LDAC/aptX 等编码。
- AI 服务需要用户自己的配置；本轮未调用真实付费 AI 服务，未生成并冒充真实 AI 作品。
- 已做模拟器、离线渲染与真机 ARM64 构建；本轮没有连接实体 iPhone 验证蓝牙、锁屏、来电中断或长时间后台播放。
- 测试音频仅在 Debug `--uitesting` 下生成并明确标为 QA；Release IPA 不自动放入示例曲目、听歌历史或评分。

## 数据与复现

用户文件位于应用的 `Documents/Awake/`：`library.json`、`Music/`。密码和密钥不进入 JSON。报告导出只包含评分与软件结果，由用户主动分享。iOS Keychain 密钥不与桌面钥匙串自动同步。

```bash
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/Awake.xcodeproj -scheme AwakeIOS \
  -destination 'platform=iOS Simulator,name=Awake iOS QA' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

0.7.0 基线通过 12 项原生测试和 2 项界面测试。覆盖参数/皮肤校验、来源边界、真实标签导入、链路独立持久化、创作中断与凭据绑定、5 秒离线渲染、暂停与连续队列、两小时稀疏音轨末尾跳转、评分保存及主题切换。模拟器离线渲染 240,000 帧的本次耗时约 0.056 秒，峰值 0.4571、RMS 0.1960，无削波和非有限采样。该数字属于这次模拟器运行。

界面截图：[主流型号搜索](../docs/ios-screenshots/mainstream-catalog.png) · [设备与听感](../docs/ios-screenshots/equipment-evidence.png) · [聆听实验室](../docs/ios-screenshots/listening-lab.png) · [白色主题](../docs/ios-screenshots/light-theme.png)。截图中音频为 Debug 自生成 QA 夹具。

0.7.1 已扩展为 15 项原生测试和 3 项界面测试，新增单位换算、缺失资料处理、精确型号匹配、蓝牙/前端隔离、输出模式链路分离与新资料界面保存。切回自定义型号的界面流程另做针对性回归。

测试日志与交付校验见 [0.7.0 验证记录](../docs/validation-ios-v0.7.log) 与 [0.7.1 验证记录](../docs/validation-ios-v0.7.1.log)。
