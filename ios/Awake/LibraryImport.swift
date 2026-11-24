import Foundation

/// 本地导入的纯逻辑：枚举、去重判定与一句话结果。
///
/// 刻意不依赖 SwiftUI / UIKit / 曲库模型：本机模拟器的 XCTest 服务起不来
/// （`DTServiceHubClient failed to bless service hub`），所以这个文件要被
/// `swiftc` 在 macOS 上单独编译成逻辑 harness 跑真实断言。别把 Song 之类的
/// 类型塞进来，否则 harness 就编译不过、测试又只能靠肉眼。
enum LibraryImport {
  struct FileScan {
    var files: [URL] = []
    /// 单个条目读不了元数据（File Provider 未下载、权限）而跳过的数量。
    var unreadable = 0
    /// 超过单次导入上限。
    var exceeded = false
  }

  static let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "alac",
  ]

  /// App 自己管理的子目录（相对曲库根目录）。
  ///
  /// 这些目录里的音频是 **App 自己写出来的副本**：导入缓存、封面、语音合成、新闻音频。
  /// 扫描时把它们当成用户文件，就会「导入自己的导入结果」——每扫一次多一代拷贝。
  static let managedDirectories: Set<String> = [
    "Music", "Artwork", "Speech", "News",
  ]

  /// 递归枚举文件夹里的音频文件。
  ///
  /// 四条规则，每一条都对应一次「导入怎么修都修不好」：
  /// 1. 单个条目读不了就跳过并计数，绝不让一个坏条目毁掉整次导入；
  /// 2. 符号链接一律跳过（File Provider 的占位链接复制时会失败）；
  /// 3. App 自己管理的目录（`excludingManagedFrom` 之下）整棵跳过，不列举、不进入；
  /// 4. 目录清单读不到（iCloud 未下载）时，用 NSFileCoordinator 协调读取再枚举一次。
  static func audioFiles(
    in url: URL, limit: Int = 20000, excludingManagedFrom root: URL? = nil
  ) -> FileScan {
    var scan = FileScan()
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
    var found: [URL] = []
    var skipped = 0
    let managedRoot = root

    func walk(_ base: URL) -> Bool {
      guard
        let enumerator = FileManager.default.enumerator(
          at: base, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
      else { return false }
      for case let item as URL in enumerator {
        guard let values = try? item.resourceValues(forKeys: keys) else {
          skipped += 1
          continue
        }
        if values.isSymbolicLink == true { continue }
        if values.isDirectory == true {
          if let managedRoot, isManagedFile(item, root: managedRoot) {
            enumerator.skipDescendants()
          }
          continue
        }
        guard values.isRegularFile == true,
          audioExtensions.contains(item.pathExtension.lowercased())
        else { continue }
        if let managedRoot, isManagedFile(item, root: managedRoot) { continue }
        found.append(item)
        if found.count > limit {
          scan.exceeded = true
          return true
        }
      }
      return true
    }

    var walked = walk(url)
    if !walked || (found.isEmpty && skipped > 0) {
      // iCloud / File Provider 的目录清单没下载时，协调读取会触发下载。
      var coordinationError: NSError?
      NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
        readURL in
        if walk(readURL) { walked = true }
      }
    }
    scan.files = found.sorted { $0.path < $1.path }
    scan.unreadable = skipped
    return scan
  }

  /// 这个文件是不是 App 自己写出来的（在 `root/Music`、`root/Artwork` 等目录里）。
  ///
  /// 同时按两种写法判：标准化后的绝对前缀，以及「Documents 之后」的相对路径。
  /// 后者是为了兜住 `/var/...` 与 `/private/var/...` 这类同一个文件的两种写法。
  static func isManagedFile(_ url: URL, root: URL) -> Bool {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
    let rootName = (rootPath as NSString).lastPathComponent
    for dir in managedDirectories {
      if path.hasPrefix(rootPath + "/" + dir + "/") { return true }
      if let relative = documentsRelativePath(path),
        relative.hasPrefix(rootName + "/" + dir + "/")
      {
        return true
      }
    }
    return false
  }

  /// 把任意 App 容器路径里 `/Documents/` 之后的部分取出来；不是容器路径则返回 nil。
  ///
  /// App 的数据容器 UUID 会在重装、恢复备份、某些升级路径上变掉，绝对路径不能当身份。
  static func documentsRelativePath(_ path: String) -> String? {
    guard let range = path.range(of: "/Documents/") else { return nil }
    let head = String(path[path.startIndex..<range.lowerBound])
    guard head.contains("/Containers/Data/Application/") else { return nil }
    return String(path[range.upperBound...])
  }

  /// 稳定身份：容器内的文件记成 `own:Awake/xxx.mp3`，容器外仍是绝对路径。
  ///
  /// 只解决「同一个文件在同一个 App 里的身份」，不解决「同一段音频换了名字」——
  /// 后者交给 `fingerprint(size:duration:)` + 文件头哈希兜。
  static let ownScheme = "own:"
  /// App 自己生成的音频（语音合成、AI 作曲、内置示例）的身份前缀。
  static let cacheScheme = "cache:"

  static func locator(for url: URL, documents: URL? = nil) -> String {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    if let documents {
      let base = documents.standardizedFileURL.resolvingSymlinksInPath().path
      if path == base { return ownScheme }
      if path.hasPrefix(base + "/") {
        return ownScheme + String(path.dropFirst(base.count + 1))
      }
    }
    if let relative = documentsRelativePath(path) { return ownScheme + relative }
    return path
  }

  /// 把 locator 归一成可比较的身份键。旧档案里的绝对容器路径会被折成 `own:`。
  static func identityKey(_ locator: String, documents: URL? = nil) -> String {
    guard !locator.isEmpty else { return "" }
    var base = locator
    var suffix = ""
    if let cue = locator.range(of: "#cue-") {
      base = String(locator[locator.startIndex..<cue.lowerBound])
      suffix = String(locator[cue.lowerBound...])
    }
    if base.hasPrefix(ownScheme) {
      return ownScheme + normalizedRelative(String(base.dropFirst(ownScheme.count))) + suffix
    }
    if base.hasPrefix(cacheScheme) { return base + suffix }
    if base.hasPrefix("/") {
      let standardized = URL(fileURLWithPath: base).standardizedFileURL.resolvingSymlinksInPath().path
      if let documents {
        let doc = documents.standardizedFileURL.resolvingSymlinksInPath().path
        if standardized.hasPrefix(doc + "/") {
          return ownScheme + String(standardized.dropFirst(doc.count + 1)) + suffix
        }
      }
      if let relative = documentsRelativePath(standardized) { return ownScheme + relative + suffix }
      return standardized + suffix
    }
    // http(s)、plex://、插件 JSON、cache: 之外的自定义 scheme：原样比较。
    return base + suffix
  }

  /// 存进曲库前用的 locator：能相对化就相对化，不能就保留原样。
  static func migratedLocator(_ locator: String, documents: URL) -> String {
    guard !locator.isEmpty else { return locator }
    let key = identityKey(locator, documents: documents)
    if key.hasPrefix(ownScheme) { return key }
    return locator
  }

  static func cacheLocator(_ file: String) -> String { cacheScheme + file }

  private static func normalizedRelative(_ path: String) -> String {
    var parts: [String] = []
    for part in path.split(separator: "/") {
      switch part {
      case ".": continue
      case "..": if !parts.isEmpty { parts.removeLast() }
      default: parts.append(String(part))
      }
    }
    return parts.joined(separator: "/")
  }

  /// 文件名式的 UUID（含 `XXXX-...` 前缀截断形式）：这种标题是缓存文件名漏进了界面。
  static func isUUIDLike(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 8 else { return false }
    let chars = Array(trimmed.prefix(36))
    var hexCount = 0
    var hyphens = 0
    for (index, char) in chars.enumerated() {
      if char == "-" {
        hyphens += 1
        if index != 8 && index != 13 && index != 18 && index != 23 { return false }
        continue
      }
      guard char.isHexDigit else { return false }
      hexCount += 1
    }
    // 完整的 8-4-4-4-12，或「截断到 36 字符以内但至少 8 位十六进制 + 连字符」。
    return hexCount >= 8 && (hyphens >= 1 || chars.count == 32)
  }

  /// 便宜的内容指纹：字节数 + 时长（0.1 秒）。真正落库前再用文件头哈希二次确认。
  static func fingerprint(size: Int64, duration: Double) -> String {
    "\(size)-\(Int((duration * 10).rounded()))"
  }

  static func sizeKey(size: Int64, duration: Double) -> String {
    "\(size)-\(Int((duration * 10).rounded()))"
  }

  /// 文件头哈希（FNV-1a 64）：同尺寸同时长的不同歌靠它分开，比全文件哈希便宜。
  static func headHash(_ data: Data) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in data {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
  }

  /// 已有曲目时还要不要复制：本机文件不在就补齐。
  /// 备份恢复过的曲库只有元数据、系统清理过缓存、上次复制失败，都会走到这里。
  static func shouldImport(existingHasLocalFile: Bool?) -> Bool {
    existingHasLocalFile != true
  }

  // MARK: - 去重分组（纯逻辑，可在 macOS 上直接跑）

  /// 一首本地曲目在去重时需要的全部信息。
  struct Entry: Equatable {
    var id: String
    var identity: String
    /// `size-duration`；nil 表示没有本机文件、或 CUE 虚拟分轨（不能按内容判重）。
    var fingerprint: String?
    var file: String?
    var title: String
    var artist: String
    var hasArtwork = false
    var hasLyrics = false
    /// 歌单 / 听书进度 / 评分 / 听歌记录里还引着它。
    var referenced = false
    var addedAt: Date?
  }

  struct DuplicateGroup: Equatable {
    var keep: String
    var drop: [String]
  }

  /// 留下哪一条：先看用户看得见的质量，再看有没有被歌单 / 听书记录引用。
  ///
  /// 标题质量排第一，是因为重复导入留下的那一条标题多半是缓存文件名（UUID）；
  /// 只要保留项选对了，引用可以在合并时整体改过去，界面也不会再出现乱码标题。
  static func rank(_ entry: Entry) -> Int {
    var score = 0
    if !entry.title.isEmpty && !isUUIDLike(entry.title) { score += 8 }
    if entry.referenced { score += 4 }
    if !entry.artist.isEmpty && entry.artist != "未知艺人" { score += 2 }
    if entry.hasArtwork { score += 1 }
    if entry.hasLyrics { score += 1 }
    return score
  }

  /// 把同内容 / 同身份的曲目分桶；键是 `fp:<指纹>` 或 `id:<身份>`。
  static func buckets(_ entries: [Entry]) -> [String: [Entry]] {
    var buckets: [String: [Entry]] = [:]
    for entry in entries {
      let key: String
      if let fingerprint = entry.fingerprint, !fingerprint.isEmpty {
        key = "fp:" + fingerprint
      } else if !entry.identity.isEmpty {
        key = "id:" + entry.identity
      } else {
        continue
      }
      buckets[key, default: []].append(entry)
    }
    return buckets
  }

  /// 一组同内容曲目里留谁、丢谁；不足两条时返回 nil。
  static func group(_ rows: [Entry]) -> DuplicateGroup? {
    guard rows.count > 1 else { return nil }
    let ordered = rows.sorted { a, b in
      let ra = rank(a)
      let rb = rank(b)
      if ra != rb { return ra > rb }
      let da = a.addedAt ?? Date.distantFuture
      let db = b.addedAt ?? Date.distantFuture
      if da != db { return da < db }
      return a.id < b.id
    }
    guard let keep = ordered.first else { return nil }
    return DuplicateGroup(keep: keep.id, drop: ordered.dropFirst().map(\.id))
  }

  /// 把同内容 / 同身份的曲目归组；每组给出保留项与待合并项。
  static func duplicateGroups(_ entries: [Entry]) -> [DuplicateGroup] {
    var groups: [DuplicateGroup] = []
    for (_, rows) in buckets(entries) {
      if let group = group(rows) { groups.append(group) }
    }
    return groups.sorted { $0.keep < $1.keep }
  }

  /// 读文件头（最多 `limit` 字节）做二次确认；读不到返回 nil。
  static func headBytes(of url: URL, limit: Int = 65536) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    return try? handle.read(upToCount: limit)
  }

  /// 导入结果的一句话。返回 nil 表示「什么都没发生」。
  static func statusMessage(added: Int, healed: Int, skipped: Int, failed: [String]) -> String? {
    var parts: [String] = []
    if added > 0 { parts.append("已导入 \(added) 首") }
    if healed > 0 { parts.append("补齐 \(healed) 首本机缓存") }
    if skipped > 0 { parts.append("跳过 \(skipped) 首已在曲库") }
    if !failed.isEmpty {
      let sample = failed.prefix(3).joined(separator: "、")
      let more = failed.count > 3 ? " 等 \(failed.count) 首" : ""
      parts.append("\(failed.count) 首失败：\(sample)\(more)")
    }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: "，")
  }
}
