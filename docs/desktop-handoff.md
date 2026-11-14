# 桌面端交接（给单独开的那条对话）

这份文件写给「专门做电脑端适配」的那条新对话：它没有本轮上下文，靠这份文件起步。
移动端的工作留在原来的对话里继续。

## 先读什么

| 顺序 | 文件 | 为什么 |
| --- | --- | --- |
| 1 | `docs/roadmap.md` | 需求 1–6 的落点、未闭合项按「谁能推进」分类 |
| 2 | `docs/audit-residual-g1-g2.md` | 上一轮残留收口，含本轮补的版本号守卫与两处陈旧 |
| 3 | `docs/releases/v0.9.2.md` | 当前版本在交付什么 |
| 4 | `README.md` | 边界：网盘 OAuth、公共源目录这些明确不做 |

## 电脑端这边的待办

1. **响度匹配 A/B（roadmap §3.3 C）**：先算 LUFS 与峰值，再做等响切换。验收要求两个版本切换时主观音量不跳，且**有数值断言**。
2. **洞察面板口径校验（§3.3 D）**：用真实收听数据核对 30 秒门槛与连击定义，必须与 `rust/crates/awake-app/src/insight.rs` 的 `HEARD_SECONDS` 同源。
3. **前端测试通道继续铺（§3.3 A）**：`npm test --prefix ui` 现在 17 项（gaps / plex / version）。下一步是把 `useAwake` 的队列与偏好更新抽成纯函数后补测——所有播放状态都在那里，是静默失效的高发区。
4. **需求 3 仍然没有落点**：仓库里除了路线图那句之外零命中。这条只有用户能补。
5. **清理项**：`Resources/AwakeInfo.plist` 还是 0.2.0 + `com.seewow.awake`，只有旧 Swift 路径 `build_awake.sh` 会 `cp` 它。Rust 包不读，但谁哪天走那条脚本就会打出包 ID 和版本都错的包。

## 本地怎么跑

```bash
npm install --prefix ui
npm test --prefix ui                 # 17 项
cargo test --manifest-path rust/Cargo.toml -p awake-app --lib   # 97 项
AWAKE_ARCHS=arm64 ./Tools/build_rust_app.sh                     # 打出 dist-rust/Awake.app
```

`build_rust_app.sh` 里有 `lsof` 守卫：包内可执行文件正在运行时会直接停下，不会覆盖出一个半成品。

## 两条纪律（这个仓库自己的规矩）

- **判断「做完了」必须有一个能红的东西**：一条测试、一次实跑输出、或一份带数字的日志。没有就写「未验证」。
- **别把系统的英文错误直接弹给用户**。0.9.2 修的就是这件事：`AudioFailure.describe` 把 OSStatus 翻成中文并保留码值。前端侧同样适用。
