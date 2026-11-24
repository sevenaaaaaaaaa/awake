import SwiftUI

/// 播放页的仪器部件：链路条、31 段曲线、静默封面。
///
/// 这些数值全部来自真实模型（`MobilePlayer.route` / `EnhancementState` / `ListeningChain`），
/// 没有数据的地方留空或写「—」，不拿占位数字充数。

// MARK: - 数值格式

enum PlayerFormat {
  /// 采样率：48 kHz / 44.1 kHz；0 或异常值给「—」。
  static func hz(_ value: Double) -> String {
    guard value.isFinite, value >= 8000 else { return "—" }
    let k = value / 1000
    let text = k.rounded() == k ? String(Int(k)) : String(format: "%.1f", k)
    return text + " kHz"
  }

  /// 增益：带符号，一位小数。
  static func db(_ value: Float) -> String {
    guard value.isFinite else { return "—" }
    return String(format: "%+.1f dB", value)
  }

  /// 频率标签。
  static func freq(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "—" }
    if value >= 1000 {
      let k = value / 1000
      return (k.rounded() == k ? String(Int(k)) : String(format: "%.1f", k)) + "kHz"
    }
    return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
  }

  /// 输出路由的中文名。系统给的 portName 常常是英文裸词，直接摆出来会和界面其它中文打架。
  static func routeName(_ name: String, transport: String) -> String {
    let lower = name.lowercased()
    if lower.contains("speaker") || lower.contains("扬声器") { return "本机扬声器" }
    if lower.contains("headphone") || lower.contains("耳机") { return "耳机输出" }
    if lower.contains("airpod") { return "AirPods" }
    if lower.contains("bluetooth") || transport.lowercased().contains("bluetooth") { return "蓝牙输出" }
    if lower.contains("airplay") { return "AirPlay" }
    if lower.contains("usb") { return "USB 音频" }
    return name.trimmingCharacters(in: .whitespaces).isEmpty ? "系统输出" : name
  }

  /// 音频格式：从文件名 / Plex 资源路径取扩展名，取不到给「—」。
  static func format(_ path: String?) -> String {
    guard let path, !path.isEmpty else { return "—" }
    let ext = URL(fileURLWithPath: path).pathExtension.uppercased()
    if ext.isEmpty { return "—" }
    return ext == "M4A" ? "AAC" : ext
  }
}

// MARK: - 链路条

/// 音源 → 解码 → EQ → 输出。每一段写真实数值，不是装饰。
struct ChainStrip: View {
  let steps: [(label: String, value: String)]
  private var border: Color { Color.white.opacity(0.08) }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
        VStack(alignment: .leading, spacing: 4) {
          Text(step.label)
            .font(.caption2.weight(.regular))
            .foregroundStyle(.secondary)
          Text(step.value)
            .font(.caption.weight(.medium).monospaced())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if index < steps.count - 1 {
          Rectangle()
            .fill(border)
            .frame(width: 10, height: 1)
            .padding(.top, 19)
            .padding(.horizontal, 2)
        }
      }
    }
    .padding(.vertical, 12)
    .overlay(alignment: .bottom) { Rectangle().fill(border).frame(height: 0.5) }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("信号链")
  }
}

// MARK: - 静默封面

/// 没有封面图时的占位：一块中性面 + 顶部刻度，不用渐变、光斑和标语。
struct PlayerPlate: View {
  @EnvironmentObject var store: MobileStore
  var title: String
  var artwork: String?
  var size: CGFloat
  @State private var image: UIImage?

  private var surface: Color { Color(hex: store.state.skin.colors.surface) }
  private var border: Color { Color(hex: store.state.skin.colors.border) }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6, style: .continuous).fill(surface)
      if let image {
        Image(uiImage: image).resizable().scaledToFill()
          .frame(width: size, height: size).clipped()
      } else {
        VStack(spacing: 0) {
          Canvas { context, bounds in
            var x: CGFloat = 0
            var index = 0
            while x <= bounds.width {
              let h: CGFloat = index % 5 == 0 ? bounds.height : bounds.height * 0.55
              context.fill(
                Path(CGRect(x: x, y: 0, width: 0.5, height: h)),
                with: .color(.white.opacity(index % 5 == 0 ? 0.16 : 0.07)))
              x += 4
              index += 1
            }
          }
          .frame(height: size * 0.18)
          Spacer(minLength: 0)
          Text(String(title.prefix(2)))
            .font(.system(size: size * 0.16, weight: .regular, design: .serif))
            .foregroundStyle(Color(hex: store.state.skin.colors.text).opacity(0.5))
          Spacer(minLength: 0)
        }
        .padding(.top, size * 0.05)
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(border, lineWidth: 0.5))
    .accessibilityHidden(true)
    .task(id: artwork) {
      image = nil
      if let artwork, let url = store.artworkURL(artwork) {
        image = UIImage(contentsOfFile: url.path)
      }
    }
  }
}

// MARK: - 31 段曲线

/// 当前链路实际生效的 31 段增益。能拖：按住曲线上下拖改那一段，松手写回链路。
/// 没有链路记录时只读地画出当前曲线，并写「平直」。
struct EQCurvePanel: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @Binding var gains: [Float]
  var editable: Bool
  var onCommit: ([Float]) -> Void

  @State private var activeBand: Int?
  @State private var dragValue: Float = 0

  private let range: Float = 12
  private let inset: CGFloat = 10
  private let labelBand: CGFloat = 18
  private let panelHeight: CGFloat = 152

  private var accent: Color { Color(hex: store.state.skin.colors.accent) }
  private var border: Color { Color(hex: store.state.skin.colors.border) }
  private var muted: Color { Color(hex: store.state.skin.colors.muted) }

  private var peak: (index: Int, value: Float) {
    let index = gains.indices.max(by: { abs(gains[$0]) < abs(gains[$1]) }) ?? 0
    return (index, gains.indices.contains(index) ? gains[index] : 0)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("31 段曲线")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Spacer()
        Text(caption)
          .font(.caption.weight(.medium).monospaced())
          .foregroundStyle(abs(shownValue) < 0.05 ? muted : accent)
      }
      GeometryReader { geo in
        Canvas { context, size in
          draw(context: &context, size: size)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(size: geo.size))
      }
      .frame(height: panelHeight)
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color(hex: store.state.skin.colors.bg).opacity(0.5)))
      .overlay(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .stroke(border, lineWidth: 0.5))
      .accessibilityElement()
      .accessibilityLabel("31 段均衡曲线")
      .accessibilityValue(caption)
    }
  }

  private var shownValue: Float {
    guard let band = activeBand, gains.indices.contains(band) else { return peak.value }
    return dragValue == 0 && gains[band] != 0 ? gains[band] : dragValue
  }

  private var caption: String {
    if let band = activeBand, gains.indices.contains(band) {
      return PlayerFormat.freq(Double(EQMath.frequencies[band])) + " "
        + PlayerFormat.db(gains[band])
    }
    if abs(peak.value) < 0.05 { return "平直" }
    return PlayerFormat.freq(Double(EQMath.frequencies[peak.index])) + " "
      + PlayerFormat.db(peak.value)
  }

  // MARK: 坐标

  private func x(_ frequency: Double, width: CGFloat) -> CGFloat {
    let lo = log10(20.0)
    let hi = log10(20000.0)
    let clamped = max(20.0, min(20000.0, frequency))
    let ratio: Double = (log10(clamped) - lo) / (hi - lo)
    return CGFloat(ratio) * width
  }

  private func y(_ db: Float, height: CGFloat) -> CGFloat {
    let clamped: Float = max(-range, min(range, db))
    let span: Float = 2 * range
    let ratio: CGFloat = CGFloat(clamped / span)
    return height * (0.5 - ratio)
  }

  private func plotHeight(_ size: CGSize) -> CGFloat {
    max(1, size.height - inset - labelBand)
  }

  // MARK: 绘制

  private func draw(context: inout GraphicsContext, size: CGSize) {
    let width = max(1, size.width - inset * 2)
    let height = plotHeight(size)
    let origin = CGPoint(x: inset, y: inset)

    for frequency in [31.5, 125.0, 500.0, 2000.0, 8000.0, 16000.0] {
      let px = origin.x + x(frequency, width: width)
      var line = Path()
      line.move(to: CGPoint(x: px, y: origin.y))
      line.addLine(to: CGPoint(x: px, y: origin.y + height))
      context.stroke(line, with: .color(border.opacity(0.7)), lineWidth: 0.5)
      context.draw(
        Text(PlayerFormat.freq(frequency))
          .font(.caption2.weight(.regular).monospaced())
          .foregroundStyle(muted),
        at: CGPoint(x: px, y: origin.y + height + 9), anchor: .center)
    }

    for step in [-6.0, 0.0, 6.0] as [Float] {
      let py = origin.y + y(step, height: height)
      var line = Path()
      line.move(to: CGPoint(x: origin.x, y: py))
      line.addLine(to: CGPoint(x: origin.x + width, y: py))
      context.stroke(
        line, with: .color(border.opacity(step == 0 ? 1 : 0.45)),
        style: StrokeStyle(lineWidth: 0.5, dash: step == 0 ? [] : [2, 3]))
      if step == 0 {
        context.draw(
          Text("0")
            .font(.caption2.weight(.regular).monospaced())
            .foregroundStyle(muted),
          at: CGPoint(x: origin.x + 3, y: py - 7), anchor: .leading)
      }
    }

    guard gains.count == EQMath.frequencies.count else { return }

    var curve = Path()
    for (index, gain) in gains.enumerated() {
      let point = CGPoint(
        x: origin.x + x(Double(EQMath.frequencies[index]), width: width),
        y: origin.y + y(gain, height: height))
      if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
    }

    var fill = curve
    fill.addLine(to: CGPoint(x: origin.x + width, y: origin.y + y(0, height: height)))
    fill.addLine(to: CGPoint(x: origin.x, y: origin.y + y(0, height: height)))
    fill.closeSubpath()
    context.fill(fill, with: .color(accent.opacity(0.10)))
    context.stroke(curve, with: .color(accent), lineWidth: 1.5)

    let index = activeBand ?? peak.index
    let value = activeBand == nil ? peak.value : gains[index]
    let marker = CGPoint(
      x: origin.x + x(Double(EQMath.frequencies[index]), width: width),
      y: origin.y + y(value, height: height))

    if activeBand != nil {
      var handle = Path()
      handle.move(to: CGPoint(x: marker.x, y: origin.y))
      handle.addLine(to: CGPoint(x: marker.x, y: origin.y + height))
      context.stroke(handle, with: .color(accent.opacity(0.28)), lineWidth: 0.5)
    }
    context.fill(
      Path(ellipseIn: CGRect(x: marker.x - 2.5, y: marker.y - 2.5, width: 5, height: 5)),
      with: .color(accent))
  }

  // MARK: 拖动

  private func dragGesture(size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard editable, gains.count == EQMath.frequencies.count else { return }
        let width = max(1, size.width - inset * 2)
        let height = plotHeight(size)
        let ratio = Double(max(0, min(width, value.location.x - inset)) / width)
        let lo = log10(20.0), hi = log10(20000.0)
        let frequency = pow(10, lo + ratio * (hi - lo))
        let band = EQMath.frequencies.enumerated().min {
          abs(Double($0.element) - frequency) < abs(Double($1.element) - frequency)
        }?.offset ?? 0
        let raw = (0.5 - Double((value.location.y - inset) / max(1, height)))
          * Double(range) * 2
        let db = Float(max(-Double(range), min(Double(range), raw)))
        // 4 个像素以内不动：手指按住时不要因为抖动把曲线改乱。
        if abs(db - (gains[band])) < 0.25, activeBand != band {
          activeBand = band
          dragValue = gains[band]
          return
        }
        var next = gains
        next[band] = db
        gains = next
        activeBand = band
        dragValue = db
        let chain = store.activeChain(route: player.route.uid)
        player.setEQ(
          next, apo: chain?.apo ?? "", origin: chain?.eqOrigin ?? .manual,
          profile: chain?.headphone ?? player.route.name,
          source: chain?.measurementSource ?? "", announce: false)
      }
      .onEnded { _ in
        guard editable else { return }
        onCommit(gains)
        activeBand = nil
      }
  }
}

// MARK: - Mini 播放器的音效状态

/// 原来的发光胶囊换成一行 mono 状态；仍然是按钮，点开是详情。
struct MiniEnhancementLabel: View {
  @EnvironmentObject var player: MobilePlayer
  @EnvironmentObject var store: MobileStore
  @State private var details = false

  var body: some View {
    Button {
      details = true
    } label: {
      Text(player.enhancement.shortTitle)
        .font(.caption2.weight(.medium).monospaced())
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("miniEnhancementBadge")
    .accessibilityValue(player.enhancement.title(playing: player.playing))
    .sheet(isPresented: $details) {
      EnhancementDetails().environmentObject(store).environmentObject(player)
    }
  }
}

// MARK: - 写回链路

extension MobileStore {
  /// 播放页拖动曲线后写回这条链路；没有链路记录（未识别耳机）时不动任何东西。
  func setChainGains(_ gains: [Float], route: String) {
    guard gains.count == 31,
      let id = state.activeChains[route],
      let index = state.chains.firstIndex(where: { $0.id == id }),
      state.chains[index].gains != gains
    else { return }
    state.chains[index].gains = gains
    save()
  }
}
