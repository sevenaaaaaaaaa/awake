import SwiftUI

/// V3：说一句话，让 agent（或本地规则）在当前曲线上做可听、可撤销的小改动。
struct TuneSheet: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var busy = false
  @State private var note = ""
  @State private var proposal: TuningProposal?
  @State private var previous: EQSnapshot?
  /// 撤销时连「这首歌的曲线」一起还原，否则音频回去了、记忆还留着。
  @State private var previousCurve: SongCurve?
  @State private var curveSongID: String?

  private var aiReady: Bool {
    !store.state.curatorModel.isEmpty && store.state.curatorURL == store.state.curatorCredentialEndpoint
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("说一句话") {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(SoundTuning.phrases, id: \.self) { phrase in
                Button(phrase) { text = phrase }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
              }
            }.padding(.vertical, 2)
          }
          TextField("例如：人声再靠前一点，低频别那么糊", text: $text, axis: .vertical)
            .lineLimit(1...3)
          Button(aiReady ? "让 agent 调" : "用本地规则调") { Task { await tune() } }
            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if busy { ProgressView() }
          if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        if let proposal {
          Section("\(proposal.source) 的改动") {
            ForEach(proposal.lines, id: \.self) { line in
              Text(line).font(.system(size: 13, design: .monospaced))
            }
            if !proposal.why.isEmpty {
              Text(proposal.why).font(.caption).foregroundStyle(.secondary)
            }
            Button("应用到当前曲线") { apply(proposal) }
            if previous != nil {
              Button("撤销这次改动", role: .destructive) { undo() }
            }
          }
        }
        Section {
          Text(aiReady
            ? "改动只作用于当前曲线，每段不超过 6 dB、最多 6 段；随时可撤销。"
            : "还没配置 AI 模型：这里用固定短语的本地规则，不冒充 agent。配置后同一句话会交给模型。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .appSurface()
      .navigationTitle("一句话调音")
      .toolbar { Button("完成") { dismiss() } }
    }
  }

  @MainActor
  private func tune() async {
    busy = true
    note = ""
    proposal = nil
    defer { busy = false }
    let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let current = player.currentSnapshot.gains
    if aiReady {
      do {
        proposal = try await SoundTuning.agent(request, from: current, store: store)
        return
      } catch {
        note = "agent 没成功（\(error.localizedDescription)），先按本地规则给一版。"
      }
    }
    if let local = SoundTuning.local(request, from: current) {
      proposal = local
    } else if note.isEmpty {
      note = "这句话没听懂。试试短语：人声太靠后 / 低频糊 / 想更亮 / 太吵。"
    }
  }

  @MainActor
  private func apply(_ proposal: TuningProposal) {
    let snapshot = player.currentSnapshot
    previous = snapshot
    let ok = player.setEQ(
      proposal.gains, apo: snapshot.apo,
      origin: proposal.source == "AI" ? .ai : .manual,
      profile: snapshot.profile,
      source: proposal.source == "AI" ? "一句话调音：" + text : "本地规则：" + text,
      announce: false)
    guard ok else {
      note = "应用失败，曲线保持原样。"
      return
    }
    // V4：把这版曲线记到当前这首歌上，切歌回来还在。
    if let song = player.song {
      curveSongID = song.id
      previousCurve = store.songCurve(song.id)
      store.rememberCurve(
        player.currentSnapshot, for: song.id,
        label: proposal.source == "AI" ? "一句话调音" : "本地规则",
        basis: "耳机：\(player.route.name) · \(proposal.source) · \(text)")
      note = "已应用并记到这首歌，切歌回来还在。"
    } else {
      note = "已应用，松手听一下差别。"
    }
  }

  @MainActor
  private func undo() {
    guard let snapshot = previous else { return }
    _ = player.setEQ(
      snapshot.gains, apo: snapshot.apo, origin: snapshot.origin,
      profile: snapshot.profile, source: snapshot.source, announce: false)
    if let songID = curveSongID {
      if let saved = previousCurve {
        var map = store.state.songCurves ?? [:]
        map[songID] = saved
        store.state.songCurves = map
        store.save()
      } else {
        store.forgetCurve(songID)
      }
    }
    previous = nil
    previousCurve = nil
    curveSongID = nil
    proposal = nil
    note = "已撤销，回到调音前的曲线与记忆。"
  }
}
