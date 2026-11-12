import AVFoundation
import CryptoKit
import Foundation

final class TrustPolicy: @unchecked Sendable {
  private let lock = NSLock()
  private var hosts = Set<String>()
  func allow(_ host: String) {
    lock.lock()
    hosts.insert(host.lowercased())
    lock.unlock()
  }
  func allows(_ host: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return hosts.contains(host.lowercased())
  }
}

final class NoRedirect: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
  let trust: TrustPolicy?
  init(trust: TrustPolicy? = nil) { self.trust = trust }

  private func answer(
    _ challenge: URLAuthenticationChallenge,
    _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust, trust.allows(challenge.protectionSpace.host),
      let serverTrust = challenge.protectionSpace.serverTrust
    {
      completionHandler(.useCredential, URLCredential(trust: serverTrust))
    } else {
      completionHandler(.performDefaultHandling, nil)
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) { answer(challenge, completionHandler) }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) { answer(challenge, completionHandler) }
}

enum DigestAuth {
  struct Challenge: Sendable {
    var realm = ""
    var nonce = ""
    var opaque: String?
    var qop: String?
    var algorithm = "MD5"
  }

  static func parse(_ header: String) -> Challenge? {
    guard header.lowercased().hasPrefix("digest") else { return nil }
    var parts: [String] = []
    var current = ""
    var quoted = false
    for ch in header.dropFirst("digest".count) {
      if ch == "\"" { quoted.toggle() }
      if ch == "," && !quoted {
        parts.append(current)
        current = ""
      } else {
        current.append(ch)
      }
    }
    parts.append(current)
    var challenge = Challenge()
    for part in parts {
      let pieces = part.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard pieces.count == 2 else { continue }
      let key = pieces[0].lowercased()
      var value = pieces[1]
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }
      switch key {
      case "realm": challenge.realm = value
      case "nonce": challenge.nonce = value
      case "opaque": challenge.opaque = value
      case "qop": challenge.qop = value
      case "algorithm": challenge.algorithm = value
      default: break
      }
    }
    return challenge.nonce.isEmpty ? nil : challenge
  }

  static func authorization(
    _ challenge: Challenge, method: String, url: URL, username: String, password: String,
    cnonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
    nonceCount: String = "00000001"
  ) throws -> String {
    let uri = url.path(percentEncoded: true) + (url.query.map { "?" + $0 } ?? "")
    let algorithm = challenge.algorithm.uppercased()
    let ha1 = try hash(algorithm, "\(username):\(challenge.realm):\(password)")
    let ha2 = try hash(algorithm, "\(method):\(uri)")
    let wantsQop =
      challenge.qop?.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces).lowercased()
      }.contains("auth") ?? false
    let response =
      wantsQop
      ? try hash(
        algorithm,
        "\(ha1):\(challenge.nonce):\(nonceCount):\(cnonce):auth:\(ha2)")
      : try hash(algorithm, "\(ha1):\(challenge.nonce):\(ha2)")
    var fields = [
      "username=\"\(username)\"", "realm=\"\(challenge.realm)\"", "nonce=\"\(challenge.nonce)\"",
      "uri=\"\(uri)\"", "response=\"\(response)\"", "algorithm=\(challenge.algorithm)",
    ]
    if wantsQop {
      fields += ["qop=auth", "nc=\(nonceCount)", "cnonce=\"\(cnonce)\""]
    }
    if let opaque = challenge.opaque { fields.append("opaque=\"\(opaque)\"") }
    return "Digest " + fields.joined(separator: ", ")
  }

  static func hash(_ algorithm: String, _ text: String) throws -> String {
    let data = Data(text.utf8)
    switch algorithm {
    case "MD5", "":
      return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    case "SHA-256", "SHA256":
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    default:
      throw AppFailure("服务器使用暂不支持的 Digest 算法（\(algorithm)），请改用基础认证或 HTTPS")
    }
  }
}

enum Network {
  struct Auth: Sendable {
    var username = ""
    var password = ""
    var trustSelfSigned = false
    var hasCredentials: Bool { !username.isEmpty || !password.isEmpty }

    init(username: String = "", password: String = "", trustSelfSigned: Bool = false) {
      self.username = username
      self.password = password
      self.trustSelfSigned = trustSelfSigned
    }
  }

  static let policy = TrustPolicy()

  private static let configuration: URLSessionConfiguration = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 30
    c.timeoutIntervalForResource = 240
    c.httpShouldSetCookies = false
    return c
  }()

  static let session = URLSession(
    configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
  private static let trustingSession = URLSession(
    configuration: configuration, delegate: NoRedirect(trust: policy), delegateQueue: nil)

  private static func session(_ request: URLRequest, auth: Auth) -> URLSession {
    guard auth.trustSelfSigned, let host = request.url?.host else { return session }
    policy.allow(host)
    return trustingSession
  }

  static func isLocalHost(_ host: String) -> Bool {
    let value = host.lowercased()
    if value == "localhost" || value == "::1" || value == "[::1]" { return true }
    if [".local", ".lan", ".home", ".internal", ".localdomain"].contains(where: {
      value.hasSuffix($0)
    }) { return true }
    if value.contains(":") {
      let literal = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      return literal.hasPrefix("fc") || literal.hasPrefix("fd") || literal.hasPrefix("fe80")
    }
    if !value.contains(".") { return true }
    let pieces = value.split(separator: ".")
    let octets = pieces.compactMap { Int($0) }
    guard pieces.count == 4, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) })
    else { return false }
    return octets[0] == 10 || octets[0] == 127
      || (octets[0] == 192 && octets[1] == 168)
      || (octets[0] == 172 && (16...31).contains(octets[1]))
      || (octets[0] == 169 && octets[1] == 254)
  }

  static func endpoint(_ text: String, localHTTP: Bool = false) throws -> URL {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AppFailure("请填写服务器地址") }
    guard trimmed.contains("://") else {
      throw AppFailure("地址需以 http:// 或 https:// 开头，例如 https://192.168.1.10:5006/dav")
    }
    guard let u = URL(string: trimmed), let host = u.host, !host.isEmpty,
      u.user == nil, u.password == nil, u.query == nil, u.fragment == nil
    else { throw AppFailure("请输入不含凭据、查询参数的服务器地址") }
    if u.scheme == "https" { return u }
    guard u.scheme == "http" else { throw AppFailure("只支持 http:// 或 https:// 地址") }
    guard localHTTP, isLocalHost(host) else {
      throw AppFailure(
        "外部地址请使用 HTTPS。局域网设备（192.168.x、10.x、单段主机名或 .local）可以用 HTTP：\(trimmed)")
    }
    return u
  }

  static func check(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
      throw AppFailure("服务器没有返回 HTTP 响应")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw AppFailure(message(for: http))
    }
  }

  static func message(for response: HTTPURLResponse) -> String {
    let address = response.url?.absoluteString ?? "该地址"
    switch response.statusCode {
    case 401:
      return "需要登录（401）。请核对账号与密码；开启双重验证的 NAS 请使用「应用密码」。地址：\(address)"
    case 403:
      return "服务器拒绝访问（403）。确认这个账号对该目录有读取权限。地址：\(address)"
    case 404:
      return "路径不存在（404）。WebDAV 通常需要带完整路径（例如 /dav），请核对。地址：\(address)"
    case 405, 501:
      return "这个地址不支持 WebDAV（HTTP \(response.statusCode)）。请先在 NAS 设置里开启 WebDAV 服务，并填写 WebDAV 的完整地址。地址：\(address)"
    case 407:
      return "代理需要认证（407）。地址：\(address)"
    case 503:
      return "服务器暂时不可用（503）。地址：\(address)"
    default:
      return "服务返回 HTTP \(response.statusCode)。地址：\(address)"
    }
  }

  private static let redirectCodes: Set<Int> = [301, 302, 303, 307, 308]

  private static func redirectLocation(_ response: HTTPURLResponse) -> URL? {
    guard redirectCodes.contains(response.statusCode),
      let value = response.value(forHTTPHeaderField: "Location"),
      let base = response.url
    else { return nil }
    return URL(string: value, relativeTo: base)?.absoluteURL
  }

  private static func followed(_ request: URLRequest, to target: URL) throws -> URLRequest {
    guard let base = request.url, base.scheme == target.scheme, base.host == target.host,
      base.port == target.port
    else { throw AppFailure("服务器试图重定向到其他站点，已停止") }
    var next = request
    next.url = target
    return next
  }

  static func data(
    _ request: URLRequest, limit: Int = 2 * 1024 * 1024, auth: Auth = Auth()
  ) async throws -> Data {
    var request = request
    var redirects = 0
    var digestTries = 0
    while true {
      let (bytes, response) = try await session(request, auth: auth).bytes(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw AppFailure("服务器没有返回 HTTP 响应")
      }
      if let target = redirectLocation(http) {
        redirects += 1
        guard redirects <= 3 else {
          throw AppFailure("重定向次数过多：\(request.url?.absoluteString ?? "")")
        }
        request = try followed(request, to: target)
        continue
      }
      if http.statusCode == 401, auth.hasCredentials,
        let raw = http.value(forHTTPHeaderField: "WWW-Authenticate"),
        let challenge = DigestAuth.parse(raw)
      {
        digestTries += 1
        guard digestTries <= 1 else {
          throw AppFailure(
            "认证失败（Digest 401）。请核对账号与密码。地址：\(request.url?.absoluteString ?? "")")
        }
        request.setValue(
          try DigestAuth.authorization(
            challenge, method: request.httpMethod ?? "GET", url: request.url!,
            username: auth.username, password: auth.password),
          forHTTPHeaderField: "Authorization")
        continue
      }
      try check(http)
      guard http.expectedContentLength <= Int64(limit) else { throw AppFailure("服务响应过大") }
      var data = Data()
      data.reserveCapacity(min(limit, 65536))
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < limit else { throw AppFailure("服务响应超过限制") }
        data.append(byte)
      }
      return data
    }
  }

  static func download(
    _ request: URLRequest, limit: Int64 = 4 * 1024 * 1024 * 1024, auth: Auth = Auth()
  ) async throws -> URL {
    var request = request
    var redirects = 0
    var digestTries = 0
    while true {
      let (url, response) = try await session(request, auth: auth).download(for: request)
      guard let http = response as? HTTPURLResponse else {
        try? FileManager.default.removeItem(at: url)
        throw AppFailure("服务器没有返回 HTTP 响应")
      }
      if let target = redirectLocation(http) {
        try? FileManager.default.removeItem(at: url)
        redirects += 1
        guard redirects <= 3 else {
          throw AppFailure("重定向次数过多：\(request.url?.absoluteString ?? "")")
        }
        request = try followed(request, to: target)
        continue
      }
      if http.statusCode == 401, auth.hasCredentials,
        let raw = http.value(forHTTPHeaderField: "WWW-Authenticate"),
        let challenge = DigestAuth.parse(raw)
      {
        try? FileManager.default.removeItem(at: url)
        digestTries += 1
        guard digestTries <= 1 else {
          throw AppFailure(
            "认证失败（Digest 401）。请核对账号与密码。地址：\(request.url?.absoluteString ?? "")")
        }
        request.setValue(
          try DigestAuth.authorization(
            challenge, method: request.httpMethod ?? "GET", url: request.url!,
            username: auth.username, password: auth.password),
          forHTTPHeaderField: "Authorization")
        continue
      }
      do {
        try check(http)
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size > 0, Int64(size) <= limit else {
          throw AppFailure("音频为空或超过支持大小")
        }
        return url
      } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
      }
    }
  }

  static func child(_ href: String, base: URL, restrictPath: Bool = true) throws -> URL {
    guard let url = URL(string: href, relativeTo: base)?.absoluteURL.standardized,
      url.scheme == base.scheme, url.host == base.host, url.port == base.port, url.user == nil,
      url.password == nil, url.query == nil, url.fragment == nil
    else { throw AppFailure("来源返回了跨站或无效的文件地址") }
    let root = base.path.hasSuffix("/") ? base.path : base.path + "/"
    if restrictPath && url.path != base.path && !url.path.hasPrefix(root) {
      throw AppFailure("文件超出配置的来源目录")
    }
    return url
  }
}
struct RemoteEntry {
  var href = "", title = "", artist = "", album = "", duration: Double = 0, isDirectory = false,
    status = "", length: Int64 = 0
}
final class SourceXML: NSObject, XMLParserDelegate {
  var rows: [RemoteEntry] = [], sections: [String] = []
  var failures = 0
  private var current: RemoteEntry?, field = "", text = ""
  func parse(_ data: Data) throws {
    let p = XMLParser(data: data)
    p.shouldProcessNamespaces = true
    p.delegate = self
    guard p.parse() else { throw AppFailure("来源 XML 格式无效") }
  }
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    field = elementName.lowercased()
    text = ""
    if field == "response" { current = RemoteEntry() }
    if field == "collection" { current?.isDirectory = true }
    if field == "directory", attributes["type"] == "artist", let key = attributes["key"] {
      sections.append(key)
    }
    if field == "track" {
      current = RemoteEntry(
        title: attributes["title"] ?? "未命名",
        artist: attributes["grandparentTitle"] ?? attributes["originalTitle"] ?? "未知艺人",
        album: attributes["parentTitle"] ?? "",
        duration: (Double(attributes["duration"] ?? "0") ?? 0) / 1000)
    }
    if field == "part", current?.href.isEmpty == true { current?.href = attributes["key"] ?? "" }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName: String?
  ) {
    let name = elementName.lowercased()
    let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if name == "href" { current?.href = v }
    if name == "displayname" { current?.title = v }
    if name == "status", current?.status.contains(" 2") != true { current?.status = v }
    if name == "getcontentlength" { current?.length = Int64(v) ?? 0 }
    if name == "response" || name == "track" {
      if let c = current, !c.href.isEmpty, c.status.isEmpty || c.status.contains(" 2") {
        rows.append(c)
      } else if current != nil {
        failures += 1
      }
      current = nil
    }
    text = ""
    field = ""
  }
}
enum SourceService {
  static func request(_ url: URL, source: MusicSource, secret: String) -> URLRequest {
    var r = URLRequest(url: url)
    if source.kind == "telegram" {
      r.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
    } else if source.kind == "plex" {
      r.setValue(secret, forHTTPHeaderField: "X-Plex-Token")
    } else if !source.username.isEmpty || !secret.isEmpty {
      r.setValue(
        "Basic " + Data((source.username + ":" + secret).utf8).base64EncodedString(),
        forHTTPHeaderField: "Authorization")
    }
    return r
  }
  static func auth(_ source: MusicSource, secret: String) -> Network.Auth {
    Network.Auth(
      username: source.kind == "webdav" ? source.username : "",
      password: source.kind == "webdav" ? secret : "",
      trustSelfSigned: source.trustSelfSigned)
  }
  static func webDAVHint(_ data: Data) -> String? {
    let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
    if head.contains("<html") || head.contains("<!doctype html") || head.contains("<head") {
      return "这个地址返回的是网页，不是 WebDAV 目录。请确认 NAS 已开启 WebDAV 服务，并填写完整地址（常见形如 https://主机:5006/dav）。"
    }
    return nil
  }
  static func scan(_ source: MusicSource, secret: String) async throws -> [Song] {
    if source.kind == "telegram" { return try await TelegramService.scan(source, secret: secret) }
    let base = try Network.endpoint(source.url, localHTTP: true)
    if source.kind == "plex" {
      func api(_ path: String) throws -> URL {
        guard let u = URL(string: path, relativeTo: base.appendingPathComponent("/"))?.absoluteURL
        else { throw AppFailure("Plex 地址无效") }
        return try Network.child(u.absoluteString, base: base, restrictPath: false)
      }
      let plexAuth = auth(source, secret: secret)
      let xml = SourceXML()
      do {
        try xml.parse(
          try await Network.data(
            request(try api("library/sections"), source: source, secret: secret),
            limit: 8 * 1024 * 1024, auth: plexAuth))
      } catch {
        throw AppFailure("Plex 资料库读取失败：\(error.localizedDescription)。请确认 Token 仍有效，且服务器地址指向这台 Plex 服务器。")
      }
      var songs: [Song] = []
      for section in xml.sections.prefix(30) {
        var offset = 0
        while offset < 20000 {
          let u = try api("library/sections/\(section)/all")
          var components = URLComponents(url: u, resolvingAgainstBaseURL: false)!
          components.queryItems = [
            .init(name: "type", value: "10"),
            .init(name: "X-Plex-Container-Start", value: String(offset)),
            .init(name: "X-Plex-Container-Size", value: "500"),
          ]
          let page = SourceXML()
          do {
            try page.parse(
              try await Network.data(
                request(components.url!, source: source, secret: secret), limit: 8 * 1024 * 1024,
                auth: plexAuth))
          } catch {
            throw AppFailure("Plex 曲目分页读取失败：\(error.localizedDescription)")
          }
          for row in page.rows {
            _ = try Network.child(row.href, base: base, restrictPath: false)
            songs.append(
              Song(
                title: row.title, artist: row.artist, album: row.album, duration: row.duration,
                sourceID: source.id, locator: row.href))
          }
          if page.rows.count < 500 { break }
          offset += 500
        }
      }
      return songs
    }
    var root = base
    if !root.absoluteString.hasSuffix("/") { root.appendPathComponent("") }
    let davAuth = auth(source, secret: secret)
    var stack: [(URL, Int)] = [(root, 0)]
    var seen = Set<String>()
    var songs: [Song] = []
    var skipped = 0
    var firstError: Error?
    var sawEntry = false
    while let (folder, depth) = stack.popLast() {
      try Task.checkCancellation()
      guard seen.insert(folder.absoluteString).inserted else { continue }
      guard seen.count <= 300, depth <= 12 else { throw AppFailure("来源目录过深或超过 300 个目录，请选择更小的根目录") }
      var req = request(folder, source: source, secret: secret)
      req.httpMethod = "PROPFIND"
      req.setValue("1", forHTTPHeaderField: "Depth")
      req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
      req.httpBody = Data(
        "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:displayname/><d:getcontentlength/></d:prop></d:propfind>"
          .utf8)
      let xml = SourceXML()
      let body: Data
      do {
        body = try await Network.data(req, limit: 8 * 1024 * 1024, auth: davAuth)
        if let hint = webDAVHint(body) { throw AppFailure(hint) }
      } catch {
        if folder == root { throw error }
        skipped += 1
        firstError = firstError ?? error
        continue
      }
      do {
        try xml.parse(body)
      } catch {
        if folder == root, let hint = webDAVHint(body) { throw AppFailure(hint) }
        if folder == root { throw AppFailure("这个地址没有返回 WebDAV 目录结构。请确认地址指向 WebDAV 根目录（常见形如 /dav），并且服务器已开启 WebDAV。") }
        skipped += 1
        firstError = firstError ?? error
        continue
      }
      if !xml.rows.isEmpty { sawEntry = true }
      if xml.rows.isEmpty && xml.failures > 0 {
        throw AppFailure("这个目录的所有条目都无法读取（共 \(xml.failures) 个），请检查账号权限")
      }
      for row in xml.rows {
        let url = try Network.child(row.href, base: root)
        if url.standardized.path == folder.standardized.path { continue }
        if row.isDirectory {
          stack.append((url, depth + 1))
        } else if ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "caf"].contains(
          url.pathExtension.lowercased())
        {
          songs.append(
            Song(
              title: row.title.isEmpty
                ? url.deletingPathExtension().lastPathComponent
                : URL(fileURLWithPath: row.title).deletingPathExtension().lastPathComponent,
              sourceID: source.id, locator: url.absoluteString))
          guard songs.count <= 20000 else { throw AppFailure("来源曲目超过两万首，请缩小目录") }
        }
      }
    }
    if songs.isEmpty {
      if let firstError { throw firstError }
      if skipped > 0 { throw AppFailure("有 \(skipped) 个目录无法读取，且没有找到可播放的音频；请检查账号权限") }
      if sawEntry { throw AppFailure("这个 WebDAV 目录里没有支持的音频文件（mp3 / m4a / flac / wav / aiff / alac / caf）") }
      throw AppFailure("这个 WebDAV 目录是空的，或没有读取到任何条目")
    }
    return songs
  }
  static func cache(_ song: Song, source: MusicSource, secret: String, directory: URL) async throws
    -> Song
  {
    let base = try Network.endpoint(source.url, localHTTP: true)
    let url = try Network.child(song.locator, base: base, restrictPath: source.kind != "plex")
    let temp = try await Network.download(
      request(url, source: source, secret: secret), auth: auth(source, secret: secret))
    defer { try? FileManager.default.removeItem(at: temp) }
    let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
    let name = song.id + "." + ext
    let dest = directory.appendingPathComponent(name)
    let partial = directory.appendingPathComponent(song.id + ".part")
    try? FileManager.default.removeItem(at: partial)
    try FileManager.default.copyItem(at: temp, to: partial)
    do {
      let decoded = try AVAudioFile(forReading: partial)
      let buf = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 4096)!
      try decoded.read(into: buf)
      guard buf.frameLength > 0 else { throw AppFailure("音频解码为空") }
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.moveItem(at: partial, to: dest)
      var out = song
      if let tags = try? await MobileStore.readSong(dest, file: name) {
        if out.artwork == nil { out.artwork = tags.artwork }
        if out.lyrics?.isEmpty ?? true { out.lyrics = tags.lyrics }
        if out.comment?.isEmpty ?? true { out.comment = tags.comment }
      }
      out.file = name
      out.duration = Double(decoded.length) / decoded.processingFormat.sampleRate
      out.sampleRate = decoded.processingFormat.sampleRate
      return out
    } catch {
      try? FileManager.default.removeItem(at: partial)
      throw error
    }
  }
}
struct EQCandidate: Identifiable {
  var id: String
  var name: String
  var attribution: String
  var note: String
  var url: URL
  var sourceURL: String
  var requiredAcousticMode: String? = nil
}
enum MeasurementService {
  static func search(_ model: String) async throws -> [EQCandidate] {
    let q = normalize(model)
    guard q.count >= 3 else { throw AppFailure("请输入完整耳机型号") }
    if let known = EquipmentKnowledge.headphone(model), known.measurementNames.isEmpty {
      throw AppFailure("该版本尚无明确的测量映射，请先确认具体版本，或导入注明条件的参数文件")
    }
    var rows: [EQCandidate] = []
    if matches(candidate: "Apple AirPods Pro 3", model: model) {
      for (prefix, target) in [
        ("Harman25", "Harman 2025"), ("JM1-10dB", "JM-1 −10dB"), ("IEF25", "IEF 2025"),
        ("SoundGuys", "SoundGuys"),
      ] {
        let url = URL(
          string:
            "https://raw.githubusercontent.com/kunkun9527/airpods-pro3-eq/a48a077c8ad03b2f00f771ac2ab4f240e57cb4e7/presets/\(prefix)_6k.txt"
        )!
        rows.append(
          .init(
            id: prefix, name: "Apple AirPods Pro 3 (\(target) · 6k)",
            attribution: "kunkun9527 · MIT · 5128 多测量拟合",
            note: "社区估计：原装耳套、ANC 开启、约 60% 音量。非本机或个人测量。", url: url,
            sourceURL: "https://github.com/kunkun9527/airpods-pro3-eq",
            requiredAcousticMode: "ANC 开启"))
      }
      return rows
    }
    let data = try await Network.data(
      URLRequest(
        url: URL(
          string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/INDEX.md")!
      ), limit: 2 * 1024 * 1024)
    return rows + parseIndex(String(decoding: data, as: UTF8.self), model: model)
  }
  static func parseIndex(_ index: String, model: String) -> [EQCandidate] {
    var rows: [EQCandidate] = []
    for line in index.components(separatedBy: .newlines) {
      guard line.hasPrefix("- ["), let middle = line.range(of: "]("),
        let end = line.range(of: ") by ", options: .backwards)
      else { continue }
      let name = String(line[line.index(line.startIndex, offsetBy: 3)..<middle.lowerBound])
      guard matches(candidate: name, model: model) else { continue }
      let path = String(line[middle.upperBound..<end.lowerBound]).replacingOccurrences(
        of: "./", with: "")
      guard !path.contains(".."), let component = path.split(separator: "/").last,
        let u = URL(
          string:
            "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/\(path)/\(component)%20ParametricEQ.txt"
        )
      else { continue }
      rows.append(
        .init(
          id: path, name: name, attribution: String(line[end.upperBound...]),
          note: "请核对测量中的 ANC、耳套与版本；未注明的条件不能视为已确认。", url: u,
          sourceURL: "https://github.com/jaakkopasanen/AutoEq/tree/master/results/" + path))
      if rows.count >= 30 { break }
    }
    return rows
  }
  static func normalize(_ s: String) -> String {
    s.lowercased().filter { $0.isLetter || $0.isNumber }
  }
  static func matches(candidate: String, model: String) -> Bool {
    let known = EquipmentKnowledge.headphone(model)
    let names = known?.measurementNames ?? [model]
    let identities = Set(names.map(normalize).filter { !$0.isEmpty })
    var value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    while true {
      if identities.contains(normalize(value)) { return true }
      guard value.hasSuffix(")"), let start = value.range(of: " (", options: .backwards) else {
        return false
      }
      value = String(value[..<start.lowerBound])
    }
  }
  static func conditionConflict(
    candidate: String, chain: ListeningChain, requiredAcousticMode: String? = nil
  ) -> String? {
    if let requiredAcousticMode, chain.acousticMode != requiredAcousticMode {
      return "此参数要求 \(requiredAcousticMode)，请切换对应链路。"
    }
    guard chain.acousticMode != "待确认" else { return "请先确认当前链路的声学状态。" }
    if let model = EquipmentKnowledge.headphone(chain.headphone),
      !model.modes.contains(chain.acousticMode)
    {
      return "该型号资料尚未确认此声学状态，请核对实际设备设置。"
    }
    let n = candidate.lowercased()
    let off = n.contains("anc off") || n.contains("(passive")
    let on = n.contains("anc on") || n.contains("anc mode") || n.contains("+ anc")
    let ambient = n.contains("ambient") || n.contains("transparency")
    if off && !["ANC 关闭", "被动模式"].contains(chain.acousticMode) { return "此测量属于降噪关闭/被动状态，请切换对应链路。" }
    if on && chain.acousticMode != "ANC 开启" { return "此测量属于降噪开启状态，请切换对应链路。" }
    if ambient && chain.acousticMode != "通透" { return "此测量属于通透状态，请切换对应链路。" }
    let analogMeasurement =
      n.contains("analog cable") || n.contains("wired") || n.contains("3.5 mm")
    let analogPath =
      chain.connection == "analog"
      || (!chain.frontend.isEmpty
        && ["usb", "wireless_24", "bluetooth"].contains(chain.connection))
    if analogMeasurement && !analogPath { return "此测量采用模拟线连接，请切换对应的有线/前端链路。" }
    if let model = EquipmentKnowledge.headphone(chain.headphone),
      !EquipmentKnowledge.connectionMatches(model, chain: chain)
    {
      return "当前连接与型号资料不符，请先确认实际连接。"
    }
    return nil
  }
  static func parameters(_ c: EQCandidate) async throws -> String {
    let data = try await Network.data(URLRequest(url: c.url), limit: 65536)
    let text = String(decoding: data, as: UTF8.self)
    _ = try EQMath.parse(text)
    return text
  }
}
enum AIService {
  static func json(
    base: String, model: String, key: String, instruction: String, payload: [String: Any]
  ) async throws -> [String: Any] {
    guard !key.isEmpty, !model.isEmpty else { throw AppFailure("请先配置模型与密钥") }
    var url = try Network.endpoint(base)
    url.appendPathComponent("chat/completions")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model, "response_format": ["type": "json_object"],
      "messages": [
        ["role": "system", "content": instruction],
        [
          "role": "user",
          "content": String(
            data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!,
        ],
      ],
    ])
    let data = try await Network.data(req, limit: 1024 * 1024)
    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = response["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String, let bytes = content.data(using: .utf8),
      let output = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    else { throw AppFailure("AI 响应格式无效") }
    return output
  }
  static func compose(
    endpoint: String, model: String, key: String, prompt: String, seconds: Int, directory: URL
  ) async throws -> Song {
    guard !key.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      prompt.count <= 4100, [30, 60, 120, 180].contains(seconds),
      ["music_v1", "music_v2", "music_v2_5"].contains(model)
    else { throw AppFailure("请配置音乐服务并填写有效描述") }
    let base = try Network.endpoint(endpoint)
    var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    c.queryItems = [.init(name: "output_format", value: "mp3_44100_128")]
    var request = URLRequest(url: c.url!)
    request.httpMethod = "POST"
    request.timeoutInterval = 180
    request.setValue(key, forHTTPHeaderField: "xi-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model_id": model, "prompt": prompt, "music_length_ms": seconds * 1000,
      "force_instrumental": true,
    ])
    let temp = try await Network.download(request, limit: 64 * 1024 * 1024)
    defer { try? FileManager.default.removeItem(at: temp) }
    try Task.checkCancellation()
    let audio = try AVAudioFile(forReading: temp)
    let name = UUID().uuidString + ".mp3"
    let dest = directory.appendingPathComponent(name)
    let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096)!
    try audio.read(into: buffer)
    guard buffer.frameLength > 0 else { throw AppFailure("生成音频无法解码") }
    try FileManager.default.moveItem(at: temp, to: dest)
    return Song(
      title: String(prompt.prefix(32)), artist: "AI · ElevenLabs", album: "Awake 原创作品",
      genre: "AI Generated", duration: Double(audio.length) / audio.processingFormat.sampleRate,
      sampleRate: audio.processingFormat.sampleRate, file: name)
  }
}
