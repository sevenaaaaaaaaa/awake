import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @Environment(\.scenePhase) private var scenePhase
  @State private var tab = 0
  var body: some View {
    TabView(selection: $tab) {
      NavigationStack { HomeView().playerInset() }.tabItem { Label("为你", systemImage: "waveform") }
        .tag(0)
      NavigationStack { LibraryView().playerInset() }.tabItem {
        Label("曲库", systemImage: "square.stack")
      }.tag(1)
      NavigationStack { SoundView().playerInset() }.tabItem {
        Label("声音", systemImage: "slider.horizontal.3")
      }.tag(2)
      NavigationStack { LabView().playerInset() }.tabItem {
        Label("评测", systemImage: "waveform.path.ecg")
      }.tag(3)
      NavigationStack { SettingsView().playerInset() }.tabItem {
        Label("设置", systemImage: "gearshape")
      }.tag(4)
    }
    .tint(Color(hex: store.state.skin.colors.accent))
    .preferredColorScheme(store.state.skin.mode == "light" ? .light : .dark)
    .alert(
      "Awake",
      isPresented: Binding(
        get: { !store.message.isEmpty || !player.error.isEmpty },
        set: {
          if !$0 {
            store.message = ""
            player.error = ""
          }
        })
    ) {
      Button("知道了") {
        store.message = ""
        player.error = ""
      }
    } message: {
      Text(store.message.isEmpty ? player.error : store.message)
    }
    .safeAreaInset(edge: .top) {
      if let source = store.state.sources.first(where: { $0.id == player.song?.sourceID && $0.kind == "telegram" }) {
        ScrollView { TelegramSponsoredView(source: source).padding(.horizontal) }.frame(maxHeight: 160)
      }
    }
    .overlay(alignment: .top) { EffectActivationOverlay() }
    .sensoryFeedback(.success, trigger: player.effectRevision)
    .onChange(of: player.route.uid) { _, _ in applyChain() }
    .onChange(of: store.pendingLibrarySource) { _, value in
      // 来源刚连上：直接把人送到曲库，列表已经筛到那个来源。
      if value != nil { tab = 1 }
    }
    .onChange(of: store.requestedTab) { _, value in
      guard let value else { return }
      tab = value
      store.requestedTab = nil
    }
    .onOpenURL { url in
      Task { await store.importFiles([url]) }
    }
    .task {
      #if DEBUG
        // 端到端自检通道（见 Diagnostics）；只有显式传环境变量时才动。
        Diagnostics.e2eConnectIfRequested(store)
        Diagnostics.e2ePlayIfRequested(store: store, player: player)
      #endif
      player.onListen = { song, seconds in
        store.recordListen(song, seconds: seconds)
        store.updateBookProgress(song: song, position: player.position, duration: player.duration)
      }
      player.onProgress = { song, position, duration in
        store.updateBookProgress(song: song, position: position, duration: duration)
      }
      player.artworkResolver = { song in store.artworkURL(song.artwork) }
      player.prepareSession()
      applyChain(announce: false)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active, let song = player.song {
        store.updateBookProgress(song: song, position: player.position, duration: player.duration)
      }
    }
  }
  private func applyChain(announce: Bool = true) {
    let c = store.activeChain(route: player.route.uid)
    player.useChain(c, announce: announce)
  }
}
extension View {
  func playerInset() -> some View { self.safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer() } }
  func appSurface() -> some View { self.modifier(AppSurface()) }
}
struct AppSurface: ViewModifier {
  @EnvironmentObject var store: MobileStore
  func body(content: Content) -> some View {
    content.scrollContentBackground(.hidden).background {
      if store.state.skin.mode == "glass" {
        LinearGradient(
          colors: [
            Color(hex: store.state.skin.colors.bg), Color(hex: store.state.skin.colors.raised),
          ], startPoint: .topLeading, endPoint: .bottomTrailing)
      } else {
        Color(hex: store.state.skin.colors.bg)
      }
    }
  }
}
struct Panel<Content: View>: View {
  @EnvironmentObject var store: MobileStore
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 14) { content }.frame(
      maxWidth: .infinity, alignment: .leading
    ).padding(20).background {
      if store.state.skin.mode == "glass" {
        RoundedRectangle(cornerRadius: store.state.skin.radius).fill(.ultraThinMaterial)
      } else {
        RoundedRectangle(cornerRadius: store.state.skin.radius).fill(
          Color(hex: store.state.skin.colors.surface))
      }
    }.overlay(
      RoundedRectangle(cornerRadius: store.state.skin.radius).stroke(
        Color(hex: store.state.skin.colors.border), lineWidth: 0.6))
  }
}
struct Cover: View {
  @EnvironmentObject var store: MobileStore
  var title: String
  var artwork: String? = nil
  var style = "auto"
  var size: CGFloat = 48
  @State private var image: UIImage?
  private var palette: [Color] {
    let hash = title.utf8.reduce(UInt32(2166136261)) { ($0 &* 16777619) ^ UInt32($1) }
    let choice = ["nocturne", "forest", "amber", "rose"].contains(style) ? style : ["nocturne", "forest", "amber", "rose"][Int(hash % 4)]
    switch choice {
    case "forest": return [Color(hex: "#809783"), Color(hex: "#385e53"), Color(hex: "#122a27")]
    case "amber": return [Color(hex: "#c4ac75"), Color(hex: "#896a44"), Color(hex: "#302c28")]
    case "rose": return [Color(hex: "#c69b95"), Color(hex: "#815c71"), Color(hex: "#302537")]
    default: return [Color(hex: "#8a9db9"), Color(hex: "#465775"), Color(hex: "#172132")]
    }
  }
  var body: some View {
    ZStack(alignment: .bottomLeading) {
      LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
      Circle().fill(RadialGradient(colors: [Color(hex: "#ffedd2").opacity(0.9), Color(hex: "#ebcba7").opacity(0.2), .clear], center: .center, startRadius: 0, endRadius: size * 0.2))
        .frame(width: size * 0.4, height: size * 0.4).position(x: size * 0.7, y: size * 0.32)
      Canvas { context, bounds in
        for i in 0..<9 {
          let inset = Double(i) * bounds.width * 0.055
          let rect = CGRect(x: -bounds.width * 0.3 - inset, y: bounds.height * 0.4 - inset * 0.2, width: bounds.width * 1.5 + inset * 2, height: bounds.height * 0.8 + inset)
          context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.08 + Double(i % 3) * 0.025)), lineWidth: max(0.5, bounds.width / 600))
        }
      }
      if size >= 150 {
        VStack(alignment: .leading, spacing: 8) {
          Text(String(title.prefix(32))).font(.system(size: size * 0.085, weight: .medium, design: .serif)).lineLimit(3)
          Text("PERSONAL SOUND ARCHIVE").font(.system(size: max(6, size * 0.024), weight: .medium)).tracking(1.5)
        }.foregroundStyle(.white.opacity(0.95)).padding(size * 0.09)
      }
      if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipped() }
    }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.075))
      .accessibilityHidden(true).task(id: artwork) {
        image = nil
        if let url = store.artworkURL(artwork) { image = UIImage(contentsOfFile: url.path) }
      }
  }
}
struct MiniPlayer: View {
  @EnvironmentObject var player: MobilePlayer
  @EnvironmentObject var store: MobileStore
  var body: some View {
    if let song = player.song {
      HStack(spacing: 12) {
        Button {
          store.playerSheetOpen = true
        } label: {
          HStack {
            Cover(title: song.title, artwork: song.artwork, style: song.mediaInfo?.cover_style ?? "auto", size: 40)
            VStack(alignment: .leading) {
              Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
              Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).accessibilityLabel("打开正在播放")
        MiniEnhancementLabel()
        Button {
          player.toggle()
        } label: {
          Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(
            width: 40, height: 44)
        }.accessibilityIdentifier("miniPlay").accessibilityLabel(player.playing ? "暂停" : "继续播放")
        Button {
          player.next()
        } label: {
          Image(systemName: "forward.end.fill").frame(width: 32, height: 44)
        }.accessibilityLabel("下一首")
      }.padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial).fullScreenCover(
        isPresented: Binding(
          get: { store.playerSheetOpen }, set: { store.playerSheetOpen = $0 })
      ) { NowPlayingView() }
    }
  }
}
struct NowPlayingView: View {
  @EnvironmentObject var player: MobilePlayer
  @EnvironmentObject var store: MobileStore
  @Environment(\.dismiss) var dismiss
  @State private var editingInfo = false
  @State private var swiping = false
  @State private var handingOff = false
  @State private var receiving = false
  @State private var showEnhancement = false
  @State private var gains = Array(repeating: Float(0), count: 31)
  var body: some View {
    if swiping {
      SwipePlayerView(onClose: { swiping = false })
        .environmentObject(store)
        .environmentObject(player)
    } else {
      nowPlaying
    }
  }
  private var nowPlaying: some View {
    NavigationStack {
      ZStack(alignment: .top) {
        Color(hex: store.state.skin.colors.bg).ignoresSafeArea()
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if let song = player.song {
            ChainStrip(steps: chainSteps(song))
            if activeChain != nil {
              EQCurvePanel(gains: $gains, editable: true, onCommit: commitGains)
                .padding(.top, 20)
              statusLine(song)
                .padding(.top, 8)
            } else {
              // 没有链路就不画一条空线：说明现状，并给出下一步。
              chainEmptyBlock
                .padding(.top, 20)
            }
            HStack(alignment: .top, spacing: 16) {
              PlayerPlate(title: song.title, artwork: song.artwork, size: 112)
              VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                  .font(.system(size: 20, weight: .medium))
                  .lineLimit(2)
                Text(song.artist)
                  .font(.system(size: 13, weight: .regular))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                if !song.album.isEmpty {
                  Text(song.album)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
                Text(metaLine(song))
                  .font(.system(size: 11, weight: .regular, design: .monospaced))
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
              }
              Spacer(minLength: 0)
            }
            .padding(.top, 24)
            scrubber
              .padding(.top, 24)
            transport
              .padding(.top, 20)
            tools(song)
              .padding(.top, 24)
            if let text = song.lyrics, !text.isEmpty {
              instrumentSection("歌词") { MediaLyricsView(text: text) }
                .padding(.top, 32)
            }
            siblingsSection(song)
            if let reviews = song.mediaInfo?.reviews, !reviews.isEmpty {
              instrumentSection("听众乐评") { reviewsBody(reviews) }
                .padding(.top, 24)
            }
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 32)
      }
        .safeAreaInset(edge: .top, spacing: 0) { playerHeader }
      }
      .toolbar(.hidden, for: .navigationBar)
      .presentationBackground(Color(hex: store.state.skin.colors.bg))
      .onAppear { syncGains() }
      .onChange(of: player.route.uid) { _, _ in syncGains() }
    }
    .sheet(isPresented: $editingInfo) { if let song = player.song { MediaInfoView(song: song) } }
    .sheet(isPresented: $handingOff) { HandoffSheet() }
    .sheet(isPresented: $receiving) {
      HandoffReceiveView()
        .environmentObject(store)
        .environmentObject(player)
    }
    .overlay(alignment: .top) { EffectActivationOverlay(priority: 1) }
  }

  // MARK: 顶部条

  /// 自绘顶部条：一个下拉箭头和一行小标题。系统 toolbar 的「完成」胶囊和仪器面板不搭。
  private var playerHeader: some View {
    HStack(spacing: 0) {
      Button {
        dismiss()
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("关闭正在播放")
      Spacer(minLength: 0)
      Text("正在播放")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      Color.clear.frame(width: 44, height: 44)
    }
    .padding(.horizontal, 4)
    .background(Color(hex: store.state.skin.colors.bg))
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color(hex: store.state.skin.colors.border).opacity(0.5)).frame(height: 0.5)
    }
  }

  // MARK: 仪器区

  private var activeChain: ListeningChain? {
    store.activeChain(route: player.route.uid)
  }

  /// 没有听感链路时的仪器区：不画空曲线，直接说清楚现在是什么状态、下一步去哪。
  private var chainEmptyBlock: some View {
    Button {
      store.playerSheetOpen = false
      store.requestedTab = 2
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Text("31 段曲线")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Text("平直")
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(hex: store.state.skin.colors.muted))
        }
        HStack(alignment: .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text("还没有听感链路")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(.primary)
            Text("当前输出按平直曲线播放。在「声音」里选耳机型号与链路后，这里会画出实际生效的 31 段曲线。")
              .font(.system(size: 12, weight: .regular))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .multilineTextAlignment(.leading)
          }
          Spacer(minLength: 0)
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color(hex: store.state.skin.colors.surface).opacity(0.5)))
        .overlay(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(Color(hex: store.state.skin.colors.border), lineWidth: 0.5))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("enhancementBadge")
    .accessibilityLabel("还没有听感链路，去声音里设置")
  }

  private func chainSteps(_ song: Song) -> [(label: String, value: String)] {
    let enhancement = player.enhancement
    let bands = enhancement.graphicBands + enhancement.correctionBands
    let eq: String
    if enhancement.enabled {
      eq = bands > 0 ? "\(bands) 段" : "已启用"
    } else {
      eq = enhancement.bypassed ? "旁路" : "平直"
    }
    return [
      ("音源", PlayerFormat.format(song.file ?? song.locator)),
      ("解码", PlayerFormat.hz(player.route.rate)),
      ("EQ", eq),
      ("输出", PlayerFormat.routeName(player.route.name, transport: player.route.transport)),
    ]
  }

  private func metaLine(_ song: Song) -> String {
    var parts: [String] = []
    if song.sampleRate >= 8000 { parts.append(PlayerFormat.hz(song.sampleRate)) }
    if let chain = activeChain, !chain.headphone.isEmpty { parts.append(chain.headphone) }
    return parts.isEmpty ? "—" : parts.joined(separator: " · ")
  }

  /// 音效状态：一行真实状态，点开是详情。原来的发光胶囊去掉了。
  private func statusLine(_ song: Song) -> some View {
    Button {
      if activeChain == nil {
        // 没有听感链路时，这一行最有用的动作是去「声音」把链路建起来。
        store.playerSheetOpen = false
        store.requestedTab = 2
      } else {
        showEnhancement = true
      }
    } label: {
      HStack(spacing: 6) {
        Circle()
          .fill(
            player.enhancement.enabled
              ? Color(hex: store.state.skin.colors.accent)
              : Color(hex: store.state.skin.colors.muted)
          )
          .frame(width: 5, height: 5)
        Text(enhancementLine)
          .font(.system(size: 12, weight: .regular, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        Spacer(minLength: 0)
        if activeChain == nil {
          Text("去设置")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(hex: store.state.skin.colors.accent))
        }
      }
      .frame(minHeight: 28)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("enhancementBadge")
    .accessibilityValue(player.enhancement.title(playing: player.playing))
    .sheet(isPresented: $showEnhancement) {
      EnhancementDetails().environmentObject(store).environmentObject(player)
    }
  }

  private var enhancementLine: String {
    let enhancement = player.enhancement
    if enhancement.bypassed { return "EQ 已旁路 · 原声直出" }
    if !enhancement.configured { return "平直曲线 · 未设置听感链路" }
    if !enhancement.enabled { return "原声 · \(enhancement.profile)" }
    let bands = enhancement.graphicBands + enhancement.correctionBands
    var parts = [enhancement.origin.title]
    if bands > 0 { parts.append("\(bands) 段") }
    if abs(enhancement.preamp) >= 0.05 { parts.append("前级 " + PlayerFormat.db(enhancement.preamp)) }
    return parts.joined(separator: " · ")
  }

  private var scrubber: some View {
    VStack(spacing: 6) {
      GeometryReader { geo in
        let progress = player.duration > 0
          ? min(1, max(0, player.position / player.duration)) : 0
        ZStack(alignment: .leading) {
          Capsule().fill(Color(hex: store.state.skin.colors.border)).frame(height: 2)
          Capsule()
            .fill(Color(hex: store.state.skin.colors.accent))
            .frame(width: max(1, geo.size.width * progress), height: 2)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { value in
            guard player.duration > 0, geo.size.width > 0 else { return }
            let ratio = max(0, min(1, value.location.x / geo.size.width))
            player.seek(Double(ratio) * player.duration)
          })
      }
      .frame(height: 20)
      HStack {
        Text(clock(player.position))
        Spacer()
        Text(clock(player.duration))
      }
      .font(.system(size: 11, weight: .regular, design: .monospaced))
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("播放进度")
  }

  private var transport: some View {
    HStack(spacing: 0) {
      Button {
        player.previous()
      } label: {
        Image(systemName: "backward.end.fill")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 56, height: 56)
      }
      .accessibilityLabel("上一首")
      Spacer(minLength: 0)
      Button {
        player.toggle()
      } label: {
        ZStack {
          Circle()
            .fill(Color(hex: store.state.skin.colors.text))
            .frame(width: 56, height: 56)
          Image(systemName: player.playing ? "pause.fill" : "play.fill")
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(Color(hex: store.state.skin.colors.bg))
            .offset(x: player.playing ? 0 : 1.5)
        }
      }
      .accessibilityLabel(player.playing ? "暂停" : "播放")
      Spacer(minLength: 0)
      Button {
        player.next()
      } label: {
        Image(systemName: "forward.end.fill")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 56, height: 56)
      }
      .accessibilityLabel("下一首")
    }
  }

  private func tools(_ song: Song) -> some View {
    HStack(spacing: 20) {
      Button {
        if let index = store.state.songs.firstIndex(where: { $0.id == song.id }) {
          store.state.songs[index].favorite.toggle()
          store.save()
        }
      } label: {
        Image(systemName: song.favorite ? "heart.fill" : "heart")
          .font(.system(size: 16, weight: .regular))
          .foregroundStyle(
            song.favorite ? Color(hex: store.state.skin.colors.accent) : .secondary)
          .frame(width: 32, height: 32)
      }
      .accessibilityLabel(song.favorite ? "取消收藏" : "收藏")
      Button {
        swiping = true
      } label: {
        Image(systemName: "shuffle")
          .font(.system(size: 16, weight: .regular))
          .foregroundStyle(.secondary)
          .frame(width: 32, height: 32)
      }
      .accessibilityLabel("刷音乐")
      .accessibilityIdentifier("swipeModeEntry")
      Spacer(minLength: 0)
      Menu {
        Button("接力到电脑", systemImage: "airplayaudio") { handingOff = true }
          .accessibilityIdentifier("handoffToMac")
        Button("接收接力", systemImage: "iphone.and.arrow.forward") { receiving = true }
          .accessibilityIdentifier("handoffFromMac")
        Divider()
        Button("整理封面、歌词与乐评", systemImage: "square.and.pencil") { editingInfo = true }
          .accessibilityIdentifier("editPlayingMedia")
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(.secondary)
          .frame(width: 32, height: 32)
      }
      .accessibilityLabel("更多")
    }
  }

  /// 同一张专辑里的其它曲目。没有歌词时下方不再是一片空白，而且这一块本来就是真的有用。
  private func siblingsSection(_ song: Song) -> some View {
    let others = store.state.songs
      .filter { $0.album == song.album && $0.id != song.id }
      .prefix(6)
    return Group {
      if !others.isEmpty, !song.album.isEmpty {
        instrumentSection("同专辑 · \(song.album)") {
          VStack(spacing: 0) {
            ForEach(Array(others)) { other in
              Button {
                Task { await playSong(other, store: store, player: player) }
              } label: {
                HStack(spacing: 12) {
                  Text(other.title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                  Spacer(minLength: 12)
                  Text(clock(other.duration))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              if other.id != others.last?.id {
                Rectangle().fill(Color(hex: store.state.skin.colors.border).opacity(0.6))
                  .frame(height: 0.5)
              }
            }
          }
        }
        .padding(.top, 32)
      }
    }
  }

  private func instrumentSection<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func reviewsBody(_ reviews: [MediaReview]) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(reviews.prefix(3)) { review in
        VStack(alignment: .leading, spacing: 4) {
          Text(
            (review.scope == "release_group"
              ? "专辑乐评" : review.scope == "recording" ? "单曲乐评" : "导入评论")
              + " · " + review.author
          )
          .font(.system(size: 11, weight: .regular, design: .monospaced))
          .foregroundStyle(.secondary)
          Text(review.text).font(.system(size: 14)).lineLimit(7)
          Text(review.source + " · " + review.license)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
          if let url = URL(string: review.url),
            ["https", "http"].contains(url.scheme ?? "")
          {
            Link("查看原文与署名", destination: url).font(.system(size: 12))
          }
        }
      }
      Button {
        editingInfo = true
      } label: {
        Text("查看全部与来源").font(.system(size: 12))
      }
      .accessibilityIdentifier("editPlayingMediaDetail")
    }
  }

  private func syncGains() {
    if let chain = activeChain, chain.gains.count == 31 {
      gains = chain.gains
    } else {
      gains = Array(repeating: Float(0), count: 31)
    }
  }

  private func commitGains(_ values: [Float]) {
    store.setChainGains(values, route: player.route.uid)
  }
}
func clock(_ seconds: Double) -> String {
  let s = Int(max(0, seconds.isFinite ? seconds : 0))
  return String(format: "%d:%02d", s / 60, s % 60)
}
struct RoutePicker: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let v = AVRoutePickerView()
    v.prioritizesVideoDevices = false
    return v
  }
  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
@MainActor func playSong(_ song: Song, store: MobileStore, player: MobilePlayer) async {
  store.busy = true
  defer { store.busy = false }
  do {
    var current = song
    if let source = store.state.sources.first(where: { $0.id == song.sourceID && $0.kind == "telegram" }) {
      _ = try await TelegramService.sponsored(source, secret: Secrets.get("source." + source.id))
    }
    if store.localURL(song) == nil {
      guard let source = store.state.sources.first(where: { $0.id == song.sourceID }) else {
        throw AppFailure("找不到文件，请重新导入或刷新来源")
      }
      current = try await SourceService.cache(
        song, source: source, secret: Secrets.get("source." + source.id), directory: store.music)
      if let i = store.state.songs.firstIndex(where: { $0.id == song.id }) {
        store.state.songs[i] = current
        store.save()
      }
    }
    let cached = store.recommendations().compactMap { s -> (Song, URL)? in
      guard let u = store.localURL(s) else { return nil }
      return (s, u)
    }
    guard let i = cached.firstIndex(where: { $0.0.id == current.id }) else {
      throw AppFailure("文件无法读取")
    }
    player.play(cached, at: i)
  } catch { store.message = error.localizedDescription }
}
struct HomeView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("YOUR LISTENING SPACE").font(.caption.monospaced()).tracking(2).foregroundStyle(
          .secondary)
        Text("好音乐，\n刚好懂你。").font(.system(size: 36, weight: .bold)).tracking(-1)
        Panel {
          HStack {
            VStack(alignment: .leading, spacing: 12) {
              Text("此刻，为你而鸣").font(.title2.bold())
              Text("从 \(store.state.songs.count) 首音乐与真实聆听记录中，找回自己的节奏。").font(.subheadline)
                .foregroundStyle(.secondary)
              Button("开始我的电台", systemImage: "play.fill") {
                if let s = store.recommendations().first {
                  Task { await playSong(s, store: store, player: player) }
                }
              }.buttonStyle(AwakeButtonStyle()).disabled(store.state.songs.isEmpty || store.busy)
            }
            Spacer()
            Image(systemName: "waveform.circle").font(.system(size: 70, weight: .ultraLight))
              .foregroundStyle(Color(hex: store.state.skin.colors.accent))
          }
        }
        HStack {
          NavigationLink {
            AgentView()
          } label: {
            Label("听歌搭子", systemImage: "sparkles").frame(maxWidth: .infinity).padding(.vertical, 12)
          }.buttonStyle(.bordered)
          NavigationLink {
            LabView()
          } label: {
            Label("听感反馈", systemImage: "heart.text.clipboard").frame(maxWidth: .infinity).padding(
              .vertical, 12)
          }.buttonStyle(.bordered)
        }
        HStack {
          NavigationLink {
            BooksHubView()
          } label: {
            Label("听书与播报", systemImage: "book.closed").frame(maxWidth: .infinity).padding(.vertical, 12)
          }.buttonStyle(.bordered)
          NavigationLink {
            WeeklySummaryView()
          } label: {
            Label("本周总结", systemImage: "chart.bar").frame(maxWidth: .infinity).padding(.vertical, 12)
          }.buttonStyle(.bordered)
        }
        Panel {
          HStack {
            VStack(alignment: .leading, spacing: 6) {
              Text("为你生成").font(.headline)
              Text("每天按最近聆听、完整播放与收藏重新排序。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
              if let first = store.recommendations().first {
                Task { await playSong(first, store: store, player: player) }
              }
            } label: {
              Label("播放", systemImage: "play.fill")
            }.buttonStyle(.bordered).disabled(store.state.songs.isEmpty)
          }
        }
        Text("下一次心动").font(.title3.bold())
        if store.state.songs.isEmpty {
          ContentUnavailableView(
            "从你的音乐开始", systemImage: "music.note",
            description: Text("在曲库导入文件，或在设置连接自己的 NAS、WebDAV 和 Plex。"))
        }
        ForEach(Array(store.recommendations().prefix(12))) { SongRow(song: $0) }
        if !store.state.ratings.isEmpty {
          Panel {
            Label("越听，越合拍", systemImage: "waveform.path.ecg").font(.headline)
            Text(
              store.localAdvice(chainID: store.activeChain(route: player.route.uid)?.id).first ?? ""
            ).font(.subheadline).foregroundStyle(.secondary)
          }
        }
      }.padding(20)
    }.appSurface().navigationTitle("awake.").toolbar { if store.busy { ProgressView() } }
  }
}
struct SongRow: View {
  let song: Song
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @State private var editingInfo = false
  var body: some View {
    HStack(spacing: 12) {
      Button {
        Task { await playSong(song, store: store, player: player) }
      } label: {
        HStack(spacing: 12) {
          Cover(title: song.title, artwork: song.artwork, style: song.mediaInfo?.cover_style ?? "auto")
          VStack(alignment: .leading, spacing: 5) {
            Text(song.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(
              1)
            Text(song.artist + (store.localURL(song) == nil ? " · 播放前缓存" : "")).font(.caption)
              .foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          if player.song?.id == song.id {
            Image(systemName: "waveform")
          } else {
            Text(clock(song.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
      }.buttonStyle(.plain).disabled(store.busy).accessibilityIdentifier("song-" + song.id)
      Button {
        if let i = store.state.songs.firstIndex(where: { $0.id == song.id }) {
          store.state.songs[i].favorite.toggle()
          store.save()
        }
      } label: {
        Image(systemName: song.favorite ? "heart.fill" : "heart").frame(width: 40, height: 44)
      }.accessibilityLabel(song.favorite ? "取消收藏" : "收藏")
    }.padding(.vertical, 5).sheet(isPresented: $editingInfo) { MediaInfoView(song: store.state.songs.first { $0.id == song.id } ?? song) }.contextMenu {
      Button("整理封面、歌词与乐评", systemImage: "info.circle") { editingInfo = true }
      if let origin = song.origin, let url = URL(string: origin), url.scheme == "https", url.host == "t.me" {
        Link("查看原始 Telegram 消息", destination: url)
      }
    }
  }
}
struct LibraryView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @State private var picking: ImportTarget?
  @State private var importingPlaylist = false
  @State private var query = ""
  /// 只看某一个来源；nil 表示全部来源。
  @State private var sourceFilter: String?
  var filtered: [Song] {
    store.state.songs.filter { song in
      guard sourceFilter == nil || song.sourceID == sourceFilter else { return false }
      return query.isEmpty
        || (song.title + song.artist + song.album).localizedCaseInsensitiveContains(query)
    }
  }
  /// 当前筛选来源的曲目数，用来在筛选条上直接回答「我加的那个来源进来了几首」。
  private func count(in source: MusicSource) -> Int {
    store.state.songs.filter { $0.sourceID == source.id }.count
  }
  var body: some View {
    List {
      if store.busy {
        HStack {
          ProgressView()
          Text("正在导入或缓存音频…")
        }
      }
      if !store.state.sources.isEmpty {
        Section {
          Picker(
            "来源",
            selection: Binding(
              get: { sourceFilter ?? "" },
              set: { sourceFilter = $0.isEmpty ? nil : $0 }
            )
          ) {
            Text("全部来源 · \(store.state.songs.count) 首").tag("")
            ForEach(store.state.sources) { source in
              Text("\(source.name) · \(count(in: source)) 首").tag(source.id)
            }
          }
          .pickerStyle(.menu)
          .accessibilityIdentifier("librarySourceFilter")
        }
      }
      if filtered.isEmpty {
        ContentUnavailableView(
          "把音乐带进来", systemImage: "square.and.arrow.down",
          description: Text(
            sourceFilter == nil
              ? "支持文件 App 中的本地、iCloud Drive 和已连接的网盘文件。"
              : "这个来源里还没有曲目。到设置里刷新来源，或把来源切回「全部来源」。"))
      }
      Section("推荐歌单") {
        Button {
          Task {
            guard let first = store.recommendations().first else {
              store.message = "曲库里还没有可播放的音乐。"
              return
            }
            await playSong(first, store: store, player: player)
          }
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text("为你生成").font(.subheadline.weight(.semibold))
              Text("动态 · 每天按聆听与收藏重排").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "sparkles").foregroundStyle(Color(hex: store.state.skin.colors.accent))
            Image(systemName: "play.circle").font(.title3)
          }
        }.buttonStyle(.plain).accessibilityIdentifier("forYouPlaylist")
      }
      if !(store.state.playlists ?? []).isEmpty {
        Section("歌单") {
          ForEach(store.state.playlists ?? []) { list in
            NavigationLink {
              PlaylistDetailView(playlistID: list.id)
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(list.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                  Text(
                    "\(list.songIDs.count) 首"
                      + ((list.pending?.isEmpty ?? true)
                        ? " · \(list.note.isEmpty ? "本地歌单" : list.note)"
                        : " · \(list.pending?.count ?? 0) 首待匹配")
                  ).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
              }
            }.buttonStyle(.plain)
              .accessibilityIdentifier("playlist-\(list.id)")
              .contextMenu {
                Button("删除歌单", role: .destructive) {
                  store.state.playlists = (store.state.playlists ?? []).filter { $0.id != list.id }
                  store.save()
                }
              }
          }
        }
      }
      ForEach(filtered) { SongRow(song: $0).listRowBackground(Color.clear) }
    }
    .importPicker($picking) { urls, target in
      switch target {
      case .audioFiles: Task { await store.importFiles(urls) }
      case .audioFolder: Task { for url in urls { await store.importAudioFolder(url) } }
      case .skin, .backup: break  // 曲库页没有这两个入口
      }
    } onFail: { error, _ in
      if (error as NSError).code != NSUserCancelledError { store.message = error.localizedDescription }
    }
    .appSurface().navigationTitle("音乐资料库").searchable(text: $query, prompt: "曲名、艺人或专辑").toolbar {
      NavigationLink {
        BooksHubView()
      } label: {
        Label("听书", systemImage: "book.closed")
      }.accessibilityIdentifier("openBooksHub")
      Button("导入歌单", systemImage: "music.note.list") { importingPlaylist = true }
        .accessibilityIdentifier("importPlaylist")
      Button("导入文件夹", systemImage: "folder.badge.plus") { picking = .audioFolder }
        .accessibilityIdentifier("importLibraryFolder")
      Button("导入文件", systemImage: "plus") { picking = .audioFiles }
        .accessibilityIdentifier("importMusic")
    }.sheet(isPresented: $importingPlaylist) {
      PlaylistImportView().environmentObject(store).environmentObject(player)
    }.onAppear {
      adoptPendingSource()
    }.onChange(of: store.pendingLibrarySource) { _, _ in
      adoptPendingSource()
    }
  }

  /// 刚连上来源时，把列表筛到这个来源 —— 与桌面端 connect → focusSource 的行为对齐。
  private func adoptPendingSource() {
    guard let id = store.pendingLibrarySource else { return }
    sourceFilter = id
    store.pendingLibrarySource = nil
  }
  private func playPlaylist(_ list: Playlist) async {
    let byID = Dictionary(uniqueKeysWithValues: store.state.songs.map { ($0.id, $0) })
    let playable = list.songIDs.compactMap { byID[$0] }.compactMap { song -> (Song, URL)? in
      guard let url = store.localURL(song) else { return nil }
      return (song, url)
    }
    guard !playable.isEmpty else {
      store.message = "这个歌单里的曲目还不在本机。请先播放或导入对应音频。"
      return
    }
    player.play(playable, at: 0)
  }
}

struct PlaylistDetailView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  let playlistID: String

  private var playlist: Playlist? {
    (store.state.playlists ?? []).first { $0.id == playlistID }
  }
  private var songs: [Song] {
    guard let playlist else { return [] }
    let byID = Dictionary(uniqueKeysWithValues: store.state.songs.map { ($0.id, $0) })
    return playlist.songIDs.compactMap { byID[$0] }
  }

  var body: some View {
    List {
      if let playlist {
        Section {
          Text(playlist.note.isEmpty ? "本地歌单" : playlist.note)
            .font(.caption).foregroundStyle(.secondary)
          Text(
            "\(songs.count) 首可播放"
              + ((playlist.pending?.isEmpty ?? true)
                ? "" : " · \(playlist.pending?.count ?? 0) 首待匹配"))
            .font(.caption2).foregroundStyle(.secondary)
          Button {
            play()
          } label: {
            Label("播放歌单", systemImage: "play.fill")
          }.disabled(songs.isEmpty)
        }
        Section("曲目") {
          if songs.isEmpty {
            Text("还没有可播放的曲目").foregroundStyle(.secondary)
          }
          ForEach(songs) { SongRow(song: $0) }
        }
        if let pending = playlist.pending, !pending.isEmpty {
          Section("待匹配曲目") {
            ForEach(pending) { item in
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(item.title).font(.subheadline.weight(.medium))
                  Text(
                    [item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " · ")
                  ).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("未匹配").font(.caption2).foregroundStyle(.orange)
              }
            }
            Button("重新匹配曲库", systemImage: "arrow.clockwise") {
              if rematch(save: true) {
                store.message = "已重新匹配待处理曲目"
              } else {
                store.message = "曲库里还没有这些曲目；导入对应文件后再试。"
              }
            }
          }
        }
      } else {
        Text("歌单已删除").foregroundStyle(.secondary)
      }
    }
    .appSurface()
    .navigationTitle(playlist?.name ?? "歌单")
    .onAppear { _ = rematch(save: true) }
  }

  private func play() {
    guard let playlist else { return }
    let byID = Dictionary(uniqueKeysWithValues: store.state.songs.map { ($0.id, $0) })
    let queue = playlist.songIDs.compactMap { byID[$0] }.compactMap { song -> (Song, URL)? in
      guard let url = store.localURL(song) else { return nil }
      return (song, url)
    }
    guard !queue.isEmpty else {
      store.message = "这个歌单的曲目还不在本机。请先播放或导入对应音频。"
      return
    }
    player.play(queue, at: 0)
  }

  private func normalize(_ text: String) -> String {
    text.lowercased().filter { !$0.isWhitespace }
  }

  @discardableResult
  private func rematch(save: Bool) -> Bool {
    guard var list = playlist, let pending = list.pending, !pending.isEmpty else {
      return false
    }
    var changed = false
    var remaining: [PendingTrack] = []
    for item in pending {
      let title = normalize(item.title)
      let artist = normalize(item.artist)
      let exact = store.state.songs.first {
        normalize($0.title) == title && normalize($0.artist) == artist
      }
      let titleMatches = store.state.songs.filter { normalize($0.title) == title }
      let found = exact ?? (titleMatches.count == 1 ? titleMatches[0] : nil)
      if let found {
        if !list.songIDs.contains(found.id) { list.songIDs.append(found.id) }
        changed = true
      } else {
        remaining.append(item)
      }
    }
    guard changed else { return false }
    list.pending = remaining.isEmpty ? nil : remaining
    if let index = (store.state.playlists ?? []).firstIndex(where: { $0.id == list.id }) {
      store.state.playlists?[index] = list
      if save { store.save() }
    }
    return true
  }
}

struct AwakeButtonStyle: ButtonStyle {
  @EnvironmentObject var store: MobileStore
  @Environment(\.isEnabled) var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(
      Color(hex: store.state.skin.colors.onAccent)
    ).padding(.horizontal, 18).padding(.vertical, 12).background(
      Color(hex: store.state.skin.colors.accent), in: Capsule()
    ).opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
  }
}

/// 接力到电脑：发现设备、输入配对码、发送一次请求。
/// 配对码只存在于内存，发送成功后立即清空，不写入档案或钥匙串。
struct HandoffSheet: View {
  @EnvironmentObject var player: MobilePlayer
  @EnvironmentObject var store: MobileStore
  @Environment(\.dismiss) private var dismiss
  @StateObject private var browser = HandoffBrowser()
  @State private var code = ""
  @State private var selected: HandoffDevice?
  @State private var manualAddress = ""
  @State private var manualEndpoint: HandoffEndpoint?
  @State private var manualNote = ""
  @State private var status = ""
  @State private var failed = false
  @State private var sending = false

  private var target: HandoffEndpoint? { manualEndpoint ?? selected?.endpoint }

  var body: some View {
    NavigationStack {
      Form {
        if let song = player.song {
          Section("当前曲目") {
            VStack(alignment: .leading, spacing: 3) {
              Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(2)
              Text(song.artist + (song.album.isEmpty ? "" : " · " + song.album))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
        }
        Section {
          if browser.devices.isEmpty {
            HStack(spacing: 8) {
              if browser.searching { ProgressView().controlSize(.small) }
              Text(
                browser.searching
                  ? "正在搜索附近的电脑…"
                  : (browser.note.isEmpty ? "没有找到电脑。请在电脑上点「接收接力」后重试。" : browser.note)
              ).font(.subheadline).foregroundStyle(.secondary)
            }
          } else {
            ForEach(browser.devices) { device in
              Button {
                selected = device
                manualEndpoint = nil
                manualNote = ""
                failed = false
                status = ""
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.subheadline.weight(.semibold))
                      .foregroundStyle(.primary).lineLimit(1)
                    Text(device.displayAddress).font(.caption.monospaced())
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  if manualEndpoint == nil, selected?.id == device.id {
                    Image(systemName: "checkmark.circle.fill")
                      .foregroundStyle(Color(hex: store.state.skin.colors.accent))
                  }
                }
              }.buttonStyle(.plain).accessibilityIdentifier("handoffDevice-" + device.id)
            }
          }
        } header: {
          HStack {
            Text("附近的电脑")
            Spacer()
            if browser.searching { ProgressView().controlSize(.mini) }
          }
        }
        Section("配对码") {
          TextField("电脑上显示的 6 位数字", text: $code)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .accessibilityIdentifier("handoffCode")
            .onChange(of: code) { _, value in
              let digits = HandoffRequest.sanitizedCode(value)
              if digits != value { code = digits }
            }
        }
        Section("手动输入地址") {
          TextField("例如 192.168.1.8:8737", text: $manualAddress)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("handoffManualAddress")
          Button("使用这个地址") { useManualAddress() }
            .accessibilityIdentifier("handoffUseManualAddress")
          if !manualNote.isEmpty {
            Text(manualNote).font(.caption).foregroundStyle(.secondary)
          }
        }
        Section {
          Button {
            send()
          } label: {
            HStack(spacing: 8) {
              if sending { ProgressView().controlSize(.small) }
              Text(sending ? "正在发送…" : "发送")
            }.frame(maxWidth: .infinity)
          }
          .disabled(sending || target == nil || code.count != 6 || player.song == nil)
          .accessibilityIdentifier("handoffSend")
          if !status.isEmpty {
            Text(status).font(.subheadline).foregroundStyle(failed ? .red : .green)
              .accessibilityIdentifier("handoffStatus")
          }
        } footer: {
          Text("只把曲名、艺人、专辑、时长与进度发给电脑，不发音频、账号或 token；只连局域网，配对码不保存在手机上。")
            .font(.caption2)
        }
      }
      .navigationTitle("接力到电脑")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("完成") { dismiss() } }
      .onAppear { browser.start() }
      .onDisappear { browser.stop() }
      .onChange(of: browser.devices) { _, devices in
        if selected == nil { selected = devices.first }
      }
    }
  }

  private func useManualAddress() {
    guard let endpoint = HandoffEndpoint.parse(manualAddress) else {
      manualEndpoint = nil
      manualNote = "格式应为 主机:端口，例如 192.168.1.8:8737"
      return
    }
    guard endpoint.isLocalNetworkHost else {
      manualEndpoint = nil
      manualNote = "只支持局域网地址：192.168.x.x、10.x、172.16–31.x 或 电脑名.local"
      return
    }
    manualEndpoint = endpoint
    manualNote = "当前目标：" + endpoint.displayAddress
    failed = false
    status = ""
  }

  @MainActor private func send() {
    guard let song = player.song, let endpoint = target else { return }
    let position = player.position
    let playing = player.playing
    let pairing = code
    sending = true
    failed = false
    status = "正在发送…"
    Task {
      let reply = await HandoffSender().send(
        code: pairing, song: song, position: position, playing: playing, to: endpoint)
      sending = false
      failed = !reply.succeeded
      status = reply.text
      // 配对码只在一次请求里用，成功后立刻清空。
      if reply.succeeded { code = "" }
    }
  }
}
