# 2026-11-25 · 电台列表 / MusicBee 码表 / 跨盘映射 / 古典命中率 / 三档截图

五件事，逐项写**结论、证据、可重跑的命令、仍然没验的部分**。
没有 A/B 级来源的地方直接标"未验证"，不写成"应该没问题"。

---

## 1. MusicBee 的 tag 码 → 字段名

**结论：拿到了官方枚举，接进代码了；但仍是"推断"，不是实测。**

- 来源（B 级）：官方插件 SDK 的 `public enum MetaDataType`，
  原文 `https://www.getmusicbee.com/download/plugins/MusicBeeInterface.cs` 第 391–466 行。
  该地址对脚本返回 403，实际取的是逐字节相同的 GitHub 镜像
  `cqjjjzr/MusicBee-NeteaseLyrics/MusicBeeInterface.cs`（39976 字节）。
- 生成方式：脚本按 `Name = 数字` 解析，**没有手抄**，因此不会出现少写一位的数字。
  表落在 `rust/crates/awake-core/src/musicbee_tags.rs::TAG_CODES`，73 项，按码升序。
- 为什么还算"推断"：.mbl 的 tags 段用单字节码存值，SDK 枚举是 API 层的同一个枚举，
  两者一致是**高置信度推断**，不是同一个文件格式规范里的明文规定。
- 反证条件（一条命令）：样例值的语义与名字对不上，就是表错了。

```sh
cargo build -p awake-cli
./rust/target/debug/awake-cli mbl tags /path/to/MusicBeeLibrary.mbl
```

输出每个真实出现的码、表里的名字、出现条数、三个去重样例值；表外的码显示
`unknown(code=N)`。确认语义后可以先用 `--tag 65=TrackTitle` 试覆盖，再改表。

**没有真实 .mbl**，所以这份表在当前机器上只被合成样本验证过
（`Tools/make_sample_mbl.py`，5 条记录 / 2 个盘根 / 8 种 tag 码）。
合成样本证明"命令能跑、字段能读出来"，**不证明码表正确**。

## 2. 古典解析的真实命中率

**结论：语料内 31/31 命中（100%），1 条已知缺口；真实曲库上分母为 0，命中率无定义。**

- 语料：`Tools/classical_corpus.json`，32 条，覆盖冒号/无冒号、中英文、有/无作品号、
  三种乐章写法，以及 4 条反例（流行、爵士、"Various Artists: ..."、无作曲家的专辑）。
- 语料是**常见写法的重建**，不是任何人的真实曲库。100% 说明"语料覆盖的写法都处理了"，
  不说明"你的库能命中多少"——这是本次唯一诚实的读法。
- 已知缺口（`known_gap`，不计入分母）：`album_artist` 是指挥时会被当成作曲家
  （`Herbert von Karajan` 被读成作曲家）。要修得再补一张指挥家/乐团表，本轮没做。

```sh
cargo test -p awake-core --lib classical -- --nocapture
./rust/target/debug/awake-cli classical-check ~/Library/Application\ Support/com.seven.awake/library.json
```

本机真实曲库：18 首，古典专架 0 首 → **命中率无定义（分母 0）**。
这不是解析失败，是分类层没把任何专辑归进古典。要真实数字，得在装了古典的库上跑第二条命令。

### 本轮补的解析规则（都是"可判定的排除"，不是猜）

| 规则 | 为什么 |
|---|---|
| 作品号加 `HWV` / `WoO` / `S.` | Handel、Beethoven bagatelle、Liszt 的真实标签常用这三种 |
| `D 899` / `K 331` / `Hob XVI:52` 的点可有可无 | 抓轨工具不同写法不同，只认带点会漏一半舒伯特 |
| 全角冒号 `：` 也认 | 中文库写的是「贝多芬：第五交响曲」 |
| 冒号前含体裁词 → 不是作曲家 | 「贝多芬第五交响曲全集」不是人名 |
| 冒号前是 `Various Artists` 这类占位符 → 不是作曲家 | 否则会冒出一位叫 Various Artists 的作曲家 |
| 作曲家词典兜底（约 120 项） | `album_artist` 与 `artist` 都是演奏者时，作曲家常只写在 artist 多值串里 |

顺序是有讲究的：**冒号 → 词典 → `album_artist != artist`**。
反过来会把 `Wiener Philharmoniker` 这种乐团名当成作曲家。

## 3. 跨多块 Windows 盘的 .mbl 映射

**结论：修好了，跨两个盘 5/5 命中。**

- `awake_core::musicbee::Mount { win_root, posix_root }` + `plan_multi`；
  旧的 `plan(records, win_root, posix_root)` 保留为单盘包装，行为不变。
- 同一条记录被多个 Mount 命中时取 **`win_root` 最长**的那个——
  `F:\Music` 比 `F:\` 更具体，用户加它就是为了让映射落到对的目录。
- `windows_roots(records)` 报这份库跨了几个盘根、各多少条；CLI 与面板都用它。
- CLI：`--map "F:\Music=/Volumes/F"` 可以给多次；旧的 `--root + --mount` 仍然认。

```sh
python3 Tools/make_sample_mbl.py /tmp/sample.mbl
./rust/target/debug/awake-cli mbl inspect /tmp/sample.mbl \
  --map "F:\Music=/Volumes/F" --map "G:\Archive=/Volumes/G"
# 映射: 2 对 / 匹配: 5 条 / 未匹配: 0 条
```

第三条盘根没有挂载点时会如实报未匹配（`a_drive_without_a_mount_is_reported_unmatched_not_silently_dropped`）。

## 4. 电台台站列表

**结论：列表页做完了——目录、判定、探测、复制地址都在；内置播放还没接。**

- 判定与缓存仍在 `awake_core::radio`（有测试，不联网）；
- 网络与磁盘在 `awake-app/src/radio_stations.rs`：按官方约定问
  `all.api.radio-browser.info/json/servers` 要服务器列表，失败退到 `de1`；
- 界面 `ui/src/RadioStations.vue`：搜索、判定徽标、探测（真连上去解 4 秒）、复制地址。

**刻意没做的**：内嵌播放。电台不是 `Track`，`Player::play_queue` 只吃库内曲目；
要做必须在播放内核加一条"从任意 reader 播"的路径，那是另一件事。
界面上一句话写清了这点，没有假装能播。

浏览器预览（`?view=sources`）里是一份示例台站，标注"不是真实目录"。
真实目录与判定只在桌面版。

```sh
cd ui && npx vite --port 5199 --strictPort
# 打开 http://localhost:5199/?view=sources
```

## 5. 新加面板的视觉验收（375 / 768 / 1280）

三张真实截图，chromium headless，`?view=sources` 深链直达：

| 档位 | 文件 | 看到什么 |
|---|---|---|
| 375 | `screens/radio-375.png` | 单列列表；徽标完整；名字省略号正确；装饰图标隐藏腾宽度 |
| 768 | `screens/radio-768.png` | 两栏外壳（侧栏 + 内容）；卡片一路竖排；徽标完整 |
| 1280 | `screens/radio-1280.png` | 台站三列；MusicBee 卡片同屏可见 |

截图暴露并修掉的三个真 bug：

1. **`.field` 竖排时 `flex-basis: 220px` 变成高度**——搜索框被撑成 220px 的方块；
2. **`.station` 是 grid item，默认 `min-width: auto`**——badge 的 `nowrap` 把卡片按内容撑宽，
   375 下整块溢出屏幕；
3. **`MusicBeeImport.vue` / `RadioSettingsCard.vue` / `RadioStations.vue` 都没 import `Icon`**——
   控制台一直在报 `Failed to resolve component: Icon`，图标从来没渲染过。这是先前就存在的问题。

```sh
CH=~/Library/Caches/ms-playwright/chromium_headless_shell-1243/chrome-headless-shell-mac-arm64/chrome-headless-shell
"$CH" --headless --hide-scrollbars --screenshot=screens/radio-375.png \
  --window-size=375,1500 --virtual-time-budget=8000 "http://localhost:5199/?view=sources"
```

**没验的**：hover / focus / active / disabled 四态只能靠读 CSS，headless 截图拍不到；
触屏真机（iOS Safari）没跑；Tauri 桌面窗口里的实际渲染没截（只截了浏览器预览）。

## 仍然没解决的（需要外部输入或下一轮）

1. **真实 `.mbl`**：码表与路径映射都只被合成样本验证过。给我一个文件，`mbl tags` 一条命令就能定论。
2. **真实古典库**：本机 18 首、古典 0 首，命中率无定义。
3. **指挥家/乐团词典**：已知缺口，`album_artist` 是指挥时会被误认成作曲家。
4. **电台内嵌播放**：需要播放内核支持任意 reader。
5. **触屏真机与 hover/focus 态**：截图拍不到。
