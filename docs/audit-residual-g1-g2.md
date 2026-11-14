# G1 / G2 残留收口记录

日期：2026-11-15。起点：v0.9.1 已发布（tag `v0.9.1`，GitHub Release 有正文）。
范围：G1 审计 §5 的未验证项、G2 计划里的遗留，以及为了把这两类遗留钉住而补的防线。

## 1. 结论表

| 来源 | 遗留项 | 本轮处理 | 证据 |
| --- | --- | --- | --- |
| G1 §5.1 | 真机点击回归 | 仍未做，需要用户拿鼠标点 | — |
| G1 §5.2 | 浏览器预览降级路径没实跑 | 缺口聚合抽成 `aggregateGaps`，7 项测试；洞察面板在浏览器里改为明说原因，并实跑确认 | `ui/src/gaps.test.ts`、§5 |
| G1 §5.3 | 生成侧没有预置下拉 | v0.9.1 已补（`App.vue` 音乐服务表单） | `ui/src/App.vue` 2309 附近 |
| G1 §5.4 | 深夜档按 UTC 判定 | v0.9.1 已改 `chrono::Local`，本轮复核代码与测试 | `rust/crates/awake-app/src/insight.rs` 275 |
| G2 #1 | Plex `sourceKind` | 抽成 `plexSourceDraft`，6 项测试，并验证过「把 bug 放回去会红」 | `ui/src/plex.test.ts`、§4 |
| G2 #2 | 预置下拉与策展侧对齐 | v0.9.1 已补，浏览实跑看到下拉渲染 | `ui/src/App.vue` |
| 本轮新发现 | 版本号写在四处，0.9.1 只改了两处 | 抽 `ui/src/version.ts` 单点 + 同步测试；`Cargo.lock` 随本轮提交追上 0.9.1 | `ui/src/version.test.ts` |
| 本轮新发现 | 浏览器里洞察面板静默消失 | 改为显示「浏览器预览读不到，请在桌面应用查看」 | §5 实跑文本 |

## 2. 版本号这一条要单独说

`chore: bump version to 0.9.1`（e14a604）只改了 `rust/Cargo.toml` 和 `ui/package.json`。真正会露面的还有三处没改：

- `ui/src/App.vue` 侧栏底部：`0.9.0 / PERSONAL`；
- `ui/src/useAwake.ts` 启动上报：`frontend_ready { version: "0.9.0" }`；
- `rust/Cargo.lock`：三个 crate 仍写着 `0.9.0`，直到本轮跑 release 构建时 cargo 才顺手改掉。

第二条最严重：G1 审计 §4b 引用的那行启动日志 `FRONTEND_READY version=0.9.0` 本身就是错的版本号——拿它证明「0.9.1 的构建跑起来了」是站不住的。第三条说明发版清单是凭记忆走的：改了 `Cargo.toml` 却没跑一次会让 lock 更新的命令。

现在只有一个地方写版本：`ui/src/version.ts`。`version.test.ts` 拿它和 `ui/package.json` 比，下次发版漏改界面会直接红，而不是等下一轮审计靠肉眼发现。

## 3. 为什么先补测试通道，而不是先补代码

G2 的三处改动全部落在「没有任何自动化能碰到」的地方：`App.vue` 的表单赋值、下拉过滤、`chrono` 调用。0.9.1 的发行说明写的是「fix confirmed by code review」——那不是验证，是第二个人的一次阅读。所以遗留的根因不是某个 bug 没修，而是这类改动没有任何地方会红。

这一轮补的通道：

```bash
npm test --prefix ui      # node --test 'src/**/*.test.ts'
```

- 零新依赖：Node 22 自带类型剥离，直接跑 `.ts`；`node:test` + `node:assert/strict`。
- 测试文件在 `ui/tsconfig.json` 的 `exclude` 里，不进 `vue-tsc` 的类型范围（避免为 `node:` 内置模块引入 `@types/node`），但仍会被 `npm test` 跑到。
- 纯逻辑抽到 `gaps.ts` / `plex.ts` / `version.ts`，组件只负责把结果写进 ref。被抽出来的都是「读一眼代码看不出对错、但错了会静默失效」的那部分。

## 4. 测试证据

```
npm test --prefix ui
# tests 15
# pass 15
# fail 0
```

```
cargo test --manifest-path rust/Cargo.toml -p awake-app --lib
test result: ok. 97 passed; 0 failed; 10 ignored
```

### 4b. 这些用例真的会红

把 `plexSourceDraft` 里的 `kind: "plex"` 改成 `"local"`，重跑：

```
# tests 13
# pass 11
# fail 2
```

改回来重跑：`# pass 13 / # fail 0`。这说明 0.9.0 那个 P0 一旦复发，测试先炸，不依赖任何人记得这件事。

（当时 13 项是加入 `version.test.ts` 之前的数；现在共 15 项。）

## 5. 浏览器预览实跑（G1 §5.2）

`npm run dev --prefix ui`，Aside 浏览器打开 `http://localhost:1420/`：

- 首页：`pageerror` 与 `console.error` 均为空；
- 侧栏版本行：`0.9.1 / PERSONAL`（改之前是 `0.9.0 / PERSONAL`）；
- 「听歌搭子」视图：没有覆盖度面板（浏览器没有本地曲库，正确），并显示
  `曲库覆盖度与成就要读完整个本地曲库，浏览器预览读不到，请在 Awake 桌面应用中查看。`

这一条同时纠正了 G1 审计里的一句话：「`libraryCoverage` / `listeningAchievements` 会抛『需要桌面版』」——实际上 `loadInsight()` 在 `!desktop` 时直接 `return`，那两个命令在浏览器里根本不会被调到，异常分支是死代码。所以原来不是「降级提示不对」，是**什么都不显示**。

## 6. 桌面构建与启动核验

```bash
AWAKE_ARCHS=arm64 ./Tools/build_rust_app.sh
# Built: /Users/sevenaaaaaaa/Awake/dist-rust/Awake.app (arm64)
codesign --verify --deep --strict dist-rust/Awake.app   # 通过
lipo -info dist-rust/Awake.app/Contents/MacOS/Awake     # architecture: arm64
```

隔离 HOME 启动（不碰用户现有曲库与钥匙串）：

```bash
HOME=/tmp/awake-g2-home ./dist-rust/Awake.app/Contents/MacOS/Awake
```

```
[awake] WINDOW_URL=Ok(Url { scheme: "tauri", ... })
[... INFO  awake_app_lib] FRONTEND_READY version=0.9.1 tracks=0
[awake] 前端已挂载 version=0.9.1 tracks=0
```

这一行 `version=0.9.1` 是 §2 那条的直接证据：同样的日志在动手之前是 `version=0.9.0`。跑完用 `kill -TERM` 结束该 PID，`/tmp/awake-g2-home` 里没有留下任何用户数据。

## 6b. 构建脚本这次踩到的坑（值得写下来）

第一次跑构建，`cargo` 之后脚本在第 51 行 `lipo -info` 处被 `Killed: 9` 打断：

```
./Tools/build_rust_app.sh: line 51: 67157 Killed: 9   lipo -info "$APP_BINARY"
```

原因不是 lipo，也不是二进制有问题——**包里那个可执行文件正被一个 2 小时前启动、没人收掉的实例占用**（`PID 19803`，上一轮核验留下的）。覆盖一个正在运行的 Mach-O 会被系统拦下。

后果有两层，第二层更要紧：

1. 构建 `cargo` 花了 10 分 40 秒，成果被一句 `Killed: 9` 挡在包里；
2. `Info.plist` 与 `codesign` 都在那一行后面，所以包里的版本号与签名**停在上一版**，而 `dist-rust/Awake.app` 看上去是「刚构建过」的。

脚本已改：动包之前先用 `lsof` 查这个可执行文件有没有被占用，占用就直接停下并打印是谁；架构校验也改成在**构建产物**上做，而不是读包里的文件。

新脚本重跑（cargo 已热）：`Built: ... (arm64)`，签名替换成功，`Info.plist` 0.9.1。

## 7. 仍然没有验证到的（不打折地说）

1. **没有真机点击回归。** 覆盖度面板、成就解锁、缺口面板的按钮、预置下拉的实际点击，仍然只有类型检查、单元测试和浏览器渲染证据，没有在桌面 App 里点过。
2. **没有 Plex 真实账号。** `plexSourceDraft` 的测试证明「kind 是对的」，不证明「真 Plex 服务器能扫出歌」。后者需要用户自己的地址与 Token。
3. **`playlistImportGaps` 的桌面分支没有端到端跑。** 浏览器分支有 7 项测试，Rust 侧有 4 项，两侧口径靠代码对齐；但「粘贴一个真歌单 → 匹配 → 面板出现」这条链没跑。
4. **iOS 侧不在本轮。** G2 计划里就写着不动 iOS，本轮同样不动。

## 8. 口径对齐说明

`aggregateGaps` 的排序原来是 `a.artist.localeCompare(b.artist)`，Rust 侧是 `a.artist.cmp(&b.artist)`（UTF-8 字节序 = 码点序）。同一份歌单在桌面版和浏览器预览里，缺口数相同的艺人顺序可能不同。现在浏览器侧改成按码点比较（`compareByCodePoint`），与后端一致；`gaps.test.ts` 有一条用例钉住这个顺序。

## 9. 补记（同日）：版本号其实是五处，`tauri.conf.json` 还停在 0.9.0

§1 与 §2 说「版本号写在四处」——**数漏了一处**，而且漏的正好是打包路径读的那一处。

`rust/crates/awake-app/tauri.conf.json` 的 `version` 一直是 `0.9.0`，本轮提交时仍是。它的影响面要说准，不能夸大：

- `Tools/build_rust_app.sh` 的 `Info.plist` 由脚本内联的 python 从 `ui/package.json` 生成，**不读**这个文件，所以已发布的 0.9.1 包本身版本是对的（`CFBundleShortVersionString` = 0.9.1，已用 PlistBuddy 复核）；
- 但 `tauri build` / `tauri dev`（`npm run tauri` 走的就是它）读这个文件决定包版本。换个人用 Tauri 自带命令构建，就得到一个版本号写着 0.9.0 的 0.9.1 包。

修法与证据：

```
not ok 16 - rust/crates/awake-app/tauri.conf.json 的版本与界面版本一致
  expected: '0.9.1'
  actual: '0.9.0'
# tests 17 / # pass 16 / # fail 1
```

改 `tauri.conf.json` 为 `0.9.1` 后重跑：`# tests 17 / # pass 17 / # fail 0`。

同一条也补上了 `rust/Cargo.toml` 的 `[workspace.package] version`：各 crate 写的是 `version.workspace = true`，后端二进制与 `frontend_ready` 上报的版本都来自这里，此前没有任何断言看着它。

于是「同一个版本号」的落点是这些，以及谁看着它：

| 落点 | 性质 | 由谁守 |
| --- | --- | --- |
| `ui/package.json` | 源头 | `version.test.ts` |
| `ui/src/version.ts` | 界面显示与启动上报 | `version.test.ts` |
| `rust/Cargo.toml`（workspace） | 后端二进制 | `version.test.ts` |
| `rust/crates/awake-app/tauri.conf.json` | Tauri 自带命令打包 | `version.test.ts` |
| `rust/Cargo.lock` | 派生，跟随 Cargo.toml | 不守，手改反而会错 |
| `ios/project.yml` | **另一条发版线** | 故意不守：0.9.1 就没有 iOS 改动，要求相等会让「桌面发版但 iOS 不动」变成不可能 |

## 10. 顺手核到的两处陈旧，本轮不动

1. `Resources/AwakeInfo.plist`：`0.2.0`、`CFBundleIdentifier` 是 `com.seewow.awake`（实际是 `com.seven.awake`）。只有旧的 `build_awake.sh`（Swift 那条路径）`cp` 它，Rust 包不读。谁哪天走那条脚本，就会打出一个包 ID 和版本都错的包。属于清理项，不在本轮范围。
2. 工作区里 `ios/project.yml` 有未提交改动：`MARKETING_VERSION` 0.9.0 → 0.9.1、`CURRENT_PROJECT_VERSION` 18 → 19，而 `docs/roadmap.md` 写着「0.9.1 没有 iOS 改动」。两者只能留一个：要么撤掉这个 bump（iOS 停在 0.9.0），要么留着并改路线图那行。**这是产品口径，等一句话再动。**

