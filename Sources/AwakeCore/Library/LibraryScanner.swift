import Foundation
import AppKit

public final class LibraryScanner {
    public static let audioExtensions: Set<String> = [
        "flac", "m4a", "alac", "mp3", "aiff", "aif", "wav", "dsf", "dff",
        "ape", "wv", "ogg", "opus", "m4b", "aac"
    ]

    public init() {}

    public func scan(root: URL,
                     sourceID: UUID,
                     existing: [String: Track],
                     progress: @escaping (Int, String) -> Void) async -> [Track] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            candidates.append(url)
        }

        // Album-level artwork sidecars help when individual files carry no embedded art.
        var folderArtwork: [String: URL] = [:]
        for url in candidates {
            let dir = url.deletingLastPathComponent().path
            if folderArtwork[dir] != nil { continue }
            for name in ["cover", "folder", "front", "album", "artwork"] {
                for ext in ["jpg", "jpeg", "png", "webp"] {
                    let candidate = url.deletingLastPathComponent().appendingPathComponent("\(name).\(ext)")
                    if fm.fileExists(atPath: candidate.path) { folderArtwork[dir] = candidate; break }
                }
                if folderArtwork[dir] != nil { break }
            }
        }

        var tracks: [Track] = []
        tracks.reserveCapacity(candidates.count)
        // 用解析软链接后的路径做前缀：/tmp → /private/tmp 这类符号链接会让
        // enumerator 返回的 URL 与 root 字面量不一致，locator 退化成文件名并产生冲突。
        let resolvedRootPath = root.resolvingSymlinksInPath().path
        let rootPrefix = resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/"

        for (index, url) in candidates.enumerated() {
            let resolvedPath = url.resolvingSymlinksInPath().path
            let locator = resolvedPath.hasPrefix(rootPrefix) ? String(resolvedPath.dropFirst(rootPrefix.count)) : url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? Date.distantPast

            if let cached = existing[locator], cached.fileSize == size,
               abs(cached.modified.timeIntervalSince(modified)) < 1 {
                tracks.append(cached)
                if index % 25 == 0 { progress(index, cached.title) }
                continue
            }

            let tags = await TagReader.read(url: url)
            let id = Track.makeID(sourceID: sourceID, locator: locator)
            var artworkPath: String?
            if let data = tags.artwork, !data.isEmpty {
                artworkPath = Self.persistArtwork(data, id: id)
            } else if let folder = folderArtwork[url.deletingLastPathComponent().path] {
                artworkPath = folder.path
            }

            let track = Track(
                id: id,
                title: tags.title,
                artist: tags.artist,
                albumArtist: tags.albumArtist,
                album: tags.album,
                genre: tags.genre,
                year: tags.year,
                trackNumber: tags.trackNumber,
                discNumber: tags.discNumber,
                duration: tags.duration,
                sampleRate: tags.sampleRate,
                bitDepth: tags.bitDepth,
                channels: tags.channels,
                codec: tags.codec,
                sourceID: sourceID,
                locator: locator,
                fileSize: size,
                modified: modified,
                artworkPath: artworkPath,
                playCount: existing[locator]?.playCount ?? 0,
                favorite: existing[locator]?.favorite ?? false,
                lastPlayed: existing[locator]?.lastPlayed,
                addedAt: existing[locator]?.addedAt ?? Date()
            )
            tracks.append(track)
            if index % 10 == 0 || index == candidates.count - 1 {
                progress(index + 1, track.title)
            }
        }

        // Propagate album artwork to sibling tracks so the grid looks coherent.
        var albumArt: [String: String] = [:]
        for t in tracks where t.artworkPath != nil {
            albumArt[t.albumKey] = t.artworkPath
        }
        for i in tracks.indices where tracks[i].artworkPath == nil {
            if let art = albumArt[tracks[i].albumKey] { tracks[i].artworkPath = art }
        }
        return tracks
    }

    public static func persistArtwork(_ data: Data, id: String) -> String? {
        AwakePaths.ensure()
        let target = AwakePaths.artworkFile(for: id)
        if let image = NSImage(data: data) {
            let resized = image.resized(maxDimension: 1200)
            if let tiff = resized.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) {
                try? jpeg.write(to: target)
                return target.path
            }
        }
        if (try? data.write(to: target)) != nil { return target.path }
        return nil
    }
}

public extension NSImage {
    func resized(maxDimension: CGFloat) -> NSImage {
        let w = size.width, h = size.height
        guard max(w, h) > maxDimension, w > 0, h > 0 else { return self }
        let scale = maxDimension / max(w, h)
        let newSize = NSSize(width: w * scale, height: h * scale)
        let image = NSImage(size: newSize)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1)
        image.unlockFocus()
        return image
    }
}
