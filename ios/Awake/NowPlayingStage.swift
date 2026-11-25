import SwiftUI
import UIKit

/// 正在播放页的主视觉组件。
///
/// 这一页以前是「把设置页的东西从上往下摊开」：封面 112pt、歌词在页面最底部、
/// 每一项都是同样字号的 caption。这里把结构固定成一条纵深：
/// 环境色 → 封面 → 曲名 → 跟随歌词 → 进度 → 传输 → 折叠的仪器区。
///
/// 动效只有两种，和 design-system 的约定一致：
/// 1. 环境层 9 秒的呼吸（透明度与 2% 缩放），暂停即停；
/// 2. 歌词换行 0.28 秒的位移。
/// 没有旋转、没有弹跳、没有超过 300ms 的过渡；减弱动效时全部静止。

// MARK: - 封面取色

/// 从封面图取一个环境色。只取一次（按文件名缓存），失败时退回中性色。
///
/// 不做「每帧取色」：这一层是背景氛围，不是音频可视化，不该跟着播放跳。
enum ArtworkPalette {
  private static let cache = NSCache<NSString, UIColor>()

  @MainActor static func color(for artwork: String?, store: MobileStore) -> Color {
    let neutral = Color(uiColor: UIColor(red: 0.42, green: 0.47, blue: 0.56, alpha: 1))
    guard let artwork, let url = store.artworkURL(artwork) else { return neutral }
    if let cached = cache.object(forKey: artwork as NSString) { return Color(uiColor: cached) }
    guard let image = UIImage(contentsOfFile: url.path), let cg = image.cgImage else {
      return neutral
    }
    let color = average(of: cg) ?? UIColor(red: 0.42, green: 0.47, blue: 0.56, alpha: 1)
    cache.setObject(color, forKey: artwork as NSString)
    return Color(uiColor: color)
  }

  /// 缩到 1×1 求平均。比 CIFilter 便宜，也比按主色做直方图稳定。
  private static func average(of image: CGImage) -> UIColor? {
    var pixel = [UInt8](repeating: 0, count: 4)
    guard
      let context = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let r = CGFloat(pixel[0]) / 255, g = CGFloat(pixel[1]) / 255, b = CGFloat(pixel[2]) / 255
    // 压一点亮度范围：太黑的环境层看不出呼吸，太亮会盖住文字。
    // 环境层只做「有一点来自封面」的暗示，所以亮度上限收得比原来低：
    // 太亮的染色会让播放页看起来像另一套主题。
    let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let lift = max(0.16, min(0.40, luminance))
    let scale = lift / max(0.08, luminance)
    return UIColor(
      red: min(1, r * scale), green: min(1, g * scale), blue: min(1, b * scale), alpha: 1)
  }
}

// MARK: - 环境层

/// 播放页背景：皮肤底色 + 两团来自封面的柔光。
///
/// 呼吸只在播放时进行，用 `repeatForever` 交给 Core Animation，不逐帧重算布局。
struct PlaybackAmbience: View {
  @EnvironmentObject var store: MobileStore
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.awakeReducedMotion) private var forcedReduceMotion

  var artwork: String?
  var playing: Bool
  @State private var breathing = false

  private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }

  var body: some View {
    let tint = ArtworkPalette.color(for: artwork, store: store)
    ZStack {
      Color(hex: store.state.skin.colors.bg)
      // 强度压到主界面同一套色阶能接受的量：以前的 0.62 让播放页像另一套配色，
      // 现在只留一层能看出「来自封面」的余地，底色仍是皮肤底色。
      RadialGradient(
        colors: [tint.opacity(0.30), tint.opacity(0.08), .clear],
        center: UnitPoint(x: 0.22, y: 0.12), startRadius: 0, endRadius: 460
      )
      .scaleEffect(breathing ? 1.12 : 1.0)
      .opacity(breathing ? 1.0 : 0.78)
      RadialGradient(
        colors: [tint.opacity(0.14), .clear],
        center: UnitPoint(x: 0.86, y: 0.62), startRadius: 0, endRadius: 380
      )
      .scaleEffect(breathing ? 1.0 : 1.08)
      .opacity(breathing ? 0.9 : 0.6)
      // 底部压一层底色，保证歌词与时间在任何封面上都读得清。
      LinearGradient(
        colors: [.clear, Color(hex: store.state.skin.colors.bg).opacity(0.55)],
        startPoint: .center, endPoint: .bottom)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .animation(
      reduceMotion ? nil : .easeInOut(duration: 9).repeatForever(autoreverses: true),
      value: breathing
    )
    .onAppear { breathing = playing && !reduceMotion }
    .onChange(of: playing) { _, value in breathing = value && !reduceMotion }
    .onChange(of: reduceMotion) { _, value in breathing = playing && !value }
  }
}

// MARK: - 封面

/// 首屏封面：圆角 + 一层很浅的投影，播放时随环境层一起「呼吸」。
struct HeroArtwork: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.awakeReducedMotion) private var forcedReduceMotion

  var song: Song
  var size: CGFloat
  var playing: Bool

  @State private var expanded = false
  private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }

  var body: some View {
    PlayerPlate(title: song.title, artwork: song.artwork, size: size)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    // 进度直接长在封面上：这一页最常被看的是「放到哪了」，
    // 但进度条在屏底，手指在封面上时不方便确认。一条 3pt 的线就够，不抢封面。
    .overlay(alignment: .bottomLeading) {
      let fraction = player.duration > 0 ? player.position / player.duration : 0
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.18))
        Capsule()
          .fill(Color(hex: store.state.skin.colors.accent))
          .frame(width: max(0, min(1, fraction)) * (size - 28))
      }
      .frame(width: size - 28, height: 3)
      .padding(.leading, 14)
      .padding(.bottom, 12)
      .allowsHitTesting(false)
    }
    .shadow(color: .black.opacity(0.45), radius: 26, x: 0, y: 18)
    .scaleEffect(expanded ? 1.015 : 1.0)
    .animation(
      reduceMotion ? nil : .easeInOut(duration: 12).repeatForever(autoreverses: true),
      value: expanded
    )
    .onAppear { expanded = playing && !reduceMotion }
    .onChange(of: playing) { _, value in expanded = value && !reduceMotion }
    .accessibilityHidden(true)
  }
}

// MARK: - 跟随歌词

/// 歌词舞台：固定的五行窗口，当前行居中，换行时整块位移。
///
/// 不用嵌套 ScrollView —— 外层页面本身要滚动，两层纵向滚动会互相抢手势。
/// 现在的做法是把所有行画在一个 VStack 里，再用 offset 把当前行对到中间，
/// 位移交给 0.28 秒的 easeOut。点击任意一行仍然可以跳转。
struct LyricsStage: View {
  @EnvironmentObject var store: MobileStore
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.awakeReducedMotion) private var forcedReduceMotion

  var song: Song
  var position: Double
  var onSeek: (Double) -> Void
  var onEdit: () -> Void

  @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 40
  private let visibleRows: CGFloat = 5

  private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
  private var lines: [LyricLine] { MediaLyrics.parseCached(song.lyrics ?? "") }
  private var current: Int { MediaLyrics.currentIndex(lines, at: position) ?? 0 }

  var body: some View {
    VStack(spacing: 0) {
      if lines.isEmpty {
        emptyState
      } else {
        stage
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var stageHeight: CGFloat { rowHeight * visibleRows }

  /// 当前行永远落在第 3 行：只渲染 current-2…current+2 这五行。
  /// 不用滚动偏移、不用嵌套 ScrollView —— 居中由结构保证，换行只换这五行。
  private var window: [Int] { (-2...2).map { current + $0 } }

  private var stage: some View {
    VStack(spacing: 0) {
      ForEach(window, id: \.self) { index in
        if lines.indices.contains(index) {
          Button {
            onSeek(lines[index].time)
          } label: {
            lyricText(index)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("跳到 \(clock(lines[index].time))：\(lines[index].text)")
        } else {
          Color.clear.frame(height: rowHeight)
        }
      }
    }
    .frame(height: stageHeight)
    .clipped()
    .mask(
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: .black, location: 0.16),
          .init(color: .black, location: 0.84),
          .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    )
    .animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: current)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("歌词")
    .accessibilityValue(lines.indices.contains(current) ? lines[current].text : "")
  }

  private func lyricText(_ index: Int) -> some View {
    let line = lines[index]
    let isCurrent = index == current
    return Text(line.text)
      .font(isCurrent ? .title3.weight(.semibold) : .body)
      .foregroundStyle(
        isCurrent
          ? Color(hex: store.state.skin.colors.text)
          : Color(hex: store.state.skin.colors.muted)
            .opacity(max(0.28, 0.72 - 0.16 * Double(abs(index - current)))))
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .frame(maxWidth: .infinity, alignment: .center)
      .frame(height: rowHeight)
      .contentShape(Rectangle())
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Text("还没有歌词")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Color(hex: store.state.skin.colors.text))
      Text("导入 LRC 或粘贴歌词后，这里会跟着播放逐行滚动。")
        .font(.footnote)
        .foregroundStyle(Color(hex: store.state.skin.colors.muted))
        .multilineTextAlignment(.center)
      Button("添加歌词") { onEdit() }
        .font(.footnote.weight(.medium))
        .buttonStyle(.borderless)
        .accessibilityIdentifier("addLyricsFromStage")
    }
    .frame(maxWidth: .infinity)
    .frame(height: stageHeight)
    .padding(.horizontal, 24)
    .accessibilityIdentifier("lyricsEmptyState")
  }
}

// MARK: - 进度

struct PlayerProgressBar: View {
  @EnvironmentObject var store: MobileStore
  var position: Double
  var duration: Double
  var onSeek: (Double) -> Void

  private var progress: Double {
    guard duration > 0 else { return 0 }
    return min(1, max(0, position / duration))
  }

  var body: some View {
    VStack(spacing: 6) {
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color(hex: store.state.skin.colors.border))
            .frame(height: 3)
          Capsule()
            .fill(Color(hex: store.state.skin.colors.text))
            .frame(width: max(2, geo.size.width * progress), height: 3)
          Circle()
            .fill(Color(hex: store.state.skin.colors.text))
            .frame(width: progress > 0 ? 9 : 0, height: progress > 0 ? 9 : 0)
            .offset(x: max(0, geo.size.width * progress - 4.5))
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { value in
            guard duration > 0, geo.size.width > 0 else { return }
            let ratio = max(0, min(1, value.location.x / geo.size.width))
            onSeek(Double(ratio) * duration)
          })
      }
      .frame(height: 24)
      HStack {
        Text(clock(position))
        Spacer(minLength: 8)
        Text(clock(duration))
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(Color(hex: store.state.skin.colors.muted))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("播放进度")
    .accessibilityValue("\(clock(position))，共 \(clock(duration))")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: onSeek(min(duration, position + 10))
      case .decrement: onSeek(max(0, position - 10))
      @unknown default: break
      }
    }
  }
}

// MARK: - 传输

struct PlayerTransportDeck: View {
  @EnvironmentObject var store: MobileStore
  var playing: Bool
  var onPrevious: () -> Void
  var onToggle: () -> Void
  var onNext: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button(action: onPrevious) {
        Image(systemName: "backward.end.fill")
          .font(.title3.weight(.medium))
          .foregroundStyle(Color(hex: store.state.skin.colors.muted))
          .frame(width: 64, height: 64)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("上一首")
      Spacer(minLength: 0)
      Button(action: onToggle) {
        ZStack {
          Circle()
            .fill(Color(hex: store.state.skin.colors.text))
            .frame(width: 68, height: 68)
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
          Image(systemName: playing ? "pause.fill" : "play.fill")
            .font(.title.weight(.semibold))
            .foregroundStyle(Color(hex: store.state.skin.colors.bg))
            .offset(x: playing ? 0 : 2)
        }
      }
      .accessibilityLabel(playing ? "暂停" : "播放")
      Spacer(minLength: 0)
      Button(action: onNext) {
        Image(systemName: "forward.end.fill")
          .font(.title3.weight(.medium))
          .foregroundStyle(Color(hex: store.state.skin.colors.muted))
          .frame(width: 64, height: 64)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("下一首")
    }
  }
}
