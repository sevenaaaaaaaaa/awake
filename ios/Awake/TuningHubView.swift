import SwiftUI

/// 「调音」= 原「声音」+ 原「评测」，合并成一个入口。
///
/// 为什么合并：这两页本来就是同一件事的两半——一半是参数（链路、31 段曲线），
/// 一半是听感（打分、A/B、跑分）。分在两个 tab 里，用户得自己把
/// 「我说一句想要什么」「我看到什么参数」「我听完觉得怎样」串起来，
/// 而串这个正是 agent 该干的活。合并后对话在第一段，曲线与记录是它的两个证据面。
struct TuningHubView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @State private var segment = Self.e2eInitialSegment

  /// 验收通道：AWAKE_E2E_SEGMENT=1 直接落在「曲线」段。
  private static var e2eInitialSegment: Int {
    #if DEBUG
      return Int(ProcessInfo.processInfo.environment["AWAKE_E2E_SEGMENT"] ?? "") ?? 0
    #else
      return 0
    #endif
  }

  private var names: [String] { ["对话", "曲线", "记录"] }

  var body: some View {
    VStack(spacing: 0) {
      segments
      Group {
        switch segment {
        case 0: TuneSheet(embedded: true)
        case 1: SoundView()
        default: LabView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .appSurface()
    .navigationTitle("调音")
    .toolbar { if store.busy { ProgressView() } }
  }

  private var segments: some View {
    HStack(spacing: 4) {
      ForEach(names.indices, id: \.self) { index in
        Button {
          withAnimation(.easeOut(duration: 0.18)) { segment = index }
        } label: {
          Text(names[index])
            .font(.footnote.weight(segment == index ? .semibold : .regular))
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(
              segment == index
                ? Color(hex: store.state.skin.colors.bg)
                : Color(hex: store.state.skin.colors.text))
            .background(
              Capsule().fill(
                segment == index ? Color(hex: store.state.skin.colors.text) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tuningSegment-\(index)")
        .accessibilityAddTraits(segment == index ? .isSelected : [])
      }
    }
    .padding(.horizontal, DS.Space.page)
    .padding(.bottom, DS.Space.xs)
  }
}
