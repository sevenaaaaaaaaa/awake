// 「添加音乐 · 已连接」三种文案的单元级验证。
//
// 由 Tools/verify_ios_add_source_entry.sh 调用：
//   swiftc ios/Awake/AddSourceCopy.swift Tools/verify_add_source_copy.swift -o /tmp/verify-copy
//   /tmp/verify-copy
//
// 为什么单独编：本机 Xcode 27 的模拟器测试 runner 起不来（见 Diagnostics.swift），
// 但文案是纯函数，不需要模拟器。这段断言 2 秒内跑完，且读的就是 App 用的同一份代码。
import Foundation

@main
struct VerifyAddSourceCopy {
  static func main() {
    var failures: [String] = []
    var checks = 0

    func check(_ condition: Bool, _ label: String, _ actual: String) {
      checks += 1
      if condition {
        print("PASS \(label)")
      } else {
        failures.append(label)
        print("FAIL \(label) -> \(actual)")
      }
    }

    let three = AddSourceCopy.statusLine(kindName: "Plex", count: 3)
    check(three.contains("Plex · 3 首"), "有曲目：类型与数量", three)
    check(three.contains("点这里进曲库"), "有曲目：说清点击结果", three)

    let zero = AddSourceCopy.statusLine(kindName: "Plex", count: 0)
    check(zero.contains("还没有曲目"), "0 首：说清现状", zero)
    check(zero.contains("刷新"), "0 首：给出下一步", zero)

    let inSheet = AddSourceCopy.failureInSheet(reason: "401 Not Authorized")
    check(inSheet.hasPrefix("没有加入："), "失败：弹窗内写「没有加入」", inSheet)

    let outside = AddSourceCopy.failureOutside(name: "PlexE2E", reason: "401")
    check(outside.contains("「PlexE2E」没有加入："), "失败：弹窗之外带来源名", outside)

    let unnamed = AddSourceCopy.failureOutside(name: "   ", reason: "超时")
    check(unnamed.contains("这个来源没有加入："), "失败：空名字有兜底", unnamed)

    let empty = AddSourceCopy.emptyLibraryMessage(sourceName: "PlexE2E")
    check(empty.contains("还没有曲目"), "0 首空态：说清为什么空", empty)
    check(empty.contains("刷新"), "0 首空态：给出下一步", empty)

    if failures.isEmpty {
      print("PASS 文案自检 \(checks)/\(checks)")
      exit(0)
    }
    print("FAIL 文案自检 \(checks - failures.count)/\(checks)：\(failures.joined(separator: "；"))")
    exit(1)
  }
}
