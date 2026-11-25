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
  /// 稳定身份：App 容器内的文件记成 `own:Awake/...`，容器外还是绝对路径。
  /// 容器 UUID 会在重装 / 恢复备份后变，绝对路径不能当身份用。
  static func locator(for url: URL) -> String { LibraryImport.locator(for: url) }
  static func locator(for url: URL, documents: URL) -> String {
    LibraryImport.locator(for: url, documents: documents)
  }
  /// 旧档案里的绝对路径与新 locator 折成同一个可比较的键。
  static func identityKey(_ locator: String, documents: URL?) -> String {
    LibraryImport.identityKey(locator, documents: documents)
  }
  static func existingSongID(locator: String, songs: [Song]) -> String? {
    songs.first(where: { $0.locator == locator })?.id
  }
  static func removedLocators(previous: [String], current: Set<String>) -> [String] {
    previous.filter { !current.contains($0) }
  }
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
  /// V4：每首歌自己的曲线（key = song.id）。旧档案没有这个字段，保持可选。
  var songCurves: [String: SongCurve]?
  /// 切歌时是否自动套用这首歌的曲线；nil 视为开。
  var autoSongCurve: Bool?
  /// R2：耳朵校准得到的个人听感先验；nil 表示没校准过。
  var earPrior: EarPrior?
  /// 是否把先验叠加到播放曲线上；nil 视为开。
  var applyEarPrior: Bool?
  /// R3：agent 调音审计记录（谁提的、改了什么、从哪到哪）。
  var tuningLog: [TuningRecord]?
}

/// 一次调音的完整记录：够回滚，也够解释。
struct TuningRecord: Codable, Identifiable, Equatable {
  var id: String = UUID().uuidString
  var songID: String
  var songTitle: String
  var request: String
  var source: String
  var lines: [String]
  var before: [Float]
  var after: [Float]
  var createdAt: Date = Date()
  /// 已经被撤销或回滚过的记录，列表里仍然保留，但标灰。
  var reverted: Bool = false
}

/// 一轮 A/B 校准的产物：31 段先验 + 版本号 + 每个问题的选择，可审计。
struct EarPrior: Codable, Equatable {
  var version: Int = 1
  var gains: [Float] = Array(repeating: 0, count: 31)
  var updatedAt: Date = .distantPast
  /// 问题 id → 选择（"a" / "b" / "skip"）。用来解释这条先验怎么来的。
  var choices: [String: String] = [:]
  var summary: String {
    let answered = choices.values.filter { $0 != "skip" }.count
    return "校准 v\(version) · 回答 \(answered)/\(choices.count) 题"
  }
}

/// 一首歌对应的曲线。存的是完整快照而不是差分：差分一旦基线变了就会算错。
struct SongCurve: Codable, Equatable {
  var gains: [Float]
  var apo: String = ""
  var origin: EQOrigin = .manual
  var source: String = ""
  var updatedAt: Date = .distantPast
  /// 依据记录：这条曲线在什么前提下成立（耳机 / 链路 / 用什么方法调的）。
  /// 可选，0.9.27–0.9.30 写下的记录没有这个字段也能读。
  var basis: String?
  /// R1：结构化的三段依据（耳机 / 曲目 / 先验）。旧记录没有它，用 basis 兜底。
  var basisDetail: CurveBasis?
}

/// 一条曲线凭什么成立——三段，缺一段就说缺。
struct CurveBasis: Codable, Equatable {
  /// 耳机或输出设备：AVAudioSession 报的路由名，或链路上填的耳机型号。
  var headphone: String
  /// 曲目侧的触发：时长/采样率等可核对的指纹，加上这次调音的由头（用户原话或方法）。
  var track: String
  /// 个人先验：目前还没有校准，写「暂无校准」；R2 之后这里是校准版本。
  var prior: String

  /// 组装三段依据：耳机取当前路由名，曲目取可核对的指纹 + 这次调音的由头。
  static func make(
    headphone: String, song: Song, trigger: String, prior: String = "暂无校准"
  ) -> CurveBasis {
    CurveBasis(
      headphone: headphone,
      track: fingerprint(
        duration: song.duration, sampleRate: song.sampleRate, album: song.album, trigger: trigger),
      prior: prior)
  }

  /// 曲目依据的写法。与桌面 `listening::track_fingerprint` 逐字一致：
  /// 空的一段直接不写，而不是留下一个悬空的「 · 」。
  static func fingerprint(
    duration: Double, sampleRate: Double, album: String, trigger: String
  ) -> String {
    var parts: [String] = []
    if duration > 0 {
      let total = Int(duration)
      parts.append(String(format: "%d:%02d", total / 60, total % 60))
    }
    if sampleRate > 0 { parts.append("\(Int(sampleRate / 1000)) kHz") }
    let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
    if !album.isEmpty { parts.append(album) }
    let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trigger.isEmpty { parts.append(trigger) }
    return parts.joined(separator: " · ")
  }
}

/// 两端共用的听感规则。与 Rust 侧 `awake-core::listening` 逐条对应：
/// 数值与判定必须一致，否则同一副耳机在两端会得到不同结论。
enum EarRules {
  /// 增益限幅，与桌面 `MAX_GAIN_DB` 同一个数。
  static let maxGaindB: Float = 12

  static func applyingPrior(_ gains: [Float], prior: EarPrior?, enabled: Bool) -> [Float] {
    guard enabled, let prior, prior.gains.count == 31, gains.count == 31 else { return gains }
    return zip(gains, prior.gains).map { max(-maxGaindB, min(maxGaindB, $0 + $1)) }
  }

  static func basisMismatch(saved: String, now: String) -> Bool {
    let saved = saved.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let now = now.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !saved.isEmpty, !now.isEmpty else { return false }
    if saved == now { return false }
    return !(saved.contains(now) || now.contains(saved))
  }

  /// 依据失效时给人看的一句话；成立时为空串。与桌面 `stale_hint` 同一写法。
  static func basisHint(saved: String, now: String) -> String {
    guard basisMismatch(saved: saved, now: now) else { return "" }
    return "依据里记的是「\(saved.trimmingCharacters(in: .whitespacesAndNewlines))」，"
      + "现在用的是「\(now.trimmingCharacters(in: .whitespacesAndNewlines))」"
  }
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
  /// 呈现页正在自己说明结果（例如「添加音乐」刚失败）时，全局提示先让位。
  /// 否则 iOS 会先撤掉整张 sheet 再弹 alert：用户既看不到添加页，也看不清原因。
  @Published var suppressGlobalAlert = false
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
  // MARK: - V4 每首歌的曲线

  /// 会话内锁定：用户手动调过之后，不希望切歌被自动覆盖。
  @Published var curveLocked = false

  func songCurve(_ songID: String) -> SongCurve? {
    guard let curve = state.songCurves?[songID], curve.gains.count == 31 else { return nil }
    return curve
  }

  /// 把当前快照记到一首歌上（调音或手动保存时调用）。basis 记录这次适配的前提。
  func rememberCurve(
    _ snapshot: EQSnapshot, for songID: String, label: String, basis: String = "",
    detail: CurveBasis? = nil
  ) {
    var map = state.songCurves ?? [:]
    let previous = map[songID]
    map[songID] = SongCurve(
      gains: snapshot.gains, apo: snapshot.apo, origin: snapshot.origin,
      source: snapshot.source.isEmpty ? label : snapshot.source, updatedAt: Date(),
      basis: basis.isEmpty ? previous?.basis : basis,
      basisDetail: detail ?? previous?.basisDetail)
    state.songCurves = map
    save()
  }

  /// 这条曲线的依据还成立吗：耳机名对不上就算失效（大小写、空白、型号包含关系都容忍）。
  func basisMismatch(_ curve: SongCurve, currentHeadphone: String) -> Bool {
    guard let detail = curve.basisDetail else { return false }
    return EarRules.basisMismatch(saved: detail.headphone, now: currentHeadphone)
  }

  func forgetCurve(_ songID: String) {
    state.songCurves?[songID] = nil
    save()
  }

  /// 把个人先验叠加到一条曲线上（逐段相加，限幅 ±12）；没校准或关闭叠加时原样返回。
  func applyingPrior(_ gains: [Float]) -> [Float] {
    EarRules.applyingPrior(gains, prior: state.earPrior, enabled: state.applyEarPrior ?? true)
  }

  /// 依据里「先验」那一段的写法。
  var priorDescription: String {
    guard let prior = state.earPrior else { return "暂无校准" }
    return "校准 v\(prior.version)"
  }

  // MARK: - R3 调音审计

  /// 记一次调音；上限 200 条，超出丢最旧的。
  @discardableResult
  func logTuning(
    song: Song, request: String, source: String, lines: [String],
    before: [Float], after: [Float]
  ) -> String {
    var log = state.tuningLog ?? []
    let record = TuningRecord(
      songID: song.id, songTitle: song.title, request: request, source: source,
      lines: lines, before: before, after: after)
    log.insert(record, at: 0)
    if log.count > 200 { log.removeLast(log.count - 200) }
    state.tuningLog = log
    save()
    return record.id
  }

  func tuningHistory(for songID: String? = nil) -> [TuningRecord] {
    let log = state.tuningLog ?? []
    guard let songID else { return log }
    return log.filter { $0.songID == songID }
  }

  /// 回滚到某条记录之前或之后，并把这条标成已回滚。
  func revertTuning(_ record: TuningRecord, toBefore: Bool, player: MobilePlayer) {
    let gains = toBefore ? record.before : record.after
    guard gains.count == 31 else { return }
    _ = player.setEQ(
      gains, apo: "", origin: .manual, profile: player.currentSnapshot.profile,
      source: "回滚：\(record.source)", announce: false)
    if let index = state.tuningLog?.firstIndex(where: { $0.id == record.id }) {
      state.tuningLog?[index].reverted = true
      save()
    }
  }

  /// 保存一轮校准结果：版本号递增，旧的曲线依据因此会显示「先验已更新」。
  func saveEarPrior(gains: [Float], choices: [String: String]) {
    let next = (state.earPrior?.version ?? 0) + 1
    state.earPrior = EarPrior(
      version: next,
      gains: gains.map { max(-6, min(6, $0)) },
      updatedAt: Date(),
      choices: choices)
    save()
  }

  /// 切歌时的曲线策略。
  ///
  /// - 锁定：什么都不动（用户正在手调）。
  /// - 自动开且有这首歌的记忆：套用记忆（叠加先验）。
  /// - 其余情况（关闭自动 / 这首歌没有记忆）：**回落到当前链路的曲线**（同样叠加先验），
  ///   而不是把上一首的曲线留在那儿 —— 那会让用户以为这首歌也被调过。
  func applySongCurve(_ songID: String?, player: MobilePlayer) {
    guard let songID else { return }
    if curveLocked { return }
    if state.autoSongCurve ?? true, let curve = songCurve(songID) {
      _ = player.setEQ(
        applyingPrior(curve.gains), apo: curve.apo, origin: curve.origin, profile: nil,
        source: curve.source, announce: false)
      return
    }
    if let chain = activeChain(route: player.route.uid) {
      _ = player.setEQ(
        applyingPrior(chain.gains), apo: chain.apo, origin: chain.eqOrigin ?? .manual,
        profile: chain.headphone, source: chain.measurementSource, announce: false)
    }
  }

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
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let managedRoot = root
    // 枚举放到后台：大目录（上千首）在主线程序列化会把界面卡住。
    // 同时排除 App 自己的缓存目录：否则「选整个 Awake 文件夹」会把上次导入写出的
    // Music/<UUID>.m4a 再当成用户文件吃一遍，每扫一次多一代副本。
    let scan = await Task.detached(priority: .userInitiated) {
      LibraryImport.audioFiles(in: url, excludingManagedFrom: managedRoot)
    }.value
    Diagnostics.log(
      "扫描文件夹 \(url.lastPathComponent)：音频 \(scan.files.count) 个，读不了 \(scan.unreadable) 个，超限 \(scan.exceeded)"
    )
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
    let folderKey = LibraryImport.identityKey(
      LibraryImport.locator(for: url, documents: documents), documents: documents)
    let currentLocators = Set(
      scan.files.map {
        LibraryImport.identityKey(
          LibraryImport.locator(for: $0, documents: documents), documents: documents)
      })
    let records = state.importedFolderPaths ?? [:]
    // 旧档案里的文件夹键是绝对路径（还带着旧的容器 UUID）：按身份找回来，
    // 否则「这次扫描」与「上次记录」永远对不上，消失的成员也就永远不会被清掉。
    let previousKey = records.keys.first {
      LibraryImport.identityKey($0, documents: documents) == folderKey
    }
    let previousLocators = (previousKey.flatMap { records[$0] } ?? []).map {
      LibraryImport.identityKey($0, documents: documents)
    }
    let removed = Set(
      LibraryImportIdentity.removedLocators(previous: previousLocators, current: currentLocators))
    let oldState = state
    let oldSongs = state.songs
    state.songs.removeAll {
      $0.sourceID == nil
        && removed.contains(LibraryImport.identityKey($0.locator, documents: documents))
    }
    var nextRecords = records.filter { $0.key != previousKey }
    nextRecords[folderKey] = Array(currentLocators)
    state.importedFolderPaths = nextRecords
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
    let removedIDs = Set(
      oldSongs.filter {
        removed.contains(LibraryImport.identityKey($0.locator, documents: documents))
      }.map(\.id))
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
      "文件夹导入结果：新增 \(result.added)，补齐 \(result.healed)，跳过 \(result.skipped)，失败 \(result.failed.prefix(5).joined(separator: "、"))"
    )
  }
  /// 兜底导入：扫描 App 自己的 Documents/Awake（Files App 里可见），
  /// 把用户直接拷进来的音频导入曲库。选择器在个别重签环境里不可用时，这是另一条路。
  ///
  /// 只收「用户放进来的文件」：`Music/`、`Artwork/`、`Speech/`、`News/` 是 App 自己写的，
  /// 一律不进候选；这条规则在扫描器里统一执行，两条导入路径共用。
  func importOwnFolder() async {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let ownRoot = docs.appendingPathComponent("Awake", isDirectory: true)
    let managedRoot = root
    let scan = await Task.detached(priority: .userInitiated) {
      LibraryImport.audioFiles(in: ownRoot, excludingManagedFrom: managedRoot)
    }.value
    guard !scan.files.isEmpty else {
      message =
        "「文件」App 的 Awake 文件夹里没有待导入的音频。把文件拷进「我的 iPhone → Awake」后，再点一次这个按钮。"
      Diagnostics.log(
        "Documents 导入：没有候选文件（扫描到 \(scan.files.count) 个，读不了 \(scan.unreadable) 个）")
      return
    }
    let result = await importFiles(scan.files, report: true)
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
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var songs = state.songs
    // 身份索引：O(1) 判重；旧档案里的绝对容器路径经 identityKey 折成同一身份。
    var byIdentity: [String: Int] = [:]
    for (index, song) in songs.enumerated() where song.sourceID == nil && !song.locator.isEmpty {
      let key = LibraryImport.identityKey(song.locator, documents: documents)
      if byIdentity[key] == nil { byIdentity[key] = index }
    }
    // 尺寸索引：只有身份没命中时才用，避免每次导入都给几千个缓存文件算哈希。
    var bySize: [String: [Int]] = [:]
    for (index, song) in songs.enumerated() where song.sourceID == nil && song.segmentStart == nil {
      guard let file = song.file, let size = Self.fileSize(music.appendingPathComponent(file))
      else { continue }
      bySize[LibraryImport.sizeKey(size: size, duration: song.duration), default: []].append(index)
    }
    var changed = false
    for url in urls {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      do {
        // App 自己的缓存目录（Music / Artwork / Speech / News）永远不是用户来源：
        // 导进来的副本就写在 Music/，把它当来源会让每扫一次多一代拷贝。
        if LibraryImport.isManagedFile(url, root: root) {
          result.skipped += 1
          continue
        }
        let locator = LibraryImport.locator(for: url, documents: documents)
        let identity = LibraryImport.identityKey(locator, documents: documents)
        let existingIndex = byIdentity[identity]
        if let existingIndex, localURL(songs[existingIndex]) != nil {
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
          // 身份没命中时再按内容判一次：同一段音频换了名字 / 换了容器路径，
          // 不该再进第二遍 —— 这是「每扫一次多一份」的另一半原因。
          if existingIndex == nil,
            let twin = Self.fingerprintTwin(
              of: dest, duration: song.duration, candidates: bySize, songs: songs, music: music)
          {
            try? FileManager.default.removeItem(at: dest)
            if songs[twin].locator != locator {
              songs[twin].locator = locator
              changed = true
            }
            byIdentity[identity] = twin
            result.skipped += 1
            continue
          }
          song.locator = locator
          song.addedAt = Date()
          song.originalFilename = url.lastPathComponent
          let folder = url.deletingLastPathComponent().lastPathComponent
          song.folder = folder.isEmpty ? nil : folder
          Self.readSidecars(from: url, song: &song, directory: artworkDirectory)
          if song.title == dest.deletingPathExtension().lastPathComponent {
            song.title = url.deletingPathExtension().lastPathComponent
          }
          if let existingIndex, songs.indices.contains(existingIndex) {
            // 补齐缺失的本机文件：保留 id（歌单、听书记录都靠它），只换文件与缺失的元数据。
            var healed = songs[existingIndex]
            healed.file = name
            healed.locator = locator
            if healed.duration <= 0 { healed.duration = song.duration }
            if healed.sampleRate <= 0 { healed.sampleRate = song.sampleRate }
            if healed.title.isEmpty { healed.title = song.title }
            if healed.artwork == nil { healed.artwork = song.artwork }
            if healed.lyrics == nil || healed.lyrics?.isEmpty == true { healed.lyrics = song.lyrics }
            songs[existingIndex] = healed
            result.healed += 1
          } else {
            songs.append(song)
            byIdentity[identity] = songs.count - 1
            if let size = Self.fileSize(dest) {
              bySize[LibraryImport.sizeKey(size: size, duration: song.duration), default: []]
                .append(songs.count - 1)
            }
            result.added += 1
          }
          changed = true
        } catch {
          try? FileManager.default.removeItem(at: dest)
          throw error
        }
      } catch {
        result.failed.append(url.lastPathComponent)
        Diagnostics.log("导入失败 \(url.lastPathComponent)：\(error.localizedDescription)")
      }
    }
    // 一次导入只写一次盘、只推一次界面：逐首 save() 在上千首时会把界面卡成幻灯片。
    if changed {
      state.songs = songs
      save()
    }
    if report || result.added + result.healed > 1,
      let verdict = LibraryImport.statusMessage(
        added: result.added, healed: result.healed, skipped: result.skipped, failed: result.failed)
    {
      message = verdict
    }
    return result
  }

  /// 缓存里有没有「同一段音频」：字节数与时长相同，再比文件头哈希。
  nonisolated static func fingerprintTwin(
    of url: URL, duration: Double, candidates: [String: [Int]], songs: [Song], music: URL
  ) -> Int? {
    guard let size = fileSize(url) else { return nil }
    let key = LibraryImport.sizeKey(size: size, duration: duration)
    guard let indexes = candidates[key], !indexes.isEmpty else { return nil }
    guard let head = LibraryImport.headBytes(of: url) else { return nil }
    let hash = LibraryImport.headHash(head)
    for index in indexes where songs.indices.contains(index) {
      guard let file = songs[index].file else { continue }
      let cached = music.appendingPathComponent(file)
      guard let cachedHead = LibraryImport.headBytes(of: cached),
        LibraryImport.headHash(cachedHead) == hash
      else { continue }
      return index
    }
    return nil
  }

  nonisolated static func fileSize(_ url: URL) -> Int64? {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
      let size = values.fileSize
    else { return nil }
    return Int64(size)
  }

  // MARK: - 曲库整理（合并历史重复 / 清理缓存）

  struct LibraryRepairReport {
    var ran = false
    var scanned = 0
    var merged = 0
    var removedFiles = 0
    var freedBytes: Int64 = 0
    var rewrittenLocators = 0
    var backupName: String?
    var summary: String {
      guard ran else { return "" }
      var parts: [String] = []
      if merged > 0 { parts.append("合并重复 \(merged) 首") }
      if removedFiles > 0 {
        parts.append(
          "清理缓存 \(removedFiles) 个（\(ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file))）"
        )
      }
      if rewrittenLocators > 0 { parts.append("修正地址 \(rewrittenLocators) 条") }
      return parts.isEmpty ? "曲库已检查：没有发现重复项" : "整理完成：" + parts.joined(separator: "，")
    }
  }

  /// 把历史上重复导入的曲目按「内容」合并回一条，并清理没人引用的缓存文件。
  ///
  /// 只动本地曲目（`sourceID == nil`）：远程来源重复的成员由来源扫描自己合并。
  /// 合并前先备份 `library.json`；任何持久化失败都整批回滚。
  @discardableResult
  func repairLocalLibrary() async -> LibraryRepairReport {
    var report = LibraryRepairReport()
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var songs = state.songs

    // 1. 身份归一：容器绝对路径 → own:（重装 / 恢复后绝对路径全变，旧记录就永远命中不了）
    for index in songs.indices where songs[index].sourceID == nil {
      let next = LibraryImport.migratedLocator(songs[index].locator, documents: documents)
      if next != songs[index].locator {
        songs[index].locator = next
        report.rewrittenLocators += 1
      }
      // 缓存文件名漏进标题的（UUID），用导入时记下的原始文件名还原成人能读的标题。
      if LibraryImport.isUUIDLike(songs[index].title),
        let original = songs[index].originalFilename, !original.isEmpty
      {
        let stem = (original as NSString).deletingPathExtension
        if !stem.isEmpty, !LibraryImport.isUUIDLike(stem) { songs[index].title = stem }
      }
    }

    // 2. 收集可判重的本地曲目：CUE 虚拟分轨共用同一个文件，不能按内容合并。
    let referenced = referencedSongIDs()
    var entries: [LibraryImport.Entry] = []
    for song in songs where song.sourceID == nil && song.segmentStart == nil {
      var fingerprint: String?
      if let file = song.file, file == URL(fileURLWithPath: file).lastPathComponent,
        let size = Self.fileSize(music.appendingPathComponent(file)), song.duration > 0
      {
        fingerprint = LibraryImport.fingerprint(size: size, duration: song.duration)
      }
      entries.append(
        LibraryImport.Entry(
          id: song.id,
          identity: LibraryImport.identityKey(song.locator, documents: documents),
          fingerprint: fingerprint,
          file: song.file,
          title: song.title,
          artist: song.artist,
          hasArtwork: song.artwork != nil,
          hasLyrics: song.lyrics?.isEmpty == false,
          referenced: referenced.contains(song.id),
          addedAt: song.addedAt))
    }
    report.scanned = entries.count
    let musicPath = music.path
    let groups = await Task.detached(priority: .utility) { () -> [LibraryImport.DuplicateGroup] in
      var refined: [LibraryImport.DuplicateGroup] = []
      for (key, rows) in LibraryImport.buckets(entries) where rows.count > 1 {
        guard key.hasPrefix("fp:") else {
          if let group = LibraryImport.group(rows) { refined.append(group) }
          continue
        }
        // 只按「字节数 + 时长」分组还不够：不同歌可能刚好撞上，再用文件头哈希细分。
        var byHash: [String: [LibraryImport.Entry]] = [:]
        for row in rows {
          let hash: String
          if let file = row.file,
            let data = LibraryImport.headBytes(
              of: URL(fileURLWithPath: musicPath).appendingPathComponent(file))
          {
            hash = LibraryImport.headHash(data)
          } else {
            hash = "no-cache-file:" + row.id
          }
          byHash[hash, default: []].append(row)
        }
        for (_, same) in byHash {
          if let group = LibraryImport.group(same) { refined.append(group) }
        }
      }
      return refined.sorted { $0.keep < $1.keep }
    }.value

    var keepUpdates: [String: Song] = [:]
    var dropToKeep: [String: String] = [:]
    for group in groups {
      guard let keepIndex = songs.firstIndex(where: { $0.id == group.keep }) else { continue }
      var keep = songs[keepIndex]
      for dropID in group.drop {
        guard let dropIndex = songs.firstIndex(where: { $0.id == dropID }) else { continue }
        let dropped = songs[dropIndex]
        // 用户动过的痕迹并到保留项上，只补空缺，不覆盖已有。
        if !keep.favorite { keep.favorite = dropped.favorite }
        if keep.artwork == nil { keep.artwork = dropped.artwork }
        if keep.lyrics?.isEmpty != false { keep.lyrics = dropped.lyrics }
        if keep.comment?.isEmpty != false { keep.comment = dropped.comment }
        if keep.mediaInfo == nil { keep.mediaInfo = dropped.mediaInfo }
        if keep.originalFilename == nil { keep.originalFilename = dropped.originalFilename }
        if keep.title.isEmpty || LibraryImport.isUUIDLike(keep.title),
          !dropped.title.isEmpty, !LibraryImport.isUUIDLike(dropped.title)
        {
          keep.title = dropped.title
          if !dropped.artist.isEmpty { keep.artist = dropped.artist }
          if !dropped.album.isEmpty { keep.album = dropped.album }
        }
        dropToKeep[dropID] = group.keep
        report.merged += 1
      }
      keepUpdates[group.keep] = keep
    }

    if !dropToKeep.isEmpty {
      report.backupName = backupLibraryFile()
      let previous = state
      var next = state
      let droppedIDs = Set(dropToKeep.keys)
      next.songs = songs.filter { !droppedIDs.contains($0.id) }
      for index in next.songs.indices {
        if let updated = keepUpdates[next.songs[index].id] { next.songs[index] = updated }
      }
      next.playlists = next.playlists?.map { playlist in
        var value = playlist
        value.songIDs = value.songIDs.map { dropToKeep[$0] ?? $0 }
        return value
      }
      next.listens = next.listens.map { listen in
        var value = listen
        if let keep = dropToKeep[value.songID] { value.songID = keep }
        return value
      }
      next.ratings = next.ratings.map { rating in
        var value = rating
        if let keep = dropToKeep[value.songID] { value.songID = keep }
        return value
      }
      if let creations = next.creations {
        next.creations = creations.map { job in
          var value = job
          if let songID = value.songID, let keep = dropToKeep[songID] { value.songID = keep }
          return value
        }
      }
      if let log = next.tuningLog {
        next.tuningLog = log.map { record in
          var value = record
          if let keep = dropToKeep[value.songID] { value.songID = keep }
          return value
        }
      }
      if let progress = next.bookProgress {
        next.bookProgress = progress.mapValues { entry in
          var value = entry
          if let songID = value.songID, let keep = dropToKeep[songID] { value.songID = keep }
          return value
        }
      }
      if let curves = next.songCurves {
        var rebuilt: [String: SongCurve] = [:]
        for (songID, curve) in curves {
          let key = dropToKeep[songID] ?? songID
          if rebuilt[key] == nil { rebuilt[key] = curve }
        }
        next.songCurves = rebuilt
      }
      // 文件夹成员记录也一起归一，避免下次扫描把已合并的成员当成「消失」。
      if let records = next.importedFolderPaths {
        next.importedFolderPaths = Dictionary(
          grouping: records.flatMap { key, locators in
            locators.map { (LibraryImport.identityKey(key, documents: documents), LibraryImport.identityKey($0, documents: documents)) }
          },
          by: { $0.0 }
        ).mapValues { rows in Array(Set(rows.map { $0.1 })) }
      }
      do {
        try commit(next)
      } catch {
        state = previous
        message = "整理失败：无法写入曲库（\(error.localizedDescription)）"
        report.ran = false
        return report
      }
      // 只删「已经没有曲目引用」的缓存文件。
      let stillReferenced = Set(state.songs.compactMap(\.file))
      for dropID in droppedIDs {
        guard let dropped = songs.first(where: { $0.id == dropID }), let file = dropped.file,
          !stillReferenced.contains(file)
        else { continue }
        let url = music.appendingPathComponent(file)
        if let size = Self.fileSize(url) { report.freedBytes += size }
        if (try? FileManager.default.removeItem(at: url)) != nil { report.removedFiles += 1 }
      }
    }

    // 3. 孤儿缓存：没人引用、且放置超过一小时（避开正在写入的下载 / 渲染）。
    let referencedFiles = Set(state.songs.compactMap(\.file))
    let cutoff = Date().addingTimeInterval(-3600)
    if !busy,
      let listing = try? FileManager.default.contentsOfDirectory(
        at: music, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
        options: [.skipsHiddenFiles])
    {
      for file in listing {
        let name = file.lastPathComponent
        if referencedFiles.contains(name) { continue }
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let date = values?.contentModificationDate, date < cutoff else { continue }
        if let size = values?.fileSize { report.freedBytes += Int64(size) }
        if (try? FileManager.default.removeItem(at: file)) != nil { report.removedFiles += 1 }
      }
    }

    report.ran = true
    return report
  }

  /// 歌单 / 听书进度 / 评分 / 听歌记录 / 曲线 / 调音记录里被引用的曲目 id。
  func referencedSongIDs() -> Set<String> {
    var ids = Set<String>()
    for playlist in state.playlists ?? [] { ids.formUnion(playlist.songIDs) }
    for listen in state.listens { ids.insert(listen.songID) }
    for rating in state.ratings { ids.insert(rating.songID) }
    for job in state.creations ?? [] { if let songID = job.songID { ids.insert(songID) } }
    for record in state.tuningLog ?? [] { ids.insert(record.songID) }
    for entry in (state.bookProgress ?? [:]).values {
      if let songID = entry.songID { ids.insert(songID) }
    }
    return ids
  }

  /// 整理前留一份原件；只保留最近三份，避免 `library.json` 旁边越长越多。
  func backupLibraryFile() -> String? {
    let source = root.appendingPathComponent("library.json")
    guard FileManager.default.fileExists(atPath: source.path) else { return nil }
    let name = "library.json.before-repair-\(Int(Date().timeIntervalSince1970))"
    do {
      try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(name))
    } catch {
      return nil
    }
    let manager = FileManager.default
    if let listing = try? manager.contentsOfDirectory(atPath: root.path) {
      let backups = listing.filter { $0.hasPrefix("library.json.before-repair-") }.sorted()
      for stale in backups.dropLast(3) {
        try? manager.removeItem(at: root.appendingPathComponent(stale))
      }
    }
    return name
  }

  /// 启动时跑一次整理（只在第一次升级到这个版本时），之后由设置页按钮手动触发。
  static let libraryRepairKey = "libraryRepair.v2"

  func repairLibraryIfNeeded() async {
    guard !UserDefaults.standard.bool(forKey: Self.libraryRepairKey) else { return }
    let report = await repairLocalLibrary()
    guard report.ran else { return }
    UserDefaults.standard.set(true, forKey: Self.libraryRepairKey)
    if report.merged > 0 || report.removedFiles > 0 {
      message = report.summary
      Diagnostics.log("曲库整理：\(report.summary)（扫描 \(report.scanned) 首）")
    }
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
