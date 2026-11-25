import Foundation

/// 「添加音乐 · 已连接」每一行说什么，由这里唯一决定。
///
/// 为什么抽出来：这三句话（有曲目 / 0 首 / 连接失败）以前散在视图里，
/// 验证只能靠人看截图。抽成纯函数后，`Tools/verify_add_source_copy.swift`
/// 可以在两秒内把三种情况跑一遍，不需要模拟器，也不需要 Xcode。
enum AddSourceCopy {
  /// 一行状态：类型 · 曲数 · 下一步。
  /// 0 首必须说清下一步，否则「加了但没东西」看起来就是坏了。
  static func statusLine(kindName: String, count: Int) -> String {
    if count == 0 {
      return "\(kindName) · 还没有曲目 · 到「设置 → 音乐来源」刷新或移除"
    }
    return "\(kindName) · \(count) 首 · 点这里进曲库"
  }

  /// 连接失败：仍然留在弹窗里的那句红字。
  static func failureInSheet(reason: String) -> String {
    "没有加入：\(reason)"
  }

  /// 连接失败：关掉弹窗之后还能看见的那句（添加页「最近一次操作」与全局提示共用）。
  static func failureOutside(name: String, reason: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    let label = trimmed.isEmpty ? "这个来源" : "「\(trimmed)」"
    return "\(label)没有加入：\(reason)"
  }

  /// 点进一个 0 首来源时，曲库空态要回答「为什么空、下一步做什么」。
  static func emptyLibraryMessage(sourceName: String) -> String {
    "「\(sourceName)」还没有曲目：到「设置 → 音乐来源」刷新一次；不想保留就移除，筛选会回到全部。"
  }
}
