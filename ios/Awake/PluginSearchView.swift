import SwiftUI

/// 单个插件的搜索页：搜到的东西按 MusicFree 契约落成曲库曲目，
/// locator 存原始 musicItem JSON —— S3 解析直链时要用它。
struct PluginSearchView: View {
  let plugin: InstalledPlugin
  @EnvironmentObject var store: MobileStore
  @State private var query = ""
  @State private var hits: [PluginHit] = []
  @State private var busy = false
  @State private var note = ""

  var body: some View {
    Form {
      Section("搜索") {
        TextField("歌名 / 艺人", text: $query)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .accessibilityIdentifier("pluginQuery")
        Button("搜索") { Task { await run() } }
          .disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
          .accessibilityIdentifier("pluginSearch")
        if busy { ProgressView() }
        if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
      }
      Section("结果") {
        if hits.isEmpty {
          Text("还没有结果。").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(hits) { hit in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text(hit.title).font(.subheadline)
              Text(
                [hit.artist, hit.album].filter { !$0.isEmpty }.joined(separator: " · ")
              ).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("入库") { save(hit) }
          }
        }
        if !hits.isEmpty {
          Text("入库只保存曲目信息（按原始条目去重），音频要等 S3 接上直链解析再播放。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .appSurface()
    .glassRows()
    .navigationTitle(plugin.name)
  }

  @MainActor
  private func run() async {
    busy = true
    note = ""
    hits = []
    defer { busy = false }
    do {
      guard let code = PluginLibrary.shared.code(for: plugin.id) else {
        throw AppFailure("插件文件不见了，请重新导入")
      }
      let result = try await PluginSandbox.shared.search(
        code: code, query: query.trimmingCharacters(in: .whitespaces), page: 1)
      hits = result
      note = result.isEmpty ? "插件没有返回结果" : "拿到 \(result.count) 条"
    } catch {
      note = "搜索失败：" + error.localizedDescription
    }
  }

  @MainActor
  private func save(_ hit: PluginHit) {
    if store.state.songs.contains(where: { $0.sourceID == plugin.id && $0.locator == hit.rawJSON }) {
      note = "《\(hit.title)》已经在曲库里"
      return
    }
    var song = Song(title: hit.title)
    song.artist = hit.artist.isEmpty ? "未知艺人" : hit.artist
    song.album = hit.album
    song.duration = hit.duration
    song.sourceID = plugin.id
    song.locator = hit.rawJSON
    song.origin = "plugin"
    song.addedAt = Date()
    store.state.songs.append(song)
    store.save()
    note = "已入库《\(hit.title)》"
  }
}
