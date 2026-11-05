import XCTest
@testable import AwakeCore

final class MetadataTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AwakeMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempHome = url
        setenv("AWAKE_HOME", url.path, 1)
        XCTAssertTrue(AwakePaths.ensure())
    }

    override func tearDownWithError() throws {
        unsetenv("AWAKE_HOME")
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        tempHome = nil
        try super.tearDownWithError()
    }

    // MARK: - LRC parsing

    func testParseSyncedLRC() {
        let text = """
        [ti:Test Song]
        [ar:Artist]
        [al:Album]
        [00:01.50]First line
        [00:03.00]Second line
        """
        let lines = LRCParser.parse(text)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "First line")
        XCTAssertEqual(lines[0].time ?? -1, 1.5, accuracy: 0.001)
        XCTAssertEqual(lines[1].text, "Second line")
        XCTAssertEqual(lines[1].time ?? -1, 3.0, accuracy: 0.001)
        XCTAssertTrue(LRCParser.isSynced(text))
    }

    func testMultipleTimestampsOnOneLine() {
        let lines = LRCParser.parse("[00:10.00][01:20.50]Chorus")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.text), ["Chorus", "Chorus"])
        XCTAssertEqual(lines[0].time ?? -1, 10.0, accuracy: 0.001)
        XCTAssertEqual(lines[1].time ?? -1, 80.5, accuracy: 0.001)
    }

    func testTimestampFractionPrecision() {
        let lines = LRCParser.parse("[00:01]a\n[00:02.5]b\n[00:03.25]c\n[00:04.125]d")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].time ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(lines[1].time ?? -1, 2.5, accuracy: 0.0001)
        XCTAssertEqual(lines[2].time ?? -1, 3.25, accuracy: 0.0001)
        XCTAssertEqual(lines[3].time ?? -1, 4.125, accuracy: 0.0001)
    }

    func testUnsynchronizedPlainText() {
        let text = "[ti:Title]\nFirst line\n\nSecond line\n[Verse]\n"
        let lines = LRCParser.parse(text)
        XCTAssertEqual(lines.map(\.text), ["First line", "Second line", "[Verse]"])
        XCTAssertTrue(lines.allSatisfy { $0.time == nil })
        XCTAssertFalse(LRCParser.isSynced(text))
    }

    func testOutOfOrderTimestampsAreSorted() {
        let lines = LRCParser.parse("[00:05.00]B\n[00:01.00]A")
        XCTAssertEqual(lines.map(\.text), ["A", "B"])
    }

    func testMetadataOnlyPayloadHasNoLines() {
        XCTAssertTrue(LRCParser.parse("[ti:Title]\n[ar:Artist]\n[offset:+200]").isEmpty)
        XCTAssertFalse(LRCParser.isSynced("[ti:Title]"))
    }

    func testLyricsDocumentPlainIsDerived() {
        let document = LyricsDocument(
            lines: [LyricsLine(time: 1, text: "a"), LyricsLine(time: nil, text: "b")],
            isSynced: true,
            source: "测试"
        )
        XCTAssertEqual(document.plain, "a\nb")
    }

    // MARK: - Cache paths

    func testCachePathsFollowAwakePaths() {
        XCTAssertTrue(AwakePaths.lyricsCache.path.hasPrefix(tempHome.path))

        let lyricsURL = LyricsService.cacheURL(for: "track-id")
        XCTAssertEqual(lyricsURL.deletingLastPathComponent().path, AwakePaths.lyricsCache.path)
        XCTAssertEqual(lyricsURL.lastPathComponent, "track-id.json")

        let lines = ["one", "two"]
        let translationURL = TranslationService.cacheURL(lines: lines, target: "zh-CN")
        XCTAssertEqual(translationURL.deletingLastPathComponent().path, AwakePaths.translationCache.path)
        let expectedHash = lines.joined(separator: "\n").sha256Short
        XCTAssertEqual(translationURL.lastPathComponent, "\(expectedHash)-zh-cn.json")

        XCTAssertEqual(AwakePaths.artworkFile(for: "track-id").lastPathComponent, "track-id.jpg")
        XCTAssertEqual(ArtworkService.cacheURL(for: "track-id").path,
                       AwakePaths.artworkFile(for: "track-id").path)
    }

    func testLyricsCacheRoundTrip() {
        let document = LyricsDocument(
            lines: LRCParser.parse("[00:01.00]Hello\n[00:02.00]World"),
            isSynced: true,
            source: "测试"
        )
        let url = LyricsService.cacheURL(for: "cache-track")
        JSONFile.write(document, to: url)
        let loaded = JSONFile.read(LyricsDocument.self, at: url)
        XCTAssertEqual(loaded?.lines, document.lines)
        XCTAssertEqual(loaded?.plain, "Hello\nWorld")
        XCTAssertEqual(loaded?.source, "测试")
        XCTAssertEqual(loaded?.isSynced, true)
    }

    func testITunesArtworkUpgrade() {
        let raw = "https://is1-ssl.mzstatic.com/image/thumb/Music/x/100x100bb.jpg"
        XCTAssertEqual(ArtworkService.highResolutionArtworkURL(raw),
                       "https://is1-ssl.mzstatic.com/image/thumb/Music/x/600x600bb.jpg")
    }

    // MARK: - Cache-first services (no network)

    func testLyricsServicePrefersCache() async {
        let track = Track(id: "cached-track", title: "Song", artist: "Artist",
                          sourceID: UUID(), locator: "missing.flac")
        let document = LyricsDocument(
            lines: [LyricsLine(time: 1, text: "cached line")],
            isSynced: true,
            source: "本地歌词"
        )
        JSONFile.write(document, to: LyricsService.cacheURL(for: track.id))

        let loaded = await LyricsService.shared.lyrics(for: track)
        XCTAssertEqual(loaded?.lines.first?.text, "cached line")
        XCTAssertEqual(loaded?.source, "本地歌词")
    }

    func testLyricsServiceDegradesWithoutNetwork() async {
        let track = Track(id: "empty-\(UUID().uuidString)", title: "", artist: "",
                          sourceID: UUID(), locator: "nothing.flac")
        let result = await LyricsService.shared.lyrics(for: track)
        XCTAssertNil(result)
    }

    func testTranslationPrefersCache() async {
        let lines = ["hello", "world"]
        let cached = TranslatedLyrics(language: "zh-cn", lines: ["你好", "世界"])
        JSONFile.write(cached, to: TranslationService.cacheURL(lines: lines, target: "zh-CN"))

        let result = await TranslationService.shared.translate(lines: lines, target: "zh-CN")
        XCTAssertEqual(result, ["你好", "世界"])
    }

    func testTranslationEmptyInput() async {
        let empty = await TranslationService.shared.translate(lines: [], target: "zh-CN")
        XCTAssertTrue(empty.isEmpty)

        let document = LyricsDocument(lines: [], isSynced: false, source: "测试")
        let translated = await TranslationService.shared.translate(document: document, target: "zh-CN")
        XCTAssertNil(translated)
    }

    func testArtworkServiceReturnsCachedFile() async throws {
        let id = "artwork-\(UUID().uuidString)"
        let track = Track(id: id, title: "Song", artist: "Artist", album: "Album",
                          sourceID: UUID(), locator: "missing.flac")
        let target = AwakePaths.artworkFile(for: id)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: target)

        let path = await ArtworkService.shared.artwork(for: track)
        XCTAssertEqual(path, target.path)
    }
}
