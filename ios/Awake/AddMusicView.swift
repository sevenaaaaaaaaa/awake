import SwiftUI

/// 「添加音乐」一个入口：所有把音乐带进 Awake 的方式都收在这一页。
///
/// 设置页原来平铺四个导入按钮，加上配置文件夹与插件库两个入口，一共六行平级动作；
/// 用户进来想问的是「我有哪些来源 / 怎么加一个」，却先看见六个按钮。
/// 现在设置页只留一个「添加音乐」，按「服务器 / 本机 / 配置与插件」分三组。
struct AddMusicView: View {
  @EnvironmentObject var store: MobileStore
  @Environment(\.dismiss) private var dismiss
  @State private var picking: ImportTarget?
  @State private var sourceSheet = false
  @State private var note = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("从服务器") {
          Button { sourceSheet = true } label: {
            Label("WebDAV / Plex / Telegram", systemImage: "server.rack")
          }
          .accessibilityIdentifier("addRemoteSource")
          Text("连接你自己的 NAS、Plex 或自托管连接器；密码与 Token 只存钥匙串，写不进曲目地址。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("从本机") {
          Button { picking = .audioFiles } label: {
            Label("选择音频文件", systemImage: "doc.badge.plus")
          }
          .accessibilityIdentifier("addAudioFiles")
          Button { picking = .audioFolder } label: {
            Label("选择文件夹（本地 / Telegram 下载）", systemImage: "folder")
          }
          .accessibilityIdentifier("addAudioFolder")
          Button {
            Task {
              await store.importOwnFolder()
              note = "已读取「文件」里的 Awake 文件夹"
            }
          } label: {
            Label("导入「文件」里的 Awake 文件夹", systemImage: "tray.and.arrow.down")
          }
          .accessibilityIdentifier("addOwnFolder")
        }
        Section("从配置与插件") {
          NavigationLink {
            ConfigFolderView()
          } label: {
            Label("配置文件夹 · 点刷新导入", systemImage: "folder.badge.gearshape")
          }
          NavigationLink {
            PluginsView()
          } label: {
            Label("插件库 · MusicFree 兼容", systemImage: "puzzlepiece.extension")
          }
        }
        if !note.isEmpty {
          Section { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        Section {
          Text("只读你选择的内容；远程曲目首次播放先下载到本机，再进统一 EQ 链路。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .appSurface()
      .navigationTitle("添加音乐")
      .toolbar { Button("完成") { dismiss() } }
      .sheet(isPresented: $sourceSheet) { SourceEditor() }
      .importPicker($picking) { urls, target in
        switch target {
        case .audioFiles: Task { await store.importFiles(urls) }
        case .audioFolder: Task { for url in urls { await store.importAudioFolder(url) } }
        default: break
        }
      } onFail: { error, _ in
        if (error as NSError).code != NSUserCancelledError { note = error.localizedDescription }
      }
    }
  }
}
