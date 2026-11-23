import SwiftUI

/// R2：耳朵校准。四道 A/B，每题只问「要不要更多/更少」，不做频率测验。
///
/// 选 B 的题把它的增益累加进先验（限幅 ±6 dB）；选 A 表示这条轴不需要偏置。
/// 结果带版本号；之后每条曲线的依据里会写「校准 vN」，校准更新时旧曲线可被识别。
struct CalibrationView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @Environment(\.dismiss) private var dismiss

  struct Question: Identifiable {
    let id: String
    let title: String
    let detail: String
    let gains: [Float]
  }

  static func bell(_ range: ClosedRange<Double>, _ delta: Float) -> [Float] {
    var out = Array(repeating: Float(0), count: 31)
    for (index, freq) in EQMath.frequencies.enumerated() where range.contains(Double(freq)) {
      out[index] = delta
    }
    return out
  }

  static let questions: [Question] = [
    Question(
      id: "bass", title: "低频：要不要再多一点？",
      detail: "B 在 80 Hz 以下抬 3 dB——鼓更近、下潜更实。",
      gains: bell(20...80, 3)),
    Question(
      id: "vocal", title: "人声：要不要更靠前？",
      detail: "B 在 1.6–3 kHz 抬 2.5 dB——人声从伴奏里出来。",
      gains: bell(1_600...3_150, 2.5)),
    Question(
      id: "air", title: "高频：要不要更亮一点？",
      detail: "B 在 8–12 kHz 抬 2 dB——更多空气感。",
      gains: bell(8_000...12_500, 2)),
    Question(
      id: "sibilance", title: "齿音：要不要压一点？",
      detail: "B 在 5–7 kHz 收 2 dB——压住「嘶」声。",
      gains: bell(5_000...7_000, -2)),
  ]

  @State private var index = 0
  @State private var choices: [String: String] = [:]
  @State private var base: EQSnapshot?
  @State private var previewing = false
  @State private var finished = false
  @State private var note = ""

  var body: some View {
    Form {
      if finished {
        Section("结果") {
          if let prior = store.state.earPrior {
            Text(prior.summary)
            Text("先验幅度：" + SoundTuning.describe(
              from: Array(repeating: 0, count: 31), to: prior.gains
            ).joined(separator: " · "))
              .font(.caption).foregroundStyle(.secondary)
          }
          Text("之后每条曲线的「先验」会写校准版本；随时可以重做。")
            .font(.caption).foregroundStyle(.secondary)
          Button("完成") { dismiss() }
        }
      } else {
        let question = Self.questions[min(index, Self.questions.count - 1)]
        Section("\(index + 1) / \(Self.questions.count)") {
          Text(question.title).font(.headline)
          Text(question.detail).font(.caption).foregroundStyle(.secondary)
          HStack(spacing: 12) {
            Button("听 A（现在的）") { preview(question, withDelta: false) }
            Button("听 B（调整后）") { preview(question, withDelta: true) }
          }
          .buttonStyle(.borderless)
          HStack(spacing: 12) {
            Button("A 更好") { record(question, choice: "a") }
            Button("B 更好") { record(question, choice: "b") }
            Button("听不出") { record(question, choice: "skip") }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
        if !note.isEmpty { Section { Text(note).font(.caption) } }
      }
    }
    .appSurface()
    .navigationTitle("听觉校准")
    .onAppear { if base == nil { base = player.currentSnapshot } }
    .onDisappear { restore() }
  }

  @MainActor
  private func preview(_ question: Question, withDelta: Bool) {
    guard let base else { return }
    let gains = withDelta
      ? zip(base.gains, question.gains).map { min(12, max(-12, $0 + $1)) }
      : base.gains
    _ = player.setEQ(
      gains, apo: base.apo, origin: base.origin, profile: base.profile,
      source: base.source, announce: false)
    previewing = true
  }

  @MainActor
  private func record(_ question: Question, choice: String) {
    choices[question.id] = choice
    note = choice == "skip" ? "这题跳过，不写进先验。" : (choice == "b" ? "已记下：这条轴需要偏置。" : "已记下：这条轴保持原样。")
    restore()
    if index + 1 < Self.questions.count {
      index += 1
    } else {
      finish()
    }
  }

  @MainActor
  private func finish() {
    var gains = Array(repeating: Float(0), count: 31)
    for question in Self.questions where choices[question.id] == "b" {
      for i in 0..<31 { gains[i] += question.gains[i] }
    }
    let clamped = gains.map { max(-6, min(6, $0)) }
    store.saveEarPrior(gains: clamped, choices: choices)
    finished = true
  }

  @MainActor
  private func restore() {
    guard let base else { return }
    _ = player.setEQ(
      base.gains, apo: base.apo, origin: base.origin, profile: base.profile,
      source: base.source, announce: false)
    previewing = false
  }
}
