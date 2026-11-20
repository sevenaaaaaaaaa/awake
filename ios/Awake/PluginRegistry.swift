import Foundation

/// 插件源里的一条：一张 myPlugins.json 列出的可装插件。
struct RegistryEntry: Identifiable, Equatable {
  var name: String
  var url: String
  var version: String?
  var id: String { url }
}

/// `myPlugins.json` 解析与下载。规则照抄桌面 `ui/src/plugins.ts` 的 parsePluginRegistry：
/// 根可以是数组，或对象的 plugins / data / list 之一；每条要有 name 与 http(s) 地址；按地址去重；上限 200 条。
enum PluginRegistry {
  static let limit = 200
  /// 注册表本身不该有几百 KB —— 超了说明拿到的不是注册表。
  static let maxRegistryBytes = 256 * 1024

  static func parse(_ data: Data) throws -> [RegistryEntry] {
    let object = try JSONSerialization.jsonObject(with: data)
    let raw: [Any]
    if let array = object as? [Any] {
      raw = array
    } else if let dict = object as? [String: Any] {
      if let list = dict["plugins"] as? [Any] { raw = list }
      else if let list = dict["data"] as? [Any] { raw = list }
      else if let list = dict["list"] as? [Any] { raw = list }
      else { throw AppFailure("这不是插件源：找不到插件列表") }
    } else {
      throw AppFailure("这不是插件源：找不到插件列表")
    }

    var out: [RegistryEntry] = []
    var seen = Set<String>()
    for item in raw {
      guard let record = item as? [String: Any] else { continue }
      let name = (record["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let address = (record["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, !address.isEmpty else { continue }
      let lower = address.lowercased()
      guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { continue }
      guard !seen.contains(address) else { continue }
      seen.insert(address)
      let rawVersion = (record["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let version = (rawVersion?.isEmpty ?? true) ? nil : rawVersion
      out.append(RegistryEntry(name: name, url: address, version: version))
      if out.count >= limit { break }
    }
    guard !out.isEmpty else { throw AppFailure("插件源里没有可用的插件") }
    return out
  }

  /// 从地址抓一份注册表。局域网 http 也允许（只对 10.x / 192.168.x / .local 这类）。
  static func fetch(_ text: String) async throws -> [RegistryEntry] {
    let url = try Network.endpoint(text, localHTTP: true)
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data = try await Network.data(request, limit: maxRegistryBytes)
    return try parse(data)
  }

  static func download(_ entry: RegistryEntry) async throws -> Data {
    guard let url = URL(string: entry.url), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { throw AppFailure("插件地址无效：\(entry.url)") }
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    let data = try await Network.data(request, limit: PluginLibrary.maxBytes + 1)
    guard data.count <= PluginLibrary.maxBytes else {
      throw AppFailure("插件 \(data.count) 字节，超过 512 KB 上限")
    }
    return data
  }

  /// 从插件地址推文件名，推不出就叫 plugin.js（桌面同名规则）。
  static func fileName(from address: String) -> String {
    guard let url = URL(string: address) else { return "plugin.js" }
    let last = url.lastPathComponent
    let ok = last.range(of: #"^[A-Za-z0-9_.-]+\.js$"#, options: .regularExpression) != nil
    return ok ? last : "plugin.js"
  }
}
