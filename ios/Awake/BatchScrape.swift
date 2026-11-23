import SwiftUI

/// 批量刮削：按专辑把「缺的」补齐——歌词走 LRCLIB，封面走 iTunes Search，
/// 艺人/专辑资料走 MusicBrainz + Wikipedia（每张专辑只查一次）。
///
/// 全部请求经 MetadataGate 限速（约 1 次/秒），顺序执行、可取消；失败逐条记账，不吞。
enum ScrapeSource {
  private static let agent = "Awake/0.9.33 (https://github.com/sevenaaaaaaaaa/awake)"

  static func lyrics(_ song: Song) async throws -> String? {
    let delay = await MetadataGate.shared.reserve()
    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    var components = URLComponents(string: "https://lrclib.net/api/get")!
    var items: [URLQueryItem] = [
      .init(name: "track_name", value: song.title),
      .init(name: "artist_name", value: song.artist == "未知艺人" ? "" : song.artist),
    ]
    if !song.album.isEmpty { items.append(.init(name: "album_name", value: song.album)) }
    if song.duration > 0 { items.append(.init(name: "duration", value: String(Int(song.duration.rounded())))) }
    components.queryItems = items
    var request = URLRequest(url: components.url!)
    request.setValue(agent, forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20
    guard let data = try? await Network.data(request, limit: 256 * 1024),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let synced = (object["syncedLyrics"] as? String) ?? ""
    let plain = (object["plainLyrics"] as? String) ?? ""
    let text = synced.isEmpty ? plain : synced
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : text
  }

  static func cover(_ song: Song) async throws -> Data? {
    let delay = await MetadataGate.shared.reserve()
    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    var components = URLComponents(string: "https://itunes.apple.com/search")!
    let term = [song.artist == "未知艺人" ? "" : song.artist, song.album.isEmpty ? song.title : song.album]
      .filter { !$0.isEmpty }.joined(separator: " ")
    components.queryItems = [
      .init(name: "term", value: term),
      .init(name: "media", value: "music"),
      .init(name: "entity", value: "album"),
      .init(name: "limit", value: "5"),
    ]
    var request = URLRequest(url: components.url!)
    request.timeoutInterval = 20
    guard let data = try? await Network.data(request, limit: 512 * 1024),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rows = object["results"] as? [[String: Any]],
      let first = rows.first,
      var artwork = first["artworkUrl100"] as? String
    else { return nil }
    artwork = artwork.replacingOccurrences(of: "100x100bb", with: "600x600bb")
    guard let url = URL(string: artwork), url.scheme == "https" else { return nil }
    var image = URLRequest(url: url)
    image.timeoutInterval = 25
    return try? await Network.data(image, limit: 8 * 1024 * 1024)
  }
}

@MainActor
final class BatchScraper: ObservableObject {
  struct Failure: Identifiable {
    let id = UUID()
    var title: String
    var step: String
    var message: String
  }
  struct Group: Identifiable {
    var id: String
    var title: String
    var detail: String
    var songs: [Song]
  }

  @Published var running = false
  @Published var done = 0
  @Published var total = 0
  @Published var failures: [Failure] = []
  @Published var finished = false

  static func groups(_ songs: [Song]) -> [Group] {
    let key: (Song) -> String = { song in
      let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
      let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
      return album.isEmpty ? "folder:" + (song.folder ?? "未分文件夹") : artist + "|" + album
    }
    var map: [String: [Song]] = [:]
    for song in songs { map[key(song), default: []].append(song) }
    return map.map { id, list in
      let song = list[0]
      let album = song.album.isEmpty ? (song.folder ?? "未分文件夹") : song.album
      let missingLyrics = list.filter { ($0.lyrics ?? "").isEmpty }.count
      let missingCover = list.filter { $0.artwork == nil }.count
      return Group(
        id: id, title: album,
        detail: "\(list.count) 首 · 缺歌词 \(missingLyrics) · 缺封面 \(missingCover)",
        songs: list)
    }.sorted { $0.songs.count > $1.songs.count }
  }

  func run(_ songs: [Song], store: MobileStore) async {
    guard !running, !songs.isEmpty else { return }
    running = true; finished = false; done = 0; total = songs.count; failures = []
    var infoDone = Set<String>()
    for song in songs {
      if Task.isCancelled { break }
      var current = store.state.songs.first(where: { $0.id == song.id }) ?? song
      var changed = false

      if (current.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        do {
          if let text = try await ScrapeSource.lyrics(current) {
            current.lyrics = text
            changed = true
          } else {
            failures.append(.init(title: current.title, step: "歌词", message: "没找到匹配的歌词"))
          }
        } catch {
          failures.append(.init(title: current.title, step: "歌词", message: error.localizedDescription))
        }
      }

      if current.artwork == nil {
        do {
          if let data = try await ScrapeSource.cover(current),
            let name = try? MediaArt.persist(data, directory: store.artworkDirectory)
          {
            current.artwork = name
            changed = true
          } else {
            failures.append(.init(title: current.title, step: "封面", message: "没找到可用封面"))
          }
        } catch {
          failures.append(.init(title: current.title, step: "封面", message: error.localizedDescription))
        }
      }

      // 艺人/专辑资料每张专辑只查一次，写进这张专辑下每首歌的档案。
      let infoKey = current.artist + "|" + current.album
      if !current.album.isEmpty, !infoDone.contains(infoKey) {
        infoDone.insert(infoKey)
        let enrichment = await FreeMetadata.enrich(artist: current.artist, album: current.album)
        if enrichment.artistBio != nil || enrichment.albumInfo != nil {
          for index in store.state.songs.indices where
            store.state.songs[index].artist == current.artist
              && store.state.songs[index].album == current.album
          {
            var target = store.state.songs[index]
            var info = target.mediaInfo ?? MediaInfo(
              original_title: target.title, original_artist: target.artist,
              original_album: target.album, original_artwork: target.artwork,
              original_comment: target.comment ?? "", original_lyrics: target.lyrics ?? "")
            if let bio = enrichment.artistBio { info.artist_bio = bio }
            if let albumInfo = enrichment.albumInfo { info.album_info = albumInfo }
            info.credits = Array(Set(info.credits + enrichment.credits)).sorted()
            target.mediaInfo = info
            store.state.songs[index] = target
          }
          changed = true
        }
      }

      if changed, let index = store.state.songs.firstIndex(where: { $0.id == current.id }) {
        var merged = current
        if let existing = store.state.songs[index].mediaInfo { merged.mediaInfo = existing }
        store.state.songs[index] = merged
        store.save()
      }
      done += 1
    }
    running = false
    finished = true
  }
}
