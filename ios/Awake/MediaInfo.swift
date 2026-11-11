import Foundation
import SwiftUI
import ImageIO

struct MediaReview: Codable, Identifiable, Equatable {
  var author: String; var text: String; var source: String; var url: String
  var scope: String; var license: String; var license_url: String
  var id: String { source + url + author + text }
}
struct MediaInfo: Codable, Equatable {
  var original_title = "", original_artist = "", original_album = ""
  var original_artwork: String?
  var original_comment = "", original_lyrics = ""
  var source_note = "", suggested_filename = "", cover_style = "auto"
  var credits: [String] = []
  var reviews: [MediaReview] = []
}
struct MediaCandidate: Codable, Identifiable {
  var id: String, title: String, artist: String, album: String, release_id: String, group_id: String
  var duration: Double, score: Int
}
struct MediaResources { var artwork: String?; var lyrics = ""; var reviews: [MediaReview] = []; var credits: [String] = []; var warnings: [String] = [] }

enum MediaNaming {
  static func suggest(filename: String, title: String, artist: String) -> (title: String, artist: String, filename: String) {
    let leaf = URL(fileURLWithPath: filename).lastPathComponent
    let ext = URL(fileURLWithPath: leaf).pathExtension
    let stem = URL(fileURLWithPath: leaf).deletingPathExtension().lastPathComponent
    var clean = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == stem ? stem : title
    clean = clean.replacingOccurrences(of: "_", with: " ")
    for marker in ["[FLAC]", "[MP3]", "[WAV]", "[无损]", "【无损】", "[320kbps]", "[24bit]", "[16bit]", "[Hi-Res]"] {
      clean = clean.replacingOccurrences(of: marker, with: "")
    }
    if let brackets = try? NSRegularExpression(pattern: "[\\[【]([^\\]】]{1,80})[\\]】]") {
      let ns = clean as NSString
      for match in brackets.matches(in: clean, range: NSRange(location: 0, length: ns.length)).reversed() {
        let inside = ns.substring(with: match.range(at: 1))
        if inside.range(of: "(?i)(flac|mp3|alac|hi-res|无损|高品质|[0-9]+(?:\\.[0-9]+)?\\s*(?:kbps|khz|bit))", options: .regularExpression) != nil,
           inside.range(of: "(?i)(live|remix|acoustic|现场)", options: .regularExpression) == nil,
           let range = Range(match.range, in: clean) { clean.removeSubrange(range) }
      }
    }
    clean = clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    clean = clean.replacingOccurrences(of: "^[0-9]{1,3}(?:\\. | - )+", with: "", options: .regularExpression)
    var performer = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    if performer.isEmpty || performer == "未知艺人", let separator = clean.range(of: " - ") {
      let a = String(clean[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
      let b = String(clean[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
      if !a.isEmpty && !b.isEmpty { performer = a; clean = b }
    }
    if clean.isEmpty { clean = "未命名音频" }
    let combined = performer.isEmpty || performer == "未知艺人" ? clean : performer + " - " + clean
    let safe = String(combined.prefix(120)).map { "<>:\"/\\|?*".contains($0) || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? "_" : String($0) }.joined().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return (clean, performer, safe + (ext.isEmpty ? "" : "." + ext.lowercased()))
  }
}
enum MediaArt {
  static func persist(_ data: Data, directory: URL) throws -> String {
    guard data.count <= 8 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
          w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 32000000,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
          let bytes = UIImage(cgImage: image).jpegData(compressionQuality: 0.9) else { throw AppFailure("封面图片无效、超过 8 MB 或像素过大") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = UUID().uuidString + ".jpg"
    try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
    return name
  }
}
actor MetadataGate {
  static let shared = MetadataGate()
  private var next = Date.distantPast
  func reserve() -> TimeInterval {
    let start = max(next, Date())
    next = start.addingTimeInterval(1.1)
    return max(0, start.timeIntervalSinceNow)
  }
}
enum MediaLookup {
  static let agent = "Awake/0.7.5 (https://github.com/sevenaaaaaaaaa/awake)"
  static func json(_ base: String, query: [String: String]) async throws -> Any {
    let delay = await MetadataGate.shared.reserve()
    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    var components = URLComponents(string: base)!
    components.queryItems = query.map { .init(name: $0.key, value: $0.value) }
    var request = URLRequest(url: components.url!); request.setValue(agent, forHTTPHeaderField: "User-Agent")
    return try JSONSerialization.jsonObject(with: await Network.data(request))
  }
  static func candidates(_ object: Any) -> [MediaCandidate] {
    guard let root = object as? [String: Any], let rows = root["recordings"] as? [[String: Any]] else { return [] }
    return rows.prefix(10).compactMap { row in
      guard let id = row["id"] as? String, UUID(uuidString: id) != nil else { return nil }
      let release = (row["releases"] as? [[String: Any]])?.first ?? [:]
      let group = release["release-group"] as? [String: Any] ?? [:]
      let artist = (row["artist-credit"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? (($0["artist"] as? [String: Any])?["name"] as? String) ?? "") + ($0["joinphrase"] as? String ?? "") }.joined()
      return MediaCandidate(id: id, title: row["title"] as? String ?? "", artist: artist, album: release["title"] as? String ?? "", release_id: release["id"] as? String ?? "", group_id: group["id"] as? String ?? "", duration: min(604800, max(0, (row["length"] as? Double ?? 0) / 1000)), score: row["score"] as? Int ?? 0)
    }
  }
  static func search(title: String, artist: String) async throws -> [MediaCandidate] {
    guard !title.isEmpty, title.utf8.count <= 500, artist.utf8.count <= 500 else { throw AppFailure("请输入不超过 500 字节的曲名与艺人") }
    func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: " ").replacingOccurrences(of: "\"", with: " ") }
    let query = "recording:\"\(escape(title))\"" + (artist.isEmpty ? "" : " AND artist:\"\(escape(artist))\"")
    if let object = try? await json("https://musicbrainz.org/ws/2/recording/", query: ["query": query, "fmt": "json", "limit": "10"]) {
      let rows = candidates(object)
      if !rows.isEmpty { return rows }
    }
    var parameters = ["track_name": title]
    if !artist.isEmpty { parameters["artist_name"] = artist }
    guard let rows = try await json("https://lrclib.net/api/search", query: parameters) as? [[String: Any]] else { return [] }
    return rows.prefix(10).compactMap { row in
      guard let id = row["id"] as? Int, let title = row["trackName"] as? String else { return nil }
      return MediaCandidate(id: "lrclib:\(id)", title: title, artist: row["artistName"] as? String ?? "", album: row["albumName"] as? String ?? "", release_id: "", group_id: "", duration: min(604800, max(0, row["duration"] as? Double ?? 0)), score: 0)
    }
  }
  static func reviews(_ object: Any, scope: String) -> [MediaReview] {
    guard let root = object as? [String: Any], let rows = root["reviews"] as? [[String: Any]] else { return [] }
    return Array(rows.compactMap { row -> MediaReview? in
      let license = row["license"] as? [String: Any] ?? [:]
      guard let name = license["id"] as? String,
            ["CC0", "CC0 1.0", "CC BY 3.0", "CC BY 4.0", "CC BY-SA 3.0", "CC BY-SA 4.0"].contains(name),
            let id = row["id"] as? String, UUID(uuidString: id) != nil,
            let text = row["text"] as? String, !text.isEmpty, text.utf8.count <= 20000 else { return nil }
      let user = row["user"] as? [String: Any] ?? [:]
      return MediaReview(author: user["display_name"] as? String ?? "未署名", text: text, source: "CritiqueBrainz", url: "https://critiquebrainz.org/review/" + id, scope: scope, license: name, license_url: license["info_url"] as? String ?? "")
    }.prefix(10))
  }
  static func cover(_ release: String, directory: URL) async throws -> String? {
    guard UUID(uuidString: release) != nil else { return nil }
    var url = URL(string: "https://coverartarchive.org/release/\(release)/front-500")!
    for _ in 0..<6 {
      var request = URLRequest(url: url); request.setValue(agent, forHTTPHeaderField: "User-Agent")
      let (bytes, response) = try await Network.session.bytes(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if status == 404 { return nil }
      if (300..<400).contains(status), let value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
         let next = URL(string: value, relativeTo: url)?.absoluteURL, let host = next.host,
         next.scheme == "https", host == "coverartarchive.org" || host == "archive.org" || host.hasSuffix(".archive.org") {
        url = next; continue
      }
      try Network.check(response)
      var data = Data()
      for try await byte in bytes { guard data.count < 8 * 1024 * 1024 else { throw AppFailure("封面超过 8 MB") }; data.append(byte) }
      return try MediaArt.persist(data, directory: directory)
    }
    throw AppFailure("封面重定向过多")
  }
  static func resources(_ candidate: MediaCandidate, directory: URL) async -> MediaResources {
    var result = MediaResources()
    if candidate.id.hasPrefix("lrclib:"), let id = Int(candidate.id.dropFirst(7)), id >= 0 {
      do {
        if let row = try await json("https://lrclib.net/api/get/\(id)", query: [:]) as? [String: Any] {
          result.lyrics = (row["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? row["plainLyrics"] as? String ?? ""
          result.credits = ["LRCLIB · https://lrclib.net/api/get/\(id)"]
        }
        result.warnings = ["歌词库候选未确认 MusicBrainz 身份，封面与乐评保持原样"]
      } catch { result.warnings = ["歌词：" + error.localizedDescription] }
      return result
    }
    result.credits = ["MusicBrainz · https://musicbrainz.org/recording/" + candidate.id]
    do {
      result.artwork = try await cover(candidate.release_id, directory: directory)
      if result.artwork != nil { result.credits.append("Cover Art Archive · https://coverartarchive.org/release/" + candidate.release_id) }
    } catch { result.warnings.append("封面：" + error.localizedDescription) }
    do {
      var query = ["track_name": candidate.title, "artist_name": candidate.artist, "album_name": candidate.album]
      if candidate.duration > 0 && candidate.duration <= 3600 { query["duration"] = String(Int(candidate.duration.rounded())) }
      if let value = try await json("https://lrclib.net/api/get", query: query) as? [String: Any] {
        result.lyrics = value["syncedLyrics"] as? String ?? value["plainLyrics"] as? String ?? ""
        if let id = value["id"] as? Int { result.credits.append("LRCLIB · https://lrclib.net/api/get/\(id)") }
      }
    } catch { result.warnings.append("歌词：" + error.localizedDescription) }
    for (scope, id) in [("recording", candidate.id), ("release_group", candidate.group_id)] where UUID(uuidString: id) != nil {
      do { result.reviews += reviews(try await json("https://critiquebrainz.org/ws/1/review/", query: ["entity_id": id, "entity_type": scope, "limit": "10"]), scope: scope) }
      catch { result.warnings.append("乐评：" + error.localizedDescription) }
    }
    return result
  }
}

extension MobileStore {
  var artworkDirectory: URL { root.appendingPathComponent("Artwork", isDirectory: true) }
  func artworkURL(_ name: String?) -> URL? {
    guard let name, URL(fileURLWithPath: name).lastPathComponent == name else { return nil }
    return artworkDirectory.appendingPathComponent(name)
  }
  func saveMedia(_ proposed: Song) throws {
    guard let i = state.songs.firstIndex(where: { $0.id == proposed.id }), let info = proposed.mediaInfo,
          !proposed.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          proposed.title.utf8.count <= 1000, proposed.artist.utf8.count <= 1000, proposed.album.utf8.count <= 1000,
          (proposed.lyrics ?? "").utf8.count <= 131072, (proposed.comment ?? "").utf8.count <= 16000,
          info.source_note.utf8.count <= 4000, info.reviews.count <= 50,
          ["auto", "original", "nocturne", "forest", "amber", "rose"].contains(info.cover_style) else { throw AppFailure("资料字段为空、无效或超过支持长度") }
    for r in info.reviews {
      guard r.text.utf8.count <= 20000, r.author.utf8.count <= 1000, r.url.utf8.count <= 2000,
            ["recording", "release_group", "imported"].contains(r.scope) else { throw AppFailure("评论格式无效") }
    }
    let previous = state.songs[i]
    var saved = proposed
    saved.id = previous.id; saved.file = previous.file; saved.sourceID = previous.sourceID; saved.locator = previous.locator; saved.origin = previous.origin
    if let original = previous.mediaInfo {
      saved.mediaInfo?.original_title = original.original_title; saved.mediaInfo?.original_artist = original.original_artist
      saved.mediaInfo?.original_album = original.original_album; saved.mediaInfo?.original_artwork = original.original_artwork
      saved.mediaInfo?.original_lyrics = original.original_lyrics; saved.mediaInfo?.original_comment = original.original_comment
    }
    state.songs[i] = saved
    do { try persist() } catch { state.songs[i] = previous; throw error }
  }
  func resetMedia(_ id: String) throws {
    guard let i = state.songs.firstIndex(where: { $0.id == id }), let info = state.songs[i].mediaInfo else { return }
    let previous = state.songs[i]
    state.songs[i].title = info.original_title; state.songs[i].artist = info.original_artist; state.songs[i].album = info.original_album
    state.songs[i].artwork = info.original_artwork; state.songs[i].lyrics = info.original_lyrics; state.songs[i].comment = info.original_comment
    state.songs[i].mediaInfo = nil
    do { try persist() } catch { state.songs[i] = previous; throw error }
  }
}
