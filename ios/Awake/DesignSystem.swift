import SwiftUI

/// Awake iOS 的设计系统。
///
/// 之前每个页面各写各的：17 种字号、11 种圆角、20 种间距、164 段说明小字。
/// 这个文件把「间距 / 圆角 / 字号 / 动效」收成一套刻度，并把最常用的五种块
/// （分区标题、入口行、说明、卡片、空态）固定下来。新页面只用这里的组件，
/// 不再自己写 `.font(.system(size: 13))`。
enum DS {
  /// 间距只用 4 的倍数。页面内边距 20、区块间距 24、行内 12。
  enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    /// 页面左右边距：全 App 统一一个值。
    static let page: CGFloat = 20
  }

  /// 圆角三档：小控件 8、行与卡 12、大面板 16。
  enum Radius {
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
  }

  /// 动效只允许两档；减弱动效时调用方传 nil。
  enum Motion {
    static let quick: Double = 0.18
    static let standard: Double = 0.26
  }

  /// 点击目标：Apple HIG 44pt。低于这个值的可点区域不允许出现。
  static let hit: CGFloat = 44

  /// 结构线：一条 0.5pt，不用阴影做分层。
  static func hairline(_ skin: Skin) -> Color {
    Color(hex: skin.colors.border).opacity(0.6)
  }
}

// MARK: - 分区标题

/// 一个区块的标题：小号、宽字距、可选右侧状态。替代「裸 Section + 大段说明」。
struct AwakeSectionTitle: View {
  @EnvironmentObject var store: MobileStore
  var title: String
  var status: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(.footnote.weight(.semibold))
        .tracking(0.6)
        .foregroundStyle(Color(hex: store.state.skin.colors.muted))
      Spacer(minLength: 0)
      if let status, !status.isEmpty {
        Text(status)
          .font(.caption.monospacedDigit())
          .foregroundStyle(Color(hex: store.state.skin.colors.muted).opacity(0.8))
          .lineLimit(1)
      }
    }
    .padding(.bottom, DS.Space.xs)
    .accessibilityAddTraits(.isHeader)
  }
}

// MARK: - 入口行

/// 全 App 唯一的入口行：图标 + 标题 + 一句说明 + 右侧状态 / 箭头。
/// 所有「点进去」的东西都用它，不再各页自己拼 Label / HStack。
struct AwakeRow: View {
  @EnvironmentObject var store: MobileStore
  var icon: String
  var title: String
  var detail: String?
  var status: String?
  var chevron = true
  var destructive = false

  private var tint: Color {
    if destructive { return Color(hex: "#e0736d") }
    return Color(hex: store.state.skin.colors.text)
  }

  var body: some View {
    HStack(spacing: DS.Space.s) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .regular))
        .foregroundStyle(tint.opacity(0.82))
        .frame(width: 28, height: 28)
        .background(
          RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
            .fill(Color(hex: store.state.skin.colors.raised)))
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline)
          .foregroundStyle(tint)
          .lineLimit(1)
        if let detail, !detail.isEmpty {
          Text(detail)
            .font(.caption)
            .foregroundStyle(Color(hex: store.state.skin.colors.muted))
            .lineLimit(2)
        }
      }
      Spacer(minLength: DS.Space.xs)
      if let status, !status.isEmpty {
        Text(status)
          .font(.caption.monospacedDigit())
          .foregroundStyle(Color(hex: store.state.skin.colors.muted))
          .lineLimit(1)
      }
      if chevron {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(Color(hex: store.state.skin.colors.muted).opacity(0.5))
      }
    }
    .frame(minHeight: DS.hit)
    .contentShape(Rectangle())
  }
}

// MARK: - 说明（默认折叠）

/// 长说明不再铺在页面上：默认只显示一行「说明」，点开才展开。
/// 这是把 164 段小字从视觉里拿掉的方式——信息还在，但不再抢注意力。
struct AwakeNote: View {
  @EnvironmentObject var store: MobileStore
  var title = "说明"
  var text: String
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      Button {
        withAnimation(.easeInOut(duration: DS.Motion.quick)) { expanded.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "info.circle")
            .font(.caption2)
          Text(expanded ? "收起" : title)
            .font(.caption.weight(.medium))
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .foregroundStyle(Color(hex: store.state.skin.colors.muted))
        .frame(minHeight: DS.hit, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if expanded {
        Text(text)
          .font(.caption)
          .foregroundStyle(Color(hex: store.state.skin.colors.muted))
          .fixedSize(horizontal: false, vertical: true)
          .transition(.opacity)
      }
    }
  }
}

// MARK: - 卡片

struct AwakeCard<Content: View>: View {
  @EnvironmentObject var store: MobileStore
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(DS.Space.m)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
          .fill(Color(hex: store.state.skin.colors.surface)))
      .overlay(
        RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
          .stroke(Color(hex: store.state.skin.colors.border), lineWidth: 0.6))
  }
}

// MARK: - 空态

/// 空态只给一个主行动。原来一页里同时给「导入」「连接服务器」「去设置」三条路，
/// 用户不知道先做哪个。
struct AwakeEmptyState: View {
  @EnvironmentObject var store: MobileStore
  var icon: String
  var title: String
  var message: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: DS.Space.s) {
      Image(systemName: icon)
        .font(.system(size: 30, weight: .light))
        .foregroundStyle(Color(hex: store.state.skin.colors.muted))
      Text(title)
        .font(.headline)
        .foregroundStyle(Color(hex: store.state.skin.colors.text))
        .multilineTextAlignment(.center)
      Text(message)
        .font(.footnote)
        .foregroundStyle(Color(hex: store.state.skin.colors.muted))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if let actionTitle, let action {
        AwakePrimaryButton(title: actionTitle, action: action)
          .padding(.top, DS.Space.xs)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, DS.Space.xl)
  }
}

// MARK: - 按钮

/// 主按钮：一屏只允许一个。样式固定在组件里，ButtonStyle 拿不到 store，不能在里面读皮肤。
struct AwakePrimaryButton: View {
  @EnvironmentObject var store: MobileStore
  var title: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color(hex: store.state.skin.colors.bg))
        .padding(.horizontal, DS.Space.m)
        .frame(minHeight: DS.hit)
        .background(Capsule().fill(Color(hex: store.state.skin.colors.text)))
    }
    .buttonStyle(.plain)
  }
}

struct AwakeSecondaryButton: View {
  @EnvironmentObject var store: MobileStore
  var title: String
  var systemImage: String?
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let systemImage {
          Image(systemName: systemImage).font(.footnote)
        }
        Text(title).font(.subheadline.weight(.medium))
      }
      .foregroundStyle(Color(hex: store.state.skin.colors.text))
      .padding(.horizontal, DS.Space.m)
      .frame(minHeight: DS.hit)
      .background(Capsule().fill(Color(hex: store.state.skin.colors.surface)))
      .overlay(Capsule().stroke(Color(hex: store.state.skin.colors.border), lineWidth: 0.6))
    }
    .buttonStyle(.plain)
  }
}

// MARK: - 翻页手势的豁免区

/// 横向控件（来源 chip、滑杆、曲线编辑器）自己吃横滑；
/// 这些区域上报全局坐标，RootView 的翻页手势不从这里起手。
struct TabSwipeExemptKey: PreferenceKey {
  static var defaultValue: [CGRect] = []
  static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
    value.append(contentsOf: nextValue())
  }
}

extension View {
  func tabSwipeExempt() -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: TabSwipeExemptKey.self, value: [proxy.frame(in: .global)])
      })
  }
}
