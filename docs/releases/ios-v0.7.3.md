Awake 的原生 iPhone / iPad 测试版，最低 **iOS 17**。

**下载 Assets 中的 `Awake-0.7.3-ios-arm64-unsigned.ipa`。这是未签名的真机 ARM64 Release 包，需要自行重签后安装。** 本次通过 GitHub 分发，不属于 App Store / TestFlight 分发包。

## 音效应用与播放状态

- 应用音效时展示耳机 / 入耳图标、光环、短波纹与参数曲线过渡，约 2.6 秒自动收起，不阻挡操作。
- 迷你播放器、正在播放页与声音实验室显示增强开启、暂停就绪、EQ 旁路与原声状态。
- 点开标识可查看来源、前级及频段，并用“恢复 EQ 增强 / 临时聆听原声”切换。尊重系统减少动态效果。
- 本地 / 测量曲线显示 EQ+；只有明确 AI 来源且已实际应用的曲线才显示 AI EQ。现有 AI 文字建议不会自动开启 AI EQ。

## 本地聆听与主流设备

原生 AVAudioEngine 播放、文件 App 导入、长音轨跳转、相同格式连续队列、31 段 EQ 与参数校正、独立聆听链路、本地偏好、主观评分、A/B 与离线软件跑分。

收录 **75 个档案 / 18 个品牌分组**，覆盖 Sony、Bose、Sennheiser、Moondrop，以及 Apple、Samsung、Xiaomi / Redmi、Huawei、OPPO、OnePlus、vivo / iQOO、HONOR、realme、Pixel、Nothing 等代表型号。原道保留版本待确认登记入口。支持中文别名、品牌筛选与对应型号的公开测量查询；档案覆盖不表示全部具有实测 EQ。

WebDAV、Plex 与文件 App 中用户自行连接的 NAS / 网盘来源可用。远程曲目首次播放先缓存到本机，再进入统一 EQ 链路。

## 安装、升级与验证

- 请保留并备份自己的曲库与配置；重签时保持 Bundle ID、签名及安装方式一致，能否保留沙盒数据取决于所用工具。
- 21 项原生测试与 6 个界面流程验收通过（含最终播放页流程的针对性重跑）；IPA 的版本、架构、资源、CRC 与 SHA-256 已校验。
- 未做实体 iPhone 蓝牙 / 长期后台 / 触觉反馈验收，未调用真实付费 AI。无线编码由系统协商；云端服务需自行配置。
- 同时提交了本轮桌面 Rust / Tauri 重构源码；此次附件仅发布 iOS，不替换 macOS 稳定版更新入口。

[安装与功能说明](https://github.com/sevenaaaaaaaaa/awake/blob/ios-v0.7.3/ios/README.md) · [主流型号及出处](https://github.com/sevenaaaaaaaaa/awake/blob/ios-v0.7.3/docs/mainstream-headphones-v0.7.2.md) · [验证记录](https://github.com/sevenaaaaaaaaa/awake/blob/ios-v0.7.3/docs/validation-ios-v0.7.3.log)

Assets 同时提供 `SHA256SUMS` 和安装说明。下载到同一目录后可运行 `shasum -a 256 -c SHA256SUMS` 验证。
