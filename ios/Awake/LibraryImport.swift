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

  /// 递归枚举文件夹里的音频文件。
  ///
  /// 三条规则，每一条都对应一次「导入怎么修都修不好」：
  /// 1. 单个条目读不了就跳过并计数，绝不让一个坏条目毁掉整次导入；
  /// 2. 符号链接一律跳过（File Provider 的占位链接复制时会失败）；
  /// 3. 目录清单读不到（iCloud 未下载）时，用 NSFileCoordinator 协调读取再枚举一次。
  static func audioFiles(in url: URL, limit: Int = 20000) -> FileScan {
    var scan = FileScan()
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
    var found: [URL] = []
    var skipped = 0

    func walk(_ root: URL) -> Bool {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
      else { return false }
      for case let item as URL in enumerator {
        guard let values = try? item.resourceValues(forKeys: keys) else {
          skipped += 1
          continue
        }
        if values.isSymbolicLink == true { continue }
        if values.isDirectory == true { continue }
        guard values.isRegularFile == true,
          audioExtensions.contains(item.pathExtension.lowercased())
        else { continue }
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

  /// 已有曲目时还要不要复制：本机文件不在就补齐。
  /// 备份恢复过的曲库只有元数据、系统清理过缓存、上次复制失败，都会走到这里。
  static func shouldImport(existingHasLocalFile: Bool?) -> Bool {
    existingHasLocalFile != true
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
