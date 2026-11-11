import Foundation
import SwiftUI

struct TelegramCatalog: Decodable {
  struct Chat: Identifiable, Decodable { var id: String; var title: String; var kind: String }
  struct Folder: Identifiable, Decodable { var id: String; var title: String; var chat_ids: [String] }
  var chats: [Chat]
  var folders: [Folder]
}
struct TelegramAdvertisement: Identifiable, Decodable {
  var id: String; var title: String; var text: String; var url: String; var button: String
  var sponsor_info: String; var additional_info: String
}
enum TelegramService {
  static func request(base: String, path: String, secret: String, body: [String: Any]? = nil) throws -> URLRequest {
    guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AppFailure("请输入连接器访问令牌")
    }
    var root = try Network.endpoint(base, localHTTP: true)
    if !root.absoluteString.hasSuffix("/") { root.appendPathComponent("") }
    let endpoint = try Network.child(path, base: root)
    var req = URLRequest(url: endpoint)
    req.timeoutInterval = 240
    req.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
    if let body {
      req.httpMethod = "POST"
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    return req
  }
  static func catalog(base: String, secret: String) async throws -> TelegramCatalog {
    try JSONDecoder().decode(TelegramCatalog.self, from: await Network.data(request(base: base, path: "v1/catalog", secret: secret)))
  }
  static func collection(base: String, secret: String, ids: Set<String>, limit: Int) async throws -> String {
    struct Result: Decodable { var path: String }
    guard (1...20).contains(ids.count), (100...2000).contains(limit) else { throw AppFailure("请选择 1–20 个来源，消息范围为 100–2000 条") }
    let req = try request(base: base, path: "v1/libraries", secret: secret, body: ["chat_ids": ids.sorted(), "message_limit": limit])
    let result = try JSONDecoder().decode(Result.self, from: await Network.data(req))
    let root = try Network.endpoint(base.hasSuffix("/") ? base : base + "/", localHTTP: true)
    return try Network.child(result.path, base: root).absoluteString
  }
  static func scan(_ source: MusicSource, secret: String) async throws -> [Song] {
    struct Result: Decodable { var tracks: [Entry] }
    struct Entry: Decodable {
      var locator: String; var title: String; var artist: String; var album: String
      var duration: Double; var origin: String
    }
    _ = try await sponsored(source, secret: secret)
    let req = try request(base: source.url, path: "tracks", secret: secret)
    let result = try JSONDecoder().decode(Result.self, from: await Network.data(req, limit: 16 * 1024 * 1024))
    guard result.tracks.count <= 40000 else { throw AppFailure("Telegram 曲目超过上限") }
    var seen = Set<String>()
    let base = try Network.endpoint(source.url.hasSuffix("/") ? source.url : source.url + "/", localHTTP: true)
    return try result.tracks.map { row in
      guard row.locator.hasPrefix("media/"), seen.insert(row.locator).inserted,
        row.duration.isFinite, row.duration >= 0 else { throw AppFailure("音频列表存在无效或重复项目") }
      _ = try Network.child(row.locator, base: base)
      return Song(title: row.title, artist: row.artist, album: row.album, duration: row.duration,
                  sourceID: source.id, locator: row.locator, origin: row.origin)
    }
  }
  static func sponsored(_ source: MusicSource, secret: String) async throws -> [TelegramAdvertisement] {
    struct Result: Decodable { var messages: [TelegramAdvertisement] }
    let req = try request(base: source.url, path: "sponsored", secret: secret)
    return try JSONDecoder().decode(Result.self, from: await Network.data(req)).messages
  }
  static func viewed(_ ad: TelegramAdvertisement, source: MusicSource, secret: String) async throws {
    let req = try request(base: source.url, path: "viewed", secret: secret, body: ["id": ad.id])
    _ = try await Network.data(req)
  }
}

struct SourceConfiguration: Codable {
  var version: Int
  var kind: String
  var name: String
  var url: String
  var username: String?
  static func parse(_ text: String, format: String) throws -> Self {
    guard text.utf8.count <= 65536 else { throw AppFailure("配置文件不能超过 64 KB") }
    let allowed: Set<String> = ["version", "kind", "name", "url", "username"]
    var fields: [String: Any] = [:]
    func add(_ key: String, _ value: String) throws {
      guard allowed.contains(key), fields[key] == nil else { throw AppFailure("配置含未知或重复字段；凭据请在应用内填写") }
      if key == "version" {
        guard let version = Int(value) else { throw AppFailure("配置版本无效") }
        fields[key] = version
      } else { fields[key] = value }
    }
    switch format.lowercased() {
    case "json":
      guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            Set(object.keys).isSubset(of: allowed) else { throw AppFailure("JSON 配置格式无效或含未知字段") }
      fields = object
    case "txt":
      for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let equal = line.firstIndex(of: "=") else { throw AppFailure("TXT 每行需要为 字段=值") }
        try add(String(line[..<equal]).trimmingCharacters(in: .whitespaces),
                String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces))
      }
    case "xml":
      let delegate = ConfigurationXML()
      let parser = XMLParser(data: Data(text.utf8))
      parser.shouldResolveExternalEntities = false
      parser.delegate = delegate
      guard parser.parse(), !delegate.invalid else { throw AppFailure("XML 配置格式无效，根节点需要为 awake-source") }
      for (key, value) in delegate.fields { try add(key, value) }
    default: throw AppFailure("支持 JSON、XML 或 TXT 配置文件")
    }
    let result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: fields))
    guard result.version == 1, ["webdav", "plex", "telegram"].contains(result.kind),
          !result.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          result.name.utf8.count <= 240 else { throw AppFailure("请使用版本 1 的 WebDAV、Plex 或 Telegram 配置，并填写名称") }
    _ = try Network.endpoint(result.url, localHTTP: true)
    return result
  }
}
private final class ConfigurationXML: NSObject, XMLParserDelegate {
  var fields: [String: String] = [:], invalid = false
  private var depth = 0, key = "", text = ""
  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
    depth += 1
    if !attributes.isEmpty || depth > 2 || (depth == 1 && elementName != "awake-source") { invalid = true; parser.abortParsing() }
    if depth == 2 { key = elementName; text = "" }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) { if depth == 2 { text += string } }
  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
    if depth == 2 {
      if fields[key] != nil { invalid = true; parser.abortParsing() }
      fields[key] = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    depth -= 1
  }
  func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
  func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
}

struct TelegramSponsoredView: View {
  var source: MusicSource
  @State private var ads: [TelegramAdvertisement] = []
  @State private var error = ""
  @State private var seen = Set<String>()
  @State private var destination: URL?
  @State private var confirmLink = false
  @Environment(\.openURL) private var openURL
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary) }
      ForEach(ads) { ad in
        VStack(alignment: .leading, spacing: 6) {
          Text("Telegram 赞助消息").font(.caption).foregroundStyle(.secondary)
          Text(ad.title).font(.headline)
          Text(ad.text)
          if !ad.sponsor_info.isEmpty { Text(ad.sponsor_info).font(.caption) }
          if !ad.additional_info.isEmpty { Text(ad.additional_info).font(.caption) }
          Button(ad.button.isEmpty ? "查看" : ad.button) {
            if let url = URL(string: ad.url), ["https", "http", "tg"].contains(url.scheme ?? "") {
              destination = url; confirmLink = true
            }
          }
        }.onGeometryChange(for: Bool.self) { geometry in
          let frame = geometry.frame(in: .global)
          return frame.minY >= 0 && frame.maxY <= UIScreen.main.bounds.height
        } action: { visible in
          if visible && seen.insert(ad.id).inserted {
            Task {
              do { try await TelegramService.viewed(ad, source: source, secret: Secrets.get("source." + source.id)) }
              catch { seen.remove(ad.id) }
            }
          }
        }
      }
    }.task(id: source.id) {
      repeat {
        do { ads = try await TelegramService.sponsored(source, secret: Secrets.get("source." + source.id)); error = "" }
        catch { self.error = "Telegram 频道信息暂不可用" }
        do { try await Task.sleep(for: .seconds(300)) } catch { break }
      } while !Task.isCancelled
    }.confirmationDialog("打开此赞助消息链接？", isPresented: $confirmLink) {
      Button("打开链接") { if let destination { openURL(destination) } }
    }
  }
}
