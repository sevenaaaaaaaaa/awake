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
