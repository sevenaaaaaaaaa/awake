import Foundation

/// 免费数据源补全：艺人资料、专辑资料。
///
/// 只用公开、无需密钥的接口：MusicBrainz（元数据）+ Wikipedia（简介）。
/// 都带 User-Agent、都走 MetadataGate 限速；拿不到就留空，不编造内容。
enum FreeMetadata {
  static let agent = "Awake/0.9.29 (https://github.com/sevenaaaaaaaaa/awake)"

  struct Enrichment {
    var artistBio: String?
    var albumInfo: String?
    var credits: [String] = []
  }

  private static func get(_ base: String, query: [String: String] = [:]) async throws -> [String: Any] {
    let delay = await MetadataGate.shared.reserve()
    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    var components = URLComponents(string: base)!
    if !query.isEmpty {
      components.queryItems = query.map { .init(name: $0.key, value: $0.value) }
    }
    var request = URLRequest(url: components.url!)
    request.setValue(agent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 20
    let data = try await Network.data(request, limit: 512 * 1024)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AppFailure("返回的不是 JSON")
    }
    return object
  }

  private static func wikipediaSummary(_ title: String) async -> String? {
    let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
    for host in ["zh.wikipedia.org", "en.wikipedia.org"] {
      guard let url = URL(string: "https://\(host)/api/rest_v1/page/summary/\(encoded)") else { continue }
      var request = URLRequest(url: url)
      request.setValue(agent, forHTTPHeaderField: "User-Agent")
      request.timeoutInterval = 20
      guard let data = try? await Network.data(request, limit: 256 * 1024),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let extract = object["extract"] as? String,
        !extract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      return extract
    }
    return nil
  }

  static func enrich(artist: String, album: String) async -> Enrichment {
    var result = Enrichment()
    let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
    let unknown = cleanArtist.isEmpty || cleanArtist == "未知艺人"

    if !unknown {
      var lines: [String] = []
      let query = "artist:\"\(cleanArtist)\""
      if let object = try? await get(
        "https://musicbrainz.org/ws/2/artist/",
        query: ["query": query, "fmt": "json", "limit": "1"]),
        let rows = object["artists"] as? [[String: Any]],
        let first = rows.first
      {
        let name = first["name"] as? String ?? cleanArtist
        var facts: [String] = []
        if let type = first["type"] as? String { facts.append("类型：" + type) }
        if let area = first["area"] as? [String: Any], let areaName = area["name"] as? String {
          facts.append("地区：" + areaName)
        }
        if let span = first["life-span"] as? [String: Any], let begin = span["begin"] as? String {
          facts.append("起始：" + begin)
        }
        if let note = first["disambiguation"] as? String, !note.isEmpty {
          facts.append("说明：" + note)
        }
        if !facts.isEmpty { lines.append(name + " · " + facts.joined(separator: " · ")) }
        if let id = first["id"] as? String, !id.isEmpty {
          result.credits.append("MusicBrainz · https://musicbrainz.org/artist/" + id)
        }
      }
      if let summary = await wikipediaSummary(cleanArtist) {
        lines.append(summary)
        result.credits.append("Wikipedia · CC BY-SA · " + cleanArtist)
      }
      if !lines.isEmpty { result.artistBio = lines.joined(separator: "\n\n") }
    }

    if !cleanAlbum.isEmpty {
      var lines: [String] = []
      let artistClause = unknown ? "" : " AND artist:\"\(cleanArtist)\""
      let query = "releasegroup:\"\(cleanAlbum)\"" + artistClause
      if let object = try? await get(
        "https://musicbrainz.org/ws/2/release-group/",
        query: ["query": query, "fmt": "json", "limit": "1"]),
        let rows = object["release-groups"] as? [[String: Any]],
        let first = rows.first
      {
        var facts: [String] = []
        if let date = first["first-release-date"] as? String, !date.isEmpty {
          facts.append("首发：" + date)
        }
        if let type = first["primary-type"] as? String { facts.append("类型：" + type) }
        if let secondary = first["secondary-types"] as? [String], !secondary.isEmpty {
          facts.append("次级类型：" + secondary.joined(separator: "、"))
        }
        let title = first["title"] as? String ?? cleanAlbum
        if !facts.isEmpty { lines.append(title + " · " + facts.joined(separator: " · ")) }
        if let id = first["id"] as? String, !id.isEmpty {
          result.credits.append("MusicBrainz · https://musicbrainz.org/release-group/" + id)
        }
      }
      if let summary = await wikipediaSummary(cleanAlbum) {
        lines.append(summary)
      }
      if !lines.isEmpty { result.albumInfo = lines.joined(separator: "\n\n") }
    }

    result.credits = Array(Set(result.credits)).sorted()
    return result
  }
}
