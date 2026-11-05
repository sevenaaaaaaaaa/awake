import Foundation
import CoreFoundation

// MARK: - Shared plumbing

/// Tiny async HTTP helper shared by the metadata services.
/// Every request fails silently (nil) so callers can degrade gracefully offline.
enum MetadataHTTP {
    static let userAgent = "Awake/1.0 ( https://github.com/seewow )"

    static func data(from url: URL,
                     timeout: TimeInterval = 12,
                     headers: [String: String] = [:]) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    static func json(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Conservative UTF-8 length of a query value once percent-encoded.
    static func encodedLength(_ value: String) -> Int {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed)?.utf8.count ?? value.utf8.count
    }

    static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+#")
        return set
    }()
}

/// Resolves the on-disk audio file for a track so sidecar assets (.lrc, cover art) can be found.
enum TrackFileResolver {
    private static let lock = NSLock()
    private static var cachedSources: [MediaSource] = []
    private static var cachedLibraryPath: String?
    private static var cachedLibraryStamp: Date?

    static func audioURL(for track: Track) -> URL? {
        let fm = FileManager.default
        // Remote providers store the absolute path in the locator.
        if track.locator.hasPrefix("/") {
            let url = URL(fileURLWithPath: track.locator)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return url
        }
        guard let source = sources().first(where: { $0.id == track.sourceID }), source.kind == .local else {
            return nil
        }
        let root = URL(fileURLWithPath: source.url, isDirectory: true)
        let url = root.appendingPathComponent(track.locator)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return url
    }

    /// Finds a sibling file next to `audio` by stem or by a fixed set of names, case-insensitively.
    static func sibling(of audio: URL, extensions: [String], names: [String]? = nil) -> URL? {
        let fm = FileManager.default
        let directory = audio.deletingLastPathComponent()
        let stem = audio.deletingPathExtension().lastPathComponent.lowercased()
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        let loweredNames = names?.map { $0.lowercased() }
        for entry in entries {
            let nsEntry = entry as NSString
            let ext = nsEntry.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }
            let candidateStem = nsEntry.deletingPathExtension.lowercased()
            let matches = loweredNames?.contains(candidateStem) ?? (candidateStem == stem)
            if matches {
                return directory.appendingPathComponent(entry)
            }
        }
        return nil
    }

    static func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        // Honour UTF-16 BOMs before attempting UTF-8.
        if data.count >= 2 {
            let bom = [UInt8](data.prefix(2))
            if bom == [0xFF, 0xFE] || bom == [0xFE, 0xFF], let text = String(data: data, encoding: .utf16) {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Legacy Chinese lyric files are frequently GB18030/GBK encoded.
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)))
        if let text = String(data: data, encoding: gb18030) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: Library snapshot

    private static func sources() -> [MediaSource] {
        let url = AwakePaths.libraryFile
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date

        lock.lock()
        if cachedLibraryPath == url.path, let cachedStamp = cachedLibraryStamp, cachedStamp == stamp {
            let cached = cachedSources
            lock.unlock()
            return cached
        }
        lock.unlock()

        let loaded = loadSources(at: url)
        lock.lock()
        cachedSources = loaded
        cachedLibraryPath = url.path
        cachedLibraryStamp = stamp
        lock.unlock()
        return loaded
    }

    private static func loadSources(at url: URL) -> [MediaSource] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // Only decode the `sources` array: the track list can be large.
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawSources = root["sources"],
           let sourcesData = try? JSONSerialization.data(withJSONObject: rawSources) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let sources = try? decoder.decode([MediaSource].self, from: sourcesData) {
                return sources
            }
        }
        return JSONFile.read(LibrarySnapshot.self, at: url)?.sources ?? []
    }
}

// MARK: - Lyrics service

/// Resolves lyrics for a track: local sidecar .lrc first, then LRCLIB, then nothing.
public actor LyricsService {
    public static let shared = LyricsService()

    /// Session-level negative cache so missing lyrics do not re-hit the network constantly.
    private var misses: Set<String> = []

    public init() {}

    public func lyrics(for track: Track) async -> LyricsDocument? {
        let cache = Self.cacheURL(for: track.id)

        // 1. Disk cache first — works fully offline.
        if let cached = JSONFile.read(LyricsDocument.self, at: cache), !cached.lines.isEmpty {
            return cached
        }
        // 2. Sidecar file next to the audio.
        if let document = localDocument(for: track) {
            JSONFile.write(document, to: cache)
            return document
        }
        if misses.contains(track.id) { return nil }

        // 3. LRCLIB (exact match, then search).
        if let document = await lrclibDocument(for: track) {
            JSONFile.write(document, to: cache)
            return document
        }

        misses.insert(track.id)
        return nil
    }

    static func cacheURL(for trackID: String) -> URL {
        let safe = trackID.replacingOccurrences(of: "/", with: "_")
        return AwakePaths.lyricsCache.appendingPathComponent(safe + ".json")
    }

    // MARK: Local sidecar

    private func localDocument(for track: Track) -> LyricsDocument? {
        guard let audio = TrackFileResolver.audioURL(for: track),
              let lrc = TrackFileResolver.sibling(of: audio, extensions: ["lrc"]),
              let text = TrackFileResolver.readText(at: lrc)?.trimmed,
              !text.isEmpty else {
            return nil
        }
        let lines = LRCParser.parse(text)
        guard !lines.isEmpty else { return nil }
        return LyricsDocument(lines: lines, isSynced: LRCParser.isSynced(text), source: "本地歌词")
    }

    // MARK: LRCLIB

    private func lrclibDocument(for track: Track) async -> LyricsDocument? {
        if let exact = await lrclibExactMatch(for: track) { return exact }
        return await lrclibSearch(for: track)
    }

    private func lrclibExactMatch(for track: Track) async -> LyricsDocument? {
        let title = track.title.trimmed
        let artist = track.artist.trimmed
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title)
        ]
        if !track.album.trimmed.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: track.album.trimmed))
        }
        if track.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        components?.queryItems = items
        guard let url = components?.url,
              let data = await MetadataHTTP.data(from: url),
              let object = MetadataHTTP.json(data) as? [String: Any] else {
            return nil
        }
        return Self.document(fromLRCLIB: object, source: "LRCLIB")
    }

    private func lrclibSearch(for track: Track) async -> LyricsDocument? {
        let title = track.title.trimmed
        let artist = track.artist.trimmed
        guard !title.isEmpty || !artist.isEmpty else { return nil }

        var components = URLComponents(string: "https://lrclib.net/api/search")
        var items: [URLQueryItem] = []
        if !title.isEmpty { items.append(URLQueryItem(name: "track_name", value: title)) }
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        if !track.album.trimmed.isEmpty { items.append(URLQueryItem(name: "album_name", value: track.album.trimmed)) }
        components?.queryItems = items
        guard let url = components?.url,
              let data = await MetadataHTTP.data(from: url),
              let rows = MetadataHTTP.json(data) as? [[String: Any]] else {
            return nil
        }

        var bestScore = Int.min
        var bestDocument: LyricsDocument?
        for row in rows {
            guard let document = Self.document(fromLRCLIB: row, source: "LRCLIB") else { continue }
            var score = 0
            if let number = row["duration"] as? NSNumber, track.duration > 0,
               abs(number.doubleValue - track.duration) < 3 {
                score += 3
            }
            if let rowArtist = row["artistName"] as? String,
               rowArtist.caseInsensitiveCompare(artist) == .orderedSame {
                score += 2
            }
            if let rowTitle = row["trackName"] as? String,
               rowTitle.caseInsensitiveCompare(title) == .orderedSame {
                score += 2
            }
            if let rowAlbum = row["albumName"] as? String,
               !track.album.trimmed.isEmpty,
               rowAlbum.caseInsensitiveCompare(track.album.trimmed) == .orderedSame {
                score += 1
            }
            if document.isSynced { score += 3 }
            if score > bestScore {
                bestScore = score
                bestDocument = document
            }
        }
        return bestDocument
    }

    private static func document(fromLRCLIB object: [String: Any], source: String) -> LyricsDocument? {
        if let instrumental = object["instrumental"] as? Bool, instrumental { return nil }

        if let synced = object["syncedLyrics"] as? String, !synced.trimmed.isEmpty {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty {
                return LyricsDocument(lines: lines, isSynced: true, source: source)
            }
        }
        if let plain = object["plainLyrics"] as? String, !plain.trimmed.isEmpty {
            let lines = LRCParser.parse(plain)
            if !lines.isEmpty {
                return LyricsDocument(lines: lines, isSynced: false, source: source)
            }
        }
        return nil
    }
}
