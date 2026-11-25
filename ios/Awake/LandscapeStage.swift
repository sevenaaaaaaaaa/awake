import SwiftUI

/// 横屏播放页：一台会转的机器 + 一条控制带。
///
/// 为什么横屏要有另一套布局：横过来之后屏幕只剩一半高，竖屏那套纵向信息流
/// （封面、卡片、歌词窗口、仪器区）全都不成立。横屏真正想看的是「我在听这张碟」——
/// 载体在转、切歌像换碟、形态可以换，而不是把竖屏压扁。
struct LandscapePlayerView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer

  @State private var carrier: Carrier = .cd
  @State private var ejecting = false
  @State private var spinning = false
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.awakeReducedMotion) private var forcedReduceMotion

  private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
  private var accent: Color { Color(hex: store.state.skin.colors.accent) }
  private var muted: Color { Color(hex: store.state.skin.colors.muted) }
  private var surface: Color { Color(hex: store.state.skin.colors.surface) }

  private enum Carrier: String, CaseIterable, Identifiable {
    case cd, cassette, vinyl
    var id: String { rawValue }
    var title: String {
      switch self {
      case .cd: return "CD"
      case .cassette: return "磁带"
      case .vinyl: return "黑胶"
      }
    }
    var icon: String {
      switch self {
      case .cd: return "opticaldisc"
      case .cassette: return "recordingtape"
      case .vinyl: return "circle.circle"
      }
    }
  }

  var body: some View {
    HStack(spacing: DS.Space.l) {
      stage
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      controls
        .frame(maxWidth: .infinity)
    }
    .padding(DS.Space.l)
    .background(stageBackground)
    .onAppear { spinning = player.playing && !reduceMotion }
    .onChange(of: player.playing) { _, playing in spinning = playing && !reduceMotion }
    .onChange(of: player.song?.id) { _, _ in eject() }
  }

  // MARK: - 载体舞台

  private var stage: some View {
    ZStack {
      switch carrier {
      case .cd: cdDisc
      case .cassette: cassetteTape
      case .vinyl: vinylRecord
      }
    }
    .scaleEffect(ejecting ? 0.86 : 1)
    .opacity(ejecting ? 0.15 : 1)
    .animation(.easeIn(duration: 0.22), value: ejecting)
    .accessibilityElement()
    .accessibilityLabel("\(carrier.title)：\(player.song?.title ?? "空仓")")
    .accessibilityHint("轻点切换载体形态")
    .onTapGesture {
      // 换形态是这个页面唯一的「玩法」：同一首歌换个载体听，视觉上的差别比参数更直接。
      let all = Carrier.allCases
      let next = all[(all.firstIndex(of: carrier) ?? 0) + 1 == all.count ? 0 : (all.firstIndex(of: carrier) ?? 0) + 1]
      withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { carrier = next }
    }
  }

  private var coverSize: CGFloat { 150 }

  /// CD：银色盘面 + 一圈内环 + 一张印在盘面上的封面。
  private var cdDisc: some View {
    ZStack {
      Circle()
        .fill(
          AngularGradient(
            colors: [
              Color(white: 0.72), Color(white: 0.45), Color(white: 0.86), Color(white: 0.38),
              Color(white: 0.66), Color(white: 0.86), Color(white: 0.5), Color(white: 0.72),
            ], center: .center))
      Circle()
        .fill(Color.black.opacity(0.28))
        .frame(width: coverSize * 1.5, height: coverSize * 1.5)
      Cover(
        title: player.song?.title ?? "空仓", artwork: player.song?.artwork,
        style: player.song?.mediaInfo?.cover_style ?? "auto", size: coverSize)
        .clipShape(Circle())
      Circle()
        .fill(Color(hex: store.state.skin.colors.bg))
        .frame(width: coverSize * 0.16, height: coverSize * 0.16)
      progressRing
    }
    .padding(6)
    .rotationEffect(.degrees(spinning ? 360 : 0))
    .animation(
      reduceMotion ? nil : .linear(duration: 9).repeatForever(autoreverses: false), value: spinning)
  }

  /// 黑胶：一大圈纹路 + 中间标签 + 更像「唱片在转」的慢速。
  private var vinylRecord: some View {
    ZStack {
      Circle().fill(Color(white: 0.06))
      ForEach(0..<14, id: \.self) { index in
        Circle()
          .stroke(Color.white.opacity(0.05), lineWidth: 0.6)
          .frame(width: coverSize * (1.5 + CGFloat(index) * 0.12))
      }
      Circle()
        .fill(Color(hex: store.state.skin.colors.surface))
        .frame(width: coverSize * 0.7, height: coverSize * 0.7)
      Cover(
        title: player.song?.title ?? "空仓", artwork: player.song?.artwork,
        style: player.song?.mediaInfo?.cover_style ?? "auto", size: coverSize * 0.62)
        .clipShape(Circle())
      Circle().fill(Color.black).frame(width: 6, height: 6)
      progressRing
    }
    .padding(6)
    .rotationEffect(.degrees(spinning ? 360 : 0))
    .animation(
      reduceMotion ? nil : .linear(duration: 14).repeatForever(autoreverses: false), value: spinning)
  }

  /// 磁带：盒体 + 两个卷轴 + 中间贴纸。卷轴只在播放时转，且比 CD 快。
  private var cassetteTape: some View {
    VStack(spacing: 0) {
      HStack(spacing: DS.Space.s) {
        reel
        Spacer(minLength: 0)
        reel
      }
      .padding(.horizontal, 18)
      .padding(.top, 16)
      Cover(
        title: player.song?.title ?? "空仓", artwork: player.song?.artwork,
        style: player.song?.mediaInfo?.cover_style ?? "auto", size: coverSize)
        .padding(.bottom, 12)
    }
    .frame(width: coverSize * 2.1, height: coverSize * 1.45)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(white: 0.16))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 0.8)))
    .overlay(alignment: .bottom) { progressRing.padding(.horizontal, 16).padding(.bottom, 8) }
  }

  private var reel: some View {
    ZStack {
      Circle().stroke(Color.white.opacity(0.22), lineWidth: 1.4)
      ForEach(0..<3, id: \.self) { index in
        Capsule()
          .fill(Color.white.opacity(0.24))
          .frame(width: 22, height: 2)
          .rotationEffect(.degrees(Double(index) * 60))
      }
    }
    .frame(width: 44, height: 44)
    .rotationEffect(.degrees(spinning ? 360 : 0))
    .animation(
      reduceMotion ? nil : .linear(duration: 2.2).repeatForever(autoreverses: false), value: spinning)
  }

  /// 进度：一圈细弧，从 12 点开始。三种载体通用。
  private var progressRing: some View {
    let fraction = player.duration > 0 ? min(1, max(0, player.position / player.duration)) : 0
    return Circle()
      .trim(from: 0, to: max(0.001, fraction))
      .stroke(accent.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
      .rotationEffect(.degrees(-90))
      .animation(.linear(duration: 0.25), value: fraction)
  }

  private var stageBackground: some View {
    RadialGradient(
      colors: [Color(hex: store.state.skin.colors.surface), Color(hex: store.state.skin.colors.bg)],
      center: .center, startRadius: 20, endRadius: 420)
      .ignoresSafeArea()
  }

  private func eject() {
    guard !reduceMotion else { return }
    ejecting = true
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 240_000_000)
      withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { ejecting = false }
    }
  }

  // MARK: - 控制带

  private var controls: some View {
    VStack(alignment: .leading, spacing: DS.Space.m) {
      VStack(alignment: .leading, spacing: 3) {
        Text(player.song?.title ?? "没有在播放")
          .font(.title3.weight(.semibold))
          .lineLimit(1)
        Text(
          [player.song?.artist, player.song?.album].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
        )
        .font(.footnote).foregroundStyle(muted).lineLimit(1)
      }
      Slider(
        value: Binding(
          get: { player.duration > 0 ? player.position / player.duration : 0 },
          set: { player.seek($0 * player.duration) }
        ), in: 0...1
      )
      .tint(accent)
      .accessibilityLabel("播放进度")
      HStack(spacing: 6) {
        Text(clock(player.position)).font(.caption2.monospacedDigit()).foregroundStyle(muted)
        Spacer(minLength: 0)
        Text(clock(player.duration)).font(.caption2.monospacedDigit()).foregroundStyle(muted)
      }
      HStack(spacing: DS.Space.l) {
        Button {
          player.previous()
        } label: {
          Image(systemName: "backward.fill").font(.title3)
        }
        .accessibilityLabel("上一首")
        Button {
          player.toggle()
        } label: {
          Image(systemName: player.playing ? "pause.fill" : "play.fill")
            .font(.title2)
            .frame(width: 56, height: 56)
            .foregroundStyle(Color(hex: store.state.skin.colors.bg))
            .background(Circle().fill(Color(hex: store.state.skin.colors.text)))
        }
        .accessibilityLabel(player.playing ? "暂停" : "播放")
        Button {
          player.next()
        } label: {
          Image(systemName: "forward.fill").font(.title3)
        }
        .accessibilityLabel("下一首")
        Spacer(minLength: 0)
        Button {
          let all = Carrier.allCases
          let index = all.firstIndex(of: carrier) ?? 0
          withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            carrier = all[(index + 1) % all.count]
          }
        } label: {
          Label(carrier.title, systemImage: carrier.icon).font(.caption)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("landscapeCarrier")
      }
      .foregroundStyle(Color(hex: store.state.skin.colors.text))
      Text("横过来是一台机器：点载体换形态，切歌就是换碟。")
        .font(.caption2).foregroundStyle(muted)
    }
  }

  private func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
