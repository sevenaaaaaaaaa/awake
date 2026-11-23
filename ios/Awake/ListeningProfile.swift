import SwiftUI

/// R4：跨设备听感接力。把「校准先验 + 每首歌的曲线」打包成一份 JSON，
/// 用 AirDrop / iCloud / 文件 App 传到另一台设备，在那边导入即可继续。
///
/// 只包含曲线与先验，不含音频、来源凭据、播放历史。
struct ListeningProfile: Codable {
  var version: Int = 1
  var device: String
  var createdAt: Date
  var prior: EarPrior?
  var curves: [String: SongCurve]
  var titles: [String: String]

  @MainActor
  static func build(store: MobileStore) -> ListeningProfile {
    let curves = store.state.songCurves ?? [:]
    var titles: [String: String] = [:]
    for song in store.state.songs where curves[song.id] != nil {
      titles[song.id] = song.title
    }
    return ListeningProfile(
      device: ProcessInfo.processInfo.hostName,
      createdAt: Date(),
      prior: store.state.earPrior,
      curves: curves,
      titles: titles)
  }
}

/// 导出页：写文件 + 系统分享，不经过任何服务器。
struct ListeningProfileExportView: View {
  @EnvironmentObject var store: MobileStore
  @Environment(\.dismiss) private var dismiss
  @State private var shareFile: SharedFile?
  @State private var note = ""

  private var profile: ListeningProfile { ListeningProfile.build(store: store) }

  var body: some View {
    Form {
      Section("这份档案包含") {
        Text("校准先验：\(profile.prior?.summary ?? "未校准")")
        Text("每首歌的曲线：\(profile.curves.count) 首")
        Text("不含音频、来源凭据、播放历史。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        Button("生成并分享档案") { export() }
          .disabled(profile.curves.isEmpty && profile.prior == nil)
        if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        Text("在另一台设备上导入同名字的 .json，就能沿用同样的先验与按歌曲线。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .appSurface()
    .navigationTitle("导出听感档案")
    .sheet(item: $shareFile) { file in ShareView(url: file.url) }
  }

  private func export() {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(profile)
      guard data.count <= 2 * 1024 * 1024 else { throw AppFailure("档案过大（超过 2 MB）") }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("awake-listening-profile.json")
      try data.write(to: url, options: .atomic)
      shareFile = SharedFile(url: url)
      note = "已生成，大小 \(data.count / 1024) KB。"
    } catch { note = error.localizedDescription }
  }
}
