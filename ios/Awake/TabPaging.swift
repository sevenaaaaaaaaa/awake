import CoreGraphics
import Foundation

/// 「横滑换 tab」的判定规则。
///
/// 之所以抽成纯函数：手势本身没法在模拟器里注入验证，但**规则可以**。
/// 这台机器起不来 XCTest，这个文件会被 `Tools/run_library_import_harness.sh`
/// 一起编译并跑断言，至少保证「什么时候该翻、什么时候不该翻」不是靠肉眼。
enum TabPaging {
  /// 触发翻页所需的最小水平位移。
  static let minimumDistance: CGFloat = 80
  /// 水平位移至少是垂直位移的多少倍，才算横滑。
  static let horizontalRatio: CGFloat = 2
  /// 屏幕左右留给系统返回手势的宽度。
  static let edgeInset: CGFloat = 24

  /// 返回要切到的 tab；nil 表示这次手势不翻页。
  ///
  /// - 向左滑（dx < 0）= 下一个；向右滑 = 上一个；到头不循环。
  /// - 起手在屏幕边缘、或在横向控件（chip / 滑杆 / 曲线）里，不翻页。
  static func nextTab(
    current: Int, count: Int, translation: CGSize, start: CGPoint, width: CGFloat,
    exempt: [CGRect]
  ) -> Int? {
    guard count > 0, (0..<count).contains(current) else { return nil }
    let dx = translation.width
    let dy = translation.height
    guard abs(dx) >= minimumDistance else { return nil }
    guard abs(dx) >= abs(dy) * horizontalRatio else { return nil }
    guard start.x > edgeInset, start.x < width - edgeInset else { return nil }
    guard !exempt.contains(where: { $0.contains(start) }) else { return nil }
    let next = dx < 0 ? current + 1 : current - 1
    guard (0..<count).contains(next), next != current else { return nil }
    return next
  }
}
