import Foundation

/// 听书进度：按书（专辑或单曲）保存上次听到的章节与位置。
struct BookProgress: Codable, Equatable {
  var songID: String?
  var position: Double = 0
  var finished = false
  var updatedAt = Date()
}

struct Book: Identifiable {
  var id: String
  var title: String
  var author: String
  var artwork: String?
  var chapters: [Song]
  var total: Double
  var listened: Double
  var currentSongID: String?
  var position: Double
  var finished: Bool
  var updatedAt: Date

  var percent: Double { total > 0 ? min(1, max(0, listened / total)) : 0 }
  var listenedLabel: String {
    let minutes = Int((listened / 60).rounded())
    return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分钟"
  }
}

enum BookShelf {
  static let markers = [
    "有声", "听书", "广播剧", "评书", "小说", "朗读", "演播",
    "audiobook", "audio book", "novel", "chapter", "全集", "连载",
  ]

  static func isBookMarker(_ text: String) -> Bool {
    let lower = text.lowercased()
    return markers.contains { lower.contains($0) }
  }

  /// 自然排序：第 2 章排在第 10 章之前。
  static func naturalCompare(_ a: String, _ b: String) -> Bool {
    let left = Array(a), right = Array(b)
    var i = 0, j = 0
    while i < left.count && j < right.count {
      let x = left[i], y = right[j]
      if x.isNumber && y.isNumber {
        var ni = i, nj = j
        var xn = 0, yn = 0
        while ni < left.count, let d = left[ni].wholeNumberValue {
          xn = xn * 10 + d; ni += 1
        }
        while nj < right.count, let d = right[nj].wholeNumberValue {
          yn = yn * 10 + d; nj += 1
        }
        if xn != yn { return xn < yn }
        i = ni; j = nj
      } else {
        if x.lowercased() != y.lowercased() {
          return x.lowercased() < y.lowercased()
        }
        i += 1; j += 1
      }
    }
    return left.count < right.count
  }

  static func shelf(_ songs: [Song], progress: [String: BookProgress]) -> [Book] {
    var groups: [String: [Song]] = [:]
    var titles: [String: String] = [:]
    for song in songs {
      let key: String
      let title: String
      if !song.album.trimmingCharacters(in: .whitespaces).isEmpty {
        key = "album|\(song.album.lowercased())|\(song.artist.lowercased())"
        title = song.album
      } else {
        // 没有专辑标签时，只把明确像有声书的长音频当成书。
        guard isBookMarker(song.title) || isBookMarker(song.artist) || song.duration >= 480 else {
          continue
        }
        key = "song|\(song.id)"
        title = song.title
      }
      titles[key] = titles[key] ?? title
      groups[key, default: []].append(song)
    }

    var books: [Book] = []
    for (key, list) in groups {
      let title = titles[key] ?? "未命名有声书"
      let average = list.reduce(0) { $0 + $1.duration } / Double(max(1, list.count))
      let musicalAlbum =
        !(list.first?.album ?? "").isEmpty
        && !isBookMarker(title)
        && average < 480
        && !(list.count >= 3 && average >= 300)
      if musicalAlbum { continue }

      let chapters = list.sorted { a, b in
        if a.segmentStart != nil || b.segmentStart != nil {
          return (a.segmentStart ?? 0) < (b.segmentStart ?? 0)
        }
        return naturalCompare(a.title, b.title)
      }
      let total = chapters.reduce(0) { $0 + $1.duration }
      let state = progress[key]
      var listened = 0.0
      var position = 0.0
      if let state, let songID = state.songID,
        let index = chapters.firstIndex(where: { $0.id == songID })
      {
        listened = chapters.prefix(index).reduce(0) { $0 + $1.duration } + state.position
        position = state.position
      }
      books.append(
        Book(
          id: key, title: title, author: chapters.first?.artist ?? "",
          artwork: chapters.first?.artwork, chapters: chapters, total: total,
          listened: min(listened, total), currentSongID: state?.songID,
          position: position, finished: state?.finished ?? false,
          updatedAt: state?.updatedAt ?? .distantPast))
    }
    books.sort { a, b in
      func rank(_ book: Book) -> Int {
        if book.finished { return 2 }
        if book.updatedAt > .distantPast || book.listened > 0 { return 0 }
        return 1
      }
      if rank(a) != rank(b) { return rank(a) < rank(b) }
      if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
      return naturalCompare(a.title, b.title)
    }
    return books
  }

  static func book(containing song: Song, in books: [Book]) -> Book? {
    books.first { book in book.chapters.contains { $0.id == song.id } }
  }
}

struct WeeklyDay: Identifiable {
  var id: Int { index }
  var index: Int
  var seconds: Double
}

struct WeeklySummary {
  var since: Date
  var until: Date
  var seconds: Double
  var plays: Int
  var completed: Int
  var artistCount: Int
  var bookCount: Int
  var topSongs: [(song: Song, plays: Int, seconds: Double)]
  var topArtists: [(artist: String, seconds: Double)]
  var days: [WeeklyDay]
  var lines: [String]

  var minutes: Int { Int((seconds / 60).rounded()) }

  static func make(
    songs: [Song], listens: [Listen], progress: [String: BookProgress], now: Date = Date(),
    calendar: Calendar = .current
  ) -> WeeklySummary {
    var cal = calendar
    cal.firstWeekday = 2
    let start = cal.startOfDay(for: now)
    let weekday = cal.component(.weekday, from: start)
    let offset = (weekday + 5) % 7
    let since = cal.date(byAdding: .day, value: -offset, to: start) ?? start
    let until = cal.date(byAdding: .day, value: 7, to: since) ?? now

    let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
    var perSong: [String: (count: Int, seconds: Double)] = [:]
    var perArtist: [String: Double] = [:]
    var daySeconds = Array(repeating: 0.0, count: 7)
    var seconds = 0.0
    var plays = 0
    var completed = 0

    for event in listens where event.at >= since && event.at < until {
      guard let song = byID[event.songID], event.seconds.isFinite, event.seconds > 0 else {
        continue
      }
      seconds += event.seconds
      let threshold = min(120, max(0.1, song.duration / 2))
      if event.seconds >= threshold {
        plays += 1
        perSong[event.songID, default: (0, 0)].count += 1
        perArtist[song.artist, default: 0] += event.seconds
      }
      perSong[event.songID, default: (0, 0)].seconds += event.seconds
      if song.duration > 0 && event.seconds >= song.duration * 0.9 { completed += 1 }
      let day = cal.dateComponents([.day], from: since, to: event.at).day ?? 0
      if (0..<7).contains(day) { daySeconds[day] += event.seconds }
    }

    let topSongs =
      perSong.compactMap { id, value -> (Song, Int, Double)? in
        guard let song = byID[id] else { return nil }
        return (song, value.count, value.seconds)
      }
      .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }
      .prefix(5)
      .map { ($0.0, $0.1, $0.2) }
    let topArtists =
      perArtist.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    let books = progress.values.filter { $0.updatedAt >= since && $0.updatedAt < until }.count
    var lines: [String] = []
    if plays == 0 && seconds < 60 {
      lines.append("这周还没有完整的聆听记录。放一首喜欢的歌，下周的总结会从这里开始。")
    } else {
      lines.append("这周你听了 \(Int((seconds / 60).rounded())) 分钟，完整听完 \(plays) 首。")
      if let first = topSongs.first {
        lines.append("最常播放的是《\(first.0.title)》，来自 \(first.0.artist)。")
      }
      if let artist = topArtists.first {
        lines.append("\(artist.0) 陪你最久，共 \(Int((artist.1 / 60).rounded())) 分钟。")
      }
      if completed > 0 { lines.append("有 \(completed) 次播放自然播完，说明它们经得起完整聆听。") }
      if books > 0 { lines.append("还有 \(books) 本书在进行中，记得回来接着听。") }
    }
    return WeeklySummary(
      since: since, until: until, seconds: seconds, plays: plays, completed: completed,
      artistCount: Set(perArtist.keys).count, bookCount: books,
      topSongs: topSongs, topArtists: topArtists.map { ($0.0, $0.1) },
      days: daySeconds.enumerated().map { WeeklyDay(index: $0.offset, seconds: $0.element) },
      lines: lines)
  }
}
