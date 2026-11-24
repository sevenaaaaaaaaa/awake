import Foundation

/// 本地版内置示例曲库。
///
/// 示例音频直接打进 App 包（ios/Resources/builtin-NN.flac），首次运行时复制进
/// Documents/music 并写进曲库 —— 不依赖任何来源配置、不联网，装上就能播。
/// 只给本地测试版用，不进入线上发布。
enum BuiltinMusic {
  struct Track {
    let resource: String
    let title: String
    let artist: String
    let album: String
  }

  static let tracks: [Track] = [
    Track(resource: "builtin-01.flac", title: "低频原点", artist: "Awake 示例", album: "夜航"),
    Track(resource: "builtin-02.flac", title: "和弦共鸣", artist: "Awake 示例", album: "白噪实验室"),
    Track(resource: "builtin-03.flac", title: "全频扫掠", artist: "Awake 示例", album: "频谱边界"),
  ]

  static let flagKey = "builtinMusicSeeded.v1"
  static let origin = "builtin"

  /// 包里真实存在哪些示例文件。按前缀扫，而不是写死文件名 ——
  /// 文件名对不上时静默什么都不做，是最难查的那种「功能没生效」。
  static func available() -> [(track: Track, url: URL)] {
    guard let root = Bundle.main.resourceURL else { return [] }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    var out: [(Track, URL)] = []
    for track in tracks {
      guard let name = names.first(where: { $0.hasPrefix(track.resource.replacingOccurrences(of: ".flac", with: "")) })
      else { continue }
      out.append((track, root.appendingPathComponent(name)))
    }
    return out
  }

  static var isSeeded: Bool { UserDefaults.standard.bool(forKey: flagKey) }
}

extension MobileStore {
  var builtinSongs: [Song] { state.songs.filter { $0.origin == BuiltinMusic.origin } }

  /// 把内置示例放进本机曲库。force 为真时即使标记已写过也重新补一遍（缺哪首补哪首）。
  @discardableResult
  func installBuiltinMusic(force: Bool = false) async -> Int {
    if !force, BuiltinMusic.isSeeded { return 0 }
    if root.path.contains("Awake-UITests") { return 0 }
    var added = 0
    for item in BuiltinMusic.available() {
      let name = item.url.lastPathComponent
      let dest = music.appendingPathComponent(name)
      if !FileManager.default.fileExists(atPath: dest.path) {
        try? FileManager.default.copyItem(at: item.url, to: dest)
      }
      if state.songs.contains(where: { $0.file == name }) { continue }
      var song: Song
      if let parsed = try? await MobileStore.readSong(dest, file: name) {
        song = parsed
      } else {
        song = Song(title: item.track.title)
      }
      song.locator = LibraryImport.cacheLocator(name)
      if song.title.isEmpty { song.title = item.track.title }
      if song.artist.isEmpty || song.artist == "未知艺人" { song.artist = item.track.artist }
      if song.album.isEmpty { song.album = item.track.album }
      song.origin = BuiltinMusic.origin
      song.addedAt = Date()
      state.songs.append(song)
      added += 1
    }
    if added > 0 { save() }
    UserDefaults.standard.set(true, forKey: BuiltinMusic.flagKey)
    return added
  }

  /// 移除内置示例：删曲目、删本机文件、清标记。返回删掉的曲目数。
  @discardableResult
  func removeBuiltinMusic() -> Int {
    let doomed = state.songs.filter { $0.origin == BuiltinMusic.origin }
    for song in doomed {
      if let file = song.file {
        try? FileManager.default.removeItem(at: music.appendingPathComponent(file))
      }
    }
    state.songs.removeAll { $0.origin == BuiltinMusic.origin }
    UserDefaults.standard.removeObject(forKey: BuiltinMusic.flagKey)
    save()
    return doomed.count
  }

  /// 清空「本地添加的记录」：不属于任何远程来源的曲目（本地导入、内置示例、插件曲目）
  /// 连同本机文件一起删掉，来源配置与设置保留。返回（曲目数, 文件夹记录数）。
  @discardableResult
  func clearLocalRecords() -> (songs: Int, folders: Int) {
    let remoteIDs = Set(state.sources.map { $0.id })
    let doomed = state.songs.filter { song in
      guard let id = song.sourceID else { return true }
      return !remoteIDs.contains(id)
    }
    for song in doomed {
      if let file = song.file {
        try? FileManager.default.removeItem(at: music.appendingPathComponent(file))
      }
    }
    let doomedIDs = Set(doomed.map { $0.id })
    state.songs.removeAll { doomedIDs.contains($0.id) }
    let folders = state.importedFolderPaths?.count ?? 0
    state.importedFolderPaths = nil
    UserDefaults.standard.removeObject(forKey: BuiltinMusic.flagKey)
    save()
    return (doomed.count, folders)
  }
}
