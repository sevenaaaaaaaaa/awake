import SwiftUI

struct EquipmentEditor: View {
  @Binding var chain: ListeningChain
  func field<T>(_ key: WritableKeyPath<EquipmentContext, T>) -> Binding<T> {
    Binding(
      get: { (chain.equipment ?? EquipmentContext())[keyPath: key] },
      set: { value in
        var context = chain.equipment ?? EquipmentContext()
        context[keyPath: key] = value
        chain.equipment = context
      })
  }
  var body: some View {
    Form {
      Section("先确定你想要的声音") {
        Picker("聆听目标", selection: field(\.goal)) {
          ForEach(EquipmentKnowledge.goals, id: \.self) { Text($0).tag($0) }
        }.accessibilityIdentifier("listeningGoal")
        Picker("当前问题", selection: field(\.issue)) {
          ForEach(EquipmentKnowledge.issues, id: \.self) { Text($0).tag($0) }
        }
        Text("保留个人喜爱的调音特色。场景和品牌故事用于形成试听建议，应用 EQ 仍需你比较确认。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("已核对的型号资料") {
        NavigationLink {
          HeadphoneCatalogView(chain: $chain)
        } label: {
          Label("选择耳机资料", systemImage: "headphones")
        }.accessibilityIdentifier("headphoneEvidencePicker")
        Text(EquipmentKnowledge.headphone(chain.headphone)?.name ?? "自定义型号 / 未收录")
          .font(.caption).foregroundStyle(.secondary)
        TextField("耳机完整型号", text: $chain.headphone).accessibilityIdentifier(
          "equipmentHeadphoneModel")
        TextField("前端完整型号", text: $chain.frontend)
        Picker("输出口与工作模式", selection: field(\.outputID)) {
          Text("未确认 / 自定义前端").tag("")
          ForEach(EquipmentKnowledge.outputs) { output in Text(output.name).tag(output.id) }
        }.accessibilityIdentifier("outputEvidencePicker")
          .onChange(of: chain.equipment?.outputID) { _, id in
            if let output = EquipmentKnowledge.outputs.first(where: { $0.id == id }) {
              chain.frontend = output.frontend
            }
          }
        Text("输出口和增益/供电模式由你确认；系统输出名称不能证明小尾巴后的耳机型号。切换输出模式会创建独立链路。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("手动耳机参数 · 留空时使用型号资料") {
        TextField("标称阻抗 Ω（可选）", value: field(\.impedance), format: .number)
          .keyboardType(.decimalPad).accessibilityIdentifier("manualImpedance")
        TextField("灵敏度（可选）", value: field(\.sensitivity), format: .number)
          .keyboardType(.decimalPad)
        Picker("灵敏度单位", selection: field(\.sensitivityUnit)) {
          Text("dB SPL / 1 mW").tag("dB/mW")
          Text("dB SPL / 1 V").tag("dB/V")
        }
        TextField("参数出处与测试条件", text: field(\.specSource), axis: .vertical)
        Text("任一手动参数填写后，按手动资料整体计算，不拼接不同来源的未知参数。前端输出阻抗与耳机标称阻抗分别处理。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("当前型号与模式的调音倾向") {
        TextField("设备端音效/固件模式，如 Signature", text: field(\.hardwareProfile))
        TextField("如：人声靠前、低频偏多、开放通透", text: field(\.character), axis: .vertical)
        Picker("描述来源", selection: field(\.characterKind)) {
          ForEach(["个人听感", "厂商描述", "社区评价"], id: \.self) { Text($0).tag($0) }
        }
        TextField("网页、作者与适用条件", text: field(\.characterSource), axis: .vertical)
        Text("‘女毒’‘低音强’是描述性标签；不同系列、代际、耳垫、ANC 和连接方式需要分别核对。实测 EQ 仍在社区测量中导入。")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = validationError {
        Section("请修正后保存链路") { Text(error).foregroundStyle(.red) }
      }
      Section("资料与建议预览") { EquipmentSummary(chain: chain) }
      Section {
        Text(
          "资料核对日期：\(EquipmentKnowledge.checked)。已收录 \(EquipmentKnowledge.headphones.count) 个型号档案，可手动补全未知参数。修改会在返回后随链路一起保存。"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }.appSurface().navigationTitle("设备与听感")
  }
  var validationError: String? {
    do {
      try chain.equipment?.validate()
      return nil
    } catch { return error.localizedDescription }
  }
}

struct EquipmentSummary: View {
  let chain: ListeningChain
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let model = EquipmentKnowledge.headphone(chain.headphone) {
        Text(model.name).font(.headline)
        if let impedance = model.impedance { Text("厂商标称阻抗 \(impedance, specifier: "%.0f") Ω") }
        if let sensitivity = model.sensitivity {
          Text("厂商灵敏度 \(sensitivity, specifier: "%.1f") \(model.unit)")
        }
        Text("\(model.brand) · \(model.form) · \(model.status)")
          .font(.caption).foregroundStyle(.secondary)
        Text(
          "音频入口：" + model.connections.map(EquipmentKnowledge.connectionName).joined(separator: "、"))
        Text("声学状态：" + model.modes.joined(separator: "、"))
        if let source = URL(string: model.source), source.scheme == "https" {
          Link("耳机资料出处", destination: source)
        }
        if model.impedance == nil && model.sensitivity == nil {
          Text("当前资料未收录可用于推力计算的阻抗与灵敏度。")
            .font(.caption).foregroundStyle(.secondary)
        }
      } else {
        Text("该型号尚未收录，不按品牌或相似型号补造参数。")
      }
      if let out = EquipmentKnowledge.output(chain) {
        Link("前端参数出处与条件", destination: URL(string: out.source)!)
      }
      if let context = chain.equipment {
        if !context.hardwareProfile.isEmpty { Text("设备端模式：\(context.hardwareProfile)") }
        if !context.specSource.isEmpty { Text("手动参数出处：\(context.specSource)") }
        if !context.characterSource.isEmpty { Text("调音描述出处：\(context.characterSource)") }
      }
      ForEach(EquipmentKnowledge.advice(chain), id: \.self) { Text($0) }
    }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct HeadphoneCatalogView: View {
  @Binding var chain: ListeningChain
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var brand = "全部品牌"
  var models: [HeadphoneEvidence] { EquipmentKnowledge.search(query, brand: brand) }
  var body: some View {
    List {
      Section {
        Picker("品牌", selection: $brand) {
          Text("全部品牌").tag("全部品牌")
          ForEach(EquipmentKnowledge.brands, id: \.self) { Text($0).tag($0) }
        }.accessibilityIdentifier("catalogBrandPicker")
        Text(
          "\(models.count) 个匹配 · 收录 \(EquipmentKnowledge.headphones.count) 个档案。型号资料用于链路建议，实测 EQ 在社区测量中单独查询。"
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("自定义型号 / 未收录") {
          chain.headphone = ""
          chain.acousticMode = "待确认"
          var context = chain.equipment ?? EquipmentContext()
          context.impedance = nil
          context.sensitivity = nil
          context.specSource = ""
          context.character = ""
          context.characterSource = ""
          context.hardwareProfile = ""
          chain.equipment = context
          dismiss()
        }
      }
      if let error = EquipmentKnowledge.catalogError {
        Section { Text(error).foregroundStyle(.red) }
      }
      if models.isEmpty {
        Section { Text("未找到匹配型号，可搜索中文品牌、完整型号或选择自定义。") }
      }
      ForEach(
        EquipmentKnowledge.brands.filter { b in models.contains { $0.brand == b } }, id: \.self
      ) { b in
        Section(b) {
          ForEach(models.filter { $0.brand == b }) { model in
            VStack(alignment: .leading, spacing: 10) {
              Button {
                EquipmentKnowledge.select(model, for: &chain)
                dismiss()
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  Text(model.name).font(.headline)
                  Text(
                    model.form + " · "
                      + model.connections.map(EquipmentKnowledge.connectionName).joined(
                        separator: " / ")
                  )
                  .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(
                  Rectangle())
              }.buttonStyle(.plain).accessibilityIdentifier("selectModel-" + model.id)
              Text(model.description).font(.caption).foregroundStyle(.secondary)
              if let url = URL(string: model.source), url.scheme == "https" {
                Link("\(model.status) · \(model.checked)", destination: url).font(.caption)
              } else {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
              }
            }.padding(.vertical, 4)
          }
        }
      }
    }.appSurface().navigationTitle("耳机型号库").navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, prompt: "品牌、中文别名或完整型号")
  }
}
