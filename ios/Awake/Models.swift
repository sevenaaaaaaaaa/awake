import AVFoundation
import Foundation
import Security
import SwiftUI

struct Song: Identifiable, Codable, Equatable {
  var id = UUID().uuidString
  var title: String
  var artist = "未知艺人"
  var album = ""
  /// 导入时的上级文件夹名，用于没有专辑标签的有声书归并。
  var folder: String?
  var genre = ""
  var duration: Double = 0
  var sampleRate: Double = 0
  /// 有声书章节序号；用于保持生成章节的顺序。
  var trackNumber: Int?
  var file: String?
  var sourceID: String?
  var locator = ""
  var favorite = false
  var addedAt: Date?
  var origin: String?
  var originalFilename: String?
  var artwork: String?
  var lyrics: String?
  var comment: String?
  var mediaInfo: MediaInfo?
  /// CUE 整轨分轨：同一音频文件内的起始/结束秒；为 nil 时按整个文件播放。
  var segmentStart: Double?
  var segmentEnd: Double?
}
struct PendingTrack: Identifiable, Codable, Equatable, Hashable {
  var id = UUID().uuidString
  var title: String
  var artist = ""
  var album = ""
}

enum LibraryImportIdentity {
  static func locator(for url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
  static func existingSongID(locator: String, songs: [Song]) -> String? { songs.first(where: { $0.locator == locator })?.id }
  static func removedLocators(previous: [String], current: Set<String>) -> [String] { previous.filter { !current.contains($0) } }
}

struct Playlist: Identifiable, Codable, Equatable {
  var id = UUID().uuidString
  var name: String
  var songIDs: [String] = []
  var createdAt = Date()
  var note = ""
  /// 导入时本地没有匹配到的曲目；曲库更新后可重新匹配。
  var pending: [PendingTrack]? = nil
}
struct MusicSource: Identifiable, Codable {
  var id = UUID().uuidString
  var name: String
  var kind: String
  var url: String
  var username = ""
  /// 用户明确勾选后才对该来源的主机放行自签名 HTTPS 证书。
  var trustSelfSigned = false
  /// Plex 音乐库分区 key；为空表示整个服务器的音乐分区。
  var section: String?

  init(id: String = UUID().uuidString, name: String, kind: String, url: String, username: String = "", trustSelfSigned: Bool = false, section: String? = nil) {
    self.id = id
    self.name = name
    self.kind = kind
    self.url = url
    self.username = username
    self.trustSelfSigned = trustSelfSigned
    self.section = section
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名来源"
    kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "webdav"
    url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
    trustSelfSigned = try c.decodeIfPresent(Bool.self, forKey: .trustSelfSigned) ?? false
    section = try c.decodeIfPresent(String.self, forKey: .section)
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, kind, url, username, trustSelfSigned, section
  }
}
struct Listen: Codable {
  var songID: String
  var seconds: Double
  var at = Date()
}
struct ListeningChain: Identifiable, Codable, Equatable {
  var id = UUID().uuidString
  var routeUID: String
  var name: String
  var headphone: String
  var connection: String
  var frontend = ""
  var acousticMode = "待确认"
  var fit = "待确认"
  var codecPreference = "系统协商"
  var referenceModel = ""
  var referenceEvidence = ""
  var gains = Array(repeating: Float(0), count: 31)
  var apo = ""
  var measurementSource = ""
  var eqOrigin: EQOrigin?
  var equipment: EquipmentContext?
}
struct Rating: Identifiable, Codable {
  var id = UUID().uuidString
  var date = Date()
  var songID: String
  var chainID: String?
  var headphone: String
  var connection: String
  var clarity: Double
  var bass: Double
  var comfort: Double
  var fatigue: Double
  var note: String
  var gains: [Float]
  var measurementSource: String
  var blindChoice: String?
  var chosenWasEQ: Bool?
  var listenedSeconds: Double
  var eqOrigin: EQOrigin?
  var equipment: EquipmentContext?
  var overall: Double { (clarity + bass + comfort + (6 - fatigue)) / 4 }
}
struct BenchResult: Identifiable, Codable {
  var id = UUID().uuidString
  var date = Date()
  var frames: Int
  var sampleRate: Double
  var seconds: Double
  var peak: Float
  var rms: Float
  var nonFinite: Int
  var clipped: Int
  var profile: String
  var realtimeFactor: Double { seconds > 0 ? Double(frames) / sampleRate / seconds : 0 }
}
struct Skin: Codable, Equatable {
  struct Colors: Codable, Equatable {
    var bg, surface, raised, text, muted, accent, onAccent, border: String
  }
  static let currentVersion = 2
  var version = 1
  var id: String
  var name: String
  var mode: String
  var colors: Colors
  var radius: Double = 16
  var density = "comfortable"
  var font = "system"
  var blur: Double = 0
  // 只有黑与白。三个皮肤是同一根中性阶上的三段，不是三种颜色主张：
  // 强调色本身就是黑/白，按钮是「白底黑字」或「黑底白字」——没有第二个色相。
  static let dark = Skin(
    version: 2, id: "dark", name: "黑色 · Obsidian", mode: "dark",
    colors: .init(
      bg: "#08090b", surface: "#131417", raised: "#1d1f23", text: "#f7f8fa", muted: "#9aa0a8",
      accent: "#f4f5f7", onAccent: "#0a0b0d", border: "#2b2e34"))
  static let light = Skin(
    version: 2, id: "light", name: "白色 · Paper", mode: "light",
    colors: .init(
      bg: "#f4f4f5", surface: "#ffffff", raised: "#ececee", text: "#0b0c0e", muted: "#5c6066",
      accent: "#111214", onAccent: "#ffffff", border: "#d8d9dd"))
  static let glass = Skin(
    version: 2, id: "glass", name: "玻璃 · Haze", mode: "glass",
    colors: .init(
      bg: "#0a0b0d", surface: "#1a1c20", raised: "#26282d", text: "#f7f8fa", muted: "#a9afb7",
      accent: "#ffffff", onAccent: "#0a0b0d", border: "#3a3d43"), radius: 22, blur: 24)
  /// 内置皮肤的调色板换过（0.9.9 起只有黑与白）。老档案里存的是旧色板，
  /// 直接读出来会把新配色挡在门外——用户看到的还是上一版的蓝。
  /// 换的只是调色板：用户选的仍是同一个皮肤；自定义皮肤一个字不动。
  static func migrated(_ skin: Skin) -> Skin {
    guard skin.version < 2 else { return skin }
    switch skin.id {
    case Skin.dark.id: return .dark
    case Skin.light.id: return .light
    case Skin.glass.id: return .glass
    default: return skin
    }
  }
  static func parse(_ text: String) throws -> Skin {
    guard text.utf8.count <= 65536 else { throw AppFailure("设计文件超过 64 KB") }
    var content = text
    if let r = text.range(
      of: "```(?:json|awake-skin)\\s*\\n([\\s\\S]*?)```", options: .regularExpression)
    {
      let block = String(text[r])
      content = block.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        .replacingOccurrences(of: "```", with: "")
    }
    let skin = try JSONDecoder().decode(Skin.self, from: Data(content.utf8))
    try skin.validate()
    return skin
  }
  func validate() throws {
    let values = [
      colors.bg, colors.surface, colors.raised, colors.text, colors.muted, colors.accent,
      colors.onAccent, colors.border,
    ]
    // 1 和 2 都合法：老档案里存的是 1，读出来会迁移成当前调色板再写回 2。
    // 只认 1 的话，迁移后的档案第二次启动就会被判成损坏。
    guard (1...Skin.currentVersion).contains(version), !name.isEmpty, name.count <= 60, ["dark", "light", "glass"].contains(mode),
      radius.isFinite, (0...28).contains(radius), blur.isFinite, (0...40).contains(blur),
      ["comfortable", "compact"].contains(density), ["system", "serif"].contains(font),
      values.allSatisfy({ $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil })
    else { throw AppFailure("皮肤格式或颜色无效") }
    for bg in [colors.bg, colors.surface, colors.raised] {
      guard Self.contrast(colors.text, bg) >= 4.5, Self.contrast(colors.muted, bg) >= 4.5 else {
        throw AppFailure("皮肤文字对比度不足 4.5:1")
      }
    }
    guard Self.contrast(colors.onAccent, colors.accent) >= 4.5 else {
      throw AppFailure("按钮文字对比度不足")
    }
  }
  static func contrast(_ a: String, _ b: String) -> Double {
    func light(_ h: String) -> Double {
      let n = UInt(h.dropFirst(), radix: 16) ?? 0
      let c = [Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255)].map { $0 / 255 }
        .map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
      return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
    }
    let x = light(a)
    let y = light(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
  }
}
extension Color {
  init(hex: String) {
    let n = UInt(hex.dropFirst(), radix: 16) ?? 0
    self.init(
      red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255,
      blue: Double(n & 255) / 255)
  }
}
struct CreationJob: Identifiable, Codable {
  var id = UUID().uuidString
  var prompt: String
  var model: String
  var state = "queued"
  var date = Date()
  var songID: String?
  var error: String?
}
struct LibraryState: Codable {
  var creations: [CreationJob]?
  var version = 1
  var songs: [Song] = []
  var sources: [MusicSource] = []
  var listens: [Listen] = []
  var chains: [ListeningChain] = []
  var activeChains: [String: String] = [:]
  var ratings: [Rating] = []
  var benches: [BenchResult] = []
  /// 旧档案没有这个字段，保持可选以兼容已有 library.json。
  var playlists: [Playlist]?
  var skin = Skin.dark
  var customSkins: [Skin] = []
  var curatorCredentialEndpoint = ""
  var curatorCredentialAccount = ""
  var musicCredentialEndpoint = ""
  var musicCredentialAccount = ""
  var curatorURL = "https://api.openai.com/v1"
  var curatorModel = ""
  var musicURL = "https://api.elevenlabs.io/v1/music"
  var musicModel = "music_v1"
  /// 听书进度：key 为书（专辑键或单曲 ID）。
  var bookProgress: [String: BookProgress]?
  var importedFolderPaths: [String: [String]]?
}
struct AppFailure: LocalizedError {
  var message: String
  init(_ m: String) { message = m }
  var errorDescription: String? { message }
}
enum Secrets {
  static let service = "com.seven.awake.ios"
  static func get(_ account: String) throws -> String {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &out)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess, let data = out as? Data,
      let s = String(data: data, encoding: .utf8)
    else { throw AppFailure("无法读取系统钥匙串") }
    return s
  }
  static func set(_ value: String, account: String) throws {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attrs: [String: Any] = [
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
    if status == errSecItemNotFound {
      var add = q
      for (key, value) in attrs { add[key] = value }
      guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
        throw AppFailure("无法保存到系统钥匙串")
      }
    } else if status != errSecSuccess {
      throw AppFailure("系统钥匙串保存失败")
    }
  }
  static func remove(_ account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AppFailure("系统钥匙串凭据清理失败")
    }
  }
}
@MainActor final class MobileStore: ObservableObject {
  @Published var state = LibraryState()
  @Published var message = ""
  @Published var busy = false
  @Published var generationRunning = false
  @Published var speechPlans: [SpeechPlan] = []
  @Published var newsItems: [NewsItem] = []
  /// 刚连上的来源：曲库用它把列表筛到这一个来源，连完就能看见自己刚加的东西。
  /// 读取后由曲库清空，避免每次进曲库都被上一次的连接结果锁住。
  @Published var pendingLibrarySource: String?
  /// 正在播放页的开合；MiniPlayer 与端到端自检都用它。
  @Published var playerSheetOpen = false
  /// 请求切到某个底部标签（播放页的「去设置」用）。读完即清空。
  @Published var requestedTab: Int?
  var generationTask: Task<Void, Never>?
  var jobs: [CreationJob] {
    get { state.creations ?? [] }
    set { state.creations = newValue }
  }
  let root: URL
  var music: URL { root.appendingPathComponent("Music", isDirectory: true) }
  init(root: URL? = nil) {
    self.root =
      root
      ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Awake", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
      speechPlans = SpeechPlanStore.load(self.root)
      newsItems = NewsStore.load(self.root)
      let path = self.root.appendingPathComponent("library.json")
      if FileManager.default.fileExists(atPath: path.path) {
        do {
          let decoded = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: path))
          try decoded.skin.validate()
          state = decoded
          state.skin = Skin.migrated(state.skin)
          state.creations = state.creations?.map { job in
            var restored = job
            if restored.state == "running" || restored.state == "queued" {
              restored.state = "interrupted"
              restored.error = "应用退出使接收中断，不会自动重复请求"
            }
            return restored
          }
        } catch {
          try? FileManager.default.copyItem(
            at: path,
            to: self.root.appendingPathComponent(
              "library-corrupt-\(Int(Date().timeIntervalSince1970)).json"))
          message = "档案读取失败，已保留恢复副本"
        }
      }
    } catch { message = error.localizedDescription }
  }
  func persist() throws {
    try JSONEncoder().encode(state).write(
      to: root.appendingPathComponent("library.json"), options: .atomic)
  }
  func save() { do { try persist() } catch { message = "保存失败：\(error.localizedDescription)" } }
  func commit(_ next: LibraryState) throws {
    let previous = state
    state = next
    do { try persist() } catch { state = previous; throw error }
  }
  func localURL(_ song: Song) -> URL? {
    guard let name = song.file, URL(fileURLWithPath: name).lastPathComponent == name else {
      return nil
    }
    let u = music.appendingPathComponent(name)
    return FileManager.default.fileExists(atPath: u.path) ? u : nil
  }
  func removeSource(_ sourceID: String) throws {
    guard let source = state.sources.first(where: { $0.id == sourceID }),
      ["webdav", "plex", "telegram"].contains(source.kind)
    else { throw AppFailure("找不到可移除的远程来源") }
    let removed = state.songs.filter { $0.sourceID == sourceID }
    let previous = state
    let credential = try Secrets.get("source." + sourceID)
    var next = state
    next.sources.removeAll { $0.id == sourceID }
    next.songs.removeAll { $0.sourceID == sourceID }
    let removedIDs = Set(removed.map(\.id))
    next.playlists = next.playlists?.map { playlist in
      var copy = playlist
      copy.songIDs.removeAll { removedIDs.contains($0) }
      return copy
    }
    next.listens.removeAll { removedIDs.contains($0.songID) }
    next.bookProgress = next.bookProgress?.filter { _, progress in
      guard let songID = progress.songID else { return true }
      return !removedIDs.contains(songID)
    }
    let folders = next.importedFolderPaths ?? [:]
    next.importedFolderPaths = folders.reduce(into: [:]) { result, entry in
      let kept = entry.value.filter { locator in !removed.contains(where: { $0.locator == locator }) }
      if !kept.isEmpty { result[entry.key] = kept }
    }
    let files = removed.compactMap { localURL($0) }
    let stagedRoot = root.appendingPathComponent(".source-removal-\(UUID().uuidString)", isDirectory: true)
    var staged: [(URL, URL)] = []
    do {
      try FileManager.default.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
      for (index, file) in files.enumerated() {
        let backup = stagedRoot.appendingPathComponent(String(index))
        try FileManager.default.moveItem(at: file, to: backup)
        staged.append((file, backup))
      }
      try commit(next)
      try Secrets.remove("source." + sourceID)
      for (_, backup) in staged { try? FileManager.default.removeItem(at: backup) }
      try FileManager.default.removeItem(at: stagedRoot)
    } catch {
      if credential.isEmpty == false { try? Secrets.set(credential, account: "source." + sourceID) }
      for (original, backup) in staged.reversed() { try? FileManager.default.moveItem(at: backup, to: original) }
      state = previous
      try? persist()
      try? FileManager.default.removeItem(at: stagedRoot)
      throw error
    }
  }
  func activeChain(route: String) -> ListeningChain? {
    state.chains.first { $0.id == state.activeChains[route] && $0.routeUID == route }
  }
  func saveChain(_ chain: ListeningChain) {
    do { try chain.equipment?.validate() } catch {
      message = error.localizedDescription
      return
    }
    var c = chain
    if let old = state.chains.first(where: { $0.id == c.id }),
      old.headphone != c.headphone || old.connection != c.connection || old.frontend != c.frontend
        || old.acousticMode != c.acousticMode || old.fit != c.fit
        || old.referenceModel != c.referenceModel || old.referenceEvidence != c.referenceEvidence
        || (old.equipment?.outputID ?? "") != (c.equipment?.outputID ?? "")
        || (old.equipment?.hardwareProfile ?? "") != (c.equipment?.hardwareProfile ?? "")
    {
      c.id = UUID().uuidString
      c.gains = Array(repeating: 0, count: 31)
      c.apo = ""
      c.measurementSource = ""
      c.eqOrigin = nil
    }
    state.chains.removeAll { $0.id == c.id }
    state.chains.append(c)
    state.activeChains[c.routeUID] = c.id
    save()
  }
  func recordListen(_ song: Song, seconds: Double) {
    guard seconds.isFinite, seconds > 0 else { return }
    state.listens.append(.init(songID: song.id, seconds: seconds))
    state.listens = Array(state.listens.suffix(5000))
    save()
  }
  func books() -> [Book] {
    BookShelf.shelf(state.songs, progress: state.bookProgress ?? [:])
  }
  func weeklySummary(now: Date = Date()) -> WeeklySummary {
    WeeklySummary.make(
      songs: state.songs, listens: state.listens, progress: state.bookProgress ?? [:], now: now)
  }
  /// 播放/暂停时把当前章节与位置写进听书进度。
  func updateBookProgress(song: Song, position: Double, duration: Double) {
    guard position.isFinite, position >= 0 else { return }
    let shelf = books()
    guard let book = BookShelf.book(containing: song, in: shelf) else { return }
    var progress = state.bookProgress ?? [:]
    let finished = (progress[book.id]?.finished ?? false)
      || (book.chapters.last?.id == song.id && duration > 0 && position >= duration * 0.98)
    progress[book.id] = BookProgress(
      songID: song.id, position: position, finished: finished, updatedAt: Date())
    state.bookProgress = progress
    save()
  }
  func saveSpeechPlans() { SpeechPlanStore.save(speechPlans, root: root) }
  func saveNews() { NewsStore.save(newsItems, root: root) }
  func recommendations() -> [Song] {
    let byID = Dictionary(uniqueKeysWithValues: state.songs.map { ($0.id, $0) })
    var artists: [String: Double] = [:]
    var played: [String: Int] = [:]
    var seconds: [String: Double] = [:]
    for e in state.listens where e.seconds.isFinite && e.seconds > 0 {
      seconds[e.songID, default: 0] += e.seconds
    }
    for (id, total) in seconds {
      guard let s = byID[id] else { continue }
      let threshold = min(120, max(0.1, s.duration / 2))
      guard total >= threshold else { continue }
      let times = min(10, Int(total / threshold))
      artists[s.artist, default: 0] += Double(times)
      played[s.id, default: 0] = times
    }
    for s in state.songs where s.favorite { artists[s.artist, default: 0] += 2 }
    return state.songs.sorted { a, b in
      let x =
        (a.favorite ? 4.0 : 0) + (artists[a.artist] ?? 0) * 0.5 - Double(played[a.id] ?? 0) * 0.1
      let y =
        (b.favorite ? 4.0 : 0) + (artists[b.artist] ?? 0) * 0.5 - Double(played[b.id] ?? 0) * 0.1
      return x == y ? a.title.localizedStandardCompare(b.title) == .orderedAscending : x > y
    }
  }
  /// 一次导入的结果：给调用方决定「要不要回滚」与「怎么报告」。
  struct ImportResult {
    var added = 0
    var healed = 0
    var skipped = 0
    var failed: [String] = []
    var changed: Bool { added + healed > 0 }
  }

  /// 用一次扫描结果替换某个来源的曲目：按 locator 保留收藏、本机缓存文件名、封面、
  /// 歌词、评论与人工整理过的元数据。重复连接同一来源时不会再叠加一份副本。
  func mergeScannedSongs(_ rows: [Song], previous: [Song]) -> [Song] {
    let byLocator = Dictionary(previous.map { ($0.locator, $0) }, uniquingKeysWith: { first, _ in first })
    return rows.map { row in
      guard let old = byLocator[row.locator] else { return row }
      var updated = row
      updated.id = old.id
      updated.favorite = old.favorite
      updated.file = old.file
      updated.originalFilename = old.originalFilename
      if old.artwork != nil { updated.artwork = old.artwork }
      if old.lyrics?.isEmpty == false { updated.lyrics = old.lyrics }
      if old.comment?.isEmpty == false { updated.comment = old.comment }
      if let info = old.mediaInfo {
        updated.title = old.title
        updated.artist = old.artist
        updated.album = old.album
        updated.mediaInfo = info
      }
      return updated
    }
  }
  func importAudioFolder(_ url: URL) async {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    busy = true
    defer { busy = false }
    // 枚举放到后台：大目录（上千首）在主线程序列化会把界面卡住。
    let scan = await Task.detached(priority: .userInitiated) {
      LibraryImport.audioFiles(in: url)
    }.value
    Diagnostics.log("扫描文件夹 \(url.lastPathComponent)：音频 \(scan.files.count) 个，读不了 \(scan.unreadable) 个，超限 \(scan.exceeded)")
    guard !scan.exceeded else {
      message = "导入失败：文件夹超过两万首，请选择更小的目录"
      return
    }
    guard !scan.files.isEmpty else {
      message =
        scan.unreadable > 0
        ? "导入失败：文件夹里有 \(scan.unreadable) 个条目读不了，且没有找到可导入的音频；请先在文件 App 里把文件下载到本机再试"
        : "这个文件夹里没有支持的音频文件（mp3 / m4a / flac / wav / aiff / alac / caf）"
      return
    }
    let folder = LibraryImportIdentity.locator(for: url)
    let currentLocators = Set(scan.files.map(LibraryImportIdentity.locator))
    let previousLocators = state.importedFolderPaths?[folder] ?? []
    let removed = Set(
      LibraryImportIdentity.removedLocators(previous: previousLocators, current: currentLocators))
    let oldState = state
    let oldSongs = state.songs
    state.songs.removeAll { removed.contains($0.locator) && $0.sourceID == nil }
    state.importedFolderPaths = state.importedFolderPaths ?? [:]
    state.importedFolderPaths?[folder] = scan.files.map(LibraryImportIdentity.locator)
    let result = await importFiles(scan.files, report: false, manageBusy: false)
    // 只有「一首都没进来、而且确实有文件失败」才整体回滚。
    // 个别文件读不了不再连坐：能导入的先导入，失败的名字当面说清楚。
    guard result.changed || result.failed.isEmpty else {
      state = oldState
      let sample = result.failed.prefix(3).joined(separator: "、")
      let more = result.failed.count > 3 ? " 等 \(result.failed.count) 首" : ""
      message = "导入失败：\(sample)\(more) 无法读取；已恢复原曲库"
      return
    }
    do {
      try persist()
    } catch {
      state = oldState
      message = "导入失败：无法写入曲库（\(error.localizedDescription)）"
      return
    }
    let removedIDs = Set(oldSongs.filter { removed.contains($0.locator) }.map(\.id))
    if !removedIDs.isEmpty {
      state.playlists = state.playlists?.map { playlist in
        var value = playlist
        value.songIDs.removeAll { removedIDs.contains($0) }
        return value
      }
      state.listens.removeAll { removedIDs.contains($0.songID) }
      try? persist()
      for song in oldSongs where removedIDs.contains(song.id) {
        if let cached = localURL(song) { try? FileManager.default.removeItem(at: cached) }
      }
    }
    if let verdict = LibraryImport.statusMessage(
      added: result.added, healed: result.healed, skipped: result.skipped, failed: result.failed)
    {
      message = verdict
    }
    Diagnostics.log(
      "文件夹导入结果：新增 \(result.added)，补齐 \(result.healed)，跳过 \(result.skipped)，失败 \(result.failed.prefix(5).joined(separator: "、"))")
  }
  /// 兜底导入：扫描 App 自己的 Documents/Awake（Files App 里可见），
  /// 把用户直接拷进来的音频导入曲库。选择器在个别重签环境里不可用时，这是另一条路。
  func importOwnFolder() async {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let root = docs.appendingPathComponent("Awake", isDirectory: true)
    let musicPrefix = music.path + "/"
    let scan = await Task.detached(priority: .userInitiated) {
      LibraryImport.audioFiles(in: root)
    }.value
    let candidates = scan.files.filter { !$0.path.hasPrefix(musicPrefix) }
    guard !candidates.isEmpty else {
      message =
        "「文件」App 的 Awake 文件夹里没有待导入的音频。把文件拷进「我的 iPhone → Awake」后，再点一次这个按钮。"
      Diagnostics.log("Documents 导入：没有候选文件（扫描到 \(scan.files.count) 个，读不了 \(scan.unreadable) 个）")
      return
    }
    let result = await importFiles(candidates, report: true)
    if let verdict = LibraryImport.statusMessage(
      added: result.added, healed: result.healed, skipped: result.skipped, failed: result.failed)
    {
      message = verdict
    }
  }
  nonisolated static func audioFiles(in url: URL) throws -> [URL] {

    let scan = LibraryImport.audioFiles(in: url)
    guard !scan.exceeded else { throw AppFailure("文件夹超过两万首，请选择更小的目录") }
    guard !scan.files.isEmpty else {
      throw AppFailure(
        scan.unreadable > 0
          ? "文件夹里有 \(scan.unreadable) 个条目读不了，且没有找到可导入的音频；请先在文件 App 里下载到本机"
          : "这个文件夹里没有支持的音频文件（mp3 / m4a / flac / wav / aiff / alac / caf）")
    }
    return scan.files
  }
  @discardableResult
  func importFiles(_ urls: [URL], report: Bool = false, manageBusy: Bool = true) async
    -> ImportResult
  {
    if manageBusy { busy = true }
    defer { if manageBusy { busy = false } }
    var result = ImportResult()
    for url in urls {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      do {
        let locator = LibraryImportIdentity.locator(for: url)
        let existing = state.songs.first(where: { $0.locator == locator && $0.sourceID == nil })
        // 已有曲目且本机文件还在 → 真正重复；本机文件不在（备份恢复、缓存被清、
        // 上次复制失败）→ 继续走复制，把缺失的文件补齐。
        if let existing, !LibraryImport.shouldImport(existingHasLocalFile: localURL(existing) != nil)
        {
          result.skipped += 1
          continue
        }
        let ext = url.pathExtension.lowercased()
        guard LibraryImport.audioExtensions.contains(ext) else {
          throw AppFailure("不支持的文件：\(url.lastPathComponent)")
        }
        let name = UUID().uuidString + "." + ext
        let dest = music.appendingPathComponent(name)
        do {
          try await Task.detached(priority: .userInitiated) {
            try Self.copyImported(url, to: dest)
          }.value
        } catch {
          try? FileManager.default.removeItem(at: dest)
          throw error
        }
        do {
          var song = try await Self.readSong(dest, file: name)
          song.locator = locator
          song.addedAt = Date()
          song.originalFilename = url.lastPathComponent
          let folder = url.deletingLastPathComponent().lastPathComponent
          song.folder = folder.isEmpty ? nil : folder
          Self.readSidecars(from: url, song: &song, directory: artworkDirectory)
          if song.title == dest.deletingPathExtension().lastPathComponent {
            song.title = url.deletingPathExtension().lastPathComponent
          }
          if let existing, let index = state.songs.firstIndex(where: { $0.id == existing.id }) {
            // 补齐缺失的本机文件：保留 id（歌单、听书记录都靠它），只换文件与缺失的元数据。
            var healed = existing
            healed.file = name
            if healed.duration <= 0 { healed.duration = song.duration }
            if healed.sampleRate <= 0 { healed.sampleRate = song.sampleRate }
            if healed.title.isEmpty { healed.title = song.title }
            if healed.artwork == nil { healed.artwork = song.artwork }
            if healed.lyrics == nil || healed.lyrics?.isEmpty == true { healed.lyrics = song.lyrics }
            state.songs[index] = healed
            result.healed += 1
          } else {
            state.songs.append(song)
            result.added += 1
          }
          save()
        } catch {
          try? FileManager.default.removeItem(at: dest)
          throw error
        }
      } catch {
        result.failed.append(url.lastPathComponent)
        Diagnostics.log("导入失败 \(url.lastPathComponent)：\(error.localizedDescription)")
      }
    }
    if report || result.added + result.healed > 1,
      let verdict = LibraryImport.statusMessage(
        added: result.added, healed: result.healed, skipped: result.skipped, failed: result.failed)
    {
      message = verdict
    }
    return result
  }

  /// iCloud Drive / 文件提供者返回的 URL 直接 copy 可能失败；用 NSFileCoordinator 触发下载后再复制。
  nonisolated static func copyImported(_ source: URL, to destination: URL) throws {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var copyError: Error?
    coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) {
      readURL in
      do { try FileManager.default.copyItem(at: readURL, to: destination) } catch {
        copyError = error
      }
    }
    if let copyError { throw copyError }
    if let coordinationError { throw coordinationError }
  }
  /// 音频探测：优先 AVAudioFile（能拿到采样率），失败再退回 AVAsset（只拿时长）。
  /// 导入这一关不该因为「AVFoundation 的解码器不认这个容器」就整个失败——
  /// 播放器另有 AVPlayer 回退，导入先让文件进得来、能被看见。
  nonisolated static func probeAudio(_ url: URL) async -> (duration: Double, rate: Double)? {
    if let audio = try? AVAudioFile(forReading: url), audio.length > 0 {
      let rate = audio.processingFormat.sampleRate
      if rate > 0 {
        return (Double(audio.length) / rate, rate)
      }
    }
    if let duration = try? await AVURLAsset(url: url).load(.duration) {
      let seconds = CMTimeGetSeconds(duration)
      if seconds.isFinite, seconds > 0 { return (seconds, 0) }
    }
    return nil
  }
  static func readSong(_ url: URL, file: String) async throws -> Song {
    guard let probe = await probeAudio(url) else {
      throw AppFailure("这个文件无法解码为音频：请确认格式受支持（FLAC / ALAC / MP3 / AAC / WAV / AIFF / M4A）")
    }
    var song = Song(
      title: url.deletingPathExtension().lastPathComponent,
      duration: probe.duration,
      sampleRate: probe.rate, file: file)
    let asset = AVURLAsset(url: url)
    if let metadata = try? await asset.load(.commonMetadata) {
      for item in metadata {
        guard let key = item.commonKey, let value = try? await item.load(.stringValue),
          !value.isEmpty
        else { continue }
        switch key {
        case .commonKeyTitle: song.title = value
        case .commonKeyArtist: song.artist = value
        case .commonKeyAlbumName: song.album = value
        default: break
        }
      }
    }
    if let items = try? await asset.load(.metadata) {
      for item in items {
        let identifier = (item.identifier?.rawValue ?? "").lowercased()
        if item.commonKey == .commonKeyArtwork || identifier.contains("apic") || identifier.contains("covr"),
           song.artwork == nil, let data = try? await item.load(.dataValue) {
          song.artwork = try? MediaArt.persist(data, directory: url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Artwork"))
        }
        if identifier.contains("uslt") || identifier.contains("lyrics") || identifier.contains("lyr") {
          song.lyrics = try? await item.load(.stringValue)
        }
        if identifier.contains("comment") || identifier.contains("comm") || identifier.contains("cmt") {
          song.comment = try? await item.load(.stringValue)
        }
      }
    }
    return song
  }
  nonisolated static func readSidecars(from url: URL, song: inout Song, directory: URL) {
    let manager = FileManager.default
    func bounded(_ file: URL, limit: Int) -> Data? {
      guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { return nil }
      return try? Data(contentsOf: file)
    }
    if song.artwork == nil {
      let root = url.deletingLastPathComponent()
      let names = [url.deletingPathExtension().lastPathComponent, "cover", "folder", "front", "Cover", "Folder"]
      for name in names {
        for ext in ["jpg", "jpeg", "png", "webp"] {
          let file = root.appendingPathComponent(name + "." + ext)
          if manager.fileExists(atPath: file.path), let data = bounded(file, limit: 8 * 1024 * 1024),
             let artwork = try? MediaArt.persist(data, directory: directory) { song.artwork = artwork; break }
        }
        if song.artwork != nil { break }
      }
    }
    if song.lyrics?.isEmpty ?? true {
      for ext in ["lrc", "lyrics.txt"] {
        if let data = bounded(url.deletingPathExtension().appendingPathExtension(ext), limit: 131072) { song.lyrics = String(data: data, encoding: .utf8); break }
      }
    }
  }
  func curatorSecret() throws -> String {
    guard state.curatorURL == state.curatorCredentialEndpoint,
      !state.curatorCredentialAccount.isEmpty
    else { throw AppFailure("首次配置或更换 AI 地址后，请重新保存 API 密钥") }
    return try Secrets.get(state.curatorCredentialAccount)
  }
  func musicSecret() throws -> String {
    guard state.musicURL == state.musicCredentialEndpoint, !state.musicCredentialAccount.isEmpty
    else { throw AppFailure("首次配置或更换音乐服务地址后，请重新保存 API 密钥") }
    return try Secrets.get(state.musicCredentialAccount)
  }
  func startGeneration(prompt: String, seconds: Int) throws {
    guard !generationRunning else { throw AppFailure("已有创作任务运行中") }
    let endpoint = state.musicURL
    let model = state.musicModel
    let key = try musicSecret()
    guard !prompt.isEmpty, prompt.count <= 4100 else { throw AppFailure("描述需要 1–4100 字") }
    let job = CreationJob(prompt: prompt, model: model)
    jobs = Array((jobs + [job]).suffix(100))
    try persist()
    generationRunning = true
    generationTask = Task {
      defer {
        generationRunning = false
        generationTask = nil
      }
      do {
        try updateJob(job.id) { $0.state = "running" }
        let song = try await AIService.compose(
          endpoint: endpoint, model: model, key: key, prompt: prompt, seconds: seconds,
          directory: music)
        var generated = song
        generated.addedAt = Date()
        state.songs.append(generated)
        try updateJob(job.id) {
          $0.state = "completed"
          $0.songID = generated.id
        }
        message = "原创音乐已保存到曲库"
      } catch {
        try? updateJob(job.id) {
          $0.state = Task.isCancelled ? "cancelled" : "failed"
          $0.error = error.localizedDescription
        }
        message = error.localizedDescription
      }
    }
  }
  func updateJob(_ id: String, _ change: (inout CreationJob) -> Void) throws {
    var rows = jobs
    guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
    change(&rows[i])
    jobs = rows
    try persist()
  }
  func reportURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Awake-feedback.json")
    let report = FeedbackExport(ratings: state.ratings, benches: state.benches)
    try JSONEncoder().encode(report).write(to: url, options: .atomic)
    return url
  }
  struct FeedbackExport: Codable {
    var version = 1
    var ratings: [Rating]
    var benches: [BenchResult]
  }
  func localAdvice(chainID: String?) -> [String] {
    let ratings = state.ratings.filter { $0.chainID == chainID }
    let equipmentAdvice =
      state.chains.first { $0.id == chainID }.map(EquipmentKnowledge.advice) ?? []
    guard !ratings.isEmpty else {
      return ["先用熟悉的曲目记录一次评分。建议会随着同一链路的反馈更新。"] + equipmentAdvice
    }
    let count = Double(ratings.count)
    let fatigue = ratings.map(\.fatigue).reduce(0, +) / count
    let comfort = ratings.map(\.comfort).reduce(0, +) / count
    var tips = [
      "当前链路有 \(ratings.count) 次主观反馈，平均满意度 \(String(format:"%.1f",ratings.map(\.overall).reduce(0,+)/count))/5。"
    ]
    if fatigue >= 3 { tips.append("反馈中疲劳感偏高：先降低音量、缩短连续聆听，再比较较少高频提升的曲线。") }
    if comfort < 3 { tips.append("舒适度偏低：优先核对佩戴、耳套或耳垫，再比较 EQ。") }
    if ratings.count < 5 { tips.append("样本较少，暂不自动调整 EQ。多记录几首不同风格的音乐。") }
    if (state.benches.last?.clipped ?? 0) > 0 { tips.append("软件测试出现削波：减少增益或进一步降低前级。") }
    tips.append("这些建议来自本机记录，不代表耳机实测、医学检测或全网统计。")
    return tips + equipmentAdvice
  }
}
