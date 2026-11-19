# Awake iOS 0.9.6

iOS 17+。这一版只处理一件事：**本地文件「选不了、导不进、播不出」**。上一版修的是导入流程里的容错，这一版再往下挖了两层——选择器的类型过滤、以及解码/播放对单一格式的依赖。

## 1. 选文件不再被类型过滤挡住

`fileImporter` 之前用 `.audio` 过滤。iOS 只认系统已声明的音频 UTI，**FLAC / ALAC / APE / DSF 在「文件」里常被归成 `public.data`，用 `.audio` 过滤时会直接灰掉**——表现就是「本地文件根本选不了」。现在：

- 选择器放行全部普通文件（`.data`），音频扩展名由导入逻辑自己判断，不支持的文件会明确报「不是音频」；
- `Info.plist` 声明了 `org.xiph.flac` / `com.apple.alac` / `org.xiph.opus` / `org.monkeysaudio.ape` / `org.wavpack.wv` / `com.sony.dsf` 六种导入类型，Files 里显示为音频、其它 App 的「用 Awake 打开」也认这些格式；
- `CFBundleDocumentTypes` 一并加入这些类型。

## 2. 导入不再依赖单一解码器

`AVAudioFile` 打不开的容器之前会让整个文件导入失败。现在先试 `AVAudioFile`（能拿到采样率），失败退回 `AVURLAsset`（只拿时长），两者都不行才报错，并把原始错误写进诊断日志。

## 3. 播放增加 AVPlayer 回退

`AVAudioFile` 不认的文件（部分 FLAC 变体、APE、DSD 等）之前会直接弹「播放失败」。现在自动切到 `AVPlayer` 直出：能播放、能暂停/拖动、能接下一首，只是**没有 31 段 EQ**；能解码的文件仍然走原来的 AVAudioEngine + EQ 链路。切换曲目时会重新尝试主链路。

## 4. 设备端自检与诊断日志（重签包没有 Xcode 日志）

设置 →「自己的音乐来源」下新增：

- **导入 / 播放自检**：检查沙盒写入、Files 可见性、生成 1 秒 WAV 再读回来的完整解码链路，一页结论；
- **分享诊断日志**：`Documents/Awake/diagnostics.log`（Files App 里可见），记录每次导入失败的文件与原始错误、文件夹扫描统计、以及转 AVPlayer 回退的事件。

## 关于「全能签 + 自购证书」重签

App 本身不需要额外 entitlement 就能通过系统文件选择器读文件（安全作用域 URL 由系统授予）。重签时请注意三点：

1. **App ID 不要用通配符（`com.xxx.*`）**。通配符下钥匙串不可用，保存 WebDAV / Plex 凭据会报「无法保存到系统钥匙串」；本地导入不受影响。
2. 签名工具要保留原始 `Info.plist`（本版的音频类型声明在里面）。若工具会重写 plist，请把本仓库 `ios/Info.plist` 的内容合并进去。
3. 从 iCloud Drive 选文件时，先在「文件」App 里把它下载到本机；未下载的文件系统会拒绝复制——这一版会在诊断日志里写清楚。

## 验证（2026-11-19 本机）

- `xcodebuild build-for-testing` → `TEST BUILD SUCCEEDED`。
- `bash Tools/build_ios_app.sh` → `** ARCHIVE SUCCEEDED **`；IPA 内 `CFBundleShortVersionString` = 0.9.6、`CFBundleVersion` = 22、`UTImportedTypeDeclarations` 已嵌入（抽查 `org.xiph.flac`）。
- `LibraryImport` 逻辑 harness（真实源码，macOS 上 `swiftc` 编译）：15 项断言仍全过。
- **没有真机验证**：本机模拟器的 XCTest 服务仍不可用，重签环境也无法在这里复现。请用新 IPA 重签后，进设置点一次「导入 / 播放自检」，并把「分享诊断日志」得到的文件发我——那里面会有设备上的真实结论。

## 已发布产物

- GitHub Release：tag `ios-v0.9.6`，资产 `Awake-0.9.6-ios-arm64-unsigned.ipa`（3,156,428 字节，sha256 `9d6dcb398796785d63bddd1fba6005c85cc4dc64d9743e2751935a2aae756e1a`）与同名 `.sha256`。未签名，需自行重签。
- 同一份 IPA 已复制到 iCloud Drive：`iCloud Drive/Awake-0.9.6-ios-arm64-unsigned.ipa`。
