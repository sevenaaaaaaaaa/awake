# Awake 路线图与遗留清单

最后更新：2026-11-17（v0.9.4 与 ios-v0.9.4 发布之后）。这份文件只做两件事：**说清哪些需求已经有落点**，以及**把还没闭合的项按「谁能推进」分类**。数字和结论都指向仓库里的文件，不凭记忆。

## 1. 已发布

| 版本 | 主题 | 说明 |
| --- | --- | --- |
| 0.9.0 | 双向接力 | 电脑 → 手机；协议 v2，见 `docs/handoff-protocol.md` |
| 0.9.1 | 修缺 | Plex 来源类型、音乐生成预置下拉、深夜档本地时区，见 `docs/releases/v0.9.1.md` |
| 0.9.2 | 修缺 | iOS 启动不再弹 `OSStatus -50`，音频错误中文化；版本号守卫扩到四个落点，见 `docs/releases/v0.9.2.md` |
| 0.9.3 | 修缺 | Plex 登录会记住、凭据改存 `credentials.json`（0600）、来源可移除、加进来的曲目有地方看、本机文件夹连接前先验证；见 `docs/releases/v0.9.3.md` |
| 0.9.4 | 修缺 | 桌面手动刷新不再写回过期扫描结果、刷新保留收听痕迹；iOS Plex 扫描拒绝不完整结果、重复导入幂等、远程来源可移除；见 `docs/releases/v0.9.4.md` 与 `docs/releases/ios-v0.9.4.md` |

iOS 最新是 **0.9.4**（`ios-v0.9.4`，GitHub 标记 **Pre-release**，只有未签名 IPA），与桌面端在接力上互通。桌面 `v0.9.3` 是 Latest，但**只有 arm64 包**，没有 Intel 包也没有通用包，见 `docs/releases/v0.9.3.md` 的「已发布产物」与「更正」。

iOS 侧的相邻版本按 `gh release list` 核对过，别凭记忆：已发布的 iOS 包是 `ios-v0.9.2` 与 `ios-v0.9.3`（都标 Pre-release，都是未签名 IPA），再往前是 `ios-v0.8.1`。**`ios-v0.9.0` 与 `ios-v0.9.1` 从来没有发布过，也没有对应 tag**——0.9.0 的接力协议与 0.9.1 的 Plex 来源类型只出现在桌面端，iOS 这两版是空白。

## 2. 需求 1–6 的落点

| 需求 | 内容 | 状态 | 落点 |
| --- | --- | --- | --- |
| 1 | Plex「连接曲库」扫不出歌 | 已修（0.9.1），已有回归测试 | `ui/src/plex.ts` + `plex.test.ts` |
| 2 | 本地导入选择器 / 音乐生成预置下拉 | 已做（0.9.1） | `ui/src/App.vue` 音乐服务表单 |
| 3 | **没有落点** | 未确认 | 仓库里任何文档都没有记录这一项 |
| 4 | 歌单解析后引导扫本地再匹配 | 已做（G1） | `playlist_import.rs`、`PlaylistImport.vue` |
| 5 | AI 平台预置 | 已做（G1） | `preset.rs`、`App.vue` |
| 6 | 覆盖度 / 宝藏歌曲 / 成就 | 已做（G1） | `insight.rs`、`App.vue` |

需求 3 是这份清单里唯一的空洞：G1 审计写「本轮做 4/5/6，1/2 是 G2」，G2 计划写「做 1/2」，3 从来没被任何一轮提起。**这条需要用户补一句它是什么**，否则「推进后面所有规划」就少了一块。

## 3. 未闭合项，按「谁能推进」分

### 3.1 需要用户动手（我这边只能准备）

| 项 | 为什么卡住 | 准备到什么程度 |
| --- | --- | --- |
| 桌面端真机点击回归 | 需要鼠标点，且要真实曲库 | 浏览器渲染已实跑；测试通道已建 |
| Plex 真实账号端到端 | 需要你的服务器地址与 Token | 类型与分区逻辑有测试，扫描链未跑 |
| iOS 真机回归 | 需要 iPhone 与开发者证书 | 本轮 iOS 改动只过了编译与独立逻辑验证；模拟器 XCTest runner 起不来（见 3.4） |

### 3.2 需要硬件或付费账号

| 项 | 依赖 |
| --- | --- |
| 长音轨 DAC 硬件回环测量 | 声卡回环设备；现有测试用 loopback HTTP，不是真实 DAC |
| AI 创作真实出片 | ElevenLabs 付费账号；现只有本地 HTTP 音频响应验证 |
| 云端策展真实模型 | 你自己的 API key |

### 3.3 可以自己推进（按价值排序）

| # | 项 | 现状 | 建议动作 | 验收边界 |
| --- | --- | --- | --- | --- |
| A | 前端测试通道继续铺 | 25 项（2026-11-17 实跑 `npm test --prefix ui`：25 通过 / 0 失败），覆盖 gaps / plex / version / 来源收窄 | 把 `useAwake` 的队列与偏好更新抽成纯函数后补测 | 现有 25 项不退化，新增项能复现红 |
| B | 耳机测量「数据独立认证」 | 未做；现在只校验滤波参数合法性 | 记录测量来源与内容摘要，导入时核对，界面标明出处 | 无来源的测量不能进校正列表 |
| C | 响度匹配 A/B | 未做 | 先算 LUFS/峰值，再做等响切换 | 两个版本切换时主观音量不跳；有数值断言 |
| D | 洞察面板口径校验 | 深夜档已本地化 | 用真实收听数据核对 30 秒门槛与连击定义 | 与 `insight.rs` 的 `HEARD_SECONDS` 同源 |
| E | iOS 与桌面端对齐 | iOS 已到 0.9.4，但 `ios-v0.9.0` / `ios-v0.9.1` 从未发布，语义对齐没有版本记录 | 0.9.4 的 iOS 修复已发版，两端曲库语义按本轮两个发行说明核对 | 两端接力与曲库语义一致 |

### 3.4 环境阻塞（本机无法验证，不是「没做」）

| 项 | 症状 | 已试过的做法 | 需要什么才能推进 |
| --- | --- | --- | --- |
| iOS XCTest 跑不起来 | `xcodebuild test` / `test-without-building` 都会卡在起 test host：日志里只有命令行回显，随后出现 `DTServiceHubClient failed to bless service hub for simulator <device>` 与 `Mach error -308 (ipc/mig) server died`；无 `.xcresult` 产出 | 重启 `com.apple.CoreSimulator.CoreSimulatorService`、`simctl erase` 重建设备、换 iPhone 17 / iPhone 17 Pro / ProbeFresh 三台设备、`-parallel-testing-enabled NO`、先 `build-for-testing` 再 `test-without-building` | 本机 Xcode-beta（27A5228h）里**没有 Simulator.app**，模拟器 GUI 起不来，service hub 也就无法 bless。换一台装了完整 Xcode（含 Simulator.app）的机器，或在真机上跑 |
| 推送 github.com 偶发不通 | `git push` 报 `Error in the HTTP2 framing layer`，`curl https://github.com/` 超时；此时 `api.github.com` 与 `codeload.github.com` 正常，`gh` 命令可用。原因是 DNS 偶尔把 `github.com` 解析到不通的地址（2026-11-17 出现过 `20.247.166.64`），恢复后解析为 `20.205.243.166` 即正常 | 重试、等 DNS 恢复、把 `github.com` 临时指向可用 IP（如 `140.82.121.4`）走本地转发；只影响 `github.com` 直连，不影响 `gh`（走 `api.github.com`）。**2026-11-20 有效的办法**：本机起一个 CONNECT 代理（`/tmp/github_proxy.py`，把 `github.com:443` 固定转给可用 IP），再 `git -c http.proxy=http://127.0.0.1:8899 push origin <ref>`；当天可用 IP 是 `140.82.121.4` / `20.205.243.166` / `20.27.177.113`，而 `140.82.112/113/114/116.3` 全部 000。`gh release create` 与资产上传（`uploads.github.com`，解析到 `140.82.112.13`）不受影响，不需要走代理 | 推送前先 `curl -o /dev/null -w '%{http_code}' https://github.com/` 探一下，200 再推 |

这台机器上能证明的只有两件事，都要按字面理解：`xcodebuild build-for-testing` 输出 `** TEST BUILD SUCCEEDED **`（测试代码能编译），以及纯逻辑用 `swiftc` 独立编译后跑出 **12 项断言 / 0 失败**（`PlexScanValidation` 与 `LibraryImportIdentity` 的真实源码行，机械抽取，不手抄）。**这不等于 XCTest 通过。**

### 3.5 记录在案但不打算做

- 网盘原生 OAuth、分享链接解析、SMB 自动挂载（README 已写明边界）。
- 公共源目录 / 社区源推荐（产品边界，不开放）。

## 4. 下一批（0.9.4 之后）

### 4.1 本轮已修并**已发版**（tag `v0.9.4` 与 `ios-v0.9.4`，2026-11-17）

这一批全是「静默失效」类问题——不报错，但结果不对：

| 端 | 修的是什么 | 落点 |
| --- | --- | --- |
| 桌面 | 手动刷新在异步扫描期间，来源被移除或配置被改，旧扫描结果仍会 `save` 回去，把来源插回来或把配置盖掉。现在提交前校验来源仍存在且配置一致，不一致就返回错误并保留当前状态 | `rust/crates/awake-app/src/connections.rs` |
| 桌面 | 刷新提交改为合并式：收藏、播放次数、上次播放、加入时间按曲目标识继承，不再被全新扫描结果清空 | 同上 |
| iOS | Plex 分页在 20000 首上限处停下却不确认是否还有后续页；合法空结果会让旧曲库被清空。现在满页且 `totalSize` 显示还有更多、缺 `totalSize`、零分区、分区零曲目都按失败处理，走「保留旧曲库」路径 | `ios/Awake/Services.swift` |
| iOS | 同一个文件/文件夹重复导入会生成随机新副本。现在按标准化路径（`standardizedFileURL.resolvingSymlinksInPath`）做稳定身份，重复导入不新增记录、不新增缓存；文件夹重扫时只移除本次扫描中消失的成员 | `ios/Awake/Models.swift` |
| iOS | 远程来源只能加不能删。现在每个 WebDAV/Plex/Telegram 来源都有「移除来源」（二次确认），曲目、凭据、按曲目命名的缓存文件一起清；持久化失败时内存状态、缓存文件与凭据一起回滚 | `ios/Awake/Models.swift`、`ios/Awake/SettingsViews.swift` |

验证数字（2026-11-17，本机，0.9.4 树上重跑）：Rust `cargo test -p awake-app --lib` = **107 通过 / 0 失败 / 10 按需忽略**，退出码 0；前端 `npm test --prefix ui` = **25 通过 / 0 失败**（版本号四落点 = 0.9.4）；iOS `xcodebuild build` = `** BUILD SUCCEEDED **`，`build-for-testing` = `** TEST BUILD SUCCEEDED **`；纯逻辑 harness = 12 项断言 0 失败；**XCTest 未跑起来**，原因见 3.4，不能记为通过。0.9.4 是在这个缺口下按用户决定先发版的（2026-11-17，用户明确选择不等 XCTest），缺口不因此消失：下一次在完整 Xcode 或真机上要补跑 `AwakeTests`。

### 4.2 上一版遗留项已随 0.9.3 发出（2026-11-17 核对）

上一版这份清单把下面三条写成「未发版」，现在它们已经随 `v0.9.3` 一起发了，不再属于待发内容：

- 前端测试通道 `npm test --prefix ui`（当时 15 项，0.9.3 验证时是 25 项）；
- 版本号单点来源 `ui/src/version.ts` + 同步测试（发版漏改会红）：四个同发版落点全部有断言——`ui/package.json`、`version.ts`、`rust/Cargo.toml` 的 workspace 版本、`tauri.conf.json`；
- 浏览器预览里洞察面板改为明说「读不到，请用桌面版」。

### 4.3 下一步的优先级（我的建议，按这个顺序）

1. **先让本轮修复真发出去**。4.1 那一批现在只在分支上，用户拿不到；不合并、不打 tag，等于没修。发版前要做的最小闭环：合并 → 一次 `cargo test` + `npm test --prefix ui` → 打 `v0.9.4` 与 `ios-v0.9.4`。
2. **补 Intel 包**。0.9.3 只有 arm64，Intel Mac 用户现在装不上；这条要么补发 `AWAKE_ARCHS="arm64 x86_64"` 的通用包，要么在 README 与发布页写死「仅 Apple Silicon」。
3. **把 iOS XCTest 挪到能跑的环境**（3.4）。这不是可选项：本轮 iOS 两条修复的验收断言现在是「编译通过 + 独立 harness」，还差一次真的 XCTest 通过。
4. **然后才是 A + B**：把测试通道铺到 `useAwake`（所有播放状态都在那里，是这类静默失效的高发区），再做耳机测量的来源认证——它是一条能闭环、不需要硬件也不需要账号的完整需求。

## 5. 判据

这份清单里的每一项，判断「完成了」都必须有一个能红的东西：一条测试、一次实跑输出、或一份带数字的日志。没有这些的一律写「未验证」，不写「已完成」。
