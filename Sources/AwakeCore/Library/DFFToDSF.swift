import Foundation

/// DSDIFF (.dff) is not supported by ffmpeg, but its uncompressed audio payload
/// is the same 1-bit stream as DSF. Repackaging it into a DSF container lets the
/// existing ffmpeg DSF decoder do the conversion with no quality loss.
enum DFFToDSF {
    struct Info {
        let sampleRate: Int
        let channels: Int
        let audioOffset: UInt64
        let audioSize: UInt64
        let isDST: Bool
    }

    enum RepackError: LocalizedError {
        case invalidFile(String)
        case dstCompressed

        var errorDescription: String? {
            switch self {
            case .invalidFile(let detail):
                return "无法读取 DFF 文件：\(detail)"
            case .dstCompressed:
                return "这个 DFF 使用 DST 压缩，Awake 暂时无法直接转换。请导出为未压缩 DFF 或 DSF。"
            }
        }
    }

    static func inspect(_ url: URL) throws -> Info {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            throw RepackError.invalidFile("文件不可读")
        }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        guard fileSize >= 16 else { throw RepackError.invalidFile("文件过短") }
        try? fh.seek(toOffset: 0)
        guard let head = try? fh.read(upToCount: 16), head.count == 16,
              head.prefix(4) == Data("FRM8".utf8),
              String(decoding: head[12..<16], as: UTF8.self) == "DSD " else {
            throw RepackError.invalidFile("不是 DSDIFF（FRM8/DSD）文件")
        }

        var offset: UInt64 = 16
        var sampleRate = 0
        var channels = 0
        var audioOffset: UInt64 = 0
        var audioSize: UInt64 = 0
        var isDST = false

        while offset + 12 <= fileSize {
            try? fh.seek(toOffset: offset)
            guard let chunk = try? fh.read(upToCount: 12), chunk.count == 12 else { break }
            let id = String(decoding: chunk[0..<4], as: UTF8.self)
            guard let size = readUInt64BE(chunk, at: 4) else { break }
            let body = offset + 12
            guard body <= fileSize, size <= fileSize - body else { break }

            switch id {
            case "PROP":
                if size <= 8 * 1024 * 1024,
                   let data = read(fh, at: body, count: Int(size)), data.count >= 4,
                   data.prefix(4) == Data("SND ".utf8) {
                    parseProperties(data, sampleRate: &sampleRate, channels: &channels, isDST: &isDST)
                }
            case "DSD ":
                audioOffset = body
                audioSize = size
            case "DST ":
                isDST = true
                audioOffset = body
                audioSize = size
            default:
                break
            }
            offset = body + size + (size % 2)
        }

        guard sampleRate > 0, channels > 0 else {
            throw RepackError.invalidFile("缺少采样率或声道信息")
        }
        guard audioSize > 0 else { throw RepackError.invalidFile("缺少 DSD 音频数据") }
        return Info(sampleRate: sampleRate, channels: channels,
                    audioOffset: audioOffset, audioSize: audioSize, isDST: isDST)
    }

    static func repackage(_ source: URL, to destination: URL) throws {
        let info = try inspect(source)
        guard !info.isDST else { throw RepackError.dstCompressed }
        guard info.audioSize % UInt64(info.channels) == 0 else {
            throw RepackError.invalidFile("音频字节数不能被声道数整除")
        }

        let sampleCount = info.audioSize * 8 / UInt64(info.channels)
        let totalSize = UInt64(92) + info.audioSize
        var header = Data()
        header.append(Data("DSD ".utf8))
        appendLE(28, to: &header)
        appendLE(totalSize, to: &header)
        appendLE(UInt64(0), to: &header)
        header.append(Data("fmt ".utf8))
        appendLE(52, to: &header)
        appendLE(UInt32(1), to: &header) // format version
        appendLE(UInt32(0), to: &header) // format id: DSD raw
        appendLE(channelType(info.channels), to: &header)
        appendLE(UInt32(info.channels), to: &header)
        appendLE(UInt32(info.sampleRate), to: &header)
        appendLE(UInt32(1), to: &header) // bits per sample
        appendLE(sampleCount, to: &header)
        appendLE(UInt32(4096), to: &header) // block size per channel
        appendLE(UInt32(0), to: &header)
        header.append(Data("data".utf8))
        appendLE(info.audioSize, to: &header)

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: header) else {
            throw RepackError.invalidFile("无法写入临时文件")
        }
        guard let input = try? FileHandle(forReadingFrom: source),
              let output = try? FileHandle(forWritingTo: destination) else {
            throw RepackError.invalidFile("无法打开文件")
        }
        defer { try? input.close(); try? output.close() }
        try? output.seekToEnd()
        try? input.seek(toOffset: info.audioOffset)

        var remaining = info.audioSize
        while remaining > 0 {
            if Task.isCancelled { throw CancellationError() }
            let want = Int(min(remaining, 1024 * 1024))
            guard let chunk = try? input.read(upToCount: want), !chunk.isEmpty else {
                throw RepackError.invalidFile("音频数据意外结束")
            }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
    }

    private static func parseProperties(_ data: Data, sampleRate: inout Int,
                                        channels: inout Int, isDST: inout Bool) {
        var offset = 4
        while offset + 12 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            guard let size = readUInt64BE(data, at: offset + 4),
                  size <= 8 * 1024 * 1024 else { break }
            let start = offset + 12
            guard start + Int(size) <= data.count else { break }
            switch id {
            case "FS  ":
                if let r = readUInt32BE(data, at: start), r > 0 { sampleRate = Int(r) }
            case "CHNL":
                if let c = readUInt16BE(data, at: start), c > 0 { channels = Int(c) }
            case "CMPR":
                if size >= 4, String(decoding: data[start..<(start + 4)], as: UTF8.self) == "DST " {
                    isDST = true
                }
            default:
                break
            }
            offset = start + Int(size) + (size % 2 == 1 ? 1 : 0)
        }
    }

    private static func channelType(_ channels: Int) -> UInt32 {
        switch channels {
        case 1: return 1
        case 2: return 2
        case 3: return 3
        case 4: return 4
        case 5: return 5
        case 6: return 7
        default: return 0
        }
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        data.append(Data(bytes: &little, count: MemoryLayout<T>.size))
    }

    private static func read(_ fh: FileHandle, at offset: UInt64, count: Int) -> Data? {
        try? fh.seek(toOffset: offset)
        return try? fh.read(upToCount: count)
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(data[offset + i]) }
        return value
    }
}
