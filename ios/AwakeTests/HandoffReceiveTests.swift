import XCTest

@testable import Awake

/// 电脑 → 手机接力的接收端逻辑：配对码闸门、TXT 角色、HTTP 解析、匹配。
final class HandoffReceiveTests: XCTestCase {
  private var now = Date(timeIntervalSince1970: 1_800_000_000)

  // MARK: - 配对码闸门

  func testGateAcceptsCorrectCodeAndExtendsSession() {
    var gate = HandoffGate(code: "123456", now: now)
    XCTAssertEqual(gate.evaluate(now: now, supplied: " 123456 "), .accepted)
    // 10 分钟内再次请求仍然有效，且窗口从这次请求重新计时。
    now = now.addingTimeInterval(5 * 60)
    XCTAssertEqual(gate.evaluate(now: now, supplied: "123456"), .accepted)
    XCTAssertFalse(gate.isExpired(now: now.addingTimeInterval(9 * 60)))
  }

  func testGateRejectsWrongCodeAndRotatesAfterFive() {
    var gate = HandoffGate(code: "123456", now: now)
    for expected in [HandoffGate.Verdict.wrong, .wrong, .wrong, .wrong] {
      now = now.addingTimeInterval(3)
      XCTAssertEqual(gate.evaluate(now: now, supplied: "000000"), expected)
    }
    now = now.addingTimeInterval(3)
    // 第 5 次错误：换新码并回 429。
    XCTAssertEqual(gate.evaluate(now: now, supplied: "000000"), .rotated)
    XCTAssertNotEqual(gate.code, "000000")
    XCTAssertEqual(gate.code.count, 6)
    XCTAssertTrue(gate.code.allSatisfy(\.isNumber))
    XCTAssertEqual(gate.wrong, 0)
    // 新码可用。
    now = now.addingTimeInterval(3)
    XCTAssertEqual(gate.evaluate(now: now, supplied: gate.code), .accepted)
  }

  func testGateExpiresAfterTenMinutes() {
    var gate = HandoffGate(code: "123456", now: now)
    XCTAssertEqual(gate.evaluate(now: now.addingTimeInterval(601), supplied: "123456"), .expired)
  }

  func testGateRateLimitsWrongCodesToo() {
    var gate = HandoffGate(code: "123456", now: now)
    XCTAssertEqual(gate.evaluate(now: now, supplied: "111111"), .wrong)
    // 1 秒后再猜：直接拒绝，不给暴力猜的窗口。
    XCTAssertEqual(gate.evaluate(now: now.addingTimeInterval(1), supplied: "111112"), .tooSoon)
    XCTAssertEqual(gate.wrong, 1)
  }

  func testRandomCodeIsSixDigitsAndCanHaveLeadingZero() {
    for _ in 0..<200 {
      let code = HandoffGate.randomCode()
      XCTAssertEqual(code.count, 6)
      XCTAssertTrue(code.allSatisfy(\.isNumber))
    }
  }

  // MARK: - Bonjour TXT

  func testTXTRoundTripAndRole() {
    let data = HandoffTXT.encode([
      ("v", "2"), ("name", "阿七的 iPhone"), ("code_required", "1"), ("to", "phone"),
    ])
    let parsed = HandoffTXT.parse(data)
    XCTAssertEqual(parsed["v"], "2")
    XCTAssertEqual(parsed["name"], "阿七的 iPhone")
    XCTAssertEqual(parsed["code_required"], "1")
    XCTAssertEqual(HandoffTXT.role(in: data), HandoffRole.phone.rawValue)
  }

  func testTXTMissingRoleDefaultsToDesktop() {
    let data = HandoffTXT.encode([("v", "1"), ("name", "Mac")])
    XCTAssertEqual(HandoffTXT.role(in: data), HandoffRole.desktop.rawValue)
    XCTAssertEqual(HandoffTXT.role(in: nil), HandoffRole.desktop.rawValue)
    // 坏数据不炸：长度字节指向超出范围时停止解析。
    XCTAssertEqual(HandoffTXT.role(in: Data([200, 1, 2, 3])), HandoffRole.desktop.rawValue)
  }

  // MARK: - HTTP 解析

  private func request(
    method: String = "POST", path: String = "/handoff", type: String = "application/json",
    body: Data
  ) -> Data {
    var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    head += "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\n\r\n"
    var data = Data(head.utf8)
    data.append(body)
    return data
  }

  private let payload = Data(
    """
    {"code":"123456","track":{"title":"晴天","artist":"周杰伦","album":"叶惠美","duration":269.5},"position":42.5,"playing":true}
    """.utf8)

  func testHTTPParsesCompleteRequest() throws {
    let parsed = HandoffHTTP.parse(request(body: payload))
    guard case .request(let request) = parsed else {
      return XCTFail("应当解析成请求，实际 \(parsed)")
    }
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/handoff")
    XCTAssertTrue(request.contentType.contains("application/json"))
    let decoded = try JSONDecoder().decode(IncomingHandoff.self, from: request.body)
    XCTAssertEqual(decoded.code, "123456")
    XCTAssertEqual(decoded.track.title, "晴天")
    XCTAssertEqual(decoded.position, 42.5)
    XCTAssertTrue(decoded.playing)
  }

  func testHTTPReturnsIncompleteUntilBodyArrives() {
    let full = request(body: payload)
    let partial = full.dropLast(10)
    XCTAssertEqual(HandoffHTTP.parse(Data(partial)), .incomplete)
    XCTAssertEqual(HandoffHTTP.parse(Data("POST /handoff HTTP/1.1\r\n".utf8)), .incomplete)
  }

  func testHTTPRejectsOversizedBody() {
    let huge = Data(repeating: 0x41, count: IncomingHandoff.maximumBodyBytes + 1)
    guard case .failure(let status, _) = HandoffHTTP.parse(request(body: huge)) else {
      return XCTFail("超大请求体应当被拒绝")
    }
    XCTAssertEqual(status, 413)
  }

  func testIncomingHandoffDefaultsOptionalFields() throws {
    let json = Data(
      """
      {"code":"000123","track":{"title":"A","artist":"B","album":"","duration":12}}
      """.utf8)
    let decoded = try JSONDecoder().decode(IncomingHandoff.self, from: json)
    XCTAssertEqual(decoded.position, 0)
    XCTAssertTrue(decoded.playing)
  }

  // MARK: - 匹配

  func testNormalizeStripsBracketsFeatAndNoise() {
    XCTAssertEqual(
      HandoffMatcher.normalize("晴天 (Live) [官方高清]"), "晴天")
    XCTAssertEqual(
      HandoffMatcher.normalize("Song Title feat. Someone"), "song title")
    XCTAssertEqual(
      HandoffMatcher.normalize("Official Video - 夜曲 (Remastered)"), "夜曲")
  }

  func testMatchesSameSongAcrossNamingNoise() throws {
    let song = Song(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269.5)
    let query = HandoffTrackInfo(
      title: "晴天 (Live)", artist: "周杰伦", album: "叶惠美", duration: 269.0)
    let matched = HandoffMatcher.bestMatch(query: query, songs: [song], isPlayable: { _ in true })
    XCTAssertEqual(matched?.id, song.id)
  }

  func testDurationMismatchIsRejected() {
    let song = Song(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269.5)
    let query = HandoffTrackInfo(
      title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 300)
    XCTAssertNil(HandoffMatcher.bestMatch(query: query, songs: [song], isPlayable: { _ in true }))
  }

  func testUnrelatedSongStaysUnmatched() {
    let song = Song(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269.5)
    let query = HandoffTrackInfo(
      title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera", duration: 354)
    XCTAssertNil(HandoffMatcher.bestMatch(query: query, songs: [song], isPlayable: { _ in true }))
  }

  func testPrefersPlayableLocalCopy() {
    let remote = Song(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269.5)
    let local = Song(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269.5)
    let query = HandoffTrackInfo(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269.5)
    let matched = HandoffMatcher.bestMatch(
      query: query, songs: [remote, local], isPlayable: { $0.id == local.id })
    XCTAssertEqual(matched?.id, local.id)
  }

  func testScoreWeightsTolerateMissingArtist() {
    let song = Song(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269.5)
    let query = HandoffTrackInfo(title: "晴天", artist: "", album: "", duration: 269.5)
    let score = try? XCTUnwrap(HandoffMatcher.score(query: query, song: song))
    XCTAssertEqual(score ?? 0, 1.0, accuracy: 0.0001)
    // 只有曲名时不应因为缺艺人而扣分到阈值以下。
    XCTAssertGreaterThanOrEqual(score ?? 0, HandoffMatcher.threshold)
  }
}
