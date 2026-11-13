import AVFoundation
import Foundation

/// 把分章文本合成为本机音频文件（CAF 中间格式 → AAC m4a），
/// 生成后作为普通曲目加入曲库，与桌面端的「AI 有声书」保持一致。
@MainActor
enum SpeechRenderer {
  static func render(_ plan: SpeechPlan, store: MobileStore) async throws -> [Song] {
    guard !plan.chapters.isEmpty else { throw AppFailure("没有可合成的章节") }
    let voices = voiceMap(plan)
    var songs: [Song] = []
    for (index, chapter) in plan.chapters.enumerated() {
      let caf = store.music.appendingPathComponent(UUID().uuidString + ".caf")
      let m4a = store.music.appendingPathComponent(UUID().uuidString + ".m4a")
      do {
        try await synthesize(chapter, to: caf, voices: voices)
        let output: URL
        do {
          try await exportM4A(caf, to: m4a)
          try? FileManager.default.removeItem(at: caf)
          output = m4a
        } catch {
          try? FileManager.default.removeItem(at: m4a)
          output = caf
        }
        let audio = try AVAudioFile(forReading: output)
        guard audio.length > 0 else { throw AppFailure("第 \(index + 1) 章合成结果为空") }
        var song = Song(
          title: chapter.title,
          artist: plan.author.isEmpty ? "AI 有声书" : plan.author,
          album: plan.title,
          duration: Double(audio.length) / audio.processingFormat.sampleRate,
          sampleRate: audio.processingFormat.sampleRate,
          file: output.lastPathComponent)
        song.trackNumber = index + 1
        song.addedAt = Date()
        songs.append(song)
      } catch {
        try? FileManager.default.removeItem(at: caf)
        try? FileManager.default.removeItem(at: m4a)
        throw error
      }
    }
    return songs
  }

  private static func synthesize(
    _ chapter: SpeechChapter, to url: URL, voices: [String: AVSpeechSynthesisVoice]
  ) async throws {
    let synth = AVSpeechSynthesizer()
    var file: AVAudioFile?
    for segment in chapter.segments {
      let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = voices[segment.speaker] ?? voices[""]
      utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
      utterance.pitchMultiplier = 0.9 + Float(abs(segment.speaker.hashValue) % 4) * 0.06
      let buffers = try await capture(utterance, synth: synth)
      for buffer in buffers {
        guard buffer.frameLength > 0 else { continue }
        if file == nil {
          let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
            channels: buffer.format.channelCount, interleaved: false)!
          let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: buffer.format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
          ]
          file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        }
        guard let file else { continue }
        let converted = try convert(buffer, to: file.processingFormat)
        try file.write(from: converted)
      }
    }
    guard file != nil else { throw AppFailure("这一章没有可朗读的文本") }
  }

  private static func capture(
    _ utterance: AVSpeechUtterance, synth: AVSpeechSynthesizer
  ) async throws -> [AVAudioPCMBuffer] {
    let collector = Collector()
    synth.write(utterance) { buffer in
      if let pcm = buffer as? AVAudioPCMBuffer { collector.append(pcm) }
    }
    return try await collector.wait(timeout: 60)
  }

  private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var finished = false
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Error>?

    func append(_ buffer: AVAudioPCMBuffer) {
      lock.lock()
      defer { lock.unlock() }
      guard !finished else { return }
      if buffer.frameLength == 0 {
        finished = true
        let result = buffers
        continuation?.resume(returning: result)
        continuation = nil
      } else if let copy = Self.copy(buffer) {
        buffers.append(copy)
      }
    }

    func wait(timeout: TimeInterval) async throws -> [AVAudioPCMBuffer] {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if finished {
          let result = buffers
          lock.unlock()
          continuation.resume(returning: result)
        } else {
          self.continuation = continuation
          lock.unlock()
          DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.expire()
          }
        }
      }
    }

    private func expire() {
      lock.lock()
      guard !finished else {
        lock.unlock()
        return
      }
      finished = true
      let pending = continuation
      continuation = nil
      lock.unlock()
      pending?.resume(throwing: AppFailure("语音合成超时，请缩短章节后重试"))
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
      guard
        let copy = AVAudioPCMBuffer(
          pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
      else { return nil }
      copy.frameLength = buffer.frameLength
      guard let source = buffer.floatChannelData, let target = copy.floatChannelData else {
        return nil
      }
      for channel in 0..<Int(buffer.format.channelCount) {
        memcpy(
          target[channel], source[channel],
          Int(buffer.frameLength) * MemoryLayout<Float>.size)
      }
      return copy
    }
  }

  private static func convert(
    _ buffer: AVAudioPCMBuffer, to format: AVAudioFormat
  ) throws -> AVAudioPCMBuffer {
    if buffer.format.sampleRate == format.sampleRate,
      buffer.format.channelCount == format.channelCount,
      buffer.format.commonFormat == format.commonFormat,
      buffer.format.isInterleaved == format.isInterleaved
    {
      return buffer
    }
    guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
      throw AppFailure("无法转换语音格式")
    }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4096
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      throw AppFailure("无法创建语音缓冲")
    }
    var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    if let error { throw error }
    return output
  }

  private static func exportM4A(_ source: URL, to destination: URL) async throws {
    let asset = AVURLAsset(url: source)
    guard
      let session = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPresetAppleM4A)
    else { throw AppFailure("系统不支持导出 m4a") }
    try? FileManager.default.removeItem(at: destination)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      session.outputURL = destination
      session.outputFileType = .m4a
      session.exportAsynchronously {
        switch session.status {
        case .completed:
          continuation.resume()
        case .failed, .cancelled:
          continuation.resume(throwing: session.error ?? AppFailure("音频导出失败"))
        default:
          continuation.resume(throwing: AppFailure("音频导出被中断"))
        }
      }
    }
  }

  private static func voiceMap(_ plan: SpeechPlan) -> [String: AVSpeechSynthesisVoice] {
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
    let narrator =
      voices.first { $0.language == "zh-CN" } ?? AVSpeechSynthesisVoice(language: "zh-CN")
      ?? AVSpeechSynthesisVoice(language: "en-US")
    var map: [String: AVSpeechSynthesisVoice] = [:]
    if let narrator { map[""] = narrator }
    let speakers = Set(
      plan.chapters.flatMap { $0.segments.map(\.speaker) }.filter { !$0.isEmpty }
    ).sorted()
    for (index, speaker) in speakers.enumerated() where !voices.isEmpty {
      map[speaker] = voices[index % voices.count]
    }
    return map
  }
}
