import SwiftUI
import UniformTypeIdentifiers

struct MediaInfoView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var draft: Song
  @State private var info: MediaInfo
  @State private var candidates: [MediaCandidate] = []
  @State private var busy = false
  @State private var importing = false
  @State private var importKind = "cover"
  @State private var error = ""
  @State private var notice = ""
  init(song: Song) {
    _draft = State(initialValue: song)
    _info = State(initialValue: song.mediaInfo ?? MediaInfo(original_title: song.title, original_artist: song.artist, original_album: song.album, original_artwork: song.artwork, original_comment: song.comment ?? "", original_lyrics: song.lyrics ?? ""))
  }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack { Spacer(); Cover(title: draft.title, artwork: ["auto", "original"].contains(info.cover_style) ? draft.artwork : nil, style: info.cover_style, size: 200); Spacer() }
          Picker("封面风格", selection: $info.cover_style) {
            Text("使用图片封面").tag("original"); Text("自动设计配图").tag("auto")
            Text("夜色 · Nocturne").tag("nocturne"); Text("山林 · Forest").tag("forest")
            Text("琥珀 · Amber").tag("amber"); Text("暮色 · Rose").tag("rose")
          }
          Button("导入封面图片") { importKind = "cover"; importing = true }
          Text("没有图片时按标题生成设计配图。设计配图不代表原始专辑封面。").font(.caption).foregroundStyle(.secondary)
        }
        Section("曲目资料") {
          TextField("显示名称", text: $draft.title).accessibilityIdentifier("mediaTitle")
          TextField("艺人", text: $draft.artist)
          TextField("专辑", text: $draft.album)
          Button("整理文件名与显示信息") {
            let name = MediaNaming.suggest(filename: draft.originalFilename ?? draft.locator, title: draft.title, artist: draft.artist)
            draft.title = name.title; draft.artist = name.artist; info.suggested_filename = name.filename
            notice = "名称建议已预览，原文件路径保留。"
          }.accessibilityIdentifier("tidyMedia")
          TextField("文件名建议（用于整理或导出）", text: $info.suggested_filename)
          TextField("来源说明，例如个人录音或现场采集", text: $info.source_note, axis: .vertical)
          TextField("文件注释 / 个人备注", text: Binding(get: { draft.comment ?? "" }, set: { draft.comment = $0 }), axis: .vertical).lineLimit(2...6)
        }
        Section("在线匹配 · 预览后保存") {
          Button("查找封面、歌词与乐评") { Task { await search() } }.disabled(draft.title.isEmpty)
          Text("主动查询会发送你填写的曲名和艺人；加载候选还会发送专辑与时长。不上传音频、录音内容、路径或来源凭据。").font(.caption).foregroundStyle(.secondary)
          ForEach(candidates) { candidate in
            VStack(alignment: .leading, spacing: 6) {
              Text(candidate.title).font(.headline)
              Text(candidate.artist + " · " + candidate.album).font(.caption)
              Text((candidate.id.hasPrefix("lrclib:") ? "歌词库候选" : "匹配分 \(candidate.score)") + " · \(Int(candidate.duration)) 秒 · 当前 \(Int(draft.duration)) 秒").font(.caption).foregroundStyle(.secondary)
              Button("预览此候选资料") { Task { await choose(candidate) } }
            }
          }
        }
        Section("歌词") {
          Button("导入 LRC / TXT 歌词") { importKind = "lyrics"; importing = true }
          TextEditor(text: Binding(get: { draft.lyrics ?? "" }, set: { draft.lyrics = $0 })).frame(minHeight: 150).accessibilityLabel("歌词内容")
          Text("支持同步歌词和纯文本。录音或纯音乐可留空。").font(.caption).foregroundStyle(.secondary)
        }
        Section("听众乐评") {
          Button("导入带署名和来源的评论 JSON") { importKind = "reviews"; importing = true }
          if info.reviews.isEmpty { Text("没有匹配到听众乐评；不会生成或虚构评论。").font(.caption).foregroundStyle(.secondary) }
          ForEach(info.reviews) { review in
            VStack(alignment: .leading, spacing: 8) {
              Text((review.scope == "release_group" ? "专辑乐评" : review.scope == "recording" ? "单曲乐评" : "导入评论") + " · " + review.source).font(.caption).foregroundStyle(.secondary)
              Text(review.author).font(.headline)
              Text(review.text).textSelection(.enabled)
              Text(review.license).font(.caption)
              if let url = safeURL(review.url) { Link("查看原文", destination: url) }
              if let url = safeURL(review.license_url) { Link("许可说明", destination: url) }
              Button("移除此条", role: .destructive) { info.reviews.removeAll { $0.id == review.id } }
            }.padding(.vertical, 8)
          }
        }
        Section("来源与出处") {
          Text("真实来源：" + (store.state.sources.first { $0.id == draft.sourceID }?.name ?? "本地音频"))
          Text("原始文件名：" + (draft.originalFilename ?? draft.file ?? draft.locator)).font(.caption)
          if !draft.locator.isEmpty { Text(draft.locator).font(.caption).textSelection(.enabled) }
          ForEach(info.credits, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
        }
        Section {
          if !error.isEmpty { Text(error).foregroundStyle(.red).accessibilityIdentifier("mediaError") }
          if !notice.isEmpty { Text(notice).font(.caption) }
          Button("保存到曲库") { save() }.disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("saveMedia")
          Button("恢复原始信息", role: .destructive) {
            do { try store.resetMedia(draft.id); if let song = store.state.songs.first(where: { $0.id == draft.id }) { player.refreshMetadata(song) }; dismiss() }
            catch { self.error = error.localizedDescription }
          }.disabled(store.state.songs.first { $0.id == draft.id }?.mediaInfo == nil)
        }
      }.disabled(busy).appSurface().navigationTitle("整理这份声音").navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("完成") { dismiss() }.disabled(busy) }
      .overlay { if busy { ProgressView("正在读取资料…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
      .fileImporter(isPresented: $importing, allowedContentTypes: importKind == "cover" ? [.image] : importKind == "reviews" ? [.json] : [.plainText, .text, .data]) { result in
        do {
          let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
          defer { if access { url.stopAccessingSecurityScopedResource() } }
          let limit = importKind == "cover" ? 8 * 1024 * 1024 : 512 * 1024
          guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= limit else { throw AppFailure("资料文件超过大小限制") }
          let data = try Data(contentsOf: url)
          switch importKind {
          case "cover": draft.artwork = try MediaArt.persist(data, directory: store.artworkDirectory); info.cover_style = "original"
          case "reviews":
            let reviews = try JSONDecoder().decode([MediaReview].self, from: data)
            guard reviews.count <= 50, reviews.allSatisfy({ !$0.author.isEmpty && !$0.source.isEmpty && !$0.license.isEmpty && !$0.url.isEmpty }) else { throw AppFailure("评论必须包含作者、来源、链接和许可，最多 50 条") }
            info.reviews = reviews
          default: guard let text = String(data: data, encoding: .utf8) else { throw AppFailure("歌词需要为 UTF-8 编码") }; draft.lyrics = text
          }
          notice = "本地资料已读取，保存后生效。"; error = ""
        } catch { self.error = error.localizedDescription }
      }
    }
  }
  private func safeURL(_ text: String) -> URL? { guard let url = URL(string: text), ["https", "http"].contains(url.scheme ?? "") else { return nil }; return url }
  private func search() async {
    busy = true; error = ""; notice = ""; defer { busy = false }
    do { candidates = try await MediaLookup.search(title: draft.title, artist: draft.artist == "未知艺人" ? "" : draft.artist); if candidates.isEmpty { notice = "没有可靠候选，可以手动编辑并使用设计配图。" } }
    catch { self.error = error.localizedDescription }
  }
  private func choose(_ candidate: MediaCandidate) async {
    busy = true; error = ""; defer { busy = false }
    let result = await MediaLookup.resources(candidate, directory: store.artworkDirectory)
    draft.title = candidate.title; draft.artist = candidate.artist; draft.album = candidate.album
    if let artwork = result.artwork { draft.artwork = artwork; info.cover_style = "original" }
    if !result.lyrics.isEmpty { draft.lyrics = result.lyrics }
    if !candidate.id.hasPrefix("lrclib:") { info.reviews = result.reviews }; info.credits = Array(Set(info.credits + result.credits)).sorted()
    let mismatch = candidate.duration > 0 && draft.duration > 0 && abs(candidate.duration - draft.duration) > 5 ? "候选时长不同，可能是现场版、节选或不同版本，请核对。" : ""
    notice = "候选资料已放入预览，保存后生效。" + mismatch + result.warnings.joined(separator: "；")
  }
  private func save() {
    do {
      var proposed = draft; proposed.mediaInfo = info
      if !["auto", "original"].contains(info.cover_style) { proposed.artwork = nil }
      try store.saveMedia(proposed); player.refreshMetadata(proposed); dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

struct LyricLine: Identifiable { var time: Double; var text: String; var id: Int }
enum MediaLyrics {
  static func parse(_ text: String) -> [LyricLine] {
    guard let regex = try? NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]") else { return [] }
    var rows: [LyricLine] = []
    var offset = 0.0
    for line in text.components(separatedBy: .newlines) where line.hasPrefix("[offset:") {
      offset = (Double(line.replacingOccurrences(of: "[offset:", with: "").replacingOccurrences(of: "]", with: "")) ?? 0) / 1000
    }
    for line in text.components(separatedBy: .newlines) {
      let ns = line as NSString
      let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
      guard let last = matches.last else { continue }
      let content = ns.substring(from: last.range.upperBound).trimmingCharacters(in: .whitespaces)
      guard !content.isEmpty else { continue }
      for match in matches {
        guard let minutes = Double(ns.substring(with: match.range(at: 1))), let seconds = Double(ns.substring(with: match.range(at: 2))), seconds < 60 else { continue }
        rows.append(.init(time: max(0, minutes * 60 + seconds + offset), text: content, id: rows.count))
      }
    }
    return rows.sorted { $0.time < $1.time }
  }
}
struct MediaLyricsView: View {
  var text: String
  @EnvironmentObject var player: MobilePlayer
  var rows: [LyricLine] { MediaLyrics.parse(text) }
  var current: Int? { rows.last { $0.time <= player.position }?.id }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if rows.isEmpty { Text(text).lineSpacing(10).textSelection(.enabled) }
      else { ForEach(rows) { line in Button { player.seek(line.time) } label: { Text(line.text).fontWeight(current == line.id ? .semibold : .regular).foregroundStyle(current == line.id ? .primary : .secondary).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain) } }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
