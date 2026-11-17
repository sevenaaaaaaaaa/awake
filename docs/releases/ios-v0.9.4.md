# iOS 0.9.4

iPhone / iPad，iOS 17+。未签名 IPA，需要自行重签后安装。这一轮修的是「导入与刷新的结果能不能信」：重复导入不再造副本、远程来源可以删掉、Plex 扫描不再把不完整的结果当成完整结果。

## 本次修正

- **Plex 刷新只提交完整且有效的结果**。分页到 20000 首上限时，以前直接停下并返回已经拿到的部分曲目；现在满页且 `totalSize` 表明还有后续页、或响应里没有 `totalSize` 可核对，都按失败处理。响应不是可识别的 Plex 音乐目录、所有分区合计没有曲目，也按失败处理。失败保留原曲库，不会因为一次空结果把来源的旧曲目删光。
- **同一文件/文件夹重复导入不再生成副本**。稳定身份取标准化路径（`standardizedFileURL.resolvingSymlinksInPath().path`）：重复导入同一文件直接跳过，不新增记录、不新增缓存、Song ID 保持稳定；重新导入文件夹时按各文件的稳定路径去重，新文件追加，本次扫描中消失的文件从该文件夹的曲目集合移除。文件夹成员关系存进 `library.json` 的 `importedFolderPaths`，系统文件夹安全作用域 URL 不落盘。
- **远程来源可以移除了**。设置页每个 WebDAV / Plex / Telegram 来源都有「移除来源」，点两次确认。移除会一起清掉来源记录、所属曲目、歌单引用、听书记录、听书进度、`source.<id>` 钥匙串凭据和按 Song ID 命名的缓存音频；手动导入的本地曲目不受影响。实现上先把缓存文件移进暂存目录再提交持久化，任一步失败就整批回滚，不会出现「曲目删了、缓存还在」或「内存清了、磁盘没清」。

## 数据与兼容

- `library.json` 新增可选字段 `importedFolderPaths`；旧曲库缺这个字段时按空处理，直接可读。
- 歌单、听书记录、皮肤与备份文件格式未变。
- 桌面端 0.9.4 与 iOS 0.9.4 可以各自独立升级，接力协议 v2 不变。

## 验证（2026-11-17 本机）

- 构建：`xcodebuild build` = `** BUILD SUCCEEDED **`（退出码 0）；`xcodebuild build-for-testing` = `** TEST BUILD SUCCEEDED **`（退出码 0，测试代码可编译）。
- 纯逻辑：`PlexScanValidation`（`ios/Awake/Services.swift`）与 `LibraryImportIdentity`（`ios/Awake/Models.swift`）的真实源码行机械抽取后用 `swiftc` 独立编译执行，**12 项断言 / 0 失败**——覆盖满页且 totalSize 相等、totalSize 超出、totalSize 缺失、未满页、首页小结果、零分区报错、分区零曲目报错、正常库不报错；以及稳定 locator、重复命中同一 id、不同文件不误命中、只清理消失成员。
- 安装包：见下方「已发布产物」。

## 未验证

- **XCTest 未执行**。本机 Xcode-beta（27A5228h）没有 Simulator.app，`xcodebuild test` / `test-without-building` 停在起 test host：`DTServiceHubClient failed to bless service hub for simulator`（`Mach error -308`），无 `.xcresult`。`simctl erase`、换设备（iPhone 17 / iPhone 17 Pro / ProbeFresh）、`-parallel-testing-enabled NO`、先 build-for-testing 再 test-without-building 都试过。**build 成功不等于 XCTest 通过**，这条留作缺口，需要在完整 Xcode 或真机上补跑。
- 真机重签后的安装、导入与「移除来源」交互没有验证（需要开发者证书与真机）。
- 真实 Plex 账号的一次完整刷新没有跑（需要账号与服务器）。

## 已发布产物

- tag `ios-v0.9.4`，GitHub Release 标记 **Pre-release**（未签名 IPA，需要自行重签）。
- IPA 与 `.sha256` 见 Release 附件；本轮先发 tag 与说明，包在构建完成后补进 Release。
