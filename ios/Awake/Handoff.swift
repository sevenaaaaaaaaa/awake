import Foundation

// MARK: - 接力请求（协议 v1）

/// 手机 → 电脑的接力请求体，字段与 docs/handoff-protocol.md 一致。
/// 只含曲目元数据与进度：不含音频、文件路径、账号、token 或设备标识。
struct HandoffRequest: Codable, Equatable {
  struct Track: Codable, Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
  }

  var code: String
  var track: Track
  var position: Double
  var playing: Bool

  /// 电脑端请求体上限 8 KB；单字段截断到 200 字，远小于上限又能保留可匹配信息。
  static let maximumBodyBytes = 8 * 1024
  static let maximumFieldLength = 200
}

extension HandoffRequest {
  init(code: String, song: Song, position: Double, playing: Bool) {
    self.init(
      code: Self.sanitizedCode(code),
      track: Track(
        title: Self.clip(song.title), artist: Self.clip(song.artist), album: Self.clip(song.album),
        duration: song.duration.isFinite ? max(0, song.duration) : 0),
      position: position.isFinite ? max(0, position) : 0,
      playing: playing)
  }

  static func sanitizedCode(_ code: String) -> String {
    String(code.filter { $0.isASCII && $0.isNumber }.prefix(6))
  }

  private static func clip(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return String(trimmed.prefix(maximumFieldLength))
  }

  func body() throws -> Data { try JSONEncoder().encode(self) }
}

// MARK: - 设备地址

/// 一台可接力的电脑。name 是展示用的设备名，host / port 来自 Bonjour 解析或手动输入。
struct HandoffEndpoint: Equatable {
  var host: String
  var port: Int
  var name: String

  init(host: String, port: Int, name: String) {
    self.host = host
    self.port = port
    self.name = name
  }

  /// 形如 192.168.1.8:8737，IPv6 加方括号。
  var displayAddress: String {
    host.contains(":") ? "[" + host + "]:" + String(port) : host + ":" + String(port)
  }

  /// 只发到 http://<host>:<port>/handoff，不写其他路径。
  var requestURL: URL? {
    // IPv6 主机必须用方括号包起来，URLComponents 直接塞冒号可能拼不出地址。
    if host.contains(":") {
      return URL(string: "http://[" + host + "]:" + String(port) + "/handoff")
    }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = port
    components.path = "/handoff"
    return components.url
  }

  /// 仅局域网：私有 IPv4、IPv6 链路本地/ULA、.local 主机名或 localhost。
  var isLocalNetworkHost: Bool {
    let h = host.lowercased()
    if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".local.") { return true }
    if h.contains(":") {
      return h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") || h == "::1"
    }
    let octets = h.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
    guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
    if octets[0] == 10 || octets[0] == 127 { return true }
    if octets[0] == 192, octets[1] == 168 { return true }
    if octets[0] == 172, (16...31).contains(octets[1]) { return true }
    if octets[0] == 169, octets[1] == 254 { return true }
    // 100.64.0.0/10：部分组网/运营商级 NAT 的局域网地址。
    if octets[0] == 100, (64...127).contains(octets[1]) { return true }
    return false
  }

  /// 解析 host:port；也接受 http://host:port、尾部路径和空白。
  /// 端口必须在 1…65535，裸 IPv6 必须加方括号。
  static func parse(_ text: String) -> HandoffEndpoint? {
    var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty, raw.count <= 255 else { return nil }
    let lower = raw.lowercased()
    for scheme in ["http://", "https://"] where lower.hasPrefix(scheme) {
      raw = String(raw.dropFirst(scheme.count))
    }
    if let cut = raw.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
      raw = String(raw[..<cut])
    }
    guard !raw.isEmpty else { return nil }

    let host: String
    let portText: String
    if raw.hasPrefix("[") {
      guard let close = raw.firstIndex(of: "]") else { return nil }
      host = String(raw[raw.index(after: raw.startIndex)..<close])
      let rest = raw[raw.index(after: close)...]
      guard rest.hasPrefix(":") else { return nil }
      portText = String(rest.dropFirst())
    } else {
      guard let colon = raw.lastIndex(of: ":"), !raw[..<colon].contains(":") else { return nil }
      host = String(raw[..<colon])
      portText = String(raw[raw.index(after: colon)...])
    }
    guard !host.isEmpty, host.count <= 200,
      !host.contains(" "), !host.contains("/"), !host.contains("@")
    else { return nil }
    guard let port = Int(portText), (1...65535).contains(port) else { return nil }
    return HandoffEndpoint(host: host.lowercased(), port: port, name: host)
  }
}

/// Bonjour 发现到的一台电脑。
struct HandoffDevice: Identifiable, Equatable {
  var id: String
  var name: String
  var host: String
  var port: Int

  var endpoint: HandoffEndpoint {
    HandoffEndpoint(host: host, port: port, name: name)
  }

  var displayAddress: String { endpoint.displayAddress }
}

// MARK: - 响应

/// 电脑的回应，已翻译成可展示的中文提示。
struct HandoffReply: Equatable {
  enum Outcome: Equatable {
    /// 200 且 matched=true，电脑已开始播放。
    case delivered
    /// 200 但没匹配到曲目。
    case unmatched
    /// 401 配对码错误。
    case wrongCode
    /// 429 尝试过多。
    case tooManyAttempts
    /// 400 请求格式错误。
    case badRequest
    /// 没发出去或没收到回应（地址、网络、超时、本地校验失败）。
    case notSent
  }

  var outcome: Outcome
  var statusCode: Int
  var ok: Bool
  var matched: Bool
  var title: String
  var deviceName: String
  var text: String

  var succeeded: Bool { outcome == .delivered }

  static func notSent(_ text: String, deviceName: String = "") -> HandoffReply {
    HandoffReply(
      outcome: .notSent, statusCode: 0, ok: false, matched: false, title: "",
      deviceName: deviceName, text: text)
  }

  private struct Wire: Codable {
    var ok: Bool?
    var matched: Bool?
    var title: String?
    var error: String?
    var message: String?
  }

  /// 解析响应体；失败信息按协议只给可读原因，不含路径或网络细节。
  static func parse(statusCode: Int, body: Data, deviceName: String) -> HandoffReply {
    let wire = try? JSONDecoder().decode(Wire.self, from: body)
    let ok = wire?.ok ?? false
    let matched = wire?.matched ?? false
    let title = (wire?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let error = (wire?.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let name = deviceName.isEmpty ? "电脑" : deviceName

    let outcome: Outcome
    let text: String
    switch statusCode {
    case 200 where ok && matched:
      outcome = .delivered
      text = "已接力到 " + name
    case 200:
      outcome = .unmatched
      text = error.isEmpty ? "电脑曲库没有找到这首歌" : error
    case 401:
      outcome = .wrongCode
      text = "配对码不对，请再确认电脑上显示的 6 位数字"
    case 429:
      outcome = .tooManyAttempts
      text = "尝试次数太多，请等电脑换一组配对码后再试"
    case 400:
      outcome = .badRequest
      text = error.isEmpty ? "电脑没看懂这次请求，请再试一次" : error
    default:
      outcome = .notSent
      text = "电脑返回了意外的状态（" + String(statusCode) + "），请再试一次"
    }
    return HandoffReply(
      outcome: outcome, statusCode: statusCode, ok: ok, matched: matched, title: title,
      deviceName: name, text: text)
  }
}

// MARK: - 发送

/// 只做一次 POST /handoff，超时 5 秒；不重试、不保存配对码。
struct HandoffSender {
  var session: URLSession = HandoffSender.makeSession()
  static let timeout: TimeInterval = 5

  static func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.waitsForConnectivity = false
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
  }

  static func sanitizedCode(_ code: String) -> String {
    HandoffRequest.sanitizedCode(code)
  }

  func send(
    code: String, song: Song, position: Double, playing: Bool, to endpoint: HandoffEndpoint
  ) async -> HandoffReply {
    let device = endpoint.name.isEmpty ? endpoint.host : endpoint.name
    let clean = Self.sanitizedCode(code)
    guard clean.count == 6 else {
      return .notSent("配对码是电脑上显示的 6 位数字", deviceName: device)
    }
    guard endpoint.isLocalNetworkHost else {
      return .notSent("只能接力到同一局域网内的电脑，不支持公网地址", deviceName: device)
    }
    guard let url = endpoint.requestURL else {
      return .notSent("这个地址不可用，请检查主机与端口", deviceName: device)
    }
    let payload = HandoffRequest(code: clean, song: song, position: position, playing: playing)
    let body: Data
    do {
      body = try payload.body()
    } catch {
      return .notSent("无法生成接力请求，请再试一次", deviceName: device)
    }
    guard body.count <= HandoffRequest.maximumBodyBytes else {
      return .notSent("曲目信息过长，无法接力", deviceName: device)
    }

    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = body

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .notSent("电脑没有回应，请再试一次", deviceName: device)
      }
      return HandoffReply.parse(statusCode: http.statusCode, body: data, deviceName: device)
    } catch let error as URLError where error.code == .timedOut {
      return .notSent("连接超时（5 秒），请确认电脑仍在接收接力", deviceName: device)
    } catch {
      return .notSent(
        "连不上 " + device + "，请确认电脑点过「接收接力」且两台设备在同一 Wi-Fi",
        deviceName: device)
    }
  }
}

// MARK: - 发现

/// 浏览 _awake._tcp 并解析主机与端口。只在局域网内搜索、只读服务信息。
final class HandoffBrowser: NSObject, ObservableObject {
  @Published private(set) var devices: [HandoffDevice] = []
  @Published private(set) var searching = false
  @Published private(set) var note = ""

  private let browser = NetServiceBrowser()
  private var services: [NetService] = []
  private var resolving = Set<NetService>()

  override init() {
    super.init()
    browser.delegate = self
  }

  func start() {
    guard !searching else { return }
    devices = []
    note = ""
    searching = true
    browser.searchForServices(ofType: "_awake._tcp.", inDomain: "local.")
  }

  func stop() {
    browser.stop()
    for service in services { service.stop() }
    services.removeAll()
    resolving.removeAll()
    searching = false
  }

  private func publish(_ change: @escaping () -> Void) {
    if Thread.isMainThread {
      change()
    } else {
      DispatchQueue.main.async(execute: change)
    }
  }

  private func upsert(_ device: HandoffDevice) {
    if let index = devices.firstIndex(where: { $0.id == device.id }) {
      devices[index] = device
    } else {
      devices.append(device)
      devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    note = ""
  }
}

extension HandoffBrowser: NetServiceBrowserDelegate {
  func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
    publish { self.searching = true }
  }

  func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
    publish { self.searching = false }
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]
  ) {
    publish {
      self.searching = false
      self.note = "没法搜索附近的电脑，请检查 Wi-Fi 或本地网络权限"
    }
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool
  ) {
    guard !services.contains(service) else { return }
    // 只把电脑列为接力目标：手机的接收端实例名带 AwakePhone- 前缀。
    guard !HandoffRole.isPhoneServiceName(service.name) else { return }
    service.delegate = self
    services.append(service)
    resolving.insert(service)
    service.resolve(withTimeout: HandoffSender.timeout)
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool
  ) {
    services.removeAll { $0 == service }
    resolving.remove(service)
    let name = service.name
    publish { self.devices.removeAll { $0.id == name } }
  }
}

extension HandoffBrowser: NetServiceDelegate {
  func netServiceDidResolveAddress(_ sender: NetService) {
    resolving.remove(sender)
    guard !HandoffRole.isPhoneServiceName(sender.name) else { return }
    guard sender.port > 0, let hostName = sender.hostName else { return }
    // Bonjour 常返回尾部带点的主机名，去掉后才能拼出可连接的 URL。
    let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
    let device = HandoffDevice(
      id: sender.name, name: sender.name, host: host.lowercased(), port: sender.port)
    publish { self.upsert(device) }
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    resolving.remove(sender)
    services.removeAll { $0 == sender }
  }
}
