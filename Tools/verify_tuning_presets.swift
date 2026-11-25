// 内置调音预设的自检：不需要模拟器。
//   swiftc ios/Awake/TuningPresets.swift Tools/verify_tuning_presets.swift -o /tmp/verify-presets
//   /tmp/verify-presets
//
// 它检查的是「这份表能不能信」，不是「好不好听」：
// 数量、段数、幅度上限、名称唯一、说明齐全、以及每条的取向是否和它的名字一致。
import Foundation

@main
struct VerifyTuningPresets {
  static func main() {
    var checks = 0
    var failures = 0
    func check(_ ok: Bool, _ label: String, _ actual: String = "") {
      checks += 1
      if ok {
        print("PASS \(label)")
      } else {
        failures += 1
        print("FAIL \(label) -> \(actual)")
      }
    }
    func mean(_ gains: [Float], _ range: ClosedRange<Int>) -> Float {
      let slice = gains[range]
      guard !slice.isEmpty else { return 0 }
      return slice.reduce(0, +) / Float(slice.count)
    }

    let all = TuningPresets.all
    check(TuningPresets.frequencies.count == 31, "频率表 31 段", "\(TuningPresets.frequencies.count)")
    check(all.count == 26, "预设共 26 条（6 器材 + 10 曲风 + 10 二级）", "\(all.count)")
    check(TuningPresets.group(.hardware).count == 6, "器材 6 条", "\(TuningPresets.group(.hardware).count)")
    check(TuningPresets.group(.genre).count == 10, "曲风 10 条", "\(TuningPresets.group(.genre).count)")
    check(TuningPresets.group(.subgenre).count == 10, "二级 10 条", "\(TuningPresets.group(.subgenre).count)")

    check(Set(all.map(\.id)).count == all.count, "id 唯一", "\(Set(all.map(\.id)).count)")
    check(Set(all.map(\.name)).count == all.count, "名称唯一", "\(Set(all.map(\.name)).count)")

    let wrongLength = all.filter { $0.gains.count != 31 }
    check(wrongLength.isEmpty, "每条都是 31 段曲线", wrongLength.map(\.name).joined(separator: ","))

    let overLimit = all.filter { $0.gains.contains { abs($0) > 6.0001 } }
    check(overLimit.isEmpty, "没有一段超过 ±6dB", overLimit.map(\.name).joined(separator: ","))

    let thinCopy = all.filter { $0.why.count < 12 || $0.caveat.count < 12 }
    check(thinCopy.isEmpty, "每条都有 why 与 caveat", thinCopy.map(\.name).joined(separator: ","))

    // 相邻段跳变：锯齿状的曲线一听就「塑料」，这里限制在 3.5dB 内。
    let jagged = all.filter { preset in
      zip(preset.gains, preset.gains.dropFirst()).contains { abs($0 - $1) > 3.5 }
    }
    check(jagged.isEmpty, "没有锯齿状跳变（相邻段 ≤3.5dB）", jagged.map(\.name).joined(separator: ","))

    // 取向与名字是否对得上：这是这份表最容易骗人的地方。
    let cd = TuningPresets.preset("cd")!
    check(cd.gains.allSatisfy { $0 == 0 }, "CD 是平直对照", cd.gains.map { String(format: "%.1f", $0) }.joined(separator: ","))

    let cassette = TuningPresets.preset("cassette")!
    check(mean(cassette.gains, 27...30) < -0.8, "磁带的高频是滚降", "\(mean(cassette.gains, 27...30))")
    check(mean(cassette.gains, 6...8) > 0.3, "磁带的低频是温厚", "\(mean(cassette.gains, 6...8))")

    let earbud = TuningPresets.preset("earbud")!
    check(earbud.gains[7] < -1, "平头塞的 100Hz 是泄掉的", "\(earbud.gains[7])")
    check(mean(earbud.gains, 20...23) > 0.5, "平头塞的中高频更亮", "\(mean(earbud.gains, 20...23))")

    let techno = TuningPresets.preset("techno")!
    check(mean(techno.gains, 3...5) > 1.5, "Techno 的低频是主导", "\(mean(techno.gains, 3...5))")

    let lofi = TuningPresets.preset("lofi")!
    check(mean(lofi.gains, 27...30) < -1.5, "Lo-fi 是带限的", "\(mean(lofi.gains, 27...30))")

    let female = TuningPresets.preset("femalepop")!
    check(female.gains[25] < 0, "女声预设收了齿音区", "\(female.gains[25])")

    let classical = TuningPresets.preset("classical")!
    check(mean(classical.gains, 0...4) <= 0, "古典不夸张低频", "\(mean(classical.gains, 0...4))")

    // 同一条预设不能被两组同时收录。
    let ids = Set(TuningPresets.group(.hardware).map(\.id))
    check(ids.isDisjoint(with: Set(TuningPresets.group(.genre).map(\.id))), "器材与曲风没有重名 id")

    if failures == 0 {
      print("PASS 预设自检 \(checks)/\(checks)")
      exit(0)
    }
    print("FAIL \(failures)/\(checks) 项未通过")
    exit(1)
  }
}
