# G1 审计记录（需求 4 / 5 / 6）

日期：2026-11-14。范围：歌单导入后的缺口引导、AI 平台预置、曲库覆盖度与成就。
本轮**没有**碰 Plex 媒体库（需求 1）和本地导入选择器（需求 2）——那是 G2。

## 1. 改了什么

| # | 需求 | 落点 | 文件 |
| --- | --- | --- | --- |
| 4 | 歌单解析后引导扫本地再匹配 | 缺口聚合（Rust，有测试）+ 缺口面板与「选文件夹再匹配」按钮 | `rust/crates/awake-app/src/playlist_import.rs`、`ui/src/PlaylistImport.vue` |
| 5 | AI 平台预置 | 9 家平台的地址/模型/说明清单 + 表单里的一键填入 | `rust/crates/awake-app/src/preset.rs`、`ui/src/App.vue` |
| 6 | 宝藏歌曲 / 覆盖度 / 成就 | 覆盖度（艺人·年代·流派分桶）+ 5 个本地成就 | `rust/crates/awake-app/src/insight.rs`、`ui/src/App.vue`、`ui/src/styles.css` |
| — | 前后端契约 | 4 个新命令与浏览器降级 | `rust/crates/awake-app/src/lib.rs`、`ui/src/bridge.ts` |

新增命令：`playlist_import_gaps`、`ai_presets`、`library_coverage`、`listening_achievements`。

## 2. 判定口径写在一处

「听过」= 听完（`completed`）或单次收听 ≥ 30 秒（`HEARD_SECONDS`）。这条定义只写在 `insight.rs` 一处，覆盖度、成就、前端提示共用，避免两套口径。

## 3. 测试证据

```
cargo test --manifest-path rust/Cargo.toml -p awake-app --lib
```

- 本轮之前：81 passed / 10 ignored
- 本轮之后：**97 passed / 0 failed / 10 ignored**（新增 16 项）

新增用例分布：

- `insight`：9 项——30 秒门槛、分桶与百分比、空曲库不出 NaN、被删曲目不计入覆盖、专辑完成度均值、连续收听的最大连击、成就阈值、毫秒与秒两种时间戳。
- `preset`：3 项——id 唯一且合法、地址全为 https、预置内容里不含任何 key。
- `playlist_import::gap_tests`：4 项——空输入、只聚合未匹配项、空艺人回落「未知艺人」且每组曲名封顶 5 条、全部匹配时不提示扫描。

前端：

```
npm run build --prefix ui
```

`vue-tsc` 无类型错误；产物 297.27 kB（gzip 102.60 kB），较上一版 292 kB 增加约 5 kB。

## 4. 测试抓到的一个真 bug（记录在案）

`decade_label` 原本写成 `format!("{}0s", (year / 10) * 10)`，输出是 `19900s` 而不是 `1990s`——多补了一个零。`coverage_splits_buckets_and_rounds_percent` 断言 `by_decade` 里存在 `1990s` 时失败暴露出来，改为 `format!("{}s", (year / 10) * 10)` 后通过。

这条留着，因为它说明测试确实在验证输出，而不是在验证「跑过了」。

## 4b. 运行时启动验证

用隔离的 `HOME=/tmp/awake-g1-home` 启动新构建（不碰用户现有曲库）：

```
HOME=/tmp/awake-g1-home dist-rust/Awake.app/Contents/MacOS/Awake
[INFO awake_app_lib] FRONTEND_READY version=0.9.0 tracks=0
```

`codesign --verify --deep --strict` 通过，`lipo -info` = arm64，进程正常挂载前端后被我主动结束。

**一条方法论教训**：先前用 `strings` 在二进制里找命令名来判断「命令有没有注册」，这个办法不可靠——同样零参数的 `output_device`（线上一直在用）在二进制里也搜不到。真正的保证是 `tauri::generate_handler!` 的宏展开：签名不匹配会直接编译失败，所以「编译通过」比「二进制里有这串字」更可信。这条写下来，避免下一次再靠 grep 字符串下结论。

## 4c. 对上一轮 Plex 判断的修正

上一轮我说「音乐库 section key 从来没进过扫描」，这句话不准确。核对后发现：

- `ui/src/App.vue` 调 `connect_source` 时**确实**带了 `section: plex.sections[plex.sectionIndex]?.key`；
- `rust/crates/awake-app/src/remote.rs` 的 `plex()` **确实**按 `source.section` 过滤分区，分区不存在还会报「Plex 音乐库分区不存在或已删除」；
- 真正的断点在别处：`applyPlexServer()` 只写了 `sourcePath / sourceSecret / sourceName`，**没有把 `sourceKind` 设成 `plex`**。于是点「连接曲库」时走的是 `sourceKind === "local"` 分支，把 `http://…` 当作本地路径扫描，自然一条也扫不出来。

这条要在 G2 里先用真实账号复现确认，再改。上面的结论是读代码得出的，还没有跑过运行时。

## 5. 没有验证到的（不打折地说）

1. **没有做真机点击回归。** 本轮只到「编译 + 单元测试 + 前端构建」，没有启动 App 去点「扫文件夹再匹配」和洞察面板。
2. **浏览器预览的降级路径没有实跑。** `playlistImportGaps` 在非桌面环境有本地实现，`libraryCoverage` / `listeningAchievements` 会抛「需要桌面版」，都只做了类型检查。
3. **生成侧（music）没有加预置下拉**，只有策展侧（curator）有。预置清单里 `kind` 已标好 `both` 的平台，下一步接生成表单时直接复用。
4. **成就的口径未经过真实收听数据校验。** 深夜档按 UTC 小时判定，跨时区用户看到的「0–5 点」不是本地时间。

## 6. 手工复核步骤（给下一轮用）

1. 打开 App → 顶栏进「推荐」视图 → 应看到「听歌覆盖度 xx%」与 5 个成就；没听过任何歌时应是 0%。
2. 「数据与接力」→ 歌单导入 → 粘贴一个网易云歌单链接 → 解析 → 匹配；若有未匹配，应出现「缺 N 首（M 位艺人）」，点按钮选一个音乐文件夹，扫完自动重新匹配。
3. 「推荐」页 → 展开「云端策展服务」→ 「预置平台」下拉选 DeepSeek → 地址与模型被填入、提示只剩 token。
