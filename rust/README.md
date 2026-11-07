# Awake · Rust 重构

Swift 版 Awake 的 Rust 重建工程，架构：**Tauri 2 + Vue 3 + Rust**。
音频核心与 Swift 侧数值对齐，曲库层行为一致，界面为全新实现。

## 结构

```
rust/
  Cargo.toml                    # workspace
  crates/
    awake-core/                 # 音频与曲库核心（库，可被任何前端复用）
      src/decode.rs             # 解码：symphonia
      src/eq.rs                 # 31 段 EQ：biquad 级联
      src/analyze.rs            # 32 段频谱：rustfft
      src/resample.rs           # 重采样：rubato
      src/models.rs             # Track / Album / MediaSource
      src/metadata.rs           # 标签与封面：lofty
      src/library.rs            # 扫描、增量索引、持久化
    awake-cli/                  # 命令行验证器（不依赖 GUI，可脚本化验证）
    awake-app/                  # Tauri 后端 + IPC 命令
ui/                             # Vue 3 + Vite 前端
```

## 验收方式

```bash
cd rust

# 1. 单元测试（22 个）
cargo test

# 2. 读格式
cargo run --bin awake-cli -- probe ../DemoMusic

# 3. 曲库扫描（9 首 / 3 专辑）
cargo run --bin awake-cli -- scan ../DemoMusic

# 4. 频谱画像
cargo run --bin awake-cli -- analyze "../DemoMusic/03 频谱边界/02 - 低频拍频.flac"

# 5. EQ 处理 + 削波检查
cargo run --bin awake-cli -- eq-test "../DemoMusic/01 夜航/01 - 低频原点.flac"

# 6. 真实播放 3 秒
cargo run --bin awake-cli -- play "../DemoMusic/01 夜航/03 - 高频星尘.flac" 3

# 7. 启动桌面应用
cargo run -p awake-app
```

## 与 Swift 版的数值对齐（已用测试锁定）

| 项 | Swift | Rust |
|---|---|---|
| 频段 | 31 段 ISO 1/3 倍频程 | 逐项一致 |
| 每段 Q | 1/3 倍频程 | ≈ 4.3185 |
| headroom | `-(max_gain + margin)` | 同公式 |
| 曲目 ID | sha256(source\|locator) 短哈希 | 同规则，16 位十六进制 |
| 增量扫描 | size + mtime（<1s） | 同规则 |
| 封面优先级 | 内嵌 > 同目录 sidecar > 专辑传播 | 同顺序 |
| 采样率 | 按曲目切设备采样率 | 先协商原生，不支持才重采样 |

## 打包

```bash
# 前端产物
cd ui && pnpm build

# Release 二进制
cd ../rust && cargo build -p awake-app --release

# 组装 .app（脚本化，避免 tauri CLI 的路径依赖）
cd .. && cp rust/target/release/awake-app dist-rust/Awake.app/Contents/MacOS/Awake
codesign --force --deep --sign - dist-rust/Awake.app
open dist-rust/Awake.app
```

产物：`dist-rust/Awake.app`（16 MB，已 ad-hoc 签名，可双击运行）。

> 注意：`tauri.conf.json` 已移除 `devUrl`，release 包直接使用嵌入的前端资源。
> 前端改动后必须重新 `pnpm build` 再编译 Rust，否则界面不会更新。

## 数据落盘

`~/Library/Application Support/Awake/`
- `library.json` —— 曲库快照
- `artwork/` —— 从内嵌标签提取的封面

## 已迁移 / 未迁移

已迁移：解码、31 段 EQ、32 段频谱、重采样、采样率协商、音频输出、曲库扫描与增量索引、元数据与封面、桌面应用壳与 IPC。

未迁移：WebDAV / Plex / SMB 来源、歌词与逐句翻译、AutoEQ 耳机库与偏好学习、在线更新、DSD/APE 解码兜底（需 ffmpeg 或 libav）。
