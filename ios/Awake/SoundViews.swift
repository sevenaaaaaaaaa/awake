import SwiftUI
import UniformTypeIdentifiers


struct SoundView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @State private var configure = false
  @State private var band = 17
  @State private var importing = false
  @State private var source = ""
  @State private var text = ""
  @State private var sliderEditing = false
  @State private var needsCommit = false
  @State private var sliderRevision = 0
  @State private var presetKind: TuningPresets.Kind = .hardware
  @State private var presetNote = ""
  var chain: ListeningChain? { store.activeChain(route: player.route.uid) }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        presetSection
        NavigationLink {
          MeasurementView(model: chain?.headphone ?? player.route.name)
        } label: {
          Panel {
            Label("按耳机型号套用", systemImage: "hifispeaker.and.homepod").font(.headline)
            Text("按型号查询 AutoEq 与已收录的公开拟合，保留来源和适用条件。").font(.subheadline).foregroundStyle(.secondary)
          }
        }.buttonStyle(.plain)
        Panel {
          HStack {
            Image(systemName: "headphones").font(.title)
            VStack(alignment: .leading) {
              Text(player.route.name).font(.headline)
              Text("\(player.route.transport) · PCM \(Int(player.route.rate)) Hz").font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            RoutePicker().frame(width: 40, height: 40)
          }
          AwakeNote(text: "无线编码由系统协商；2.4GHz 接收器和小尾巴后的模拟耳机需要手动绑定。")
          Picker(
            "当前链路",
            selection: Binding(
              get: { chain?.id ?? "" },
              set: {
                store.state.activeChains[player.route.uid] = $0
                store.save()
                apply()
              })
          ) {
            Text("设备默认 · 平直").tag("")
            ForEach(store.state.chains.filter { $0.routeUID == player.route.uid }) {
              Text($0.name).tag($0.id)
            }
          }
          Button("配置耳机与连接", systemImage: "cable.connector") { configure = true }
            .accessibilityIdentifier("configureChain")
          if let c = chain {
            Text("\(c.headphone) · \(c.connection) · \(c.acousticMode)\n\(c.frontend) \(c.fit)")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Panel {
          HStack {
            Text("你的声音曲线").font(.title3.bold())
            Spacer()
            Button("恢复原声") {
              update { c in
                c.gains = Array(repeating: 0, count: 31)
                c.apo = ""
                c.measurementSource = ""
                c.eqOrigin = nil
              }
            }.disabled(chain == nil).accessibilityIdentifier("restoreOriginal")
          }
          EQChart(
            gains: chain?.gains ?? Array(repeating: 0, count: 31),
            onEdit: { band, gain in
              guard chain != nil else { return }
              update(save: false) { $0.gains[band] = gain }
              needsCommit = true
            },
            onEditEnd: { commitSlider() }
          )
          .frame(height: 130)
          .tabSwipeExempt()
          if chain != nil {
            Text("按住曲线左右拖，可以直接把想要的形状画出来；松手才落盘，随时可撤销。")
              .font(.caption2).foregroundStyle(.secondary)
          }
          EnhancementBadge(context: "sound")
          Picker("频段", selection: $band) {
            ForEach(0..<31, id: \.self) { i in Text("\(Int(EQMath.frequencies[i])) Hz").tag(i) }
          }.pickerStyle(.menu)
          Slider(
            value: Binding(
              get: { Double(chain?.gains[band] ?? 0) },
              set: { value in
                update(save: false) { $0.gains[band] = Float(value) }
                needsCommit = true
                sliderRevision += 1
              }),
            in: -12...12, step: 0.5,
            onEditingChanged: { editing in
              sliderEditing = editing
              if !editing { commitSlider() }
            }
          ).disabled(chain == nil).accessibilityLabel("频段增益").accessibilityIdentifier(
            "eqGainSlider"
          ).tabSwipeExempt()
          Text(
            "\(String(format:"%.1f",chain?.gains[band] ?? 0)) dB · 前级 \(String(format:"%.1f",player.preamp)) dB"
          ).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          Toggle("暂时旁路 EQ", isOn: $player.bypassed).accessibilityIdentifier("bypassEQ")
          Text("iOS 使用原生 Audio Unit 执行滤波，参数 Q 转换为带宽。前级采用保守余量；设备端频响尚未经过测量认证。").font(.caption)
            .foregroundStyle(.secondary)
        }
        if let c = chain {
          Panel {
            DisclosureGroup("设备资料与匹配建议") { EquipmentSummary(chain: c) }
          }
        }
        NavigationLink {
          ManualEQView()
        } label: {
          Panel {
            Label("导入参数校正", systemImage: "square.and.arrow.down").font(.headline)
            Text("从测量文件或 AutoEq 参数粘贴，自动换算成这 31 段。").font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }.buttonStyle(.plain)
      }.padding(20)
    }.appSurface()
      .task(id: sliderRevision) {
        guard needsCommit else { return }
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        if !Task.isCancelled && !sliderEditing { commitSlider() }
      }
      .onDisappear { if needsCommit { commitSlider(announce: false) } }
      .sheet(isPresented: $configure) {
        ChainEditor(chain: chain, route: player.route) { apply() }
      }.fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { result in
        do {
          let u = try result.get()
          let access = u.startAccessingSecurityScopedResource()
          defer { if access { u.stopAccessingSecurityScopedResource() } }
          guard (try u.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 65536 else {
            throw AppFailure("参数文件不能超过 64KB")
          }
          text = try String(contentsOf: u, encoding: .utf8)
        } catch { store.message = error.localizedDescription }
      }
  }
  /// 起点卡片：2×2，每张一张小曲线 + 一句人话。
  /// 风格预设放在这一段最前：31 段曲线对多数人是一张空白考卷，
  /// 先给一条有名字、有理由、可撤销的曲线，比让他从零开始画容易。
  private var presetSection: some View {
    Panel {
      HStack(alignment: .firstTextBaseline) {
        Text("风格预设").font(.title3.bold())
        Spacer()
        Text("\(TuningPresets.all.count) 条").font(.caption2).foregroundStyle(.secondary)
      }
      presetPicker
    }
  }

  /// 风格预设：介质与器材 / 曲风 / 二级分类三组。
  /// 每一条都带 why 与 caveat，点了就把它为什么这么给显示出来——
  /// 只给一个风格名，等于让人相信一个没有理由的曲线。
  private var presetPicker: some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      HStack(spacing: 4) {
        ForEach(TuningPresets.Kind.allCases) { kind in
          Button(kind.title) {
            presetKind = kind
          }
          .font(.caption2.weight(presetKind == kind ? .semibold : .regular))
          .foregroundStyle(
            presetKind == kind
              ? Color(hex: store.state.skin.colors.bg)
              : Color(hex: store.state.skin.colors.text))
          .padding(.horizontal, 10)
          .frame(minHeight: 28)
          .background(
            Capsule().fill(
              presetKind == kind ? Color(hex: store.state.skin.colors.text) : .clear))
          .buttonStyle(.plain)
          .accessibilityIdentifier("presetKind_\(kind.rawValue)")
        }
        Spacer(minLength: 0)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(TuningPresets.group(presetKind)) { preset in
            Button(preset.name) { applyPreset(preset) }
              .font(.caption)
              .foregroundStyle(Color(hex: store.state.skin.colors.text))
              .padding(.horizontal, 10)
              .frame(minHeight: 32)
              .background(
                Capsule().fill(Color(hex: store.state.skin.colors.surface)))
              .overlay(
                Capsule().stroke(Color(hex: store.state.skin.colors.border), lineWidth: 0.6))
              .buttonStyle(.plain)
              .accessibilityIdentifier("preset_\(preset.id)")
          }
        }
        .padding(.vertical, 2)
      }
      .tabSwipeExempt()
      if !presetNote.isEmpty {
        Text(presetNote)
          .font(.caption2)
          .foregroundStyle(Color(hex: store.state.skin.colors.muted))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func applyPreset(_ preset: TuningPresets.Preset) {
    guard chain != nil else {
      presetNote = "还没有听感链路：先到「配置耳机与连接」建一条，再套预设。"
      return
    }
    update { chain in
      chain.gains = preset.gains
      chain.measurementSource = "预设 · \(preset.name)"
      chain.eqOrigin = .manual
    }
    presetNote = "「\(preset.name)」：\(preset.why) 注意：\(preset.caveat)"
  }

  func commitSlider(announce: Bool = true) {
    guard needsCommit else { return }
    needsCommit = false
    store.save()
    apply(announce: announce)
  }
  func apply(announce: Bool = true) {
    player.useChain(chain, announce: announce)
  }
  func update(save: Bool = true, _ change: (inout ListeningChain) -> Void) {
    guard let c = chain, let i = store.state.chains.firstIndex(where: { $0.id == c.id }) else {
      return
    }
    change(&store.state.chains[i])
    if !save { store.state.chains[i].eqOrigin = .manual }
    if save { store.save() }
    apply(announce: save)
  }
}
struct EQChart: View {
  let gains: [Float]
  /// 满量程的一半。默认 ±14 dB；起点卡片用 ±5，否则 3.5 dB 的曲线看起来还是一条直线。
  var range: Float = 14
  /// 传了就可拖：手指落在哪，就改那一段；斜着划过去会把中间几段一起插值改掉，
  /// 也就是「画」出一条曲线，而不是先选频段再拖滑块。
  /// 拖动过程只改内存（由调用方决定不落盘），松手时由 onEditEnd 统一提交一次。
  var onEdit: ((Int, Float) -> Void)? = nil
  var onEditEnd: (() -> Void)? = nil

  @State private var lastBand: Int?
  @State private var lastGain: Float?

  var body: some View {
    GeometryReader { geo in
      if let onEdit {
        canvas.gesture(paint(in: geo.size, edit: onEdit))
      } else {
        canvas
      }
    }
    .accessibilityLabel("31 段图形 EQ 曲线")
    .accessibilityValue(onEdit == nil ? "" : "可按住左右拖动直接改频段")
  }

  private var canvas: some View {
    Canvas { ctx, size in
      var grid = Path()
      for y in [0.0, 0.5, 1.0] {
        grid.move(to: CGPoint(x: 0, y: size.height * y))
        grid.addLine(to: CGPoint(x: size.width, y: size.height * y))
      }
      ctx.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
      var line = Path()
      for i in gains.indices {
        let p = CGPoint(
          x: Double(i) / 30 * size.width,
          y: (0.5 - Double(gains[i]) / Double(2 * max(range, 1))) * size.height)
        if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
      }
      ctx.stroke(
        line, with: .color(.accentColor),
        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }
  }

  private func paint(in size: CGSize, edit: @escaping (Int, Float) -> Void) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard size.width > 0, size.height > 0 else { return }
        let x = min(1, max(0, value.location.x / size.width))
        let band = Int((x * 30).rounded())
        let limit = Double(max(range, 1))
        let ratio = 0.5 - value.location.y / size.height
        let gain = Float(min(limit, max(-limit, ratio * 2 * limit)))
        // 跨段时把中间几段线性补齐：一次横划就是一条连续曲线，不用逐段调。
        if let lastBand, let lastGain, abs(band - lastBand) > 1 {
          let count = band - lastBand
          let step = count > 0 ? 1 : -1
          var b = lastBand + step
          while b != band {
            let t = Float(b - lastBand) / Float(count)
            edit(b, lastGain + (gain - lastGain) * t)
            b += step
          }
        }
        edit(band, gain)
        lastBand = band
        lastGain = gain
      }
      .onEnded { _ in
        lastBand = nil
        lastGain = nil
        onEditEnd?()
      }
  }
}
struct ChainEditor: View {
  @EnvironmentObject var store: MobileStore
  @Environment(\.dismiss) var dismiss
  @State var draft: ListeningChain
  let changed: () -> Void
  init(chain: ListeningChain?, route: RouteInfo, changed: @escaping () -> Void) {
    _draft = State(
      initialValue: chain
        ?? ListeningChain(
          routeUID: route.uid, name: route.name, headphone: route.name, connection: route.transport)
    )
    self.changed = changed
  }
  var acousticModes: [String] {
    let modes =
      EquipmentKnowledge.headphone(draft.headphone)?.modes
      ?? ["ANC 开启", "ANC 关闭", "通透", "被动模式", "开放式佩戴"]
    var options = ["待确认"]
    for mode in modes + [draft.acousticMode] where !options.contains(mode) { options.append(mode) }
    return options
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("独立聆听配置") {
          TextField("配置名称", text: $draft.name).accessibilityIdentifier("chainName")
          TextField("耳机型号", text: $draft.headphone).accessibilityIdentifier("headphoneModel")
          Picker("连接", selection: $draft.connection) {
            ForEach(
              ["bluetooth", "wireless_24", "usb", "analog", "builtin", "airplay"], id: \.self
            ) {
              Text(
                [
                  "bluetooth": "蓝牙", "wireless_24": "2.4GHz 接收器", "usb": "USB 数字音频",
                  "analog": "有线模拟耳机", "builtin": "内置扬声器", "airplay": "AirPlay",
                ][$0] ?? $0
              ).tag($0)
            }
          }
          TextField("前端 / 小尾巴 / 接收器", text: $draft.frontend)
          Picker("声学状态", selection: $draft.acousticMode) {
            ForEach(acousticModes, id: \.self) { Text($0).tag($0) }
          }
          TextField("耳套、耳垫与佩戴", text: $draft.fit)
          Picker("编码偏好（建议）", selection: $draft.codecPreference) {
            ForEach(["系统协商", "音质优先", "低延迟优先", "有线 PCM"], id: \.self) { Text($0) }
          }
        }
        Section("设备资料与聆听目标") {
          NavigationLink {
            EquipmentEditor(chain: $draft)
          } label: {
            Label("参数、调音倾向与使用场景", systemImage: "slider.horizontal.3")
          }.accessibilityIdentifier("equipmentEditor")
          Text("\(draft.equipment?.goal ?? "保留原调音") · \(draft.equipment?.issue ?? "暂无明显问题")")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("其他型号参考试听") {
          TextField("参考耳机型号（可选）", text: $draft.referenceModel)
          TextField("同单元 / 调音等判断依据与出处", text: $draft.referenceEvidence)
          Text("同芯片、同单元不保证频响相同。参考校正不会被标为本型号实测。").font(.caption)
        }
        Section {
          Text("更改耳机、连接、前端或声学条件会创建新链路，EQ 从平直开始。重连时恢复相同输出上的选择；系统无法读取的 ANC 与佩戴变化需手动切换。").font(
            .caption)
        }
      }.appSurface().navigationTitle("聆听链路").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            do { try draft.equipment?.validate() } catch {
              store.message = error.localizedDescription
              return
            }
            guard !draft.name.isEmpty, !draft.headphone.isEmpty else {
              store.message = "填写链路名称与耳机型号"
              return
            }
            guard draft.referenceModel.isEmpty || !draft.referenceEvidence.isEmpty else {
              store.message = "请填写参考依据"
              return
            }
            store.saveChain(draft)
            changed()
            dismiss()
          }.accessibilityIdentifier("saveChain")
        }
      }
    }
  }
}
struct MeasurementView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @State private var query: String
  /// 从「声音」页带型号进来：省掉一次手动输入，这也是这一页最主要的入口。
  init(model: String = "") {
    _query = State(initialValue: model)
  }
  @State private var candidates: [EQCandidate] = []
  @State private var busy = false
  @State private var parameters = ""
  @State private var selected: EQCandidate?
  @State private var conditionsConfirmed = false
  var chain: ListeningChain? { store.activeChain(route: player.route.uid) }
  var body: some View {
    List {
      Section {
        TextField("完整耳机型号", text: $query).textInputAutocapitalization(.never)
        Button(busy ? "正在查询…" : "查询公开测量") {
          Task {
            busy = true
            defer { busy = false }
            do { candidates = try await MeasurementService.search(query) } catch {
              store.message = error.localizedDescription
            }
          }
        }.disabled(busy)
        Menu("按品牌选择型号") {
          ForEach(EquipmentKnowledge.brands, id: \.self) { brand in
            Menu(brand) {
              ForEach(EquipmentKnowledge.headphones.filter { $0.brand == brand }) { model in
                Button(model.name) { query = model.name }
              }
            }
          }
        }
      }
      if candidates.isEmpty {
        Section { Text("没有找到时可以手动导入，或记录参考型号与依据。不会自动用上一代替代。").foregroundStyle(.secondary) }
      }
      ForEach(candidates) { c in
        Section {
          Text(c.name).font(.headline)
          Text(c.attribution).font(.caption)
          Text(c.note).font(.caption).foregroundStyle(.secondary)
          Link("查看出处", destination: URL(string: c.sourceURL)!)
          Button("读取并预览参数") {
            Task {
              busy = true
              defer { busy = false }
              do {
                parameters = try await MeasurementService.parameters(c)
                selected = c
                conditionsConfirmed = false
              } catch { store.message = error.localizedDescription }
            }
          }.disabled(busy)
        }
      }
      if let selected {
        Section("参数预览") {
          Text(parameters).font(.caption.monospaced()).textSelection(.enabled)
          Toggle("已核对型号、连接、ANC 与耳套/耳垫条件", isOn: $conditionsConfirmed)
          if let chain,
            let conflict = MeasurementService.conditionConflict(
              candidate: selected.name, chain: chain,
              requiredAcousticMode: selected.requiredAcousticMode)
          {
            Text(conflict).font(.caption).foregroundStyle(.orange)
          }
          Button("应用到当前链路") {
            guard conditionsConfirmed, let chain,
              MeasurementService.conditionConflict(
                candidate: selected.name, chain: chain,
                requiredAcousticMode: selected.requiredAcousticMode) == nil,
              MeasurementService.matches(
                candidate: selected.name,
                model: chain.referenceModel.isEmpty ? chain.headphone : chain.referenceModel),
              let i = store.state.chains.firstIndex(where: { $0.id == chain.id })
            else { return }
            store.state.chains[i].apo = parameters
            store.state.chains[i].measurementSource =
              selected.attribution + " · " + selected.sourceURL
            store.state.chains[i].eqOrigin = .measurement
            store.save()
            player.useChain(store.state.chains[i])
          }.disabled(
            chain == nil || !conditionsConfirmed
              || chain.map {
                MeasurementService.conditionConflict(
                  candidate: selected.name, chain: $0,
                  requiredAcousticMode: selected.requiredAcousticMode) != nil
              } == true
              || !MeasurementService.matches(
                candidate: selected.name,
                model: chain?.referenceModel.isEmpty == false
                  ? chain!.referenceModel : chain?.headphone ?? "")
          )
          AwakeNote(text: "不同型号需要先在链路里建立参考关系。公开资料的测量条件与当前佩戴不一定相同。")
        }
      }
    }.appSurface().navigationTitle("社区测量参数").task {
      query =
        chain?.referenceModel.isEmpty == false
        ? chain!.referenceModel : chain?.headphone ?? player.route.name
    }
  }
}

/// 参数校正：把测量文件/APO 参数换算成这 31 段。
/// 一年用一两次，所以它不再占「声音」首屏，而是二级页——但状态仍在，进来就能继续改。
struct ManualEQView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @State private var source = ""
  @State private var text = ""
  @State private var importing = false

  private var chain: ListeningChain? { store.activeChain(route: player.route.uid) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Panel {
          Text("测量者、目标与出处链接").font(.subheadline).foregroundStyle(.secondary)
          TextField("例如 AutoEq · HD600 · harman_over-ear_2018", text: $source)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          TextEditor(text: $text)
            .frame(minHeight: 180)
            .font(.caption.monospaced())
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
          HStack {
            Button("读取参数文件") { importing = true }
            Spacer()
            Button("校验并应用") { applyEq() }.buttonStyle(AwakeButtonStyle())
          }
          if let c = chain, !c.measurementSource.isEmpty {
            AwakeNote(text: "当前来源：\(c.measurementSource)")
          }
        }
      }.padding(20)
    }
    .appSurface()
    .navigationTitle("参数校正")
    .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { result in
      do {
        let url = try result.get()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 65536 else {
          throw AppFailure("参数文件不能超过 64KB")
        }
        text = try String(contentsOf: url, encoding: .utf8)
      } catch { store.message = error.localizedDescription }
    }
  }

  private func applyEq() {
    do {
      _ = try EQMath.parse(text)
      guard var c = chain,
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw AppFailure("先在「声音」里保存一条链路，并填写测量来源") }
      c.apo = text
      c.measurementSource = source
      c.eqOrigin = .imported
      store.saveChain(c)
      player.useChain(store.activeChain(route: player.route.uid))
    } catch { store.message = error.localizedDescription }
  }
}

