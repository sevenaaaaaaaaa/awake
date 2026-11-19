import SwiftUI
import UniformTypeIdentifiers

/// 一个页面只挂一个 `.fileImporter`，用状态决定「这次要选什么」。
///
/// iOS 上把多个 `.fileImporter` 分别挂在同一页面的不同按钮上时，SwiftUI 会让它们互相抢
/// presentation：表现为**点了没反应**，或者第一次能用、第二次沉默。
/// 0.7.3 曾用「每个按钮各挂一个」绕过一次，之后又长回多挂的状态，同一种症状复发。
/// 这个类型把形状固定住，新的导入入口只加 `ImportTarget` 的 case，不再加选择器。
///
/// 注意：`allowsMultipleSelection` 必须在编译期是常量（SwiftUI 有两套重载），
/// 所以统一用 `true`，单选的场景取数组第一项。
enum ImportTarget: String, Identifiable {
  case audioFiles
  case audioFolder
  case skin
  case backup

  var id: String { rawValue }

  var types: [UTType] {
    switch self {
    case .audioFiles:
      // 不要用 .audio 过滤：iOS 只认系统已声明的音频 UTI，FLAC / ALAC / APE / DSF
      // 等在「文件」里常被归成 public.data，选它时直接灰掉——用户看到的就是
      // 「本地文件根本选不了」。这里放行全部普通文件，扩展名由导入逻辑自己判断。
      return [.data]
    case .audioFolder: return [.folder]
    case .skin: return [.plainText, .json, .text]
    case .backup: return [.awakeBackupFile, .json]
    }
  }
}

private struct SingleFileImporter: ViewModifier {
  @Binding var target: ImportTarget?
  let onPick: ([URL], ImportTarget) -> Void
  let onFail: (Error, ImportTarget) -> Void

  func body(content: Content) -> some View {
    content.fileImporter(
      isPresented: Binding(
        get: { target != nil },
        set: { presented in if !presented { target = nil } }
      ),
      allowedContentTypes: target?.types ?? [.data],
      allowsMultipleSelection: true
    ) { result in
      guard let pick = target else { return }
      target = nil
      switch result {
      case .success(let urls): onPick(urls, pick)
      case .failure(let error): onFail(error, pick)
      }
    }
  }
}

extension View {
  func importPicker(
    _ target: Binding<ImportTarget?>,
    onPick: @escaping ([URL], ImportTarget) -> Void,
    onFail: @escaping (Error, ImportTarget) -> Void
  ) -> some View {
    modifier(SingleFileImporter(target: target, onPick: onPick, onFail: onFail))
  }
}
