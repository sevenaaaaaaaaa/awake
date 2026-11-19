import AVFoundation
import Foundation

/// 设备端诊断：用第三方工具重签安装的包拿不到 Xcode 日志，
/// 所以把关键结论写进 `Documents/Awake/diagnostics.log`（Files App 里可见、可分享），
/// 并在设置里提供一键自检 —— 沙盒写入、音频生成、解码各走一遍。
enum Diagnostics {
  static var fileURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Awake", isDirectory: true)
      .appendingPathComponent("diagnostics.log")
  }

  static func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(message)\n"
    let manager = FileManager.default
    let url = fileURL
    try? manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // 诊断日志不需要历史，超过 256 KB 直接重开。
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 256 * 1024 {
      try? Data().write(to: url)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      try? Data(line.utf8).write(to: url)
    }
  }

  static func reset() {
    try? FileManager.default.removeItem(at: fileURL)
  }

  /// 设备自检：沙盒写入 → 生成 1 秒 WAV → 解码 → 一页结论。
  /// 任何一步失败都把原因原文写出来，不让用户对着「导入失败」猜。
  static func selfTest() async -> String {
    let manager = FileManager.default
    var lines: [String] = []
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    lines.append("Awake \(version) (\(build))")
    lines.append("Bundle: \(Bundle.main.bundleIdentifier ?? "?")")
    let sharing =
      Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool ?? false
    let openInPlace =
      Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool
      ?? false
    lines.append("Files 可见: \(sharing ? "是" : "否") · 原地打开: \(openInPlace ? "是" : "否")")

    let docs = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let probe = docs.appendingPathComponent("Awake").appendingPathComponent(".diag-probe")
    do {
      try manager.createDirectory(
        at: probe.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("ok".utf8).write(to: probe)
      try manager.removeItem(at: probe)
      lines.append("沙盒写入: 通过")
    } catch {
      lines.append("沙盒写入: 失败 — \(error.localizedDescription)")
    }

    let music = docs.appendingPathComponent("Awake").appendingPathComponent("Music", isDirectory: true)
    let wav = music.appendingPathComponent("diagnostics.wav")
    do {
      try manager.createDirectory(at: music, withIntermediateDirectories: true)
      try? manager.removeItem(at: wav)
      let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
      let frames = AVAudioFrameCount(48_000)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
      buffer.frameLength = frames
      for channel in 0..<2 {
        for index in 0..<Int(frames) {
          buffer.floatChannelData![channel][index] =
            Float(sin(Double(index) * 2 * Double.pi * 440 / 48_000) * 0.1)
        }
      }
      let file = try AVAudioFile(forWriting: wav, settings: format.settings)
      try file.write(from: buffer)
      if let probe = await MobileStore.probeAudio(wav) {
        lines.append(
          String(format: "音频写入/解码: 通过（%.2f 秒 · %.0f Hz）", probe.duration, probe.rate))
      } else {
        lines.append("音频写入: 通过；解码: 失败 — AVFoundation 读不回刚写入的 WAV")
      }
      try? manager.removeItem(at: wav)
    } catch {
      lines.append("音频写入: 失败 — \(error.localizedDescription)")
    }
    lines.append("曲库: \(manager.urls(for: .documentDirectory, in: .userDomainMask)[0].path)")
    let report = lines.joined(separator: "\n")
    log("SELF TEST\n\(report)")
    return report
  }
}

#if DEBUG
extension Diagnostics {
  /// 端到端自检通道：启动时按环境变量真实跑一遍远端来源连接，把结果写进诊断日志。
  ///
  /// `AWAKE_E2E_SOURCE="plex|http://127.0.0.1:32400|token"`
  ///
  /// 存在的理由：Xcode 27 的模拟器测试 runner 在这台机器上起不来，
  /// 「连接成功但曲库看不到」这条链一直只能靠人点。有了它，扫描/入库可以在模拟器里
  /// 被脚本复现，结果直接落在 `Documents/Awake/diagnostics.log`。
  @MainActor static func e2eConnectIfRequested(_ store: MobileStore) {
    guard let raw = ProcessInfo.processInfo.environment["AWAKE_E2E_SOURCE"],
      !raw.trimmingCharacters(in: .whitespaces).isEmpty
    else { return }
    let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
      .map(String.init)
    guard parts.count == 3 else {
      log("E2E 参数无效：期望 kind|url|secret")
      return
    }
    let kind = parts[0]
    let url = parts[1]
    let secret = parts[2]
    Task {
      let source = MusicSource(name: "E2E " + kind, kind: kind, url: url)
      log("E2E 开始 kind=\(kind) url=\(url)")
      do {
        let songs = try await SourceService.scan(
          source, secret: secret, artwork: store.artworkDirectory)
        // 和设置页连接时一样把凭据写进钥匙串，否则播放时缓存远程音频会 401。
        try Secrets.set(secret, account: "source." + source.id)
        var next = store.state
        next.sources.append(source)
        next.songs.append(contentsOf: songs)
        store.state = next
        try store.persist()
        store.pendingLibrarySource = source.id
        log("E2E 扫描成功 songs=\(songs.count) 入库后曲目总数=\(next.songs.count)")
        for song in songs.prefix(5) {
          log("E2E 曲目 title=\(song.title) artist=\(song.artist) album=\(song.album) sourceID=\(song.sourceID ?? "nil") locator=\(song.locator)")
        }
      } catch {
        log("E2E 扫描失败 error=\(error.localizedDescription)")
      }
    }
  }
}
#endif

#if DEBUG
extension Diagnostics {
  /// 播放页自检：`AWAKE_E2E_PLAYER=1` 时播第一首并打开「正在播放」，
  /// 用来在模拟器里截取播放界面（模拟器没有可点击的 GUI）。
  @MainActor static func e2ePlayIfRequested(store: MobileStore, player: MobilePlayer) {
    guard ProcessInfo.processInfo.environment["AWAKE_E2E_PLAYER"] == "1" else { return }
    guard let song = store.state.songs.first else {
      log("E2E 播放：曲库为空")
      return
    }
    Task {
      if ProcessInfo.processInfo.environment["AWAKE_E2E_CHAIN"] == "1" {
        seedDemoChain(store: store, player: player)
      }
      await playSong(song, store: store, player: player)
      store.playerSheetOpen = true
      log("E2E 播放：\(song.title)")
    }
  }

  /// 造一条演示用的听感链路，用来在模拟器里看到「有曲线时」的播放页。
  /// 只在显式传 `AWAKE_E2E_CHAIN=1` 时创建，不是产品逻辑。
  @MainActor static func seedDemoChain(store: MobileStore, player: MobilePlayer) {
    guard store.state.chains.isEmpty else {
      if let chain = store.activeChain(route: player.route.uid) { player.useChain(chain, announce: false) }
      return
    }
    var chain = ListeningChain(
      routeUID: player.route.uid, name: "演示链路", headphone: "演示耳机", connection: "3.5 mm")
    let curve: [Float] = [
      3.0, 3.2, 3.0, 2.6, 2.0, 1.4, 0.8, 0.4, 0.0, -0.2, -0.2, 0.0, 0.4, 0.8,
      1.2, 1.4, 1.5, 1.4, 1.2, 0.8, 0.4, 0.0, -0.4, -0.8, -1.2, -1.6, -2.0,
      -2.4, -2.8, -3.2, -3.6,
    ]
    chain.gains = curve
    chain.measurementSource = "演示数据"
    store.state.chains.append(chain)
    store.state.activeChains[chain.routeUID] = chain.id
    store.save()
    player.useChain(chain, announce: false)
    log("E2E 已建立演示链路 route=\(chain.routeUID)")
  }
}
#endif
