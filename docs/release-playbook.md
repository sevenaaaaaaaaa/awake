# 发版手册

> 这份文件定义「一次大版本收尾」要做什么、按什么顺序、产物放哪。
> 灵魂卡（`~/.dsh/prompt-inject.md`）里有同一条纪律的简版：**大版本做完自动发，不用提醒**。
> 这里是可以照着敲命令的版本。

## 1. 什么时候算一次大版本

- 一个批次里的一个完整步骤收尾（S1、S2、S3、S4），或一个独立的修复版本；
- 用户说「发一版」；
- 判定标准：**别人拿到这个包，能感知到一处真实变化**。单纯重构、补注释、改文档不算。

小改动照旧只提交，不发版。避免把 release 列表刷成一堆「改了个错别字」。

## 2. 版本号

- 形式 `0.9.X`，X 递增，一个版本一次，不跳号、不复用。
- 桌面与 iOS **用同一个号**。两端代码在同一棵树上，版本号是同一批的标记，不同步会让「哪版」说不清。
- 递增时五处一起改（见下），少一处前端的一致性测试会红。

## 3. 五处同步

| 文件 | 字段 |
| --- | --- |
| `rust/Cargo.toml` | `version` |
| `ui/package.json` | `version` |
| `ui/src/version.ts` | `APP_VERSION` |
| `rust/crates/awake-app/tauri.conf.json` | `version` |
| `ios/project.yml` | `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`（后者每次 +1） |

改完 iOS 那份要 `cd ios && xcodegen generate`，否则 `project.pbxproj` 里还是旧号。

## 4. 发布前检查（全绿才发）

```sh
cargo test --manifest-path rust/Cargo.toml -p awake-core -p awake-app --lib
npm test --prefix ui
npx --prefix ui vue-tsc --noEmit    # 或 npm run build --prefix ui
```

iOS 至少 `xcodebuild ... build` 通过（不签名也能验编译）。有一条红就停下修，不带着红发布。

## 5. 本地一条链（CI 不可用时走这条）

```sh
# 桌面
AWAKE_ARCHS=arm64 bash Tools/build_rust_app.sh
defaults read dist-rust/Awake.app/Contents/Info.plist CFBundleShortVersionString
codesign --verify --deep --strict dist-rust/Awake.app

# 安装（先备份旧版）
ditto /Applications/Awake.app /tmp/Awake-<旧版本>-backup.app
rm -rf /Applications/Awake.app && ditto dist-rust/Awake.app /Applications/Awake.app
open -a /Applications/Awake.app

# iOS（unsigned，真机需重签）
bash Tools/build_ios_app.sh
unzip -p dist-ios/Awake-<版本>-ios-arm64-unsigned.ipa Payload/Awake.app/Info.plist > /tmp/ipa.plist
plutil -extract CFBundleShortVersionString raw /tmp/ipa.plist

# 送到 iCloud
cp dist-ios/Awake-<版本>-ios-arm64-unsigned.ipa* \
   "$HOME/Library/Mobile Documents/com~apple~CloudDocs/"
shasum -a 256 "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Awake-<版本>-ios-arm64-unsigned.ipa"
```

最后一步必须**重算哈希并与 `.sha256` 比对**，不能"拷过去就算数"。

## 6. 线上打包（推荐，省本机资源）

`.github/workflows/release.yml` 提供两个产物：`Awake-<ver>-macos-arm64.zip` 与
`Awake-<ver>-ios-arm64-unsigned.ipa`（都带 `.sha256`）。

- 触发：推送 `v<ver>` tag，或在 Actions 页面手动运行并填版本号。
- 计费：仓库是公开的，GitHub-hosted macOS runner 不额外计费；私有仓库会烧分钟数。
- 已知限制：runner 的 Xcode 版本由 GitHub 决定，不一定是本机那套 beta。若代码用到更新的 SDK，
  iOS job 会红——那就退回本地打包，并把失败原因记在 release note 的「已知边界」里。
- CI 红**不发布**：先修，再从头走。

## 7. 产物与位置

| 产物 | 本地位置 | 线上位置 |
| --- | --- | --- |
| macOS App | `dist-rust/Awake.app` → `/Applications/Awake.app` | Release 附件 `Awake-<ver>-macos-arm64.zip` |
| iOS IPA | `dist-ios/Awake-<ver>-ios-arm64-unsigned.ipa` | Release 附件 + iCloud Drive 根目录 |
| 发布说明 | `docs/releases/v<ver>.md` | Release 正文 |

iCloud 目录：`~/Library/Mobile Documents/com~apple~CloudDocs/`。

## 8. 失败与回滚

- 构建失败：不提交、不打 tag。现有版本不受影响。
- 已推送但安装的 app 有问题：`ditto /tmp/Awake-<旧版本>-backup.app /Applications/Awake.app` 回退。
- 已发布的 tag 有问题：**不删 tag、不改历史**（除非用户明确要求）。补一个 `0.9.X+1` 修掉，
  在 release note 里写清上一版哪里不对。
- IPA 未签名装不上：这是预期行为，走重签流程，不是发版失败。

## 9. 不自动化的事

- 真机上装 IPA、点一遍验收；
- App Store 上架与审核；
- 含密钥的产物（本仓库不发带凭据的包）。

这三件事写进每次的汇报里，不假装已经做了。
