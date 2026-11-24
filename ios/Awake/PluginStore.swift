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
  @State private var registryURL = ""
  @State private var registryEntries: [RegistryEntry] = []
  @State private var registryBusy = false
  @State private var registryStatus = ""
  @State private var registryError = ""
  @State private var installing: String?

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
          NavigationLink {
            PluginSearchView(plugin: plugin)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(plugin.name).font(.headline)
              AwakeNote(text: "\(plugin.fileName) · \(plugin.bytes) 字节")
              if let source = plugin.sourceURL {
                Text(source).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
              }
            }
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("删除", role: .destructive) { library.remove(plugin.id) }
          }
        }
      }
      Section("插件源（myPlugins.json）") {
        TextField("…/myPlugins.json 或 http 地址", text: $registryURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .accessibilityIdentifier("pluginRegistryURL")
        HStack {
          Button("载入插件源") { Task { await loadRegistry() } }
            .disabled(registryBusy || registryURL.trimmingCharacters(in: .whitespaces).isEmpty)
          if ConfigFolder.hasFolder {
            Button("从配置文件夹读") { Task { await loadFromFolder() } }
              .disabled(registryBusy)
          }
        }
        if registryBusy { ProgressView() }
        if !registryStatus.isEmpty {
          Text(registryStatus).font(.caption).foregroundStyle(.secondary)
        }
        if !registryError.isEmpty {
          Text(registryError).font(.caption).foregroundStyle(.red)
        }
        ForEach(registryEntries) { entry in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.name).font(.subheadline)
              Text(entry.url).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Button(installing == entry.id ? "安装中…" : "安装") { Task { await install(entry) } }
              .disabled(installing != nil)
          }
        }
        AwakeNote(text: "地址可以是 https 的注册表，也可以是局域网 http。也可以把 myPlugins.json 放进「来源配置文件夹」，点「从配置文件夹读」。")
      }
      Section {
        Button("导入插件 .js", systemImage: "square.and.arrow.down") { importing = true }
          .accessibilityIdentifier("importPlugin")
        if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.red) }
        AwakeNote(text: "单文件上限 512 KB，按 UTF-8 文本保存。这一步只做导入与保存：搜索、解析直链要等沙箱接上（下一步 S2），现在点插件不会去联网。")
        AwakeNote(text: "插件按你显式导入处理，信任级别等同于你安装的应用——只导入你信任来源的插件。")
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

  // MARK: - 插件源

  @MainActor
  private func loadRegistry() async {
    registryBusy = true
    registryStatus = ""
    registryError = ""
    defer { registryBusy = false }
    do {
      let entries = try await PluginRegistry.fetch(
        registryURL.trimmingCharacters(in: .whitespacesAndNewlines))
      registryEntries = entries
      registryStatus = "载入 \(entries.count) 个插件"
    } catch {
      registryEntries = []
      registryError = "载入失败：" + error.localizedDescription
    }
  }

  @MainActor
  private func loadFromFolder() async {
    registryBusy = true
    registryStatus = ""
    registryError = ""
    defer { registryBusy = false }
    do {
      let folder = try ConfigFolder.resolve()
      let access = folder.startAccessingSecurityScopedResource()
      defer { if access { folder.stopAccessingSecurityScopedResource() } }
      let urls = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
      var merged: [RegistryEntry] = []
      var problems: [String] = []
      for url in urls where url.pathExtension.lowercased() == "json" {
        do {
          let data = try Data(contentsOf: url)
          for entry in try PluginRegistry.parse(data)
          where !merged.contains(where: { $0.url == entry.url }) {
            merged.append(entry)
          }
        } catch {
          // 来源配置也是 json，解析不出插件列表很正常，记下来只是备用提示。
          problems.append("\(url.lastPathComponent)：\(error.localizedDescription)")
        }
      }
      registryEntries = merged
      if merged.isEmpty {
        registryError = problems.first ?? "文件夹里没找到可用的 myPlugins.json"
      } else {
        registryStatus = "从文件夹读到 \(merged.count) 个插件"
      }
    } catch {
      registryError = "读文件夹失败：" + error.localizedDescription
    }
  }

  @MainActor
  private func install(_ entry: RegistryEntry) async {
    installing = entry.id
    registryStatus = ""
    registryError = ""
    defer { installing = nil }
    do {
      let data = try await PluginRegistry.download(entry)
      let saved = try library.store(
        data: data,
        fileName: PluginRegistry.fileName(from: entry.url),
        sourceURL: entry.url,
        version: entry.version)
      registryStatus = "已安装 \(saved.name)（\(saved.bytes) 字节）"
    } catch {
      registryError = "安装失败：" + error.localizedDescription
    }
  }
}
