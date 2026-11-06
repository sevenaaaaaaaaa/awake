import SwiftUI
import AppKit
import AwakeCore

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            background

            HStack(spacing: 0) {
                SidebarView()
                Rectangle()
                    .fill(AwakeTheme.hairline)
                    .frame(width: 1)
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.bottom, 92)

            PlayerBar()
        }
        .overlay(alignment: .top) { toastLayer }
        .overlay {
            if model.showNowPlaying {
                NowPlayingView()
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity))
                    .zIndex(2)
            }
        }
        .overlay {
            if model.showPalette {
                CommandPaletteView()
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .sheet(isPresented: $model.showEQ) { EQPanelView().environmentObject(model) }
        .sheet(isPresented: $model.showSources) { SourcesSheet().environmentObject(model) }
        .sheet(isPresented: $model.showSettings) { SettingsSheet().environmentObject(model) }
        .sheet(isPresented: $model.showUpdateSheet) { UpdateSheet().environmentObject(model) }
        .animation(AwakeTheme.spring, value: model.showNowPlaying)
        .animation(.easeOut(duration: 0.15), value: model.showPalette)
        .task {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--page"), i + 1 < args.count {
                switch args[i + 1] {
                case "albums": model.destination = .albums
                case "artists": model.destination = .artists
                case "songs": model.destination = .songs
                case "favorites": model.destination = .favorites
                default: break
                }
            }
            if args.contains("--nowplaying") {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(AwakeTheme.spring) { model.showNowPlaying = true }
            }
            if args.contains("--palette") {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                model.showPalette = true
            }
            if args.contains("--sources") {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                model.showSources = true
            }
            if args.contains("--settings") {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                model.showSettings = true

            }
            guard args.contains("--autoplay") else { return }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if let first = model.library.tracks.first {
                model.play(first, context: model.library.tracks, title: "全部歌曲")
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(AwakeTheme.spring) { model.showNowPlaying = true }
            if args.contains("--eq") {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                model.showEQ = true
            }
        }
        .background(
            Button("") { model.showPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    private var background: some View {
        ZStack {
            AwakeTheme.background
            LinearGradient(colors: [model.palette.primary.opacity(0.16),
                                    model.palette.secondary.opacity(0.07),
                                    Color.clear],
                           startPoint: .topLeading,
                           endPoint: .center)
            RadialGradient(colors: [model.palette.secondary.opacity(0.10), .clear],
                           center: .bottomTrailing,
                           startRadius: 20,
                           endRadius: 900)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: model.palette.primary)
    }

    @ViewBuilder
    private var mainContent: some View {
        if let album = model.selectedAlbum {
            AlbumDetailView(album: album)
        } else if let artist = model.selectedArtist {
            ArtistDetailView(name: artist)
        } else {
            switch model.destination {
            case .home:
                HomeView()
            case .albums:
                AlbumsGridView()
            case .artists:
                ArtistsView()
            case .songs:
                SongsView()
            case .favorites:
                FavoritesView()
            }
        }
    }

    @ViewBuilder
    private var toastLayer: some View {
        if let toast = model.toast {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.palette.secondary)
                    .frame(width: 6, height: 6)
                Text(toast)
                    .font(.system(size: AwakeType.bodySize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .padding(.top, 18)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    private let items: [(AppModel.Destination, String, String)] = [
        (.home, "首页", "house"),
        (.albums, "专辑", "square.stack"),
        (.artists, "艺人", "music.mic"),
        (.songs, "歌曲", "music.note.list"),
        (.favorites, "收藏", "heart")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 20)
                .padding(.top, 40)
                .padding(.bottom, 26)

            VStack(spacing: 3) {
                ForEach(items, id: \.0) { item in
                    sidebarRow(item.0, title: item.1, symbol: item.2)
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("音乐来源")
                        .font(.system(size: AwakeType.metaSize, weight: .semibold))
                        .foregroundStyle(AwakeTheme.tertiaryText)
                    Spacer()
                    Button {
                        model.showSources = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AwakeTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(model.library.sources.prefix(4)) { source in
                    HStack(spacing: 8) {
                        Image(systemName: source.kind.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(AwakeTheme.secondaryText)
                        Text(source.name)
                            .font(.system(size: AwakeType.bodySize))
                            .foregroundStyle(AwakeTheme.secondaryText)
                            .lineLimit(1)
                        Spacer()
                        Text(String(source.trackCount))
                            .font(.system(size: AwakeType.metaSize, design: .rounded))
                            .foregroundStyle(AwakeTheme.tertiaryText)
                    }
                }

            }
            .padding(.horizontal, 20)

            Divider()
                .overlay(AwakeTheme.hairline)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)

            HStack(spacing: 10) {
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13))
                        .foregroundStyle(AwakeTheme.secondaryText)
                        .overlay(alignment: .topTrailing) {
                            if model.hasUpdate {
                                Circle()
                                    .fill(AwakeTheme.warm)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 1, y: -1)
                            }
                        }
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Awake \(model.appVersion)")
                    .font(.system(size: AwakeType.metaSize, design: .rounded))
                    .foregroundStyle(AwakeTheme.tertiaryText)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
        }
        .frame(width: 236)
        .background(Color.white.opacity(0.022))
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [model.palette.primary, model.palette.secondary],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black.opacity(0.8))
            }
            Text("Awake")
                .font(.system(size: AwakeType.titleSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
        }
    }

    private func sidebarRow(_ destination: AppModel.Destination, title: String, symbol: String) -> some View {
        let selected = model.destination == destination && model.selectedAlbum == nil && model.selectedArtist == nil
        return Button {
            model.selectedAlbum = nil
            model.selectedArtist = nil
            model.destination = destination
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: AwakeType.bodySize, weight: .medium))
                Spacer()
            }
            .foregroundStyle(selected ? Color.white : AwakeTheme.secondaryText)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.09) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
