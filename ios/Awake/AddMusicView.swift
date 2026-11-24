import SwiftUI

/// 「添加音乐」——所有把音乐带进 Awake 的入口都在这一页。
///
/// 这一页以前是六个平级按钮：用户进来先看见「有哪些按钮」，而不是「我有哪几类来源、各自要什么」。
/// 现在按「服务器 / 本机 / 配置与插件」分组，每一行写清需要准备什么、当前有几个来源，
/// 服务器那三种直接带着类型进编辑器，不用再在下拉框里选一次。
struct AddMusicView: View {
  @EnvironmentObject var store: MobileStore
  @Environment(\.dismiss) private var dismiss
  @State private var picking: ImportTarget?
  @State private var sourceSheet = false
  @State private var sourceKind = "webdav"
  @State private var note = ""

  private var remoteSources: [MusicSource] { store.state.sources }

  var body: some View {
    NavigationStack {
      Form {
        if !remoteSources.isEmpty {
          Section("已连接") {
            ForEach(remoteSources) { source in
              HStack(spacing: 12) {
                Image(systemName: icon(for: source.kind))
                  .font(.subheadline.weight(.regular))
                  .foregroundStyle(Color(hex: store.state.skin.colors.text).opacity(0.75))
                  .frame(width: 28, height: 28)
                  .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                      .fill(Color(hex: store.state.skin.colors.surface)))
                VStack(alignment: .leading, spacing: 2) {
                  Text(source.name).font(.subheadline.weight(.medium))
                  Text(
                    "\(kindName(source.kind)) · \(store.state.songs.filter { $0.sourceID == source.id }.count) 首"
                  )
                  .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
              }
              .accessibilityIdentifier("connectedSource_\(source.id)")
            }
            Text("刷新与移除在「设置 → 音乐来源」里。")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }

        Section("从服务器") {
          ForEach(serverOptions, id: \.kind) { option in
            Button {
              sourceKind = option.kind
              sourceSheet = true
            } label: {
              EntryRow(
                icon: option.icon, title: option.title, subtitle: option.requirement,
                detail: nil)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("addSource_" + option.kind)
          }
          AwakeNote(text: "远程曲目首次播放先下载到本机，再进统一 EQ 链路；当前 iOS 版不宣称即点即流。")
        }

        Section("从本机") {
          Button { picking = .audioFiles } label: {
            EntryRow(
              icon: "doc.badge.plus", title: "选择音频文件",
              subtitle: "mp3 / m4a / flac / wav / aiff / alac / caf", detail: nil)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("addAudioFiles")
          Button { picking = .audioFolder } label: {
            EntryRow(
              icon: "folder", title: "选择文件夹",
              subtitle: "本地目录，或 Telegram / 网盘下载到「文件」的目录", detail: nil)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("addAudioFolder")
          Button {
            Task {
              await store.importOwnFolder()
              note = "已读取「文件」里的 Awake 文件夹"
            }
          } label: {
            EntryRow(
              icon: "tray.and.arrow.down", title: "导入「文件」里的 Awake 文件夹",
              subtitle: "把音频拷进「我的 iPhone → Awake」，点这里直接入库", detail: nil)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("addOwnFolder")
          AwakeNote(text: "只读你选择的内容。App 自己的缓存目录（Music / Artwork / Speech / News）不会被当成来源导入。")
        }

        Section("从配置与插件") {
          NavigationLink {
            ConfigFolderView()
          } label: {
            EntryRow(
              icon: "folder.badge.gearshape", title: "配置文件夹",
              subtitle: "把来源配置放进去，点刷新导入", detail: nil)
          }
          NavigationLink {
            PluginsView()
          } label: {
            EntryRow(
              icon: "puzzlepiece.extension", title: "插件库 · MusicFree 兼容",
              subtitle: "从插件仓库拿搜索结果，播放时再解析直链", detail: nil)
          }
        }

        if !note.isEmpty {
          Section { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        if !store.message.isEmpty {
          Section("最近一次导入") {
            Text(store.message).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .appSurface()
      .navigationTitle("添加音乐")
      .toolbar { Button("完成") { dismiss() } }
      .sheet(isPresented: $sourceSheet) {
        SourceEditor(initialKind: sourceKind).environmentObject(store)
      }
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

  private struct ServerOption {
    var kind: String
    var icon: String
    var title: String
    var requirement: String
    var detail: String
  }

  private var serverOptions: [ServerOption] {
    [
      ServerOption(
        kind: "webdav", icon: "externaldrive.connected.to.line.below", title: "WebDAV / NAS / 网盘",
        requirement: "需要服务器地址、账号与应用密码", detail: "自签证书可单独放行"),
      ServerOption(
        kind: "plex", icon: "play.rectangle.on.rectangle", title: "Plex 音乐库",
        requirement: "用 Plex 账号登录换 Token，或直接填 Token", detail: "可选音乐库分区"),
      ServerOption(
        kind: "telegram", icon: "paperplane", title: "Telegram 个人媒体库",
        requirement: "需要先在自己电脑上跑连接器", detail: "选频道 / 文件夹"),
    ]
  }

  private func icon(for kind: String) -> String {
    switch kind {
    case "plex": return "play.rectangle.on.rectangle"
    case "telegram": return "paperplane"
    default: return "externaldrive.connected.to.line.below"
    }
  }

  private func kindName(_ kind: String) -> String {
    switch kind {
    case "plex": return "Plex"
    case "telegram": return "Telegram"
    default: return "WebDAV"
    }
  }
}

/// 一行「入口」：与设置页、曲库共用 AwakeRow，不再各写一套。
private struct EntryRow: View {
  @EnvironmentObject var store: MobileStore
  var icon: String
  var title: String
  var subtitle: String
  var detail: String?

  var body: some View {
    AwakeRow(icon: icon, title: title, detail: subtitle, status: nil, chevron: true)
  }
}
