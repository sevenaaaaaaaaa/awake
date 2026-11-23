# 提示词：补完 S2 的 iOS 自检页

> 用法：新开会话，把本文件整段贴进去，或直接说「读 docs/prompt-s2-ios-selfcheck.md 并执行」。
> 写于 2026-11-23 23:22，基线提交在 `crew` 之外的工作区（未提交）。

## 一句话目标

在 iOS 端补完 S2「两端自检」：新建 `ios/Awake/SelfCheck.swift`（8 条纯逻辑断言 + 一个页面），
在 `SettingsViews.swift` 的「诊断与数据」里接进入口，然后 `xcodegen generate` + 构建验证。

## 现在的状态（这些别重做）

已完成，且 `xcodebuild` 已通过（BUILD SUCCEEDED，exit=0）：

- `ios/Awake/Models.swift:356` 新增 `CurveBasis.fingerprint(duration:sampleRate:album:trigger:)`，
  `CurveBasis.make` 改为调用它。
  **行为有变，是故意的**：以前 trigger 为空时 `track` 会留下悬空的「 · 」，
  现在与桌面 `listening::track_fingerprint` 一致，空的那段直接不写。
- `ios/Awake/Models.swift:375` 新增 `enum EarRules`：
  - `maxGaindB: Float = 12`（与桌面 `MAX_GAIN_DB` 同一个数）
  - `applyingPrior(_:prior:enabled:)`
  - `basisMismatch(saved:now:)`
  - `basisHint(saved:now:)` —— 新加的失效文案，写法与桌面 `stale_hint` 一致
- `MobileStore.applyingPrior` 与 `MobileStore.basisMismatch` 已改为调用 `EarRules`，行为不变。

未做：

- `ios/Awake/SelfCheck.swift` 不存在；
- `SettingsViews.swift` 没有自检入口；
- 新增 `.swift` 文件后没有重新 `xcodegen generate`（新文件不进 target 会表现为「找不到 PureLogicCheck」）。

## 要写的 8 条（照抄，不要增删）

| id | 钉什么 | 期望值 |
| --- | --- | --- |
| prior.clamp | 10 + 5 必须限幅到 **12** | 写死 12 |
| prior.off | 关掉叠加**原样**返回 10 | 写死 10 |
| prior.absent | 没有先验时不动 | 写死 -3 |
| profile.roundtrip | 档案编码→解码：曲线数、先验版本、增益不丢 | 1 / 7 / 1.5 |
| basis.device | 大小写容忍；不同耳机失效；空值不失效 | true/false |
| basis.hint | 文案同时点名两边；成立时为空 | 含两个设备名 |
| basis.fingerprint | 222s / 44.1 kHz / 夜航 → 「3:42 · 44 kHz · 夜航」 | 整串相等 |
| basis.roundtrip | CurveBasis 编解码往返 + `make` 拼出的曲目段 | 整串相等 |

**不要为了凑 9 条去复制桌面的「档案解析」「同名不猜」**：iOS 不导入档案、不做曲名匹配，
那两条在 iOS 上没有对应函数。条数不同是刻意的。

## 完整代码

### ios/Awake/SelfCheck.swift（新建）

```swift
import Foundation
import SwiftUI

/// S2：设备内纯逻辑自检。
///
/// 规矩与桌面一致：**期望值写死**，不再调用一次生产函数算期望——
/// 否则改坏常量后两边一起变，永远绿，那不是自检，是复读。
///
/// 只锁纯函数。全绿不等于产品可用：界面、手势、真实耳机它都测不到。
enum PureLogicCheck {
  struct Item: Identifiable {
    let id: String
    let name: String
    let ok: Bool
    let detail: String
  }

  struct Report {
    let version: String
    let checkedAt: Date
    let items: [Item]
    var passed: Int { items.filter(\.ok).count }
    var total: Int { items.count }
  }

  static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
  }

  static func run() -> Report {
    var items: [Item] = []
    func near(_ actual: Float, _ expected: Float, _ what: String) -> String? {
      abs(actual - expected) < 0.0001 ? nil : "\(what)：期望 \(expected)，实际 \(actual)"
    }
    func check(_ id: String, _ name: String, _ body: () throws -> String?) {
      do {
        if let failure = try body() {
          items.append(Item(id: id, name: name, ok: false, detail: failure))
        } else {
          items.append(Item(id: id, name: name, ok: true, detail: ""))
        }
      } catch {
        items.append(Item(id: id, name: name, ok: false, detail: error.localizedDescription))
      }
    }

    check("prior.clamp", "先验叠加先加后限幅（10 + 5 → 12）") {
      let prior = EarPrior(
        version: 7, gains: [Float](repeating: 5, count: 31), updatedAt: Date(), choices: [:])
      let out = EarRules.applyingPrior(
        [Float](repeating: 10, count: 31), prior: prior, enabled: true)
      return near(out[0], 12, "10 + 5 应被限幅到 12") ?? near(out[30], 12, "末段也要限幅")
    }

    check("prior.off", "关掉先验时曲线原样") {
      let prior = EarPrior(
        version: 7, gains: [Float](repeating: 5, count: 31), updatedAt: Date(), choices: [:])
      let out = EarRules.applyingPrior(
        [Float](repeating: 10, count: 31), prior: prior, enabled: false)
      return near(out[0], 10, "关掉叠加应原样返回")
    }

    check("prior.absent", "没有先验时曲线原样") {
      let out = EarRules.applyingPrior(
        [Float](repeating: -3, count: 31), prior: nil, enabled: true)
      return near(out[0], -3, "没有先验时不应改动曲线")
    }

    check("profile.roundtrip", "听感档案导出 → 读回：曲线与先验不丢") {
      let curve = SongCurve(
        gains: [Float](repeating: 1.5, count: 31), apo: "", origin: .ai, source: "自检",
        updatedAt: Date(), basis: nil, basisDetail: nil)
      let prior = EarPrior(
        version: 7, gains: [Float](repeating: 1, count: 31), updatedAt: Date(), choices: [:])
      let profile = ListeningProfile(
        version: 1, device: "check", createdAt: Date(), prior: prior,
        curves: ["A": curve], titles: ["A": "夜航"])
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let back = try decoder.decode(ListeningProfile.self, from: encoder.encode(profile))
      guard back.curves.count == 1, back.prior?.version == 7 else {
        return "往返后条目数或先验版本不符"
      }
      guard back.curves["A"]?.gains.first == 1.5 else { return "往返后增益不符" }
      return nil
    }

    check("basis.device", "依据失效判定（大小写容忍、换耳机失效）") {
      guard !EarRules.basisMismatch(saved: "AirPods Pro", now: "airpods pro") else {
        return "只差大小写不该判失效"
      }
      guard EarRules.basisMismatch(saved: "AirPods Pro", now: "监听耳机") else {
        return "不同耳机必须判失效"
      }
      guard !EarRules.basisMismatch(saved: "", now: "AirPods Pro") else {
        return "不知道保存的是哪副时不该判失效"
      }
      return nil
    }

    check("basis.hint", "失效文案要点名两边") {
      let hint = EarRules.basisHint(saved: "AirPods Pro", now: "监听耳机")
      guard hint.contains("AirPods Pro"), hint.contains("监听耳机") else {
        return "文案要同时点名两边，实际「\(hint)」"
      }
      guard EarRules.basisHint(saved: "AirPods Pro", now: "airpods pro").isEmpty else {
        return "依据成立时不该有提示"
      }
      return nil
    }

    check("basis.fingerprint", "曲目依据指纹写法（3:42 · 44 kHz）") {
      let value = CurveBasis.fingerprint(
        duration: 222, sampleRate: 44_100, album: "夜航", trigger: "")
      guard value == "3:42 · 44 kHz · 夜航" else {
        return "期望「3:42 · 44 kHz · 夜航」，实际「\(value)」"
      }
      return nil
    }

    check("basis.roundtrip", "三段依据往返，make 拼出的曲目段正确") {
      let basis = CurveBasis(
        headphone: "AirPods Pro", track: "3:42 · 44 kHz · 夜航", prior: "校准 v3")
      let back = try JSONDecoder().decode(CurveBasis.self, from: JSONEncoder().encode(basis))
      guard back == basis else { return "往返后三段依据不一致" }
      let song = Song(title: "夜航", album: "夜航", duration: 222, sampleRate: 44_100)
      let made = CurveBasis.make(
        headphone: "AirPods Pro", song: song, trigger: "人声太远", prior: "校准 v3")
      guard made.track == "3:42 · 44 kHz · 夜航 · 人声太远" else {
        return "make 拼出的曲目段不对：「\(made.track)」"
      }
      return nil
    }

    return Report(version: appVersion, checkedAt: Date(), items: items)
  }
}

struct PureLogicCheckView: View {
  @State private var report: PureLogicCheck.Report?

  var body: some View {
    Form {
      Section {
        Text(
          "只锁纯函数：先验叠加、依据判定、失效文案、曲目指纹、档案往返。"
            + "全绿不等于产品可用——界面、手势、真实耳机它都测不到。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Button("运行自检", systemImage: "checkmark.seal") {
          report = PureLogicCheck.run()
        }
        .accessibilityIdentifier("runPureLogicCheck")
      }
      if let report {
        Section("结果 · \(report.passed)/\(report.total)") {
          ForEach(report.items) { item in
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 8) {
                Text(item.ok ? "PASS" : "FAIL")
                  .font(.system(.caption2, design: .monospaced))
                  .foregroundStyle(item.ok ? .secondary : .primary)
                Text(item.name).font(.callout)
              }
              if !item.detail.isEmpty {
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 2)
          }
        }
      }
    }
    .navigationTitle("纯逻辑自检")
    .appSurface()
  }
}
```

### SettingsViews.swift（两处小改）

1. `SettingsView` 第 150 行 `Section("诊断与数据")` 里，在现有 `NavigationLink { DiagnosticsSettingsView().environmentObject(store) }` 之前插入：

```swift
        NavigationLink {
          PureLogicCheckView().environmentObject(store)
        } label: {
          Label("纯逻辑自检", systemImage: "checkmark.seal")
        }
```

2. `DiagnosticsSettingsView` 的「自检与日志」Section 末尾再放一个同样的入口（用户从两个地方都能进）：

```swift
        NavigationLink {
          PureLogicCheckView().environmentObject(store)
        } label: {
          Label("纯逻辑自检（先验 / 依据 / 档案）", systemImage: "checkmark.seal")
        }
        .accessibilityIdentifier("openPureLogicCheck")
```

## 验收（三步，都要真的跑）

```sh
cd ios && xcodegen generate
cd /Users/sevenaaaaaaa/Awake && xcodebuild -project ios/Awake.xcodeproj -scheme AwakeIOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

期望 `** BUILD SUCCEEDED **`，退出码 0。

2. 模拟器/真机：设置 → 诊断与数据 → 纯逻辑自检 → 运行自检 → **8 / 8**。

3. 改坏常量（这是 v2 指定的那条验收，必须真做）：
   - 把 `EarRules.maxGaindB` 从 `12` 改成 `6`；
   - 重跑构建并点「运行自检」→ `prior.clamp` 应变 FAIL，detail 为「期望 12，实际 6」，
     其余 7 条不受影响；
   - 改回 `12`，重跑 → 8/8。
   桌面已经做过同一实验，结果记在 `docs/todo-backlog.md` 的 S2 段，可直接对照。

## 陷阱（踩过一次的都列在这里）

- **新文件必须先 `xcodegen generate`**。`project.yml` 用目录扫描（`sources: - Awake`），
  不重新生成 `Awake.xcodeproj` 的话，`PureLogicCheckView` 会报「cannot find in scope」。
- `Song` 的 memberwise init 顺序是声明顺序：`title → artist → album → folder → genre → duration → sampleRate`。
  可以跳过高默认值的（`id`、`artist`、`folder`、`genre`），但写出来的参数必须保持相对顺序，
  所以 `Song(title:album:duration:sampleRate:)` 合法，`Song(title:duration:album:)` 不合法。
- 档案往返**必须显式设 `.iso8601`**：`ListeningProfileExportView` 就是这么导出的，
  默认的 `deferredToDate` 会把 `Date` 编成浮点数，与真实档案形态不符，测了也白测。
- 本机 `xcodebuild test` 起不来 XCTest runner（README 与 `docs/releases/ios-v0.9.7.md` 都记了），
  **不要试图用 XCTest 代替自检页**。自检页就是设备内可跑的那条通道，这是 S2 的初衷。
- `EarRules.basisHint` 的返回要能直接显示，前缀固定为「依据里记的是」——桌面 `stale_hint` 同写法，
  改文案要两端一起改，否则同一件事两个说法。

## 做完之后

1. 更新 `docs/todo-backlog.md` 的「v2 批次 · S2 两端自检」：
   把「还没做」里的 iOS 三条删掉，补一段「iOS 已落地」写明 8 条清单与改坏常量的实际输出。
2. 写 **启发 24**：自检的条数应该由「这个平台真正拥有的纯逻辑」决定，不是两端对齐出来的数字。
3. 版本：两端已经都是 `0.9.39`（`ios/project.yml` `MARKETING_VERSION: 0.9.39` /
   `CURRENT_PROJECT_VERSION: 51`，桌面 `tauri.conf.json` 同为 0.9.39）。
   S2 两端都完成后，再一起打 `0.9.40`；**不要单边改**，两端版本号是同一批的标记。
