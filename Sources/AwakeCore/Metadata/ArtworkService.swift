import Foundation

/// Resolves cover art for a track with a graceful, fully offline-capable fallback chain:
/// existing track artwork → cached download → album sidecar image → MusicBrainz + Cover Art
/// Archive → iTunes Search API → nothing.
public actor ArtworkService {
    public static let shared = ArtworkService()

    private static let imageExtensions = ["jpg", "jpeg", "png", "webp", "heic"]
    private static let sidecarNames = ["cover", "folder", "front", "album", "artwork"]
    private static let minimumMusicBrainzSpacing: UInt64 = 1_100_000_000

    /// Single-flight download jobs so a burst of UI requests issues one network call.
    private var jobs: [String: Task<String?, Never>] = [:]
    /// Negative cache for the current session.
    private var misses: Set<String> = []
    /// MusicBrainz requests are serialized through this chain to enforce the 1.1s spacing.
    private var musicBrainzChain: Task<Void, Never>?

    public init() {}

    public func artwork(for track: Track) async -> String? {
        // 1. Artwork already attached to the track.
        if let existing = Self.existingFile(track.artworkPath) { return existing }

        // 2. Previously downloaded artwork.
        let cached = AwakePaths.artworkFile(for: track.id).path
        if let existing = Self.existingFile(cached) { return existing }

        // 3. Album sidecar image next to the audio file.
        if let audio = TrackFileResolver.audioURL(for: track),
           let image = TrackFileResolver.sibling(of: audio,
                                                extensions: Self.imageExtensions,
                                                names: Self.sidecarNames),
           let existing = Self.existingFile(image.path) {
            return existing
        }

        if misses.contains(track.id) { return nil }
        if let job = jobs[track.id] { return await job.value }

        let job = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.resolve(track)
        }
        jobs[track.id] = job
        let result = await job.value
        jobs[track.id] = nil
        if result == nil { misses.insert(track.id) }
        return result
    }

    // MARK: Resolution

    private func resolve(_ track: Track) async -> String? {
        // MusicBrainz release → Cover Art Archive front image.
        if let releaseID = await musicBrainzReleaseID(for: track),
           let coverURL = Self.coverArtURL(releaseID),
           let data = await MetadataHTTP.data(from: coverURL) {
            if let path = LibraryScanner.persistArtwork(data, id: track.id) { return path }
        }

        // iTunes Search API.
        if let url = await iTunesArtworkURL(for: track),
           let data = await MetadataHTTP.data(from: url) {
            if let path = LibraryScanner.persistArtwork(data, id: track.id) { return path }
        }

        return nil
    }

    // MARK: MusicBrainz

    private func musicBrainzReleaseID(for track: Track) async -> String? {
        let album = track.album.trimmed
        let artist = (track.albumArtist.trimmed.isEmpty ? track.artist : track.albumArtist).trimmed
        // Without an album name the lookup is too likely to attach the wrong cover.
        guard !album.isEmpty else { return nil }

        var query = "release:\"\(album)\""
        if !artist.isEmpty { query += " AND artist:\"\(artist)\"" }

        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "3")
        ]
        guard let url = components?.url else { return nil }

        let data = await withMusicBrainzSlot {
            await MetadataHTTP.data(from: url)
        }
        guard let data,
              let root = MetadataHTTP.json(data) as? [String: Any],
              let releases = root["releases"] as? [[String: Any]],
              let releaseID = releases.first?["id"] as? String,
              !releaseID.isEmpty else {
            return nil
        }
        return releaseID
    }

    /// Serializes MusicBrainz calls and enforces the required minimum spacing.
    private func withMusicBrainzSlot<T>(_ body: @escaping () async -> T) async -> T {
        let previous = musicBrainzChain
        let job = Task<T, Never> {
            // The first lookup is immediate; every follow-up waits its turn plus the spacing.
            if let previous {
                await previous.value
                try? await Task.sleep(nanoseconds: Self.minimumMusicBrainzSpacing)
            }
            return await body()
        }
        musicBrainzChain = Task { _ = await job.value }
        return await job.value
    }

    private static func coverArtURL(_ releaseID: String) -> URL? {
        guard let encoded = releaseID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://coverartarchive.org/release/\(encoded)/front-500")
    }

    // MARK: iTunes

    private func iTunesArtworkURL(for track: Track) async -> URL? {
        let artist = (track.albumArtist.trimmed.isEmpty ? track.artist : track.albumArtist).trimmed
        let album = track.album.trimmed
        let term = [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
        guard !album.isEmpty, !term.isEmpty else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url,
              let data = await MetadataHTTP.data(from: url),
              let root = MetadataHTTP.json(data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let raw = results.first?["artworkUrl100"] as? String else {
            return nil
        }
        return URL(string: Self.highResolutionArtworkURL(raw))
    }

    /// Turns `.../100x100bb.jpg` into `.../600x600bb.jpg`.
    static func highResolutionArtworkURL(_ raw: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\d+x\\d+bb") else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "600x600bb")
    }

    // MARK: Helpers

    private static func existingFile(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return path
    }
}

// MARK: - Cache path helpers

extension ArtworkService {
    /// Cached artwork destination for a track id (downloads always land here).
    static func cacheURL(for trackID: String) -> URL {
        AwakePaths.artworkFile(for: trackID.replacingOccurrences(of: "/", with: "_"))
    }
}
