import Foundation

/// 曲库的「来源筛选 + 搜索」规则：唯一一份实现，界面与脚本读同一份。
///
/// 为什么必须有这一层（真实故障，不是假想）：
/// 添加来源成功后，曲库会自动筛到那个来源。如果这个来源 0 首，用户看到的是
/// 「曲库空了」；搜索框又只在那个空来源里搜，于是「搜索也用不了」。三个症状同一个根：
/// **筛选是隐藏状态**——它只活在一个高亮胶囊里，滚动到列表中部就完全看不见。
///
/// 所以这里把规则写死三条：
///  1. 有搜索词 → 搜索跨全部来源；之前有筛选就在顶部明说「已忽略」；
///  2. 只看某来源 → 顶部一行「正在只看 X · N 首」+「看全部」，不靠胶囊暗示；
///  3. 列表空分三种，各自给下一步：全库空 / 这个来源空 / 搜索无结果。
enum LibraryFilter {
  enum EmptyKind: Equatable {
    case none
    case emptyLibrary
    case sourceEmpty
    case noMatch
  }

  enum EmptyAction: Equatable {
    case none
    case importFiles
    case clearFilter
    case clearSearch
  }

  struct Decision: Equatable {
    /// 实际生效的来源筛选；nil = 全部来源。
    var scopeSourceID: String?
    /// 列表顶部那行提示；nil = 不显示。
    var bannerText: String?
    /// 提示右侧按钮标题；nil = 没有按钮。
    var bannerActionTitle: String?
    var emptyKind: EmptyKind
    var emptyTitle: String
    var emptyMessage: String
    var emptyActionTitle: String
    var emptyAction: EmptyAction
  }

  /// 生效的来源范围：搜索是全局的，有搜索词就不再按来源收窄。
  /// 界面用它过滤，decide 用它算空态——同一份规则，两处不会走样。
  static func scope(sourceID: String?, query: String) -> String? {
    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sourceID : nil
  }

  /// - Parameters:
  ///   - sourceID: 用户点的来源胶囊；nil = 全部。
  ///   - sourceName: 该来源的名字（已删除的来源由调用方给兜底）。
  ///   - sourceCount: 该来源的曲目总数。
  ///   - query: 搜索框原文。
  ///   - totalCount: 全库曲目数。
  ///   - matchCount: 按生效范围 + 搜索词过滤后的条数。
  static func decide(
    sourceID: String?,
    sourceName: String,
    sourceCount: Int,
    query: String,
    totalCount: Int,
    matchCount: Int
  ) -> Decision {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let searching = !trimmedQuery.isEmpty
    let trimmedName = sourceName.trimmingCharacters(in: .whitespaces)
    let name = trimmedName.isEmpty ? "这个来源" : trimmedName

    // 搜索跨全部来源：用户点过一次「只看 Plex」，不该让他接下来的每次搜索都沉默地窄在 Plex 里。
    let activeScope = LibraryFilter.scope(sourceID: sourceID, query: query)

    var bannerText: String?
    var bannerActionTitle: String?
    if searching, sourceID != nil {
      bannerText = "在全部 \(totalCount) 首里搜「\(trimmedQuery)」· 已忽略「\(name)」的筛选"
    } else if !searching, sourceID != nil {
      bannerText =
        sourceCount == 0
        ? "「\(name)」还没有曲目"
        : "正在只看「\(name)」· \(sourceCount) 首"
      bannerActionTitle = "看全部"
    }

    let emptyKind: EmptyKind
    if matchCount > 0 {
      emptyKind = .none
    } else if searching {
      emptyKind = .noMatch
    } else if activeScope != nil {
      emptyKind = .sourceEmpty
    } else {
      emptyKind = .emptyLibrary
    }

    switch emptyKind {
    case .none:
      return Decision(
        scopeSourceID: activeScope, bannerText: bannerText, bannerActionTitle: bannerActionTitle,
        emptyKind: .none, emptyTitle: "", emptyMessage: "", emptyActionTitle: "",
        emptyAction: .none)
    case .noMatch:
      return Decision(
        scopeSourceID: activeScope, bannerText: bannerText, bannerActionTitle: bannerActionTitle,
        emptyKind: .noMatch,
        emptyTitle: "没有匹配的曲目",
        emptyMessage: "「\(trimmedQuery)」在全部 \(totalCount) 首里没有找到。换个词，或清除搜索。",
        emptyActionTitle: "清除搜索", emptyAction: .clearSearch)
    case .sourceEmpty:
      return Decision(
        scopeSourceID: activeScope, bannerText: bannerText, bannerActionTitle: bannerActionTitle,
        emptyKind: .sourceEmpty,
        emptyTitle: "这个来源里还没有曲目",
        emptyMessage: AddSourceCopy.emptyLibraryMessage(sourceName: name),
        emptyActionTitle: "看全部", emptyAction: .clearFilter)
    case .emptyLibrary:
      return Decision(
        scopeSourceID: activeScope, bannerText: bannerText, bannerActionTitle: bannerActionTitle,
        emptyKind: .emptyLibrary,
        emptyTitle: "把音乐带进来",
        emptyMessage:
          "文件 App 里的本地、iCloud Drive 与网盘文件都能导入；也可以连接自己的 NAS、WebDAV 或 Plex。",
        emptyActionTitle: "导入文件", emptyAction: .importFiles)
    }
  }
}
