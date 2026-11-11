import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
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
    .overlay(alignment: .top) { EffectActivationOverlay() }
    .sensoryFeedback(.success, trigger: player.effectRevision)
    .onChange(of: player.route.uid) { _, _ in applyChain() }
    .task {
      player.onListen = { song, seconds in store.recordListen(song, seconds: seconds) }
      applyChain(announce: false)
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
  var title: String
  var size: CGFloat = 48
  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color.indigo.opacity(0.55), Color.cyan.opacity(0.22)], startPoint: .topLeading,
        endPoint: .bottomTrailing)
      Image(systemName: "waveform").font(.system(size: size * 0.38, weight: .light))
        .foregroundStyle(.white)
    }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.18))
      .accessibilityHidden(true)
  }
}
struct MiniPlayer: View {
  @EnvironmentObject var player: MobilePlayer
  @State private var expanded = false
  var body: some View {
    if let song = player.song {
      HStack(spacing: 12) {
        Button {
          expanded = true
        } label: {
          HStack {
            Cover(title: song.title, size: 40)
            VStack(alignment: .leading) {
              Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
              Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).accessibilityLabel("打开正在播放")
        EnhancementBadge(compact: true)
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
      }.padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial).sheet(
        isPresented: $expanded
      ) { NowPlayingView() }
    }
  }
}
struct NowPlayingView: View {
  @EnvironmentObject var player: MobilePlayer
  @EnvironmentObject var store: MobileStore
  @Environment(\.dismiss) var dismiss
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 28) {
          if let song = player.song {
            Cover(title: song.title, size: 240).padding(.top, 30)
            VStack(spacing: 8) {
              Text(song.title).font(.title2.bold()).multilineTextAlignment(.center)
              Text(song.artist).foregroundStyle(.secondary)
            }
            EnhancementBadge()
            Slider(
              value: Binding(get: { player.position }, set: { player.seek($0) }),
              in: 0...max(1, player.duration)
            ).accessibilityLabel("播放进度")
            HStack {
              Text(clock(player.position))
              Spacer()
              Text(clock(player.duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 38) {
              Button {
                player.previous()
              } label: {
                Image(systemName: "backward.end.fill")
              }
              Button {
                player.toggle()
              } label: {
                Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(
                  .system(size: 64))
              }
              Button {
                player.next()
              } label: {
                Image(systemName: "forward.end.fill")
              }
            }.font(.title2)
            HStack {
              Text(player.route.name).font(.caption)
              Spacer()
              RoutePicker().frame(width: 40, height: 40)
            }
            Text("PCM \(Int(player.route.rate)) Hz · 无线编码由系统协商").font(.caption).foregroundStyle(
              .secondary)
          }
        }.padding(24)
      }.appSurface().navigationTitle("正在播放").navigationBarTitleDisplayMode(.inline).toolbar {
        Button("完成") { dismiss() }
      }
    }.overlay(alignment: .top) { EffectActivationOverlay(priority: 1) }
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
  var body: some View {
    HStack(spacing: 12) {
      Button {
        Task { await playSong(song, store: store, player: player) }
      } label: {
        HStack(spacing: 12) {
          Cover(title: song.title)
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
    }.padding(.vertical, 5)
  }
}
struct LibraryView: View {
  @EnvironmentObject var store: MobileStore
  @State private var importing = false
  @State private var query = ""
  var filtered: [Song] {
    store.state.songs.filter {
      query.isEmpty || ($0.title + $0.artist + $0.album).localizedCaseInsensitiveContains(query)
    }
  }
  var body: some View {
    List {
      if store.busy {
        HStack {
          ProgressView()
          Text("正在导入或缓存音频…")
        }
      }
      if filtered.isEmpty {
        ContentUnavailableView(
          "把音乐带进来", systemImage: "square.and.arrow.down",
          description: Text("支持文件 App 中的本地、iCloud Drive 和已连接的网盘文件。"))
      }
      ForEach(filtered) { SongRow(song: $0).listRowBackground(Color.clear) }
    }.appSurface().navigationTitle("音乐资料库").searchable(text: $query, prompt: "曲名、艺人或专辑").toolbar {
      Button("导入", systemImage: "plus") { importing = true }.accessibilityIdentifier("importMusic")
    }.fileImporter(
      isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls): Task { await store.importFiles(urls) }
      case .failure(let e): store.message = e.localizedDescription
      }
    }
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
