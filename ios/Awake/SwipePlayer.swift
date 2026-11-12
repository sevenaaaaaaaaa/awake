import SwiftUI

/// 「刷音乐」播放界面：只从正在播放页进入，提供上下滑动与左右抽卡两种换歌方式。
struct SwipePlayerView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  /// 由正在播放页以内容切换方式打开时使用；为 nil 时退回 dismiss。
  var onClose: (() -> Void)? = nil
  @Environment(\.dismiss) private var dismiss
  @Environment(\.awakeReducedMotion) private var reduceMotion
  @State private var deck: [Song] = []
  @State private var index = 0
  @State private var mode = SwipeMode.vertical
  @State private var drag: CGSize = .zero
  @State private var loading = false
  @State private var toast = ""

  enum SwipeMode: String, CaseIterable { case vertical, cards }

  private var current: Song? { deck.indices.contains(index) ? deck[index] : player.song }
  private var next: Song? { deck.indices.contains(index + 1) ? deck[index + 1] : nil }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(hex: store.state.skin.colors.bg), Color(hex: store.state.skin.colors.surface)],
        startPoint: .top, endPoint: .bottom
      ).ignoresSafeArea()
      if deck.isEmpty {
        ContentUnavailableView(
          "还没有可刷的音乐", systemImage: "rectangle.stack.badge.play",
          description: Text("先导入本地音频或添加来源，再回到正在播放页进入刷音乐。"))
      } else if mode == .vertical {
        verticalPager
      } else {
        cardStack
      }
      VStack {
        topBar
        Spacer()
        bottomBar
      }.padding(.horizontal, 20).padding(.vertical, 14)
      if !toast.isEmpty {
        Text(toast)
          .font(.caption.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
          .background(.ultraThinMaterial, in: Capsule())
          .padding(.bottom, 96)
          .frame(maxHeight: .infinity, alignment: .bottom)
          .transition(.opacity)
          .accessibilityIdentifier("swipeToast")
      }
    }
    .task { await prepare() }
    .onChange(of: player.song?.id) { _, id in
      guard let id, let i = deck.firstIndex(where: { $0.id == id }) else { return }
      index = i
    }
  }

  private var topBar: some View {
    HStack(spacing: 12) {
      Button {
        if let onClose { onClose() } else { dismiss() }
      } label: {
        Image(systemName: "xmark").font(.subheadline.weight(.semibold))
          .frame(width: 36, height: 36)
          .background(.ultraThinMaterial, in: Circle())
      }.accessibilityLabel("关闭刷音乐").accessibilityIdentifier("closeSwipe")
      Spacer()
      Picker("模式", selection: $mode) {
        Label("上下", systemImage: "arrow.up.arrow.down").tag(SwipeMode.vertical)
        Label("卡片", systemImage: "rectangle.stack").tag(SwipeMode.cards)
      }
      .pickerStyle(.segmented)
      .frame(width: 176)
      .accessibilityIdentifier("swipeMode")
      .onChange(of: mode) { _, value in
        announce(value == .vertical ? "上下滑动换歌" : "左右滑动抽卡")
      }
      Spacer()
      Text("\(min(index + 1, deck.count)) / \(deck.count)")
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        .frame(width: 36)
    }
  }

  private var bottomBar: some View {
    VStack(spacing: 12) {
      if let song = current {
        HStack(spacing: 18) {
          Button {
            toggleFavorite(song)
          } label: {
            Image(systemName: isFavorite(song) ? "heart.fill" : "heart")
              .font(.title3)
              .foregroundStyle(isFavorite(song) ? Color(hex: store.state.skin.colors.accent) : .secondary)
          }.accessibilityLabel("收藏").accessibilityIdentifier("swipeFavorite")
          Button { player.toggle() } label: {
            Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill")
              .font(.system(size: 56))
          }.accessibilityLabel(player.playing ? "暂停" : "播放")
          Button {
            Task { await advance(1) }
          } label: {
            Image(systemName: "forward.end.fill").font(.title3)
          }.accessibilityLabel("下一首").accessibilityIdentifier("swipeNext")
        }
        ProgressView(value: min(1, max(0, player.position / max(1, player.duration))))
          .tint(Color(hex: store.state.skin.colors.accent))
        HStack {
          Text(clock(player.position))
          Spacer()
          Text(clock(player.duration))
        }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        Text(mode == .vertical ? "上滑下一首 · 下滑上一首 · 轻点暂停" : "右滑喜欢 · 左滑跳过 · 上滑下一首")
          .font(.caption2).foregroundStyle(.secondary)
      }
      if loading { ProgressView().controlSize(.small) }
    }
  }

  private var verticalPager: some View {
    GeometryReader { proxy in
      ZStack {
        if let next {
          page(next, size: proxy.size, dimmed: true)
            .offset(y: proxy.size.height + drag.height)
        }
        if let current {
          page(current, size: proxy.size, dimmed: false)
            .offset(y: drag.height)
            .gesture(
              DragGesture(minimumDistance: 18)
                .onChanged { if !loading { drag = $0.translation } }
                .onEnded { value in
                  let dy = value.translation.height
                  if abs(dy) > 90 {
                    Task { await advance(dy < 0 ? 1 : -1) }
                  } else {
                    withAnimation(animation) { drag = .zero }
                  }
                })
        }
      }
      .clipped()
    }
    .padding(.vertical, 60)
  }

  private func page(_ song: Song, size: CGSize, dimmed: Bool) -> some View {
    let side = min(size.width, size.height * 0.62)
    return VStack(spacing: 18) {
      Cover(
        title: song.title, artwork: song.artwork, style: song.mediaInfo?.cover_style ?? "auto",
        size: side
      )
      .frame(width: side, height: side)
      .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
      .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
      VStack(spacing: 6) {
        Text(song.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
          .lineLimit(2)
        Text(song.artist.isEmpty ? "未知艺人" : song.artist)
          .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
      }
      if let lyrics = song.lyrics, !lyrics.isEmpty, !dimmed {
        Text(lyrics.split(separator: "\n").prefix(2).joined(separator: " · "))
          .font(.caption).foregroundStyle(.secondary).lineLimit(2)
          .multilineTextAlignment(.center).padding(.horizontal, 24)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .opacity(dimmed ? 0.35 : 1)
    .scaleEffect(dimmed ? 0.94 : 1)
  }

  private var cardStack: some View {
    GeometryReader { proxy in
      ZStack {
        if let next {
          card(next, size: proxy.size).scaleEffect(0.93).offset(y: 18).opacity(0.5)
        }
        if let current {
          card(current, size: proxy.size)
            .offset(x: drag.width, y: drag.height * 0.2)
            .rotationEffect(.degrees(Double(drag.width / proxy.size.width) * 8))
            .gesture(
              DragGesture(minimumDistance: 12)
                .onChanged { if !loading { drag = $0.translation } }
                .onEnded { value in
                  let dx = value.translation.width
                  let dy = value.translation.height
                  if abs(dx) > abs(dy), abs(dx) > 90 {
                    let liked = dx > 0
                    Task { await swipe(liked: liked ? true : nil, dy: 0) }
                  } else if dy < -90 {
                    Task { await advance(1) }
                  } else if dy > 90 {
                    Task { await advance(-1) }
                  } else {
                    withAnimation(animation) { drag = .zero }
                  }
                })
            .overlay(alignment: .topLeading) {
              if drag.width > 40 { stamp("喜欢", color: Color(hex: "#8fd9a8")) }
            }
            .overlay(alignment: .topTrailing) {
              if drag.width < -40 { stamp("跳过", color: Color(hex: "#e39a9a")) }
            }
        }
      }
    }
    .padding(.vertical, 54)
  }

  private func card(_ song: Song, size: CGSize) -> some View {
    let side = min(size.width - 24, size.height * 0.58)
    return VStack(spacing: 14) {
      Cover(
        title: song.title, artwork: song.artwork, style: song.mediaInfo?.cover_style ?? "auto",
        size: side
      )
      .frame(width: side, height: side)
      .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
      Text(song.title).font(.headline).lineLimit(1).padding(.horizontal, 18)
      Text(song.artist.isEmpty ? "未知艺人" : song.artist)
        .font(.caption).foregroundStyle(.secondary)
      Text(song.album.isEmpty ? "本地曲库" : song.album)
        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .fill(Color(hex: store.state.skin.colors.raised).opacity(0.9))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
    )
    .padding(.horizontal, 24)
    .accessibilityIdentifier("swipeCard")
  }

  private func stamp(_ text: String, color: Color) -> some View {
    Text(text).font(.title3.bold()).foregroundStyle(color)
      .padding(.horizontal, 14).padding(.vertical, 6)
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 2))
      .rotationEffect(.degrees(-10)).padding(28)
  }

  private var animation: Animation? {
    reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)
  }

  private func announce(_ text: String) {
    withAnimation(.easeOut(duration: 0.2)) { toast = text }
    Task {
      try? await Task.sleep(nanoseconds: 1_400_000_000)
      withAnimation(.easeIn(duration: 0.2)) { toast = "" }
    }
  }

  private func advance(_ step: Int) async {
    let target = index + step
    guard deck.indices.contains(target), !loading else {
      withAnimation(animation) { drag = .zero }
      return
    }
    await move(to: target, exit: CGSize(width: 0, height: step > 0 ? -700 : 700))
  }

  private func swipe(liked: Bool?, dy: CGFloat) async {
    if liked == true, let song = current { setFavorite(song, true); announce("已收藏") }
    if liked == false { announce("已跳过") }
    await move(to: index + 1, exit: CGSize(width: liked == false ? -700 : 700, height: 0))
  }

  private func move(to target: Int, exit: CGSize) async {
    guard deck.indices.contains(target) else {
      withAnimation(animation) { drag = .zero }
      return
    }
    loading = true
    let song = deck[target]
    withAnimation(animation) { drag = CGSize(width: exit.width, height: exit.height) }
    try? await Task.sleep(nanoseconds: 180_000_000)
    index = target
    drag = .zero
    await play(song)
    loading = false
  }

  private func prepare() async {
    var list = store.recommendations()
    if let song = player.song {
      if let i = list.firstIndex(where: { $0.id == song.id }) {
        list = [list[i]] + list[0..<i] + list[(i + 1)...]
      } else {
        list.insert(song, at: 0)
      }
    }
    deck = list
    if let id = player.song?.id, let i = deck.firstIndex(where: { $0.id == id }) { index = i }
  }

  private func play(_ song: Song) async {
    var target = song
    do {
      if store.localURL(target) == nil {
        guard let source = store.state.sources.first(where: { $0.id == target.sourceID }) else {
          throw AppFailure("找不到这个曲目的来源")
        }
        target = try await SourceService.cache(
          target, source: source, secret: Secrets.get("source." + source.id),
          directory: store.music)
        if let i = store.state.songs.firstIndex(where: { $0.id == target.id }) {
          store.state.songs[i] = target
          store.save()
        }
      }
      let playable = deck.compactMap { item -> (Song, URL)? in
        guard let url = store.localURL(item) else { return nil }
        return (item, url)
      }
      guard let i = playable.firstIndex(where: { $0.0.id == target.id }) else {
        throw AppFailure("文件无法读取")
      }
      player.play(playable, at: i)
    } catch { store.message = error.localizedDescription }
  }

  private func isFavorite(_ song: Song) -> Bool {
    store.state.songs.first(where: { $0.id == song.id })?.favorite ?? song.favorite
  }

  private func toggleFavorite(_ song: Song) {
    setFavorite(song, !isFavorite(song))
    announce(isFavorite(song) ? "已收藏" : "已取消收藏")
  }

  private func setFavorite(_ song: Song, _ value: Bool) {
    guard let i = store.state.songs.firstIndex(where: { $0.id == song.id }) else { return }
    store.state.songs[i].favorite = value
    store.save()
    if deck.indices.contains(index), deck[index].id == song.id { deck[index].favorite = value }
  }
}
