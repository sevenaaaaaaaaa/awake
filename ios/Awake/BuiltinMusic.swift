import Foundation

/// 本地版内置示例曲库。
///
/// 三首示例音频直接打进 App 包（ios/Resources/builtin-*.flac），首次运行时复制进
/// Documents/music 并写进曲库 —— 不依赖任何来源配置、不联网，装上就能播。
/// 这一份只给本地测试版用，不进入线上发布。
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

  /// 播种标记：同一次安装只做一次；想重来就删 App。
  static let flagKey = "builtinMusicSeeded.v1"
}

extension MobileStore {
  /// 首次启动时把内置示例放进本机曲库。已有同名文件或曲目就跳过，不覆盖用户的东西。
  func seedBuiltinMusicIfNeeded() async {
    if UserDefaults.standard.bool(forKey: BuiltinMusic.flagKey) { return }
    if root.path.contains("Awake-UITests") { return }
    var added = 0
    for track in BuiltinMusic.tracks {
      guard let source = Bundle.main.url(forResource: track.resource, withExtension: nil) else {
        continue
      }
      let dest = music.appendingPathComponent(track.resource)
      if !FileManager.default.fileExists(atPath: dest.path) {
        try? FileManager.default.copyItem(at: source, to: dest)
      }
      if state.songs.contains(where: { $0.file == track.resource }) { continue }
      var song: Song
      if let parsed = try? await MobileStore.readSong(dest, file: track.resource) {
        song = parsed
      } else {
        song = Song(title: track.title)
      }
      if song.title.isEmpty { song.title = track.title }
      if song.artist.isEmpty || song.artist == "未知艺人" { song.artist = track.artist }
      if song.album.isEmpty { song.album = track.album }
      song.origin = "builtin"
      song.addedAt = Date()
      state.songs.append(song)
      added += 1
    }
    if added > 0 {
      save()
      message = "已放入内置示例曲库：\(added) 首"
    }
    UserDefaults.standard.set(true, forKey: BuiltinMusic.flagKey)
  }
}
