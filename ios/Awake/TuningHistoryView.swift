import SwiftUI

/// R3：调音审计。每次 agent/本地规则改动都留一条，可回滚到任一版本的前后状态。
struct TuningHistoryView: View {
  var songID: String? = nil
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @Environment(\.dismiss) private var dismiss
  @State private var note = ""

  private var records: [TuningRecord] { store.tuningHistory(for: songID) }

  var body: some View {
    NavigationStack {
      Form {
        if records.isEmpty {
          Section {
            Text("还没有调音记录。用「说一句话调音」改过之后会出现在这里。")
              .font(.caption).foregroundStyle(.secondary)
          }
        } else {
          Section("共 \(records.count) 次") {
            ForEach(records) { record in
              VStack(alignment: .leading, spacing: 4) {
                Text("\(record.songTitle) · \(record.source)").font(.subheadline)
                if !record.request.isEmpty {
                  Text("「\(record.request)」").font(.caption)
                }
                Text(record.lines.joined(separator: " · "))
                  .font(.caption2).foregroundStyle(.secondary)
                Text(
                  record.createdAt.formatted(date: .abbreviated, time: .shortened)
                    + (record.reverted ? " · 已回滚" : "")
                ).font(.caption2).foregroundStyle(.tertiary)
                HStack(spacing: 14) {
                  Button("回到改动前") { revert(record, toBefore: true) }
                  Button("恢复到改动后") { revert(record, toBefore: false) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
              }
            }
          }
        }
        if !note.isEmpty { Section { Text(note).font(.caption) } }
        Section {
          Text("回滚只改当前播放的曲线，并把这条例记录标成「已回滚」；不会删除记录。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .appSurface()
      .navigationTitle(songID == nil ? "调音历史" : "这首歌的调音历史")
      .toolbar { Button("完成") { dismiss() } }
    }
  }

  @MainActor
  private func revert(_ record: TuningRecord, toBefore: Bool) {
    store.revertTuning(record, toBefore: toBefore, player: player)
    note = toBefore ? "已回到这次改动之前。" : "已恢复到这次改动之后。"
  }
}
