import CommonCrypto
import CryptoKit
import Foundation
import UIKit

/// v1 备份格式错误。密码错误/密文篡改统一使用同一个提示，避免泄露细节。
enum BackupError: LocalizedError, Equatable {
  case invalidContainer
  case wrongPassword
  case crossPlatform(String)
  case unsupportedSchema(String)
  case invalidPayload
  case passwordTooShort
  case passwordMismatch
  case fileTooLarge
  case cryptoUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidContainer: return "不是有效的 Awake 备份文件"
    case .wrongPassword: return "密码错误或备份已损坏"
    case .crossPlatform(let message): return message
    case .unsupportedSchema(let message): return message
    case .invalidPayload: return "备份内容不完整或已损坏"
    case .passwordTooShort: return "备份密码至少 8 个字符"
    case .passwordMismatch: return "两次输入的密码不一致"
    case .fileTooLarge: return "备份文件不能超过 32 MB"
    case .cryptoUnavailable: return "无法派生备份密钥"
    }
  }
}

struct BackupEnvelope: Codable, Equatable {
  var format: String
  var version: Int
  var kdf: String
  var iterations: Int
  var salt: String
  var cipher: String
  var data: String
}

/// AES-256-GCM + PBKDF2-HMAC-SHA256 容器实现（格式见 docs/backup-format.md）。
enum BackupCrypto {
  static let format = "awake-e2e"
  static let version = 1
  static let kdf = "pbkdf2-hmac-sha256"
  static let cipher = "aes-256-gcm"
  static let iterations = 310_000
  static let saltLength = 16
  static let nonceLength = 12
  static let tagLength = 16
  static let keyLength = 32
  static let minimumPasswordLength = 8

  static func validatePassword(_ password: String, confirmation: String? = nil) throws {
    guard password.count >= minimumPasswordLength else { throw BackupError.passwordTooShort }
    if let confirmation, confirmation != password { throw BackupError.passwordMismatch }
  }

  static func deriveKey(_ password: String, salt: Data) throws -> SymmetricKey {
    guard !password.isEmpty, salt.count == saltLength else { throw BackupError.invalidContainer }
    var key = [UInt8](repeating: 0, count: keyLength)
    let passwordBytes = Array(password.utf8)
    let status: Int32 = passwordBytes.withUnsafeBytes { passwordBuffer in
      salt.withUnsafeBytes { saltBuffer in
        key.withUnsafeMutableBytes { keyBuffer in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self), passwordBytes.count,
            saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
            keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
        }
      }
    }
    guard status == kCCSuccess else { throw BackupError.cryptoUnavailable }
    return SymmetricKey(data: Data(key))
  }

  /// 固定 salt/nonce 的加密入口同时用于生产与 docs/backup-vector.json 的跨端校验。
  static func encrypt(
    _ plaintext: Data, password: String, salt: Data? = nil, nonce: Data? = nil
  ) throws -> BackupEnvelope {
    try validatePassword(password)
    let salt = salt ?? randomBytes(saltLength)
    let nonce = nonce ?? randomBytes(nonceLength)
    guard salt.count == saltLength, nonce.count == nonceLength else {
      throw BackupError.invalidContainer
    }
    let key = try deriveKey(password, salt: salt)
    let box = try AES.GCM.seal(
      plaintext, using: key, nonce: try AES.GCM.Nonce(data: nonce))
    guard let combined = box.combined else { throw BackupError.cryptoUnavailable }
    return BackupEnvelope(
      format: format, version: version, kdf: kdf, iterations: iterations,
      salt: salt.base64EncodedString(), cipher: cipher, data: combined.base64EncodedString())
  }

  static func open(_ envelope: BackupEnvelope, password: String) throws -> Data {
    guard envelope.format == format, envelope.version == version, envelope.kdf == kdf,
      envelope.iterations == iterations, envelope.cipher == cipher,
      let salt = Data(base64Encoded: envelope.salt), salt.count == saltLength,
      let combined = Data(base64Encoded: envelope.data),
      combined.count >= nonceLength + tagLength
    else { throw BackupError.invalidContainer }
    let key = try deriveKey(password, salt: salt)
    do {
      let box = try AES.GCM.SealedBox(combined: combined)
      return try AES.GCM.open(box, using: key)
    } catch { throw BackupError.wrongPassword }
  }

  static func open(_ data: Data, password: String) throws -> Data {
    let envelope: BackupEnvelope
    do { envelope = try JSONDecoder().decode(BackupEnvelope.self, from: data) } catch {
      throw BackupError.invalidContainer
    }
    return try open(envelope, password: password)
  }

  private static func randomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
  }
}

/// 明文 payload 里的当前播放位置。备份不包含音频文件。
struct BackupPlayback: Codable, Equatable {
  var title: String
  var artist: String
  var album: String
  var duration: Double
  var position: Double

  init(
    title: String, artist: String = "", album: String = "", duration: Double = 0,
    position: Double = 0
  ) {
    self.title = title
    self.artist = artist
    self.album = album
    self.duration = duration.isFinite && duration >= 0 ? duration : 0
    self.position = position.isFinite && position >= 0 ? position : 0
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
    album = try container.decodeIfPresent(String.self, forKey: .album) ?? ""
    duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
    position = try container.decodeIfPresent(Double.self, forKey: .position) ?? 0
    guard duration.isFinite, duration >= 0, position.isFinite, position >= 0 else {
      throw BackupError.invalidPayload
    }
  }

  var summary: String {
    let name = title.isEmpty ? "未知曲目" : title
    return "\(name)（\(BackupFormat.clock(position))）"
  }
}

/// iOS 明文 payload（schema = awake.backup.ios）。
struct IOSBackupPayload: Codable {
  static let iosSchema = "awake.backup.ios"
  static let macSchema = "awake.backup.macos"
  static let currentVersion = 1

  var schema: String
  var version: Int
  var exportedAtMS: Int64
  var device: String
  var appVersion: String
  var library: LibraryState
  var playback: BackupPlayback?

  init(
    schema: String = iosSchema, version: Int = currentVersion, exportedAtMS: Int64,
    device: String, appVersion: String, library: LibraryState, playback: BackupPlayback?
  ) {
    self.schema = schema
    self.version = version
    self.exportedAtMS = exportedAtMS
    self.device = device
    self.appVersion = appVersion
    self.library = library
    self.playback = playback
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decode(String.self, forKey: .schema)
    guard schema == Self.iosSchema else { throw BackupError.unsupportedSchema("不支持的备份格式：\(schema)") }
    version = try container.decode(Int.self, forKey: .version)
    guard version == Self.currentVersion else {
      throw BackupError.unsupportedSchema("不支持的备份格式：\(schema) v\(version)")
    }
    exportedAtMS = try container.decode(Int64.self, forKey: .exportedAtMS)
    device = try container.decodeIfPresent(String.self, forKey: .device) ?? "未知设备"
    appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? "未知版本"
    library = try container.decode(LibraryState.self, forKey: .library)
    playback = try container.decodeIfPresent(BackupPlayback.self, forKey: .playback)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(version, forKey: .version)
    try container.encode(exportedAtMS, forKey: .exportedAtMS)
    try container.encode(device, forKey: .device)
    try container.encode(appVersion, forKey: .appVersion)
    try container.encode(library, forKey: .library)
    try container.encodeIfPresent(playback, forKey: .playback)
  }

  private enum CodingKeys: String, CodingKey {
    case schema, version, device, library, playback
    case exportedAtMS = "exported_at_ms"
    case appVersion = "app_version"
  }
}

struct BackupPreview {
  let schema: String
  let version: Int
  let exportedAtMS: Int64
  let device: String
  let appVersion: String
  let trackCount: Int
  let playlistCount: Int
  let favoriteCount: Int
  let byteCount: Int
  let playback: BackupPlayback?

  var exportedAtText: String { BackupFormat.time(exportedAtMS) }
}

struct BackupRestoreResult {
  let preview: BackupPreview
  let safetyCopy: URL
}

enum BackupFormat {
  static func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  static func time(_ milliseconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}

/// 创建、预览、恢复。所有解密失败都落在统一的“密码错误或备份已损坏”。
enum BackupService {
  static let maxFileBytes = 32 * 1024 * 1024

  static var deviceName: String {
    let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "iPhone" : String(name.prefix(80))
  }

  static var appVersion: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    return version.isEmpty ? "未知版本" : version
  }

  static func makeBackup(
    state: LibraryState, playback: BackupPlayback?, password: String,
    exportedAt: Date = Date(), device: String = deviceName, appVersion: String = appVersion
  ) throws -> Data {
    try BackupCrypto.validatePassword(password)
    let payload = IOSBackupPayload(
      exportedAtMS: Int64((exportedAt.timeIntervalSince1970 * 1000).rounded()),
      device: String(device.prefix(80)), appVersion: String(appVersion.prefix(40)),
      library: state, playback: playback)
    let plaintext = try JSONEncoder().encode(payload)
    let envelope = try BackupCrypto.encrypt(plaintext, password: password)
    return try JSONEncoder().encode(envelope)
  }

  @MainActor
  static func makeBackup(store: MobileStore, player: MobilePlayer?, password: String) throws -> Data {
    try makeBackup(
      state: store.state, playback: currentPlayback(player), password: password)
  }

  @MainActor
  static func currentPlayback(_ player: MobilePlayer?) -> BackupPlayback? {
    guard let player, let song = player.song else { return nil }
    let duration = player.duration > 0 ? player.duration : song.duration
    return BackupPlayback(
      title: song.title, artist: song.artist, album: song.album, duration: duration,
      position: player.position)
  }

  static func writeTemporary(
    _ data: Data, directory: URL? = nil, date: Date = Date()
  ) throws -> URL {
    let folder = directory ?? FileManager.default.temporaryDirectory
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let url = folder.appendingPathComponent(
      "Awake-backup-\(formatter.string(from: date)).awake-backup")
    try data.write(to: url, options: .atomic)
    return url
  }

  static func inspect(_ fileData: Data, password: String) throws -> BackupPreview {
    let payload = try openPayload(fileData, password: password)
    return preview(for: payload, byteCount: fileData.count)
  }

  @MainActor
  static func restore(
    into store: MobileStore, fileData: Data, password: String
  ) throws -> BackupRestoreResult {
    let payload = try openPayload(fileData, password: password)
    let preview = preview(for: payload, byteCount: fileData.count)
    let safetyCopy = try writeSafetyCopy(store)
    let previous = store.state
    store.state = normalized(payload.library)
    do {
      try store.persist()
    } catch {
      store.state = previous
      throw error
    }
    return BackupRestoreResult(preview: preview, safetyCopy: safetyCopy)
  }

  private struct PayloadHeader: Decodable {
    let schema: String?
  }

  private static func openPayload(_ fileData: Data, password: String) throws -> IOSBackupPayload {
    guard fileData.count <= maxFileBytes else { throw BackupError.fileTooLarge }
    // 恢复/预览不强制最短长度：短密码本身也应落到统一的“密码错误或备份已损坏”。
    let plaintext = try BackupCrypto.open(fileData, password: password)
    let header: PayloadHeader
    do { header = try JSONDecoder().decode(PayloadHeader.self, from: plaintext) } catch {
      throw BackupError.invalidPayload
    }
    guard let schema = header.schema else { throw BackupError.invalidPayload }
    switch schema {
    case IOSBackupPayload.iosSchema:
      break
    case IOSBackupPayload.macSchema:
      throw BackupError.crossPlatform(
        "这是 macOS 备份，请在 macOS 版 Awake 恢复。跨平台只支持歌单导入，不支持整体覆盖。")
    default:
      if schema.hasPrefix("awake.backup.") {
        throw BackupError.crossPlatform(
          "这是其他平台的备份（\(schema)），请在对应平台恢复。跨平台只支持歌单导入，不支持整体覆盖。")
      }
      throw BackupError.unsupportedSchema("不支持的备份格式：\(schema)")
    }
    let payload: IOSBackupPayload
    do {
      payload = try JSONDecoder().decode(IOSBackupPayload.self, from: plaintext)
    } catch let error as BackupError {
      throw error
    } catch {
      throw BackupError.invalidPayload
    }
    guard payload.exportedAtMS > 0, payload.library.songs.count <= 1_000_000 else {
      throw BackupError.invalidPayload
    }
    do { try payload.library.skin.validate() } catch { throw BackupError.invalidPayload }
    return payload
  }

  private static func preview(for payload: IOSBackupPayload, byteCount: Int) -> BackupPreview {
    BackupPreview(
      schema: payload.schema, version: payload.version, exportedAtMS: payload.exportedAtMS,
      device: payload.device, appVersion: payload.appVersion,
      trackCount: payload.library.songs.count,
      playlistCount: payload.library.playlists?.count ?? 0,
      favoriteCount: payload.library.songs.filter(\.favorite).count, byteCount: byteCount,
      playback: payload.playback)
  }

  @MainActor
  private static func writeSafetyCopy(_ store: MobileStore) throws -> URL {
    let manager = FileManager.default
    let destination = store.root.appendingPathComponent("library.json.before-restore")
    let current = store.root.appendingPathComponent("library.json")
    if manager.fileExists(atPath: destination.path) {
      try manager.removeItem(at: destination)
    }
    if manager.fileExists(atPath: current.path) {
      try manager.copyItem(at: current, to: destination)
    } else {
      let data = try JSONEncoder().encode(store.state)
      try data.write(to: destination, options: .atomic)
    }
    return destination
  }

  /// 与 MobileStore 首次加载一致：上次运行中/排队中的生成任务标记为中断，不会自动重发。
  private static func normalized(_ state: LibraryState) -> LibraryState {
    var next = state
    next.creations = next.creations?.map { job in
      var restored = job
      if restored.state == "running" || restored.state == "queued" {
        restored.state = "interrupted"
        restored.error = "应用退出使接收中断，不会自动重复请求"
      }
      return restored
    }
    return next
  }
}
