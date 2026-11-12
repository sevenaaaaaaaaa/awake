import XCTest

@testable import Awake

final class BackupTests: XCTestCase {
  private let password = "Awake-test-123"

  private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AwakeBackupTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func sealed(_ json: String) throws -> Data {
    let envelope = try BackupCrypto.encrypt(
      Data(json.utf8), password: password,
      salt: Data(repeating: 0x4a, count: BackupCrypto.saltLength),
      nonce: Data(repeating: 0x2b, count: BackupCrypto.nonceLength))
    return try JSONEncoder().encode(envelope)
  }

  private func backupErrorMessage(_ expression: @autoclosure () throws -> Any) -> String {
    do {
      _ = try expression()
      return "没有抛出错误"
    } catch {
      return error.localizedDescription
    }
  }

  func testFixedVectorEncryptsAndDecryptsToSameData() throws {
    let salt = Data(base64Encoded: "ABEiM0RVZneImaq7zN3u/w==")!
    let nonce = Data(base64Encoded: "AAECAwQFBgcICQoL")!
    let payload = Data(
      #"{"schema":"awake.backup.test","version":1,"message":"hello awake"}"#.utf8)
    let expected =
      "AAECAwQFBgcICQoLMDUgbWvLP74LSIE1AHPmaA34YUNnvVlMUkQDFj6kqNJ0zcnVswbSGa/h5HZ9nsjMCIJ/ZjcqhNOdQr2LPyrW8m07aRH3SdS5BTGbL2IdoFVX8g=="

    let envelope = try BackupCrypto.encrypt(
      payload, password: password, salt: salt, nonce: nonce)
    XCTAssertEqual(envelope.iterations, 310_000)
    XCTAssertEqual(envelope.salt, "ABEiM0RVZneImaq7zN3u/w==")
    XCTAssertEqual(envelope.data, expected)

    let encoded = try JSONEncoder().encode(envelope)
    XCTAssertEqual(try BackupCrypto.open(encoded, password: password), payload)

    let documented = BackupEnvelope(
      format: "awake-e2e", version: 1, kdf: "pbkdf2-hmac-sha256", iterations: 310_000,
      salt: "ABEiM0RVZneImaq7zN3u/w==", cipher: "aes-256-gcm", data: expected)
    XCTAssertEqual(
      try BackupCrypto.open(JSONEncoder().encode(documented), password: password), payload)
  }

  @MainActor
  func testBackupRoundTripInspectAndRestore() throws {
    let sourceRoot = try temporaryRoot()
    let targetRoot = try temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: targetRoot)
    }

    let store = MobileStore(root: sourceRoot)
    store.state.songs = [
      Song(
        id: "s1", title: "夜曲", artist: "周杰伦", album: "十一月的萧邦", duration: 225,
        favorite: true),
      Song(id: "s2", title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269),
    ]
    store.state.playlists = [
      Playlist(id: "p1", name: "深夜", songIDs: ["s1", "s2"], note: "")
    ]
    store.save()

    let playback = BackupPlayback(
      title: "夜曲", artist: "周杰伦", album: "十一月的萧邦", duration: 225, position: 42.5)
    let data = try BackupService.makeBackup(
      state: store.state, playback: playback, password: password,
      exportedAt: Date(timeIntervalSince1970: 1_790_000_000), device: "Test iPhone",
      appVersion: "0.7.7")

    let temporary = try BackupService.writeTemporary(data, directory: sourceRoot)
    XCTAssertEqual(temporary.pathExtension, "awake-backup")
    let saved = try Data(contentsOf: temporary)
    XCTAssertEqual(saved, data)

    let preview = try BackupService.inspect(saved, password: password)
    XCTAssertEqual(preview.schema, "awake.backup.ios")
    XCTAssertEqual(preview.version, 1)
    XCTAssertEqual(preview.device, "Test iPhone")
    XCTAssertEqual(preview.appVersion, "0.7.7")
    XCTAssertEqual(preview.trackCount, 2)
    XCTAssertEqual(preview.playlistCount, 1)
    XCTAssertEqual(preview.favoriteCount, 1)
    XCTAssertEqual(preview.exportedAtMS, 1_790_000_000_000)
    XCTAssertEqual(preview.playback, playback)
    XCTAssertEqual(preview.byteCount, data.count)

    let target = MobileStore(root: targetRoot)
    target.state.songs = [Song(id: "old", title: "旧曲", artist: "旧艺人", duration: 1)]
    target.save()
    let result = try BackupService.restore(into: target, fileData: data, password: password)
    XCTAssertEqual(target.state.songs.map(\.title), ["夜曲", "晴天"])
    XCTAssertEqual(target.state.playlists?.map(\.name), ["深夜"])
    XCTAssertEqual(target.state.songs.filter(\.favorite).count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.safetyCopy.path))
    XCTAssertTrue(result.safetyCopy.lastPathComponent.hasSuffix(".before-restore"))

    let safety = try JSONDecoder().decode(
      LibraryState.self, from: Data(contentsOf: result.safetyCopy))
    XCTAssertEqual(safety.songs.map(\.title), ["旧曲"])

    let reopened = MobileStore(root: targetRoot)
    XCTAssertEqual(reopened.state.songs.map(\.title), ["夜曲", "晴天"])
    XCTAssertEqual(reopened.state.playlists?.first?.name, "深夜")
    XCTAssertEqual(reopened.state.songs.filter(\.favorite).count, 1)
  }

  func testWrongPasswordAndTamperedCiphertextUseUnifiedError() throws {
    let data = try BackupService.makeBackup(
      state: LibraryState(), playback: nil, password: password, device: "Test", appVersion: "1")

    XCTAssertEqual(
      backupErrorMessage(try BackupService.inspect(data, password: "Awake-test-124")),
      "密码错误或备份已损坏")
    XCTAssertEqual(
      backupErrorMessage(try BackupService.inspect(data, password: "short")),
      "密码错误或备份已损坏")

    var envelope = try JSONDecoder().decode(BackupEnvelope.self, from: data)
    var bytes = [UInt8](try XCTUnwrap(Data(base64Encoded: envelope.data)))
    bytes[bytes.count - 1] ^= 0x01
    envelope.data = Data(bytes).base64EncodedString()
    let tampered = try JSONEncoder().encode(envelope)
    XCTAssertEqual(
      backupErrorMessage(try BackupService.inspect(tampered, password: password)),
      "密码错误或备份已损坏")

    XCTAssertEqual(
      backupErrorMessage(try BackupService.inspect(Data("not json".utf8), password: password)),
      "不是有效的 Awake 备份文件")
  }

  func testRejectsForeignUnknownAndNewerSchemas() throws {
    let mac = #"{"schema":"awake.backup.macos","version":1,"exported_at_ms":1790000000000,"device":"MacBook","app_version":"0.7.1","library":{"songs":[]},"taste":{}}"#
    let macMessage = backupErrorMessage(try BackupService.inspect(try sealed(mac), password: password))
    XCTAssertTrue(macMessage.contains("macOS"), macMessage)
    XCTAssertTrue(macMessage.contains("歌单导入"), macMessage)

    let other = #"{"schema":"awake.backup.android","version":1,"exported_at_ms":1790000000000,"device":"Phone","library":{}}"#
    let otherMessage = backupErrorMessage(try BackupService.inspect(try sealed(other), password: password))
    XCTAssertTrue(otherMessage.contains("对应平台"), otherMessage)
    XCTAssertTrue(otherMessage.contains("歌单导入"), otherMessage)

    let unknown = #"{"schema":"other.backup","version":1,"library":{}}"#
    let unknownMessage = backupErrorMessage(try BackupService.inspect(try sealed(unknown), password: password))
    XCTAssertTrue(unknownMessage.contains("不支持的备份格式"), unknownMessage)

    let newer = #"{"schema":"awake.backup.ios","version":2,"exported_at_ms":1790000000000,"device":"iPhone","app_version":"9.0","library":{"songs":[]}}"#
    let newerMessage = backupErrorMessage(try BackupService.inspect(try sealed(newer), password: password))
    XCTAssertTrue(newerMessage.contains("不支持的备份格式"), newerMessage)
  }

  @MainActor
  func testFailedRestoreKeepsLibraryAndDoesNotWriteSafetyCopy() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MobileStore(root: root)
    store.state.songs = [Song(id: "keep", title: "保留", artist: "A", duration: 3)]
    store.save()

    let mac = #"{"schema":"awake.backup.macos","version":1,"exported_at_ms":1790000000000,"device":"MacBook","app_version":"0.7.1","library":{"songs":[]},"taste":{}}"#
    let data = try sealed(mac)
    XCTAssertThrowsError(try BackupService.restore(into: store, fileData: data, password: password))
    XCTAssertEqual(store.state.songs.map(\.title), ["保留"])
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("library.json.before-restore").path))
    XCTAssertEqual(MobileStore(root: root).state.songs.map(\.title), ["保留"])
  }

  func testPasswordPolicy() throws {
    XCTAssertThrowsError(try BackupCrypto.validatePassword("1234567"))
    XCTAssertThrowsError(
      try BackupCrypto.validatePassword("12345678", confirmation: "12345679"))
    XCTAssertNoThrow(try BackupCrypto.validatePassword("12345678", confirmation: "12345678"))
  }

  func testClockFormatting() {
    XCTAssertEqual(BackupFormat.clock(0), "0:00")
    XCTAssertEqual(BackupFormat.clock(42.5), "0:42")
    XCTAssertEqual(BackupFormat.clock(125.9), "2:05")
    XCTAssertEqual(BackupFormat.clock(.nan), "0:00")
  }
}
