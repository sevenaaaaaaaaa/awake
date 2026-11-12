import AVFoundation
import Foundation
import Security
import SwiftUI

struct Song: Identifiable, Codable, Equatable {
  var id = UUID().uuidString
  var title: String
  var artist = "未知艺人"
  var album = ""
  var genre = ""
  var duration: Double = 0
  var sampleRate: Double = 0
  var file: String?
  var sourceID: String?
  var locator = ""
  var favorite = false
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
struct Playlist: Identifiable, Codable, Equatable {
  var id = UUID().uuidString
  var name: String
  var songIDs: [String] = []
  var createdAt = Date()
  var note = ""
}
struct MusicSource: Identifiable, Codable {
  var id = UUID().uuidString
  var name: String
  var kind: String
  var url: String
  var username = ""
  /// 用户明确勾选后才对该来源的主机放行自签名 HTTPS 证书。
  var trustSelfSigned = false

  init(id: String = UUID().uuidString, name: String, kind: String, url: String, username: String = "", trustSelfSigned: Bool = false) {
    self.id = id
    self.name = name
    self.kind = kind
    self.url = url
    self.username = username
    self.trustSelfSigned = trustSelfSigned
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名来源"
    kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "webdav"
    url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
    trustSelfSigned = try c.decodeIfPresent(Bool.self, forKey: .trustSelfSigned) ?? false
  }

  private enum CodingKeys: String, CodingKey { case id, name, kind, url, username, trustSelfSigned }
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
  var version = 1
  var id: String
  var name: String
  var mode: String
  var colors: Colors
  var radius: Double = 16
  var density = "comfortable"
  var font = "system"
  var blur: Double = 0
  static let dark = Skin(
    id: "dark", name: "黑色 · Obsidian", mode: "dark",
    colors: .init(
      bg: "#0c0d10", surface: "#14161b", raised: "#20232b", text: "#f5f6fa", muted: "#a5adbe",
      accent: "#a9bcff", onAccent: "#11182f", border: "#303540"))
  static let light = Skin(
    id: "light", name: "白色 · Paper", mode: "light",
    colors: .init(
      bg: "#f6f7fb", surface: "#ffffff", raised: "#ebedf4", text: "#171a24", muted: "#596177",
      accent: "#3455d9", onAccent: "#ffffff", border: "#d7dce8"))
  static let glass = Skin(
    id: "glass", name: "玻璃 · Aurora", mode: "glass",
    colors: .init(
      bg: "#0b1125", surface: "#18213b", raised: "#27324e", text: "#f6f8ff", muted: "#b6c2dd",
      accent: "#a7e8df", onAccent: "#0b2827", border: "#435575"), radius: 20, blur: 24)
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
    guard version == 1, !name.isEmpty, name.count <= 60, ["dark", "light", "glass"].contains(mode),
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
}
@MainActor final class MobileStore: ObservableObject {
  @Published var state = LibraryState()
  @Published var message = ""
  @Published var busy = false
  @Published var generationRunning = false
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
      let path = self.root.appendingPathComponent("library.json")
      if FileManager.default.fileExists(atPath: path.path) {
        do {
          let decoded = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: path))
          try decoded.skin.validate()
          state = decoded
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
  func localURL(_ song: Song) -> URL? {
    guard let name = song.file, URL(fileURLWithPath: name).lastPathComponent == name else {
      return nil
    }
    let u = music.appendingPathComponent(name)
    return FileManager.default.fileExists(atPath: u.path) ? u : nil
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
  func importAudioFolder(_ url: URL) async {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    busy = true
    defer { busy = false }
    do {
      let urls: [URL] = try await Task.detached(priority: .userInitiated) {
        try Self.audioFiles(in: url)
      }.value
      guard !urls.isEmpty else {
        throw AppFailure("这个文件夹里没有支持的音频文件（mp3 / m4a / flac / wav / aiff / alac / caf）")
      }
      await importFiles(urls, report: true)
    } catch { message = "导入失败：" + error.localizedDescription }
  }
  nonisolated static func audioFiles(in url: URL) throws -> [URL] {
        guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
          throw AppFailure("无法读取选择的文件夹")
        }
        var files: [URL] = []
        for case let file as URL in entries {
          let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          if values.isSymbolicLink == true { entries.skipDescendants(); continue }
          if values.isRegularFile == true && ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "alac"].contains(file.pathExtension.lowercased()) {
            files.append(file)
            guard files.count <= 20000 else { throw AppFailure("文件夹超过两万首，请选择更小的目录") }
          }
        }
        return files.sorted { $0.path < $1.path }
  }
  func importFiles(_ urls: [URL], report: Bool = false) async {
    busy = true
    defer { busy = false }
    var added = 0
    var failed = 0
    var firstFailure = ""
    for url in urls {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      do {
        let ext = url.pathExtension.lowercased()
        guard ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "alac"].contains(ext)
        else { throw AppFailure("不支持的文件：\(url.lastPathComponent)") }
        let name = UUID().uuidString + "." + ext
        let dest = music.appendingPathComponent(name)
        try await Task.detached(priority: .userInitiated) {
          try Self.copyImported(url, to: dest)
        }.value
        do {
          var song = try await Self.readSong(dest, file: name)
          song.originalFilename = url.lastPathComponent
          Self.readSidecars(from: url, song: &song, directory: artworkDirectory)
          if song.title == dest.deletingPathExtension().lastPathComponent {
            song.title = url.deletingPathExtension().lastPathComponent
          }
          state.songs.append(song)
          save()
          added += 1
        } catch {
          try? FileManager.default.removeItem(at: dest)
          throw error
        }
      } catch {
        failed += 1
        if firstFailure.isEmpty { firstFailure = error.localizedDescription }
      }
    }
    if failed > 0 {
      message =
        added > 0
        ? "已导入 \(added) 首，\(failed) 首失败：\(firstFailure)"
        : "导入失败：" + firstFailure
    } else if added > 0, report || added > 1 {
      message = "已导入 \(added) 首到本机"
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
  static func readSong(_ url: URL, file: String) async throws -> Song {
    let audio = try AVAudioFile(forReading: url)
    guard audio.length > 0 else { throw AppFailure("音频为空") }
    var song = Song(
      title: url.deletingPathExtension().lastPathComponent,
      duration: Double(audio.length) / audio.processingFormat.sampleRate,
      sampleRate: audio.processingFormat.sampleRate, file: file)
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
        state.songs.append(song)
        try updateJob(job.id) {
          $0.state = "completed"
          $0.songID = song.id
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
