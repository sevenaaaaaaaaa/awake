import Foundation

public enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case local, smb, webdav, plex
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .local: return "本地文件夹"
        case .smb: return "SMB / NAS"
        case .webdav: return "WebDAV"
        case .plex: return "Plex"
        }
    }
    public var symbol: String {
        switch self {
        case .local: return "folder"
        case .smb: return "externaldrive.connected.to.line.below"
        case .webdav: return "cloud"
        case .plex: return "play.rectangle.on.rectangle"
        }
    }
}

public struct MediaSource: Identifiable, Codable, Hashable {
    public var id: UUID
    public var kind: SourceKind
    public var name: String
    /// Local path for .local, server URL for smb/webdav/plex.
    public var url: String
    public var username: String
    public var passwordKey: String
    public var token: String
    public var enabled: Bool
    public var lastScan: Date?
    public var trackCount: Int

    public init(id: UUID = UUID(), kind: SourceKind, name: String, url: String = "",
                username: String = "", passwordKey: String = "", token: String = "",
                enabled: Bool = true, lastScan: Date? = nil, trackCount: Int = 0) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
        self.username = username
        self.passwordKey = passwordKey.isEmpty ? "awake.\(id.uuidString)" : passwordKey
        self.token = token
        self.enabled = enabled
        self.lastScan = lastScan
        self.trackCount = trackCount
    }

    public var password: String {
        get { Keychain.read(passwordKey) ?? "" }
        set { Keychain.write(newValue, for: passwordKey) }
    }
}

public enum AwakeError: LocalizedError {
    case connection(String)
    case authentication
    case unsupported(String)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .connection(let m): return m
        case .authentication: return "认证失败，请检查账号或令牌"
        case .unsupported(let m): return m
        case .invalidConfiguration(let m): return m
        }
    }
}
