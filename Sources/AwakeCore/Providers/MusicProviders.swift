import Foundation

public protocol MusicProvider {
    func scan(source: MediaSource, progress: @escaping (Int, String) -> Void) async throws -> [Track]
    func playbackURL(for track: Track, source: MediaSource) async throws -> URL
}

public enum MusicProviders {
    public static func provider(for kind: SourceKind) -> MusicProvider {
        switch kind {
        case .local: return LocalMusicProvider()
        case .smb: return SMBMusicProvider()
        case .webdav: return WebDAVMusicProvider()
        case .plex: return PlexMusicProvider()
        }
    }
}

// MARK: - Local

public struct LocalMusicProvider: MusicProvider {
    public init() {}

    public func scan(source: MediaSource, progress: @escaping (Int, String) -> Void) async throws -> [Track] {
        let root = URL(fileURLWithPath: source.url, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw AwakeError.invalidConfiguration("文件夹不存在：\(source.url)")
        }
        let scanner = LibraryScanner()
        return await scanner.scan(root: root, sourceID: source.id, existing: [:], progress: progress)
    }

    public func playbackURL(for track: Track, source: MediaSource) async throws -> URL {
        let root = URL(fileURLWithPath: source.url, isDirectory: true).resolvingSymlinksInPath()
        return root.appendingPathComponent(track.locator)
    }
}

// MARK: - SMB (mount through NetFS, then treat as local)

public actor MountRegistry {
    public static let shared = MountRegistry()
    private var mounts: [UUID: URL] = [:]
    private var inflight: [UUID: Task<URL, Error>] = [:]

    func mountedURL(for id: UUID) -> URL? { mounts[id] }
    func store(_ url: URL, for id: UUID) { mounts[id] = url }
    func existingTask(for id: UUID) -> Task<URL, Error>? { inflight[id] }
    func setTask(_ task: Task<URL, Error>, for id: UUID) { inflight[id] = task }
    func finishTask(for id: UUID) { inflight.removeValue(forKey: id) }
}

public struct SMBMusicProvider: MusicProvider {
    public init() {}

    public func scan(source: MediaSource, progress: @escaping (Int, String) -> Void) async throws -> [Track] {
        let root = try await mount(source)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw AwakeError.connection("无法访问已挂载的 NAS 目录")
        }
        let scanner = LibraryScanner()
        var tracks = await scanner.scan(root: root, sourceID: source.id, existing: [:], progress: progress)
        for i in tracks.indices { tracks[i].isRemote = false }
        return tracks
    }

    public func playbackURL(for track: Track, source: MediaSource) async throws -> URL {
        let root = try await mount(source)
        let url = root.appendingPathComponent(track.locator)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AwakeError.connection("NAS 上的文件不见了：\(track.locator)")
        }
        return url
    }

    public static func mountPublic(_ source: MediaSource) async throws -> URL {
        try await SMBMusicProvider().mount(source)
    }

    func mount(_ source: MediaSource) async throws -> URL {
        if let cached = await MountRegistry.shared.mountedURL(for: source.id),
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        if let running = await MountRegistry.shared.existingTask(for: source.id) {
            return try await running.value
        }
        let task = Task<URL, Error> { try await performMount(source) }
        await MountRegistry.shared.setTask(task, for: source.id)
        defer { Task { await MountRegistry.shared.finishTask(for: source.id) } }
        let url = try await task.value
        await MountRegistry.shared.store(url, for: source.id)
        return url
    }

    private func performMount(_ source: MediaSource) async throws -> URL {
        guard let spec = SMBLocation(raw: source.url) else {
            throw AwakeError.invalidConfiguration("SMB 地址格式应为 smb://user@host/share")
        }
        let mountPoint = AwakePaths.root
            .appendingPathComponent("mounts", isDirectory: true)
            .appendingPathComponent(source.id.uuidString, isDirectory: true)
            .appendingPathComponent(spec.share, isDirectory: true)
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        if let contents = try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path), !contents.isEmpty {
            return mountPoint.appendingPathComponent(spec.subpath)
        }

        typealias MountFn = @convention(c) (CFURL?, CFURL?, CFString?, CFString?, CFMutableDictionary?, CFMutableDictionary?, UnsafeMutablePointer<CFArray?>?) -> Int32
        guard let handle = dlopen("/System/Library/Frameworks/NetFS.framework/NetFS", RTLD_NOW),
              let sym = dlsym(handle, "NetFSMountURLSync") else {
            throw AwakeError.unsupported("当前系统不支持 NetFS 挂载")
        }
        let fn = unsafeBitCast(sym, to: MountFn.self)
        let user = spec.user.isEmpty ? source.username : spec.user
        var mountpoints: CFArray?
        let status = fn(spec.url as CFURL, mountPoint as CFURL,
                        user as CFString, (source.password.isEmpty ? nil : source.password) as CFString?,
                        nil, nil, &mountpoints)
        guard status == 0 else {
            if [-5995, -5996, -5997, -6003, -6004].contains(status) { throw AwakeError.authentication }
            throw AwakeError.connection("SMB 挂载失败（\(status)）")
        }
        return mountPoint.appendingPathComponent(spec.subpath)
    }
}

public struct SMBLocation {
    public let url: URL
    public let user: String
    public let share: String
    public let subpath: String

    public init?(raw: String) {
        var text = raw.trimmed
        if !text.lowercased().hasPrefix("smb://") { text = "smb://" + text }
        guard let comps = URLComponents(string: text), let host = comps.host else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard let share = parts.first, !share.isEmpty else { return nil }
        self.user = comps.user ?? ""
        self.share = share
        self.subpath = parts.dropFirst().joined(separator: "/")
        var rebuilt = URLComponents()
        rebuilt.scheme = "smb"
        rebuilt.host = host
        rebuilt.port = comps.port
        if let user = comps.user { rebuilt.user = user }
        self.url = rebuilt.url ?? URL(string: "smb://\(host)/\(share)")!
    }
}

// MARK: - WebDAV

public struct WebDAVMusicProvider: MusicProvider {
    public init() {}

    public func scan(source: MediaSource, progress: @escaping (Int, String) -> Void) async throws -> [Track] {
        guard let base = URL(string: normalized(source.url)) else {
            throw AwakeError.invalidConfiguration("WebDAV 地址无效")
        }
        var files: [(String, Int64)] = []
        var seen = Set<String>()
        try await walk(base, path: "", depth: 0, into: &files, seen: &seen, progress: progress, source: source)
        var tracks: [Track] = []
        for (index, item) in files.enumerated() {
            let name = (item.0 as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            guard LibraryScanner.audioExtensions.contains(ext) else { continue }
            let rawTitle = (name as NSString).deletingPathExtension
            let title = rawTitle.replacingOccurrences(
                of: #"^\s*\d{1,3}\s*[-.、]\s*"#, with: "", options: .regularExpression)
            let folder = (item.0 as NSString).deletingLastPathComponent
            let album = folder.isEmpty ? source.name : (folder as NSString).lastPathComponent
            var track = Track(title: title, artist: "", album: album,
                              codec: ext.uppercased(), sourceID: source.id, locator: item.0,
                              fileSize: item.1, isRemote: true)
            // 远程条目先不谎报规格：解码器与标签等首次落盘后再补。
            track.duration = 0
            track.sampleRate = 0
            track.bitDepth = 0
            track.channels = 0
            tracks.append(track)
            if index % 20 == 0 { progress(tracks.count, title) }
        }
        return tracks
    }

    public func playbackURL(for track: Track, source: MediaSource) async throws -> URL {
        guard let base = URL(string: normalized(source.url)) else { throw AwakeError.invalidConfiguration("WebDAV 地址无效") }
        return base.appendingPathComponent(track.locator)
    }

    private func normalized(_ raw: String) -> String {
        var text = raw.trimmed
        if !text.lowercased().hasPrefix("http") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private func walk(_ base: URL, path: String, depth: Int, into files: inout [(String, Int64)],
                      seen: inout Set<String>,
                      progress: @escaping (Int, String) -> Void, source: MediaSource) async throws {
        guard depth < 8 else { return }
        let target = path.isEmpty ? base : base.appendingPathComponent(path)
        var req = URLRequest(url: target, timeoutInterval: 30)
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        if !source.username.isEmpty {
            let token = Data("\(source.username):\(source.password)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AwakeError.connection("WebDAV 无响应") }
        if http.statusCode == 401 { throw AwakeError.authentication }
        guard [207, 200].contains(http.statusCode) else { throw AwakeError.connection("WebDAV 返回 \(http.statusCode)") }

        let entries = WebDAVMultistatus.parse(data)
        for entry in entries {
            let decoded = entry.href.removingPercentEncoding ?? entry.href
            guard decoded.hasSuffix("/") == false else { continue }
            let relative = relativePath(decoded: decoded, basePath: base.path)
            guard !relative.isEmpty else { continue }
            let ext = (relative as NSString).pathExtension.lowercased()
            if LibraryScanner.audioExtensions.contains(ext), !seen.contains(relative) {
                seen.insert(relative)
                files.append((relative, entry.size))
            }
        }
        // Depth 1 的响应包含集合自身的 entry，必须排除，否则会自递归到 depth 上限。
        for entry in entries where entry.href.hasSuffix("/") {
            let decoded = entry.href.removingPercentEncoding ?? entry.href
            let relative = relativePath(decoded: decoded, basePath: base.path)
            guard !relative.isEmpty, relative != path else { continue }
            try? await walk(base, path: relative, depth: depth + 1, into: &files, seen: &seen,
                           progress: progress, source: source)
        }
    }

    private func relativePath(decoded: String, basePath: String) -> String {
        var rel = decoded
        if rel.hasPrefix(basePath) { rel = String(rel.dropFirst(basePath.count)) }
        while rel.hasPrefix("/") { rel.removeFirst() }
        if rel.hasSuffix("/") { rel.removeLast() }
        return rel
    }
}

public struct WebDAVEntry {
    public var href: String
    public var size: Int64
}

public enum WebDAVMultistatus {
    public static func parse(_ data: Data) -> [WebDAVEntry] {
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var entries: [WebDAVEntry] = []
        private var current: WebDAVEntry?
        private var text = ""
        private var inHref = false
        private var inSize = false

        /// 真实 WebDAV 服务普遍使用 <d:response> 这类带前缀的元素名；
        /// 兼容关掉命名空间处理时 elementName 仍带前缀的情况。
        private func localName(_ raw: String) -> String {
            (raw.split(separator: ":").last.map(String.init) ?? raw).lowercased()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = localName(elementName)
            if name == "response" { current = WebDAVEntry(href: "", size: 0) }
            if name == "href" { inHref = true; text = "" }
            if name == "getcontentlength" { inSize = true; text = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let name = localName(elementName)
            if name == "href", inHref {
                current?.href = text.trimmed
                inHref = false
            }
            if name == "getcontentlength", inSize {
                current?.size = Int64(text.trimmed) ?? 0
                inSize = false
            }
            if name == "response", let entry = current, !entry.href.isEmpty {
                entries.append(entry)
                current = nil
            }
        }
    }
}
