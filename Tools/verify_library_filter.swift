// 曲库「来源筛选 + 搜索」规则的单测：不需要模拟器，swiftc 直接跑。
//   swiftc ios/Awake/AddSourceCopy.swift ios/Awake/LibraryFilter.swift Tools/verify_library_filter.swift \
//     -o /tmp/verify-library-filter
//   /tmp/verify-library-filter
//
// 覆盖的正是「加了来源，库空了，搜也搜不出」这条真实抱怨的每一个分叉。
import Foundation

@main
struct VerifyLibraryFilter {
  static func main() {
    var checks = 0
    var failures = 0
    func check(_ ok: Bool, _ label: String, _ actual: String = "") {
      checks += 1
      if ok {
        print("PASS \(label)")
      } else {
        failures += 1
        print("FAIL \(label) -> \(actual)")
      }
    }

    // 1. 搜索跨全部来源：点过「只看 Plex」之后搜索，不该窄在 Plex 里。
    let searching = LibraryFilter.decide(
      sourceID: "plex-1", sourceName: "Plex", sourceCount: 3,
      query: "夜曲", totalCount: 120, matchCount: 7)
    check(searching.scopeSourceID == nil, "搜索时忽略来源筛选", "\(String(describing: searching.scopeSourceID))")
    check(searching.emptyKind == .none, "搜索有结果不算空态", "\(searching.emptyKind)")
    check(
      searching.bannerText?.contains("已忽略") == true && searching.bannerText?.contains("Plex") == true,
      "搜索时明说忽略了哪个筛选", searching.bannerText ?? "nil")

    // 2. 只看有曲目的来源：一行可见的「正在只看」，带数量与出口。
    let scoped = LibraryFilter.decide(
      sourceID: "s1", sourceName: "NAS", sourceCount: 42,
      query: "", totalCount: 120, matchCount: 42)
    check(scoped.scopeSourceID == "s1", "无搜索词时按来源过滤", "\(String(describing: scoped.scopeSourceID))")
    check(scoped.bannerText?.contains("正在只看") == true, "只看来源有常显提示", scoped.bannerText ?? "nil")
    check(scoped.bannerText?.contains("42") == true, "提示里带该来源曲数", scoped.bannerText ?? "nil")
    check(scoped.bannerActionTitle == "看全部", "提示里带出口", scoped.bannerActionTitle ?? "nil")

    // 3. 只看 0 首来源：这是「加完源库就空了」的那条路。
    let emptySource = LibraryFilter.decide(
      sourceID: "s2", sourceName: "MusicBee", sourceCount: 0,
      query: "", totalCount: 120, matchCount: 0)
    check(emptySource.emptyKind == .sourceEmpty, "0 首来源是 sourceEmpty", "\(emptySource.emptyKind)")
    check(emptySource.bannerText?.contains("还没有曲目") == true, "提示先说清它空", emptySource.bannerText ?? "nil")
    check(emptySource.emptyAction == .clearFilter, "空态按钮清筛选", "\(emptySource.emptyAction)")
    check(
      emptySource.emptyMessage.contains("设置 → 音乐来源"),
      "空态正文给出刷新路径", emptySource.emptyMessage)

    // 4. 搜索无结果：出口是清除搜索，不是切回来源。
    let noMatch = LibraryFilter.decide(
      sourceID: nil, sourceName: "", sourceCount: 0,
      query: " 不存在 ", totalCount: 120, matchCount: 0)
    check(noMatch.emptyKind == .noMatch, "无匹配是 noMatch", "\(noMatch.emptyKind)")
    check(noMatch.emptyAction == .clearSearch, "无匹配按钮清搜索", "\(noMatch.emptyAction)")
    check(noMatch.emptyMessage.contains("不存在"), "正文带上用户搜的词", noMatch.emptyMessage)

    // 5. 全库空：出口是导入文件。
    let emptyAll = LibraryFilter.decide(
      sourceID: nil, sourceName: "", sourceCount: 0,
      query: "", totalCount: 0, matchCount: 0)
    check(emptyAll.emptyKind == .emptyLibrary, "全库空是 emptyLibrary", "\(emptyAll.emptyKind)")
    check(emptyAll.emptyAction == .importFiles, "全库空按钮导入文件", "\(emptyAll.emptyAction)")
    check(emptyAll.bannerText == nil, "没有筛选时不显示横幅", emptyAll.bannerText ?? "nil")

    // 6. 搜索词只有空格 = 没在搜，筛选照旧生效。
    let blankQuery = LibraryFilter.decide(
      sourceID: "s1", sourceName: "NAS", sourceCount: 5,
      query: "   ", totalCount: 120, matchCount: 5)
    check(blankQuery.scopeSourceID == "s1", "空白搜索词不解除筛选", "\(String(describing: blankQuery.scopeSourceID))")

    // 7. 三种空态互不混用：按钮与出口一一对应。
    check(
      Set([emptyAll.emptyActionTitle, noMatch.emptyActionTitle, emptySource.emptyActionTitle])
        == Set(["导入文件", "清除搜索", "看全部"]),
      "三种空态各有不同的按钮",
      [emptyAll.emptyActionTitle, noMatch.emptyActionTitle, emptySource.emptyActionTitle].joined(separator: ","))

    if failures == 0 {
      print("PASS 筛选规则自检 \(checks)/\(checks)")
      exit(0)
    }
    print("FAIL \(failures)/\(checks) 项未通过")
    exit(1)
  }
}
