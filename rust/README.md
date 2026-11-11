# Awake Rust 主线

当前版本 **0.6.0**。完整能力、使用方式和验收边界见[项目 README](../README.md)。

```bash
# 仓库根目录
npm ci --prefix ui
./Tools/build_rust_app.sh
open dist-rust/Awake.app
cargo test --manifest-path rust/Cargo.toml -p awake-core -p awake-app --lib
cargo test --manifest-path rust/Cargo.toml -p awake-app --lib real_output -- --ignored --nocapture --test-threads=1
```

`awake-core` 提供流式解码、连续重采样、参数 EQ、元数据/曲库、偏好排序和订阅匹配。`awake-app` 提供有界 PCM 输出、后端队列、服务器连接、系统钥匙串、后台刷新、AI 服务调用和作品任务。`awake-cli` 保留原音频诊断工具。

当前不宣称已完成硬件 bit-perfect/DAC 回环验证、独占模式、自动识别并认证耳机测量、原生网盘 OAuth、SMB 自动挂载或 DSD/APE 转码。真实服务器和付费 AI 服务需配置对应账号后验收。
