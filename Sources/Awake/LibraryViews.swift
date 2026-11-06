import SwiftUI
import AppKit
import AwakeCore

// MARK: - Shared pieces

struct AlbumArt: View {
    var path: String?
    var cornerRadius: CGFloat = 10
    var palette: ArtworkPalette = .fallback
    @State private var image: NSImage?

    var body: some View {
        ArtworkView(image: image, cornerRadius: cornerRadius, palette: palette)
            .onAppear { load() }
            .onChange(of: path) { _, _ in load() }
    }

    private func load() {
        guard let path, let loaded = NSImage(contentsOfFile: path) else {
            image = nil
            return
        }
        image = loaded
    }
}

struct SectionHeader: View {
    var title: String
    var trailing: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: AwakeType.titleSize, weight: .semibold))
                .foregroundStyle(.white)
            if let trailing {
                Text(trailing)
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(AwakeTheme.tertiaryText)
            }
            Spacer()
            if let action {
                Button(action: action) {
                    Text("查看全部")
                        .font(.system(size: AwakeType.metaSize, weight: .medium))
                        .foregroundStyle(AwakeTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 12)
    }
}

struct QualityBadge: View {
    var track: Track

    var body: some View {
        Text(track.qualityLabel)
            .font(.system(size: AwakeType.metaSize, design: .monospaced))
            .foregroundStyle(track.isHiRes ? AwakeTheme.warm : AwakeTheme.secondaryText)
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if model.library.tracks.isEmpty && !model.library.isScanning {
                    emptyState
                } else {
                    hero
                    recentAlbums
                    recentTracks
                    favorites
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 42)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.system(size: AwakeType.displaySize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: AwakeType.bodySize))
                .foregroundStyle(AwakeTheme.secondaryText)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11: return "早上好"
        case 11..<14: return "中午好"
        case 14..<18: return "下午好"
        case 18..<23: return "晚上好"
        default: return "夜深了"
        }
    }

    private var subtitle: String {
        if model.library.isScanning {
            return model.library.scanStatus.isEmpty ? "正在索引曲库…" : model.library.scanStatus
        }
        let count = model.library.tracks.count
        if count == 0 { return "把音乐文件夹、NAS 或 Plex 接进来。" }
        let artists = Set(model.library.tracks.map { $0.artist }).count
        return "\(count) 首歌，\(artists) 位艺人"
    }

    private var latest: Album? {
        model.library.recentlyAdded.first ?? model.library.albums.first
    }

    @ViewBuilder
    private var hero: some View {
        if let album = latest {
            HStack(spacing: 22) {
                AlbumArt(path: album.artworkPath, cornerRadius: 8, palette: model.palette)
                    .frame(width: 168, height: 168)

                VStack(alignment: .leading, spacing: 10) {
                    Text(album.title)
                        .font(.system(size: AwakeType.titleSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(album.artist.isEmpty ? "未知艺人" : album.artist)
                        .font(.system(size: AwakeType.bodySize))
                        .foregroundStyle(AwakeTheme.secondaryText)

                    HStack(spacing: 10) {
                        Button {
                            model.playAlbum(album)
                        } label: {
                            Label("播放专辑", systemImage: "play.fill")
                                .font(.system(size: AwakeType.bodySize, weight: .semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(Color.white))
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.playAlbum(album, startingAt: album.tracks.randomElement())
                        } label: {
                            Label("随机", systemImage: "shuffle")
                                .font(.system(size: AwakeType.bodySize, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                Spacer()
                if let track = album.tracks.first {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(track.qualityLabel)
                            .font(.system(size: AwakeType.bodySize, weight: .bold, design: .rounded))
                            .foregroundStyle(track.isHiRes ? AwakeTheme.warm : .white)
                        if let decision = model.autoEQDecision {
                            Text(decision.headphone.name)
                                .font(.system(size: AwakeType.metaSize))
                                .foregroundStyle(AwakeTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(20)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.35))
                    LinearGradient(colors: [model.palette.primary.opacity(0.22), .clear],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var recentAlbums: some View {
        let albums = Array(model.library.recentlyAdded.prefix(6))
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "最近添加", action: {
                    model.destination = .albums
                })
                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        ForEach(albums) { album in
                            AlbumCard(album: album, width: 150)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private var recentTracks: some View {
        let tracks = Array(model.library.recentlyPlayed.prefix(6))
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "常听", action: {
                    model.destination = .songs
                })
                VStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track,
                                 index: index + 1,
                                 context: tracks,
                                 title: "常听")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var favorites: some View {
        let tracks = Array(model.library.favorites.prefix(5))
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "收藏", trailing: "\(model.library.favorites.count) 首", action: {
                    model.destination = .favorites
                })
                VStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track,
                                 index: index + 1,
                                 context: tracks,
                                 title: "收藏")
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(model.palette.primary)
            Text("曲库还是空的")
                .font(.system(size: AwakeType.titleSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("选择一个音乐文件夹，或者连接 NAS / Plex。")
                .font(.system(size: AwakeType.bodySize))
                .foregroundStyle(AwakeTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button("添加文件夹") { model.addLocalFolder() }
                    .buttonStyle(PillButtonStyle(filled: true))
                Button("连接 NAS / Plex") { model.showSources = true }
                    .buttonStyle(PillButtonStyle(filled: false))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))
    }
}

struct PillButtonStyle: ButtonStyle {
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AwakeType.bodySize, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(filled ? Color.white : Color.white.opacity(0.08)))
            .foregroundStyle(filled ? Color.black : Color.white.opacity(0.9))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Albums

struct AlbumCard: View {
    @EnvironmentObject var model: AppModel
    var album: Album
    var width: CGFloat = 160
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AlbumArt(path: album.artworkPath, cornerRadius: 8, palette: model.palette)
                    .frame(width: width, height: width)
                if hovered {
                    Button {
                        model.playAlbum(album)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(.white))
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(AwakeTheme.spring, value: hovered)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: AwakeType.bodySize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(album.artist)
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { model.playAlbum(album) }
        .simultaneousGesture(TapGesture().onEnded {
            model.selectedAlbum = album
            model.destination = .albums
        })
    }
}

struct AlbumsGridView: View {
    @EnvironmentObject var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 210), spacing: 22, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(title: "专辑", trailing: "\(model.library.albums.count) 张")
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(model.library.albums) { album in
                        AlbumCard(album: album)
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 42)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Album detail

struct AlbumDetailView: View {
    @EnvironmentObject var model: AppModel
    var album: Album

    private var tracks: [Track] { model.library.tracks(in: album) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .bottom, spacing: 24) {
                    AlbumArt(path: album.artworkPath, cornerRadius: 8, palette: model.palette)
                        .frame(width: 190, height: 190)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(album.title)
                            .font(.system(size: AwakeType.displaySize, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(album.artist)
                            .font(.system(size: AwakeType.bodySize, weight: .medium))
                            .foregroundStyle(AwakeTheme.secondaryText)
                        HStack(spacing: 8) {
                            if let year = album.year { Text(String(year)) }
                            Text("\(tracks.count) 首")
                            if let first = tracks.first, first.isHiRes { Text("Hi-Res") }
                        }
                        .font(.system(size: AwakeType.metaSize))
                        .foregroundStyle(AwakeTheme.tertiaryText)

                        HStack(spacing: 10) {
                            Button {
                                model.playAlbum(album)
                            } label: {
                                Label("播放", systemImage: "play.fill")
                                    .font(.system(size: AwakeType.bodySize, weight: .semibold))
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 9)
                                    .background(Capsule().fill(.white))
                                    .foregroundStyle(.black)
                            }
                            .buttonStyle(.plain)
                            Button {
                                model.playAlbum(album, startingAt: tracks.randomElement())
                            } label: {
                                Label("随机", systemImage: "shuffle")
                                    .font(.system(size: AwakeType.bodySize, weight: .medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(Capsule().fill(.white.opacity(0.08)))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 6)
                    }
                    Spacer()
                }
                .padding(.top, 42)

                VStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track,
                                 index: index + 1,
                                 context: tracks,
                                 title: album.title,
                                 showAlbum: false)
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(
            LinearGradient(colors: [model.palette.primary.opacity(0.12), .clear],
                           startPoint: .top,
                           endPoint: .center)
                .ignoresSafeArea()
        )
    }
}

// MARK: - Artists

struct ArtistAvatar: View {
    let path: String?
    let name: String
    let palette: ArtworkPalette
    let size: CGFloat

    var body: some View {
        ZStack {
            AlbumArt(path: path, cornerRadius: size / 2, palette: palette)
                .blur(radius: 22)
                .opacity(0.6)
            LinearGradient(colors: [palette.primary.opacity(0.55), palette.deep.opacity(0.92)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

struct ArtistsView: View {
    @EnvironmentObject var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(title: "艺人", trailing: "\(model.library.artists.count) 位")
                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    ForEach(model.library.artists, id: \.name) { artist in
                        Button {
                            model.selectedArtist = artist.name
                        } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                ArtistAvatar(path: artist.albums.first?.artworkPath,
                                             name: artist.name,
                                             palette: model.palette,
                                             size: 132)
                                Text(artist.name)
                                    .font(.system(size: AwakeType.bodySize, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text("\(artist.albums.count) 张专辑")
                                    .font(.system(size: AwakeType.metaSize))
                                    .foregroundStyle(AwakeTheme.tertiaryText)
                            }
                            .frame(width: 132, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 42)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }
}

struct ArtistDetailView: View {
    @EnvironmentObject var model: AppModel
    var name: String

    private var albums: [Album] {
        model.library.artists.first { $0.name == name }?.albums ?? []
    }

    private var tracks: [Track] {
        model.library.tracks.filter { $0.artist == name || $0.albumArtist == name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 24) {
                    ArtistAvatar(path: albums.first?.artworkPath, name: name, palette: model.palette, size: 128)
                    VStack(alignment: .leading, spacing: 8) {
                    Text(name)
                        .font(.system(size: AwakeType.displaySize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(albums.count) 张专辑，\(tracks.count) 首歌")
                        .font(.system(size: AwakeType.bodySize))
                        .foregroundStyle(AwakeTheme.secondaryText)
                    Button {
                        model.playArtist(name)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: AwakeType.bodySize, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(.white))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    }
                }
                .padding(.top, 42)

                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        ForEach(albums) { album in
                            AlbumCard(album: album, width: 150)
                        }
                    }
                }
                .scrollIndicators(.hidden)

                VStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, index: index + 1, context: tracks, title: name)
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Songs

struct SongsView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""

    private var tracks: [Track] {
        query.trimmed.isEmpty ? model.library.tracks : model.library.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("歌曲")
                        .font(.system(size: AwakeType.displaySize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(model.library.tracks.count) 首")
                        .font(.system(size: AwakeType.bodySize))
                        .foregroundStyle(AwakeTheme.secondaryText)
                }
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(AwakeTheme.tertiaryText)
                    TextField("筛选歌曲", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: AwakeType.bodySize))
                        .frame(width: 160)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.07), lineWidth: 1))
            }
            .padding(.horizontal, 34)
            .padding(.top, 42)
            .padding(.bottom, 18)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, index: index + 1, context: tracks, title: "歌曲")
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct FavoritesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "收藏", trailing: "\(model.library.favorites.count) 首")
                if model.library.favorites.isEmpty {
                    Text("播放时点一下心形，收藏的歌曲会出现在这里。")
                        .font(.system(size: AwakeType.bodySize))
                        .foregroundStyle(AwakeTheme.secondaryText)
                        .padding(.vertical, 40)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(model.library.favorites.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track,
                                     index: index + 1,
                                     context: model.library.favorites,
                                     title: "收藏")
                        }
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 42)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Track row

struct TrackRow: View {
    @EnvironmentObject var model: AppModel
    var track: Track
    var index: Int
    var context: [Track]
    var title: String
    var showAlbum: Bool = true

    @State private var hovered = false

    private var isCurrent: Bool { model.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isCurrent && model.isPlaying {
                    EqualizerBars(color: model.palette.secondary)
                } else {
                    Text(String(index))
                        .font(.system(size: AwakeType.metaSize, design: .rounded))
                        .foregroundStyle(AwakeTheme.tertiaryText)
                        .opacity(hovered ? 0 : 1)
                    if hovered {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 24, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: AwakeType.bodySize, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? model.palette.secondary : .white)
                    .lineLimit(1)
                Text(track.artist.isEmpty ? "未知艺人" : track.artist)
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showAlbum {
                Text(track.album)
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                    .lineLimit(1)
                    .frame(width: 190, alignment: .leading)
            }

            if track.isHiRes {
                QualityBadge(track: track)
            }

            Button {
                model.library.toggleFavorite(track.id)
            } label: {
                Image(systemName: track.favorite ? "heart.fill" : "heart")
                    .font(.system(size: 11))
                    .foregroundStyle(track.favorite ? AwakeTheme.warm : AwakeTheme.tertiaryText)
            }
            .buttonStyle(.plain)
            .opacity(track.favorite || hovered ? 1 : 0)

            Text(track.duration.timecode)
                .font(.system(size: AwakeType.metaSize, design: .rounded))
                .foregroundStyle(AwakeTheme.tertiaryText)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Color.white.opacity(0.06) : (hovered ? Color.white.opacity(0.035) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { model.play(track, context: context, title: title) }
        .contextMenu {
            Button("播放") { model.play(track, context: context, title: title) }
            Button(track.favorite ? "取消收藏" : "收藏") { model.library.toggleFavorite(track.id) }
            Divider()
            Button("在 Finder 中显示") { revealInFinder() }
        }
    }

    private func revealInFinder() {
        guard let source = model.library.sources.first(where: { $0.id == track.sourceID }),
              source.kind == .local else { return }
        let base = URL(fileURLWithPath: source.url)
        let path = track.locator.hasPrefix("/") ? track.locator : base.appendingPathComponent(track.locator).path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

struct EqualizerBars: View {
    var color: Color
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: heights(index))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func heights(_ index: Int) -> CGFloat {
        let base: [CGFloat] = [6, 14, 9]
        return base[index] + phase * CGFloat(index + 1) * 2
    }
}
