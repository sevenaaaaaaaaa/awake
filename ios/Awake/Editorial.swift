import Foundation

/// 首页「编排」：今日精选 + 专题。
///
/// 只吃轻量 Track，不依赖 Song / SwiftUI —— 这样 `Tools/verify_editorial.swift`
/// 能在两秒内把规则跑一遍，不需要模拟器。UI 侧只做 Song -> Track 的映射。
///
/// 原则：不猜用户的口味，只把库里已有的事实重新组织——
/// 收藏了还没评测、刚加入、同一位艺人、同一张专辑、够长的曲子、刚好凑一趟通勤的量。
///
/// `listenedSeconds` 的语义：Awake 没有播放次数，只有「听感评测记录」。
/// 所以它只表示「这首歌有没有被认真听过一遍（进过评测）」，文案一律说「评测」，
/// 绝不说「你还没听过」——那是没有证据的话。
enum Editorial {
  struct Track: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var favorite: Bool
    var addedAt: Date?
    var listenedSeconds: Double
  }

  struct Pick: Equatable {
    var trackID: String
    var reason: String
  }

  struct Collection: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var trackIDs: [String]
    /// 专题里的总数（不只是预览的前 8 首）。
    var trackCount: Int
  }

  /// 今日精选：收藏未听 > 最近 14 天新加入 > 常听艺人里没碰过的 > 接着上次 > 第一首。
  /// 每一条理由都必须说得出「为什么是这首」，不写「猜你喜欢」。
  static func pick(_ tracks: [Track], now: Date = Date()) -> Pick? {
    guard !tracks.isEmpty else { return nil }

    let unplayedFavorites = tracks
      .filter { $0.favorite && $0.listenedSeconds <= 0 }
      .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    if let song = unplayedFavorites.first {
      return Pick(trackID: song.id, reason: "你收下了它，还没进过评测。")
    }

    let recent = tracks
      .filter { track in
        guard let added = track.addedAt else { return false }
        return now.timeIntervalSince(added) <= 14 * 86_400
      }
      .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    if let song = recent.first {
      return Pick(trackID: song.id, reason: "最近 14 天新进来的，先听这首。")
    }

    let played = tracks.filter { $0.listenedSeconds > 0 }
    if let topArtist = Dictionary(grouping: played, by: \.artist)
      .max(by: { $0.value.count < $1.value.count })?.key,
      let song = tracks.first(where: { $0.artist == topArtist && $0.listenedSeconds <= 0 })
    {
      return Pick(trackID: song.id, reason: "你评测过 \(topArtist) 的歌，这首还没有记录。")
    }

    if let song = played.first {
      return Pick(trackID: song.id, reason: "这条已经评测过，再听一遍看这次有没有区别。")
    }

    return Pick(trackID: tracks[0].id, reason: "从这里开始。")
  }

  /// 专题：只在素材够的时候出现，宁缺不凑。每条预览最多 8 首。
  static func collections(_ tracks: [Track], now: Date = Date()) -> [Collection] {
    guard tracks.count >= 3 else { return [] }
    var out: [Collection] = []
    let playedIDs = Set(tracks.filter { $0.listenedSeconds > 0 }.map(\.id))

    let unplayed = tracks.filter { !playedIDs.contains($0.id) }
    if unplayed.count >= 3 {
      out.append(
        Collection(
          id: "unplayed", title: "还没评测过的",
          subtitle: "\(unplayed.count) 首还没有听感记录",
          trackIDs: unplayed.prefix(8).map(\.id), trackCount: unplayed.count))
    }

    let favorites = tracks.filter { $0.favorite }
    if favorites.count >= 3 {
      out.append(
        Collection(
          id: "favorites", title: "你收下的",
          subtitle: "\(favorites.count) 首亲手留下的",
          trackIDs: favorites.prefix(8).map(\.id), trackCount: favorites.count))
    }

    let longform = tracks.filter { $0.duration >= 240 }.sorted { $0.duration > $1.duration }
    if longform.count >= 3 {
      out.append(
        Collection(
          id: "longform", title: "留给灯关掉之后",
          subtitle: "四分钟以上的 \(longform.count) 首",
          trackIDs: longform.prefix(8).map(\.id), trackCount: longform.count))
    }

    let commute = commuteQueue(tracks, minutes: 20)
    let commuteSeconds = commute.reduce(0) { $0 + $1.duration }
    // 只有真凑够一趟通勤才出现：3 首 10 分钟也叫「通勤 20 分钟」是骗人。
    if commute.count >= 3, commuteSeconds >= 20 * 60 * 0.9 {
      out.append(
        Collection(
          id: "commute", title: "通勤 20 分钟",
          subtitle: "≈\(Int(commuteSeconds / 60)) 分钟",
          trackIDs: commute.map(\.id), trackCount: commute.count))
    }

    let recent = tracks
      .filter { track in
        guard let added = track.addedAt else { return false }
        return now.timeIntervalSince(added) <= 30 * 86_400
      }
      .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    if recent.count >= 3 {
      out.append(
        Collection(
          id: "recent", title: "刚加入的",
          subtitle: "最近 30 天",
          trackIDs: recent.prefix(8).map(\.id), trackCount: recent.count))
    }

    let byArtist = Dictionary(grouping: tracks.filter { $0.artist != "未知艺人" }, by: \.artist)
    if let top = byArtist.filter({ $0.value.count >= 3 }).max(by: { $0.value.count < $1.value.count }) {
      out.append(
        Collection(
          id: "artist", title: top.key,
          subtitle: "同一位艺人的 \(top.value.count) 首",
          trackIDs: top.value.prefix(8).map(\.id), trackCount: top.value.count))
    }

    let byAlbum = Dictionary(grouping: tracks.filter { !$0.album.isEmpty }, by: \.album)
    if let top = byAlbum.filter({ $0.value.count >= 3 }).max(by: { $0.value.count < $1.value.count }) {
      out.append(
        Collection(
          id: "album", title: top.key,
          subtitle: "一整张 \(top.value.count) 首",
          trackIDs: top.value.prefix(8).map(\.id), trackCount: top.value.count))
    }

    return out
  }

  /// 按曲库顺序凑到目标时长（不到 90% 也收，避免第一首就超长时返回空）。
  static func commuteQueue(_ tracks: [Track], minutes: Int) -> [Track] {
    let target = Double(minutes) * 60
    var total = 0.0
    var out: [Track] = []
    for track in tracks where track.duration > 0 {
      if total >= target * 0.9, !out.isEmpty { break }
      out.append(track)
      total += track.duration
      if out.count >= 8 { break }
    }
    return out
  }
}
