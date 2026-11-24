import SwiftUI
import UniformTypeIdentifiers

/// 记住一个文件夹（iCloud Drive / 文件 App / 本机），点「刷新」把它里面的来源配置扫出来。
///
/// iOS 不给应用后台盯盘的能力，所以这里不是文件系统监听，而是「记住书签 + 手动刷新」：
/// 书签是 security-scoped 的，App 重启后仍能重新拿到访问权；每次刷新重新读目录，
/// 用户往文件夹里丢新配置，刷新一次就能看见。
enum ConfigFolder {
  static let bookmarkKey = "configFolderBookmark"
  static let nameKey = "configFolderName"

  static var name: String? { UserDefaults.standard.string(forKey: nameKey) }
  static var hasFolder: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

  static func remember(_ url: URL) throws {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let data = try url.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    UserDefaults.standard.set(data, forKey: bookmarkKey)
    UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
  }

  static func forget() {
    UserDefaults.standard.removeObject(forKey: bookmarkKey)
    UserDefaults.standard.removeObject(forKey: nameKey)
  }

  /// 解开书签并把地址交回去。调用方负责 start/stopAccessingSecurityScopedResource。
  static func resolve() throws -> URL {
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
      throw AppFailure("还没有选过文件夹")
    }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    if stale, let fresh = try? url.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    {
      UserDefaults.standard.set(fresh, forKey: bookmarkKey)
    }
    return url
  }
}

/// 扫出来的一个候选配置：要么解析成功带着 config，要么带着失败原因。
struct ConfigCandidate: Identifiable {
  let id = UUID()
  let url: URL
  let config: SourceConfiguration?
  let error: String?
  var fileName: String { url.lastPathComponent }
  var title: String { config?.name ?? url.deletingPathExtension().lastPathComponent }
}

struct ConfigFolderView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var folderName = ConfigFolder.name
  @State private var hasFolder = ConfigFolder.hasFolder
  @State private var picking = false
  @State private var note = ""
  @State private var candidates: [ConfigCandidate] = []
  @State private var prefill: SourceConfiguration?
  @State private var editorOpen = false

  private static let allowed: Set<String> = ["json", "xml", "txt"]

  var body: some View {
    NavigationStack {
      Form {
        Section("文件夹") {
          if hasFolder {
            LabeledContent("当前", value: folderName ?? "（已选）")
          }
          Button(hasFolder ? "换一个文件夹" : "选择文件夹") { picking = true }
            .accessibilityIdentifier("pickConfigFolder")
          if hasFolder {
            Button("刷新扫描") { scan() }
              .accessibilityIdentifier("rescanConfigFolder")
            Button("忘记这个文件夹", role: .destructive) {
              ConfigFolder.forget()
              hasFolder = false
              folderName = nil
              candidates = []
              note = ""
            }
          }
          AwakeNote(text: "把这个文件夹当作来源配置入口：把 .json / .xml / .txt 放进去（iCloud Drive 里改完自动同步），点「刷新扫描」就能列出来。iOS 不能后台盯盘，所以是「记住 + 一点刷新」。")
        }
        Section("扫到的配置") {
          if note.isEmpty {
            Text(hasFolder ? "点「刷新扫描」开始。" : "先选一个文件夹。")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            Text(note).font(.caption).foregroundStyle(.secondary)
          }
          ForEach(candidates) { item in
            Button {
              guard let config = item.config else { return }
              prefill = config
              editorOpen = true
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                if let config = item.config {
                  AwakeNote(text: "\(config.kind.uppercased()) · \(config.url)")
                } else if let error = item.error {
                  Text(error).font(.caption).foregroundStyle(.red)
                }
                Text(item.fileName).font(.caption2).foregroundStyle(.tertiary)
              }
            }
            .disabled(item.config == nil)
            .accessibilityIdentifier("configCandidate_\(item.fileName)")
          }
          if !candidates.isEmpty {
            AwakeNote(text: "点一条会把类型、名称、地址填进「添加音乐来源」，密码 / Token 仍在应用内填一次——配置文件里按设计不含凭据。")
          }
        }
      }
      .appSurface()
      .navigationTitle("配置文件夹")
      .toolbar { Button("完成") { dismiss() } }
      .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
        do {
          let url = try result.get()
          try ConfigFolder.remember(url)
          folderName = url.lastPathComponent
          hasFolder = true
          scan()
        } catch { note = error.localizedDescription }
      }
      .sheet(isPresented: $editorOpen) {
        SourceEditor(prefill: prefill)
      }
      .onAppear {
        folderName = ConfigFolder.name
        hasFolder = ConfigFolder.hasFolder
      }
    }
  }

  private func scan() {
    candidates = []
    note = ""
    do {
      let folder = try ConfigFolder.resolve()
      let access = folder.startAccessingSecurityScopedResource()
      defer { if access { folder.stopAccessingSecurityScopedResource() } }
      let urls = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
      var found: [ConfigCandidate] = []
      for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let ext = url.pathExtension.lowercased()
        guard Self.allowed.contains(ext) else { continue }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 65536 else {
          found.append(ConfigCandidate(url: url, config: nil, error: "超过 64 KB，已跳过"))
          continue
        }
        do {
          let text = try String(contentsOf: url, encoding: .utf8)
          let config = try SourceConfiguration.parse(text, format: ext)
          found.append(ConfigCandidate(url: url, config: config, error: nil))
        } catch {
          found.append(
            ConfigCandidate(url: url, config: nil, error: error.localizedDescription))
        }
      }
      candidates = found
      let ok = found.filter { $0.config != nil }.count
      note =
        found.isEmpty
        ? "这个文件夹里没有 .json / .xml / .txt"
        : "找到 \(found.count) 个文件，\(ok) 个可用，\(found.count - ok) 个有问题"
    } catch {
      note = "刷新失败：" + error.localizedDescription
    }
  }
}
