import XCTest

@testable import Awake

final class HandoffTests: XCTestCase {
  private let song = Song(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269.5)

  private func json(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  // MARK: - 请求体

  func testRequestBodyMatchesProtocol() throws {
    let request = HandoffRequest(code: " 12 3456 ", song: song, position: 42.5, playing: true)
    XCTAssertEqual(request.code, "123456")
    let body = try request.body()
    let root = try json(body)

    XCTAssertEqual(Set(root.keys), ["code", "track", "position", "playing"])
    XCTAssertEqual(root["code"] as? String, "123456")
    XCTAssertEqual(root["position"] as? Double, 42.5)
    XCTAssertEqual(root["playing"] as? Bool, true)

    let track = try XCTUnwrap(root["track"] as? [String: Any])
    XCTAssertEqual(Set(track.keys), ["title", "artist", "album", "duration"])
    XCTAssertEqual(track["title"] as? String, "晴天")
    XCTAssertEqual(track["artist"] as? String, "周杰伦")
    XCTAssertEqual(track["album"] as? String, "叶惠美")
    XCTAssertEqual(track["duration"] as? Double, 269.5)
    XCTAssertLessThanOrEqual(body.count, HandoffRequest.maximumBodyBytes)

    // 协议要求：不发音频、文件路径、账号或 token。
    let text = String(decoding: body, as: UTF8.self).lowercased()
    for banned in ["audio", "path", "token", "password", "secret", "account"] {
      XCTAssertFalse(text.contains(banned), "请求体不应包含 " + banned)
    }
  }

  func testRequestClampsLongFieldsAndBadPosition() throws {
    var long = song
    long.title = String(repeating: "长", count: 5000)
    long.album = String(repeating: "a", count: 5000)
    long.artist = String(repeating: "b", count: 5000)
    let request = HandoffRequest(
      code: "123456", song: long, position: .infinity, playing: false)
    XCTAssertEqual(request.position, 0)
    XCTAssertEqual(request.track.title.count, HandoffRequest.maximumFieldLength)
    XCTAssertEqual(request.track.album.count, HandoffRequest.maximumFieldLength)
    let body = try request.body()
    XCTAssertLessThanOrEqual(body.count, HandoffRequest.maximumBodyBytes)
    let track = try XCTUnwrap(try json(body)["track"] as? [String: Any])
    XCTAssertEqual((track["title"] as? String)?.count, HandoffRequest.maximumFieldLength)
  }

  // MARK: - 响应解析

  func testResponseSuccessReportsDeviceName() {
    let body = Data(#"{"ok":true,"matched":true,"title":"晴天","message":"已开始播放"}"#.utf8)
    let reply = HandoffReply.parse(statusCode: 200, body: body, deviceName: "书房 Mac")
    XCTAssertEqual(reply.outcome, .delivered)
    XCTAssertTrue(reply.succeeded)
    XCTAssertTrue(reply.ok)
    XCTAssertTrue(reply.matched)
    XCTAssertEqual(reply.title, "晴天")
    XCTAssertEqual(reply.text, "已接力到 书房 Mac")
  }

  func testResponseUnmatchedKeepsServerReason() {
    let body = Data(#"{"ok":false,"matched":false,"error":"电脑曲库没有找到这首歌"}"#.utf8)
    let reply = HandoffReply.parse(statusCode: 200, body: body, deviceName: "书房 Mac")
    XCTAssertEqual(reply.outcome, .unmatched)
    XCTAssertFalse(reply.succeeded)
    XCTAssertFalse(reply.matched)
    XCTAssertEqual(reply.text, "电脑曲库没有找到这首歌")
  }

  func testResponseUnmatchedWithoutReasonStillReadeable() {
    let reply = HandoffReply.parse(
      statusCode: 200, body: Data(#"{"ok":false,"matched":false}"#.utf8), deviceName: "Mac")
    XCTAssertEqual(reply.outcome, .unmatched)
    XCTAssertEqual(reply.text, "电脑曲库没有找到这首歌")
  }

  func testResponseWrongCodeTooManyAndBadRequest() {
    let wrong = HandoffReply.parse(statusCode: 401, body: Data(), deviceName: "Mac")
    XCTAssertEqual(wrong.outcome, .wrongCode)
    XCTAssertFalse(wrong.ok)
    XCTAssertTrue(wrong.text.contains("配对码"))
    XCTAssertFalse(wrong.succeeded)

    let limited = HandoffReply.parse(
      statusCode: 429, body: Data(#"{"error":"too many"}"#.utf8), deviceName: "Mac")
    XCTAssertEqual(limited.outcome, .tooManyAttempts)
    XCTAssertTrue(limited.text.contains("太多"))

    let bad = HandoffReply.parse(statusCode: 400, body: Data(), deviceName: "Mac")
    XCTAssertEqual(bad.outcome, .badRequest)
    XCTAssertFalse(bad.text.isEmpty)

    let odd = HandoffReply.parse(
      statusCode: 502, body: Data("not json".utf8), deviceName: "Mac")
    XCTAssertEqual(odd.outcome, .notSent)
    XCTAssertTrue(odd.text.contains("502"))
    XCTAssertFalse(odd.text.contains("http"))
  }

  // MARK: - host:port 解析

  func testEndpointParsing() throws {
    let plain = try XCTUnwrap(HandoffEndpoint.parse(" 192.168.1.8:8737 "))
    XCTAssertEqual(plain.host, "192.168.1.8")
    XCTAssertEqual(plain.port, 8737)
    XCTAssertEqual(plain.name, "192.168.1.8")
    XCTAssertEqual(plain.displayAddress, "192.168.1.8:8737")
    XCTAssertEqual(plain.requestURL?.absoluteString, "http://192.168.1.8:8737/handoff")
    XCTAssertTrue(plain.isLocalNetworkHost)

    let named = try XCTUnwrap(HandoffEndpoint.parse("http://Sevenos-Mac.local:8080/"))
    XCTAssertEqual(named.host, "sevenos-mac.local")
    XCTAssertEqual(named.port, 8080)
    XCTAssertTrue(named.isLocalNetworkHost)

    let v6 = try XCTUnwrap(HandoffEndpoint.parse("[fe80::1]:9000"))
    XCTAssertEqual(v6.host, "fe80::1")
    XCTAssertEqual(v6.port, 9000)
    XCTAssertEqual(v6.displayAddress, "[fe80::1]:9000")
    XCTAssertNotNil(v6.requestURL)
    XCTAssertTrue(v6.isLocalNetworkHost)

    for invalid in [
      "", "   ", "1.2.3.4", "host:abc", "host:0", "host:65536", "fe80::1:9000",
      "http://:80", "[fe80::1]", "a b:80", "user@host:80",
    ] {
      XCTAssertNil(HandoffEndpoint.parse(invalid), "应拒绝：" + invalid)
    }
  }

  func testOnlyLocalAddressesAreAccepted() {
    XCTAssertTrue(HandoffEndpoint(host: "192.168.0.12", port: 1, name: "").isLocalNetworkHost)
    XCTAssertTrue(HandoffEndpoint(host: "10.0.0.5", port: 1, name: "").isLocalNetworkHost)
    XCTAssertTrue(HandoffEndpoint(host: "172.20.1.9", port: 1, name: "").isLocalNetworkHost)
    XCTAssertTrue(HandoffEndpoint(host: "book.local", port: 1, name: "").isLocalNetworkHost)
    XCTAssertTrue(HandoffEndpoint(host: "fe80::1", port: 1, name: "").isLocalNetworkHost)
    XCTAssertFalse(HandoffEndpoint(host: "172.32.1.9", port: 1, name: "").isLocalNetworkHost)
    XCTAssertFalse(HandoffEndpoint(host: "203.0.113.9", port: 1, name: "").isLocalNetworkHost)
    XCTAssertFalse(HandoffEndpoint(host: "example.com", port: 1, name: "").isLocalNetworkHost)
  }

  // MARK: - 发送

  func testSenderRejectsShortCodeAndPublicHostWithoutNetworking() async {
    let local = HandoffEndpoint(host: "192.168.1.8", port: 8737, name: "书房 Mac")
    let short = await HandoffSender().send(
      code: "12", song: song, position: 1, playing: true, to: local)
    XCTAssertEqual(short.outcome, .notSent)
    XCTAssertTrue(short.text.contains("6 位"))

    let remote = await HandoffSender().send(
      code: "123456", song: song, position: 1, playing: true,
      to: HandoffEndpoint(host: "203.0.113.9", port: 80, name: "公网"))
    XCTAssertEqual(remote.outcome, .notSent)
    XCTAssertTrue(remote.text.contains("局域网"))
  }

  func testSenderPostsProtocolBodyToHandoffPath() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HandoffStubProtocol.self]
    let sender = HandoffSender(session: URLSession(configuration: configuration))
    HandoffStubProtocol.requestHandler = { request in
      (200, Data(#"{"ok":true,"matched":true,"title":"晴天","message":"已开始播放"}"#.utf8))
    }
    defer { HandoffStubProtocol.requestHandler = nil }

    let reply = await sender.send(
      code: "123456", song: song, position: 42.5, playing: true,
      to: HandoffEndpoint(host: "192.168.1.8", port: 8737, name: "书房 Mac"))

    XCTAssertEqual(reply.outcome, .delivered)
    XCTAssertEqual(reply.text, "已接力到 书房 Mac")
    let request = try XCTUnwrap(HandoffStubProtocol.lastRequest)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.8:8737/handoff")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(request.timeoutInterval, HandoffSender.timeout)

    let body = HandoffStubProtocol.lastBody
    XCTAssertLessThanOrEqual(body.count, HandoffRequest.maximumBodyBytes)
    let root = try json(body)
    XCTAssertEqual(root["code"] as? String, "123456")
    XCTAssertEqual(root["playing"] as? Bool, true)
    let track = try XCTUnwrap(root["track"] as? [String: Any])
    XCTAssertEqual(track["title"] as? String, "晴天")
  }

  func testSenderMapsServerStatuses() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HandoffStubProtocol.self]
    let sender = HandoffSender(session: URLSession(configuration: configuration))
    defer { HandoffStubProtocol.requestHandler = nil }

    HandoffStubProtocol.requestHandler = { _ in (401, Data()) }
    let wrong = await sender.send(
      code: "123456", song: song, position: 0, playing: false,
      to: HandoffEndpoint(host: "192.168.1.8", port: 8737, name: "Mac"))
    XCTAssertEqual(wrong.outcome, .wrongCode)
    XCTAssertTrue(wrong.text.contains("配对码"))

    HandoffStubProtocol.requestHandler = { _ in
      (200, Data(#"{"ok":false,"matched":false,"error":"电脑曲库没有找到这首歌"}"#.utf8))
    }
    let unmatched = await sender.send(
      code: "123456", song: song, position: 0, playing: false,
      to: HandoffEndpoint(host: "192.168.1.8", port: 8737, name: "Mac"))
    XCTAssertEqual(unmatched.outcome, .unmatched)
    XCTAssertEqual(unmatched.text, "电脑曲库没有找到这首歌")
  }
}

/// 拦截请求，验证路径、方法、请求体与超时，不访问真实网络。
private final class HandoffStubProtocol: URLProtocol {
  static var requestHandler: ((URLRequest) throws -> (Int, Data))?
  static var lastRequest: URLRequest?
  static var lastBody = Data()

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lastRequest = request
    Self.lastBody = Self.body(of: request)
    guard let handler = Self.requestHandler else {
      client?.urlProtocol(self, didFailWithError: URLError(.unknown))
      return
    }
    do {
      let (status, data) = try handler(request)
      let response = HTTPURLResponse(
        url: request.url ?? URL(string: "http://127.0.0.1/")!, statusCode: status,
        httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}

  /// URLSession 可能把 httpBody 转成流，两种都读。
  private static func body(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let capacity = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: capacity)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
