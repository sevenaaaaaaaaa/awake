# Awake · 仓库规则

给进入这个仓库的任何 agent。规则不随会话消失，做完一轮读一遍。

## 发版

一次大版本收尾（S1/S2/S3/S4 这类）**自动走完整发版链**，不用等用户提醒：
验证 → 五处版本同步 → 提交 → push main → 打 tag → GitHub Release → 更新 /Applications/Awake.app
→ 构建 IPA 并连 `.sha256` 复制到 iCloud Drive → 汇报。

细节与命令见 [docs/release-playbook.md](docs/release-playbook.md)。
线上打包见 `.github/workflows/release.yml`（公开仓库的 macOS runner 不额外计费）。

## 测试

```sh
cargo test --manifest-path rust/Cargo.toml -p awake-core -p awake-app --lib
npm test --prefix ui
```

iOS：`cd ios && xcodegen generate` 后 `xcodebuild -project ios/Awake.xcodeproj -scheme AwakeIOS \
-sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`。

## 硬约束

- 版本号五处同步：`rust/Cargo.toml`、`ui/package.json`、`ui/src/version.ts`、
  `tauri.conf.json`、`ios/project.yml`（含 `CURRENT_PROJECT_VERSION` 递增）。
- 新增 iOS `.swift` 文件必须 `xcodegen generate`，否则不进 target。
- `dist-*`、`node_modules`、`rust/target` 不入库。
- 不删已发布的 tag、不改写已推送的历史（除非用户明确要求）；不把含密钥的东西推到公开仓库。
- 验收没做就写「未验证」，不写「通过」。
