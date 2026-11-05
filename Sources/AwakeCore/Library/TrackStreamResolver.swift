import Foundation

public actor TrackStreamResolver {
    public static let shared = TrackStreamResolver()
    public init() {}
    private var inflight: [String: Task<URL, Error>] = [:]

    public func resolveStream(for track: Track, source: MediaSource, provider: MusicProvider) async throws -> ResolvedStream {
        let remote = try await provider.playbackURL(for: track, source: source)

        if remote.isFileURL {
            guard FileManager.default.fileExists(atPath: remote.path) else {
                throw AwakeError.connection("文件不存在：\(remote.lastPathComponent)")
            }
            return try await TranscodeService.shared.prepare(track: track, sourceURL: remote)
        }

        let ext = remote.pathExtension.isEmpty ? (track.codec.lowercased() == "alac" ? "m4a" : "audio") : remote.pathExtension
        let target = AwakePaths.audioCache.appendingPathComponent("\(track.id).\(ext)")
        if Self.cacheIsValid(target, expectedSize: track.fileSize) {
            return try await TranscodeService.shared.prepare(track: track, sourceURL: target)
        }

        let raw: URL
        if let running = inflight[track.id] {
            raw = try await running.value
        } else {
            let task = Task<URL, Error> {
                try await Self.downloadVerified(remote, to: target, source: source, expectedSize: track.fileSize)
            }
            inflight[track.id] = task
            do {
                raw = try await task.value
                inflight.removeValue(forKey: track.id)
            } catch {
                inflight.removeValue(forKey: track.id)
                throw error
            }
        }
        return try await TranscodeService.shared.prepare(track: track, sourceURL: raw)
    }

    /// Compatibility entry point for callers that only need a playable URL.
    public func localURL(for track: Track, source: MediaSource, provider: MusicProvider) async throws -> URL {
        try await resolveStream(for: track, source: source, provider: provider).url
    }

    private static func cacheIsValid(_ url: URL, expectedSize: Int64) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else { return false }
        if expectedSize > 0, size != expectedSize { return false }
        return true
    }

    private static func downloadVerified(_ url: URL, to target: URL, source: MediaSource, expectedSize: Int64) async throws -> URL {
        var lastError: Error?
        for _ in 0..<2 {
            do {
                let downloaded = try await download(url, to: target, source: source)
                if expectedSize > 0 {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: downloaded.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    guard size == expectedSize else {
                        try? FileManager.default.removeItem(at: downloaded)
                        throw AwakeError.connection("下载不完整（\(size)/\(expectedSize) 字节），正在重试")
                    }
                }
                return downloaded
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: target)
            }
        }
        throw lastError ?? AwakeError.connection("下载失败")
    }

    private static func download(_ url: URL, to target: URL, source: MediaSource) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 120)
        if source.kind == .webdav, !source.username.isEmpty {
            let raw = "\(source.username):\(source.password)"
            request.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        let (temp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AwakeError.connection("下载失败（\(http.statusCode)）")
        }
        try? FileManager.default.createDirectory(at: AwakePaths.audioCache, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    public func clearCache() async {
        try? FileManager.default.removeItem(at: AwakePaths.audioCache)
        try? FileManager.default.createDirectory(at: AwakePaths.audioCache, withIntermediateDirectories: true)
        await TranscodeService.shared.clearCache()
    }
}
