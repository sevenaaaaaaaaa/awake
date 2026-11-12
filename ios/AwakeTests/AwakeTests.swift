import AVFoundation
import XCTest

@testable import Awake

final class AwakeTests: XCTestCase {
  func testMediaNamesLyricsAndLicensedReviewScope() throws {
    let name = MediaNaming.suggest(filename: "01. 王菲 - 红豆 (Live) [FLAC].flac", title: "", artist: "")
    XCTAssertEqual(name.title, "红豆 (Live)"); XCTAssertEqual(name.artist, "王菲")
    XCTAssertEqual(name.filename, "王菲 - 红豆 (Live).flac")
    XCTAssertEqual(MediaNaming.suggest(filename: "Artist - Night [FLAC 24bit 96kHz].flac", title: "", artist: "").title, "Night")
    XCTAssertEqual(MediaNaming.suggest(filename: "Artist - Night [Live FLAC].flac", title: "", artist: "").title, "Night [Live FLAC]")
    let recording = MediaNaming.suggest(filename: "录音_2026_11_11.wav", title: "", artist: "")
    XCTAssertEqual(recording.artist, ""); XCTAssertEqual(recording.title, "录音 2026 11 11")
    let lines = MediaLyrics.parse("[offset:-500]\n[00:01.50][01:02.250]回声\n[00:00.20]开始\n[00:99]bad")
    XCTAssertEqual(lines.count, 3); XCTAssertEqual(lines[0].time, 0); XCTAssertEqual(lines[1].time, 1)
    let id = "12345678-1234-1234-1234-123456789012"
    let object: [String: Any] = ["reviews": [["id": id, "text": "A licensed listener review", "user": ["display_name": "Listener"], "license": ["id": "CC BY-SA 3.0", "info_url": "https://creativecommons.org/licenses/by-sa/3.0/"]]]]
    let rows = MediaLookup.reviews(object, scope: "release_group")
    XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].scope, "release_group"); XCTAssertEqual(rows[0].author, "Listener")
    XCTAssertTrue(MediaLookup.reviews(["reviews": [["id":id,"text":"restricted","license":["id":"All rights reserved"]]]], scope: "recording").isEmpty)
  }

  @MainActor func testMediaEditsPreserveOriginalAndCanBeRestoredAfterReload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MobileStore(root: root)
    let original = Song(title: "raw_recording", file: "original.wav", sourceID: "source", locator: "safe.wav")
    store.state.songs = [original]
    var draft = original; draft.title = "My recording"; draft.lyrics = "[00:01]Text"; draft.sourceID = "untrusted"; draft.file = "other.wav"
    draft.mediaInfo = MediaInfo(original_title: original.title, original_artist: original.artist, original_album: original.album, cover_style: "forest")
    try store.saveMedia(draft)
    let restored = MobileStore(root: root)
    XCTAssertEqual(restored.state.songs[0].title, "My recording"); XCTAssertEqual(restored.state.songs[0].sourceID, "source")
    XCTAssertEqual(restored.state.songs[0].file, "original.wav"); XCTAssertEqual(restored.state.songs[0].locator, "safe.wav")
    try restored.resetMedia(original.id)
    XCTAssertEqual(restored.state.songs[0].title, original.title); XCTAssertNil(restored.state.songs[0].mediaInfo)
    XCTAssertEqual(restored.state.songs[0].file, "original.wav")
  }

  @MainActor func testArtworkImportValidatesImageAndBounds() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try MediaArt.persist(Data("not an image".utf8), directory: root))
    let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
      UIColor.blue.setFill(); context.fill(CGRect(x:0,y:0,width:32,height:32))
    }
    let name = try MediaArt.persist(image.pngData()!, directory: root)
    XCTAssertNotNil(UIImage(contentsOfFile: root.appendingPathComponent(name).path))
  }

  @MainActor func testLocalRecordingReadsAdjacentArtworkAndPlainLyrics() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("recording.wav")
    try Data().write(to: file)
    try "Local recording transcript".write(to: root.appendingPathComponent("recording.lyrics.txt"), atomically: true, encoding: .utf8)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
      UIColor.blue.setFill(); context.fill(CGRect(x:0,y:0,width:32,height:32))
    }
    try image.pngData()!.write(to: root.appendingPathComponent("recording.png"))
    var song = Song(title: "Recording")
    MobileStore.readSidecars(from: file, song: &song, directory: root.appendingPathComponent("Artwork"))
    XCTAssertEqual(song.lyrics, "Local recording transcript")
    XCTAssertNotNil(song.artwork)
    XCTAssertEqual(try Data(contentsOf: file).count, 0, "Source audio must remain untouched")
  }
  func testPersonalSourceConfigurationsAndCredentials() throws {
    for (format, text) in [
      ("json", #"{"version":1,"kind":"telegram","name":"音乐","url":"https://example.test/v1/libraries/abc/"}"#),
      ("xml", "<awake-source><version>1</version><kind>telegram</kind><name>音乐</name><url>https://example.test/v1/libraries/abc/</url></awake-source>"),
      ("txt", "# Personal library\nversion=1\nkind=telegram\nname=音乐\nurl=https://example.test/v1/libraries/abc/"),
    ] {
      let config = try SourceConfiguration.parse(text, format: format)
      XCTAssertEqual(config.kind, "telegram")
      XCTAssertEqual(config.name, "音乐")
    }
    for text in [
      "version=1\nkind=telegram\nname=a\nurl=https://a.test/\nsecret=x",
      "version=1\nkind=telegram\nname=a\nurl=https://a.test/?token=x",
      "version=1\nkind=telegram\nname=a\nurl=https://a.test/\nname=b",
    ] { XCTAssertThrowsError(try SourceConfiguration.parse(text, format: "txt")) }
    XCTAssertThrowsError(try SourceConfiguration.parse("<!DOCTYPE x [<!ENTITY e 'test'>]><awake-source><name>&e;</name></awake-source>", format: "xml"))
    let req = try TelegramService.request(base: "http://127.0.0.1:8766/", path: "v1/catalog", secret: "test-only-token")
    XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-token")
    XCTAssertNil(req.url?.query)
    XCTAssertThrowsError(try TelegramService.request(base: "http://public.example/", path: "v1/catalog", secret: "secret"))
    XCTAssertThrowsError(try TelegramService.request(base: "https://example.test/root/", path: "../outside", secret: "secret"))
  }

  @MainActor func testAudioFolderIgnoresSymlinksAndNonAudio() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("song.flac"))
    try Data().write(to: root.appendingPathComponent("script.js"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.wav"), withDestinationURL: root.appendingPathComponent("song.flac"))
    let files = try MobileStore.audioFiles(in: root)
    XCTAssertEqual(files.map(\.lastPathComponent), ["song.flac"])
  }

  @MainActor func testTelegramConnectorIntegrationWhenFixtureIsRunning() async throws {
    // Explicit opt-in: this is not counted as a real Telegram account test.
    guard ProcessInfo.processInfo.environment["AWAKE_CONNECTOR_INTEGRATION"] == "1" else {
      throw XCTSkip("Run the local fixture server and opt in to connector integration")
    }
    let base = "http://127.0.0.1:8766/", secret = "test-only-token"
    let catalog = try await TelegramService.catalog(base: base, secret: secret)
    XCTAssertEqual(catalog.chats.count, 2)
    XCTAssertEqual(catalog.folders.first?.chat_ids, ["-100123"])
    let url = try await TelegramService.collection(base: base, secret: secret, ids: ["42"], limit: 100)
    let source = MusicSource(name: "test fixture", kind: "telegram", url: url)
    let songs = try await SourceService.scan(source, secret: secret)
    XCTAssertEqual(songs.count, 1)
    XCTAssertEqual(songs[0].sampleRate, 0)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let song = try await SourceService.cache(songs[0], source: source, secret: secret, directory: root)
    XCTAssertEqual(song.sampleRate, 48000)
    XCTAssertEqual(song.duration, 1, accuracy: 0.01)
    XCTAssertNotNil(song.file)
  }
  @MainActor func testEffectStatusTracksActualEQBypassAndFailedRequests() {
    let player = MobilePlayer()
    var gains = Array(repeating: Float(0), count: 31)
    XCTAssertTrue(player.setEQ(gains, apo: "", announce: false))
    XCTAssertFalse(player.enhancement.enabled)
    XCTAssertNil(player.activation)
    gains[17] = 2
    XCTAssertTrue(player.setEQ(gains, apo: "", profile: "Sony WF-1000XM5"))
    XCTAssertEqual(player.enhancement.graphicBands, 1)
    XCTAssertTrue(player.enhancement.enabled)
    XCTAssertTrue(player.enhancement.title(playing: false).contains("已就绪"))
    let first = player.activation!.id
    let revision = player.effectRevision
    XCTAssertTrue(player.setEQ(gains, apo: "", profile: "Sony WF-1000XM5"))
    XCTAssertEqual(player.effectRevision, revision)
    let previous = player.enhancement
    XCTAssertFalse(player.setEQ([.nan], apo: "", origin: .ai, source: "test"))
    XCTAssertEqual(player.enhancement, previous)
    XCTAssertNil(player.activation)
    player.bypassed = true
    XCTAssertFalse(player.enhancement.enabled)
    XCTAssertTrue(player.enhancement.configured)
    XCTAssertEqual(player.enhancement.shortTitle, "EQ 旁路")
    player.bypassed = false
    XCTAssertTrue(player.enhancement.enabled)
    XCTAssertNotEqual(player.activation?.id, first)
    let restored = player.activation!.id
    player.dismissEffect(first)
    XCTAssertEqual(player.activation?.id, restored)
    player.dismissEffect(restored)
    XCTAssertNil(player.activation)
  }
  @MainActor func testEffectProvenanceAndSilentSliderCoalescing() {
    let player = MobilePlayer()
    var gains = Array(repeating: Float(0), count: 31)
    gains[10] = -2
    XCTAssertTrue(player.setEQ(gains, apo: "", origin: .ai))
    XCTAssertEqual(player.enhancement.origin, .manual)
    XCTAssertFalse(player.enhancement.shortTitle.contains("AI"))
    let revision = player.effectRevision
    gains[10] = -3
    XCTAssertTrue(player.setEQ(gains, apo: "", announce: false))
    gains[10] = -4
    XCTAssertTrue(player.setEQ(gains, apo: "", announce: false))
    XCTAssertEqual(player.effectRevision, revision)
    XCTAssertTrue(player.setEQ(gains, apo: ""))
    XCTAssertEqual(player.effectRevision, revision + 1)
    XCTAssertTrue(player.setEQ(gains, apo: "", origin: .ai, source: "test-only AI provenance"))
    XCTAssertEqual(player.enhancement.shortTitle, "AI EQ")
    XCTAssertTrue(player.setEQ(Array(repeating: 0, count: 31), apo: ""))
    XCTAssertFalse(player.enhancement.enabled)
    XCTAssertEqual(player.activation?.title, "已恢复原声")
  }
  @MainActor func testEffectPresentationUsesTopSheetAndSingleAnnouncement() {
    let player = MobilePlayer()
    let root = UUID()
    let fullPlayer = UUID()
    let details = UUID()
    player.registerEffectSurface(root, priority: 0)
    player.registerEffectSurface(details, priority: 2)
    player.registerEffectSurface(fullPlayer, priority: 1)
    XCTAssertEqual(player.effectSurface, details)
    player.registerEffectSurface(details, priority: nil)
    XCTAssertEqual(player.effectSurface, fullPlayer)
    player.registerEffectSurface(fullPlayer, priority: nil)
    XCTAssertEqual(player.effectSurface, root)
    player.registerEffectSurface(root, priority: nil)
    XCTAssertNil(player.effectSurface)
    let id = UUID()
    XCTAssertTrue(player.announceEffectOnce(id))
    XCTAssertFalse(player.announceEffectOnce(id))
  }
  func testMainstreamCatalogBrandsAliasesAndSourceIntegrity() throws {
    XCTAssertNil(EquipmentKnowledge.catalogError)
    XCTAssertGreaterThanOrEqual(EquipmentKnowledge.headphones.count, 70)
    for brand in [
      "索尼", "Bose", "森海塞尔", "小米", "华为", "水月雨", "原道", "三星", "OPPO", "一加", "vivo", "荣耀", "realme",
      "Google",
    ] {
      XCTAssertFalse(EquipmentKnowledge.search(brand).isEmpty, brand)
    }
    XCTAssertEqual(EquipmentKnowledge.headphone("索尼 WH-1000XM6")?.id, "wh-1000xm6")
    XCTAssertEqual(EquipmentKnowledge.headphone("华为 FreeBuds Pro 4")?.id, "huawei-freebuds-pro-4")
    XCTAssertNil(EquipmentKnowledge.headphone("Sony XM5"))
    XCTAssertNil(EquipmentKnowledge.headphone("华为"))
    XCTAssertFalse(EquipmentKnowledge.headphone("Bose QC Ultra 一代")!.connections.contains("usb"))
    XCTAssertTrue(EquipmentKnowledge.headphone("Bose QC Ultra 二代")!.connections.contains("usb"))
    let unknown = try XCTUnwrap(EquipmentKnowledge.headphone("原道"))
    XCTAssertEqual(unknown.status, "版本待确认")
    XCTAssertNil(unknown.impedance)
    XCTAssertTrue(unknown.measurementNames.isEmpty)
    let source = try XCTUnwrap(Bundle.main.url(forResource: "headphones-v1", withExtension: "json"))
    let data = try Data(contentsOf: source)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var models = try XCTUnwrap(json["models"] as? [[String: Any]])
    models[1]["aliases"] = [models[0]["name"]!]
    json["models"] = models
    XCTAssertThrowsError(
      try EquipmentKnowledge.decodeCatalog(JSONSerialization.data(withJSONObject: json)))
  }
  func testMainstreamMeasurementMappingAndConditionIsolation() {
    let index = """
      - [Huawei FreeBuds Pro 4 (ANC on)](./author/in-ear/Huawei%20FreeBuds%20Pro%204%20(ANC%20on)) by author
      - [Huawei FreeBuds Pro 4 (ANC off)](./author/in-ear/Huawei%20FreeBuds%20Pro%204%20(ANC%20off)) by author
      - [Huawei FreeBuds Pro 40](./author/in-ear/Huawei%20FreeBuds%20Pro%2040) by author
      - [Moondrop Chu 2](./author/in-ear/Moondrop%20Chu%202) by author
      - [Moondrop Chu](./author/in-ear/Moondrop%20Chu) by author
      """
    XCTAssertEqual(MeasurementService.parseIndex(index, model: "华为 FreeBuds Pro 4").count, 2)
    XCTAssertEqual(MeasurementService.parseIndex(index, model: "水月雨 竹2").count, 1)
    XCTAssertFalse(MeasurementService.matches(candidate: "Xiaomi Buds 5 Pro", model: "小米 Buds5"))
    XCTAssertFalse(
      MeasurementService.matches(
        candidate: "Bose QuietComfort Ultra Headphones", model: "Bose QC Ultra 二代"))
    XCTAssertFalse(MeasurementService.matches(candidate: "Vido", model: "原道"))
    var chain = ListeningChain(
      routeUID: "test", name: "华为", headphone: "华为 FreeBuds Pro 4", connection: "bluetooth")
    XCTAssertNotNil(
      MeasurementService.conditionConflict(
        candidate: "Huawei FreeBuds Pro 4 (ANC on)", chain: chain))
    chain.acousticMode = "ANC 开启"
    XCTAssertNil(
      MeasurementService.conditionConflict(
        candidate: "Huawei FreeBuds Pro 4 (ANC on)", chain: chain))
    XCTAssertNotNil(
      MeasurementService.conditionConflict(
        candidate: "Huawei FreeBuds Pro 4 (ANC off)", chain: chain))
    chain.connection = "usb"
    XCTAssertNotNil(
      MeasurementService.conditionConflict(candidate: "Huawei FreeBuds Pro 4", chain: chain))
  }
  @MainActor func testModelSelectionResetsConditionsAndPreservesSameModelOverrides() throws {
    let model = try XCTUnwrap(EquipmentKnowledge.headphone("水月雨 竹2"))
    var chain = ListeningChain(
      routeUID: "usb", name: "test", headphone: "HD600", connection: "analog")
    chain.acousticMode = "被动模式"
    chain.equipment = EquipmentContext()
    chain.equipment?.impedance = 500
    chain.equipment?.specSource = "old measurement"
    EquipmentKnowledge.select(model, for: &chain)
    XCTAssertEqual(chain.acousticMode, "待确认")
    XCTAssertNil(chain.equipment?.impedance)
    chain.equipment?.impedance = 18
    chain.equipment?.specSource = "own test"
    EquipmentKnowledge.select(model, for: &chain)
    XCTAssertEqual(chain.equipment?.impedance, 18)
  }
  func testEquipmentUnitsAndUnknownsAreNotInterchangeable() throws {
    XCTAssertEqual(
      EquipmentKnowledge.referenceVoltage(impedance: 32, sensitivity: 100, unit: "dB/mW")!,
      sqrt(0.0032), accuracy: 0.000001)
    XCTAssertEqual(
      EquipmentKnowledge.referenceVoltage(impedance: nil, sensitivity: 100, unit: "dB/V")!,
      pow(10, -0.5), accuracy: 0.000001)
    XCTAssertNil(
      EquipmentKnowledge.referenceVoltage(impedance: nil, sensitivity: 100, unit: "dB/mW"))
    XCTAssertNil(
      EquipmentKnowledge.referenceVoltage(impedance: 32, sensitivity: .nan, unit: "dB/V"))
    XCTAssertNil(EquipmentKnowledge.headphone("铁三角"))
    XCTAssertNil(EquipmentKnowledge.headphone("Beats"))
    XCTAssertNil(EquipmentKnowledge.headphone("ATH-AD2000X2"))
    XCTAssertEqual(EquipmentKnowledge.headphone("HD-600")?.unit, "dB/V")
    var context = EquipmentContext()
    context.impedance = 32
    XCTAssertThrowsError(try context.validate())
    context.specSource = "personal measurement"
    XCTAssertNoThrow(try context.validate())
    context.sensitivity = .infinity
    XCTAssertThrowsError(try context.validate())
  }
  func testEquipmentOutputRequiresModelModeAndAnalogPath() {
    var chain = ListeningChain(
      routeUID: "usb", name: "HD600", headphone: "HD600", connection: "usb")
    chain.frontend = "FiiO KA13"
    var context = EquipmentContext()
    context.outputID = "ka13-se-mobile"
    context.goal = "游戏定位"
    context.issue = "响度不足"
    chain.equipment = context
    XCTAssertEqual(EquipmentKnowledge.output(chain)?.powerMW, 50)
    XCTAssertTrue(
      EquipmentKnowledge.connectionMatches(EquipmentKnowledge.headphone("HD600")!, chain: chain))
    chain.acousticMode = "被动模式"
    XCTAssertNil(
      MeasurementService.conditionConflict(
        candidate: "Sennheiser HD 600 (analog cable)", chain: chain))
    let advice = EquipmentKnowledge.advice(chain).joined(separator: "\n")
    XCTAssertTrue(advice.contains("测试负载与耳机标称阻抗不同"))
    XCTAssertTrue(advice.contains("HRTF"))
    XCTAssertTrue(advice.contains("前级衰减"))
    chain.connection = "bluetooth"
    XCTAssertNil(EquipmentKnowledge.output(chain))
    XCTAssertFalse(EquipmentKnowledge.advice(chain).joined().contains("Vrms"))
    chain.connection = "usb"
    chain.frontend = "Another CS43131 dongle"
    XCTAssertNil(EquipmentKnowledge.output(chain))
  }
  @MainActor func testEquipmentLegacyDecodeAndModeForkPersistence() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = MobileStore(root: dir)
    var chain = ListeningChain(
      routeUID: "test", name: "HD600", headphone: "HD600", connection: "usb")
    let legacyData = try JSONEncoder().encode(chain)
    XCTAssertNil(try JSONDecoder().decode(ListeningChain.self, from: legacyData).equipment)
    chain.frontend = "FiiO KA13"
    chain.gains[10] = 3
    store.saveChain(chain)
    chain.equipment = EquipmentContext()
    chain.equipment?.goal = "人声优先"
    store.saveChain(chain)
    XCTAssertEqual(store.state.chains.count, 1)
    XCTAssertEqual(store.activeChain(route: "test")?.gains[10], 3)
    chain.equipment?.outputID = "ka13-bal-desktop"
    store.saveChain(chain)
    XCTAssertEqual(store.state.chains.count, 2)
    let reopened = MobileStore(root: dir)
    let current = try XCTUnwrap(reopened.activeChain(route: "test"))
    XCTAssertNotEqual(current.id, chain.id)
    XCTAssertEqual(current.gains[10], 0)
    XCTAssertEqual(current.equipment?.outputID, "ka13-bal-desktop")
    XCTAssertTrue(reopened.localAdvice(chainID: current.id).joined().contains("人声优先"))
  }
  func directory() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
  }
  func wav(_ url: URL, seconds: Double = 1, rate: Double = 48000) throws {
    let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let n = AVAudioFrameCount(seconds * rate)
    let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: n)!
    b.frameLength = n
    for c in 0..<2 {
      for i in 0..<Int(n) {
        b.floatChannelData![c][i] = Float(sin(Double(i) * 2 * Double.pi * 1000 / rate) * 0.1)
      }
    }
    let file = try AVAudioFile(forWriting: url, settings: f.settings)
    try file.write(from: b)
  }
  func testSkinInteroperabilityAndInjectionRejection() throws {
    for s in [Skin.dark, .light, .glass] {
      try s.validate()
      let text =
        "# Design\n```json\n" + String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        + "\n```"
      XCTAssertEqual(try Skin.parse(text), s)
    }
    var bad = Skin.dark
    bad.colors.accent = "url(https://example.test)"
    XCTAssertThrowsError(try bad.validate())
    bad = Skin.dark
    bad.colors.text = bad.colors.bg
    XCTAssertThrowsError(try bad.validate())
  }
  func testAPORejectsInvalidAndRetainsCenterShelfQ() throws {
    let (preamp, filters) = try EQMath.parse(
      "Preamp: -6 dB\nFilter 1: ON LSC Fc 105 Hz Gain 3 dB Q 0.7\nFilter 2: ON PK Fc 1000 Hz Gain -2 dB Q 2"
    )
    XCTAssertEqual(preamp, -6)
    XCTAssertEqual(filters.count, 2)
    XCTAssertEqual(filters[0].q, 0.7)
    XCTAssertThrowsError(try EQMath.parse("Filter 1: ON PK Fc 1000 Hz Gain NaN dB Q 1"))
    XCTAssertThrowsError(try EQMath.parse("Filter 1: ON LP Fc 1000 Hz Gain 1 dB Q 1"))
  }
  func testSourceBoundaryAndPlaintextRules() throws {
    let root = try Network.endpoint("https://nas.example/music/", localHTTP: true)
    XCTAssertNoThrow(try Network.child("/music/歌.wav", base: root))
    XCTAssertThrowsError(try Network.child("https://other.example/music/a.wav", base: root))
    XCTAssertThrowsError(try Network.child("/private/a.wav", base: root))
    XCTAssertThrowsError(try Network.endpoint("https://user:secret@nas.example/music"))
    XCTAssertThrowsError(try Network.endpoint("http://public.example/music", localHTTP: true))
    XCTAssertNoThrow(try Network.endpoint("http://192.168.1.2/music", localHTTP: true))
    XCTAssertThrowsError(try Network.endpoint("http://10.public.example/music", localHTTP: true))
  }
  func testWebDAVNamespacesAndPlexSections() throws {
    let parser = SourceXML()
    try parser.parse(
      Data(
        "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/music/歌.wav</d:href><d:propstat><d:prop><d:displayname>歌.wav</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"
          .utf8))
    XCTAssertEqual(parser.rows.first?.href, "/music/歌.wav")
    let plex = SourceXML()
    try plex.parse(
      Data(
        "<MediaContainer><Directory type=\"movie\" key=\"1\"/><Directory type=\"artist\" key=\"2\"/></MediaContainer>"
          .utf8))
    XCTAssertEqual(plex.sections, ["2"])
  }
  func testLocalAddressRulesAllowNASHostnamesAndRejectPublicPlainHTTP() throws {
    XCTAssertNoThrow(try Network.endpoint("http://diskstation:5005/dav", localHTTP: true))
    XCTAssertNoThrow(try Network.endpoint("http://192.168.1.9:5005/dav", localHTTP: true))
    XCTAssertNoThrow(try Network.endpoint("http://nas.local/dav", localHTTP: true))
    XCTAssertNoThrow(try Network.endpoint("http://[fd00::1]:5005/dav", localHTTP: true))
    XCTAssertNoThrow(try Network.endpoint("https://nas.example.com/dav", localHTTP: true))
    XCTAssertThrowsError(try Network.endpoint("http://nas.example.com/dav", localHTTP: true))
    XCTAssertThrowsError(try Network.endpoint("http://10.public.example/dav", localHTTP: true))
    XCTAssertThrowsError(try Network.endpoint("ftp://nas/dav", localHTTP: true))
    XCTAssertThrowsError(try Network.endpoint("192.168.1.9:5005/dav", localHTTP: true))
  }
  func testDigestAuthorizationMatchesRFC2617Vector() throws {
    let header = #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#
    let challenge = try XCTUnwrap(DigestAuth.parse(header))
    let authorization = try DigestAuth.authorization(
      challenge, method: "GET", url: URL(string: "http://example.com/dir/index.html")!,
      username: "Mufasa", password: "Circle Of Life", cnonce: "0a4f113b",
      nonceCount: "00000001")
    XCTAssertTrue(
      authorization.contains("response=\"6629fae49393a05397450978507c4ef1\""), authorization)
    XCTAssertTrue(authorization.contains("qop=auth"), authorization)
  }
  func testPlaylistTextM3UAndCsvParsing() throws {
    let text = PlaylistParser.text("1. 周杰伦 - 稻香\n2. 陈奕迅 - 富士山下\nAimer - 残響散歌")
    XCTAssertEqual(text.count, 3)
    XCTAssertEqual(text[0].artist, "周杰伦")
    XCTAssertEqual(text[0].title, "稻香")
    XCTAssertEqual(text[2].title, "残響散歌")

    let m3u = PlaylistParser.m3u(
      "#EXTM3U\n#EXTINF:225,周杰伦 - 稻香\nMusic/稻香.mp3\n#EXTINF:260,陈奕迅 - 富士山下\nMusic/富士山下.flac")
    XCTAssertEqual(m3u.count, 2)
    XCTAssertEqual(m3u[0].title, "稻香")
    XCTAssertEqual(m3u[0].duration, 225)
    XCTAssertEqual(m3u[0].fileName, "稻香.mp3")

    let csv = PlaylistParser.csv("title,artist,album,duration\n稻香,周杰伦,魔杰座,225\n富士山下,陈奕迅,What's Going On...,260")
    XCTAssertEqual(csv.count, 2)
    XCTAssertEqual(csv[1].artist, "陈奕迅")
    XCTAssertEqual(csv[1].duration, 260)
  }
  func testCueParsingBuildsSegmentsAndDerivesEnds() throws {
    let cue = """
      PERFORMER "Test Artist"
      TITLE "Test Album"
      FILE "album.flac" WAVE
        TRACK 01 AUDIO
          TITLE "First"
          PERFORMER "Test Artist"
          INDEX 01 00:00:00
        TRACK 02 AUDIO
          TITLE "Second"
          INDEX 01 03:12:37
        TRACK 03 AUDIO
          TITLE "Third"
          INDEX 01 07:00:00
      """
    let sheet = try PlaylistParser.cue(cue)
    XCTAssertEqual(sheet.album, "Test Album")
    XCTAssertEqual(sheet.fileName, "album.flac")
    XCTAssertEqual(sheet.tracks.count, 3)
    XCTAssertEqual(sheet.tracks[0].title, "First")
    XCTAssertEqual(sheet.tracks[0].segmentStart, 0)
    let second = 3 * 60 + 12 + 37.0 / 75
    XCTAssertEqual(sheet.tracks[0].segmentEnd ?? -1, second, accuracy: 0.001)
    XCTAssertEqual(sheet.tracks[1].segmentStart ?? -1, second, accuracy: 0.001)
    XCTAssertEqual(sheet.tracks[1].duration, 7 * 60 - second, accuracy: 0.001)
    XCTAssertNil(sheet.tracks[2].segmentEnd)
    XCTAssertEqual(sheet.tracks[2].artist, "Test Artist")
  }
  func testOnlinePlaylistFetchersWhenEnabled() async throws {
    guard ProcessInfo.processInfo.environment["AWAKE_PLAYLIST_INTEGRATION"] == "1" else {
      throw XCTSkip("设置 AWAKE_PLAYLIST_INTEGRATION=1 才请求真实平台")
    }
    let netease = try await PlaylistFetch.netease("https://music.163.com/playlist?id=2195404116")
    XCTAssertGreaterThan(netease.tracks.count, 10, "网易云应通过 trackIds 取到全量")
    XCTAssertFalse(netease.name.isEmpty)
    XCTAssertFalse(netease.tracks[0].artist.isEmpty)
    let qq = try await PlaylistFetch.qq("7011264340")
    XCTAssertGreaterThan(qq.tracks.count, 0)
    XCTAssertFalse(qq.name.isEmpty)
    let youtube = try await PlaylistFetch.youtube(
      "https://www.youtube.com/playlist?list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI")
    XCTAssertGreaterThan(youtube.tracks.count, 0)
    let apple = try await PlaylistFetch.apple(
      "https://music.apple.com/cn/playlist/%E4%BB%8A%E6%97%A5%E7%83%AD%E9%97%A8/pl.f4d106fed2bd41149aaacabb233eb5eb")
    XCTAssertGreaterThan(apple.tracks.count, 0)
  }
  func testYouTubeTitleCleaningAndClockParsing() {
    var artist = ""
    let first = PlaylistFetch.cleanYoutubeTitle(
      "BELLAKEO (Video Oficial) - Peso Pluma, Anitta", artist: &artist)
    XCTAssertEqual(first, "BELLAKEO")
    XCTAssertEqual(artist, "Peso Pluma, Anitta")
    artist = "Known Artist"
    let second = PlaylistFetch.cleanYoutubeTitle("Song Name (Official Video) - Someone", artist: &artist)
    XCTAssertEqual(second, "Song Name")
    XCTAssertEqual(artist, "Known Artist")
    XCTAssertEqual(PlaylistFetch.clockSeconds("3:55"), 235)
    XCTAssertEqual(PlaylistFetch.clockSeconds("1:02:03"), 3723)
    XCTAssertEqual(PlaylistFetch.clockSeconds("not a time"), 0)
  }
  func testPlaylistMatcherPrefersExactThenFuzzy() {
    var a = Song(title: "稻香", artist: "周杰伦", duration: 225)
    a.id = "song-a"
    var b = Song(title: "富士山下", artist: "陈奕迅", duration: 260)
    b.id = "song-b"
    let tracks = [
      ImportedTrack(title: "稻香", artist: "周杰伦", duration: 224),
      ImportedTrack(title: "稻香 (Live)", artist: "周杰伦"),
      ImportedTrack(title: "完全不存在", artist: "某个路人"),
    ]
    let matches = PlaylistMatcher.match(tracks, songs: [a, b])
    XCTAssertEqual(matches.count, 3)
    XCTAssertEqual(matches[0].song?.id, "song-a")
    XCTAssertGreaterThan(matches[0].score, 0.9)
    XCTAssertEqual(matches[1].song?.id, "song-a")
    XCTAssertNil(matches[2].song)
    XCTAssertTrue(matches[2].reason.contains("没有"))
  }
  func testSongSegmentsAndPlaylistsRoundTrip() throws {
    var song = Song(title: "Cue Track", artist: "A", album: "B", duration: 12)
    song.segmentStart = 35.5
    song.segmentEnd = 47.5
    let data = try JSONEncoder().encode(song)
    let decoded = try JSONDecoder().decode(Song.self, from: data)
    XCTAssertEqual(decoded.segmentStart, 35.5)
    XCTAssertEqual(decoded.segmentEnd, 47.5)
    let playlist = Playlist(name: "导入", songIDs: [song.id], note: "网易云音乐")
    let round = try JSONDecoder().decode(
      Playlist.self, from: JSONEncoder().encode(playlist))
    XCTAssertEqual(round.name, "导入")
    XCTAssertEqual(round.songIDs, [song.id])
    var state = LibraryState()
    state.playlists = [playlist]
    let stateData = try JSONEncoder().encode(state)
    let stateBack = try JSONDecoder().decode(LibraryState.self, from: stateData)
    XCTAssertEqual(stateBack.playlists?.first?.songIDs, [song.id])
  }
  func testSelfSignedHTTPSRequiresExplicitTrust() async throws {
    var trusted = MusicSource(
      name: "tls", kind: "webdav", url: "https://127.0.0.1:8771/dav/", username: "u")
    trusted.trustSelfSigned = true
    do {
      let songs = try await SourceService.scan(trusted, secret: "p")
      XCTAssertFalse(songs.isEmpty)
    } catch {
      throw XCTSkip(
        "自签名 HTTPS 夹具未启动：python3 Tools/webdav_matrix_server.py --tls 8771（\(error.localizedDescription)）"
      )
    }
    var untrusted = trusted
    untrusted.trustSelfSigned = false
    do {
      _ = try await SourceService.scan(untrusted, secret: "p")
      XCTFail("未勾选自签名证书时不应跳过 TLS 校验")
    } catch {
      XCTAssertFalse(error.localizedDescription.isEmpty)
    }
  }
  func testWebDAVFixtureMatrix() async throws {
    let health = URL(string: "http://127.0.0.1:8770/health")!
    do {
      _ = try await Network.data(URLRequest(url: health), limit: 4096)
    } catch {
      throw XCTSkip("WebDAV 矩阵夹具未启动：python3 Tools/webdav_matrix_server.py 8770")
    }
    func source(_ name: String, _ path: String) -> MusicSource {
      MusicSource(name: name, kind: "webdav", url: "http://127.0.0.1:8770" + path, username: "u")
    }
    let basic = try await SourceService.scan(source("basic", "/dav/"), secret: "p")
    XCTAssertEqual(basic.count, 3, basic.map(\.locator).joined(separator: ","))
    XCTAssertTrue(basic.contains { $0.locator.hasSuffix("root.flac") })
    XCTAssertTrue(basic.contains { $0.locator.hasSuffix(".mp3") })

    var request = URLRequest(url: URL(string: "http://127.0.0.1:8770/redirect/")!)
    request.httpMethod = "PROPFIND"
    request.setValue("1", forHTTPHeaderField: "Depth")
    request.setValue(
      "Basic " + Data("u:p".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    let body = try await Network.data(
      request, limit: 65536, auth: Network.Auth(username: "u", password: "p"))
    XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("multistatus"))

    do {
      var cross = URLRequest(url: URL(string: "http://127.0.0.1:8770/cross/")!)
      cross.httpMethod = "PROPFIND"
      _ = try await Network.data(cross, limit: 65536)
      XCTFail("跨站重定向应当被拒绝")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("其他站点"), error.localizedDescription)
    }

    let digest = try await SourceService.scan(source("digest", "/digest/"), secret: "p")
    XCTAssertEqual(digest.first?.title, "Digest Song")

    let partial = try await SourceService.scan(source("partial", "/partial/"), secret: "p")
    XCTAssertEqual(partial.count, 1, partial.map(\.locator).joined(separator: ","))
    XCTAssertTrue(partial[0].locator.hasSuffix("Readable.mp3"))

    do {
      _ = try await SourceService.scan(source("html", "/html/"), secret: "p")
      XCTFail("HTML 响应应当报错")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("网页"), error.localizedDescription)
    }

    do {
      _ = try await SourceService.scan(source("empty", "/empty/"), secret: "p")
      XCTFail("空目录应当报错")
    } catch {
      XCTAssertTrue(
        error.localizedDescription.contains("没有支持的音频")
          || error.localizedDescription.contains("空"),
        error.localizedDescription)
    }
  }
  @MainActor func testChainForkPersistenceAndFeedbackAdvice() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = MobileStore(root: dir)
    var chain = ListeningChain(
      routeUID: "test-route", name: "耳机 · USB", headphone: "Example", connection: "usb")
    chain.gains[17] = 2
    store.saveChain(chain)
    var changed = chain
    changed.acousticMode = "ANC 开启"
    store.saveChain(changed)
    XCTAssertEqual(store.state.chains.count, 2)
    XCTAssertNotEqual(store.activeChain(route: "test-route")?.id, chain.id)
    XCTAssertEqual(store.activeChain(route: "test-route")?.gains[17], 0)
    let reopened = MobileStore(root: dir)
    XCTAssertEqual(reopened.state.chains.count, 2)
    XCTAssertTrue(reopened.localAdvice(chainID: nil).first!.contains("先用"))
  }
  @MainActor func testImportFolderCopiesAudioAndKeepsNestedTitles() async throws {
    let dir = try directory()
    let root = try directory()
    defer {
      try? FileManager.default.removeItem(at: dir)
      try? FileManager.default.removeItem(at: root)
    }
    let nested = dir.appendingPathComponent("Album", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try wav(nested.appendingPathComponent("Track One.wav"))
    let store = MobileStore(root: root)
    await store.importAudioFolder(dir)
    XCTAssertEqual(store.state.songs.count, 1, store.message)
    XCTAssertEqual(store.state.songs.first?.title, "Track One")
    XCTAssertTrue(store.message.contains("已导入 1 首"), store.message)
  }
  @MainActor func testImportUsesRealMetadataAndKeepsOriginalFilename() async throws {
    let dir = try directory()
    let root = try directory()
    defer {
      try? FileManager.default.removeItem(at: dir)
      try? FileManager.default.removeItem(at: root)
    }
    let u = dir.appendingPathComponent("Actual clip.wav")
    try wav(u)
    let store = MobileStore(root: root)
    await store.importFiles([u])
    XCTAssertEqual(store.state.songs.count, 1)
    let s = try XCTUnwrap(store.state.songs.first)
    XCTAssertEqual(s.title, "Actual clip")
    XCTAssertEqual(s.duration, 1, accuracy: 0.001)
    XCTAssertNotNil(store.localURL(s))
  }
  func testOfflineBenchReportsActualFramesAndFiniteSignal() async throws {
    let result = try await SoftwareBench().run(gains: Array(repeating: 0, count: 31), apo: "")
    XCTAssertEqual(result.frames, 240000)
    XCTAssertEqual(result.nonFinite, 0)
    XCTAssertEqual(result.clipped, 0)
    XCTAssertGreaterThan(result.rms, 0.05)
    XCTAssertGreaterThan(result.seconds, 0)
    print(
      "IOS_BENCH frames=\(result.frames) elapsed=\(result.seconds) peak=\(result.peak) rms=\(result.rms)"
    )
  }
  @MainActor func testPlaybackSeekDoesNotLearnSkippedTime() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let u = dir.appendingPathComponent("long.wav")
    try wav(u, seconds: 30)
    let player = MobilePlayer()
    player.volume = 0
    var learned: Double = 0
    player.onListen = { _, s in learned += s }
    let song = Song(title: "test", duration: 30, sampleRate: 48000, file: "long.wav")
    player.play([(song, u)])
    try await Task.sleep(nanoseconds: 400_000_000)
    player.seek(29)
    try await Task.sleep(nanoseconds: 200_000_000)
    player.pause()
    XCTAssertLessThan(learned, 2)
    player.stop()
  }
  func testGenerationsAreNotImplicitlyInterchangeable() {
    XCTAssertFalse(
      MeasurementService.matches(candidate: "Apple AirPods Max", model: "Apple AirPods Max 2"))
    XCTAssertFalse(
      MeasurementService.matches(candidate: "Apple AirPods Pro 2", model: "AirPods Pro 3"))
    XCTAssertTrue(
      MeasurementService.matches(
        candidate: "Apple AirPods Pro 3 (Harman · 6k)", model: "AirPods Pro 3"))
  }
  @MainActor func testCompatibleQueuePauseAndCompletion() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.wav")
    let b = dir.appendingPathComponent("b.wav")
    try wav(a, seconds: 0.7)
    try wav(b, seconds: 0.7)
    let player = MobilePlayer()
    player.volume = 0
    var gains = Array(repeating: Float(0), count: 31)
    gains[17] = -1
    player.setEQ(gains, apo: "", announce: false)
    let first = Song(id: "a", title: "a", duration: 0.7)
    let second = Song(id: "b", title: "b", duration: 0.7)
    player.play([(first, a), (second, b)])
    XCTAssertEqual(player.enhancement.title(playing: player.playing), "EQ 增强开启")
    try await Task.sleep(nanoseconds: 300_000_000)
    player.pause()
    XCTAssertEqual(player.enhancement.title(playing: player.playing), "EQ 增强已就绪")
    let paused = player.position
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(player.position, paused, accuracy: 0.05)
    player.resume()
    try await Task.sleep(nanoseconds: 2_000_000_000)
    XCTAssertEqual(player.song?.id, "b")
    XCTAssertFalse(player.playing)
    XCTAssertEqual(player.position, 0.7, accuracy: 0.05)
    player.stop()
  }
  @MainActor func testTwoHourSparseTrackSeeksWithoutFullDecode() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("two-hours.wav")
    var header = Data()
    func word<T: FixedWidthInteger>(_ x: T) {
      var n = x.littleEndian
      withUnsafeBytes(of: &n) { header.append(contentsOf: $0) }
    }
    let bytes = UInt32(7200 * 48000 * 2 * 2)
    header.append(Data("RIFF".utf8))
    word(bytes + 36)
    header.append(Data("WAVEfmt ".utf8))
    word(UInt32(16))
    word(UInt16(1))
    word(UInt16(2))
    word(UInt32(48000))
    word(UInt32(192000))
    word(UInt16(4))
    word(UInt16(16))
    header.append(Data("data".utf8))
    word(bytes)
    try header.write(to: url)
    let file = try FileHandle(forWritingTo: url)
    try file.truncate(atOffset: UInt64(bytes) + 44)
    try file.close()
    let player = MobilePlayer()
    player.volume = 0
    var seconds = 0.0
    player.onListen = { _, s in seconds += s }
    player.play([(Song(title: "long", duration: 7200), url)], from: 7199.7)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    XCTAssertEqual(player.duration, 7200, accuracy: 0.001)
    XCTAssertFalse(player.playing)
    XCTAssertLessThan(seconds, 1)
    player.stop()
  }

  @MainActor func testInterruptedJobsDoNotAutoRetryAndCredentialDestinationMustMatch() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = MobileStore(root: dir)
    var job = CreationJob(prompt: "test", model: "music_v1")
    job.state = "running"
    store.jobs = [job]
    try store.persist()
    let reopened = MobileStore(root: dir)
    XCTAssertEqual(reopened.jobs.first?.state, "interrupted")
    XCTAssertFalse(reopened.generationRunning)
    reopened.state.curatorCredentialEndpoint = "https://first.example/v1"
    reopened.state.curatorCredentialAccount = "test-reference"
    reopened.state.curatorURL = "https://second.example/v1"
    XCTAssertThrowsError(try reopened.curatorSecret())
  }

}
