import AVFoundation
import Foundation

final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
enum Network {
  static let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 30
    c.timeoutIntervalForResource = 240
    c.httpShouldSetCookies = false
    return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
  }()
  static func endpoint(_ text: String, localHTTP: Bool = false) throws -> URL {
    guard let u = URL(string: text), let host = u.host, u.user == nil, u.password == nil,
      u.query == nil, u.fragment == nil
    else { throw AppFailure("请输入不含凭据、查询参数的服务器地址") }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    let ipv4 =
      parts.count == 4 && parts.allSatisfy { (0...255).contains($0) }
      && host.split(separator: ".").count == 4
    let privateIP =
      ipv4
      && (parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
        || (parts[0] == 172 && (16...31).contains(parts[1]))
        || (parts[0] == 169 && parts[1] == 254))
    let local =
      host == "localhost" || host.hasSuffix(".local") || host == "::1" || host == "[::1]"
      || privateIP
    guard u.scheme == "https" || (localHTTP && local && u.scheme == "http") else {
      throw AppFailure("外部服务使用 HTTPS；局域网可使用 HTTP")
    }
    return u
  }
  static func check(_ response: URLResponse) throws {
    guard let r = response as? HTTPURLResponse, (200..<300).contains(r.statusCode) else {
      throw AppFailure("服务 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    }
  }
  static func data(_ request: URLRequest, limit: Int = 2 * 1024 * 1024) async throws -> Data {
    let (bytes, response) = try await session.bytes(for: request)
    try check(response)
    guard response.expectedContentLength <= limit else { throw AppFailure("服务响应过大") }
    var data = Data()
    data.reserveCapacity(min(limit, 65536))
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < limit else { throw AppFailure("服务响应超过限制") }
      data.append(byte)
    }
    return data
  }
  static func download(_ request: URLRequest, limit: Int64 = 4 * 1024 * 1024 * 1024) async throws
    -> URL
  {
    let (url, response) = try await session.download(for: request)
    do {
      try check(response)
      let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
      guard size > 0, Int64(size) <= limit else { throw AppFailure("音频为空或超过支持大小") }
      return url
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
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
    if source.kind == "plex" {
      r.setValue(secret, forHTTPHeaderField: "X-Plex-Token")
    } else if !source.username.isEmpty || !secret.isEmpty {
      r.setValue(
        "Basic " + Data((source.username + ":" + secret).utf8).base64EncodedString(),
        forHTTPHeaderField: "Authorization")
    }
    return r
  }
  static func scan(_ source: MusicSource, secret: String) async throws -> [Song] {
    let base = try Network.endpoint(source.url, localHTTP: true)
    if source.kind == "plex" {
      func api(_ path: String) throws -> URL {
        guard let u = URL(string: path, relativeTo: base.appendingPathComponent("/"))?.absoluteURL
        else { throw AppFailure("Plex 地址无效") }
        return try Network.child(u.absoluteString, base: base, restrictPath: false)
      }
      let xml = SourceXML()
      try xml.parse(
        try await Network.data(
          request(try api("library/sections"), source: source, secret: secret),
          limit: 8 * 1024 * 1024))
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
          try page.parse(
            try await Network.data(
              request(components.url!, source: source, secret: secret), limit: 8 * 1024 * 1024))
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
    var stack: [(URL, Int)] = [(root, 0)]
    var seen = Set<String>()
    var songs: [Song] = []
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
      try xml.parse(try await Network.data(req, limit: 8 * 1024 * 1024))
      guard xml.failures == 0 else { throw AppFailure("目录包含无法读取的项目，保留原索引") }
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
    return songs
  }
  static func cache(_ song: Song, source: MusicSource, secret: String, directory: URL) async throws
    -> Song
  {
    let base = try Network.endpoint(source.url, localHTTP: true)
    let url = try Network.child(song.locator, base: base, restrictPath: source.kind != "plex")
    let temp = try await Network.download(request(url, source: source, secret: secret))
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
