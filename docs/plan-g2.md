# G2 计划（需求 1 / 2 + G1 收尾项）

日期：2026-11-14。v0.9.0 已发布，G2 在 main 上直接开发。

## 范围

| # | 来源 | 内容 | 优先级 |
|---|------|------|--------|
| 1 | 需求 1 | Plex sourceKind 修复：applyPlexServer() 补 `sourceKind.value = "plex"` | P0 |
| 2 | 需求 2 / G1 收尾 | 音乐生成表单加预置平台下拉（与策展侧对齐，复用 curator 同款组件） | P0 |
| 3 | G1 收尾 | 深夜档成就改用本地时区（chrono::Local 替代 UTC 取模） | P1 |

> 修订（2026-11-15）：原表第 2 行与第 4 行是同一件事（音乐生成表单的预置下拉），
> 写法不同而已，已合并为第 2 行。实际交付见 `audit-g2-0.9.1.md` 与
> `audit-residual-g1-g2.md`。

## 不做

- 真机点击回归（需要用户配合）
- Plex 真实账号端到端（需要用户提供凭据）
- iOS 侧改动

## 预期产出

- Rust 测试 ≥ 97 passed（新增深夜档本地时区测试）
- 前端 vue-tsc 无错
- 一个 feat commit，不 push

## 实际产出（2026-11-15 补记）

- `a7305fe` G2 实现，`e14a604` 版本号 0.9.1，`v0.9.1` 已发布。
- 三项都落地，但当时**没有自动化拦着**：`App.vue` 的赋值和下拉过滤、`chrono` 调用
  都在无测试覆盖的区域，发行说明里只能写「code review confirmed」。
- 版本号只改了 `Cargo.toml` 与 `package.json`，侧栏与 `frontend_ready` 上报仍写 0.9.0。
- 以上两条在 `audit-residual-g1-g2.md` 里收口：补前端测试通道（15 项）、版本号单点来源。
