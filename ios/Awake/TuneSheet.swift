import SwiftUI

/// V3 + R3：说一句话，拿到 2–3 条候选曲线，挑一条应用；每次应用都进审计记录，可回滚。
struct TuneSheet: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var busy = false
  @State private var note = ""
  @State private var proposals: [TuningProposal] = []
  @State private var selected = 0
  @State private var previous: EQSnapshot?
  @State private var previousCurve: SongCurve?
  @State private var curveSongID: String?
  @State private var historyOpen = false
  @State private var modeID = TuningModes.balance.id

  private var aiReady: Bool {
    !store.state.curatorModel.isEmpty && store.state.curatorURL == store.state.curatorCredentialEndpoint
  }
  private var current: TuningProposal? {
    proposals.indices.contains(selected) ? proposals[selected] : nil
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("工作模式") {
          ForEach(TuningModes.all) { mode in
            Button {
              modeID = mode.id
            } label: {
              HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(mode.name)
                    .font(.subheadline.weight(mode.id == modeID ? .semibold : .regular))
                    .foregroundStyle(Color(hex: store.state.skin.colors.text))
                  Text(mode.intent)
                    .font(.caption)
                    .foregroundStyle(Color(hex: store.state.skin.colors.muted))
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if mode.id == modeID {
                  Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(hex: store.state.skin.colors.text))
                    .padding(.top, 2)
                }
              }
              .frame(minHeight: 44)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tuningMode_" + mode.id)
            .accessibilityAddTraits(mode.id == modeID ? .isSelected : [])
          }
          Text("模式决定 agent 的取舍和本地规则的默认动作；同一句话在五个模式下结果不同。")
            .font(.caption2).foregroundStyle(.secondary)
        }
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
          Button(aiReady ? "让 agent 给候选" : "用本地规则调") {
            Task { await tune() }
          }
          .accessibilityIdentifier("runTuning")
            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if busy { ProgressView() }
          if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        if !proposals.isEmpty {
          Section("候选（\(proposals.count) 条）") {
            Picker("选一条", selection: $selected) {
              ForEach(proposals.indices, id: \.self) { index in
                Text(proposals.count == 1 ? "结果" : "候选 \(index + 1)").tag(index)
              }
            }
            .pickerStyle(.segmented)
            if let proposal = current {
              ForEach(proposal.lines, id: \.self) { line in
                Text(line).font(.system(size: 13, design: .monospaced))
              }
              if !proposal.why.isEmpty {
                Text(proposal.why).font(.caption).foregroundStyle(.secondary)
              }
              Text("来源：\(proposal.source)").font(.caption2).foregroundStyle(.tertiary)
              Button("应用这条") { apply(proposal) }
            }
            if previous != nil {
              Button("撤销这次改动", role: .destructive) { undo() }
            }
          }
        }
        Section {
          Text(aiReady
            ? "候选之间是取舍，不是对错；每段不超过 6 dB、最多 6 段，随时可撤销，改过的都进历史。"
            : "还没配置 AI 模型：这里按模式的本地规则调，结果会标明「本地规则 · 模式名」，不冒充 agent。配置后会一次给 2–3 条候选。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .appSurface()
      .navigationTitle("一句话调音")
      .toolbar {
        Button("历史") { historyOpen = true }
        Button("完成") { dismiss() }
      }
      .sheet(isPresented: $historyOpen) {
        TuningHistoryView(songID: player.song?.id)
          .environmentObject(store).environmentObject(player)
      }
    }
  }

  @MainActor
  private func tune() async {
    busy = true
    note = ""
    proposals = []
    selected = 0
    defer { busy = false }
    let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentGains = player.currentSnapshot.gains
    let mode = TuningModes.mode(modeID)
    if aiReady {
      do {
        proposals = try await SoundTuning.agentCandidates(
          request, mode: mode, from: currentGains, store: store)
        note = "「\(mode.name)」拿到 \(proposals.count) 条候选，挑一条再应用。"
        return
      } catch {
        note = "agent 没成功（\(error.localizedDescription)），先按本地规则给一版。"
      }
    }
    if let local = SoundTuning.local(request, mode: mode, from: currentGains) {
      proposals = [local]
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
    if let song = player.song {
      curveSongID = song.id
      previousCurve = store.songCurve(song.id)
      store.rememberCurve(
        player.currentSnapshot, for: song.id,
        label: proposal.source == "AI" ? "一句话调音" : "本地规则",
        basis: "耳机：\(player.route.name) · \(proposal.source) · \(text)",
        detail: CurveBasis.make(
          headphone: player.route.name, song: song,
          trigger: "\(proposal.source)：\(text)", prior: store.priorDescription))
      // R3：进审计记录，之后能回滚。
      store.logTuning(
        song: song, request: text, source: proposal.source, lines: proposal.lines,
        before: snapshot.gains, after: proposal.gains)
      note = "已应用并记到这首歌，历史里可回滚。"
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
    proposals = []
    note = "已撤销，回到调音前的曲线与记忆。"
  }
}
