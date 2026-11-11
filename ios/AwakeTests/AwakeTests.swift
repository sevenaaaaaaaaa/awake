import AVFoundation
import XCTest

@testable import Awake

final class AwakeTests: XCTestCase {
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
