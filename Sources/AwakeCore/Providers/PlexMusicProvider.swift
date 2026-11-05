import Foundation

public struct PlexMusicProvider: MusicProvider {
    public init() {}

    private func base(_ source: MediaSource) throws -> URL {
        var text = source.url.trimmed
        guard !text.isEmpty else { throw AwakeError.invalidConfiguration("未填写 Plex 服务器地址") }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text) else { throw AwakeError.invalidConfiguration("Plex 地址格式错误") }
        return url
    }

    private func token(_ source: MediaSource) -> String {
        source.token.isEmpty ? (Keychain.read(source.passwordKey) ?? "") : source.token
    }

    private func get(_ source: MediaSource, path: String, query: [URLQueryItem] = []) async throws -> Data {
        var comps = URLComponents(url: try base(source).appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query
        let tk = token(source)
        if !tk.isEmpty { items.append(URLQueryItem(name: "X-Plex-Token", value: tk)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!, timeoutInterval: 45)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !tk.isEmpty { req.setValue(tk, forHTTPHeaderField: "X-Plex-Token") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AwakeError.connection("Plex 无响应") }
        if http.statusCode == 401 { throw AwakeError.authentication }
        guard (200...299).contains(http.statusCode) else { throw AwakeError.connection("Plex 返回 \(http.statusCode)") }
        return data
    }

    public func scan(source: MediaSource, progress: @escaping (Int, String) -> Void) async throws -> [Track] {
        let sectionsData = try await get(source, path: "library/sections")
        guard let root = try JSONSerialization.jsonObject(with: sectionsData) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any],
              let dirs = container["Directory"] as? [[String: Any]] else {
            throw AwakeError.connection("无法解析 Plex 资料库")
        }
        let musicSections = dirs.filter { ($0["type"] as? String) == "artist" }
        var tracks: [Track] = []
        var albumArt: [String: String] = [:]

        for section in musicSections {
            guard let key = section["key"] as? String else { continue }
            let title = (section["title"] as? String) ?? "Plex 音乐"
            let data = try await get(source, path: "library/sections/\(key)/all", query: [URLQueryItem(name: "type", value: "10")])
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let inner = parsed["MediaContainer"] as? [String: Any],
                  let metas = inner["Metadata"] as? [[String: Any]] else { continue }
            for meta in metas {
                guard let ratingKey = meta["ratingKey"] as? String,
                      let name = meta["title"] as? String else { continue }
                var partKey = ""
                if let media = meta["Media"] as? [[String: Any]],
                   let first = media.first,
                   let parts = first["Part"] as? [[String: Any]],
                   let part = parts.first,
                   let key = part["key"] as? String {
                    partKey = key
                }
                guard !partKey.isEmpty else { continue }
                let artist = (meta["grandparentTitle"] as? String) ?? (meta["originalTitle"] as? String) ?? "未知艺人"
                let album = (meta["parentTitle"] as? String) ?? title
                let duration = (meta["duration"] as? Double ?? 0) / 1000.0
                var track = Track(
                    id: "plex|\(source.id.uuidString)|\(ratingKey)",
                    title: name,
                    artist: artist,
                    albumArtist: artist,
                    album: album,
                    year: meta["year"] as? Int,
                    trackNumber: meta["index"] as? Int,
                    discNumber: meta["parentIndex"] as? Int,
                    duration: duration,
                    sampleRate: 44100,
                    bitDepth: 16,
                    channels: 2,
                    codec: "Plex",
                    sourceID: source.id,
                    locator: partKey,
                    fileSize: 0,
                    modified: Date(timeIntervalSince1970: meta["addedAt"] as? Double ?? 0),
                    isRemote: true
                )
                track.addedAt = Date(timeIntervalSince1970: meta["addedAt"] as? Double ?? 0)
                if let thumb = meta["thumb"] as? String {
                    albumArt[track.albumKey] = thumb
                }
                if let media = meta["Media"] as? [[String: Any]], let first = media.first {
                    if let audio = first["audioCodec"] as? String { track.codec = audio.uppercased() }
                    if let bitrate = first["bitrate"] as? Int { _ = bitrate }
                }
                tracks.append(track)
            }
            progress(tracks.count, title)
        }

        // Download one cover per album (Plex only exposes per-track thumbs pointing at the same album art).
        var resolved: [String: String] = [:]
        for (albumKey, thumb) in albumArt {
            if let path = await downloadArtwork(source: source, thumb: thumb) {
                resolved[albumKey] = path
            }
        }
        for i in tracks.indices {
            if let path = resolved[tracks[i].albumKey] { tracks[i].artworkPath = path }
        }
        return tracks
    }

    private func downloadArtwork(source: MediaSource, thumb: String) async -> String? {
        guard let baseURL = try? base(source),
              var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = baseURL.path + thumb
        comps.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token(source))]
        guard let url = comps.url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url), !data.isEmpty else { return nil }
        let id = "plex-" + thumb.sha256Short
        return LibraryScanner.persistArtwork(data, id: id)
    }

    public func playbackURL(for track: Track, source: MediaSource) async throws -> URL {
        guard let baseURL = try? base(source) else { throw AwakeError.invalidConfiguration("Plex 地址无效") }
        var comps = URLComponents(url: baseURL.appendingPathComponent(track.locator), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "download", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: token(source))
        ]
        guard let url = comps?.url else { throw AwakeError.connection("无法生成 Plex 播放地址") }
        return url
    }
}
