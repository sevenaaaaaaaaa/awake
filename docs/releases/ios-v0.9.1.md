# Awake iOS 0.9.1

iOS 17+，未签名 IPA，需自行重签。

## 这一版有什么变化

**没有新功能，但有一处会咬人的修复。**

桌面端的改动（Plex 来源类型、深夜档本地时区、音乐生成预置下拉）都在 Rust 与 Vue 里，iOS 不涉及。iOS 侧这一版只有一件事：

- **不再在 `App.init` 里碰音频会话。** 原来 App 一启动就调 `AVAudioSession.setCategory/setActive`，在某些机型上会和系统正在播放的音乐抢会话——轻则暂停用户的歌，重则报一个英文的音频错误弹在界面上。现在音频会话只在真要播放时配置，错误文案也改成了中文。

这条改动带测试：`ios/AwakeTests/AwakeTests.swift` 里新增 18 行断言。

## 与 0.9.0 的关系

- 接力协议 v2 不变，双向接力照旧，与 0.9.0 完全兼容。
- 曲库、备份、耳机档案等所有用户数据格式不变，升级不迁移任何东西。
- 已经装 0.9.0 且没遇到「启动就抢音频」的，这一版对你只有版本号上的意义。

## 构建

- `xcodegen generate --spec ios/project.yml` → `xcodebuild archive`（`CODE_SIGNING_ALLOWED=NO`）→ 打包为未签名 IPA。
- 构建配置：`MARKETING_VERSION 0.9.1`、`CURRENT_PROJECT_VERSION 19`。

## 未验证

- **没有在真机或模拟器上装过。** IPA 未签名，需要 AltStore / Sideloadly / 自有证书重签。
- 没有跑 XCTest：Xcode 27 beta 的 iOS 27 模拟器注入测试宿主会卡住，与 0.9.0 遇到的是同一个环境问题。
- 「不再抢音频会话」这条改动本身没有在 iPhone 上实测，只有编译与断言。
