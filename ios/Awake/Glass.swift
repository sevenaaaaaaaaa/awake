import SwiftUI

/// 液态玻璃表面。
///
/// iOS 26 起用系统 `glassEffect`：折射、边缘高光、随内容实时模糊都由系统渲染，
/// 自己画不出同一套光学行为。更早的系统退回材质 + 一道 0.5pt 结构线——
/// 那一道线是必要的：只有模糊没有边，卡片会糊进背景，读不出"这是一块"。
///
/// `enabled` 为 false 时原样返回，皮肤不是 glass 就不该出现玻璃。
struct GlassSurface<S: Shape>: ViewModifier {
  var enabled: Bool
  var shape: S
  var interactive = false

  func body(content: Content) -> some View {
    if #available(iOS 26.0, *), enabled {
      content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    } else if enabled {
      content
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    } else {
      content
    }
  }
}

extension View {
  /// `shape` 决定玻璃的轮廓：胶囊、圆角矩形、圆。
  func glassSurface<S: Shape>(
    _ shape: S, enabled: Bool = true, interactive: Bool = false
  ) -> some View {
    modifier(GlassSurface(enabled: enabled, shape: shape, interactive: interactive))
  }
}

/// 列表/表单的行背景。系统行默认不透明，玻璃皮肤下要逐行换掉——
/// glassEffect 作用不到「一个分区的所有行」，只能用 listRowBackground 一层层铺。
struct GlassRow: ViewModifier {
  @EnvironmentObject var store: MobileStore
  func body(content: Content) -> some View {
    if store.state.skin.mode == "glass" {
      content.listRowBackground(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(.ultraThinMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(Color.white.opacity(0.08), lineWidth: 0.5))
          .padding(.vertical, 1))
    } else {
      content
    }
  }
}
extension View {
  func glassRows() -> some View { modifier(GlassRow()) }
}
