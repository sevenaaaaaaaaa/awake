import Foundation

// Descriptive evidence never becomes an acoustic correction or hardware identification.
struct EquipmentContext: Codable, Equatable {
  var goal = "保留原调音"
  var issue = "暂无明显问题"
  var outputID = ""
  var hardwareProfile = ""
  var impedance: Double?
  var sensitivity: Double?
  var sensitivityUnit = "dB/mW"
  var specSource = ""
  var character = ""
  var characterKind = "个人听感"
  var characterSource = ""

  func validate() throws {
    if let impedance, !impedance.isFinite || !(1...5000).contains(impedance) {
      throw AppFailure("耳机阻抗需要为 1–5000 Ω")
    }
    if let sensitivity, !sensitivity.isFinite || !(40...160).contains(sensitivity) {
      throw AppFailure("灵敏度需要为 40–160，且必须确认 dB/mW 或 dB/V 单位")
    }
    guard ["dB/mW", "dB/V"].contains(sensitivityUnit) else { throw AppFailure("灵敏度单位无效") }
    if impedance != nil || sensitivity != nil {
      guard !specSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AppFailure("请填写手动参数的来源，便于核对条件和单位")
      }
    }
    if !character.isEmpty && characterKind != "个人听感" && characterSource.isEmpty {
      throw AppFailure("厂商描述和社区评价需要填写出处")
    }
  }
}

struct HeadphoneEvidence: Identifiable, Codable {
  let id: String
  let name: String
  let aliases: [String]
  let brand: String
  let form: String
  let connections: [String]
  let modes: [String]
  let measurementNames: [String]
  let status: String
  let checked: String
  let impedance: Double?
  let sensitivity: Double?
  let unit: String
  let description: String
  let source: String
}
struct OutputEvidence: Identifiable {
  let id: String
  let name: String
  let frontend: String
  let chip: String
  let impedanceUpperBound: Double?
  let powerMW: Double?
  let loadOhms: Double?
  let condition: String
  let source: String
  var summary: String {
    var rows = [chip, condition]
    if let powerMW, let loadOhms { rows.append("每声道 ≥\(powerMW) mW / \(loadOhms) Ω") }
    if let impedanceUpperBound { rows.append("输出阻抗 <\(impedanceUpperBound) Ω") }
    return rows.joined(separator: " · ")
  }
}

enum EquipmentKnowledge {
  static let checked = "2026-11-11"
  static let goals = ["保留原调音", "更均衡", "人声优先", "低频氛围", "游戏定位"]
  static let issues = ["暂无明显问题", "响度不足", "低频过多", "低频不足", "人声不清晰", "延迟明显"]
  struct Catalog: Codable {
    let version: Int
    let checked: String
    let models: [HeadphoneEvidence]
  }
  static let catalogResult: Result<Catalog, Error> = Result {
    guard let url = Bundle.main.url(forResource: "headphones-v1", withExtension: "json") else {
      throw AppFailure("内置型号目录缺失，可继续手动填写设备")
    }
    return try decodeCatalog(Data(contentsOf: url))
  }
  static var headphones: [HeadphoneEvidence] { (try? catalogResult.get().models) ?? [] }
  static var catalogError: String? {
    if case .failure(let error) = catalogResult { return error.localizedDescription }
    return nil
  }
  static var brands: [String] { Array(Set(headphones.map(\.brand))).sorted() }
  static func decodeCatalog(_ data: Data) throws -> Catalog {
    guard data.count <= 2_000_000 else { throw AppFailure("型号目录过大") }
    let catalog = try JSONDecoder().decode(Catalog.self, from: data)
    guard catalog.version == 1, !catalog.models.isEmpty, catalog.models.count <= 1000 else {
      throw AppFailure("型号目录版本或数量无效")
    }
    var ids = Set<String>()
    var identities: [String: String] = [:]
    for model in catalog.models {
      guard ids.insert(model.id).inserted, !model.name.isEmpty, !model.brand.isEmpty,
        !model.connections.isEmpty, !model.modes.isEmpty,
        model.connections.allSatisfy({ ["bluetooth", "analog", "usb", "wireless_24"].contains($0) }
        ),
        ["厂商资料", "版本待确认"].contains(model.status),
        model.status == "版本待确认" || URL(string: model.source)?.scheme == "https",
        ["dB/mW", "dB/V"].contains(model.unit)
      else { throw AppFailure("型号资料不完整或重复：\(model.name)") }
      if let z = model.impedance, !z.isFinite || !(1...5000).contains(z) {
        throw AppFailure("阻抗无效")
      }
      if let sensitivity = model.sensitivity,
        !sensitivity.isFinite || !(40...160).contains(sensitivity)
      {
        throw AppFailure("灵敏度无效")
      }
      if model.status == "版本待确认",
        model.impedance != nil || model.sensitivity != nil || !model.measurementNames.isEmpty
      {
        throw AppFailure("未确认版本不能预置电气参数或测量映射")
      }
      for name in [model.name] + model.aliases {
        let key = normalize(name)
        guard !key.isEmpty, identities[key] == nil || identities[key] == model.id else {
          throw AppFailure("型号别名存在冲突：\(name)")
        }
        identities[key] = model.id
      }
    }
    return catalog
  }
  static func search(_ query: String, brand: String = "全部品牌") -> [HeadphoneEvidence] {
    let tokens = query.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter {
      !$0.isEmpty
    }
    return headphones.filter { model in
      (brand == "全部品牌" || model.brand == brand)
        && tokens.allSatisfy { token in
          ([model.name, model.brand, model.form] + model.aliases).contains {
            normalize($0).contains(token)
          }
        }
    }
  }
  static func select(_ model: HeadphoneEvidence, for chain: inout ListeningChain) {
    // Re-selecting the same model must preserve manually confirmed conditions and overrides.
    guard headphone(chain.headphone)?.id != model.id else { return }
    chain.headphone = model.name
    chain.acousticMode = "待确认"
    chain.fit = "待确认"
    var context = chain.equipment ?? EquipmentContext()
    context.impedance = nil
    context.sensitivity = nil
    context.specSource = ""
    context.character = ""
    context.characterSource = ""
    context.hardwareProfile = ""
    chain.equipment = context
  }
  static func connectionMatches(_ model: HeadphoneEvidence, chain: ListeningChain) -> Bool {
    if model.connections.contains(chain.connection) { return true }
    return model.connections.contains("analog")
      && !chain.frontend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && ["usb", "wireless_24", "bluetooth"].contains(chain.connection)
  }
  static func connectionName(_ key: String) -> String {
    ["bluetooth": "蓝牙", "analog": "有线模拟", "usb": "USB 音频", "wireless_24": "2.4GHz 接收器"][key] ?? key
  }
  static let outputs: [OutputEvidence] = [
    .init(
      id: "ka13-se-desktop", name: "KA13 · 3.5mm · 桌面模式开", frontend: "FiiO KA13",
      chip: "双 CS43131", impedanceUpperBound: 1.7, powerMW: 170, loadOhms: 32,
      condition: "USB 输入；桌面模式 ON；THD+N <1%", source: "https://fiio.com/ka13_parameters"),
    .init(
      id: "ka13-se-mobile", name: "KA13 · 3.5mm · 桌面模式关", frontend: "FiiO KA13",
      chip: "双 CS43131", impedanceUpperBound: 1.7, powerMW: 50, loadOhms: 32,
      condition: "USB 输入；桌面模式 OFF；THD+N <1%", source: "https://fiio.com/ka13_parameters"),
    .init(
      id: "ka13-bal-desktop", name: "KA13 · 4.4mm · 桌面模式开", frontend: "FiiO KA13",
      chip: "双 CS43131", impedanceUpperBound: 1.8, powerMW: 550, loadOhms: 32,
      condition: "USB 输入；桌面模式 ON；THD+N <1%", source: "https://fiio.com/ka13_parameters"),
    .init(
      id: "ka13-bal-mobile", name: "KA13 · 4.4mm · 桌面模式关", frontend: "FiiO KA13",
      chip: "双 CS43131", impedanceUpperBound: 1.8, powerMW: 260, loadOhms: 32,
      condition: "USB 输入；桌面模式 OFF；THD+N <1%", source: "https://fiio.com/ka13_parameters"),
    .init(
      id: "dawn-se", name: "DAWN PRO · 3.5mm", frontend: "MOONDROP DAWN PRO",
      chip: "当前来源未核对芯片", impedanceUpperBound: nil, powerMW: nil, loadOhms: nil,
      condition: "厂商标注线路输出 2 Vrms；带载功率未收录，不能视作耳机负载下保证值",
      source: "https://moondroplab.com/en/products/dawn-pro"),
    .init(
      id: "dawn-bal", name: "DAWN PRO · 4.4mm", frontend: "MOONDROP DAWN PRO",
      chip: "当前来源未核对芯片", impedanceUpperBound: nil, powerMW: nil, loadOhms: nil,
      condition: "厂商标注线路输出 4 Vrms；带载功率未收录，不能视作耳机负载下保证值",
      source: "https://moondroplab.com/en/products/dawn-pro"),
  ]
  static func normalize(_ value: String) -> String {
    value.lowercased().filter { $0.isLetter || $0.isNumber }
  }
  static func headphone(_ name: String) -> HeadphoneEvidence? {
    let key = normalize(name)
    guard !key.isEmpty else { return nil }
    return headphones.first { ([$0.name] + $0.aliases).contains { normalize($0) == key } }
  }
  static func output(_ chain: ListeningChain) -> OutputEvidence? {
    guard ["analog", "usb", "wireless_24"].contains(chain.connection),
      let id = chain.equipment?.outputID
    else { return nil }
    return outputs.first { $0.id == id && normalize($0.frontend) == normalize(chain.frontend) }
  }
  // Reference calculation only: no digital volume / hearing safety calibration is inferred.
  static func referenceVoltage(
    impedance: Double?, sensitivity: Double?, unit: String,
    spl: Double = 90
  ) -> Double? {
    guard let sensitivity, sensitivity.isFinite, (40...160).contains(sensitivity),
      spl.isFinite, (40...110).contains(spl)
    else { return nil }
    if unit == "dB/V" { return pow(10, (spl - sensitivity) / 20) }
    guard unit == "dB/mW", let impedance, impedance.isFinite, (1...5000).contains(impedance)
    else { return nil }
    return sqrt(pow(10, (spl - sensitivity) / 10) * impedance / 1000)
  }
  static func advice(_ chain: ListeningChain) -> [String] {
    let context = chain.equipment ?? EquipmentContext()
    let model = headphone(chain.headphone)
    let out = output(chain)
    var rows: [String] = []
    if let model {
      rows.append(model.description)
      if !connectionMatches(model, chain: chain) {
        rows.append("当前连接与该型号已收录的入口不一致，请核对实际链路；暂不套用型号电气参数。")
      }
      if chain.connection == "bluetooth" {
        rows.append("iOS 蓝牙编码由系统协商；厂商宣传的 LDAC、LHDC、aptX、SSC 或星闪能力不会因选择型号而启用。设备端预设与自适应/空间音效请单独记录。")
      }
      if model.form.contains("开放") || model.form.contains("半入耳") || model.form.contains("平头") {
        rows.append("开放佩戴优先核对位置、耳棉与环境声；先在安静环境试听低频，保留当前结构的声音特色。")
      }
    }
    if !context.character.isEmpty {
      rows.append("\(context.characterKind)：\(context.character)。仅作为当前型号与声学模式的偏好线索。")
    }
    if context.goal == "保留原调音" {
      rows.append("当前目标是保留原调音：先比较旁路与现有曲线，保留你喜欢的声音特色。")
    } else if context.goal == "游戏定位" {
      rows.append("游戏定位：优先比较有线或接收器链路的实际延迟、左右定位和游戏内 HRTF；避免叠加空间音效。EQ 不保证提升脚步辨识。")
    } else if context.goal == "人声优先" {
      rows.append("人声优先：先比较熟悉的人声片段；若伴奏遮盖，可小幅减少低中频，再记录清晰度与齿音反馈。")
    } else if context.goal == "低频氛围" {
      rows.append("低频氛围：先检查密封与佩戴，再少量试听低频变化；保留前级余量并记录疲劳感。")
    } else if context.goal == "更均衡" {
      rows.append("更均衡：优先查找相同型号、声学模式的测量，再由个人评分决定校正程度。")
    }
    let passive =
      ["analog", "usb", "wireless_24"].contains(chain.connection)
      && (chain.connection != "usb" || !chain.frontend.isEmpty)
    if passive {
      let manual = context.impedance != nil || context.sensitivity != nil
      let compatible = model.map { connectionMatches($0, chain: chain) } == true
      let impedance = manual ? context.impedance : compatible ? model?.impedance : nil
      let sensitivity = manual ? context.sensitivity : compatible ? model?.sensitivity : nil
      let unit = manual ? context.sensitivityUnit : model?.unit ?? "dB/mW"
      if let volts = referenceVoltage(impedance: impedance, sensitivity: sensitivity, unit: unit) {
        rows.append(
          String(
            format: "按%@参数估算，90 dB SPL 工程参考约需 %.3f Vrms；未含音乐瞬态与 EQ 衰减。不代表实际声压或建议音量。",
            manual ? "手动录入" : "厂商", volts))
      }
      if let out {
        rows.append("已确认输出：\(out.name)。\(out.summary)。芯片型号不决定整机音质。")
        if let load = out.loadOhms, let impedance, abs(load - impedance) > 0.5 {
          rows.append("输出功率的测试负载与耳机标称阻抗不同，暂不推算最大响度；需要对应负载下的电压、电流与失真数据。")
        }
        if let limit = out.impedanceUpperBound, let impedance, limit > impedance / 8 {
          rows.append("输出阻抗上限超过耳机标称阻抗的 1/8，建议核对阻抗曲线与实际频响；这个经验条件本身不能证明声音受影响。")
        }
      } else if !chain.frontend.isEmpty {
        rows.append("前端输出口或工作模式未确认，暂不判断推力；请在设备资料中选择具体模式。")
      }
    }
    switch context.issue {
    case "响度不足":
      rows.append("响度不足：依次核对源文件电平、音量限制、EQ 前级衰减、前端增益与供电。软件增益不能补足硬件输出能力，先避免削波。")
    case "低频过多": rows.append("低频过多：先排除双重音效，再小幅减少低频做 A/B；无需因品牌标签而固定削低频。")
    case "低频不足": rows.append("低频不足：先检查耳套密封、佩戴与开放式结构，再比较低频调整，避免大幅补偿结构性滚降。")
    case "人声不清晰": rows.append("人声不清晰：先用熟悉录音排除混音差异，再比较低中频遮盖；避免直接大幅提升高频。")
    case "延迟明显": rows.append("延迟明显：对比有线与当前无线模式。标称蓝牙版本或‘游戏’宣传语不能替代端到端延迟测试。")
    default: break
    }
    return rows
  }
}
