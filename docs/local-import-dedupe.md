# 本地导入为什么会重复，以及现在的判重规则

发现：2026-11-24。现象是「扫描本地 Awake 文件夹」之后曲库里冒出大量 UUID 标题的曲目，
旧的与新的同时存在，每扫一次数量继续涨，界面越来越卡。

## 结论：不是「没判重」，是判重的三个前提都不成立

### 1. 扫描会吃到自己的缓存（主因，可复现）

导入时 App 把文件复制进 `Documents/Awake/Music/<UUID>.<ext>`，而用户能选的正好是
`Documents/Awake` 这一层。`importAudioFolder` 之前没有任何「这是我自己写的目录」的判断，
于是：

- 第 1 次扫描：发现 200 首用户文件 → 导入 → `Music/` 里多出 200 份副本；
- 第 2 次扫描：200 份副本被当成新文件 → 再导入 → 又写 200 份；
- 每一轮多一代，标题就是副本文件名（UUID），艺人自然是「未知艺人」。

`importOwnFolder` 有一条 `musicPrefix` 字符串前缀过滤，但只对它自己那条路径生效，
另一条路径（选择器选文件夹）没有，而且前缀比较在 `/var` 与 `/private/var` 两种写法下有漏。

**现在是扫描器统一执行**：`LibraryImport.audioFiles(in:limit:excludingManagedFrom:)`
把 `root/Music`、`root/Artwork`、`root/Speech`、`root/News` 整棵跳过，
两条导入路径（选择器 / 兜底文件夹）都传同一个 root。

### 2. 身份是绝对路径，而容器路径会变

判重键是 `URL.path`。App 数据容器带 UUID
（`/var/mobile/Containers/Data/Application/<UUID>/Documents/...`），重装、恢复备份、
部分升级路径会换掉它；选择器返回的还可能是 `/private/var/...`。

后果：同一个文件换了个绝对路径，在曲库里就是「新歌」。

**现在**：`LibraryImport.locator(for:documents:)` 把容器内的文件记成
`own:Awake/2.Blue Bird.mp3`，容器外仍是绝对路径；
`identityKey` 在比较时把旧档案里的任意容器绝对路径折成同一形式，
`/var` 与 `/private/var` 折成同一个身份。CUE 分轨的 `#cue-N` 后缀原样保留。

### 3. 旧曲目没有身份，内容相同也认不出

0.9.5 之前没有判重字段，老曲目的 `locator` 是空串，任何一次重扫都不可能命中。
另外同内容文件换个名字/目录（用户自己拷了一份）在路径判重下也是新歌。

**现在**：路径没命中时再用内容判一次——字节数 + 时长（0.1 秒粒度）+ 文件头 64 KB 的
FNV-1a 哈希。命中就沿用已有那条，只把 locator 更新成新地址。
「尺寸 + 时长」只是便宜的预筛，真正决定合并的是文件头哈希，避免两首同长不同歌被并掉。

## 已经长出来的重复怎么办

`MobileStore.repairLocalLibrary()`（启动时自动跑一次，设置 →「曲库维护」可手动再跑）：

1. 归一 locator；UUID 标题若能用 `originalFilename` 还原就还原；
2. 本地曲目按内容分桶（CUE 分轨共用同一文件，不参与内容合并）；
3. 每组保留「标题像人写的 > 被歌单/听书/评分引用过 > 有艺人/封面/歌词 > 更早导入」的那条；
   收藏、封面、歌词、评论、人工元数据从被合并项补到保留项；
4. 歌单、听书记录、听歌历史、评分、调音记录、每首歌的曲线、创作任务里的曲目 id 一起改指；
5. 只删除「合并后已无曲目引用」的缓存文件；另清 `Music/` 里超过 1 小时没人引用的孤儿文件；
6. 改动前把 `library.json` 复制成 `library.json.before-repair-<时间戳>`，只保留最近三份；
   写盘失败整批回滚。

另外，自己生成的音频（语音合成 / AI 作曲 / 内置示例）现在带 `cache:<file>` 身份，
不会因为 locator 为空被当成「同一条」，也不会被文件夹导入吃进去。

## 性能

一次导入只 `save()` 一次、只赋值 `state.songs` 一次（原来逐首写盘 + 逐首推界面，
上千首时就是幻灯片）；判重用字典索引，不再每首扫全库。

## 验证

```sh
# 纯逻辑：真实源码 + 26 项断言，本机可重跑
bash Tools/run_library_import_harness.sh

# 编译（含新增的 4 条 XCTest）
cd ios && xcodegen generate && xcodebuild -project Awake.xcodeproj -scheme AwakeIOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build-for-testing
```

- `Tools/run_library_import_harness.sh`：**26 项断言 / 0 失败**。覆盖托管目录整棵跳过、
  反复扫描候选不增长（旧行为可复现）、容器路径折叠、`/private/var` 归一、UUID 标题识别、
  内容指纹分组与保留规则。
- `xcodebuild build-for-testing`：**TEST BUILD SUCCEEDED**（新增测试能编译）。
- **XCTest 没有在本机跑起来**：这台机器没有 `Simulator.app`，`test-without-building`
  停在起 test host、日志 0 增长，已按 PID 终止。新增的 4 条用例
  （自吞缓存、换名重复、整理合并保引用、CUE 不合并）需要在真机或装了完整 Xcode 的机器上补跑。
- 桌面端（Rust）不复制文件进被扫描目录，本次未改；`cargo test --lib` 57 项通过，
  `npm test --prefix ui` 57 项通过，与本次改动无关，只作回归基线。
