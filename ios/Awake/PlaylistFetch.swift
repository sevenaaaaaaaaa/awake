import Foundation

/// 平台歌单元数据抓取。只读取公开页面/公开接口，不带账号 Cookie，不下载音频。
/// 平台页面改版会让解析失效；失败时应提示用户改用“粘贴文本 / 导出文件”。
enum PlaylistFetch {
  struct Result {
    var playlist: ImportedPlaylist
    var warning = ""
  }

  private static let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 15
    c.timeoutIntervalForResource = 30
    c.httpShouldSetCookies = false
    return URLSession(configuration: c)
  }()

  private static let desktopUA =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

  static func netease(_ input: String) async throws -> ImportedPlaylist {
    let id = firstMatch(#"(?:id=|playlist/)(\d{5,})"#, input) ?? input.trimmingCharacters(
      in: .whitespaces)
    guard id.range(of: #"^\d{5,}$"#, options: .regularExpression) != nil else {
      throw AppFailure("请填写网易云歌单链接或歌单 ID")
    }
    let headers = ["Referer": "https://music.163.com/", "User-Agent": desktopUA]
    let data = try await get(
      "https://music.163.com/api/v6/playlist/detail?id=\(id)&n=1000&s=0", headers: headers)
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let playlist = root["playlist"] as? [String: Any]
    else { throw AppFailure("网易云没有返回可识别的歌单，请改用粘贴文本") }
    let name = playlist["name"] as? String ?? "网易云歌单"
    let ids = (playlist["trackIds"] as? [[String: Any]] ?? []).compactMap { row -> Int? in
      if let value = row["id"] as? Int { return value }
      if let value = row["id"] as? NSNumber { return value.intValue }
      return nil
    }
    guard !ids.isEmpty else { throw AppFailure("这个网易云歌单没有可读取的曲目") }
    let capped = Array(ids.prefix(3000))
    var tracks: [ImportedTrack] = []
    var start = 0
    while start < capped.count {
      let slice = Array(capped[start..<min(start + 200, capped.count)])
      let list = slice.map(String.init).joined(separator: ",")
      var components = URLComponents(
        string: "https://music.163.com/api/song/detail")!
      components.queryItems = [URLQueryItem(name: "ids", value: "[" + list + "]")]
      guard let url = components.url else { throw AppFailure("网易云歌曲地址无效") }
      let body = try await get(url.absoluteString, headers: headers)
      guard let page = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let songs = page["songs"] as? [[String: Any]]
      else { throw AppFailure("网易云歌曲详情返回格式异常") }
      for row in songs {
        let title = row["name"] as? String ?? ""
        guard !title.isEmpty else { continue }
        let artist = (row["artists"] as? [[String: Any]] ?? []).compactMap {
          $0["name"] as? String
        }.joined(separator: ", ")
        let album = (row["album"] as? [String: Any])?["name"] as? String ?? ""
        let ms = (row["duration"] as? Double) ?? Double((row["duration"] as? Int) ?? 0)
        tracks.append(
          ImportedTrack(
            title: title, artist: artist, album: album, duration: ms / 1000,
            number: tracks.count + 1))
      }
      start += 200
    }
    guard !tracks.isEmpty else { throw AppFailure("这个网易云歌单没有可读取的曲目") }
    let note = ids.count > capped.count ? "歌单共 \(ids.count) 首，本次导入前 \(capped.count) 首。" : ""
    return ImportedPlaylist(name: name, source: "网易云音乐", tracks: tracks, note: note)
  }

  static func qq(_ input: String) async throws -> ImportedPlaylist {
    let id = firstMatch(#"(?:disstid=|id=|playlist/)(\d{5,})"#, input) ?? input.trimmingCharacters(
      in: .whitespaces)
    guard id.range(of: #"^\d{5,}$"#, options: .regularExpression) != nil else {
      throw AppFailure("请填写 QQ 音乐歌单链接或歌单 ID")
    }
    let url =
      "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&disstid=\(id)&format=json"
    let data = try await get(
      url, headers: ["Referer": "https://y.qq.com/", "User-Agent": desktopUA])
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let cd = (root["cdlist"] as? [[String: Any]])?.first
    else { throw AppFailure("QQ 音乐没有返回可识别的歌单，请改用粘贴文本") }
    let code = (root["code"] as? NSNumber)?.intValue ?? 0
    let subcode = (root["subcode"] as? NSNumber)?.intValue ?? 0
    if code == 10 { throw AppFailure("QQ 音乐歌单不存在或已删除") }
    if subcode == 4000 {
      throw AppFailure("QQ 音乐把这个歌单标记为隐私或受限（subcode 4000）。可改用“粘贴文本”，或确认歌单是公开状态。")
    }
    let name = cd["dissname"] as? String ?? "QQ 音乐歌单"
    let rows = cd["songlist"] as? [[String: Any]] ?? []
    var tracks: [ImportedTrack] = []
    for (i, row) in rows.enumerated() {
      let title = row["name"] as? String ?? row["songname"] as? String ?? ""
      guard !title.isEmpty else { continue }
      let artist = (row["singer"] as? [[String: Any]] ?? []).compactMap {
        $0["name"] as? String
      }.joined(separator: ", ")
      let album = row["albumname"] as? String ?? ""
      let seconds = (row["interval"] as? Double) ?? Double((row["interval"] as? Int) ?? 0)
      tracks.append(
        ImportedTrack(
          title: title, artist: artist, album: album, duration: seconds, number: i + 1))
    }
    guard !tracks.isEmpty else { throw AppFailure("这个 QQ 音乐歌单没有可读取的曲目") }
    return ImportedPlaylist(name: name, source: "QQ 音乐", tracks: tracks)
  }

  static func youtube(_ input: String) async throws -> ImportedPlaylist {
    guard let list = firstMatch(#"[?&]list=([A-Za-z0-9_-]{10,})"#, input) else {
      throw AppFailure("请填写包含 list= 的 YouTube 播放列表链接")
    }
    let url = "https://www.youtube.com/playlist?list=" + list + "&hl=zh-CN"
    let data = try await get(
      url, headers: ["User-Agent": desktopUA, "Accept-Language": "zh-CN,zh;q=0.9"])
    let html = String(decoding: data, as: UTF8.self)
    guard let first = initialData(html) else {
      throw AppFailure("没有从 YouTube 页面读到播放列表数据，可改用粘贴文本")
    }
    var tracks = youtubeTracks(from: first)
    let name = youtubeTitle(first, html: html) ?? "YouTube 播放列表"
    var token = youtubeContinuation(first)
    if let key = firstMatch(#"\"INNERTUBE_API_KEY\":\"([^\"]+)\""#, html),
      let client = firstMatch(#"\"INNERTUBE_CLIENT_VERSION\":\"([^\"]+)\""#, html)
    {
      var pages = 0
      while let current = token, pages < 8 {
        pages += 1
        guard let page = await youtubeContinuationPage(token: current, key: key, client: client)
        else { break }
        let more = youtubeTracks(from: page)
        if more.isEmpty { break }
        for track in more where !tracks.contains(where: {
          $0.title == track.title && $0.artist == track.artist
        }) {
          tracks.append(track)
        }
        token = youtubeContinuation(page)
      }
    }
    guard !tracks.isEmpty else { throw AppFailure("这个 YouTube 播放列表没有可读取的曲目") }
    return ImportedPlaylist(
      name: name, source: "YouTube",
      tracks: tracks.enumerated().map { index, track in
        var item = track
        item.number = index + 1
        return item
      },
      note: "YouTube 标题是视频标题，已尽量清洗；没有专辑和 ISRC，匹配可能偏宽。")
  }

  private static func youtubeContinuationPage(
    token: String, key: String, client: String
  ) async -> [String: Any]? {
    guard
      let url = URL(
        string: "https://www.youtube.com/youtubei/v1/browse?key=" + key + "&prettyPrint=false")
    else { return nil }
    let body: [String: Any] = [
      "context": [
        "client": ["clientName": "WEB", "clientVersion": client, "hl": "zh-CN", "gl": "US"]
      ],
      "continuation": token,
    ]
    guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = payload
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
    request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, http.statusCode == 200,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json
  }

  private static func youtubeTracks(from root: [String: Any]) -> [ImportedTrack] {
    var tracks: [ImportedTrack] = []
    walk(root) { object in
      if let vm = object["lockupViewModel"] as? [String: Any],
        let track = youtubeLockup(vm), !tracks.contains(where: {
          $0.title == track.title && $0.artist == track.artist
        })
      {
        tracks.append(track)
      }
      if let vm = object["playlistVideoRenderer"] as? [String: Any],
        let track = youtubeLegacy(vm), !tracks.contains(where: {
          $0.title == track.title && $0.artist == track.artist
        })
      {
        tracks.append(track)
      }
    }
    return tracks
  }

  private static func youtubeLockup(_ vm: [String: Any]) -> ImportedTrack? {
    guard let meta = vm["metadata"] as? [String: Any],
      let lockup = meta["lockupMetadataViewModel"] as? [String: Any],
      let titleObject = lockup["title"] as? [String: Any],
      let rawTitle = titleObject["content"] as? String, !rawTitle.isEmpty
    else { return nil }
    var artist = ""
    if let metadata = lockup["metadata"] as? [String: Any],
      let content = metadata["contentMetadataViewModel"] as? [String: Any],
      let rows = content["metadataRows"] as? [[String: Any]],
      let parts = rows.first?["metadataParts"] as? [[String: Any]],
      let text = parts.first?["text"] as? [String: Any],
      let value = text["content"] as? String
    {
      artist = value
    }
    var duration: Double = 0
    if let image = vm["contentImage"] as? [String: Any],
      let thumbnail = image["thumbnailViewModel"] as? [String: Any],
      let overlays = thumbnail["overlays"] as? [[String: Any]],
      let bottom = overlays.first?["thumbnailBottomOverlayViewModel"] as? [String: Any],
      let badges = bottom["badges"] as? [[String: Any]],
      let badge = badges.first?["thumbnailBadgeViewModel"] as? [String: Any],
      let text = badge["text"] as? String
    {
      duration = clockSeconds(text)
    }
    let cleaned = cleanYoutubeTitle(rawTitle, artist: &artist)
    guard !cleaned.isEmpty else { return nil }
    return ImportedTrack(title: cleaned, artist: artist, duration: duration)
  }

  private static func youtubeLegacy(_ vm: [String: Any]) -> ImportedTrack? {
    guard let title = ((vm["title"] as? [String: Any])?["runs"] as? [[String: Any]])?
      .compactMap({ $0["text"] as? String }).joined(),
      !title.isEmpty
    else { return nil }
    let artist = ((vm["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])?
      .compactMap { $0["text"] as? String }.joined() ?? ""
    let length = (vm["lengthText"] as? [String: Any])?["simpleText"] as? String ?? ""
    var artistValue = artist
    let cleaned = cleanYoutubeTitle(title, artist: &artistValue)
    return ImportedTrack(title: cleaned, artist: artistValue, duration: clockSeconds(length))
  }

  /// YouTube 标题常是 “曲名 (Official Video) - 艺人”；去掉括号与常见后缀，并尽量拆出艺人。
  static func cleanYoutubeTitle(_ raw: String, artist: inout String) -> String {
    var title = raw
    title = title.replacingOccurrences(
      of: #"[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
    title = title.replacingOccurrences(
      of: #"(?i)\b(official|video|music|lyrics?|lyric|audio|visualizer|mv|m/v|hd|4k|8d)\b"#,
      with: "", options: .regularExpression)
    if let range = title.range(of: " - ", options: .backwards) {
      let head = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
      let tail = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
      if !head.isEmpty, !tail.isEmpty {
        title = head
        if artist.isEmpty { artist = tail }
      }
    }
    title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return title.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|"))
  }

  static func clockSeconds(_ text: String) -> Double {
    let parts = text.split(separator: ":").compactMap { Double($0) }
    guard !parts.isEmpty, parts.count <= 3 else { return 0 }
    return parts.reduce(0) { $0 * 60 + $1 }
  }

  private static func youtubeContinuation(_ root: [String: Any]) -> String? {
    var token: String?
    walk(root) { object in
      guard token == nil, let command = object["continuationCommand"] as? [String: Any],
        let value = command["token"] as? String
      else { return }
      token = value
    }
    return token
  }

  private static func youtubeTitle(_ root: [String: Any], html: String) -> String? {
    var title: String?
    walk(root) { object in
      guard title == nil else { return }
      if let header = object["pageHeaderRenderer"] as? [String: Any],
        let value = header["pageTitle"] as? String, !value.isEmpty
      {
        title = value
      }
    }
    if let title { return title }
    for pattern in [
      "<meta property=\"og:title\" content=\"([^\"]+)\"", "<title>([^<]+)</title>",
    ] {
      if let value = firstMatch(pattern, html) {
        return value.replacingOccurrences(of: " - YouTube", with: "")
      }
    }
    return nil
  }

  static func spotify(_ input: String) async throws -> ImportedPlaylist {
    guard let id = firstMatch(#"playlist/([A-Za-z0-9]{16,})"#, input)
      ?? (input.range(of: #"^[A-Za-z0-9]{16,}$"#, options: .regularExpression) != nil
        ? input.trimmingCharacters(in: .whitespaces) : nil)
    else { throw AppFailure("请填写 Spotify 歌单链接（open.spotify.com/playlist/...）") }
    let data = try await get(
      "https://open.spotify.com/embed/playlist/\(id)",
      headers: ["User-Agent": desktopUA, "Accept-Language": "zh-CN,zh;q=0.9"])
    let html = String(decoding: data, as: UTF8.self)
    guard let body = scriptJSON(html, id: "__NEXT_DATA__"),
      let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
      throw AppFailure("Spotify 页面没有返回可解析的曲目。可改用“粘贴文本”或导出 CSV。")
    }
    var tracks: [ImportedTrack] = []
    var name = "Spotify 歌单"
    walk(root) { object in
      if let entity = object["entity"] as? [String: Any],
        let title = entity["name"] as? String, !title.isEmpty, object["trackList"] != nil
      {
        name = title
      }
      if let list = object["trackList"] as? [[String: Any]] {
        for row in list {
          let title = row["title"] as? String ?? ""
          guard !title.isEmpty else { continue }
          let artist = row["subtitle"] as? String ?? row["artistName"] as? String ?? ""
          let ms = (row["duration"] as? Double) ?? Double((row["duration"] as? Int) ?? 0)
          if !tracks.contains(where: { $0.title == title && $0.artist == artist }) {
            tracks.append(
              ImportedTrack(
                title: title, artist: artist, duration: ms / 1000, number: tracks.count + 1))
          }
        }
      }
    }
    guard !tracks.isEmpty else {
      throw AppFailure("Spotify 嵌入页里没有读到曲目。可改用“粘贴文本”或第三方导出的 CSV。")
    }
    return ImportedPlaylist(
      name: name, source: "Spotify", tracks: tracks,
      note: "Spotify 不提供免授权的完整歌单 API，这里读取公开嵌入页，可能只含前 100 首。")
  }

  static func apple(_ input: String) async throws -> ImportedPlaylist {
    guard let pageURL = URL(string: input.trimmingCharacters(in: .whitespaces)),
      let host = pageURL.host, host.contains("music.apple.com")
    else { throw AppFailure("请填写 music.apple.com 的歌单链接") }
    if pageURL.path.contains("/new") {
      throw AppFailure("Apple Music 把链接重定向到了地区首页。请使用歌单完整链接（包含 /playlist/…），或改用粘贴文本。")
    }
    let data = try await get(
      pageURL.absoluteString,
      headers: ["User-Agent": desktopUA, "Accept-Language": "zh-CN,zh;q=0.9"])
    let html = String(decoding: data, as: UTF8.self)
    guard let body = scriptJSON(html, id: "serialized-server-data"),
      let root = try? JSONSerialization.jsonObject(with: body)
    else {
      throw AppFailure("Apple Music 页面没有返回可解析的曲目。Apple Music 没有免授权的歌单 API，可改用导出文本。")
    }
    var tracks: [ImportedTrack] = []
    var name = "Apple Music 歌单"
    walk(root) { object in
      if object["itemKind"] as? String == "containerDetailHeaderLockup",
        let items = object["items"] as? [[String: Any]],
        let head = items.first, let title = head["title"] as? String, !title.isEmpty
      {
        name = title
      }
      guard object["itemKind"] as? String == "trackLockup",
        let items = object["items"] as? [[String: Any]]
      else { return }
      for item in items {
        guard let title = item["title"] as? String, !title.isEmpty else { continue }
        let artist = item["artistName"] as? String ?? ""
        let ms = (item["duration"] as? Double) ?? Double((item["duration"] as? Int) ?? 0)
        var album = ""
        if let links = item["tertiaryLinks"] as? [[String: Any]],
          let first = links.first, let value = first["title"] as? String
        {
          album = value
        }
        album = album.replacingOccurrences(
          of: #"\s*-\s*(Single|EP|Album|Single & EP)$"#, with: "", options: .regularExpression)
        if !tracks.contains(where: { $0.title == title && $0.artist == artist }) {
          tracks.append(
            ImportedTrack(
              title: title, artist: artist, album: album, duration: ms / 1000,
              number: tracks.count + 1))
        }
      }
    }
    guard !tracks.isEmpty else {
      throw AppFailure("这个 Apple Music 页面里没有读取到曲目（可能被地区限制或已下架）。请确认链接以 /playlist/ 开头，或改用粘贴文本。")
    }
    return ImportedPlaylist(
      name: name, source: "Apple Music", tracks: tracks,
      note: "Apple Music 没有免授权的歌单 API；这里读取公开网页，曲目数可能不完整。")
  }

  // MARK: - 网络与解析辅助

  private static func get(_ text: String, headers: [String: String]) async throws -> Data {
    guard let url = URL(string: text) else { throw AppFailure("链接格式无效") }
    var request = URLRequest(url: url)
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw AppFailure("平台没有返回 HTTP 响应")
      }
      guard (200..<300).contains(http.statusCode) else {
        throw AppFailure("平台返回 HTTP \(http.statusCode)。请稍后重试，或改用粘贴文本。")
      }
      guard data.count < 12 * 1024 * 1024 else { throw AppFailure("平台页面过大") }
      return data
    } catch let error as AppFailure {
      throw error
    } catch {
      throw AppFailure("连接平台失败：\(error.localizedDescription)。可改用粘贴文本或导出文件。")
    }
  }

  private static func firstMatch(_ pattern: String, _ text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }

  private static func scriptJSON(_ html: String, id: String) -> Data? {
    guard let start = html.range(of: "id=\"\(id)\""),
      let open = html.range(of: ">", range: start.upperBound..<html.endIndex),
      let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex)
    else { return nil }
    return String(html[open.upperBound..<close.lowerBound]).data(using: .utf8)
  }

  private static func initialData(_ html: String) -> [String: Any]? {
    guard let marker = html.range(of: "ytInitialData") else { return nil }
    guard let open = html.range(of: "{", range: marker.upperBound..<html.endIndex) else {
      return nil
    }
    var depth = 0
    var inString = false
    var escaped = false
    var index = open.lowerBound
    while index < html.endIndex {
      let ch = html[index]
      if inString {
        if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" {
          inString = false
        }
      } else if ch == "\"" {
        inString = true
      } else if ch == "{" {
        depth += 1
      } else if ch == "}" {
        depth -= 1
        if depth == 0 {
          let end = html.index(after: index)
          let slice = String(html[open.lowerBound..<end])
          return try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any]
        }
      }
      index = html.index(after: index)
    }
    return nil
  }

  private static func playlistTitle(_ html: String) -> String? {
    for pattern in ["<meta property=\"og:title\" content=\"([^\"]+)\"", "<title>([^<]+)</title>"] {
      if let value = firstMatch(pattern, html) {
        return value.replacingOccurrences(of: " - YouTube Music", with: "")
          .replacingOccurrences(of: " - YouTube", with: "")
      }
    }
    return nil
  }

  private static func collectTexts(_ value: Any) -> [String] {
    var texts: [String] = []
    func visit(_ node: Any) {
      if let dict = node as? [String: Any] {
        if let runs = dict["runs"] as? [[String: Any]] {
          for run in runs {
            if let text = run["text"] as? String, !text.isEmpty,
              text != " • " && text != "•" && text != " · "
            {
              texts.append(text)
            }
          }
        }
        if let text = dict["simpleText"] as? String, !text.isEmpty, text != " • ",
          text != "•"
        {
          texts.append(text)
        }
        for (key, child) in dict where key != "runs" && key != "simpleText" {
          visit(child)
        }
      } else if let array = node as? [Any] {
        for child in array { visit(child) }
      }
    }
    visit(value)
    return texts
  }

  private static func walk(_ node: Any, visit: ([String: Any]) -> Void) {
    if let dict = node as? [String: Any] {
      visit(dict)
      for child in dict.values { walk(child, visit: visit) }
    } else if let array = node as? [Any] {
      for child in array { walk(child, visit: visit) }
    }
  }

  private static func firstMatchInJSON(_ node: Any, keys: [String]) -> String? {
    var found: String?
    walk(node) { object in
      guard found == nil else { return }
      for key in keys {
        if let value = object[key] as? String, !value.isEmpty { found = value; return }
      }
    }
    return found
  }
}
