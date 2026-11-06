import SwiftUI
import AwakeCore

struct EQPanelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var gains: [Float] = []
    @State private var didEdit = false

    private var automaticCurve: EQCurve {
        model.autoEQDecision?.curve ?? .flat
    }

    private var currentGains: [Float] {
        gains.count == EQBand.count ? gains : automaticCurve.gains
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AwakeTheme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summaryCard
                    curveGraph
                    bandSliders
                    controls
                }
                .padding(24)
            }
        }
        .frame(width: 900, height: 620)
        .background(AwakeTheme.background)
        .onAppear { syncFromModel() }
        .onChange(of: model.autoEQDecision) { _, _ in
            if !didEdit { syncFromModel() }
        }
    }

    private func syncFromModel() {
        gains = automaticCurve.gains
        didEdit = false
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(AwakeTheme.deepIndigo).frame(width: 34, height: 34)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AwakeTheme.accent)
            }
            Text("自动 EQ")
                .font(.system(size: AwakeType.titleSize, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: Binding(get: { model.settings.settings.autoEQ },
                                     set: { model.setAutoEQEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(AwakeTheme.accent)
            Button("完成") { dismiss() }
                .buttonStyle(PillButtonStyle(filled: true))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(AwakeTheme.surface.opacity(0.5))
    }

    private var summaryCard: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.autoEQDecision?.headphone.displayName ?? "未检测到耳机配置")
                    .font(.system(size: AwakeType.bodySize, weight: .semibold))
                    .foregroundStyle(.white)
                Text(model.autoEQDecision?.reason ?? "播放一首歌后自动生成。")
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(AwakeTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let profile = model.autoEQDecision?.trackProfile {
                    HStack(spacing: 12) {
                        stat("低频", String(format: "%.1f dB", profile.lowDB))
                        stat("中频", String(format: "%.1f dB", profile.midDB))
                        stat("高频", String(format: "%.1f dB", profile.highDB))
                        stat("亮度", String(format: "%.2f", profile.centroid))
                    }
                    .padding(.top, 4)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(model.engine.outputDevice?.name ?? "系统输出")
                    .font(.system(size: AwakeType.metaSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Text(model.engine.outputDevice?.transportLabel ?? "")
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                if model.engine.isBitPerfect {
                    Text("BIT-PERFECT")
                        .font(.system(size: AwakeType.metaSize, weight: .bold))
                        .foregroundStyle(AwakeTheme.warm)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(AwakeTheme.warm.opacity(0.14)))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AwakeTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AwakeTheme.border.opacity(0.8), lineWidth: 1))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: AwakeType.metaSize))
                .foregroundStyle(AwakeTheme.tertiaryText)
            Text(value)
                .font(.system(size: AwakeType.bodySize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var curveGraph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.25))
            GridLines()
            CurveShape(gains: currentGains)
                .fill(LinearGradient(colors: [AwakeTheme.indigo.opacity(0.45), .clear],
                                     startPoint: .top,
                                     endPoint: .bottom))
            CurveShape(gains: currentGains)
                .stroke(LinearGradient(colors: [AwakeTheme.accent, AwakeTheme.indigo],
                                       startPoint: .leading,
                                       endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            HStack {
                Text("+12 dB").font(.system(size: AwakeType.metaSize)).foregroundStyle(AwakeTheme.tertiaryText)
                Spacer()
                Text("0").font(.system(size: AwakeType.metaSize)).foregroundStyle(AwakeTheme.tertiaryText)
                Spacer()
                Text("-12 dB").font(.system(size: AwakeType.metaSize)).foregroundStyle(AwakeTheme.tertiaryText)
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AwakeTheme.border.opacity(0.8), lineWidth: 1))
    }

    private var bandSliders: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Array(EQBand.frequencies.enumerated()), id: \.offset) { index, frequency in
                    VStack(spacing: 6) {
                        Text(abs(currentGains[safe: index] ?? 0) > 0.05
                             ? String(format: "%.0f", currentGains[safe: index] ?? 0)
                             : " ")
                            .font(.system(size: AwakeType.metaSize))
                            .foregroundStyle(AwakeTheme.accent)
                        EQBandSlider(value: binding(for: index), tint: AwakeTheme.accent)
                            .frame(height: 120)
                        Text(index % 5 == 0 ? EQBand.label(for: index) : " ")
                            .font(.system(size: AwakeType.metaSize))
                            .foregroundStyle(AwakeTheme.tertiaryText)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }

    private func binding(for index: Int) -> Binding<Float> {
        Binding(
            get: { currentGains[safe: index] ?? 0 },
            set: { value in
                var updated = currentGains
                guard updated.indices.contains(index) else { return }
                updated[index] = value
                gains = updated
                didEdit = true
                let boost = max(0, updated.max() ?? 0)
                let curve = EQCurve(gains: updated,
                                    preamp: -(boost + 0.8) + Float(min(0, model.settings.settings.headroomDB)))
                model.previewManualEQ(curve)
            }
        )
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("强度")
                        .font(.system(size: AwakeType.metaSize, weight: .semibold))
                        .foregroundStyle(AwakeTheme.secondaryText)
                    Slider(value: Binding(get: { model.settings.settings.autoEQIntensity },
                                          set: { model.setAutoEQIntensity($0); syncFromModel() }),
                           in: 0...1.2)
                        .frame(width: 220)
                        .tint(AwakeTheme.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("耳机")
                        .font(.system(size: AwakeType.metaSize, weight: .semibold))
                        .foregroundStyle(AwakeTheme.secondaryText)
                    Picker("", selection: Binding(get: { model.settings.settings.headphoneProfileID },
                                                  set: { model.setHeadphonePreference($0); syncFromModel() })) {
                        Text("自动识别").tag("auto")
                        ForEach(HeadphoneDatabase.all) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                    .tint(AwakeTheme.accent)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(String(format: "预览曲线峰值 %.1f dB", currentGains.max() ?? 0))
                        .font(.system(size: AwakeType.metaSize))
                        .foregroundStyle(AwakeTheme.tertiaryText)
                    HStack(spacing: 10) {
                        Button("重置学习") { model.resetListeningProfile() }
                            .buttonStyle(PillButtonStyle(filled: false))
                        Button("记住这个声音") { model.rememberCurrentSound() }
                            .buttonStyle(PillButtonStyle(filled: true))
                            .disabled(!didEdit)
                            .opacity(didEdit ? 1 : 0.45)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AwakeTheme.surface))
    }
}

// MARK: - Curve visuals

struct CurveShape: Shape {
    var gains: [Float]

    func path(in rect: CGRect) -> Path {
        let count = max(2, gains.count)
        let mid = rect.midY
        let scale = rect.height / 2 / 14
        var path = Path()
        for index in 0..<count {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(count - 1)
            let value = CGFloat(gains[safe: index] ?? 0)
            let y = mid - value * scale
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

struct FilledCurveShape: Shape {
    var gains: [Float]

    func path(in rect: CGRect) -> Path {
        var path = CurveShape(gains: gains).path(in: rect)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

struct GridLines: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                for index in 0...4 {
                    let y = geo.size.height * CGFloat(index) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                for index in 0...6 {
                    let x = geo.size.width * CGFloat(index) / 6
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                }
            }
            .stroke(AwakeTheme.border.opacity(0.35), lineWidth: 1)
        }
    }
}

struct EQBandSlider: View {
    @Binding var value: Float
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let range: Float = 24
            let mid = geo.size.height / 2
            let factor = (geo.size.height - 12) / CGFloat(range)
            ZStack {
                Capsule()
                    .fill(AwakeTheme.surfaceRaised)
                    .frame(width: 3)
                Rectangle()
                    .fill(AwakeTheme.surfaceRaised)
                    .frame(width: 9, height: 1)
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: tint.opacity(0.6), radius: 5)
                    .offset(y: -CGFloat(value) * factor)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let delta = Float((mid - gesture.location.y) / factor)
                        value = max(-12, min(12, delta))
                    }
            )
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
