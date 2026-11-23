import SwiftUI

/// 「每首歌的曲线」管理面：看清自己改过哪些歌，逐条试听、重命名来源、删除。
///
/// 之前只会往里写，不给人看——自动适配一旦开启，用户需要能审计「它替我记了什么」。
struct SongCurveListView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @State private var renaming: String?
  @State private var renameText = ""
  @State private var removing: String?
  @State private var note = ""

  private struct Row: Identifiable {
    var id: String
    var title: String
    var artist: String
    var curve: SongCurve
    var summary: String
  }

  private var rows: [Row] {
    let byID = Dictionary(uniqueKeysWithValues: store.state.songs.map { ($0.id, $0) })
    let entries = store.state.songCurves ?? [:]
    return entries.compactMap { id, curve -> Row? in
      guard curve.gains.count == 31 else { return nil }
      let song = byID[id]
      let snapshot = EQSnapshot(
        gains: curve.gains, apo: curve.apo, origin: curve.origin,
        profile: "", source: curve.source)
      let summary = SoundSummaryBuilder.make(snapshot: snapshot, hasSong: true)
      return Row(
        id: id,
        title: song?.title ?? "曲目已不在曲库",
        artist: song?.artist ?? "",
        curve: curve,
        summary: summary.headline)
    }
    .sorted { $0.curve.updatedAt > $1.curve.updatedAt }
  }

  var body: some View {
    Form {
      if rows.isEmpty {
        Section {
          Text("还没有任何一首歌被记过曲线。在播放页调音或点「记住这首歌」后会出现在这里。")
            .font(.caption).foregroundStyle(.secondary)
        }
      } else {
        Section("共 \(rows.count) 首") {
          ForEach(rows) { row in
            VStack(alignment: .leading, spacing: 6) {
              Text(row.title).font(.headline)
              Text(row.artist).font(.caption).foregroundStyle(.secondary)
              Text(row.summary).font(.caption2).foregroundStyle(.secondary)
              Text("\(row.curve.source.isEmpty ? "未标注来源" : row.curve.source) · \(row.curve.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2).foregroundStyle(.tertiary)
              HStack(spacing: 14) {
                Button("套用到当前播放") { apply(row) }
                Button("重命名来源") {
                  renaming = row.id
                  renameText = row.curve.source
                }
                Button("删除", role: .destructive) { removing = row.id }
              }
              .font(.caption)
              .buttonStyle(.borderless)
            }
          }
        }
      }
      if !note.isEmpty {
        Section { Text(note).font(.caption).foregroundStyle(.secondary) }
      }
      Section {
        Text("套用只改当前播放的曲线，不会覆盖其它歌的记忆；删除后这首歌回到链路上的曲线。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .appSurface()
    .navigationTitle("每首歌的曲线")
    .alert(
      "重命名来源",
      isPresented: Binding(
        get: { renaming != nil },
        set: { if !$0 { renaming = nil } })
    ) {
      TextField("例如：一句话调音 / 手动 / 测量", text: $renameText)
      Button("取消", role: .cancel) { renaming = nil }
      Button("保存") {
        guard let id = renaming else { return }
        var map = store.state.songCurves ?? [:]
        if var curve = map[id] {
          curve.source = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
          map[id] = curve
          store.state.songCurves = map
          store.save()
          note = "来源已改名。"
        }
        renaming = nil
      }
    }
    .alert(
      "删除这首歌的曲线？",
      isPresented: Binding(
        get: { removing != nil },
        set: { if !$0 { removing = nil } })
    ) {
      Button("取消", role: .cancel) { removing = nil }
      Button("删除", role: .destructive) {
        if let id = removing {
          store.forgetCurve(id)
          note = "已删除，这首歌回到链路上的曲线。"
        }
        removing = nil
      }
    } message: {
      Text("只删这条记忆，不动曲目本身。")
    }
  }

  @MainActor
  private func apply(_ row: Row) {
    let ok = player.setEQ(
      row.curve.gains, apo: row.curve.apo, origin: row.curve.origin,
      profile: nil, source: row.curve.source, announce: false)
    note = ok ? "已套用《\(row.title)》的曲线到当前播放。" : "套用失败，曲线保持原样。"
  }
}
