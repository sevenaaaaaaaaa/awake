import SwiftUI
import AppKit
import AwakeCore

// MARK: - Sources

struct SourcesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var kind: SourceKind = .local
    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""

    private let kinds: [(SourceKind, String, String)] = [
        (.local, "本地", "folder"),
        (.smb, "NAS / SMB", "externaldrive.connected.to.line.below"),
        (.webdav, "WebDAV", "globe"),
        (.plex, "Plex", "play.tv")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(model.palette.primary.opacity(0.18)).frame(width: 34, height: 34)
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(model.palette.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("音乐来源")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("本地 · SMB · WebDAV · Plex，全部增量索引")
                        .font(.system(size: 10))
                        .foregroundStyle(AwakeTheme.tertiaryText)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(PillButtonStyle(filled: true))
            }
            .padding(22)

            Divider().overlay(AwakeTheme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    connectForm
                    existingSources
                }
                .padding(22)
            }
        }
        .frame(width: 780, height: 540)
        .background(AwakeTheme.background)
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(kinds, id: \.0) { item in
                    Button {
                        kind = item.0
                        url = ""
                        name = ""
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.2)
                                .font(.system(size: 10))
                            Text(item.1)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(kind == item.0 ? Color.white : Color.white.opacity(0.06))
                        )
                        .foregroundStyle(kind == item.0 ? Color.black : Color.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            if kind == .local {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .foregroundStyle(model.palette.secondary)
                    Text("选择一个音乐文件夹。Awake 会递归扫描并记住增量。")
                        .font(.system(size: 11))
                        .foregroundStyle(AwakeTheme.secondaryText)
                    Spacer()
                    Button("选择文件夹") {
                        model.addLocalFolder()
                        dismiss()
                    }
                    .buttonStyle(PillButtonStyle(filled: true))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
            } else {
                VStack(spacing: 10) {
                    field("名称", text: $name, placeholder: kind == .plex ? "家里的 Plex" : "我的 NAS 音乐")
                    field(kind == .plex ? "服务器地址" : "地址",
                          text: $url,
                          placeholder: kind == .smb ? "smb://192.168.1.10/Music" : (kind == .plex ? "http://192.168.1.10:32400" : "https://nas.local/music"))
                    if kind == .smb || kind == .webdav {
                        HStack(spacing: 10) {
                            field("用户名", text: $username, placeholder: "可选")
                            secureField("密码", text: $password, placeholder: "存入钥匙串")
                        }
                    }
                    if kind == .plex {
                        field("X-Plex-Token", text: $token, placeholder: "Plex 账户设置里的 token")
                    }
                }

                HStack {
                    Text(kind == .smb ? "SMB 会自动挂载到系统，无需提前在 Finder 连接。" : "凭据只保存在本机钥匙串。")
                        .font(.system(size: 9))
                        .foregroundStyle(AwakeTheme.tertiaryText)
                    Spacer()
                    Button("连接并扫描") {
                        let displayName = name.trimmed.isEmpty ? kind.title : name.trimmed
                        model.addSource(kind: kind,
                                        name: displayName,
                                        url: url,
                                        username: username,
                                        password: password,
                                        token: token)
                        dismiss()
                    }
                    .buttonStyle(PillButtonStyle(filled: true))
                    .disabled(url.trimmed.isEmpty)
                    .opacity(url.trimmed.isEmpty ? 0.4 : 1)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1))
    }

    private var existingSources: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已连接")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button("重新扫描全部") { model.rescanAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(model.palette.secondary)
            }

            if model.library.sources.isEmpty {
                Text("还没有来源。")
                    .font(.system(size: 11))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                    .padding(.vertical, 8)
            }

            ForEach(model.library.sources) { source in
                HStack(spacing: 12) {
                    Image(systemName: source.kind.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(model.palette.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.05)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                        Text(source.url)
                            .font(.system(size: 9.5))
                            .foregroundStyle(AwakeTheme.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(source.trackCount) 首")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(AwakeTheme.secondaryText)
                    Button("扫描") {
                        Task { await model.library.scan(source) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(model.palette.secondary)
                    Button {
                        model.removeSource(source.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(AwakeTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.025)))
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AwakeTheme.tertiaryText)
                .frame(width: 88, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.28)))
        }
    }

    private func secureField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AwakeTheme.tertiaryText)
                .frame(width: 44, alignment: .leading)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.28)))
        }
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(PillButtonStyle(filled: true))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            Divider().overlay(AwakeTheme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    group("声音", [
                        ("比特完美输出", "设备采样率与曲目一致时自动切换，跳过系统混音", binding(\.bitPerfect)),
                        ("独占模式", "独占音频设备，避免其他 App 抢占", binding(\.exclusiveMode)),
                        ("无缝播放", "同格式曲目预排队，消除间隙", binding(\.gapless))
                    ])
                    group("自动化", [
                        ("自动 EQ", "按耳机与曲目频谱实时生成校正曲线", binding(\.autoEQ)),
                        ("自动匹配封面", "音频内嵌 → 同目录 → MusicBrainz → iTunes", binding(\.autoFetchArtwork)),
                        ("自动匹配歌词", "内嵌 → .lrc → LRCLIB", binding(\.autoFetchLyrics)),
                        ("自动翻译", "逐句翻译到目标语言", binding(\.translationEnabled))
                    ])
                    translationPicker
                    group("曲库", [
                        ("启动时扫描", "打开 Awake 时增量刷新所有来源", binding(\.scanOnLaunch)),
                        ("显示频谱", "歌词舞台上显示实时频谱", binding(\.showVisualizer))
                    ])
                    updateSection
                }
                .padding(22)
            }
        }
        .frame(width: 640, height: 700)
        .background(AwakeTheme.background)
        .onChange(of: model.settings.settings.bitPerfect) { _, value in
            model.engine.setBitPerfectPreferred(value)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AwakeSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings.settings[keyPath: keyPath] },
            set: {
                model.settings.settings[keyPath: keyPath] = $0
                if keyPath == \.exclusiveMode {
                    model.engine.setExclusive($0)
                }
            }
        )
    }

    private func group(_ title: String, _ rows: [(String, String, Binding<Bool>)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(AwakeTheme.tertiaryText)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                            Text(row.1)
                                .font(.system(size: 9.5))
                                .foregroundStyle(AwakeTheme.tertiaryText)
                        }
                        Spacer()
                        Toggle("", isOn: row.2)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .tint(model.palette.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    if index < rows.count - 1 {
                        Divider().overlay(AwakeTheme.hairline).padding(.leading, 14)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
        }
    }

    private var translationPicker: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("翻译目标语言")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text("歌词舞台上逐句显示")
                    .font(.system(size: 9.5))
                    .foregroundStyle(AwakeTheme.tertiaryText)
            }
            Spacer()
            Picker("", selection: Binding(get: { model.settings.settings.translationTarget },
                                          set: { model.settings.settings.translationTarget = $0 })) {
                Text("简体中文").tag("zh-CN")
                Text("繁體中文").tag("zh-TW")
                Text("English").tag("en")
                Text("日本語").tag("ja")
                Text("한국어").tag("ko")
            }
            .labelsHidden()
            .frame(width: 150)
            .tint(model.palette.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("关于与更新")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(AwakeTheme.tertiaryText)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Awake \(model.appVersion)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(updateStatusLine)
                            .font(.system(size: 9.5))
                            .foregroundStyle(AwakeTheme.tertiaryText)
                    }
                    Spacer()
                    Button(model.hasUpdate ? "安装更新" : "检查更新") { model.presentUpdates() }
                        .buttonStyle(PillButtonStyle(filled: model.hasUpdate))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().overlay(AwakeTheme.hairline).padding(.leading, 14)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动检查更新")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        Text("每天最多一次，仅查询 GitHub Releases")
                            .font(.system(size: 9.5))
                            .foregroundStyle(AwakeTheme.tertiaryText)
                    }
                    Spacer()
                    Toggle("", isOn: binding(\.autoCheckUpdates))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(model.palette.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)

                Divider().overlay(AwakeTheme.hairline).padding(.leading, 14)

                HStack {
                    Link("GitHub 仓库", destination: URL(string: "https://github.com/sevenaaaaaaaaa/awake")!)
                    Spacer()
                    Link("发行说明", destination: UpdateChannel.releasePage)
                    Text("·")
                        .foregroundStyle(AwakeTheme.tertiaryText)
                    Text("build \(model.buildNumber)")
                        .font(.system(size: 9.5, design: .monospaced))
                }
                .font(.system(size: 10))
                .foregroundStyle(AwakeTheme.tertiaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
        }
    }

    private var updateStatusLine: String {
        switch model.updatePhase {
        case .idle:
            return "Apple Silicon · macOS 14+"
        case .checking:
            return "正在检查更新…"
        case .upToDate(let version):
            return "已是最新（\(version)）"
        case .available(let info):
            return "可更新到 \(info.version)（当前 \(info.currentVersion)）"
        case .downloading(let progress, let version):
            return "正在下载 \(version) · \(Int(progress * 100))%"
        case .installing(let version):
            return "正在安装 \(version)…"
        case .failed:
            return "上次检查失败，可重试"
        }
    }
}

// MARK: - Command palette

struct CommandPaletteView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @FocusState private var focused: Bool

    private var tracks: [Track] {
        if query.trimmed.isEmpty {
            return Array(model.library.recentlyPlayed.prefix(6))
        }
        return Array(model.library.search(query).prefix(8))
    }

    private var albums: [Album] {
        guard !query.trimmed.isEmpty else { return [] }
        return Array(model.library.albums.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.artist.localizedCaseInsensitiveContains(query)
        }.prefix(4))
    }

    private var artists: [String] {
        guard !query.trimmed.isEmpty else { return [] }
        return Array(model.library.artists.map(\.name).filter {
            $0.localizedCaseInsensitiveContains(query)
        }.prefix(4))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(AwakeTheme.secondaryText)
                    TextField("搜索歌曲、专辑、艺人，或输入命令", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focused)
                        .onSubmit { playFirst() }
                    Text("esc")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(AwakeTheme.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07)))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)

                Divider().overlay(AwakeTheme.hairline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if query.trimmed.isEmpty {
                            actionRows
                            if !tracks.isEmpty {
                                label("最近播放")
                                ForEach(tracks) { trackRow($0) }
                            }
                        } else {
                            if !tracks.isEmpty {
                                label("歌曲")
                                ForEach(tracks) { trackRow($0) }
                            }
                            if !albums.isEmpty {
                                label("专辑")
                                ForEach(albums) { album in
                                    paletteRow(icon: "square.stack",
                                               title: album.title,
                                               subtitle: album.artist,
                                               badge: "\(album.tracks.count) 首") {
                                        model.selectedAlbum = album
                                        model.destination = .albums
                                        close()
                                    }
                                }
                            }
                            if !artists.isEmpty {
                                label("艺人")
                                ForEach(artists, id: \.self) { artist in
                                    paletteRow(icon: "music.mic", title: artist, subtitle: "", badge: "") {
                                        model.selectedArtist = artist
                                        close()
                                    }
                                }
                            }
                            if tracks.isEmpty && albums.isEmpty && artists.isEmpty {
                                Text("没有找到匹配项")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AwakeTheme.tertiaryText)
                                    .padding(20)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 380)
            }
            .frame(width: 620)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.055, green: 0.055, blue: 0.070))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 40, y: 20)
            .padding(.top, 120)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear { focused = true }
        .onExitCommand { close() }
    }

    private var actionRows: some View {
        VStack(spacing: 4) {
            paletteRow(icon: model.isPlaying ? "pause.fill" : "play.fill",
                       title: model.isPlaying ? "暂停" : "播放",
                       subtitle: "Space",
                       badge: "") {
                model.togglePlayPause()
                close()
            }
            paletteRow(icon: "shuffle", title: "随机播放全部", subtitle: "⌘⇧S", badge: "") {
                model.shuffleAll()
                close()
            }
            paletteRow(icon: "slider.vertical.3", title: "自动 EQ", subtitle: "⌘E", badge: "") {
                model.showEQ = true
                close()
            }
            paletteRow(icon: "externaldrive", title: "音乐来源", subtitle: "⌘,", badge: "") {
                model.showSources = true
                close()
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(1.0)
            .foregroundStyle(AwakeTheme.tertiaryText)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func trackRow(_ track: Track) -> some View {
        paletteRow(icon: "music.note",
                   title: track.title,
                   subtitle: track.artist + " · " + track.album,
                   badge: track.qualityLabel) {
            model.play(track, context: tracks, title: "搜索")
            close()
        }
    }

    private func paletteRow(icon: String, title: String, subtitle: String, badge: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(model.palette.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(AwakeTheme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(AwakeTheme.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PaletteRowStyle())
    }

    private func playFirst() {
        if let first = tracks.first {
            model.play(first, context: tracks, title: "搜索")
        } else if let album = albums.first {
            model.playAlbum(album)
        } else if let artist = artists.first {
            model.playArtist(artist)
        }
        close()
    }

    private func close() {
        model.showPalette = false
        query = ""
    }
}

struct PaletteRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Color.white.opacity(0.10) : Color.clear)
            )
    }
}
