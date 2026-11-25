// 首页编排规则的单测：不需要模拟器，swiftc 直接跑。
//   swiftc ios/Awake/Editorial.swift Tools/verify_editorial.swift -o /tmp/verify-editorial
//   /tmp/verify-editorial
import Foundation

@main
struct VerifyEditorial {
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

    let now = ISO8601DateFormatter().date(from: "2026-11-25T00:00:00Z")!
    func track(
      _ id: String, artist: String = "A", album: String = "album", duration: Double = 200,
      favorite: Bool = false, addedDaysAgo: Int? = nil, listened: Double = 0
    ) -> Editorial.Track {
      Editorial.Track(
        id: id, title: id, artist: artist, album: album,
        duration: duration, favorite: favorite,
        addedAt: addedDaysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) },
        listenedSeconds: listened)
    }

    check(Editorial.pick([]) == nil, "空库没有今日精选")
    check(Editorial.collections([]).isEmpty, "空库没有专题")
    check(Editorial.collections([track("a"), track("b")]).isEmpty, "不足 3 首不硬凑专题")

    let favPick = Editorial.pick([
      track("fav", favorite: true, addedDaysAgo: 10),
      track("new", addedDaysAgo: 1),
    ], now: now)
    check(favPick?.trackID == "fav", "收藏未评测优先于新加入", favPick?.trackID ?? "nil")
    check(favPick?.reason.contains("收下了") == true, "收藏未评测说得出理由", favPick?.reason ?? "")

    let recentPick = Editorial.pick([
      track("old", addedDaysAgo: 40),
      track("new", addedDaysAgo: 1),
      track("older", addedDaysAgo: 90),
    ], now: now)
    check(recentPick?.trackID == "new", "没有收藏未评测时先推新加入", recentPick?.trackID ?? "nil")
    check(recentPick?.reason.contains("最近 14 天") == true, "新加入说得出理由", recentPick?.reason ?? "")

    let artistPick = Editorial.pick([
      track("heard", artist: "X", addedDaysAgo: 60, listened: 300),
      track("unheard", artist: "X", addedDaysAgo: 60),
      track("other", artist: "Y", addedDaysAgo: 60),
    ], now: now)
    check(artistPick?.trackID == "unheard", "常听艺人里没评过的那首", artistPick?.trackID ?? "nil")
    check(artistPick?.reason.contains("评测过 X") == true, "同艺人理由带名字", artistPick?.reason ?? "")

    let fallback = Editorial.pick([track("first")], now: now)
    check(fallback?.trackID == "first", "都没有时回落到第一首", fallback?.trackID ?? "nil")

    let many = [
      track("a", duration: 300), track("b", duration: 300), track("c", duration: 300),
      track("d", duration: 100), track("e", duration: 100), track("f", duration: 60),
    ]
    let themes = Editorial.collections(many, now: now)
    let ids = themes.map(\.id)
    check(ids.contains("unplayed"), "有还没评测的专题", ids.joined(separator: ","))
    check(ids.contains("longform"), "有长曲专题", ids.joined(separator: ","))
    check(ids.contains("commute"), "有通勤专题", ids.joined(separator: ","))
    let commute = themes.first { $0.id == "commute" }
    let commuteSeconds = (commute?.trackIDs ?? []).compactMap { id in
      many.first { $0.id == id }?.duration
    }.reduce(0, +)
    check(commuteSeconds >= 1080, "通勤专题至少凑到 18 分钟", "\(Int(commuteSeconds)) 秒")
    check((commute?.trackIDs.count ?? 0) >= 3, "通勤专题至少 3 首", "\(commute?.trackIDs.count ?? 0)")

    let artistTheme = Editorial.collections([
      track("1", artist: "Solo"), track("2", artist: "Solo"), track("3", artist: "Solo"),
      track("4", artist: "Other"),
    ], now: now)
    check(artistTheme.contains { $0.id == "artist" && $0.title == "Solo" }, "同艺人专题", artistTheme.map(\.title).joined(separator: ","))

    let favorites = Editorial.collections([
      track("1", favorite: true), track("2", favorite: true), track("3", favorite: true),
    ], now: now)
    check(favorites.contains { $0.id == "favorites" }, "收藏专题", favorites.map(\.id).joined(separator: ","))

    let albumTheme = Editorial.collections([
      track("1", album: "Same"), track("2", album: "Same"), track("3", album: "Same"),
      track("4", album: "Other"),
    ], now: now)
    check(
      albumTheme.contains { $0.id == "album" && $0.title == "Same" }, "同专辑专题",
      albumTheme.map(\.title).joined(separator: ","))

    // 没有播放次数，就没有资格说「你还没听过」。文案只准说评测。
    let reasons = [favPick?.reason, recentPick?.reason, artistPick?.reason, fallback?.reason]
      .compactMap { $0 }
    check(
      !reasons.contains { $0.contains("还没听过") || $0.contains("没听过") },
      "文案不说没有证据的「没听过」", reasons.joined(separator: " / "))

    if failures == 0 {
      print("PASS 编排自检 \(checks)/\(checks)")
      exit(0)
    }
    print("FAIL 编排自检 \(checks - failures)/\(checks)")
    exit(1)
  }
}
