# G2 审计记录（需求 1 / 2 + G1 收尾项）

日期：2026-11-14（v0.9.1 发布当天）。收口与补防线见 `audit-residual-g1-g2.md`。

## 1. 改了什么

| # | 需求 | 落点 | 文件 |
| --- | --- | --- | --- |
| 1 | Plex `sourceKind` | `applyPlexServer()` 补 `sourceKind.value = "plex"` | `ui/src/App.vue` |
| 2 | 音乐生成预置下拉 | 与策展侧同款下拉，过滤 `kind === "music" \|\| kind === "both"` | `ui/src/App.vue` |
| 3 | 深夜档本地时区 | `chrono::Local` 取小时，测试改为按本地 2:00 构造时间戳 | `rust/crates/awake-app/src/insight.rs` |
| — | 依赖 | `chrono 0.4`（clock feature） | `rust/Cargo.toml` |

## 2. 判定

- 需求 1 的根因来自 G1 审计 §4c：`section` 一直在传、后端一直按分区过滤，断点在**来源类型**。修的是类型，不是分区。
- 需求 2 与 G1 审计 §5.3 是同一件事，计划表里写了两行（第 2、4 行），实为一件事。

## 3. 测试证据

```
cargo test --manifest-path rust/Cargo.toml -p awake-app --lib
test result: ok. 97 passed; 0 failed; 10 ignored
npm run build --prefix ui
dist/assets/index-*.js 298.08 kB │ gzip: 102.76 kB
```

## 4. 当时没有做到的（本轮遗留的源头）

1. **三处改动都没有自动化测试。** 前端没有测试框架，`App.vue` 的赋值与过滤、`chrono` 的调用都不在 `cargo test` 的射程内。发行说明只能写「code review confirmed」。
2. **版本号只改了两处。** 侧栏 `0.9.0 / PERSONAL`、`frontend_ready` 上报 `0.9.0` 都没改；`chore: bump version` 的 diff 只有 `Cargo.toml` 和 `package.json`。
3. **没有真机点击、没有真 Plex 账号。** 与计划里的「不做」一致，但这也意味着需求 1 的修复从未在真实服务器上验证过。

以上 1、2 已在 `audit-residual-g1-g2.md` 收口；3 仍需要用户配合。

---

## 5. v0.9.1 构建与产物核对（补充记录）

上面的 1–4 节记的是「改了什么、留了什么」。本节补上构建产物这一层的实测结果，因为发行说明写「构建通过」时，得能指到具体数字。

### 5.1 桌面端（universal）

```
AWAKE_ARCHS="arm64 x86_64" bash Tools/build_rust_app.sh
Finished `release` profile [optimized] target(s) in 25m 59s
Built: dist-rust/Awake.app (x86_64 arm64)
```

- `codesign --verify --deep --strict` → 通过
- `lipo -archs` → `x86_64 arm64`
- `CFBundleShortVersionString` / `CFBundleVersion` → 0.9.1
- 可执行文件 48,512,592 bytes；.app 48 MB；分发 zip 16 MB
- 隔离 HOME 启动：`FRONTEND_READY version=0.9.1 tracks=0`，前端挂载后主动结束，无残留进程

### 5.2 iOS（未签名 IPA）

- `Payload/Awake.app/Info.plist` → `CFBundleShortVersionString 0.9.1`、`CFBundleVersion 19`
- 大小与 0.9.0 一致（3,106,565 bytes）——本轮 iOS 侧只有音频会话修复这一处，不含桌面端的三项改动

### 5.3 结论边界

构建能证明的只是「这份二进制能起来、版本号对、签名有效」。界面上的三处修复是否真的生效，仍然只有回到 §4.1 说的那条路上才能确认：要么补测试，要么真机点一次。这一节不改变 §4 的判断。
