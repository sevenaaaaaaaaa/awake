import SwiftUI
import UniformTypeIdentifiers

/// 一个已导入的 MusicFree 兼容插件。
///
/// 这一版只负责「收下并保存」：真正跑 JS 的沙箱在下一步（S2），
/// 所以这里存的是文件本身，不假装能搜索。
struct InstalledPlugin: Codable, Identifiable, Equatable {
  var id: String
  var name: String
  var fileName: String
  var bytes: Int
  var addedAt: Date
  /// 从注册表装上时记下来源地址；手动导入为 nil。
  var sourceURL: String?
  var version: String?
}

/// 插件仓库：文件放在 Documents/plugins/<id>.js，索引放在同目录 index.json。
/// 不放钥匙串、不联网：这一步只做本地存取。
final class PluginLibrary: ObservableObject {
  static let shared = PluginLibrary()
  static let maxBytes = 512 * 1024
  static let maxCount = 64

  @Published private(set) var plugins: [InstalledPlugin] = []

  private let manager = FileManager.default
  private var loaded = false

  var directory: URL {
    let docs = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent("plugins", isDirectory: true)
  }
  private var indexURL: URL { directory.appendingPathComponent("index.json") }

  private init() {}

  func loadIfNeeded() {
    guard !loaded else { return }
    loaded = true
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let data = try? Data(contentsOf: indexURL),
      let list = try? JSONDecoder().decode([InstalledPlugin].self, from: data)
    else { return }
    // 索引里记着、文件被删掉的条目直接丢掉，别让列表骗人。
    plugins = list.filter { manager.fileExists(atPath: fileURL($0.id).path) }
  }

  func fileURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".js") }

  func code(for id: String) -> String? {
    guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// 导入一个 .js。同名插件会被替换（避免列表里堆同名版本）。
  @discardableResult
  func importFile(_ url: URL) throws -> InstalledPlugin {
    loadIfNeeded()
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let data = try Data(contentsOf: url)
    return try store(data: data, fileName: url.lastPathComponent, sourceURL: nil, version: nil)
  }

  @discardableResult
  func store(data: Data, fileName: String, sourceURL: String?, version: String?) throws
    -> InstalledPlugin
  {
    loadIfNeeded()
    guard !data.isEmpty else { throw AppFailure("插件文件是空的") }
    guard data.count <= Self.maxBytes else {
      throw AppFailure("插件 \(data.count) 字节，超过 512 KB 上限")
    }
    guard let text = String(data: data, encoding: .utf8),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw AppFailure("不是 UTF-8 文本，读不出插件") }
    if plugins.count >= Self.maxCount, !plugins.contains(where: { $0.fileName == fileName }) {
      throw AppFailure("最多保存 \(Self.maxCount) 个插件")
    }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)

    if let existing = plugins.first(where: { $0.fileName == fileName }) {
      try data.write(to: fileURL(existing.id), options: .atomic)
      var updated = existing
      updated.bytes = data.count
      updated.addedAt = Date()
      updated.sourceURL = sourceURL ?? existing.sourceURL
      updated.version = version ?? existing.version
      if let index = plugins.firstIndex(where: { $0.id == existing.id }) {
        plugins[index] = updated
      }
      save()
      return updated
    }

    let id = UUID().uuidString
    try data.write(to: fileURL(id), options: .atomic)
    let plugin = InstalledPlugin(
      id: id,
      name: fileName.replacingOccurrences(of: ".js", with: ""),
      fileName: fileName,
      bytes: data.count,
      addedAt: Date(),
      sourceURL: sourceURL,
      version: version)
    plugins.append(plugin)
    save()
    return plugin
  }

  func remove(_ id: String) {
    loadIfNeeded()
    plugins.removeAll { $0.id == id }
    try? manager.removeItem(at: fileURL(id))
    save()
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(plugins) else { return }
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: indexURL, options: .atomic)
  }
}

struct PluginsView: View {
  @ObservedObject private var library = PluginLibrary.shared
  @State private var importing = false
  @State private var note = ""

  private var jsTypes: [UTType] {
    [UTType(filenameExtension: "js") ?? .plainText, .javaScript, .plainText]
  }

  var body: some View {
    Form {
      Section("已导入") {
        if library.plugins.isEmpty {
          Text("还没有插件。").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(library.plugins) { plugin in
          VStack(alignment: .leading, spacing: 4) {
            Text(plugin.name).font(.headline)
            Text("\(plugin.fileName) · \(plugin.bytes) 字节")
              .font(.caption).foregroundStyle(.secondary)
            if let source = plugin.sourceURL {
              Text(source).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("删除", role: .destructive) { library.remove(plugin.id) }
          }
        }
      }
      Section {
        Button("导入插件 .js", systemImage: "square.and.arrow.down") { importing = true }
          .accessibilityIdentifier("importPlugin")
        if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.red) }
        Text("单文件上限 512 KB，按 UTF-8 文本保存。这一步只做导入与保存：搜索、解析直链要等沙箱接上（下一步 S2），现在点插件不会去联网。")
          .font(.caption).foregroundStyle(.secondary)
        Text("插件按你显式导入处理，信任级别等同于你安装的应用——只导入你信任来源的插件。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .appSurface()
    .glassRows()
    .navigationTitle("插件库")
    .onAppear { library.loadIfNeeded() }
    .fileImporter(isPresented: $importing, allowedContentTypes: jsTypes) { result in
      switch result {
      case .success(let url):
        do {
          let plugin = try library.importFile(url)
          note = "已导入 \(plugin.name)（\(plugin.bytes) 字节）"
        } catch { note = error.localizedDescription }
      case .failure(let error):
        if (error as NSError).code != NSUserCancelledError { note = error.localizedDescription }
      }
    }
  }
}
