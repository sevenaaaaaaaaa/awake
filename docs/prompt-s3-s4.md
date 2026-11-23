# 提示词：v2 批次剩下的两步（S3 / S4）

> 用法：新开一个会话，贴对应那一段。S2 的 iOS 部分见 `docs/prompt-s2-ios-selfcheck.md`。
> 基线：2026-11-23，S1 已完成（0.9.39），S2 桌面已完成、iOS 待补。
> 三份提示词都建立在同一批规则上：**期望值写死、不造函数凑数、没点过就不写「已验收」**。

---

## S3 · 先验按设备分组 + 导入策略（0.9.41）

### 目标

把「先验是全局一份」这个**算错**修掉：先验按耳机/输出设备分开存；导入档案时给「替换 / 叠加」二选一，
并记录来源耳机与已导入哈希。v2 把它归在「正确性」，不是新功能。

### 现在的代码

- iOS：`ios/Awake/Models.swift` 的 `EarPrior { version, gains, updatedAt, choices }` 没有 `headphone`；
  `MobileStore.applyingPrior` 用唯一一份 `state.earPrior`；校准页 `CalibrationView.swift` 写入它。
- 桌面：`rust/crates/awake-app/src/song_curves.rs` 的 `SongCurveStore.prior: Option<EarPrior>` 也只有一份；
  `import_listening_profile` 直接 `store.prior = Some(prior)`，连点两次是覆盖（不叠加，但也不区分设备）。
- 两端 `EarPrior` 已经有 `headphone: Option<String>`（Rust）/ 没有（Swift），字段命名要统一。

### 要做

1. **iOS**：`EarPrior` 加 `headphone: String`（空串表示「不知道」）；`AppState` 增加
   `earPriors: [String: EarPrior]?`，读取时回落到旧的 `earPrior`（迁移不能丢数据）；
   校准页写入当前 `player.route.name`；`applyingPrior` 按当前路由键选，
   没有匹配时**提示「这台设备还没校准」**，不要拿另一副耳机的先验顶上。
2. **桌面**：`SongCurveStore.prior` 改成 `priors: HashMap<String, EarPrior>`，
   键用 `headphone`（空串为默认桶）；导入时按 `prior.headphone` 落桶；
   `curve_for_track` 按当前输出设备选桶，选不到就 `prior_applied: false`。
3. **导入策略**：`import_listening_profile` 增加参数 `mode: "replace" | "merge"`；
   `replace` 清空该设备的旧记忆再写，`merge` 只覆盖同名曲；同时记 `imported.hash`
   （对规范化后的 JSON 取 sha256），同一份档案重复导入直接返回「已导入过」。
4. 界面：卡片上写「当前用 AirPods Pro 的先验 v2」；导入后若来源耳机 ≠ 当前输出，明确提示再让用户决定。

### 验收

- 两副耳机各校准一次 → 切换设备，先验跟着换，界面写明来源版本；
- 同一份档案连点两次导入 → 第二次不改变任何曲线，并说明「已导入过」；
- 老数据（没有 headphone 的先验）升级后仍生效，归到默认桶；
- 自检（S2）加一条：按设备选桶的纯函数，期望值写死。

### 注意

- 这是修「算错」，不是加功能。旧行为「换到监听耳机仍叠 AirPods 的先验」必须能说清改了哪一行。
- 迁移只增不减：不要为了结构干净丢掉用户已有的先验。

---

## S4 · 频谱依据（0.9.42）

### 目标

让「曲目」这一段第一次有数据：iOS 离线分析曲目前 30 秒，产出**低频重心 / 高频滚降 / 动态**三个数，
写进 R1 的「曲目」段；失效提示从「依据失效」升级为差异估计。

### 现在的代码

- iOS 没有频谱分析；`ios/Awake/Models.swift` 的 `CurveBasis { headphone, track, prior }` 只有字符串。
- 桌面 `rust/crates/awake-core/src/analyze.rs` 有 `Spectrum`（32 段）与 `SpectrumAnalyzer`；
  `decode.rs` 能解前 N 秒。两边口径必须一致，别各写一套频段划分。
- `ios/Resources/headphones-v1.json` 有静态耳机参数，可用于差异估计。

### 要做

1. iOS 新文件 `TrackSpectrum.swift`：`AVAudioFile` 读前 30 秒 → `vDSP` FFT →
   算三个数（低频 20–250 Hz 能量占比 / 8–16 kHz 滚降斜率 / 动态范围），**纯函数**，可单独断言。
2. 缓存：`Documents/Awake/spectrum/<file-hash>.json`，按 `mtime + size` 失效；
   分析在后台队列，失败即跳过，**绝不进播放路径**。
3. `CurveBasis` 加 `trackDetail: TrackDetail?`（三个数 + 分析版本），旧记录没有也照常读。
4. 依据文案：从「3:42 · 44 kHz」升级为「这首本身低频就多，所以只抬 1 dB」；
   文案由「三数 + 当前曲线方向」共同决定，写成一个纯函数，自检里锁死两条示例。
5. 失效提示升级：用 `headphones-v1.json` 把旧曲线套到新耳机目标上，算偏差最大的 3 个频段，
   写成「在 3 kHz 差了约 4 dB，建议重调」。算不出就退回现在的文案，不要编数字。

### 验收

- 同一首歌的摘要能说出「这首本身低频偏多」，且与曲线方向一致；
- 换一首低频少的歌，文案随之变化（不是模板换名字）；
- 冷启动播一首没缓存的歌，首播不因分析变慢（用计时对比，记下数字）；
- 自检加三条：三数计算的固定输入、文案函数的两个示例、缓存失效判定。

### 注意

- 频谱分析必须异步 + 缓存 + 失败跳过，这是 v2 明写的风险条目，不能图省事同步跑。
- 不和桌面的 `analyze.rs` 抢口径：先读它，抄它的频段边界，再写 iOS 侧。
