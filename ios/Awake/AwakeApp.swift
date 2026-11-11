import AVFoundation
import SwiftUI

@main struct AwakeApp: App {
  @StateObject private var store: MobileStore
  @StateObject private var player = MobilePlayer()
  init() {
    #if DEBUG
      let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
      let root =
        testing
        ? FileManager.default.temporaryDirectory.appendingPathComponent(
          "Awake-UITests", isDirectory: true) : nil
      if testing, let root { try? FileManager.default.removeItem(at: root) }
      let s = MobileStore(root: root)
      if testing {
        let f = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 96000)!
        b.frameLength = 96000
        for c in 0..<2 {
          for i in 0..<96000 {
            b.floatChannelData![c][i] = Float(sin(Double(i) * 2 * Double.pi * 1000 / 48000) * 0.1)
          }
        }
        let url = s.music.appendingPathComponent("QA.wav")
        if let file = try? AVAudioFile(forWriting: url, settings: f.settings) {
          try? file.write(from: b)
          s.state.songs = [
            Song(
              id: "qa-audio", title: "QA 自生成测试音频", artist: "Awake 软件测试", duration: 2,
              sampleRate: 48000, file: "QA.wav")
          ]
          s.save()
        }
      }
      _store = StateObject(wrappedValue: s)
    #else
      _store = StateObject(wrappedValue: MobileStore())
    #endif
  }
  var body: some Scene {
    WindowGroup {
      RootView().environmentObject(store).environmentObject(player).modifier(
        TestingMotionPreference()
      ).task {
        #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("--uitesting") { player.volume = 0 }
        #endif
      }
    }
  }
}

private struct TestingMotionPreference: ViewModifier {
  func body(content: Content) -> some View {
    #if DEBUG
      content.environment(
        \.awakeReducedMotion,
        ProcessInfo.processInfo.arguments.contains("--reduce-motion-ui"))
    #else
      content
    #endif
  }
}
