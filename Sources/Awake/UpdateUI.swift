import SwiftUI
import AppKit
import AwakeCore

// MARK: - State

enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate(version: String)
    case available(UpdateInfo)
    case downloading(progress: Double, version: String)
    case installing(version: String)
    case failed(String)
}

// MARK: - Sheet

struct UpdateSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AwakeTheme.hairline)
            ScrollView {
                content
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(AwakeTheme.hairline)
            footer
        }
        .frame(width: 560, height: 470)
        .background(AwakeTheme.background)
        .onAppear { model.ensureUpdateCheck() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(model.palette.primary.opacity(0.18)).frame(width: 36, height: 36)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.palette.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("软件更新")
                    .font(.system(size: AwakeType.titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                Text("当前版本 \(model.appVersion)（\(model.buildNumber)）")
                    .font(.system(size: AwakeType.metaSize, design: .monospaced))
                    .foregroundStyle(AwakeTheme.tertiaryText)
            }
            Spacer()
            Button("关闭") { dismiss() }
                .buttonStyle(PillButtonStyle(filled: true))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch model.updatePhase {
        case .idle, .checking:
            stateBlock(icon: "arrow.triangle.2.circlepath",
                       title: "正在检查更新…",
                       detail: nil,
                       spinner: true)

        case .upToDate(let version):
            stateBlock(icon: "checkmark.seal.fill",
                       title: "已是最新版本",
                       detail: "GitHub 上最新为 \(version)。",
                       spinner: false)

        case .available(let info):
            availableContent(info)

        case .downloading(let progress, let version):
            VStack(alignment: .leading, spacing: 14) {
                stateBlock(icon: "arrow.down.circle",
                           title: "正在下载 \(version)…",
                           detail: nil,
                           spinner: true)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(model.palette.secondary)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: AwakeType.metaSize, design: .monospaced))
                    .foregroundStyle(AwakeTheme.tertiaryText)
            }

        case .installing(let version):
            stateBlock(icon: "shippingbox.fill",
                       title: "正在安装 \(version)…",
                       detail: "完成后会自动重新打开。",
                       spinner: true)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                stateBlock(icon: "exclamationmark.triangle.fill",
                           title: "更新未完成",
                           detail: message,
                           spinner: false)
                Link("打开 GitHub Releases 手动下载", destination: UpdateChannel.releasePage)
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(model.palette.secondary)
            }
        }
    }

    private func availableContent(_ info: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(info.currentVersion)
                    .font(.system(size: AwakeType.bodySize, design: .monospaced))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                Text(info.version)
                    .font(.system(size: AwakeType.bodySize, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("新版本")
                    .font(.system(size: AwakeType.metaSize, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(model.palette.primary.opacity(0.25)))
                    .foregroundStyle(model.palette.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("更新说明")
                    .font(.system(size: AwakeType.metaSize, weight: .semibold))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                Text(info.notes)
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.035)))

            Text("\(info.assetName)（\(byteText(info.assetSize))）")
                .font(.system(size: AwakeType.metaSize, design: .monospaced))
                .foregroundStyle(AwakeTheme.tertiaryText)
        }
    }

    private func stateBlock(icon: String, title: String, detail: String?, spinner: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(model.palette.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: AwakeType.bodySize, weight: .semibold))
                    .foregroundStyle(.white)
                if let detail {
                    Text(detail)
                        .font(.system(size: AwakeType.metaSize))
                        .foregroundStyle(AwakeTheme.tertiaryText)
                        .lineSpacing(3)
                }
            }
            Spacer()
            if spinner {
                ProgressView().controlSize(.small).tint(model.palette.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            switch model.updatePhase {
            case .available:
                Button("稍后") { dismiss() }
                    .buttonStyle(PillButtonStyle(filled: false))
                Button("立即更新") { model.installAvailableUpdate() }
                    .buttonStyle(PillButtonStyle(filled: true))

            case .failed:
                Button("关闭") { dismiss() }
                    .buttonStyle(PillButtonStyle(filled: false))
                Button("重试") { Task { await model.checkForUpdates(force: true) } }
                    .buttonStyle(PillButtonStyle(filled: true))

            case .upToDate:
                Button("完成") { dismiss() }
                    .buttonStyle(PillButtonStyle(filled: false))
                Button("重新检查") { Task { await model.checkForUpdates(force: true) } }
                    .buttonStyle(PillButtonStyle(filled: true))

            case .downloading, .installing:
                Text("请保持 Awake 打开")
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(AwakeTheme.tertiaryText)

            default:
                Button("完成") { dismiss() }
                    .buttonStyle(PillButtonStyle(filled: false))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
