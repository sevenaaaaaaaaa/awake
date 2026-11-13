import AVFoundation
import Foundation

struct SpeechSegment: Codable, Identifiable, Equatable {
  var id = UUID()
  var speaker = ""
  var text: String
}

struct SpeechChapter: Codable, Identifiable, Equatable {
  var id = UUID()
  var title: String
  var segments: [SpeechSegment]
}

struct SpeechPlan: Codable, Identifiable, Equatable {
  var id = UUID()
  var title: String
  var author: String
  var mode: String
  var chapters: [SpeechChapter]
  var createdAt = Date()
  var note: String?
}

enum TextPlanner {
  static func heading(_ line: String) -> String? {
    let text = line.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    if text.hasPrefix("#") {
      let title = text.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
      return title.isEmpty ? nil : String(title.prefix(80))
    }
    let lower = text.lowercased()
    if lower.hasPrefix("chapter ") { return String(text.prefix(80)) }
    if text.hasPrefix("第"), text.count <= 40 {
      let markers = ["章", "回", "节", "卷", "部", "篇"]
      if text.prefix(10).contains(where: { markers.contains(String($0)) }) {
        return String(text.prefix(80))
      }
    }
    return nil
  }

  static func plan(title: String, author: String, mode: String, text: String) -> SpeechPlan {
    let body = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = body.components(separatedBy: "\n")
    var chapters: [SpeechChapter] = []
    var current: String?
    var buffer: [String] = []

    func flush() {
      let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      buffer.removeAll()
      guard !joined.isEmpty else { return }
      let name = current ?? "第 \(chapters.count + 1) 章"
      for (index, chunk) in split(joined, limit: 3000).enumerated() {
        let chapterTitle = index == 0 ? name : name + "（续\(index)）"
        let segments =
          mode == "drama"
          ? drama(chunk)
          : [SpeechSegment(speaker: "", text: chunk)]
        chapters.append(SpeechChapter(title: chapterTitle, segments: segments))
      }
    }

    var title = title.trimmingCharacters(in: .whitespaces)
    var start = 0
    if title.isEmpty, let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
      let candidate = first.trimmingCharacters(in: .whitespaces)
      if heading(candidate) == nil, candidate.count <= 40,
        !candidate.hasSuffix("。"), !candidate.hasSuffix("，")
      {
        title = candidate
        start = (lines.firstIndex(of: first) ?? 0) + 1
      }
    }
    for line in lines.dropFirst(start) {
      if let next = heading(line) {
        flush()
        current = next
      } else {
        buffer.append(line)
      }
      if chapters.count >= 200 { break }
    }
    flush()
    if chapters.isEmpty {
      chapters = [
        SpeechChapter(title: "正文", segments: [SpeechSegment(speaker: "", text: body)])
      ]
    }
    return SpeechPlan(
      title: title.isEmpty ? "未命名有声书" : title,
      author: author.trimmingCharacters(in: .whitespaces),
      mode: mode, chapters: chapters,
      note: "本地分章，不上传文本")
  }

  private static func split(_ text: String, limit: Int) -> [String] {
    var out: [String] = []
    var current = ""
    for paragraph in text.components(separatedBy: "\n") {
      if current.count + paragraph.count > limit, !current.trimmingCharacters(in: .whitespaces).isEmpty {
        out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        current = ""
      }
      if paragraph.count > limit {
        var rest = paragraph
        while rest.count > limit {
          let cut = rest.index(rest.startIndex, offsetBy: limit)
          out.append(String(rest[..<cut]))
          rest = String(rest[cut...])
        }
        current += (current.isEmpty ? "" : "\n") + rest
        continue
      }
      current += (current.isEmpty ? "" : "\n") + paragraph
    }
    if !current.trimmingCharacters(in: .whitespaces).isEmpty {
      out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return out.isEmpty ? [text] : out
  }

  private static func drama(_ text: String) -> [SpeechSegment] {
    var out: [SpeechSegment] = []
    for raw in text.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      var speaker = ""
      var body = line
      for separator in [":", "："] {
        if let range = line.range(of: separator) {
          let head = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
          let rest = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
          if !head.isEmpty, head.count <= 12, !rest.isEmpty,
            !head.contains("，"), !head.contains("。"), !head.contains(" ")
          {
            speaker = head
            body = rest
            break
          }
        }
      }
      if var last = out.last, last.speaker == speaker {
        last.text += "\n" + body
        out[out.count - 1] = last
      } else {
        out.append(SpeechSegment(speaker: speaker, text: body))
      }
    }
    return out.isEmpty ? [SpeechSegment(speaker: "", text: text)] : out
  }
}

enum SpeechPlanStore {
  static func directory(_ root: URL) -> URL {
    root.appendingPathComponent("Speech", isDirectory: true)
  }
  static func load(_ root: URL) -> [SpeechPlan] {
    let file = directory(root).appendingPathComponent("plans.json")
    guard let data = try? Data(contentsOf: file) else { return [] }
    return (try? JSONDecoder().decode([SpeechPlan].self, from: data)) ?? []
  }
  static func save(_ plans: [SpeechPlan], root: URL) {
    let dir = directory(root)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(Array(plans.suffix(50))) {
      try? data.write(to: dir.appendingPathComponent("plans.json"), options: .atomic)
    }
  }
}

/// 用系统语音直接朗读章节；不做离线音频文件导出，
/// 但保留分章、多角色语音、暂停/继续与章节切换。
@MainActor final class SpeechNarrator: NSObject, ObservableObject {
  @Published private(set) var speaking = false
  @Published private(set) var paused = false
  @Published private(set) var chapterIndex = 0
  @Published private(set) var chapterTitle = ""
  @Published private(set) var totalChapters = 0
  @Published private(set) var progress: Double = 0
  @Published private(set) var finished = false
  @Published private(set) var title = ""

  private let synth = AVSpeechSynthesizer()
  private var plan: SpeechPlan?
  private var queue: [(chapter: Int, utterance: AVSpeechUtterance, length: Int)] = []
  private var cursor = 0
  private var generation = 0

  override init() {
    super.init()
    synth.delegate = self
  }

  @discardableResult
  func play(_ plan: SpeechPlan, from chapter: Int = 0) -> Bool {
    stop()
    guard !plan.chapters.isEmpty else { return false }
    self.plan = plan
    title = plan.title
    totalChapters = plan.chapters.count
    configureSession()
    let voices = Self.voiceMap(plan)
    queue = []
    for (index, item) in plan.chapters.enumerated() where index >= chapter {
      for segment in item.segments {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voices.voice(for: segment.speaker)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
        utterance.pitchMultiplier = voices.pitch(for: segment.speaker)
        utterance.preUtteranceDelay = 0.08
        queue.append((index, utterance, text.count))
      }
    }
    guard !queue.isEmpty else { return false }
    cursor = 0
    generation += 1
    speaking = true
    paused = false
    finished = false
    chapterIndex = chapter
    chapterTitle = plan.chapters[safe: chapter]?.title ?? ""
    progress = 0
    synth.speak(queue[0].utterance)
    return true
  }

  func toggle() {
    if paused { resume() } else { pause() }
  }

  func pause() {
    guard speaking, !paused else { return }
    if synth.isSpeaking {
      synth.pauseSpeaking(at: .immediate)
      paused = true
    }
  }

  func resume() {
    guard paused else { return }
    if synth.isPaused {
      synth.continueSpeaking()
      paused = false
    }
  }

  func stop() {
    generation += 1
    synth.stopSpeaking(at: .immediate)
    speaking = false
    paused = false
    progress = 0
  }

  private func configureSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    try? session.setActive(true)
  }

  fileprivate func advance(_ utterance: AVSpeechUtterance) {
    guard speaking, !paused, let current = queue[safe: cursor], current.utterance === utterance
    else { return }
    cursor += 1
    if cursor >= queue.count {
      speaking = false
      finished = true
      progress = 1
      return
    }
    let next = queue[cursor]
    chapterIndex = next.chapter
    chapterTitle = plan?.chapters[safe: next.chapter]?.title ?? ""
    progress = Double(cursor) / Double(max(1, queue.count))
    synth.speak(next.utterance)
  }

  fileprivate func updateRange(_ range: NSRange) {
    guard let current = queue[safe: cursor], current.length > 0 else { return }
    let fraction = min(1, Double(range.location + range.length) / Double(current.length))
    progress = min(1, (Double(cursor) + fraction) / Double(max(1, queue.count)))
  }

  private struct VoiceMap {
    var voices: [String: AVSpeechSynthesisVoice] = [:]
    var pitches: [String: Float] = [:]
    var fallback: AVSpeechSynthesisVoice?

    func voice(for speaker: String) -> AVSpeechSynthesisVoice? {
      speaker.isEmpty ? fallback : (voices[speaker] ?? fallback)
    }
    func pitch(for speaker: String) -> Float {
      pitches[speaker] ?? 1
    }
  }

  private static func voiceMap(_ plan: SpeechPlan) -> VoiceMap {
    let all = AVSpeechSynthesisVoice.speechVoices().filter {
      $0.language.hasPrefix("zh") || $0.language.hasPrefix("en")
    }
    let chinese = all.filter { $0.language.hasPrefix("zh") }
    let narrator =
      chinese.first(where: { $0.language == "zh-CN" })
      ?? AVSpeechSynthesisVoice(language: "zh-CN")
      ?? all.first
    var map = VoiceMap(fallback: narrator)
    let speakers = Set(
      plan.chapters.flatMap { $0.segments.map(\.speaker) }.filter { !$0.isEmpty }
    ).sorted()
    let pool = chinese.isEmpty ? all : chinese
    for (index, speaker) in speakers.enumerated() {
      if !pool.isEmpty {
        map.voices[speaker] = pool[index % pool.count]
      }
      map.pitches[speaker] = 0.88 + Float(index % 4) * 0.08
    }
    return map
  }
}

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

extension SpeechNarrator: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.advance(utterance) }
  }
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
    utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.updateRange(characterRange) }
  }
}

struct NewsItem: Codable, Identifiable, Equatable {
  var id = UUID()
  var title: String
  var source: String
  var text: String
  var url: String?
  var createdAt = Date()
}

enum NewsStore {
  static func file(_ root: URL) -> URL {
    root.appendingPathComponent("News", isDirectory: true).appendingPathComponent("news.json")
  }
  static func load(_ root: URL) -> [NewsItem] {
    guard let data = try? Data(contentsOf: file(root)) else { return [] }
    return (try? JSONDecoder().decode([NewsItem].self, from: data)) ?? []
  }
  static func save(_ items: [NewsItem], root: URL) {
    let url = file(root)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(Array(items.prefix(300))) {
      try? data.write(to: url, options: .atomic)
    }
  }
}

enum NewsService {
  static func fetch(_ text: String) async throws -> NewsItem {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      ["http", "https"].contains(url.scheme ?? ""), url.host != nil
    else { throw AppFailure("只支持公开的 http(s) 链接") }
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue("Awake/0.8 iOS", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw AppFailure("链接返回了错误状态")
    }
    guard data.count <= 3 * 1024 * 1024 else { throw AppFailure("页面超过 3 MB") }
    let raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
    if type.contains("html") || raw.contains("<html") {
      let title = firstMatch(raw, pattern: "(?is)<title[^>]*>(.*?)</title>") ?? "网页文章"
      let body = stripHTML(raw)
      guard body.count >= 20 else { throw AppFailure("没有从页面读到正文") }
      return NewsItem(
        title: String(decode(title).prefix(120)), source: "网页",
        text: String(body.prefix(20000)), url: url.absoluteString)
    }
    return NewsItem(title: url.lastPathComponent.isEmpty ? "链接内容" : url.lastPathComponent, source: "链接", text: String(raw.prefix(20000)), url: url.absoluteString)
  }

  static func parseEml(_ text: String, fallback: String) -> NewsItem {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let parts = normalized.components(separatedBy: "\n\n")
    let head = parts.first ?? ""
    var subject = fallback
    var encoding = ""
    for line in head.components(separatedBy: "\n") {
      let lower = line.lowercased()
      if lower.hasPrefix("subject:") {
        subject = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
      } else if lower.hasPrefix("content-transfer-encoding:") {
        encoding = String(line.dropFirst(26)).trimmingCharacters(in: .whitespaces).lowercased()
      }
    }
    var body = parts.dropFirst().joined(separator: "\n\n")
    if encoding == "base64" {
      let clean = body.components(separatedBy: .whitespacesAndNewlines).joined()
      if let data = Data(base64Encoded: clean), let decoded = String(data: data, encoding: .utf8) {
        body = decoded
      }
    }
    body = stripHTML(body)
    return NewsItem(title: subject.isEmpty ? "邮件" : subject, source: "邮件", text: String(body.prefix(20000)))
  }

  static func plan(_ items: [NewsItem], title: String) -> SpeechPlan {
    let heading = title.isEmpty ? "AI 新闻播报" : title
    var segments: [SpeechSegment] = []
    for (index, item) in items.prefix(12).enumerated() {
      segments.append(SpeechSegment(speaker: "", text: "第 \(index + 1) 条，\(item.title)。\(summary(item.text))"))
    }
    if segments.isEmpty { segments = [SpeechSegment(speaker: "", text: "目前没有可播报的内容。")] }
    return SpeechPlan(
      title: heading, author: "", mode: "news",
      chapters: [SpeechChapter(title: heading, segments: segments)],
      note: "本地摘要，不上传内容")
  }

  static func summary(_ text: String) -> String {
    var out = ""
    for character in text {
      out.append(character)
      if ["。", "！", "？", ".", "!", "?"].contains(character), out.count >= 40 { break }
      if out.count >= 220 { break }
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func stripHTML(_ html: String) -> String {
    var text = html
    for pattern in ["(?is)<script.*?</script>", "(?is)<style.*?</style>"] {
      text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    text = text.replacingOccurrences(
      of: "(?i)<br\\s*/?>|</p>|</div>|</li>|</h[1-6]>",
      with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
    text = decode(text)
    let lines = text.components(separatedBy: .newlines)
      .map { $0.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return lines.joined(separator: "\n")
  }

  static func decode(_ text: String) -> String {
    var out = text
    let map = [
      "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
      "&apos;": "'", "&nbsp;": " ",
    ]
    for (key, value) in map { out = out.replacingOccurrences(of: key, with: value) }
    if let regex = try? NSRegularExpression(pattern: "&#([0-9]{1,6});") {
      let ns = out as NSString
      let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
      var result = ""
      var last = 0
      for match in matches {
        result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
        let digits = ns.substring(with: match.range(at: 1))
        if let value = UInt32(digits), let scalar = UnicodeScalar(value) {
          result += String(scalar)
        } else {
          result += ns.substring(with: match.range)
        }
        last = match.range.location + match.range.length
      }
      result += ns.substring(from: last)
      out = result
    }
    return out
  }

  private static func firstMatch(_ text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }
}
