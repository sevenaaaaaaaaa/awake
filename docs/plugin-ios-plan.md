# iOS 吃下 MusicFree 插件源：可行性与落地方案

状态：方案稿（未开工）。目标是把桌面端已有的「网络音乐插件（枪弹分离 JS）」搬到 iOS：
导入 `myPlugins.json` 注册表 → 装单个 `.js` 插件 → 搜索 → 解析直链 → 带请求头下载 → 进现有 EQ 播放链路。

## 今天两边各有什么

| | 桌面 | iOS |
| --- | --- | --- |
| 插件运行时 | 前端 WebView 里的 `ui/src/plugins.ts`（890 行：插件 ABI + CryptoJS 子集 + fetch 桥） | **没有** |
| 插件存储 | `plugins/<id>.js`（后端只管存取，单文件上限 512 KB） | 没有 |
| HTTP 通道 | Rust `plugin_http`（绕过 CORS，限地址/方法/头/体/响应大小） | 没有 |
| 播放 | `getMediaSource` 解析出地址+请求头 → 本地 Range 管线 | `Network.download` 已支持自定义请求头 → 下载到本机 → 现有 EQ 链路 |
| 注册表 | 前端解析 `myPlugins.json`（`{plugins:[…]}` / 裸数组 / `{data}`） | 没有；但可以复用刚做的「配置文件夹」入口 |

结论：**iOS 缺的不是播放能力，是 JS 沙箱和插件 ABI**。播放那段（`Network.download(_ request:)`）已经能带请求头，改造成本最低。

## 选定路线：离屏 WKWebView 当沙箱（复用桌面那 890 行）

理由：桌面已经用同一套 JS 契约跑通 `search` / `getMediaSource` / `getLyric`，且 CryptoJS 子集是 JS 写的。
搬到 `JavaScriptCore` 要自己补 `setTimeout` / `atob` / Promise 泵，等于重写沙箱；搬到 WKWebView 只需补一座桥。

```
SwiftUI (插件搜索页 / 播放解析)
   │  evaluateJavaScript("sandbox.call(search, ...)")  → Promise
   ▼
WKWebView（不可见，长驻）: plugins.ts 编译产物 + CryptoJS 子集
   │  window.webkit.messageHandlers.awakeFetch.postMessage({id, url, init})
   ▼
Swift: Network.data / Network.download（地址/方法/头/体/超时/大小上限，白名单协议）
```

### 必须写进 DoD 的约束（照抄桌面，别放宽）

- 插件代码只从用户显式导入的文件或注册表里来，单文件 ≤ 512 KB；
- fetch 只允许 http/https，禁 `file://`、禁白名单之外的主机探测；
- 响应体 ≤ 8 MB、请求体 ≤ 2 MB、单次超时 15 s；
- 插件 token / cookie 不出沙箱，落库只存 `musicItem` JSON（单条 ≤ 32 KB），播放时才解析；
- 插件信任级别标注为「等同于你装的 App」，首次导入给一次明确确认。

## 拆成四片，每片单独可验收

| 片 | 内容 | 涉及文件（新增为主） | 粗估 |
| --- | --- | --- | --- |
| S1 | 插件来源类型 `plugin`：导入 `.js`、存 `Documents/plugins/<id>.js`、列表与删除 | `PluginStore.swift`、`SettingsViews.swift`（类型选择加一项） | 0.5 天 |
| S2 | JS 沙箱 + fetch 桥 + `search`：搜到的结果落曲库（locator=musicItem） | `PluginSandbox.swift`（WKWebView + message handler）、打包 `plugins.ts` 的 JS 产物、`MobileStore` 落库 | 1.5 天 |
| S3 | `getMediaSource`：解析地址+请求头 → `Network.download` 带头上限下载 → 播放 | `PluginSandbox.swift`、`MobilePlayer`/`Services.swift` 下载入口 | 1 天 |
| S4 | `myPlugins.json` 注册表：贴地址或从「配置文件夹」读本地 json → 列插件 → 一键装 | `PluginRegistry.swift`（`parsePluginRegistry` 的 Swift 版）、复用 `ConfigFolderView` | 0.5 天 |

合计约 3.5 天，每片都能单独出一个 0.9.x 测试 IPA。**建议顺序 S1 → S4 → S2 → S3**：S1+S4 先把「导入」这条腿打通（不跑 JS，风险最低，且立刻能用现在的配置文件夹把 `myPlugins.json` 和 `.js` 丢进 iCloud 里点刷新），S2/S3 才是真正跑插件。

## 已知风险

- **插件依赖面**：MusicFree 插件常用 `require("crypto-js")`、`TextDecoder`、`atob`、`setInterval`。WKWebView 原生有后三者，`require` 由沙箱垫片兜（桌面已验证）。
- **跨域**：WKWebView 里直接 fetch 会被 CORS 拦；一律走 `awakeFetch` 桥，走 `Network` 的 URLSession，这条和桌面的 `plugin_http` 同构。
- **线程与生命周期**：WKWebView 要长驻但不可见；页面重建后要重新注入插件代码，注册表里存「已装插件」状态即可恢复。
- **无本机 XCTest**：本机模拟器 service hub 起不来，S2/S3 的自动回归只能靠「编译 + 真机手工验收 + 沙箱纯函数单测」。这条要写进每片的 DoD，别让验收口径变成「能编译就算过」。

## 与现有功能的接缝

- 刚做的「来源配置文件夹」（0.9.14）可以直接当插件入口：把 `myPlugins.json` 和 `.js` 一起丢进 iCloud 的 `Awake-Sources`，刷新就能列出来 —— S4 只需要在扫到的文件里认出 `plugins` 形状。
- iOS 目前没有任何后台盯盘能力，所以「刷新」这个交互是长期形态，不是临时方案。
