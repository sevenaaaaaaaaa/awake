import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 协议 v2 载荷（电脑 → 手机）

/// 发送端给的曲目信息，字段与 docs/handoff-protocol.md 一致。
struct HandoffTrackInfo: Codable, Equatable {
  var title: String
  var artist: String
  var album: String
  var duration: Double

  init(title: String, artist: String, album: String, duration: Double) {
    self.title = title
    self.artist = artist
    self.album = album
    self.duration = duration
  }

  init(song: Song) {
    self.init(
      title: song.title, artist: song.artist, album: song.album,
      duration: song.duration.isFinite ? max(0, song.duration) : 0)
  }
}

/// 电脑发来的接力请求体；只含元数据与进度。
struct IncomingHandoff: Codable, Equatable {
  var code: String
  var track: HandoffTrackInfo
  var position: Double
  var playing: Bool

  static let maximumBodyBytes = 8 * 1024

  private enum CodingKeys: String, CodingKey {
    case code, track, position, playing
  }

  init(code: String, track: HandoffTrackInfo, position: Double, playing: Bool) {
    self.code = code
    self.track = track
    self.position = position
    self.playing = playing
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decode(String.self, forKey: .code)
    track = try container.decode(HandoffTrackInfo.self, forKey: .track)
    position = try container.decodeIfPresent(Double.self, forKey: .position) ?? 0
    playing = try container.decodeIfPresent(Bool.self, forKey: .playing) ?? true
  }
}

// MARK: - Bonjour TXT

/// `_awake._tcp` 的 TXT 记录编解码。`to` 标记接收端是电脑还是手机。
enum HandoffTXT {
  static let key = "to"

  /// 把 [(key, value)] 编成 DNS-SD TXT 记录：每条前面 1 字节长度。
  static func encode(_ pairs: [(String, String)]) -> Data {
    var data = Data()
    for (key, value) in pairs {
      let entry = key + "=" + value
      let bytes = Array(entry.utf8.prefix(255))
      data.append(UInt8(bytes.count))
      data.append(contentsOf: bytes)
    }
    return data
  }

  /// 解析 TXT 记录；坏数据跳过，不让广播里的垃圾字段影响判断。
  static func parse(_ data: Data?) -> [String: String] {
    guard let data, !data.isEmpty else { return [:] }
    var result: [String: String] = [:]
    var index = data.startIndex
    while index < data.endIndex {
      let length = Int(data[index])
      index = data.index(after: index)
      guard length > 0, let end = data.index(index, offsetBy: length, limitedBy: data.endIndex)
      else { break }
      if let entry = String(data: data[index..<end], encoding: .utf8),
        let equals = entry.firstIndex(of: "=")
      {
        let key = String(entry[..<equals]).lowercased()
        let value = String(entry[entry.index(after: equals)...])
        if !key.isEmpty { result[key] = value }
      }
      index = end
    }
    return result
  }

  /// 接收端角色：手机写 phone，电脑写 desktop；旧版电脑端无该键。
  static func role(in data: Data?) -> String {
    let value = parse(data)[key]?.lowercased() ?? ""
    return value == HandoffRole.phone.rawValue ? HandoffRole.phone.rawValue : HandoffRole.desktop.rawValue
  }
}

enum HandoffRole: String {
  case phone
  case desktop

  /// 手机接收端的 Bonjour 实例名前缀；电脑端用 `Awake-<主机名>`。
  static let phonePrefix = "AwakePhone-"

  static func isPhoneServiceName(_ name: String) -> Bool {
    name.hasPrefix(phonePrefix)
  }
}

// MARK: - 配对码闸门

/// 与桌面端同一套规则：10 分钟过期、每 2 秒 1 次、错 5 次换码。
/// 所有判断只依赖传入的时间，便于单测。
struct HandoffGate: Equatable {
  enum Verdict: Equatable {
    case expired
    case tooSoon
    case wrong
    case rotated
    case accepted
  }

  static let ttl: TimeInterval = 10 * 60
  static let minimumInterval: TimeInterval = 2
  static let maximumWrong = 5

  private(set) var code: String
  private(set) var wrong = 0
  private var lastRequest: Date?
  private var expiresAt: Date

  init(code: String, now: Date = Date()) {
    self.code = code
    self.expiresAt = now.addingTimeInterval(Self.ttl)
  }

  /// 6 位数字，允许前导 0（和桌面端一致）。
  static func randomCode() -> String {
    String(format: "%06d", Int.random(in: 0..<1_000_000))
  }

  func isExpired(now: Date = Date()) -> Bool { now >= expiresAt }

  /// 一次判定。无论码对错都占用当前窗口，避免用错码暴力猜。
  mutating func evaluate(now: Date, supplied: String) -> Verdict {
    if now >= expiresAt { return .expired }
    if let last = lastRequest, now.timeIntervalSince(last) < Self.minimumInterval {
      return .tooSoon
    }
    lastRequest = now
    expiresAt = now.addingTimeInterval(Self.ttl)
    guard supplied.trimmingCharacters(in: .whitespacesAndNewlines) == code else {
      wrong += 1
      if wrong >= Self.maximumWrong {
        wrong = 0
        code = Self.randomCode()
        return .rotated
      }
      return .wrong
    }
    wrong = 0
    return .accepted
  }

  /// 用户手动换码；重置错误计数与过期时间。
  mutating func rotate(now: Date = Date()) {
    code = Self.randomCode()
    wrong = 0
    lastRequest = nil
    expiresAt = now.addingTimeInterval(Self.ttl)
  }
}

// MARK: - 匹配

/// 曲目匹配：归一化 + 字符 bigram Dice 相似度，规则与桌面端逐条对齐。
enum HandoffMatcher {
  static let threshold = 0.62
  static let durationTolerance = 5.0

  private static let noiseWords: Set<String> = [
    "official", "video", "lyrics", "lyric", "audio", "hd", "4k", "remaster", "remastered",
    "version", "高清", "官方",
  ]

  /// 小写、去掉括号内容与标点、截断 feat、丢掉常见噪声词。
  static func normalize(_ text: String) -> String {
    var depth = 0
    var withoutBrackets = ""
    for character in text.lowercased() {
      switch character {
      case "(", "[", "{", "（", "【", "〔":
        depth += 1
      case ")", "]", "}", "）", "】", "〕":
        depth = max(0, depth - 1)
      default:
        if depth == 0 { withoutBrackets.append(character) }
      }
    }
    var filtered = ""
    for character in withoutBrackets {
      filtered.append(character.isLetter || character.isNumber || character.isWhitespace ? character : " ")
    }
    var tokens = filtered.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if let position = tokens.firstIndex(where: { ["feat", "ft", "featuring"].contains($0) }) {
      tokens = Array(tokens.prefix(position))
    }
    return tokens.filter { !noiseWords.contains($0) }.joined(separator: " ")
  }

  /// 字符 bigram 计数。
  static func shingles(_ text: String) -> [String: Int] {
    let characters = Array(text)
    guard characters.count >= 2 else {
      return characters.isEmpty ? [:] : [String(characters[0]): 1]
    }
    var map: [String: Int] = [:]
    for index in 0..<(characters.count - 1) {
      let gram = String(characters[index...index + 1])
      map[gram, default: 0] += 1
    }
    return map
  }

  /// bigram Dice 系数，0…1。
  static func similarity(_ left: String, _ right: String) -> Double {
    if left.isEmpty || right.isEmpty { return 0 }
    if left == right { return 1 }
    let leftShingles = shingles(left)
    let rightShingles = shingles(right)
    let leftTotal = leftShingles.values.reduce(0, +)
    let rightTotal = rightShingles.values.reduce(0, +)
    guard leftTotal > 0, rightTotal > 0 else { return 0 }
    var intersection = 0
    for (gram, count) in leftShingles {
      if let other = rightShingles[gram] { intersection += min(count, other) }
    }
    return 2 * Double(intersection) / Double(leftTotal + rightTotal)
  }

  /// 曲名 .55 + 艺人 .35 + 专辑 .10（缺项按剩余权重归一），再加时长接近度。
  /// 时长差超过 ±5 秒直接淘汰。
  static func score(query: HandoffTrackInfo, song: Song) -> Double? {
    let songDuration = song.duration
    var difference: Double?
    if query.duration > 0, songDuration > 0 {
      let gap = abs(query.duration - songDuration)
      if gap > durationTolerance { return nil }
      difference = gap
    }
    var weighted = 0.55 * similarity(normalize(query.title), normalize(song.title))
    var total = 0.55
    if !query.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      weighted += 0.35 * similarity(normalize(query.artist), normalize(song.artist))
      total += 0.35
    }
    if !query.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      weighted += 0.10 * similarity(normalize(query.album), normalize(song.album))
      total += 0.10
    }
    var value = weighted / total
    if let difference { value += 0.05 * (1 - difference / durationTolerance) }
    return min(max(value, 0), 1)
  }

  /// 只在「本机文件存在」的曲目里取最高分，避免远程曲目抢占本地曲目。
  static func bestMatch(
    query: HandoffTrackInfo, songs: [Song], isPlayable: (Song) -> Bool
  ) -> Song? {
    var ranked: [(index: Int, score: Double)] = []
    for (index, song) in songs.enumerated() {
      if let value = score(query: query, song: song), value >= threshold {
        ranked.append((index, value))
      }
    }
    ranked.sort { left, right in
      left.score == right.score ? left.index < right.index : left.score > right.score
    }
    for entry in ranked where isPlayable(songs[entry.index]) {
      return songs[entry.index]
    }
    return nil
  }
}

// MARK: - HTTP 解析

/// 最小 HTTP/1.1 解析：只要 POST /handoff + JSON 请求体，尽力而为地拒绝其他一切。
enum HandoffHTTP {
  struct Request: Equatable {
    var method: String
    var path: String
    var contentType: String
    var body: Data
  }

  enum Parse: Equatable {
    /// 数据还不够，继续读。
    case incomplete
    /// 解析成功，交给业务层判定路径与方法。
    case request(Request)
    /// 直接回错误：状态码 + 可读原因。
    case failure(status: Int, error: String)
  }

  /// 头部 + 请求体上限：8 KB 体 + 4 KB 头部余量。
  static let maximumBytes = IncomingHandoff.maximumBodyBytes + 4 * 1024

  static func parse(_ buffer: Data) -> Parse {
    if buffer.count > maximumBytes { return .failure(status: 413, error: "请求太大") }
    guard let headerEnd = rangeOfHeaderEnd(buffer) else { return .incomplete }
    let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
    guard let headerText = String(data: headerData, encoding: .utf8) else {
      return .failure(status: 400, error: "请求格式错误")
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      return .failure(status: 400, error: "请求格式错误")
    }
    let parts = requestLine.split(separator: " ").map(String.init)
    guard parts.count >= 2 else { return .failure(status: 400, error: "请求格式错误") }
    let method = parts[0].uppercased()
    let path = parts[1].split(separator: "?").first.map(String.init) ?? parts[1]

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      headers[key] = value
    }
    let contentLength = Int(headers["content-length"] ?? "0") ?? -1
    if contentLength < 0 || contentLength > IncomingHandoff.maximumBodyBytes {
      return .failure(status: 413, error: "请求太大")
    }
    let bodyStart = headerEnd.upperBound
    let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
    if available < contentLength { return .incomplete }
    let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
    let body = Data(buffer[bodyStart..<bodyEnd])
    return .request(
      Request(
        method: method, path: path, contentType: headerText.lowercased(), body: body))
  }

  private static func rangeOfHeaderEnd(_ buffer: Data) -> Range<Data.Index>? {
    let marker = Data([13, 10, 13, 10])
    guard let range = buffer.range(of: marker) else { return nil }
    return range
  }
}

// MARK: - 接收端

/// 电脑 → 手机的接收端：NWListener + Bonjour 广播 + 配对码闸门。
/// 只在 App 前台、用户主动开启时监听；停止即关闭端口并注销广播。
@MainActor
final class HandoffReceiver: ObservableObject {
  @Published private(set) var active = false
  @Published private(set) var code = ""
  @Published private(set) var port: UInt16 = 0
  @Published private(set) var name = ""
  @Published private(set) var lastMessage = ""
  @Published private(set) var lastTitle = ""

  /// 由界面注入：把请求里的曲目匹配成可播放的歌曲。
  var match: ((HandoffTrackInfo) -> Song?)?
  /// 由界面注入：播放匹配到的曲目并 seek 到指定秒数。
  var play: ((Song, Double, Bool) -> Void)?

  private var listener: NWListener?
  private var gate: HandoffGate?
  private let queue = DispatchQueue(label: "com.seven.awake.handoff.receiver")
  private var expiryTimer: Timer?

  nonisolated static func deviceName() -> String {
    #if canImport(UIKit)
    let raw = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
    #else
    let raw = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
    #endif
    return raw.isEmpty ? "iPhone" : raw
  }

  func start(name deviceName: String = HandoffReceiver.deviceName()) {
    stop()
    let newCode = HandoffGate.randomCode()
    gate = HandoffGate(code: newCode)
    code = newCode
    name = deviceName.sanitizedServiceLabel
    lastMessage = "等待电脑连接"

    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters, on: .any)
    } catch {
      lastMessage = "无法启动接收服务，请稍后再试"
      return
    }
    listener.service = NWListener.Service(
      name: HandoffRole.phonePrefix + name,
      type: "_awake._tcp",
      domain: nil,
      txtRecord: HandoffTXT.encode([
        ("v", "2"), ("name", name), ("code_required", "1"),
        (HandoffTXT.key, HandoffRole.phone.rawValue),
      ]))
    listener.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        guard let self else { return }
        switch state {
        case .ready:
          self.port = listener.port?.rawValue ?? 0
          self.active = true
          self.lastMessage = "等待电脑连接"
        case .failed, .cancelled:
          self.active = false
        default:
          break
        }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
    self.listener = listener
    active = true
    startExpiryTimer()
  }

  func stop() {
    expiryTimer?.invalidate()
    expiryTimer = nil
    listener?.cancel()
    listener = nil
    gate = nil
    active = false
    port = 0
    lastMessage = ""
    lastTitle = ""
  }

  /// 手动换一组配对码（界面上的「换一组」）。
  func refreshCode() {
    guard var gate else { return }
    gate.rotate(now: Date())
    self.gate = gate
    code = gate.code
    lastMessage = "已换新的配对码"
  }

  private func startExpiryTimer() {
    expiryTimer?.invalidate()
    expiryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, var gate = self.gate else { return }
        if gate.isExpired() {
          gate.rotate(now: Date())
          self.gate = gate
          self.code = gate.code
          self.lastMessage = "配对码已过期，换了一组新的"
        }
      }
    }
  }

  // MARK: 连接

  nonisolated private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(connection, buffer: Data())
  }

  nonisolated private func receive(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }
      var accumulated = buffer
      if let data { accumulated.append(data) }
      switch HandoffHTTP.parse(accumulated) {
      case .incomplete:
        if isComplete || error != nil {
          connection.cancel()
        } else {
          self.receive(connection, buffer: accumulated)
        }
      case .failure(let status, let message):
        self.respond(connection, status: status, json: ["ok": false, "matched": false, "error": message])
      case .request(let request):
        Task { @MainActor in self.handle(request, connection: connection) }
      }
    }
  }

  private func handle(_ request: HandoffHTTP.Request, connection: NWConnection) {
    guard request.method == "POST", request.path == "/handoff" else {
      respond(connection, status: 404, json: ["ok": false, "matched": false, "error": "未找到"])
      return
    }
    guard request.contentType.contains("application/json") else {
      lastMessage = "请求格式错误"
      respond(connection, status: 400, json: ["ok": false, "matched": false, "error": "请求格式错误"])
      return
    }
    guard let payload = try? JSONDecoder().decode(IncomingHandoff.self, from: request.body) else {
      lastMessage = "请求格式错误"
      respond(connection, status: 400, json: ["ok": false, "matched": false, "error": "请求格式错误"])
      return
    }
    guard var gate = gate else {
      respond(connection, status: 400, json: ["ok": false, "matched": false, "error": "接收已停止"])
      return
    }
    switch gate.evaluate(now: Date(), supplied: payload.code) {
    case .expired:
      self.gate = gate
      respond(connection, status: 400, json: ["ok": false, "matched": false, "error": "配对码已过期，请在手机上重新开启接收"])
    case .tooSoon:
      self.gate = gate
      respond(connection, status: 400, json: ["ok": false, "matched": false, "error": "请求太快，请稍后再试"])
    case .wrong:
      self.gate = gate
      lastMessage = "配对码不对"
      respond(connection, status: 401, json: ["ok": false, "matched": false, "error": "配对码不对"])
    case .rotated:
      self.gate = gate
      code = gate.code
      lastMessage = "错码次数太多，已换新配对码"
      respond(connection, status: 429, json: ["ok": false, "matched": false, "error": "尝试次数太多"])
    case .accepted:
      self.gate = gate
      deliver(payload, connection: connection)
    }
  }

  private func deliver(_ payload: IncomingHandoff, connection: NWConnection) {
    let requested = payload.track
    guard let song = match?(requested) else {
      lastMessage = "曲库里没有找到「" + requested.title + "」"
      respond(
        connection, status: 200,
        json: [
          "ok": false, "matched": false, "error": "手机曲库没有找到这首歌",
          "title": requested.title,
        ])
      return
    }
    let position = payload.position.isFinite ? max(0, payload.position) : 0
    play?(song, position, payload.playing)
    lastTitle = song.title
    lastMessage = "已接收：" + song.title
    respond(
      connection, status: 200,
      json: [
        "ok": true, "matched": true, "title": song.title, "message": "已开始播放",
      ])
  }

  nonisolated private func respond(_ connection: NWConnection, status: Int, json: [String: Any]) {
    let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
    head += "Content-Type: application/json\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n\r\n"
    var data = Data(head.utf8)
    data.append(body)
    connection.send(
      content: data,
      completion: .contentProcessed { _ in connection.cancel() })
  }
}

extension String {
  /// Bonjour 实例名只保留可打印且不含分隔符的字符。
  var sanitizedServiceLabel: String {
    let cleaned = map { character -> Character in
      if character.isLetter || character.isNumber { return character }
      return "-"
    }
    let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "Awake" : String(trimmed.prefix(40))
  }
}
