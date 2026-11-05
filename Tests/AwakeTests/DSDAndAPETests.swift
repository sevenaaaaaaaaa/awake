import XCTest
import AVFoundation
@testable import AwakeCore

final class DSDAndAPETests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    func testDSFTagsAndDuration() async {
        let tags = await TagReader.read(url: fixtures.appendingPathComponent("sample.dsf"))
        XCTAssertEqual(tags.codec, "DSD")
        XCTAssertEqual(tags.sampleRate, 2_822_400)
        XCTAssertEqual(tags.channels, 2)
        XCTAssertEqual(tags.bitDepth, 1)
        XCTAssertEqual(tags.duration, 1.0, accuracy: 0.01)
    }

    func testDFFTagsAndDuration() async {
        let tags = await TagReader.read(url: fixtures.appendingPathComponent("sample.dff"))
        XCTAssertEqual(tags.codec, "DSD")
        XCTAssertEqual(tags.sampleRate, 2_822_400)
        XCTAssertEqual(tags.channels, 2)
        XCTAssertEqual(tags.duration, 1.0, accuracy: 0.01)
        XCTAssertEqual(tags.title, "Awake DSD Test")
        XCTAssertEqual(tags.artist, "Awake Lab")
    }

    func testDFFRepackageProducesReadableDSF() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("awake-\(UUID().uuidString).dsf")
        defer { try? FileManager.default.removeItem(at: temp) }
        try DFFToDSF.repackage(fixtures.appendingPathComponent("sample.dff"), to: temp)
        let tags = await TagReader.read(url: temp)
        XCTAssertEqual(tags.codec, "DSD")
        XCTAssertEqual(tags.sampleRate, 2_822_400)
        XCTAssertEqual(tags.channels, 2)
        XCTAssertEqual(tags.duration, 1.0, accuracy: 0.01)
        let attrs = try FileManager.default.attributesOfItem(atPath: temp.path)
        XCTAssertEqual(attrs[.size] as? Int, 705_692)
    }

    func testDFFTranscodeToPlayableFLAC() async throws {
        guard TranscodeService.ffmpegExecutable() != nil else {
            throw XCTSkip("ffmpeg 未安装")
        }
        let track = Track(title: "Awake DSD Test", sourceID: UUID(), locator: "sample.dff")
        let source = fixtures.appendingPathComponent("sample.dff")
        let stream = try await TranscodeService.shared.prepare(track: track, sourceURL: source)
        defer {
            try? FileManager.default.removeItem(at: stream.url)
            try? FileManager.default.removeItem(at: AwakePaths.transcodeRecordFile(for: track.id))
        }
        XCTAssertTrue(stream.wasTranscoded)
        let file = try AVAudioFile(forReading: stream.url)
        XCTAssertEqual(Int(file.processingFormat.sampleRate.rounded()), 176_400)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertGreaterThan(file.length, 0)
    }

    func testAPETagsAndTranscodeWhenSampleAvailable() async throws {
        let path = ProcessInfo.processInfo.environment["AWAKE_APE_SAMPLE"] ?? "/tmp/awakefmt/sample.ape"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("未提供 APE 样本")
        }
        let source = URL(fileURLWithPath: path)
        let tags = await TagReader.read(url: source)
        XCTAssertEqual(tags.codec, "APE")
        XCTAssertEqual(tags.sampleRate, 44_100)
        XCTAssertEqual(tags.channels, 2)
        XCTAssertEqual(tags.bitDepth, 16)
        XCTAssertEqual(tags.duration, 60.48, accuracy: 0.05)

        guard TranscodeService.ffmpegExecutable() != nil else {
            throw XCTSkip("ffmpeg 未安装")
        }
        let track = Track(title: tags.title, sourceID: UUID(), locator: path)
        let stream = try await TranscodeService.shared.prepare(track: track, sourceURL: source)
        defer {
            try? FileManager.default.removeItem(at: stream.url)
            try? FileManager.default.removeItem(at: AwakePaths.transcodeRecordFile(for: track.id))
        }
        let file = try AVAudioFile(forReading: stream.url)
        XCTAssertEqual(Int(file.processingFormat.sampleRate.rounded()), 44_100)
        XCTAssertGreaterThan(file.length, 0)
    }

    func testScannerKeepsNestedLocatorsUnderSymlinkedRoot() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("awake-scan-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("album", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.copyItem(at: fixtures.appendingPathComponent("sample.dsf"),
                        to: nested.appendingPathComponent("sample.dsf"))

        let scanner = LibraryScanner()
        let scanRoot = URL(fileURLWithPath: root.path)
        let tracks = await scanner.scan(root: scanRoot, sourceID: UUID(), existing: [:], progress: { _, _ in })
        guard let track = tracks.first else { return XCTFail("扫描没有返回曲目") }
        XCTAssertEqual(track.locator, "album/sample.dsf")

        let source = MediaSource(kind: .local, name: "test", url: scanRoot.path)
        let playable = try await LocalMusicProvider().playbackURL(for: track, source: source)
        XCTAssertTrue(fm.fileExists(atPath: playable.path), "playbackURL 必须能还原到真实文件：\(playable.path)")
    }
}
