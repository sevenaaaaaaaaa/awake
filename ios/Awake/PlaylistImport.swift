import Foundation

/// 外部歌单解析与本地匹配。所有平台歌单只取元数据，不下载任何版权音频。
struct ImportedTrack: Identifiable, Equatable {
  var id = UUID().uuidString
  var title: String
  var artist = ""
  var album = ""
  var duration: Double = 0
  var isrc = ""
  var fileName: String?
  var segmentStart: Double?
  var segmentEnd: Double?
  var disc = 0
  var number = 0
}

struct ImportedPlaylist {
  var name: String
  var source: String
  var tracks: [ImportedTrack]
  var note = ""
}

struct CueSheetInfo {
  var album = ""
  var performer = ""
  var fileName = ""
  var tracks: [ImportedTrack] = []
}

struct PlaylistMatch: Identifiable {
  var id: String { track.id }
  var track: ImportedTrack
  var song: Song?
  var score = 0.0
  var reason = ""
  var enabled = true
  var hasMatch: Bool { song != nil }
}

enum PlaylistParser {
  static func detect(fileName: String, data: Data) throws -> ImportedPlaylist {
    guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    else { throw AppFailure("这个文件不是 UTF-8 / UTF-16 文本") }
    let ext = (fileName as NSString).pathExtension.lowercased()
    let name = (fileName as NSString).deletingPathExtension
    switch ext {
    case "cue":
      let sheet = try cue(content)
      return ImportedPlaylist(
        name: sheet.album.isEmpty ? name : sheet.album,
        source: "CUE", tracks: sheet.tracks,
        note: "CUE 曲目需要整轨音频已经在曲库中；APE 需要先转成 FLAC / ALAC 才能播放。")
    case "m3u", "m3u8":
      return ImportedPlaylist(name: name, source: "M3U", tracks: m3u(content))
    case "pls":
      return ImportedPlaylist(name: name, source: "PLS", tracks: pls(content))
    case "csv", "tsv":
      return ImportedPlaylist(name: name, source: "CSV", tracks: csv(content))
    case "json":
      return ImportedPlaylist(name: name, source: "JSON", tracks: try json(data))
    default:
      return ImportedPlaylist(name: name, source: "文本", tracks: text(content))
    }
  }

  /// 粘贴的文本：优先按 “艺人 - 歌名” 解析，其次按 tab / 连续空格 / 行号前缀。
  static func text(_ raw: String) -> [ImportedTrack] {
    var rows: [ImportedTrack] = []
    for rawLine in raw.components(separatedBy: .newlines) {
      var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      line = line.replacingOccurrences(
        of: #"^\s*\d+[.)、]\s*"#, with: "", options: .regularExpression)
      var artist = ""
      var title = line
      if let range = line.range(of: " - ") {
        artist = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        title = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
      } else if let range = line.range(of: " – ") {
        artist = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        title = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
      } else if line.contains("\t") {
        let parts = line.split(separator: "\t").map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.count >= 2 {
          title = parts[0]
          artist = parts[1]
        }
      }
      guard !title.isEmpty else { continue }
      rows.append(ImportedTrack(title: title, artist: artist, number: rows.count + 1))
    }
    return rows
  }

  static func m3u(_ raw: String) -> [ImportedTrack] {
    var rows: [ImportedTrack] = []
    var pending: ImportedTrack?
    for rawLine in raw.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      if line.hasPrefix("#EXTINF:") {
        let body = String(line.dropFirst("#EXTINF:".count))
        let pieces = body.split(separator: ",", maxSplits: 1).map(String.init)
        let seconds = Double(pieces.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        var title = pieces.count > 1 ? pieces[1] : ""
        var artist = ""
        if let range = title.range(of: " - ") {
          artist = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
          title = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        pending = ImportedTrack(
          title: title, artist: artist, duration: max(0, seconds),
          number: rows.count + 1)
      } else if line.hasPrefix("#") {
        continue
      } else {
        var track = pending ?? ImportedTrack(
          title: (line as NSString).lastPathComponent, number: rows.count + 1)
        if track.title.isEmpty { track.title = (line as NSString).lastPathComponent }
        track.fileName = (line as NSString).lastPathComponent
        rows.append(track)
        pending = nil
      }
    }
    if let pending { rows.append(pending) }
    return rows
  }

  static func pls(_ raw: String) -> [ImportedTrack] {
    var fields: [String: [String: String]] = [:]
    for rawLine in raw.components(separatedBy: .newlines) {
      guard let eq = rawLine.firstIndex(of: "=") else { continue }
      let key = String(rawLine[..<eq])
      let value = String(rawLine[rawLine.index(after: eq)...]).trimmingCharacters(
        in: .whitespaces)
      guard let indexStart = key.firstIndex(where: { $0.isNumber }) else { continue }
      let number = String(key[indexStart...])
      let name = String(key[..<indexStart]).lowercased()
      fields[number, default: [:]][name] = value
    }
    return fields.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { key in
      let row = fields[key] ?? [:]
      let file = row["file"] ?? ""
      let title = row["title"] ?? (file as NSString).lastPathComponent
      guard !title.isEmpty else { return nil }
      return ImportedTrack(
        title: title, artist: row["artist"] ?? "", album: row["album"] ?? "",
        duration: Double(row["length"] ?? "") ?? 0, fileName: (file as NSString).lastPathComponent,
        number: Int(key) ?? 0)
    }
  }

  static func csv(_ raw: String) -> [ImportedTrack] {
    let lines = raw.components(separatedBy: .newlines).filter {
      !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }
    guard !lines.isEmpty else { return [] }
    func cells(_ line: String) -> [String] {
      var result: [String] = []
      var current = ""
      var quoted = false
      for ch in line {
        if ch == "\"" { quoted.toggle(); continue }
        if ch == "," && !quoted {
          result.append(current.trimmingCharacters(in: .whitespaces))
          current = ""
        } else { current.append(ch) }
      }
      result.append(current.trimmingCharacters(in: .whitespaces))
      return result
    }
    var start = 0
    var map: [String: Int] = [:]
    let header = cells(lines[0]).map { $0.lowercased() }
    if header.contains(where: { ["title", "name", "song", "歌名", "歌曲"].contains($0) }) {
      for (i, key) in header.enumerated() { map[key] = i }
      start = 1
    }
    func index(_ keys: [String]) -> Int? { keys.compactMap { map[$0] }.first }
    var rows: [ImportedTrack] = []
    for line in lines[start...] {
      let cols = cells(line)
      let title: String
      let artist: String
      if !map.isEmpty {
        title = index(["title", "name", "song", "歌名", "歌曲"]).flatMap {
          cols.indices.contains($0) ? cols[$0] : nil
        } ?? ""
        artist = index(["artist", "artists", "歌手", "艺人"]).flatMap {
          cols.indices.contains($0) ? cols[$0] : nil
        } ?? ""
      } else {
        title = cols.first ?? ""
        artist = cols.count > 1 ? cols[1] : ""
      }
      guard !title.isEmpty else { continue }
      rows.append(
        ImportedTrack(
          title: title, artist: artist,
          album: index(["album", "专辑"]).flatMap {
            cols.indices.contains($0) ? cols[$0] : nil
          } ?? "",
          duration: index(["duration", "时长", "length"]).flatMap {
            cols.indices.contains($0) ? Double(cols[$0]) ?? 0 : nil
          } ?? 0,
          number: rows.count + 1))
    }
    return rows
  }

  static func json(_ data: Data) throws -> [ImportedTrack] {
    let object = try JSONSerialization.jsonObject(with: data)
    var list: [[String: Any]] = []
    if let array = object as? [[String: Any]] {
      list = array
    } else if let dict = object as? [String: Any] {
      for key in ["tracks", "songs", "items", "entries"] {
        if let array = dict[key] as? [[String: Any]] { list = array; break }
      }
    }
    return list.compactMap { row in
      let title = (row["title"] ?? row["name"] ?? row["song"] ?? row["track"]) as? String ?? ""
      guard !title.isEmpty else { return nil }
      var artist = ""
      if let value = (row["artist"] ?? row["artists"] ?? row["singer"]) as? String {
        artist = value
      } else if let items = (row["artists"] ?? row["artist"]) as? [[String: Any]] {
        artist = items.compactMap { $0["name"] as? String }.joined(separator: ", ")
      }
      var album = (row["album"] ?? row["albumName"] ?? row["album_name"]) as? String ?? ""
      if album.isEmpty, let nested = row["album"] as? [String: Any] {
        album = nested["name"] as? String ?? ""
      }
      let seconds =
        (row["duration"] as? Double)
        ?? Double((row["duration"] as? Int) ?? 0)
      return ImportedTrack(
        title: title, artist: artist, album: album, duration: seconds,
        isrc: row["isrc"] as? String ?? "", number: (row["number"] as? Int) ?? 0)
    }
  }

  /// CUE：按 INDEX 01 mm:ss:ff（75 帧/秒）切分；END = 下一轨起点，最后一轨留空表示到文件末尾。
  static func cue(_ raw: String) throws -> CueSheetInfo {
    var sheet = CueSheetInfo()
    var file = ""
    var current: ImportedTrack?
    var pendingTitle: String?
    var pendingPerformer: String?

    func finish() {
      if var track = current {
        track.title = track.title.isEmpty ? "曲目 \(track.number)" : track.title
        sheet.tracks.append(track)
      }
      current = nil
    }

    for rawLine in raw.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("REM") else { continue }
      let parts = tokenize(line)
      guard let keyword = parts.first?.uppercased() else { continue }
      switch keyword {
      case "FILE":
        finish()
        file = parts.count > 1 ? parts[1] : ""
        sheet.fileName = file
      case "TRACK":
        finish()
        var track = ImportedTrack(title: "", number: Int(parts.count > 1 ? parts[1] : "") ?? 0)
        track.fileName = file.isEmpty ? sheet.fileName : file
        if let title = pendingTitle {
          track.title = title
          pendingTitle = nil
        }
        if let performer = pendingPerformer {
          track.artist = performer
          pendingPerformer = nil
        }
        current = track
      case "TITLE":
        if current != nil { current?.title = parts.count > 1 ? parts[1] : "" }
        else if sheet.album.isEmpty { sheet.album = parts.count > 1 ? parts[1] : "" }
        else { pendingTitle = parts.count > 1 ? parts[1] : "" }
      case "PERFORMER":
        if current != nil { current?.artist = parts.count > 1 ? parts[1] : "" }
        else if sheet.performer.isEmpty { sheet.performer = parts.count > 1 ? parts[1] : "" }
        else { pendingPerformer = parts.count > 1 ? parts[1] : "" }
      case "INDEX":
        guard parts.count > 2, parts[1] == "01", let seconds = cueTime(parts[2]) else { continue }
        current?.segmentStart = seconds
      default:
        break
      }
    }
    finish()
    guard !sheet.tracks.isEmpty else { throw AppFailure("没有在 CUE 文件里找到 TRACK 段落") }

    // 同一 FILE 内按顺序补 END。
    for i in sheet.tracks.indices {
      let name = sheet.tracks[i].fileName ?? ""
      var end: Double?
      if i + 1 < sheet.tracks.count, (sheet.tracks[i + 1].fileName ?? "") == name,
        let start = sheet.tracks[i].segmentStart, let next = sheet.tracks[i + 1].segmentStart
      {
        end = next
      } else {
        end = nil
      }
      sheet.tracks[i].segmentEnd = end
      if let start = sheet.tracks[i].segmentStart, let end {
        sheet.tracks[i].duration = max(0, end - start)
      }
      if sheet.tracks[i].artist.isEmpty { sheet.tracks[i].artist = sheet.performer }
      if sheet.tracks[i].album.isEmpty { sheet.tracks[i].album = sheet.album }
    }
    if sheet.album.isEmpty { sheet.album = sheet.tracks.first?.album ?? "" }
    return sheet
  }

  static func cueTime(_ text: String) -> Double? {
    let parts = text.split(separator: ":")
    guard parts.count == 3, let m = Int(parts[0]), let s = Int(parts[1]), let f = Int(parts[2])
    else { return nil }
    return Double(m) * 60 + Double(s) + Double(f) / 75
  }

  static func tokenize(_ line: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quoted = false
    for ch in line {
      if ch == "\"" { quoted.toggle(); continue }
      if ch == " " && !quoted {
        if !current.isEmpty { result.append(current); current = "" }
      } else {
        current.append(ch)
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }
}

enum PlaylistMatcher {
  static func match(_ tracks: [ImportedTrack], songs: [Song]) -> [PlaylistMatch] {
    var used = Set<String>()
    return tracks.map { track in
      let titleKey = normalize(track.title)
      guard !titleKey.isEmpty else {
        return PlaylistMatch(track: track, reason: "缺少曲名")
      }
      var best: (Song, Double)? = nil
      for song in songs {
        var score = similarity(titleKey, normalize(song.title)) * 0.72
        guard score > 0.35 else { continue }
        let artistScore = similarity(normalize(track.artist), normalize(song.artist))
        score += artistScore * 0.22
        if track.duration > 5, song.duration > 5, abs(track.duration - song.duration) <= 4 {
          score += 0.06
        }
        if used.contains(song.id) { score -= 0.03 }
        if best == nil || score > best!.1 { best = (song, score) }
      }
      guard let best, best.1 >= 0.62 else {
        return PlaylistMatch(track: track, reason: "本地曲库没有相近曲目")
      }
      used.insert(best.0.id)
      let note = best.1 >= 0.9 ? "高置信度匹配" : best.1 >= 0.75 ? "较可能匹配" : "低置信度，需要确认"
      return PlaylistMatch(track: track, song: best.0, score: best.1, reason: note)
    }
  }

  static func normalize(_ raw: String) -> String {
    var text = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    text = text.lowercased()
    for pattern in [
      #"\(feat\.?[^)]*\)"#, #"\[feat\.?[^]]*\]"#, #"\(ft\.?[^)]*\)"#,
      #"\(live[^)]*\)"#, #"\[live[^]]*\]"#, #"\(remaster[^)]*\)"#,
      #"\(explicit\)"#, #"\[explicit\]"#, #"-\s*live.*$"#, #"\s+"#,
    ] {
      text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
      .map(String.init).joined()
  }

  static func similarity(_ a: String, _ b: String) -> Double {
    if a.isEmpty || b.isEmpty { return 0 }
    if a == b { return 1 }
    if a.contains(b) || b.contains(a) {
      return Double(min(a.count, b.count)) / Double(max(a.count, b.count))
    }
    let left = bigrams(a), right = bigrams(b)
    let shared = left.intersection(right).count
    guard !left.isEmpty, !right.isEmpty else { return 0 }
    return 2.0 * Double(shared) / Double(left.count + right.count)
  }

  private static func bigrams(_ text: String) -> Set<String> {
    let chars = Array(text)
    guard chars.count > 1 else { return Set([text]) }
    var set = Set<String>()
    for i in 0..<(chars.count - 1) { set.insert(String(chars[i...i + 1])) }
    return set
  }
}
