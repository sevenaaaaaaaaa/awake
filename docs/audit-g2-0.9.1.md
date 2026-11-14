# G2 审计记录（需求 1 / 2 + G1 收尾）

日期：2026-11-15。范围：Plex 来源类型修正、音乐生成侧预置下拉、深夜档本地时区。
基线：v0.9.0（G1 交付 97 项测试）。

## 1. 改了什么

| # | 来源 | 落点 | 文件 |
| --- | --- | --- | --- |
| 1 | 需求 1 | Plex 填入服务器信息时把来源类型设为 `plex` | `ui/src/App.vue`（`applyPlexServer`） |
| 2 | 需求 2 | 音乐生成服务表单加预置平台下拉（只列 `kind` 为 `music`/`both` 的平台） | `ui/src/App.vue` |
| 3 | G1 收尾 | 深夜档成就改用本地时区判定 0–5 点 | `rust/crates/awake-app/src/insight.rs` |
| 4 | G1 收尾 | 新增 `chrono`（仅 `clock` 特性）依赖 | `rust/Cargo.toml`、`rust/crates/awake-app/Cargo.toml` |

## 2. 需求 1：Plex 的真正断点

G1 审计里已经定位到：`applyPlexServer()` 只写了 `sourcePath / sourceSecret / sourceName`，没有把 `sourceKind` 设成 `plex`。于是点「连接曲库」时 `connectSource()` 走的是 `sourceKind === "local"` 分支，把 `http://…` 当作本地路径去扫。

G2 的改动是在 `applyPlexServer()` 开头补一行：

```ts
sourceKind.value = "plex";
```

这样选完服务器后，界面上的来源类型会立刻切到 Plex，「连接曲库」走 `connect_source`（Rust 侧 `remote::plex()`，按 `section` 过滤）。

**没有做的事**：没有用真实 Plex 账号跑一遍。这条仍然是「读代码 + 类型检查」得出的结论，需要用户拿自己的账号在界面上点一次确认。G1 审计里说的「先用真实账号复现确认再改」，事实上是先改了——因为改动只有一行、且逻辑上无歧义；复现留给用户验收。

## 3. 需求 2：音乐生成侧预置

0.9.0 只有策展侧有预置下拉。这次把同一份 `presets` 数组接到音乐生成表单上，过滤条件是 `kind === 'music' || kind === 'both'`。当前清单里只有硅基流动标了 `both`，其余 8 家都是 `curator`，所以下拉里只有一项——这是**如实反映清单**，不是漏了。要扩容就在 `preset.rs` 里把对应平台的 `kind` 改成 `both`，前端不用动。

## 4. 深夜档时区

原实现：

```rust
matches!((seconds % 86_400) / 3_600, 0 | 1 | 2 | 3 | 4)
```

这是 UTC 小时。东八区用户 08:00–12:59 听的歌会被算成「深夜」。改成：

```rust
chrono::DateTime::from_timestamp(seconds as i64, 0)
    .map(|utc| utc.with_timezone(&chrono::Local).hour())
    .map_or(false, |h| h < 5)
```

**测试跟着改了一处，这是本轮唯一一次让测试变红再变绿：** 原测试用固定时间戳 `86_400 * 20_000 + 3_600`（01:00 UTC）断言「算 2 次深夜」。改成按本地时区判定后，这个时间戳在东八区是 09:00，断言立刻失败（`left: 0.0, right: 2.0`）。改为在测试里动态构造「本地今天 02:00」的时间戳，秒和毫秒两种写法各一条，断言仍然是 2。

这条失败是有价值的：它证明测试真的在验「本地时间」这件事，而不是验「函数跑过了」。

## 5. 测试与构建证据

```
cargo test --manifest-path rust/Cargo.toml -p awake-app --lib
test result: ok. 97 passed; 0 failed; 10 ignored; 0 measured; 0 filtered out
```

与 v0.9.0 同为 97 项：本轮没有新增用例（改的是实现与既有用例的时间构造），没有删除用例。

前端：

```
npm run build --prefix ui
dist/assets/index-DMDH6tzs.js   298.08 kB │ gzip: 102.76 kB
```

`vue-tsc --noEmit` 无类型错误。较 0.9.0 的 297.27 kB 增加 0.81 kB（预置下拉的模板与分支）。

## 6. 没有验证到的（不打折地说）

1. **没有真机点击回归。** 没有启动 App 去点 Plex 登录、没有点音乐生成侧的预置下拉。
2. **Plex 端到端仍未跑。** 需要真实账号与在线服务器。
3. **音乐生成侧预置只有一项可选。** 清单里标 `both` 的只有硅基流动；这是数据现状，不是 bug。
4. **深夜档只用单元测试验了当前时区。** 没有跨多个时区跑；测试里用 `chrono::Local::now()` 取当天日期，跨零点运行理论上仍成立（构造的是「今天 02:00」，无论当前几点都在 0–5 区间内）。

## 7. 手工复核步骤

1. 打开 App → 音乐来源 → 来源类型选 Plex → 「用 Plex 账号登录」→ 授权后选服务器 → **确认来源类型下拉自动变成 Plex**（这是本次修复的可观察点）→ 点「连接曲库」→ 应提示「Plex 曲库已连接：N 首」，而不是「扫描到 0 首」。
2. 灵感工作室 → 「音乐生成服务」→ 「预置平台」下拉 → 应有一项「硅基流动」→ 选中后地址与模型被填入。
3. 推荐页 → 成就 → 「深夜档」的计数应只统计本地时间 0–5 点的收听。
