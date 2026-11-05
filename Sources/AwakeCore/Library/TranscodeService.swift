import Foundation
import AVFoundation

public struct ResolvedStream: Sendable {
    public let url: URL
    public let sourceURL: URL
    public let wasTranscoded: Bool

    public init(url: URL, sourceURL: URL, wasTranscoded: Bool) {
        self.url = url
        self.sourceURL = sourceURL
        self.wasTranscoded = wasTranscoded
    }
}

public enum TranscodeError: LocalizedError {
    case ffmpegMissing
    case processFailed(String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            return "播放 DSD / APE 需要 ffmpeg。当前 Mac 未找到 ffmpeg，请安装后重试。"
        case .processFailed(let detail):
            let tail = detail.trimmed.isEmpty ? "未知错误" : detail.trimmed
            return "音频转换失败：\(tail)"
        case .invalidOutput(let detail):
            return "音频转换结果不可播放：\(detail)"
        }
    }
}

/// Converts formats AVFoundation cannot open (DSD / APE / WavPack) into a
/// lossless FLAC cache that the rest of Awake can treat like any other track.
public actor TranscodeService {
    public static let shared = TranscodeService()
    public static let transcodeExtensions: Set<String> = ["dsf", "dff", "ape", "wv"]

    private var inflight: [String: Task<ResolvedStream, Error>] = [:]

    public init() {}

    public nonisolated static func requiresTranscode(_ url: URL) -> Bool {
        transcodeExtensions.contains(url.pathExtension.lowercased())
    }

    /// Returns a playable URL. For native formats this is the source itself;
    /// for DSD / APE / WavPack it is a validated FLAC in the transcode cache.
    public func prepare(track: Track, sourceURL: URL) async throws -> ResolvedStream {
        guard Self.requiresTranscode(sourceURL) else {
            return ResolvedStream(url: sourceURL, sourceURL: sourceURL, wasTranscoded: false)
        }
        if let cached = Self.validCachedStream(track: track, sourceURL: sourceURL) {
            return cached
        }
        if let running = inflight[track.id] {
            return try await running.value
        }

        let task = Task<ResolvedStream, Error> {
            try await Self.convert(track: track, sourceURL: sourceURL)
        }
        inflight[track.id] = task
        do {
            let result = try await task.value
            inflight[track.id] = nil
            return result
        } catch {
            inflight[track.id] = nil
            throw error
        }
    }

    public func clearCache() {
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
        try? FileManager.default.removeItem(at: AwakePaths.transcodeCache)
        try? FileManager.default.createDirectory(at: AwakePaths.transcodeCache, withIntermediateDirectories: true)
    }

    // MARK: - Cache

    private static func validCachedStream(track: Track, sourceURL: URL) -> ResolvedStream? {
        let target = AwakePaths.transcodeFile(for: track.id)
        let recordURL = AwakePaths.transcodeRecordFile(for: track.id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path),
              let outputSize = fileSize(target), outputSize > 0,
              let record = JSONFile.read(TranscodeRecord.self, at: recordURL),
              record.outputSize == outputSize else { return nil }

        guard let sourceSize = fileSize(sourceURL) else { return nil }
        if record.sourceSize > 0, sourceSize != record.sourceSize { return nil }
        if let sourceModified = modificationDate(sourceURL),
           abs(sourceModified.timeIntervalSince1970 - record.sourceModified) > 1,
           record.sourceSize <= 0 {
            return nil
        }
        return ResolvedStream(url: target, sourceURL: sourceURL, wasTranscoded: true)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    private static func modificationDate(_ url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    // MARK: - Conversion

    private struct TranscodeRecord: Codable {
        var sourceSize: Int64
        var sourceModified: TimeInterval
        var outputSize: Int64
        var sampleRate: Int
        var channels: Int
        var sourceFormat: String
        var createdAt: Date
    }

    private static func convert(track: Track, sourceURL: URL) async throws -> ResolvedStream {
        try Task.checkCancellation()
        guard let ffmpeg = ffmpegExecutable() else { throw TranscodeError.ffmpegMissing }

        let ext = sourceURL.pathExtension.lowercased()
        let tags = await TagReader.read(url: sourceURL)
        let isDSD = ext == "dsf" || ext == "dff"

        let sourceRate = tags.sampleRate > 0 ? tags.sampleRate : track.sampleRate
        let channels = max(1, tags.channels > 0 ? tags.channels : track.channels)
        let bitDepth = max(1, tags.bitDepth > 0 ? tags.bitDepth : track.bitDepth)

        // DSD carries 1-bit samples at 2.8224 MHz and up. 176.4 kHz keeps the
        // whole audio band while halving cache size versus a 352.8 kHz dump.
        let outputRate = isDSD ? 176_400 : max(8_000, sourceRate)
        let outputDepth = isDSD ? 24 : (bitDepth > 16 ? 24 : 16)
        let outputSampleFormat = outputDepth > 16 ? "s32" : "s16"

        AwakePaths.ensure()
        let target = AwakePaths.transcodeFile(for: track.id)
        let recordURL = AwakePaths.transcodeRecordFile(for: track.id)
        let temp = AwakePaths.transcodeCache.appendingPathComponent("\(track.id).\(UUID().uuidString).tmp.flac")

        // ffmpeg 没有 DSDIFF 解复用器，先把未压缩 DFF 重封装成 DSF 容器。
        var inputURL = sourceURL
        var temporaryDFF: URL?
        if ext == "dff" {
            let dsf = AwakePaths.transcodeCache.appendingPathComponent("\(track.id).\(UUID().uuidString).tmp.dsf")
            do {
                try DFFToDSF.repackage(sourceURL, to: dsf)
                inputURL = dsf
                temporaryDFF = dsf
            } catch {
                try? FileManager.default.removeItem(at: dsf)
                throw error
            }
        }
        defer {
            if let temporaryDFF { try? FileManager.default.removeItem(at: temporaryDFF) }
        }

        var args: [String] = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", inputURL.path,
            "-map", "0:a:0", "-vn"
        ]

        if isDSD {
            // Remove DSD's ultrasonic noise-shaping before resampling, then use
            // the SoX resampler for a clean, high-precision PCM conversion.
            let cutoff = sourceRate >= 5_600_000 ? 50_000 : 30_000
            args += [
                // 不用 aresample=soxr：部分 Homebrew ffmpeg 未编入 soxr，
                // 默认 swr 在 176.4 kHz/24-bit 下已经足够干净。
                "-af", "lowpass=f=\(cutoff)",
                "-ar", "\(outputRate)",
                "-sample_fmt", outputSampleFormat,
                "-bits_per_raw_sample", "\(outputDepth)",
                "-c:a", "flac", "-compression_level", "6",
                "-f", "flac", temp.path
            ]
        } else {
            args += [
                "-ar", "\(outputRate)",
                "-sample_fmt", outputSampleFormat,
                "-bits_per_raw_sample", "\(outputDepth)",
                "-c:a", "flac", "-compression_level", "6",
                "-f", "flac", temp.path
            ]
        }

        do {
            try run(ffmpeg: ffmpeg, arguments: args)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        try Task.checkCancellation()

        do {
            let file = try AVAudioFile(forReading: temp)
            guard file.length > 0, file.processingFormat.channelCount > 0 else {
                throw TranscodeError.invalidOutput("没有可播放的音频帧")
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)

            let sourceSize = fileSize(sourceURL) ?? 0
            let sourceModified = modificationDate(sourceURL)?.timeIntervalSince1970 ?? 0
            let outputSize = fileSize(target) ?? 0
            let record = TranscodeRecord(sourceSize: sourceSize,
                                         sourceModified: sourceModified,
                                         outputSize: outputSize,
                                         sampleRate: Int(file.processingFormat.sampleRate.rounded()),
                                         channels: Int(file.processingFormat.channelCount),
                                         sourceFormat: ext,
                                         createdAt: Date())
            JSONFile.write(record, to: recordURL)
            return ResolvedStream(url: target, sourceURL: sourceURL, wasTranscoded: true)
        } catch let error as TranscodeError {
            try? FileManager.default.removeItem(at: temp)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TranscodeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - ffmpeg

    public static func ffmpegExecutable() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["AWAKE_FFMPEG"], !override.isEmpty {
            candidates.append(override)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("bin/ffmpeg").path)
        }
        candidates += [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                candidates.append(String(dir) + "/ffmpeg")
            }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    private static func run(ffmpeg: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw TranscodeError.processFailed(error.localizedDescription)
        }

        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let log = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let lines = log.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw TranscodeError.processFailed(lines)
        }
    }
}
