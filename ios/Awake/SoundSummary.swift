import Foundation

/// 「这首歌为什么这样响」——把 31 段增益翻译成一句人话，外加一句依据。
///
/// 原则：只描述真实存在的增益；没有适配就直说没有，不用「优化」「智能」这类词充数。
struct SoundSummary {
  var headline: String
  var basis: String
  var hasAdaptation: Bool
}

enum SoundSummaryBuilder {
  /// 31 段中心频率（与 EQCurvePanel / EQMath 一致）。
  static let centers: [Double] = [
    20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500,
    630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000,
    10000, 12500, 16000, 20000,
  ]

  struct Region {
    let name: String
    let range: ClosedRange<Double>
    let up: String
    let down: String
  }

  static let regions: [Region] = [
    Region(name: "低频", range: 20...200, up: "鼓更近、下潜更实", down: "去掉低频的糊"),
    Region(name: "中低", range: 200...800, up: "厚度更足", down: "减掉箱音"),
    Region(name: "中高", range: 800...4000, up: "人声更靠前", down: "人声退后、不刺"),
    Region(name: "高频", range: 4000...20000, up: "更亮、空气感", down: "压住齿音"),
  ]

  static func make(snapshot: EQSnapshot, hasSong: Bool) -> SoundSummary {
    guard hasSong else {
      return SoundSummary(headline: "还没有正在播放的曲目", basis: "选一首歌后这里会说明它被怎样调过。", hasAdaptation: false)
    }
    let bands = zip(centers, snapshot.gains).filter { abs($0.1) >= 1.0 }
    guard !bands.isEmpty || !snapshot.apo.isEmpty else {
      return SoundSummary(
        headline: "平直曲线：这首歌没有做任何适配",
        basis: basisLine(snapshot), hasAdaptation: false)
    }
    var phrases: [String] = []
    for region in regions {
      let slice = bands.filter { region.range.contains($0.0) }
      guard !slice.isEmpty else { continue }
      let mean = slice.map { Double($0.1) }.reduce(0, +) / Double(slice.count)
      guard abs(mean) >= 0.5 else { continue }
      let gain = String(format: "%+.0f dB", mean)
      let effect = mean > 0 ? region.up : region.down
      phrases.append("\(region.name) \(gain)：\(effect)")
    }
    if !snapshot.apo.isEmpty, phrases.isEmpty { phrases.append("导入的参数校正正在生效") }
    let headline = phrases.isEmpty
      ? "有轻微调整（每段不足 1 dB）"
      : phrases.prefix(2).joined(separator: "；") + (phrases.count > 2 ? "…" : "")
    return SoundSummary(headline: headline, basis: basisLine(snapshot), hasAdaptation: true)
  }

  static func basisLine(_ snapshot: EQSnapshot) -> String {
    var parts = ["依据：" + snapshot.origin.title]
    if !snapshot.profile.isEmpty, snapshot.profile != "系统输出" { parts.append(snapshot.profile) }
    if !snapshot.source.isEmpty { parts.append(snapshot.source) }
    return parts.joined(separator: " · ")
  }
}
