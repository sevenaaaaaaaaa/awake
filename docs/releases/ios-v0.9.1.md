# Awake iOS 0.9.1

iOS 17+，未签名 IPA，需自行重签。

## 这一版有什么变化

**功能上没有变化。** 0.9.1 的改动（Plex 来源类型修正、深夜档本地时区、音乐生成预置下拉）全部在桌面端的 Rust 与 Vue 代码里，iOS 侧源码一个字没动。

这个 IPA 存在的唯一理由是版本号与桌面端对齐：桌面出到 0.9.1，手机停在 0.9.0 会在「关于」里显得两端不同步。

## 与 0.9.0 的关系

- 接力协议 v2 不变，双向接力照旧，与 0.9.0 完全兼容。
- 曲库、备份、耳机档案等所有用户数据格式不变，升级不会迁移任何东西，也不会丢数据。
- 如果你已经在用 0.9.0 且不需要版本号对齐，可以不重装。

## 构建

- `xcodegen generate --spec ios/project.yml` → `xcodebuild archive`（`CODE_SIGNING_ALLOWED=NO`）→ 打包为未签名 IPA。
- 构建配置：`MARKETING_VERSION 0.9.1`、`CURRENT_PROJECT_VERSION 19`。
- 未验证：真机安装。IPA 未签名，需要自行用 AltStore / Sideloadly / 自己的证书重签。
