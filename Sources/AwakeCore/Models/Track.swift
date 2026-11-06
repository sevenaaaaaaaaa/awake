import Foundation
import CryptoKit

public struct Track: Identifiable, Codable, Hashable {
    public var id: String
    public var title: String
    public var artist: String
    public var albumArtist: String
    public var album: String
    public var genre: String
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: Double
    public var sampleRate: Int
    public var bitDepth: Int
    public var channels: Int
    public var codec: String
    public var sourceID: UUID
    /// Path relative to the source root for local kinds, provider key for remote kinds.
    public var locator: String
    public var fileSize: Int64
    public var modified: Date
    public var artworkPath: String?
    public var playCount: Int
    public var favorite: Bool
    public var lastPlayed: Date?
    public var addedAt: Date
    public var isRemote: Bool

    public init(id: String = UUID().uuidString,
                title: String, artist: String = "", albumArtist: String = "",
                album: String = "", genre: String = "", year: Int? = nil,
                trackNumber: Int? = nil, discNumber: Int? = nil,
                duration: Double = 0, sampleRate: Int = 44100, bitDepth: Int = 16,
                channels: Int = 2, codec: String = "", sourceID: UUID,
                locator: String, fileSize: Int64 = 0, modified: Date = Date(),
                artworkPath: String? = nil, playCount: Int = 0, favorite: Bool = false,
                lastPlayed: Date? = nil, addedAt: Date = Date(), isRemote: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist.isEmpty ? artist : albumArtist
        self.album = album
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.codec = codec
        self.sourceID = sourceID
        self.locator = locator
        self.fileSize = fileSize
        self.modified = modified
        self.artworkPath = artworkPath
        self.playCount = playCount
        self.favorite = favorite
        self.lastPlayed = lastPlayed
        self.addedAt = addedAt
        self.isRemote = isRemote
    }

    public var albumKey: String { "\((albumArtist.isEmpty ? artist : albumArtist).lowercased())|\(album.lowercased())" }

    public var qualityLabel: String {
        guard sampleRate > 0 else { return codec.isEmpty ? "待解析" : "\(codec) 待解析" }
        if codec.uppercased() == "DSD" {
            let multiple = Int((Double(sampleRate) / 44100.0).rounded())
            let mhz = String(format: "%.1f", Double(sampleRate) / 1_000_000.0)
            var label = multiple > 0 ? "DSD\(multiple) 1-bit/\(mhz) MHz" : "DSD 1-bit/\(mhz) MHz"
            if channels > 2 { label += " \(channels)ch" }
            return label
        }
        let khz = sampleRate >= 1000 ? String(format: "%.1f", Double(sampleRate) / 1000.0) : "\(sampleRate)"
        var label = "\(codec.isEmpty ? "PCM" : codec) \(bitDepth)-bit / \(khz) kHz"
        if channels > 2 { label += " \(channels)ch" }
        return label
    }

    public var isHiRes: Bool { sampleRate > 48000 || bitDepth > 16 }

    public static func makeID(sourceID: UUID, locator: String) -> String {
        (sourceID.uuidString + "|" + locator).sha256Short
    }

    /// 远程曲目首次落盘后用真实标签补齐元数据（文件名建的条目只是占位）。
    public func applying(_ tags: AudioTags) -> Track {
        var track = self
        if !tags.title.trimmed.isEmpty { track.title = tags.title.trimmed }
        if !tags.artist.trimmed.isEmpty { track.artist = tags.artist.trimmed }
        if !tags.albumArtist.trimmed.isEmpty { track.albumArtist = tags.albumArtist.trimmed }
        else if !tags.artist.trimmed.isEmpty { track.albumArtist = tags.artist.trimmed }
        if !tags.album.trimmed.isEmpty { track.album = tags.album.trimmed }
        if !tags.genre.trimmed.isEmpty { track.genre = tags.genre.trimmed }
        track.year = tags.year ?? track.year
        track.trackNumber = tags.trackNumber ?? track.trackNumber
        track.discNumber = tags.discNumber ?? track.discNumber
        if tags.duration > 0 { track.duration = tags.duration }
        if tags.sampleRate > 0 { track.sampleRate = tags.sampleRate }
        if tags.bitDepth > 0 { track.bitDepth = tags.bitDepth }
        if tags.channels > 0 { track.channels = tags.channels }
        if !tags.codec.isEmpty { track.codec = tags.codec }
        return track
    }
}

public struct Album: Identifiable, Hashable {
    public var id: String
    public var title: String
    public var artist: String
    public var year: Int?
    public var artworkPath: String?
    public var tracks: [Track]

    public init(id: String, title: String, artist: String, year: Int?, artworkPath: String?, tracks: [Track]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.year = year
        self.artworkPath = artworkPath
        self.tracks = tracks
    }

    public var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
    public var isHiRes: Bool { tracks.contains { $0.isHiRes } }
}

public extension Array where Element == Track {
    func sortedForAlbum() -> [Track] {
        sorted { a, b in
            if (a.discNumber ?? 1) != (b.discNumber ?? 1) { return (a.discNumber ?? 1) < (b.discNumber ?? 1) }
            if (a.trackNumber ?? 0) != (b.trackNumber ?? 0) { return (a.trackNumber ?? 0) < (b.trackNumber ?? 0) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    var albums: [Album] {
        var buckets: [String: [Track]] = [:]
        for t in self { buckets[t.albumKey, default: []].append(t) }
        return buckets.map { key, tracks in
            let sorted = tracks.sortedForAlbum()
            let first = sorted.first!
            return Album(id: key,
                         title: first.album.isEmpty ? "未命名专辑" : first.album,
                         artist: first.albumArtist,
                         year: first.year,
                         artworkPath: sorted.first(where: { $0.artworkPath != nil })?.artworkPath,
                         tracks: sorted)
        }
        .sorted { ($0.artist, $0.title) < ($1.artist, $1.title) }
    }
}
