import SwiftUI
import UIKit

struct EnhancementBadge: View {
  @EnvironmentObject private var player: MobilePlayer
  @EnvironmentObject private var store: MobileStore
  @State private var details = false
  var compact = false
  var context = "player"
  private var accent: Color { Color(hex: store.state.skin.colors.accent) }
  var body: some View {
    Button {
      details = true
    } label: {
      HStack(spacing: compact ? 4 : 7) {
        Image(systemName: player.enhancement.enabled ? "sparkles" : "waveform")
          .font(.system(size: compact ? 10 : 13, weight: .semibold))
        Text(
          compact
            ? player.enhancement.shortTitle : player.enhancement.title(playing: player.playing)
        )
        .font(compact ? .caption2.weight(.bold) : .caption.weight(.semibold))
        .lineLimit(1)
        if !compact && player.enhancement.enabled {
          Circle().fill(accent).frame(width: 5, height: 5).accessibilityHidden(true)
        }
      }.foregroundStyle(player.enhancement.enabled ? accent : .secondary)
        .padding(.horizontal, compact ? 7 : 12).padding(.vertical, compact ? 5 : 9)
        .background {
          Capsule().fill(
            player.enhancement.enabled ? accent.opacity(0.12) : Color.secondary.opacity(0.08))
        }.overlay {
          Capsule().stroke(
            player.enhancement.enabled ? accent.opacity(0.4) : Color.secondary.opacity(0.2),
            lineWidth: 0.6)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityIdentifier(
      compact
        ? "miniEnhancementBadge" : context == "sound" ? "soundEnhancementBadge" : "enhancementBadge"
    )
    .accessibilityLabel("音效状态")
    .accessibilityValue(player.enhancement.title(playing: player.playing))
    .sheet(isPresented: $details) { EnhancementDetails() }
  }
}

struct EnhancementDetails: View {
  @EnvironmentObject private var player: MobilePlayer
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Label(
            player.enhancement.title(playing: player.playing),
            systemImage: player.enhancement.enabled ? "sparkles" : "waveform"
          )
          .font(.headline).accessibilityIdentifier("enhancementState")
          Button(
            player.bypassed ? "恢复 EQ 增强" : "临时聆听原声",
            systemImage: player.bypassed ? "sparkles" : "waveform"
          ) {
            player.bypassed.toggle()
          }.buttonStyle(AwakeButtonStyle()).disabled(!player.enhancement.configured)
            .accessibilityIdentifier("effectDetailsBypass")
        } footer: {
          Text("旁路保留你的曲线，随时可恢复。暂停时显示就绪。")
        }
        Section("当前链路") {
          Text(player.enhancement.profile)
          Text(player.enhancement.detail).font(.subheadline).foregroundStyle(.secondary)
          if !player.enhancement.source.isEmpty {
            Text(player.enhancement.source).font(.caption).textSelection(.enabled)
          }
        }
        Section {
          Text("标识反映播放器实际启用的处理。手动 EQ、导入参数与测量校正分别标注；有明确 AI 来源的已应用配置才显示 AI EQ。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }.appSurface().navigationTitle("声音增强").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("完成") { dismiss() } }
    }.overlay(alignment: .top) { EffectActivationOverlay(priority: 2) }
      .presentationDetents([.medium, .large])
  }
}

struct EffectActivationOverlay: View {
  @EnvironmentObject private var player: MobilePlayer
  @State private var surface = UUID()
  var priority = 0
  var body: some View {
    ZStack {
      if player.effectSurface == surface, let event = player.activation {
        EffectActivationCard(event: event).id(event.id)
          .padding(.horizontal, 18).padding(.top, 10)
          .transition(.opacity)
          .task(id: event.id) {
            if player.announceEffectOnce(event.id) {
              UIAccessibility.post(
                notification: .announcement, argument: event.title + "，" + event.state.profile)
            }
            let remaining = 2.6 - Date().timeIntervalSince(event.created)
            do { if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) } } catch {
              return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { player.dismissEffect(event.id) }
          }
      }
    }.allowsHitTesting(false)
      .onAppear { player.registerEffectSurface(surface, priority: priority) }
      .onDisappear { player.registerEffectSurface(surface, priority: nil) }
  }
}

struct EffectActivationCard: View {
  let event: EffectActivation
  @EnvironmentObject private var store: MobileStore
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.awakeReducedMotion) private var forcedReduceMotion
  private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
  @Environment(\.scenePhase) private var scenePhase
  @State private var progress = 0.0
  private var accent: Color { Color(hex: store.state.skin.colors.accent) }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 16) {
        ZStack {
          Circle().fill(accent.opacity(0.10))
          if !reduceMotion && scenePhase == .active {
            Circle().stroke(accent.opacity(0.45 * (1 - progress)), lineWidth: 1)
              .scaleEffect(0.7 + progress * 0.75)
            Circle().trim(from: 0.05, to: 0.72).stroke(
              AngularGradient(colors: [accent.opacity(0.05), accent], center: .center),
              style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
            .rotationEffect(.degrees(-90 + progress * 270))
          } else {
            Circle().stroke(accent.opacity(0.35), lineWidth: 1)
          }
          Image(systemName: event.symbol).font(.system(size: 29, weight: .light))
            .scaleEffect(reduceMotion ? 1 : 0.9 + progress * 0.1)
        }.frame(width: 64, height: 64).foregroundStyle(accent).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(accent)
            Text(event.title).font(.headline)
          }
          Text(event.state.profile).font(.subheadline).lineLimit(2)
          Text(event.state.enabled ? "曲线已就绪，继续你的音乐" : "保留音乐原本的声音")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      ZStack {
        Path { path in
          path.move(to: CGPoint(x: 0, y: 23))
          path.addLine(to: CGPoint(x: 320, y: 23))
        }.stroke(accent.opacity(0.15), style: StrokeStyle(lineWidth: 0.8, dash: [3, 5]))
        EffectCurve(gains: event.displayGains, progress: reduceMotion ? 1 : progress)
          .stroke(
            LinearGradient(
              colors: [accent.opacity(0.3), accent, accent.opacity(0.4)], startPoint: .leading,
              endPoint: .trailing),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
          )
          .shadow(color: accent.opacity(0.4), radius: 5)
      }.frame(height: 46).clipped().accessibilityHidden(true)
      Text("曲线演示 · 参数示意").font(.caption2).foregroundStyle(.secondary)
    }.padding(18).frame(maxWidth: 380, alignment: .leading)
      .foregroundStyle(Color(hex: store.state.skin.colors.text))
      .background(
        Color(hex: store.state.skin.colors.surface), in: RoundedRectangle(cornerRadius: 24)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 24).stroke(
          LinearGradient(
            colors: [accent.opacity(0.65), accent.opacity(0.08)], startPoint: .topLeading,
            endPoint: .bottomTrailing), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.25), radius: 22, y: 12)
      .accessibilityElement(children: .combine).accessibilityIdentifier("effectActivation")
      .accessibilityValue(reduceMotion ? "减少动态效果" : "动态演示")
      .onAppear {
        if reduceMotion {
          progress = 1
        } else {
          withAnimation(.easeOut(duration: 0.85)) { progress = 1 }
        }
      }
  }
}

private struct EffectCurve: Shape {
  var gains: [Float]
  var progress: Double
  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }
  func path(in rect: CGRect) -> Path {
    var path = Path()
    guard gains.count > 1 else { return path }
    let points = gains.indices.map { i in
      CGPoint(
        x: Double(i) / Double(gains.count - 1) * rect.width,
        y: rect.midY - Double(gains[i]) / 14 * rect.height * 0.42 * progress)
    }
    path.move(to: points[0])
    for i in 1..<points.count {
      let middle = CGPoint(
        x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
      path.addQuadCurve(to: middle, control: points[i - 1])
    }
    path.addLine(to: points.last!)
    return path
  }
}

private struct AwakeReducedMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var awakeReducedMotion: Bool {
    get { self[AwakeReducedMotionKey.self] }
    set { self[AwakeReducedMotionKey.self] = newValue }
  }
}
