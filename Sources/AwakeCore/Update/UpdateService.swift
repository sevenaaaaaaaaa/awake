import Foundation

// MARK: - Version

/// A small semantic-ish version that accepts release tags such as `v0.1.1`
/// and tolerates suffixes like `0.2.0-beta.1` by comparing the leading numbers.
public struct AppVersion: Comparable, CustomStringConvertible, Equatable, Sendable {
    public let components: [Int]

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = (trimmed.hasPrefix("v") || trimmed.hasPrefix("V")) ? String(trimmed.dropFirst()) : trimmed
        // Pre-release / build metadata ("0.2.0-beta.1", "1.0.0+build7") is ignored
        // so ordering only considers the numeric release version.
        let numericPart = cleaned.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? cleaned
        var numbers: [Int] = []
        for component in numericPart.split(separator: ".") {
            let digits = component.prefix { $0.isNumber }
            guard let value = Int(digits) else { return nil }
            numbers.append(value)
        }
        guard !numbers.isEmpty else { return nil }
        components = numbers
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

// MARK: - GitHub release payload

public struct ReleaseAsset: Codable, Equatable, Sendable {
    public let name: String
    public let size: Int
    public let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name, size
        case browserDownloadURL = "browser_download_url"
    }
}

public struct LatestRelease: Codable, Equatable, Sendable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let publishedAt: String?
    public let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

/// Everything the UI needs in order to offer a concrete update.
public struct UpdateInfo: Equatable, Sendable {
    public let version: String
    public let currentVersion: String
    public let notes: String
    public let downloadURL: URL
    public let assetName: String
    public let assetSize: Int
    public let releaseURL: URL

    public var isNewer: Bool {
        guard let remote = AppVersion(version), let current = AppVersion(currentVersion) else { return false }
        return current < remote
    }
}

public enum UpdateOutcome: Equatable, Sendable {
    case upToDate(version: String)
    case available(UpdateInfo)
}

public enum UpdateError: LocalizedError, Equatable {
    case network(String)
    case noRelease
    case noCompatibleAsset
    case downloadFailed(String)
    case unzipFailed(String)
    case invalidBundle
    case versionMismatch(expected: String, actual: String)
    case signatureInvalid
    case installFailed(String)
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .network(let message):
            return "网络请求失败：\(message)"
        case .noRelease:
            return "GitHub 上还没有可用的发行版本。"
        case .noCompatibleAsset:
            return "最新版本没有提供 Apple Silicon 安装包。"
        case .downloadFailed(let message):
            return "下载失败：\(message)"
        case .unzipFailed(let message):
            return "解压失败：\(message)"
        case .invalidBundle:
            return "下载包不是有效的 Awake 应用。"
        case .versionMismatch(let expected, let actual):
            return "安装包版本不符：期望 \(expected)，实际 \(actual)。"
        case .signatureInvalid:
            return "安装包签名校验失败，已中止。"
        case .installFailed(let message):
            return "写入应用失败：\(message)"
        case .notInstalled:
            return "当前运行的不是已安装的 Awake.app，无法就地更新。"
        }
    }
}

// MARK: - Channel

public enum UpdateChannel {
    public static let repository = "sevenaaaaaaaaa/awake"

    /// Defaults to the GitHub "latest release" API; `AWAKE_UPDATE_FEED` lets the
    /// end-to-end updater be exercised against a local fixture server.
    public static var feedURL: URL {
        if let custom = ProcessInfo.processInfo.environment["AWAKE_UPDATE_FEED"],
           !custom.isEmpty, let url = URL(string: custom) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public static var releasePage: URL {
        URL(string: "https://github.com/\(repository)/releases/latest")!
    }
}

// MARK: - Checker

public enum UpdateChecker {
    public static func check(currentVersion: String,
                             feed: URL = UpdateChannel.feedURL,
                             session: URLSession = .shared) async throws -> UpdateOutcome {
        let release = try await fetchLatest(feed: feed, session: session)
        guard let remoteVersion = AppVersion(release.tagName) else {
            throw UpdateError.noRelease
        }
        let current = AppVersion(currentVersion) ?? AppVersion("0.0.0")!
        guard current < remoteVersion else {
            return .upToDate(version: remoteVersion.description)
        }
        guard let asset = selectAsset(from: release.assets) else {
            throw UpdateError.noCompatibleAsset
        }
        return .available(UpdateInfo(version: remoteVersion.description,
                                     currentVersion: current.description,
                                     notes: release.body?.trimmedNonEmpty ?? "本次更新没有附说明。",
                                     downloadURL: asset.browserDownloadURL,
                                     assetName: asset.name,
                                     assetSize: asset.size,
                                     releaseURL: release.htmlURL))
    }

    public static func fetchLatest(feed: URL = UpdateChannel.feedURL,
                                   session: URLSession = .shared) async throws -> LatestRelease {
        var request = URLRequest(url: feed)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Awake/\(Bundle.main.shortVersion)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.network("未收到 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 { throw UpdateError.noRelease }
            throw UpdateError.network("HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(LatestRelease.self, from: data)
        } catch {
            throw UpdateError.network("返回内容无法解析：\(error.localizedDescription)")
        }
    }

    /// Prefers the Apple Silicon macOS archive the release workflow publishes.
    public static func selectAsset(from assets: [ReleaseAsset]) -> ReleaseAsset? {
        let zips = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        let preferred = zips.first { $0.name.lowercased().contains("macos-arm64") }
            ?? zips.first { $0.name.lowercased().contains("macos") }
            ?? zips.first { $0.name.lowercased().contains("awake") }
            ?? zips.first
        return preferred
    }
}

// MARK: - Downloader

public enum UpdateDownloader {
    /// Streams the asset to `destination`, reporting 0...1 progress.
    public static func download(_ info: UpdateInfo,
                                to destination: URL,
                                session: URLSession = .shared,
                                progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: info.downloadURL)
        request.timeoutInterval = 60
        request.setValue("Awake/\(Bundle.main.shortVersion)", forHTTPHeaderField: "User-Agent")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateError.downloadFailed("HTTP \(code)")
        }

        let expected = http.expectedContentLength > 0 ? http.expectedContentLength : Int64(info.assetSize)
        let directory = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw UpdateError.downloadFailed("无法写入临时文件")
        }
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var received: Int64 = 0
        var lastReported = -1.0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if expected > 0 {
                        let ratio = min(1, Double(received) / Double(expected))
                        if ratio - lastReported >= 0.01 {
                            lastReported = ratio
                            progress(ratio)
                        }
                    }
                }
            }
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        guard received > 0 else { throw UpdateError.downloadFailed("下载内容为空") }
        progress(1)
    }
}

// MARK: - Installer

public enum UpdateInstaller {
    /// Unpacks and validates an archive in a scratch directory. Nothing on disk
    /// outside the temp folder is touched until `installAndRelaunch` runs.
    public static func unpack(zip: URL,
                              expectedVersion: String,
                              scratchRoot: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let scratch = scratchRoot.appendingPathComponent("AwakeUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let extractDir = scratch.appendingPathComponent("extract", isDirectory: true)

        try run("/usr/bin/ditto", ["-x", "-k", zip.path, extractDir.path])
        try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", extractDir.path], allowFailure: true)

        guard let bundle = findAppBundle(in: extractDir) else {
            throw UpdateError.unzipFailed("压缩包内没有 .app")
        }
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw UpdateError.invalidBundle
        }
        guard (info["CFBundleIdentifier"] as? String) == Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidBundle
        }
        let actual = (info["CFBundleShortVersionString"] as? String) ?? ""
        guard let remote = AppVersion(actual), let expected = AppVersion(expectedVersion), remote >= expected else {
            throw UpdateError.versionMismatch(expected: expectedVersion, actual: actual)
        }
        let executable = bundle.appendingPathComponent("Contents/MacOS/Awake")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.invalidBundle
        }
        guard verifySignature(bundle) else {
            throw UpdateError.signatureInvalid
        }
        return bundle
    }

    /// Hands the swap to a detached shell helper so the running process can quit.
    public static func installAndRelaunch(newBundle: URL,
                                          destination: URL = Bundle.main.bundleURL,
                                          version: String) throws {
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notInstalled
        }
        guard destination.pathExtension == "app" else { throw UpdateError.notInstalled }

        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("awake-update-\(UUID().uuidString).sh")
        let body = """
        #!/bin/sh
        set -e
        PID=\(ProcessInfo.processInfo.processIdentifier)
        NEW=\(shellQuote(newBundle.path))
        DEST=\(shellQuote(destination.path))
        TMP="$DEST.awake-new"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        /bin/rm -rf "$TMP"
        /usr/bin/ditto "$NEW" "$TMP"
        /usr/bin/xattr -dr com.apple.quarantine "$TMP" 2>/dev/null || true
        /bin/rm -rf "$DEST"
        /bin/mv "$TMP" "$DEST"
        /usr/bin/open -n "$DEST" --args --just-updated \(shellQuote(version))
        /bin/rm -rf "$NEW"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }

    // MARK: Helpers

    private static func findAppBundle(in root: URL) -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                             includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.pathExtension == "app", (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return url
            }
        }
        return nil
    }

    private static func verifySignature(_ bundle: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func run(_ tool: String, _ arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            if allowFailure { return }
            throw UpdateError.unzipFailed(error.localizedDescription)
        }
        if process.terminationStatus != 0 && !allowFailure {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmedNonEmpty ?? "退出码 \(process.terminationStatus)"
            throw UpdateError.unzipFailed(message)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

// MARK: - Convenience

public extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
