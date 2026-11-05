import Foundation
import AVFoundation
import AudioToolbox

public struct AudioTags {
    public var title = ""
    public var artist = ""
    public var albumArtist = ""
    public var album = ""
    public var genre = ""
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: Double = 0
    public var sampleRate: Int = 44100
    public var bitDepth: Int = 16
    public var channels: Int = 2
    public var codec = "PCM"
    public var artwork: Data?
    public var lyrics: String?
    public init() {}
}

public enum TagReader {
    public static func read(url: URL) async -> AudioTags {
        var tags = AudioTags()
        let ext = url.pathExtension.lowercased()
        tags.codec = codecLabel(ext: ext)

        switch ext {
        case "flac":
            if let parsed = parseFLAC(url) { merge(parsed, into: &tags) }
        case "mp3":
            if let parsed = parseID3(url) { merge(parsed, into: &tags) }
        case "dsf":
            parseDSF(url, into: &tags)
        case "dff":
            parseDFF(url, into: &tags)
        case "ape":
            parseAPE(url, into: &tags)
        default:
            break
        }

        fillAudioProperties(url, ext: ext, into: &tags)

        // AVFoundation 不认识 DSD/APE，跳过无意义的探测。
        let nativeParsed = ext == "dsf" || ext == "dff" || ext == "ape"
        if !nativeParsed, tags.title.isEmpty || tags.artwork == nil || tags.artist.isEmpty {
            await fillFromAVAsset(url, into: &tags)
        }

        if tags.sampleRate == 0 { tags.sampleRate = 44100 }
        if tags.bitDepth == 0 { tags.bitDepth = 16 }
        if tags.channels == 0 { tags.channels = 2 }

        if tags.title.trimmed.isEmpty || tags.artist.trimmed.isEmpty {
            applyFilenameHeuristics(url, into: &tags)
        }
        return tags
    }

    private static func merge(_ other: AudioTags, into tags: inout AudioTags) {
        if !other.title.isEmpty { tags.title = other.title }
        if !other.artist.isEmpty { tags.artist = other.artist }
        if !other.albumArtist.isEmpty { tags.albumArtist = other.albumArtist }
        if !other.album.isEmpty { tags.album = other.album }
        if !other.genre.isEmpty { tags.genre = other.genre }
        if let y = other.year { tags.year = y }
        if let t = other.trackNumber { tags.trackNumber = t }
        if let d = other.discNumber { tags.discNumber = d }
        if other.duration > 0 { tags.duration = other.duration }
        if other.sampleRate > 0 { tags.sampleRate = other.sampleRate }
        if other.bitDepth > 0 { tags.bitDepth = other.bitDepth }
        if other.channels > 0 { tags.channels = other.channels }
        if !other.codec.isEmpty { tags.codec = other.codec }
        if let art = other.artwork { tags.artwork = art }
        if let lyr = other.lyrics, !lyr.trimmed.isEmpty { tags.lyrics = lyr }
    }

    // MARK: - Formats

    private static func codecLabel(ext: String) -> String {
        switch ext {
        case "flac": return "FLAC"
        case "m4a", "alac": return "ALAC"
        case "mp3": return "MP3"
        case "wav": return "WAV"
        case "aiff", "aif": return "AIFF"
        case "dsf", "dff": return "DSD"
        case "ape": return "APE"
        case "wv": return "WavPack"
        case "ogg": return "OGG"
        case "opus": return "Opus"
        default: return ext.uppercased()
        }
    }

    private static func fillAudioProperties(_ url: URL, ext: String, into tags: inout AudioTags) {
        if ext == "dsf" || ext == "dff" || ext == "ape" || ext == "wv" { return }
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr,
              let fid = fileID else { return }
        defer { AudioFileClose(fid) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioFileGetProperty(fid, kAudioFilePropertyDataFormat, &size, &asbd) == noErr {
            if asbd.mSampleRate > 0 { tags.sampleRate = Int(asbd.mSampleRate.rounded()) }
            if asbd.mChannelsPerFrame > 0 { tags.channels = Int(asbd.mChannelsPerFrame) }
        }

        var bitDepth: UInt32 = 0
        var bdSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioFileGetProperty(fid, kAudioFilePropertySourceBitDepth, &bdSize, &bitDepth) == noErr, bitDepth > 0 {
            tags.bitDepth = Int(bitDepth)
        } else if asbd.mBitsPerChannel > 0 {
            tags.bitDepth = Int(asbd.mBitsPerChannel)
        }

        var duration: Double = 0
        var dSize = UInt32(MemoryLayout<Double>.size)
        if AudioFileGetProperty(fid, kAudioFilePropertyEstimatedDuration, &dSize, &duration) == noErr {
            tags.duration = duration
        }

        if ext == "m4a" || ext == "alac" {
            tags.codec = "ALAC"
        } else if ext == "wav" {
            tags.codec = "WAV"
        } else if ext == "aiff" || ext == "aif" {
            tags.codec = "AIFF"
        }
    }

    private static func parseDSF(_ url: URL, into tags: inout AudioTags) {
        guard let fh = try? FileHandle(forReadingFrom: url),
              let header = try? fh.read(upToCount: 92) else { return }
        defer { try? fh.close() }
        guard header.count >= 92, header.prefix(4) == Data("DSD ".utf8) else { return }
        let channels = readUInt32LE(header, at: 52) ?? 0
        let freq = readUInt32LE(header, at: 56) ?? 0
        let bits = readUInt32LE(header, at: 60) ?? 0
        let sampleCount = readUInt64LE(header, at: 64) ?? 0
        if freq > 0 { tags.sampleRate = Int(freq) }
        if channels > 0 { tags.channels = Int(channels) }
        tags.bitDepth = bits > 0 ? Int(bits) : 1
        tags.codec = "DSD"
        if freq > 0, sampleCount > 0 {
            tags.duration = Double(sampleCount) / Double(freq)
        }

        // ID3 元数据块由文件头 20 字节处的绝对偏移指向。
        guard let metadataOffset = readUInt64LE(header, at: 20), metadataOffset > 0 else { return }
        guard let id3Head = readData(fh, at: metadataOffset, count: 10),
              id3Head.count == 10, id3Head.prefix(3) == Data("ID3".utf8) else { return }
        let size = syncSafeSize(id3Head, from: 6)
        let total = 10 + size + ((id3Head[5] & 0x10) != 0 ? 10 : 0)
        guard total > 0, total < 64 * 1024 * 1024,
              let data = readData(fh, at: metadataOffset, count: total),
              let id3 = parseID3Data(data) else { return }
        merge(id3, into: &tags)
        tags.codec = "DSD"
    }

    private static func parseDFF(_ url: URL, into tags: inout AudioTags) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 16), head.count == 16,
              head.prefix(4) == Data("FRM8".utf8),
              String(decoding: head[12..<16], as: UTF8.self) == "DSD " else { return }
        tags.codec = "DSD"
        tags.bitDepth = 1

        let fileSize = (try? fh.seekToEnd()) ?? 0
        var offset: UInt64 = 16
        var sampleRate = 0
        var channels = 0
        var audioBytes: UInt64 = 0
        while offset + 12 <= fileSize {
            try? fh.seek(toOffset: offset)
            guard let chunk = try? fh.read(upToCount: 12), chunk.count == 12 else { break }
            let id = String(decoding: chunk[0..<4], as: UTF8.self)
            let size = readUInt64BE(chunk, at: 4) ?? 0
            let bodyStart = offset + 12
            guard bodyStart <= fileSize, size <= fileSize - bodyStart else { break }
            switch id {
            case "PROP":
                if size <= 8 * 1024 * 1024,
                   let data = readData(fh, at: bodyStart, count: Int(size)), data.count >= 4,
                   data.prefix(4) == Data("SND ".utf8) {
                    parseDFFProperties(data, sampleRate: &sampleRate, channels: &channels)
                }
            case "DSD ", "DST ":
                audioBytes = size
            case "DIIN":
                if size <= 4 * 1024 * 1024,
                   let data = readData(fh, at: bodyStart, count: Int(size)) {
                    parseDFFInfo(data, into: &tags)
                }
            case "ID3 ":
                if size <= 64 * 1024 * 1024,
                   let data = readData(fh, at: bodyStart, count: Int(size)),
                   let id3 = parseID3Data(data) {
                    merge(id3, into: &tags)
                    tags.codec = "DSD"
                }
            default:
                break
            }
            offset = bodyStart + size + (size % 2)
        }
        if sampleRate > 0 { tags.sampleRate = sampleRate }
        if channels > 0 { tags.channels = channels }
        if sampleRate > 0, channels > 0, audioBytes > 0 {
            tags.duration = Double(audioBytes * 8) / (Double(sampleRate) * Double(channels))
        }
    }

    private static func parseDFFProperties(_ data: Data, sampleRate: inout Int, channels: inout Int) {
        var offset = 4
        while offset + 12 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            guard let size = readUInt64BE(data, at: offset + 4),
                  size <= 64 * 1024 * 1024 else { break }
            let start = offset + 12
            guard start + Int(size) <= data.count else { break }
            switch id {
            case "FS  ":
                if let r = readUInt32BE(data, at: start), r > 0 { sampleRate = Int(r) }
            case "CHNL":
                if let c = readUInt16BE(data, at: start), c > 0 { channels = Int(c) }
            default:
                break
            }
            offset = start + Int(size) + (size % 2 == 1 ? 1 : 0)
        }
    }

    private static func parseDFFInfo(_ data: Data, into tags: inout AudioTags) {
        var offset = 0
        while offset + 12 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            guard let size = readUInt64BE(data, at: offset + 4),
                  size <= 4 * 1024 * 1024 else { break }
            let start = offset + 12
            guard start + Int(size) <= data.count else { break }
            let text = String(decoding: data[start..<(start + Int(size))], as: UTF8.self)
                .replacingOccurrences(of: "\0", with: "").trimmed
            switch id {
            case "INAM": if !text.isEmpty { tags.title = text }
            case "IART": if !text.isEmpty { tags.artist = text }
            case "IPRD": if !text.isEmpty { tags.album = text }
            case "ITRK": tags.trackNumber = Int(text.split(separator: "/").first ?? "")
            case "ICMT": if !text.isEmpty, tags.lyrics == nil { tags.lyrics = text }
            default: break
            }
            offset = start + Int(size) + (size % 2 == 1 ? 1 : 0)
        }
    }

    private static func parseAPE(_ url: URL, into tags: inout AudioTags) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        guard fileSize > 64 else { return }
        try? fh.seek(toOffset: 0)
        guard let head = try? fh.read(upToCount: 1024 * 1024), head.count > 64 else { return }
        guard let macRange = head.range(of: Data("MAC ".utf8)) else { return }
        let base = macRange.lowerBound

        // 有些 APE 在文件头带 ID3v2。
        if base > 0, head.prefix(3) == Data("ID3".utf8), let id3 = parseID3Data(head) {
            merge(id3, into: &tags)
            tags.codec = "APE"
        }

        guard base + 34 <= head.count else { return }
        let version = readUInt16LE(head, at: base + 4) ?? 0
        var blocksPerFrame = 0
        var finalBlocks = 0
        var totalFrames = 0
        var bps = 16
        var channels = 2
        var rate = 44100
        let flags: UInt16

        if version >= 3980 {
            let descriptorLength = Int(readUInt32LE(head, at: base + 8) ?? 52)
            let headerStart = base + descriptorLength
            guard headerStart + 24 <= head.count else { return }
            flags = readUInt16LE(head, at: headerStart + 2) ?? 0
            blocksPerFrame = Int(readUInt32LE(head, at: headerStart + 4) ?? 0)
            finalBlocks = Int(readUInt32LE(head, at: headerStart + 8) ?? 0)
            totalFrames = Int(readUInt32LE(head, at: headerStart + 12) ?? 0)
            bps = Int(readUInt16LE(head, at: headerStart + 16) ?? 16)
            channels = Int(readUInt16LE(head, at: headerStart + 18) ?? 2)
            rate = Int(readUInt32LE(head, at: headerStart + 20) ?? 44100)
        } else {
            guard base + 32 <= head.count else { return }
            flags = readUInt16LE(head, at: base + 8) ?? 0
            channels = Int(readUInt16LE(head, at: base + 10) ?? 2)
            rate = Int(readUInt32LE(head, at: base + 12) ?? 44100)
            totalFrames = Int(readUInt32LE(head, at: base + 24) ?? 0)
            finalBlocks = Int(readUInt32LE(head, at: base + 28) ?? 0)
            if version >= 3950 {
                blocksPerFrame = 73728 * 4
            } else if version >= 3900 || (version >= 3800 && (readUInt16LE(head, at: base + 6) ?? 0) >= 4000) {
                blocksPerFrame = 73728
            } else {
                blocksPerFrame = 9216
            }
        }
        if flags & 0x0008 != 0 { bps = 8 }
        else if flags & 0x0020 != 0 { bps = 24 }
        else if version < 3980 { bps = 16 }

        tags.codec = "APE"
        if rate > 0 { tags.sampleRate = rate }
        if channels > 0 { tags.channels = channels }
        if bps > 0 { tags.bitDepth = bps }
        if rate > 0, totalFrames > 0, blocksPerFrame > 0 {
            let samples = Double(totalFrames - 1) * Double(blocksPerFrame) + Double(finalBlocks)
            tags.duration = samples / Double(rate)
        }

        parseAPETag(fh: fh, fileSize: fileSize, into: &tags)
        if tags.title.isEmpty, let id3v1 = parseID3v1(fh: fh, fileSize: fileSize) {
            merge(id3v1, into: &tags)
            tags.codec = "APE"
        }
    }

    private static func parseAPETag(fh: FileHandle, fileSize: UInt64, into tags: inout AudioTags) {
        guard fileSize >= 32 else { return }
        var footerPos = fileSize - 32
        // 末尾可能还有 128 字节 ID3v1。
        if fileSize >= 128 + 32, let tail = readData(fh, at: fileSize - 128, count: 3),
           tail == Data("TAG".utf8) {
            footerPos -= 128
        }
        guard let footer = readData(fh, at: footerPos, count: 32),
              footer.prefix(8) == Data("APETAGEX".utf8),
              let tagSize = readUInt32LE(footer, at: 12),
              let itemCount = readUInt32LE(footer, at: 16),
              let tagFlags = readUInt32LE(footer, at: 20),
              tagSize >= 32, tagSize <= 64 * 1024 * 1024 else { return }
        let start = Int64(footerPos) + 32 - Int64(tagSize)
        guard start >= 0, let data = readData(fh, at: UInt64(start), count: Int(tagSize)) else { return }
        var offset = (tagFlags & 0x8000_0000) != 0 ? 32 : 0
        var parsed = AudioTags()
        parsed.codec = ""
        for _ in 0..<min(Int(itemCount), 4096) {
            guard offset + 8 <= data.count,
                  let valueSize = readUInt32LE(data, at: offset),
                  let itemFlags = readUInt32LE(data, at: offset + 4) else { break }
            offset += 8
            var keyEnd = offset
            while keyEnd < data.count, data[keyEnd] != 0 { keyEnd += 1 }
            guard keyEnd < data.count else { break }
            let key = String(decoding: data[offset..<keyEnd], as: UTF8.self)
            offset = keyEnd + 1
            guard offset + Int(valueSize) <= data.count else { break }
            let value = data.subdata(in: offset..<(offset + Int(valueSize)))
            offset += Int(valueSize)
            applyAPETag(key: key, value: value, flags: itemFlags, into: &parsed)
        }
        merge(parsed, into: &tags)
    }

    private static func applyAPETag(key: String, value: Data, flags: UInt32, into tags: inout AudioTags) {
        let name = key.lowercased()
        if name.hasPrefix("cover art") {
            guard let nul = value.firstIndex(of: 0) else { return }
            let image = value[(nul + 1)...]
            if !image.isEmpty { tags.artwork = Data(image) }
            return
        }
        if flags & 0x0000_0002 != 0 { return } // binary item
        let text = String(decoding: value, as: UTF8.self).trimmed
        guard !text.isEmpty else { return }
        switch name {
        case "title": tags.title = text
        case "artist": tags.artist = text
        case "album artist", "albumartist": tags.albumArtist = text
        case "album": tags.album = text
        case "genre": tags.genre = text
        case "year", "date": tags.year = Int(text.prefix(4))
        case "track": tags.trackNumber = Int(text.split(separator: "/").first ?? "")
        case "disc": tags.discNumber = Int(text.split(separator: "/").first ?? "")
        case "lyrics": tags.lyrics = text
        default: break
        }
    }

    private static func parseID3v1(fh: FileHandle, fileSize: UInt64) -> AudioTags? {
        guard fileSize >= 128, let data = readData(fh, at: fileSize - 128, count: 128),
              data.prefix(3) == Data("TAG".utf8) else { return nil }
        var tags = AudioTags()
        tags.codec = ""
        tags.title = fixedString(data, start: 3, length: 30)
        tags.artist = fixedString(data, start: 33, length: 30)
        tags.album = fixedString(data, start: 63, length: 30)
        tags.year = Int(fixedString(data, start: 93, length: 4).prefix(4))
        if data[125] == 0, data[126] != 0 { tags.trackNumber = Int(data[126]) }
        return tags
    }

    private static func fixedString(_ data: Data, start: Int, length: Int) -> String {
        guard start + length <= data.count else { return "" }
        let slice = data[start..<(start + length)]
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(decoding: slice[slice.startIndex..<end], as: UTF8.self).trimmed
    }

    private static func readData(_ fh: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard count >= 0 else { return nil }
        try? fh.seek(toOffset: offset)
        return try? fh.read(upToCount: count)
    }

    private static func syncSafeSize(_ data: Data, from offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset] & 0x7F) << 21) | (Int(data[offset + 1] & 0x7F) << 14)
            | (Int(data[offset + 2] & 0x7F) << 7) | Int(data[offset + 3] & 0x7F)
    }

    // MARK: - FLAC

    private static func parseFLAC(_ url: URL) -> AudioTags? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let magic = try? fh.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }

        var tags = AudioTags()
        tags.codec = "FLAC"
        var isLast = false

        while !isLast {
            guard let header = try? fh.read(upToCount: 4), header.count == 4 else { break }
            isLast = (header[0] & 0x80) != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard length > 0, length < 64 * 1024 * 1024 else { break }
            guard let block = try? fh.read(upToCount: length), block.count == length else { break }

            switch type {
            case 0:
                parseStreamInfo(block, into: &tags)
            case 4:
                parseVorbisComment(block, into: &tags)
            case 6:
                if let art = parsePicture(block) { tags.artwork = art }
            default:
                break
            }
        }
        return tags
    }

    private static func parseStreamInfo(_ block: Data, into tags: inout AudioTags) {
        guard block.count >= 18 else { return }
        let b10 = UInt32(block[10])
        let b11 = UInt32(block[11])
        let b12 = UInt32(block[12])
        let b13 = UInt32(block[13])
        let sampleRate = Int((b10 << 12) | (b11 << 4) | (b12 >> 4))
        let channels = Int(((b12 >> 1) & 0x07)) + 1
        let bitDepth = Int((((b12 & 0x01) << 4) | (b13 >> 4)) & 0x1F) + 1
        let totalSamples = (UInt64(block[13] & 0x0F) << 32)
            | (UInt64(block[14]) << 24) | (UInt64(block[15]) << 16)
            | (UInt64(block[16]) << 8) | UInt64(block[17])
        if sampleRate > 0 { tags.sampleRate = sampleRate }
        if channels > 0 { tags.channels = channels }
        if bitDepth > 0 { tags.bitDepth = bitDepth }
        if sampleRate > 0, totalSamples > 0 { tags.duration = Double(totalSamples) / Double(sampleRate) }
    }

    private static func parseVorbisComment(_ block: Data, into tags: inout AudioTags) {
        var offset = 0
        guard let vendorLength = readUInt32LE(block, at: offset) else { return }
        offset += 4 + Int(vendorLength)
        guard let count = readUInt32LE(block, at: offset) else { return }
        offset += 4
        for _ in 0..<Int(count) {
            guard let len = readUInt32LE(block, at: offset) else { break }
            offset += 4
            guard offset + Int(len) <= block.count else { break }
            let entry = String(decoding: block[offset..<(offset + Int(len))], as: UTF8.self)
            offset += Int(len)
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[entry.startIndex..<eq]).uppercased()
            let value = String(entry[entry.index(after: eq)...])
            applyTag(key: key, value: value, into: &tags)
        }
    }

    private static func parsePicture(_ block: Data) -> Data? {
        var offset = 0
        guard let mimeLen = readUInt32BE(block, at: 4) else { return nil }
        offset = 8 + Int(mimeLen)
        guard let descLen = readUInt32BE(block, at: offset) else { return nil }
        offset += 4 + Int(descLen)
        offset += 16 // width, height, depth, colors
        guard let dataLen = readUInt32BE(block, at: offset) else { return nil }
        offset += 4
        guard dataLen > 0, offset + Int(dataLen) <= block.count else { return nil }
        return block.subdata(in: offset..<(offset + Int(dataLen)))
    }

    private static func applyTag(key: String, value: String, into tags: inout AudioTags) {
        let v = value.trimmed
        guard !v.isEmpty else { return }
        switch key {
        case "TITLE": tags.title = v
        case "ARTIST": tags.artist = v
        case "ALBUMARTIST", "ALBUM ARTIST", "ENSEMBLE": tags.albumArtist = v
        case "ALBUM": tags.album = v
        case "GENRE": tags.genre = v
        case "DATE", "YEAR": tags.year = Int(v.prefix(4))
        case "TRACKNUMBER": tags.trackNumber = Int(v.split(separator: "/").first ?? "")
        case "DISCNUMBER": tags.discNumber = Int(v.split(separator: "/").first ?? "")
        case "LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS": tags.lyrics = v
        default: break
        }
    }

    // MARK: - ID3

    private static func parseID3(_ url: URL) -> AudioTags? {
        guard let fh = try? FileHandle(forReadingFrom: url),
              let head = try? fh.read(upToCount: 10) else { return nil }
        defer { try? fh.close() }
        guard head.count == 10, head.prefix(3) == Data("ID3".utf8) else { return nil }
        let size = syncSafeSize(head, from: 6)
        guard size > 0, size < 32 * 1024 * 1024,
              let body = try? fh.read(upToCount: size) else { return nil }
        var full = Data(head)
        full.append(body)
        guard var tags = parseID3Data(full) else { return nil }
        tags.codec = "MP3"
        return tags
    }

    /// 解析一个从 ID3v2 头开始的完整数据块（DSF 的元数据区、DFF 的 ID3 chunk 都复用它）。
    private static func parseID3Data(_ data: Data) -> AudioTags? {
        guard data.count >= 10, data.prefix(3) == Data("ID3".utf8) else { return nil }
        let major = data[3]
        let size = syncSafeSize(data, from: 6)
        guard size > 0, size < 32 * 1024 * 1024, 10 + size <= data.count else { return nil }
        let body = data.subdata(in: 10..<(10 + size))
        var tags = AudioTags()
        var offset = 0
        while offset + 10 <= body.count {
            let fid = String(decoding: body[offset..<(offset + 4)], as: UTF8.self)
            if fid.trimmed.isEmpty { break }
            var frameSize = 0
            if major >= 4 {
                frameSize = (Int(body[offset + 4] & 0x7F) << 21) | (Int(body[offset + 5] & 0x7F) << 14)
                    | (Int(body[offset + 6] & 0x7F) << 7) | Int(body[offset + 7] & 0x7F)
            } else {
                frameSize = Int(body[offset + 4]) << 24 | Int(body[offset + 5]) << 16
                    | Int(body[offset + 6]) << 8 | Int(body[offset + 7])
            }
            if frameSize <= 0 || offset + 10 + frameSize > body.count { break }
            let frame = body.subdata(in: (offset + 10)..<(offset + 10 + frameSize))
            handleFrame(id: fid, data: frame, into: &tags)
            offset += 10 + frameSize
        }
        return tags
    }

    private static func handleFrame(id: String, data: Data, into tags: inout AudioTags) {
        switch id {
        case "TIT2": tags.title = decodeText(data)
        case "TPE1": tags.artist = decodeText(data)
        case "TPE2": tags.albumArtist = decodeText(data)
        case "TALB": tags.album = decodeText(data)
        case "TCON": tags.genre = decodeText(data)
        case "TDRC", "TYER": tags.year = Int(decodeText(data).prefix(4))
        case "TRCK": tags.trackNumber = Int(decodeText(data).split(separator: "/").first ?? "")
        case "TPOS": tags.discNumber = Int(decodeText(data).split(separator: "/").first ?? "")
        case "APIC":
            if let art = parseAPIC(data) { tags.artwork = art }
        case "USLT", "SYLT":
            let text = decodeText(data.dropFirst(4))
            if !text.isEmpty { tags.lyrics = text }
        default: break
        }
    }

    private static func decodeText(_ data: Data) -> String {
        guard let first = data.first else { return "" }
        let encoding = first
        let payload = data.dropFirst()
        switch encoding {
        case 0:
            return String(data: payload, encoding: .isoLatin1)?.trimmed ?? ""
        case 1:
            return String(data: payload, encoding: .utf16)?.trimmed ?? ""
        case 2:
            return String(data: payload, encoding: .utf16BigEndian)?.trimmed ?? ""
        default:
            return String(data: payload, encoding: .utf8)?.trimmed ?? ""
        }
    }

    private static func parseAPIC(_ data: Data) -> Data? {
        guard data.count > 4 else { return nil }
        let encoding = data[0]
        var offset = 1
        while offset < data.count, data[offset] != 0 { offset += 1 } // mime
        offset += 1
        offset += 1 // picture type
        if encoding == 1 || encoding == 2 {
            while offset + 1 < data.count, !(data[offset] == 0 && data[offset + 1] == 0) { offset += 2 }
            offset += 2
        } else {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        guard offset < data.count else { return nil }
        return data.subdata(in: offset..<data.count)
    }

    // MARK: - AVAsset fallback

    private static func fillFromAVAsset(_ url: URL, into tags: inout AudioTags) async {
        let asset = AVURLAsset(url: url)
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey?.rawValue else { continue }
                switch key {
                case "title":
                    if tags.title.isEmpty, let v = try? await item.load(.stringValue) { tags.title = v.trimmed }
                case "artist":
                    if tags.artist.isEmpty, let v = try? await item.load(.stringValue) { tags.artist = v.trimmed }
                case "albumName":
                    if tags.album.isEmpty, let v = try? await item.load(.stringValue) { tags.album = v.trimmed }
                case "artwork":
                    if tags.artwork == nil, let d = try? await item.load(.dataValue), !d.isEmpty { tags.artwork = d }
                default:
                    break
                }
            }
        }
        if tags.duration <= 0, let d = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(d)
            if seconds.isFinite, seconds > 0 { tags.duration = seconds }
        }
    }

    // MARK: - Filename heuristics

    private static func applyFilenameHeuristics(_ url: URL, into tags: inout AudioTags) {
        var name = url.deletingPathExtension().lastPathComponent.trimmed
        name = name.replacingOccurrences(of: "_", with: " ")
        if tags.title.isEmpty {
            if let range = name.range(of: " - ") {
                let left = String(name[name.startIndex..<range.lowerBound]).trimmed
                let right = String(name[range.upperBound...]).trimmed
                if tags.artist.isEmpty, !left.isEmpty, !right.isEmpty {
                    tags.artist = left
                    tags.title = right
                } else {
                    tags.title = right.isEmpty ? name : right
                }
            } else {
                tags.title = name
            }
        }
        if tags.album.isEmpty {
            tags.album = url.deletingLastPathComponent().lastPathComponent
        }
        if tags.artist.isEmpty { tags.artist = "未知艺人" }
        if tags.albumArtist.isEmpty { tags.albumArtist = tags.artist }
    }

    // MARK: - Byte helpers

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for i in (0..<8).reversed() {
            value = (value << 8) | UInt64(data[offset + i])
        }
        return value
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(data[offset + i])
        }
        return value
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
}
