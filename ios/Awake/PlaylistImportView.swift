import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct PlaylistImportView: View {
  @EnvironmentObject var store: MobileStore
  @Environment(\.dismiss) private var dismiss

  enum Source: String, CaseIterable, Identifiable {
    case netease, qq, youtube, spotify, apple, cue, file, text
    var id: String { rawValue }
    var title: String {
      switch self {
      case .netease: return "网易云音乐"
      case .qq: return "QQ 音乐"
      case .youtube: return "YouTube Music"
      case .spotify: return "Spotify"
      case .apple: return "Apple Music"
      case .cue: return "CUE 整轨"
      case .file: return "导出文件"
      case .text: return "粘贴文本"
      }
    }
    var hint: String {
      switch self {
      case .netease: return "公开歌单链接或 ID"
      case .qq: return "公开歌单链接或 ID"
      case .youtube: return "含 list= 的播放列表链接"
      case .spotify: return "open.spotify.com/playlist/… 链接"
      case .apple: return "music.apple.com 歌单链接"
      case .cue: return "选择 .cue 文件（整轨需已在曲库）"
      case .file: return "M3U / PLS / CSV / JSON / TXT"
      case .text: return "每行 “艺人 - 歌名”"
      }
    }
  }

  @State private var source = Source.netease
  @State private var input = ""
  @State private var pasted = ""
  @State private var busy = false
  @State private var status = ""
  @State private var imported: ImportedPlaylist?
  @State private var matches: [PlaylistMatch] = []
  @State private var onlyUnmatched = false
  @State private var pickingFile = false
  @State private var pickedCueName = ""
  @State private var suggestion = ""

  private var matched: [PlaylistMatch] { matches.filter { $0.song != nil } }
  private var visible: [PlaylistMatch] {
    onlyUnmatched ? matches.filter { $0.song == nil } : matches
  }

  var body: some View {
    NavigationStack {
      Form {
        sourceSection
        inputSection
        matchSection
        footerSection
      }
      .appSurface()
      .navigationTitle("导入歌单")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("完成") { dismiss() } }
      .sheet(item: manualPickBinding) { pick in
        ManualMatchView(trackID: pick.id) { song in
          assign(song, to: pick.id)
        }
      }
    }
  }

  private var manualPickBinding: Binding<ManualPick?> {
    Binding(
      get: { suggestion.isEmpty ? nil : ManualPick(id: suggestion) },
      set: { if $0 == nil { suggestion = "" } })
  }

  private func assign(_ song: Song, to trackID: String) {
    guard let i = matches.firstIndex(where: { $0.track.id == trackID }) else { return }
    matches[i].song = song
    matches[i].enabled = true
    matches[i].reason = "手动指定"
  }

  @ViewBuilder
  private var sourceSection: some View {
    Section("来源") {
      Picker("平台", selection: $source) {
        ForEach(Source.allCases) { item in
          Text(item.title).tag(item)
        }
      }
      .accessibilityIdentifier("playlistSource")
      Text(source.hint).font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var inputSection: some View {
    Section("输入") {
      inputFields
      if busy { ProgressView().controlSize(.small) }
      if !status.isEmpty { statusText }
    }
  }

  @ViewBuilder
  private var inputFields: some View {
    if source == .text {
      textInput
    } else if source == .cue || source == .file {
      fileInput
    } else {
      linkInput
    }
  }

  private var textInput: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextEditor(text: $pasted)
        .frame(minHeight: 120)
        .font(.callout)
        .accessibilityIdentifier("playlistText")
      Text("每行一首，例如：周杰伦 - 稻香。也支持从其他平台复制后直接粘贴。")
        .font(.caption2).foregroundStyle(.secondary)
    }
  }

  private var linkInput: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("链接或 ID", text: $input)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .keyboardType(.URL)
        .accessibilityIdentifier("playlistInput")
      Button("解析歌单") { Task { await load() } }
        .disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityIdentifier("playlistParse")
    }
  }

  private var pickTypes: [UTType] {
    if source == .cue { return [UTType(filenameExtension: "cue") ?? .plainText] }
    return [.json, .commaSeparatedText, .plainText, UTType(filenameExtension: "m3u") ?? .plainText]
  }

  private var fileInput: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(source == .cue ? "选择 .cue 文件" : "选择歌单文件") { pickingFile = true }
        .accessibilityIdentifier("playlistPickFile")
      if !pickedCueName.isEmpty {
        Text("已选择：" + pickedCueName).font(.caption).foregroundStyle(.secondary)
      }
    }
    .fileImporter(isPresented: $pickingFile, allowedContentTypes: pickTypes) { result in
      handlePickedFile(result)
    }
  }

  private func handlePickedFile(_ result: Result<URL, Error>) {
    do {
      let url = try result.get()
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let data = try Data(contentsOf: url)
      let parsed = try PlaylistParser.detect(fileName: url.lastPathComponent, data: data)
      pickedCueName = url.lastPathComponent
      imported = parsed
      suggestions(for: parsed)
      Task { await match() }
    } catch { status = error.localizedDescription }
  }

  private var statusColor: Color {
    status.contains("失败") || status.contains("没有") ? Color.red : Color.secondary
  }

  private var statusText: some View {
    Text(status).font(.caption).foregroundStyle(statusColor)
      .accessibilityIdentifier("playlistStatus")
  }

  private var footerSection: some View {
    Section {
      Text("只导入歌单元数据并匹配你自己的音频；不会下载或播放平台版权音乐。平台页面改版、地区限制或未登录时可能只能读取部分曲目，此时可改用“粘贴文本”或导出文件。")
        .font(.caption2).foregroundStyle(.secondary)
      Text("CUE 需要整轨音频已经在曲库中；APE 需要先转成 FLAC / ALAC 才能播放。")
        .font(.caption2).foregroundStyle(.secondary)
    }
  }
  private var selectedCount: Int { matches.filter { $0.enabled }.count }
  private var pendingCount: Int { matches.filter { $0.enabled && $0.song == nil }.count }

  @ViewBuilder
  private var matchSection: some View {
    if let imported {
      Section("匹配到本地曲库") {
        Text(imported.name + " · " + imported.source).font(.subheadline.weight(.semibold))
        Text(matchSummary).font(.caption).foregroundStyle(.secondary)
        if !imported.note.isEmpty {
          Text(imported.note).font(.caption2).foregroundStyle(.secondary)
        }
        Toggle("只看未匹配", isOn: $onlyUnmatched)
        ForEach(visible) { match in
          matchRow(match)
        }
        Button(
          "创建歌单（" + String(selectedCount) + " 首"
            + (pendingCount > 0 ? "，含 " + String(pendingCount) + " 首待匹配" : "") + "）"
        ) { create() }
          .disabled(selectedCount == 0)
          .accessibilityIdentifier("playlistCreate")
      }
    }
  }

  private var matchSummary: String {
    guard let imported else { return "" }
    let total = imported.tracks.count
    let hit = matched.count
    return "共 " + String(total) + " 首，匹配 " + String(hit) + " 首，未匹配 "
      + String(total - hit) + " 首"
  }

  private func matchRow(_ match: PlaylistMatch) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Button {
        toggle(match)
      } label: {
        Image(systemName: markName(match)).foregroundStyle(markColor(match))
      }.buttonStyle(.plain)
      VStack(alignment: .leading, spacing: 3) {
        Text(match.track.title).font(.subheadline).lineLimit(1)
        Text(subtitle(match)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        if let song = match.song {
          Text("→ " + song.title + " · " + song.artist).font(.caption2)
            .foregroundStyle(.secondary).lineLimit(1)
        } else {
          Text(match.reason).font(.caption2).foregroundStyle(Color.orange)
        }
      }
      Spacer()
      if match.song == nil, source != .cue {
        Button("手动选择") { suggestion = match.track.id }.font(.caption2)
      }
    }
  }

  private func markName(_ match: PlaylistMatch) -> String {
    match.enabled ? "checkmark.circle.fill" : "circle"
  }

  private func markColor(_ match: PlaylistMatch) -> Color {
    match.enabled ? Color(hex: store.state.skin.colors.accent) : Color.secondary
  }

  private func subtitle(_ match: PlaylistMatch) -> String {
    let parts = [match.track.artist, match.track.album].filter { !$0.isEmpty }
    return parts.joined(separator: " · ")
  }

  private func toggle(_ match: PlaylistMatch) {
    guard let i = matches.firstIndex(where: { $0.id == match.id }) else { return }
    matches[i].enabled.toggle()
  }

  private func suggestions(for playlist: ImportedPlaylist) {
    suggestion = ""
    if playlist.source == "CUE" {
      status = "已解析 \(playlist.tracks.count) 个 CUE 音轨"
    } else {
      status = "已解析 \(playlist.tracks.count) 首"
    }
  }

  private func load() async {
    busy = true
    status = ""
    imported = nil
    matches = []
    defer { busy = false }
    do {
      let playlist: ImportedPlaylist
      switch source {
      case .netease: playlist = try await PlaylistFetch.netease(input)
      case .qq: playlist = try await PlaylistFetch.qq(input)
      case .youtube: playlist = try await PlaylistFetch.youtube(input)
      case .spotify: playlist = try await PlaylistFetch.spotify(input)
      case .apple: playlist = try await PlaylistFetch.apple(input)
      case .text:
        let rows = PlaylistParser.text(pasted)
        guard !rows.isEmpty else { throw AppFailure("没有从文本里读到曲目，请检查每行格式") }
        playlist = ImportedPlaylist(name: "粘贴的歌单", source: "文本", tracks: rows)
      case .cue, .file:
        throw AppFailure("请先选择文件")
      }
      imported = playlist
      status = "已解析 \(playlist.tracks.count) 首"
      await match()
    } catch { status = "解析失败：" + error.localizedDescription }
  }

  private func match() async {
    guard let imported else { return }
    if imported.source == "CUE" {
      status = "CUE 曲目会作为整轨的虚拟分轨导入，需要整轨已在曲库"
      matches = []
      return
    }
    matches = PlaylistMatcher.match(imported.tracks, songs: store.state.songs)
  }

  private func create() {
    guard let imported else { return }
    if imported.source == "CUE" {
      importCue(imported)
      return
    }
    let chosen = matches.filter { $0.enabled }
    let ids = chosen.compactMap { $0.song?.id }
    let pending = chosen.filter { $0.song == nil }.map {
      PendingTrack(title: $0.track.title, artist: $0.track.artist, album: $0.track.album)
    }
    guard !ids.isEmpty || !pending.isEmpty else {
      status = "没有可添加的曲目"
      return
    }
    var list = store.state.playlists ?? []
    list.append(
      Playlist(
        name: imported.name, songIDs: ids, note: imported.source,
        pending: pending.isEmpty ? nil : pending))
    store.state.playlists = list
    store.save()
    dismiss()
  }

  private func importCue(_ playlist: ImportedPlaylist) {
    guard !playlist.tracks.isEmpty else { status = "CUE 没有曲目"; return }
    let audioName = ((playlist.tracks.first?.fileName ?? "") as NSString).lastPathComponent
    if audioName.lowercased().hasSuffix(".ape") {
      status = "APE 无法在 iOS 上解码。请先把整轨转成 FLAC / ALAC / WAV，再导入曲库并重新解析 CUE。"
      return
    }
    guard let base = store.state.songs.first(where: {
      ($0.originalFilename as NSString?)?.lastPathComponent.lowercased() == audioName.lowercased()
        || $0.title.lowercased() == (audioName as NSString).deletingPathExtension.lowercased()
    }), let file = base.file else {
      status = "曲库里没有整轨文件 \(audioName)。请先导入该音频，再重新解析 CUE。"
      return
    }
    var fileDuration = base.duration
    if let url = store.localURL(base), let audio = try? AVAudioFile(forReading: url) {
      fileDuration = Double(audio.length) / audio.processingFormat.sampleRate
    }
    guard fileDuration > 0 else {
      status = "无法读取整轨音频时长，请先确认文件可播放"
      return
    }
    var newSongs: [Song] = []
    for (i, track) in playlist.tracks.enumerated() {
      let start = max(0, track.segmentStart ?? 0)
      let end = min(fileDuration, track.segmentEnd ?? fileDuration)
      guard end > start else { continue }
      var song = Song(
        title: track.title, artist: track.artist, album: track.album,
        duration: end - start, sampleRate: base.sampleRate, file: file,
        sourceID: base.sourceID, locator: base.locator + "#cue-\(i)")
      song.segmentStart = start
      song.segmentEnd = end
      song.originalFilename = base.originalFilename
      newSongs.append(song)
    }
    guard !newSongs.isEmpty else {
      status = "CUE 的 INDEX 时间与音频时长不匹配，未创建曲目"
      return
    }
    store.state.songs.append(contentsOf: newSongs)
    var list = store.state.playlists ?? []
    list.append(Playlist(name: playlist.name, songIDs: newSongs.map(\.id), note: "CUE 分轨"))
    store.state.playlists = list
    store.save()
    dismiss()
  }
}

private struct ManualPick: Identifiable {
  let id: String
}

private struct ManualMatchView: View {
  @EnvironmentObject var store: MobileStore
  let trackID: String
  var pick: (Song) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    NavigationStack {
      List(store.state.songs.filter {
        query.isEmpty || ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(query)
      }.prefix(200)) { song in
        Button {
          pick(song)
          dismiss()
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(song.title).font(.subheadline)
            Text(song.artist).font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
      .searchable(text: $query)
      .navigationTitle("选择本地曲目").navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("取消") { dismiss() } }
    }
  }
}

extension UTType {
  static var m3uPlaylistFallback: UTType { UTType(filenameExtension: "m3u") ?? .plainText }
}
