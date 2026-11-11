import Foundation

enum EQOrigin: String, Codable {
  case manual, imported, measurement, ai
  var title: String {
    switch self {
    case .manual: "手动 EQ"
    case .imported: "导入参数"
    case .measurement: "测量校正"
    case .ai: "AI EQ"
    }
  }
}

struct EQSnapshot: Equatable {
  var gains = Array(repeating: Float(0), count: 31)
  var apo = ""
  var origin = EQOrigin.manual
  var profile = "系统输出"
  var source = ""
}

struct EnhancementState: Equatable {
  var configured = false
  var enabled = false
  var bypassed = false
  var origin = EQOrigin.manual
  var profile = "系统输出"
  var source = ""
  var graphicBands = 0
  var correctionBands = 0
  var preamp: Float = 0
  var shortTitle: String {
    enabled ? (origin == .ai ? "AI EQ" : "EQ+") : configured && bypassed ? "EQ 旁路" : "原声"
  }
  func title(playing: Bool) -> String {
    if configured && bypassed { return "EQ 已旁路" }
    if enabled { return (origin == .ai ? "AI EQ 增强" : "EQ 增强") + (playing ? "开启" : "已就绪") }
    return playing ? "原声播放" : "原声已就绪"
  }
  var detail: String {
    if !configured { return "当前输出使用平直曲线。" }
    let filters = "\(graphicBands) 个图形频段 · \(correctionBands) 个校正频段"
    return origin.title + " · " + filters + String(format: " · 前级 %.1f dB", preamp)
  }
}

struct EffectActivation: Identifiable, Equatable {
  let id = UUID()
  let created = Date()
  var state: EnhancementState
  var displayGains: [Float]
  var title: String { state.enabled ? "\(state.origin.title) 已应用" : "已恢复原声" }
  var symbol: String {
    let form = EquipmentKnowledge.headphone(state.profile)?.form ?? ""
    return form.contains("入耳") || form.contains("耳夹") || form.contains("平头")
      ? "earbuds" : "headphones"
  }
}
