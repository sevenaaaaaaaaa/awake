import Foundation

public struct LibrarySnapshot: Codable {
    public var tracks: [Track]
    public var sources: [MediaSource]
    public var scannedAt: Date?
    public init(tracks: [Track] = [], sources: [MediaSource] = [], scannedAt: Date? = nil) {
        self.tracks = tracks
        self.sources = sources
        self.scannedAt = scannedAt
    }
}

public protocol IncrementalMusicProvider: MusicProvider {
    func scan(source: MediaSource, existing: [String: Track],
              progress: @escaping (Int, String) -> Void) async throws -> [Track]
}

extension LocalMusicProvider: IncrementalMusicProvider {
    public func scan(source: MediaSource, existing: [String: Track],
                     progress: @escaping (Int, String) -> Void) async throws -> [Track] {
        let root = URL(fileURLWithPath: source.url, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw AwakeError.invalidConfiguration("文件夹不存在：\(source.url)")
        }
        let scanner = LibraryScanner()
        return await scanner.scan(root: root, sourceID: source.id, existing: existing, progress: progress)
    }
}

extension SMBMusicProvider: IncrementalMusicProvider {
    public func scan(source: MediaSource, existing: [String: Track],
                     progress: @escaping (Int, String) -> Void) async throws -> [Track] {
        let root = try await Self.mountPublic(source)
        let scanner = LibraryScanner()
        return await scanner.scan(root: root, sourceID: source.id, existing: existing, progress: progress)
    }

}

@MainActor
public final class MusicLibrary: ObservableObject {
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var sources: [MediaSource] = []
    @Published public private(set) var scannedAt: Date?
    @Published public var isScanning = false
    @Published public var scanStatus = ""
    @Published public var lastError: String?

    private var saveTask: Task<Void, Never>?

    public init() {
        AwakePaths.ensure()
        load()
    }

    // MARK: - Persistence

    public func load() {
        guard let snapshot = JSONFile.read(LibrarySnapshot.self, at: AwakePaths.libraryFile) else { return }
        tracks = snapshot.tracks
        sources = snapshot.sources
        scannedAt = snapshot.scannedAt
    }

    public func save() {
        saveTask?.cancel()
        let snapshot = LibrarySnapshot(tracks: tracks, sources: sources, scannedAt: scannedAt)
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            JSONFile.write(snapshot, to: AwakePaths.libraryFile)
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        JSONFile.write(LibrarySnapshot(tracks: tracks, sources: sources, scannedAt: scannedAt), to: AwakePaths.libraryFile)
    }

    // MARK: - Sources

    public func addSource(_ source: MediaSource) {
        sources.append(source)
        save()
    }

    public func updateSource(_ source: MediaSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
            save()
        }
    }

    public func removeSource(_ id: UUID) {
        sources.removeAll { $0.id == id }
        tracks.removeAll { $0.sourceID == id }
        save()
    }

    // MARK: - Scanning

    public func scanAll() async {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        defer { isScanning = false }

        let enabled = sources.filter(\.enabled)
        if enabled.isEmpty {
            scanStatus = "还没有添加曲库来源"
            return
        }
        for source in enabled {
            await scan(source)
        }
        scannedAt = Date()
        scanStatus = "扫描完成，\(tracks.count) 首"
        saveNow()
    }

    public func scan(_ source: MediaSource) async {
        lastError = nil
        scanStatus = "正在连接 \(source.name)…"
        let existing = Dictionary(tracks.filter { $0.sourceID == source.id }.map { ($0.locator, $0) }, uniquingKeysWith: { first, _ in first })
        let provider = MusicProviders.provider(for: source.kind)
        var tick = 0

        do {
            let scanned: [Track]
            if let incremental = provider as? IncrementalMusicProvider {
                scanned = try await incremental.scan(source: source, existing: existing) { count, label in
                    tick += 1
                    guard tick % 8 == 0 else { return }
                    Task { @MainActor [weak self] in
                        self?.scanStatus = "\(source.name)，\(count) 首，\(label)"
                    }
                }
            } else {
                scanned = try await provider.scan(source: source) { count, label in
                    tick += 1
                    guard tick % 8 == 0 else { return }
                    Task { @MainActor [weak self] in
                        self?.scanStatus = "\(source.name)，\(count) 首，\(label)"
                    }
                }
            }

            var merged = scanned
            for i in merged.indices {
                guard let old = existing[merged[i].locator] else { continue }
                merged[i].playCount = old.playCount
                merged[i].favorite = old.favorite
                merged[i].lastPlayed = old.lastPlayed
                merged[i].addedAt = old.addedAt
                if merged[i].artworkPath == nil { merged[i].artworkPath = old.artworkPath }
            }

            tracks.removeAll { $0.sourceID == source.id }
            tracks.append(contentsOf: merged)
            tracks.sort { ($0.albumArtist.localizedLowercase, $0.album.localizedLowercase, $0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.albumArtist.localizedLowercase, $1.album.localizedLowercase, $1.discNumber ?? 1, $1.trackNumber ?? 0) }

            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].lastScan = Date()
                sources[index].trackCount = merged.count
            }
            scanStatus = "\(source.name) 已收录 \(merged.count) 首"
            save()
        } catch {
            lastError = error.localizedDescription
            scanStatus = "\(source.name) 扫描失败"
        }
    }

    // MARK: - Playback resolution

    public func resolveStream(for track: Track) async throws -> ResolvedStream {
        guard let source = sources.first(where: { $0.id == track.sourceID }) else {
            throw AwakeError.connection("曲库来源已被移除")
        }
        let provider = MusicProviders.provider(for: source.kind)
        return try await TrackStreamResolver.shared.resolveStream(for: track, source: source, provider: provider)
    }

    public func resolveURL(for track: Track) async throws -> URL {
        try await resolveStream(for: track).url
    }

    // MARK: - Derived views

    public var albums: [Album] { tracks.albums }

    public func tracks(in album: Album) -> [Track] { album.tracks }

    public var artists: [(name: String, albums: [Album])] {
        let grouped = Dictionary(grouping: albums) { $0.artist }
        return grouped.map { (name: $0.key, albums: $0.value.sorted { ($0.year ?? 0) > ($1.year ?? 0) }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var recentlyAdded: [Album] {
        albums.sorted { a, b in
            let da = a.tracks.map(\.addedAt).max() ?? .distantPast
            let db = b.tracks.map(\.addedAt).max() ?? .distantPast
            return da > db
        }
    }

    public var recentlyPlayed: [Track] {
        tracks.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    public var favorites: [Track] { tracks.filter(\.favorite) }

    public func search(_ query: String) -> [Track] {
        let q = query.trimmed.localizedLowercase
        guard !q.isEmpty else { return [] }
        return tracks.filter {
            $0.title.localizedLowercase.contains(q) ||
            $0.artist.localizedLowercase.contains(q) ||
            $0.album.localizedLowercase.contains(q)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func track(id: String) -> Track? { tracks.first { $0.id == id } }

    // MARK: - Mutations

    public func markPlayed(_ id: String) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].playCount += 1
        tracks[index].lastPlayed = Date()
        save()
    }

    public func toggleFavorite(_ id: String) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].favorite.toggle()
        save()
    }

    /// 用补齐后的条目替换曲库中的旧条目（保留播放统计与收藏）。
    public func update(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        var merged = track
        merged.playCount = tracks[index].playCount
        merged.favorite = tracks[index].favorite
        merged.lastPlayed = tracks[index].lastPlayed
        merged.addedAt = tracks[index].addedAt
        tracks[index] = merged
        save()
    }

    public func setArtwork(_ path: String, for trackID: String, albumKey: String? = nil) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].artworkPath = path
        if let key = albumKey {
            for i in tracks.indices where tracks[i].albumKey == key { tracks[i].artworkPath = path }
        }
        save()
    }
}
