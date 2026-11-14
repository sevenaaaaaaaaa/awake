import SwiftUI

/// 电脑 → 手机接力的接收界面：显示配对码、连接状态与最近一次接收结果。
struct HandoffReceiveView: View {
  @EnvironmentObject var player: MobilePlayer
  @EnvironmentObject var store: MobileStore
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var receiver = HandoffReceiver()
  @State private var configured = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if receiver.active {
            VStack(alignment: .leading, spacing: 6) {
              Text("配对码").font(.caption).foregroundStyle(.secondary)
              Text(receiver.code)
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .accessibilityIdentifier("receiveCode")
              Text("在电脑上点「接力到手机」，选定这台手机后输入这 6 位数字")
                .font(.caption).foregroundStyle(.secondary)
            }
            Button("换一组配对码") { receiver.refreshCode() }
              .accessibilityIdentifier("refreshReceiveCode")
          } else {
            Text("接收已停止").font(.subheadline).foregroundStyle(.secondary)
          }
        } header: {
          HStack {
            Text("配对码")
            Spacer()
            Text(receiver.active ? "接收中" : "未开启")
              .font(.caption).foregroundStyle(receiver.active ? .green : .secondary)
          }
        }

        Section("这台手机") {
          LabeledContent("设备名", value: receiver.name.isEmpty ? HandoffReceiver.deviceName() : receiver.name)
          LabeledContent("端口", value: receiver.port == 0 ? "—" : String(receiver.port))
          if !receiver.lastMessage.isEmpty {
            Text(receiver.lastMessage).font(.caption).foregroundStyle(.secondary)
              .accessibilityIdentifier("receiveStatus")
          }
        }

        Section("最近接收") {
          if receiver.lastTitle.isEmpty {
            Text("还没有收到电脑发来的曲目").font(.subheadline).foregroundStyle(.secondary)
          } else {
            Text(receiver.lastTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
          }
        }

        Section {
          Button(role: .destructive) {
            receiver.stop()
            dismiss()
          } label: {
            Text("停止接收")
          }
          .accessibilityIdentifier("stopReceiveHandoff")
        } footer: {
          Text("配对码 10 分钟没有请求会自动过期，错码 5 次会换新码。停止接收、离开这个页面或把 App 切到后台后，端口和广播立即结束；手机不提供后台常驻接收。只传曲目信息与播放进度，不传音频、账号或密码。")
        }
      }
      .navigationTitle("接收接力")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("完成") { dismiss() }
        }
      }
    }
    .onAppear {
      configure()
      if !receiver.active { receiver.start() }
    }
    .onDisappear { receiver.stop() }
    .onChange(of: scenePhase) { _, phase in
      // 手机不做后台常驻接收：切到后台就停止监听，回来重新开启。
      if phase != .active { receiver.stop() }
    }
  }

  private func configure() {
    guard !configured else { return }
    configured = true
    receiver.match = { info in
      HandoffMatcher.bestMatch(
        query: info, songs: store.state.songs,
        isPlayable: { store.localURL($0) != nil })
    }
    receiver.play = { song, position, playing in
      guard let url = store.localURL(song) else { return }
      player.play([(song, url)], at: 0, from: position, startPlaying: playing)
    }
  }
}
