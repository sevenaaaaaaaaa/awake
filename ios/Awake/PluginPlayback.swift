import Foundation
import AVFoundation

/// S3：把插件曲目解析成直链，带请求头下载到本机，再交给现有 EQ 播放链路。
///
/// 与 `SourceService.cache` 同口径：先落 .part，能解码才改名成正式文件；
/// 文件名必须是裸文件名（`localURL` 会拒绝带路径的 file 字段）。
enum PluginPlayback {
  static func cache(_ song: Song, code: String, directory: URL) async throws -> Song {
    let resolved = try await PluginSandbox.shared.resolve(code: code, itemJSON: song.locator)
    guard let url = URL(string: resolved.url),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { throw AppFailure("插件给出的播放地址不是 http(s)") }

    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    for pair in resolved.headers where pair.count >= 2 {
      request.setValue(pair[1], forHTTPHeaderField: pair[0])
    }
    let temp = try await Network.download(request, limit: 512 * 1024 * 1024)
    defer { try? FileManager.default.removeItem(at: temp) }

    let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased()
    let name = song.id + "." + ext
    let dest = directory.appendingPathComponent(name)
    let partial = directory.appendingPathComponent(song.id + ".part")
    try? FileManager.default.removeItem(at: partial)
    try FileManager.default.copyItem(at: temp, to: partial)
    do {
      let decoded = try AVAudioFile(forReading: partial)
      let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 4096)!
      try decoded.read(into: buffer)
      guard buffer.frameLength > 0 else { throw AppFailure("音频解码为空") }
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.moveItem(at: partial, to: dest)
      var out = song
      if let tags = try? await MobileStore.readSong(dest, file: name) {
        if out.artwork == nil { out.artwork = tags.artwork }
        if out.lyrics?.isEmpty ?? true { out.lyrics = tags.lyrics }
        if out.comment?.isEmpty ?? true { out.comment = tags.comment }
      }
      out.file = name
      out.duration = Double(decoded.length) / decoded.processingFormat.sampleRate
      out.sampleRate = decoded.processingFormat.sampleRate
      return out
    } catch {
      try? FileManager.default.removeItem(at: partial)
      throw error
    }
  }
}
