# 播放页：从「平铺的设置页」改成有纵深的播放界面

这一版只动 iOS 的「正在播放」。桌面端与曲库页不改。

## 问题（用户的四句话）

1. 没有播放效果；
2. 所有东西都平铺；
3. 歌词没有随动；
4. 整体没有排版和布局。

改造前的 `NowPlayingView` 是一条长 ScrollView：声音摘要卡 → 调音按钮 → 信号链 →
31 段 EQ → 112pt 小封面 → 曲名 → 进度 → 传输 → 工具 → 歌词（纯文本列表，最底部）→
同专辑 → 乐评。首屏落在一张设置卡上，封面只有 112pt，歌词在第三屏。

## 结构（现在的首屏）

```
关闭 / 正在播放 / （右）
封面（≈260pt，圆角 14，浅投影）
曲名（title2 semibold）/ 艺人（subheadline）/ 专辑（caption）
歌词舞台（五行窗口，当前行永远是第 3 行）
进度（3pt 轨道 + 可拖动 + 等宽时间）
传输（上一首 / 68pt 播放键 / 下一首）
收藏 · 刷音乐 · 更多（44pt 点按目标）
── 折叠：声音与仪器（摘要卡 · 调音 · 信号链 · 31 段曲线 · 状态）
── 同专辑 · 乐评
```

- **层级只用字号、字重、留白和一条 0.5pt 结构线**，不靠颜色堆叠；彩色只来自封面。
- 折叠区默认收起：播放页先回答「在听什么」，再回答「为什么这样响」。
- 仪器区展开后仍是原来那些真实控件（`soundSummaryCard`、`ChainStrip`、`EQCurvePanel`、
  `statusLine`），没有为了好看删功能。

## 播放效果（只有两种动效）

| 元素 | 动效 | 时长 |
| --- | --- | --- |
| 环境层（封面主色柔光） | 透明度与 2–12% 缩放的呼吸 | 9s，`repeatForever` |
| 封面 | 1.5% 缩放呼吸 | 12s，`repeatForever` |
| 歌词换行 | 五行窗口切换 | 260ms easeOut |

没有旋转、弹跳、光斑跟随或伪频谱。环境色是从封面缩到 1×1 求平均得到的，
只代表「这张作品的色调」，不假装是音频分析。
「减弱动效」（系统设置或 App 内的 `awakeReducedMotion`）下三处全部静止。

## 歌词随动

- 解析：`MediaLyrics.parse`（LRC，含 `[offset:]` 与一行多时间戳）+ `currentIndex` 二分定位。
- 渲染：只渲染 `current-2 … current+2` 五行，当前行固定在第 3 行，居中、加粗、`text` 色；
  相邻行按距离递减透明度。居中由结构保证，不依赖滚动偏移，也不会和外层页面抢手势。
- 点击任意可见行跳转；没有歌词时给「添加歌词」入口，直接打开曲目信息编辑。
- 解析结果按「文本长度 + 哈希」缓存最近 24 份：播放页每秒重算多次 body，不能每次都跑正则。

## 可访问性

- 传输键 68pt、工具键 44×44，均带中文标签；进度条支持 VoiceOver 的可调动作（±10s）。
- 歌词行是按钮，标签为「跳到 0:12：……」，不是一段不可读的文本墙。
- 曲名标记为 header；歌词区用 `accessibilityValue` 播报当前行。
- 对比度沿用皮肤 token（深色底 + `text`/`muted`），没有新增第三种灰。

## 验证

```sh
# 类型检查（iPhoneSimulator SDK 27.0）
cd ios && swiftc -typecheck -sdk $(xcrun --sdk iphonesimulator --show-sdk-path) \
  -target arm64-apple-ios17.0-simulator Awake/*.swift

# 编译（含新增 XCTest）
xcodegen generate && xcodebuild -project Awake.xcodeproj -scheme AwakeIOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build-for-testing

# 纯逻辑
bash Tools/run_library_import_harness.sh
```

- 类型检查 **0 error**；`build-for-testing` → **TEST BUILD SUCCEEDED**；
  harness **26/0**（与本次无关，作回归基线）。
- 模拟器实机截图（`AWAKE_E2E_PLAYER=1` + `AWAKE_E2E_CHAIN=1`，模拟器没有可点击的 GUI）：
  - `docs/ios-screenshots/player-0.9.41-lyrics.png`：0:07，当前行「你听见的不是音量，是空间」居中；
  - `docs/ios-screenshots/player-0.9.41-instruments.png`：仪器区展开（声音摘要 / 信号链 / 31 段曲线 / 同专辑）。
  - 同一首歌间隔 7 秒再截一张，两图不同（歌词换行 + 呼吸），据此确认「随动」不是静态排版。
  - 仪器区那张是临时把 `showInstruments` 设为 `true`、并 `defaultScrollAnchor(.bottom)` 截的；
    两个开关都已还原，仓库里的默认值仍是收起。

## 未验证 / 边界

- **新增的 XCTest 没有在本机执行**：这台机器没有 `Simulator.app`，`test-without-building`
  起不来 test host（与 0.9.40 同一原因）。新增的 `testLyricLineLookupUsesLastTimestampBeforePlayhead`
  只证到「能编译」，需要真机或完整 Xcode 补跑。
- 真机上的手势（拖动进度、点击歌词行、展开仪器区）没有手点过；模拟器只能截图，不能点。
- 呼吸动效在低电量模式下是否被系统降频未测；代码只在 `playing` 为真时启动。
- 玻璃皮肤（`mode == "glass"`）下这页只验证了默认黑色皮肤；玻璃皮肤的顶部条与折叠区没截图。
