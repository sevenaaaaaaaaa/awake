import SwiftUI
import AppKit
import AwakeCore

@main
struct AwakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1120, minHeight: 740)
                .preferredColorScheme(.dark)
                .task { await model.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { model.presentUpdates() }
            }
            CommandMenu("播放") {
                Button(model.isPlaying ? "暂停" : "播放") { model.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("下一首") { model.nextTrack() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("上一首") { model.previousTrack() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("随机播放全部") { model.shuffleAll() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("界面") {
                Button("搜索…") { model.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("歌词舞台") { model.showNowPlaying.toggle() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("自动 EQ") { model.showEQ = true }
                    .keyboardShortcut("e", modifiers: .command)
                Button("音乐来源…") { model.showSources = true }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
        // 播放器在后台播放时必须常驻；系统自动终止会在无交互约十秒后关掉窗口。
        ProcessInfo.processInfo.disableAutomaticTermination("Awake 是音乐播放器，播放期间必须常驻")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
