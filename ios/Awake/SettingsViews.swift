import SwiftUI
import UniformTypeIdentifiers

/// 设置页顶部：先回答「我现在是什么状态」，再给入口。
///
/// 以前这一页第一屏就是九个分区、二十多行入口，用户看不到自己的曲库有多大、
/// AI 有没有配、缓存占了多少。这里把五个真实数字放在最上面，并且都是现算的。
struct SettingsSummaryCard: View {
  @EnvironmentObject var store: MobileStore
  @State private var cacheBytes: Int64 = 0
  @State private var sizeReady = false

  private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
  }
  private var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
  }
  private var aiConfigured: Bool { !store.state.curatorModel.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("本机曲库")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color(hex: store.state.skin.colors.text))
          Text("iOS \(version) · build \(build)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color(hex: store.state.skin.colors.muted))
        }
        Spacer(minLength: 8)
        Text(store.state.skin.name)
          .font(.caption2.weight(.medium))
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(
            Capsule().fill(Color(hex: store.state.skin.colors.surface)))
          .overlay(
            Capsule().stroke(Color(hex: store.state.skin.colors.border), lineWidth: 0.6))
      }
      HStack(spacing: 0) {
        stat("曲目", "\(store.state.songs.count)")
        stat("歌单", "\(store.state.playlists?.count ?? 0)")
        stat("来源", "\(store.state.sources.count)")
        stat("缓存", sizeReady ? ByteText.short(cacheBytes) : "…")
      }
      HStack(spacing: 6) {
        Circle()
          .fill(
            aiConfigured
              ? Color(hex: store.state.skin.colors.text)
              : Color(hex: store.state.skin.colors.muted).opacity(0.5))
          .frame(width: 5, height: 5)
        Text(aiConfigured ? "AI 已配置：\(store.state.curatorModel)" : "AI 未配置：调音与策展走本地规则")
          .font(.caption2)
          .foregroundStyle(Color(hex: store.state.skin.colors.muted))
        Spacer(minLength: 0)
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(hex: store.state.skin.colors.surface))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color(hex: store.state.skin.colors.border), lineWidth: 0.6))
    .task {
      let url = store.music
      let bytes = await Task.detached(priority: .utility) { () -> Int64 in
        guard
          let list = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return 0 }
        return list.reduce(Int64(0)) { total, file in
          let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
          return total + Int64(size)
        }
      }.value
      cacheBytes = bytes
      sizeReady = true
    }
  }

  private func stat(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value)
        .font(.system(.title3, design: .rounded).weight(.semibold))
        .foregroundStyle(Color(hex: store.state.skin.colors.text))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Text(label)
        .font(.caption2)
        .foregroundStyle(Color(hex: store.state.skin.colors.muted))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 设置里的一行入口：统一走 AwakeRow，避免设置、添加音乐、曲库各有一套行样式。
struct SettingsEntry: View {
  @EnvironmentObject var store: MobileStore
  var icon: String
  var title: String
  var subtitle: String
  var status: String?

  var body: some View {
    AwakeRow(icon: icon, title: title, detail: subtitle, status: status, chevron: false)
  }
}

enum ByteText {
  static func short(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

struct SettingsView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @State private var picking: ImportTarget?
  @State private var curatorKey = ""
  @State private var musicKey = ""
  @State private var shareFile: SharedFile?
  @State private var sourceSheet = false
  @State private var sourceToRemove: MusicSource?
  @State private var sourceRemovalError = ""
  @State private var backupCreate = false
  @State private var backupCandidate: BackupCandidate?
  @State private var restoredBackup: BackupPreview?
  @State private var builtinNote = ""
  @State private var confirmRemoveBuiltin = false
  @State private var confirmClearLocal = false
  @State private var repairNote = ""
  @State private var repairing = false
  @State private var showAddMusic = false
  var body: some View {
    Form {
      Section {
        SettingsSummaryCard()
          .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
          .listRowBackground(Color.clear)
      }
      Section("音乐来源") {
        Button {
          showAddMusic = true
        } label: {
          SettingsEntry(
            icon: "plus", title: "添加音乐",
            subtitle: "WebDAV / Plex / Telegram，或本机文件与文件夹",
            status: store.state.sources.isEmpty ? "还没有来源" : "\(store.state.sources.count) 个来源")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("addMusic")
        ForEach(store.state.sources) { s in
          HStack(spacing: 12) {
            Image(systemName: sourceIcon(s.kind))
              .font(.subheadline.weight(.regular))
              .foregroundStyle(Color(hex: store.state.skin.colors.text).opacity(0.8))
              .frame(width: 28, height: 28)
              .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .fill(Color(hex: store.state.skin.colors.raised)))
            VStack(alignment: .leading, spacing: 3) {
              Text(s.name).font(.subheadline)
              Text("\(s.kind.uppercased()) · \(store.state.songs.filter { $0.sourceID == s.id }.count) 首")
                .font(.caption).foregroundStyle(.secondary)
              if s.kind == "telegram" { TelegramSponsoredView(source: s) }
            }
            Spacer(minLength: 8)
            Menu {
              Button("刷新来源", systemImage: "arrow.clockwise") { Task { await refresh(s) } }
                .disabled(store.busy)
              Button("移除来源", systemImage: "trash", role: .destructive) { sourceToRemove = s }
                .disabled(store.busy)
                .accessibilityIdentifier("removeSource_\(s.id)")
            } label: {
              Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(Color(hex: store.state.skin.colors.muted))
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel("来源操作")
          }
        }
        if store.busy {
          HStack(spacing: 8) {
            ProgressView()
            Text("正在导入本机音频…").font(.caption)
          }
        }
        AwakeNote(text: "NAS 与网盘也可通过文件 App 连接并导入。远程曲目首次播放先下载到本机，随后进入统一 EQ 播放链路；当前 iOS 版不宣称远程即点即流或跨采样率无缝。")
      }
      Section("调音与档案") {
        NavigationLink {
          SongCurveListView()
        } label: {
          SettingsEntry(
            icon: "waveform.path", title: "每首歌的曲线",
            subtitle: "自动适配替你记住了哪些歌：逐条套用、改来源标注、删除",
            status: "\(store.state.songCurves?.count ?? 0)")
        }
        .accessibilityIdentifier("songCurves")
        NavigationLink {
          CalibrationView()
        } label: {
          SettingsEntry(
            icon: "ear", title: "听觉校准",
            subtitle: "四题 A/B 得到个人听感先验，叠加到每条曲线上",
            status: store.state.earPrior.map { "v\($0.version)" } ?? "未校准")
        }
        .accessibilityIdentifier("earCalibration")
        NavigationLink {
          TuningHistoryView()
        } label: {
          SettingsEntry(
            icon: "clock.arrow.circlepath", title: "调音历史",
            subtitle: "谁提的、改了什么、从哪到哪，可回滚",
            status: "\(store.state.tuningLog?.count ?? 0)")
        }
        .accessibilityIdentifier("tuningHistory")
        NavigationLink {
          BatchScrapeView()
        } label: {
          SettingsEntry(
            icon: "square.and.arrow.down.on.square", title: "批量补全资料",
            subtitle: "歌词、封面与公开资料；拿不到的留空，不编造", status: nil)
        }
        .accessibilityIdentifier("batchScrape")
        NavigationLink {
          ListeningProfileExportView()
        } label: {
          SettingsEntry(
            icon: "arrow.up.forward.app", title: "导出听感档案",
            subtitle: "把曲线、先验与依据带到另一台设备", status: nil)
        }
        .accessibilityIdentifier("exportProfile")
        AwakeNote(text: "档案只包含曲线与依据，不包含音频文件与凭据。")
      }
      Section("曲库维护") {
        Button {
          Task {
            repairing = true
            let report = await store.repairLocalLibrary()
            repairNote = report.summary
            repairing = false
          }
        } label: {
          SettingsEntry(
            icon: "arrow.triangle.merge", title: repairing ? "正在整理…" : "整理曲库",
            subtitle: "合并重复导入、清理没人引用的缓存；先备份 library.json",
            status: store.state.songs.count > 0 ? "\(store.state.songs.count) 首" : nil)
        }
        .disabled(repairing || store.busy)
        .accessibilityIdentifier("repairLibrary")
        if !repairNote.isEmpty {
          Text(repairNote).font(.caption).foregroundStyle(.secondary)
        }
        Button {
          Task {
            let added = await store.installBuiltinMusic(force: true)
            builtinNote = added > 0 ? "已补进 \(added) 首" : "曲库里已经齐了"
          }
        } label: {
          SettingsEntry(
            icon: "waveform.badge.plus", title: "补齐内置示例",
            subtitle: BuiltinMusic.available().isEmpty
              ? "包内没有找到 builtin-*.flac，这一版可能不是内置版"
              : "示例音频随包分发，不联网、不依赖来源配置",
            status: "\(store.builtinSongs.count) 首")
        }
        .accessibilityIdentifier("installBuiltin")
        Button(role: .destructive) { confirmRemoveBuiltin = true } label: {
          SettingsEntry(
            icon: "trash", title: "移除内置示例",
            subtitle: "删曲目、删本机音频，并清掉播种标记", status: nil)
        }
        .accessibilityIdentifier("removeBuiltin")
        Button(role: .destructive) { confirmClearLocal = true } label: {
          SettingsEntry(
            icon: "eraser", title: "清空本地添加的记录",
            subtitle: "只删本地导入、内置示例与插件曲目；来源配置与设置保留", status: nil)
        }
        .accessibilityIdentifier("clearLocalRecords")
        if !builtinNote.isEmpty {
          Text(builtinNote).font(.caption).foregroundStyle(.secondary)
        }
        AwakeNote(text: "内置示例移除后标记会清掉，下次启动会重新放一次；想反复验证首启就「移除 → 杀掉 App → 重开」。")
      }
      Section("外观") {
        Picker(
          "主题",
          selection: Binding(
            get: { store.state.skin.id },
            set: { id in
              if let skin = ([Skin.dark, .light, .glass] + store.state.customSkins).first(where: {
                $0.id == id
              }) {
                store.state.skin = skin
                store.save()
              }
            })
        ) {
          ForEach([Skin.dark, .light, .glass] + store.state.customSkins, id: \.id) {
            Text($0.name).tag($0.id)
          }
        }.accessibilityIdentifier("themePicker")
        Button("导入 design.md / 皮肤 JSON") { picking = .skin }
        Button("导出当前 design.md") {
          do {
            let data = try JSONEncoder().encode(store.state.skin)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("design.md")
            let content =
              "# Awake iOS skin\n\n```json\n" + String(decoding: data, as: UTF8.self) + "\n```\n"
            try content.write(to: url, atomically: true, encoding: .utf8)
            shareFile = SharedFile(url: url)
          } catch { store.message = error.localizedDescription }
        }
      }
      Section("服务") {
        NavigationLink {
          AISettingsView().environmentObject(store)
        } label: {
          SettingsEntry(
            icon: "sparkles", title: "AI 策展与音乐创作",
            subtitle: "调音 agent、歌单策展与 ElevenLabs 作曲共用",
            status: store.state.curatorModel.isEmpty ? "未配置" : store.state.curatorModel)
        }
        .accessibilityIdentifier("aiSettings")
      }
      Section("诊断与数据") {
        NavigationLink {
          DiagnosticsSettingsView().environmentObject(store)
        } label: {
          Label("自检、诊断日志与测试报告", systemImage: "stethoscope")
        }
      }
      Section("备份与恢复") {
        Button {
          backupCreate = true
        } label: {
          Label("创建加密备份", systemImage: "lock.doc")
        }.accessibilityIdentifier("createBackup")
        Button {
          picking = .backup
        } label: {
          Label("从备份文件恢复", systemImage: "arrow.down.doc")
        }.accessibilityIdentifier("restoreBackup")
        if let restoredBackup {
          if let playback = restoredBackup.playback, !playback.title.isEmpty {
            Text("上次播放：\(playback.title)（\(BackupFormat.clock(playback.position))）")
              .font(.subheadline)
            Button("继续播放") { continuePlayback(playback) }
              .accessibilityIdentifier("continueRestoredPlayback")
          }
          Text(
            "已从 \(restoredBackup.device) 的备份恢复：\(restoredBackup.trackCount) 首曲目、\(restoredBackup.playlistCount) 个歌单、\(restoredBackup.favoriteCount) 首收藏。"
          ).font(.caption).foregroundStyle(.secondary)
        }
        AwakeNote(text: "备份使用密码端到端加密，只包含曲库、歌单、收藏与配置；不备份钥匙串里的密码/Token，也不包含音频文件，换设备后需要重新填写凭据。跨平台只支持歌单导入。")
      }
      Section("关于 Awake") {
        Text(
          "Awake iOS \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")"
        )
        AwakeNote(
          title: "使用与声明",
          text: "请确认拥有来源与内容的使用权限，在授权范围内个人使用；不要制造或传播侵权内容，请支持正版音乐。应用不提供公共音乐源目录。公开测量与 AI 建议不是实物测量或全网统计。iOS 无法通过这里强制改变蓝牙编码、耳机 ANC 或接收器固件。"
        )
      }
    }
    .appSurface()
    .importPicker($picking) { urls, target in
      switch target {
      case .audioFiles: Task { await store.importFiles(urls) }
      case .audioFolder: Task { for url in urls { await store.importAudioFolder(url) } }
      case .skin: if let url = urls.first { importSkin(url) }
      case .backup: if let url = urls.first { importBackup(url) }
      }
    } onFail: { error, _ in
      if (error as NSError).code != NSUserCancelledError { store.message = error.localizedDescription }
    }
    .glassRows()
    .navigationTitle("设置")
    .navigationDestination(isPresented: $showAddMusic) {
      AddMusicView().environmentObject(store)
    }
    .onAppear {
      #if DEBUG
        if ProcessInfo.processInfo.environment["AWAKE_E2E_SETTINGS"] == "add" { showAddMusic = true }
      #endif
    }
    .sheet(isPresented: $sourceSheet) { SourceEditor() }
    .alert("移除来源？", isPresented: Binding(get: { sourceToRemove != nil }, set: { if !$0 { sourceToRemove = nil } })) {
      Button("取消", role: .cancel) { sourceToRemove = nil }
      Button("移除来源及已缓存曲目", role: .destructive) {
        guard let source = sourceToRemove else { return }
        do {
          if store.state.songs.contains(where: { $0.sourceID == source.id && $0.id == player.song?.id }) { player.stop() }
          try store.removeSource(source.id)
          store.message = "已移除来源及其缓存曲目"
        } catch { store.message = "移除失败：\(error.localizedDescription)" }
        sourceToRemove = nil
      }
    } message: {
      if let source = sourceToRemove { Text("将移除 \(source.name)、关联曲目和 Awake 缓存音频；手动导入的曲目会保留。") }
    }
    .alert("移除内置示例？", isPresented: $confirmRemoveBuiltin) {
      Button("取消", role: .cancel) {}
      Button("移除", role: .destructive) {
        let removed = store.removeBuiltinMusic()
        builtinNote = "已移除 \(removed) 首；播种标记已清，下次启动会再放一次"
      }
    } message: {
      Text("删掉内置示例的曲目和本机音频文件，并清掉播种标记。想反复验证首启：移除 → 杀掉 App → 重开。")
    }
    .alert("清空本地添加的记录？", isPresented: $confirmClearLocal) {
      Button("取消", role: .cancel) {}
      Button("清空", role: .destructive) {
        let result = store.clearLocalRecords()
        builtinNote = "已清空：曲目 \(result.songs) 首、文件夹记录 \(result.folders) 条"
      }
    } message: {
      Text("删除不属于任何远程来源的曲目（本地导入、内置示例、插件曲目）及其本机文件，并清掉导入文件夹记录；来源配置、外观与播放设置保留。")
    }
    .sheet(item: $shareFile) { file in ShareView(url: file.url) }
    .sheet(isPresented: $backupCreate) { BackupCreateSheet() }
    .sheet(item: $backupCandidate) { candidate in
      BackupRestoreSheet(candidate: candidate) { preview in restoredBackup = preview }
    }
  }
  private func sourceIcon(_ kind: String) -> String {
    switch kind {
    case "plex": return "play.rectangle.on.rectangle"
    case "telegram": return "paperplane"
    default: return "externaldrive.connected.to.line.below"
    }
  }

  private func importSkin(_ url: URL) {
    do {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard data.count <= 65536 else { throw AppFailure("皮肤文件不能超过 64 KB") }
      var skin = try Skin.parse(String(decoding: data, as: UTF8.self))
      skin.id = "custom-" + UUID().uuidString
      store.state.customSkins.append(skin)
      store.state.customSkins = Array(store.state.customSkins.suffix(30))
      store.state.skin = skin
      store.save()
    } catch { store.message = error.localizedDescription }
  }
  private func importBackup(_ url: URL) {
    do {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= BackupService.maxFileBytes else { throw AppFailure("备份文件不能超过 32 MB") }
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard data.count <= BackupService.maxFileBytes else { throw AppFailure("备份文件不能超过 32 MB") }
      let candidate = BackupCandidate(name: url.lastPathComponent, data: data)
      DispatchQueue.main.async { backupCandidate = candidate }
    } catch { store.message = error.localizedDescription }
  }
  func continuePlayback(_ playback: BackupPlayback) {
    continueBackupPlayback(playback, store: store, player: player)
  }
  func saveService(_ type: String) {
    do {
      let url = type == "music" ? store.state.musicURL : store.state.curatorURL
      _ = try Network.endpoint(url)
      let key = type == "music" ? musicKey : curatorKey
      let owner =
        type == "music"
        ? store.state.musicCredentialEndpoint : store.state.curatorCredentialEndpoint
      let oldAccount =
        type == "music" ? store.state.musicCredentialAccount : store.state.curatorCredentialAccount
      guard !key.isEmpty || (owner == url && !oldAccount.isEmpty) else {
        throw AppFailure("首次配置或更换服务地址时，请填写密钥")
      }
      let account = key.isEmpty ? oldAccount : type + "." + UUID().uuidString
      if !key.isEmpty { try Secrets.set(key, account: account) }
      if type == "music" {
        store.state.musicCredentialEndpoint = url
        store.state.musicCredentialAccount = account
      } else {
        store.state.curatorCredentialEndpoint = url
        store.state.curatorCredentialAccount = account
      }
      store.save()
      curatorKey = ""
      musicKey = ""
    } catch { store.message = error.localizedDescription }
  }
  func refresh(_ s: MusicSource) async {
    store.busy = true
    defer { store.busy = false }
    do {
      let rows = try await SourceService.scan(
        s, secret: Secrets.get("source." + s.id), artwork: store.artworkDirectory)
      let old = store.state.songs.filter { $0.sourceID == s.id }
      let merged = store.mergeScannedSongs(rows, previous: old)
      store.state.songs.removeAll { $0.sourceID == s.id }
      store.state.songs.append(contentsOf: merged)
      store.save()
      store.message = "来源已更新"
    } catch { store.message = "刷新失败，保留旧曲库：" + error.localizedDescription }
  }
}
struct SharedFile: Identifiable {
  let id = UUID()
  let url: URL
}
struct ShareView: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }
  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
struct SourceEditor: View {
  @EnvironmentObject var store: MobileStore
  @Environment(\.dismiss) var dismiss
  /// 从「添加音乐」带进来的来源类型：三种服务器的要求不同，不该让用户进来再选一次。
  var initialKind: String = "webdav"
  /// 从「配置文件夹」带进来的配置；只填类型 / 名称 / 地址 / 用户名，凭据永远由用户当场输入。
  var prefill: SourceConfiguration? = nil
  @State private var name = ""
  @State private var kind = "webdav"
  @State private var url = ""
  @State private var username = ""
  @State private var secret = ""
  @State private var busy = false
  @State private var error = ""
  @State private var configurationImport = false
  @State private var catalog: TelegramCatalog?
  @State private var selected = Set<String>()
  @State private var limit = 1000
  @State private var trustSelfSigned = false
  @State private var plexToken = ""
  @State private var plexServers: [PlexAuth.Server] = []
  @State private var plexBusy = false
  @State private var plexNote = ""
  @State private var selectedServer = ""
  @State private var plexSections: [PlexAuth.Section] = []
  @State private var selectedSection = ""
  @Environment(\.openURL) private var openURL
  var telegramReady: Bool {
    url.range(of: "/v1/libraries/[a-f0-9]{24}/?$", options: .regularExpression) != nil
  }
  /// 把文件夹里扫到的配置填进表单。凭据字段刻意留空：配置文件里没有、也不该有密码。
  func applyPrefill() {
    guard let config = prefill else { return }
    kind = config.kind
    name = config.name
    url = config.url
    username = config.username ?? ""
    secret = ""
    error = ""
    catalog = nil
    selected = []
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("来源") {
          Picker("类型", selection: $kind) {
            Text("WebDAV / NAS / 网盘").tag("webdav")
            Text("Plex 音乐库").tag("plex")
            Text("Telegram 个人媒体库").tag("telegram")
          }.accessibilityIdentifier("sourceKind")
          TextField("名称", text: $name).accessibilityIdentifier("sourceName")
          TextField(kind == "telegram" ? "个人连接器 URL" : "服务器或根目录 URL", text: $url)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            .accessibilityIdentifier("sourceURL")
          if kind == "webdav" {
            TextField("账号（可选）", text: $username).textInputAutocapitalization(.never)
            Toggle("允许自签名 HTTPS 证书", isOn: $trustSelfSigned).font(.caption)
            Text("仅当 NAS 使用自签证书时打开；只对这个来源的主机生效。能用 HTTP 局域网地址时不要打开。")
              .font(.caption2).foregroundStyle(.secondary)
          }
          SecureField(
            kind == "plex" ? "Plex Token（也可用下方账号登录）"
              : kind == "telegram" ? "连接器访问令牌" : "密码 / 应用密码", text: $secret
          )
          .accessibilityIdentifier("sourceSecret")
        }.disabled(busy)
        if kind == "plex" {
          Section("Plex 账号登录") {
            Button {
              Task { await plexSignIn() }
            } label: {
              Label(
                plexToken.isEmpty ? "用 Plex 账号登录" : "已登录 · 重新授权",
                systemImage: "person.badge.key")
            }
            .disabled(plexBusy)
            .accessibilityIdentifier("plexLogin")
            if plexBusy { ProgressView("等待浏览器完成授权…").font(.caption) }
            if !plexNote.isEmpty { Text(plexNote).font(.caption).foregroundStyle(.secondary) }
            if !plexServers.isEmpty {
              Picker("服务器线路", selection: $selectedServer) {
                ForEach(plexServers) { server in
                  Text(server.name + " · " + server.connection).tag(server.uri)
                }
              }
              .onChange(of: selectedServer) { _, value in
                guard let server = plexServers.first(where: { $0.uri == value }) else { return }
                Task { await applyServer(server) }
              }
              Button("重新读取服务器", systemImage: "arrow.clockwise") {
                Task { await loadServers() }
              }.disabled(plexBusy || plexToken.isEmpty)
            }
            if !plexSections.isEmpty {
              Picker("音乐库", selection: $selectedSection) {
                Text("全部音乐库").tag("")
                ForEach(plexSections) { section in
                  Text(section.title).tag(section.key)
                }
              }
            }
            if !plexNote.isEmpty {
              Text(plexNote).font(.caption).foregroundStyle(.secondary)
            }
            Text("登录只用于换取这台服务器的访问 Token；密码不会保存在手机上，Token 存入钥匙串。授权在 Safari 完成。换一条线路可解决 plex.direct 不可达。")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
        if kind == "telegram" && !telegramReady {
          Section("选择 Telegram 音频") {
            Text("先在你自己的电脑或 NAS 上运行连接器并登录 Telegram。iPhone 填写该设备的局域网或 HTTPS 地址，不能使用电脑的 127.0.0.1 地址。").font(.caption)
            Button("读取频道与聊天文件夹") { Task { await browse() } }
              .disabled(busy || url.isEmpty || secret.isEmpty).accessibilityIdentifier("telegramBrowse")
            if let catalog {
              ForEach(catalog.folders) { folder in
                Button("选择文件夹：" + folder.title) { selected = Set(folder.chat_ids) }.disabled(busy)
              }
              ForEach(catalog.chats) { chat in
                Toggle(chat.title, isOn: Binding(get: { selected.contains(chat.id) }, set: { enabled in
                  if enabled { selected.insert(chat.id) } else { selected.remove(chat.id) }
                })).disabled(busy)
              }
              Picker("每个来源的最近消息范围", selection: $limit) {
                ForEach([100, 500, 1000, 2000], id: \.self) { Text("最近 \($0) 条").tag($0) }
              }
              Text("已选 \(selected.count) 个，最多 20 个。聊天文件夹之后新增的频道不会自动加入。").font(.caption)
              Button("使用所选来源") { Task { await choose() } }.disabled(busy || selected.isEmpty || selected.count > 20)
            }
          }
        }
        Section {
          Button("导入个人配置 · JSON / XML / TXT") { configurationImport = true }.disabled(busy)
          Text(kind == "telegram"
            ? "只读取你选中的频道或收藏夹。Telegram 会话保存在你自己的连接器设备；这里的访问令牌保存在钥匙串。音频首次播放先下载到本机。"
            : "只连接你自己添加的服务器。密码和 Token 保存在钥匙串，认证不写入曲目 URL。外部服务使用 HTTPS，局域网可使用 HTTP。")
            .font(.caption)
          Text("请确认拥有内容及访问方式的必要授权。应用不提供公共频道或音乐源目录。").font(.caption).foregroundStyle(.secondary)
          if !error.isEmpty { Text(error).foregroundStyle(.red).accessibilityIdentifier("sourceError") }
          if busy { ProgressView("正在读取自己的曲库…") }
          Button("连接并扫描") { Task { await connect() } }
            .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || url.isEmpty || (kind == "telegram" && !telegramReady))
            .accessibilityIdentifier("connectSource")
        }
      }.appSurface().onAppear {
      if prefill == nil, kind != initialKind { kind = initialKind }
    }
      .navigationTitle("添加音乐来源").toolbar { Button("完成") { dismiss() }.disabled(busy) }
      .onAppear { applyPrefill() }
      .onChange(of: kind) { _, _ in plexNote = ""; catalog = nil; selected = [] }
      .onChange(of: url) { _, _ in catalog = nil; selected = [] }
      .onChange(of: secret) { _, _ in catalog = nil; selected = [] }
      .fileImporter(isPresented: $configurationImport, allowedContentTypes: [.json, .xml, .plainText]) { result in
        do {
          let file = try result.get()
          let access = file.startAccessingSecurityScopedResource()
          defer { if access { file.stopAccessingSecurityScopedResource() } }
          let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size <= 65536 else { throw AppFailure("配置文件不能超过 64 KB") }
          let config = try SourceConfiguration.parse(String(contentsOf: file, encoding: .utf8), format: file.pathExtension)
          kind = config.kind; name = config.name; url = config.url; username = config.username ?? ""
          secret = ""; error = ""
        } catch { self.error = error.localizedDescription }
      }
    }
  }
  func plexSignIn() async {
    plexBusy = true
    plexNote = ""
    defer { plexBusy = false }
    do {
      let pin = try await PlexAuth.createPin()
      openURL(PlexAuth.authURL(pin))
      plexNote = "已打开 Plex 授权页；登录并允许后会自动继续。"
      var token: String?
      let deadline = Date().addingTimeInterval(300)
      while Date() < deadline {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        if let value = try await PlexAuth.poll(pin) {
          token = value
          break
        }
      }
      guard let token else {
        throw AppFailure("等待 Plex 授权超时（5 分钟）。请重试，或在上面手动填写 Token。")
      }
      plexToken = token
      await loadServers()
      error = ""
    } catch { plexNote = error.localizedDescription }
  }
  func loadServers() async {
    plexBusy = true
    defer { plexBusy = false }
    do {
      let servers = try await PlexAuth.servers(token: plexToken)
      guard let first = servers.first else {
        throw AppFailure("这个 Plex 账号下没有找到可用的服务器。请确认服务器在线并已分享给该账号。")
      }
      plexServers = servers
      selectedServer = first.uri
      await applyServer(first)
    } catch { plexNote = error.localizedDescription }
  }

  func applyServer(_ server: PlexAuth.Server) async {
    url = server.uri
    secret = server.accessToken
    plexToken = server.accessToken
    if name.trimmingCharacters(in: .whitespaces).isEmpty {
      name = "Plex · " + server.name
    }
    plexSections = []
    selectedSection = ""
    plexNote = "正在检测 \(server.connection)…"
    guard await PlexAuth.probe(server) else {
      plexNote = "这条线路连不上，换一条线路再试。"
      return
    }
    plexNote = "线路可用，正在读取音乐库…"
    do {
      plexSections = try await PlexAuth.sections(server)
      selectedSection = plexSections.first?.key ?? ""
      plexNote =
        plexSections.isEmpty
        ? "线路可用；服务器没有音乐分区，将扫描全部音乐库。"
        : "线路可用，已读取 \(plexSections.count) 个音乐库。"
    } catch {
      plexNote = "线路可用，但读取音乐库失败：\(error.localizedDescription)"
    }
  }

  func browse() async {
    busy = true; error = ""
    defer { busy = false }
    do { catalog = try await TelegramService.catalog(base: url, secret: secret) }
    catch { self.error = error.localizedDescription }
  }
  func choose() async {
    busy = true; error = ""
    defer { busy = false }
    do { url = try await TelegramService.collection(base: url, secret: secret, ids: selected, limit: limit) }
    catch { self.error = error.localizedDescription }
  }
  func connect() async {
    busy = true; error = ""
    defer { busy = false }
    do {
      _ = try Network.endpoint(url, localHTTP: true)
      var source = MusicSource(
        name: name.trimmingCharacters(in: .whitespaces), kind: kind, url: url,
        username: kind == "webdav" ? username : "",
        trustSelfSigned: kind == "webdav" ? trustSelfSigned : false,
        section: kind == "plex" && !selectedSection.isEmpty ? selectedSection : nil)
      // 同一地址、同一分区的重复连接：复用来源 id，扫描结果按 locator 合并，
      // 不再出现「连两次 → 两份来源 + 两份曲目」。
      func normalised(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
      }
      let existing = store.state.sources.first {
        $0.kind == source.kind && normalised($0.url) == normalised(source.url)
          && ($0.section ?? "") == (source.section ?? "")
      }
      if let existing { source.id = existing.id }
      let songs = try await SourceService.scan(
        source, secret: secret, artwork: store.artworkDirectory)
      try Secrets.set(secret, account: "source." + source.id)
      let previous = store.state
      var next = store.state
      if let existing {
        let old = next.songs.filter { $0.sourceID == existing.id }
        let merged = store.mergeScannedSongs(songs, previous: old)
        if let index = next.sources.firstIndex(where: { $0.id == existing.id }) {
          next.sources[index] = source
        } else {
          next.sources.append(source)
        }
        next.songs.removeAll { $0.sourceID == existing.id }
        next.songs.append(contentsOf: merged)
      } else {
        next.sources.append(source)
        next.songs.append(contentsOf: songs)
      }
      store.state = next
      do { try store.persist() } catch { store.state = previous; throw error }
      secret = ""
      // 连完必须让用户看见结果：切到曲库、列表筛到这个来源。
      // 之前只 dismiss()，曲目被追加在列表末尾，来源越多越难找，看起来就是「加了但看不到」。
      let added = next.songs.filter { $0.sourceID == source.id }.count
      store.message = "「\(source.name)」已加入 \(added) 首，正在为你显示这个来源。"
      store.pendingLibrarySource = source.id
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

struct BackupCandidate: Identifiable {
  let id = UUID()
  let name: String
  let data: Data
}

extension UTType {
  /// 文档选择器里按扩展名过滤；系统没有动态类型时退回 .data。
  static var awakeBackupFile: UTType {
    UTType(filenameExtension: "awake-backup") ?? .data
  }
}

/// 按标题 + 艺人匹配恢复后的曲目，只载入并 seek，不自动播放。
@MainActor
func continueBackupPlayback(
  _ playback: BackupPlayback, store: MobileStore, player: MobilePlayer
) {
  let title = playback.title.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !title.isEmpty else {
    store.message = "备份里没有可继续播放的曲目"
    return
  }
  let artist = playback.artist.trimmingCharacters(in: .whitespacesAndNewlines)
  let matches = store.state.songs.filter { song in
    guard song.title.compare(
      title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    else { return false }
    guard !artist.isEmpty else { return true }
    return song.artist.compare(
      artist, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
  }
  guard let song = matches.first(where: { store.localURL($0) != nil }),
    let url = store.localURL(song)
  else {
    store.message = "本机没有找到《\(title)》的音频文件；备份不包含音频，请先导入后重试。"
    return
  }
  let limit = song.duration > 0 ? song.duration : playback.duration
  let requested = playback.position.isFinite ? max(0, playback.position) : 0
  let start = limit > 0 ? min(requested, max(0, limit - 0.25)) : requested
  player.play([(song, url)], at: 0, from: start, startPlaying: false)
  store.message = "已载入《\(song.title)》，未自动播放"
}

struct BackupCreateSheet: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @Environment(\.dismiss) var dismiss
  @State private var password = ""
  @State private var confirmation = ""
  @State private var message = ""
  @State private var busy = false
  @State private var shareFile: SharedFile?

  var body: some View {
    NavigationStack {
      Form {
        Section("备份密码") {
          SecureField("密码（至少 8 个字符）", text: $password)
            .accessibilityIdentifier("backupCreatePassword")
          SecureField("再次输入密码", text: $confirmation)
            .accessibilityIdentifier("backupCreatePasswordConfirm")
          Text("密码不会保存，也不会离开这台设备；忘记密码后备份无法恢复。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section {
          Button {
            create()
          } label: {
            Label("创建并分享备份", systemImage: "square.and.arrow.up")
          }
          .disabled(busy || password.isEmpty || confirmation.isEmpty)
          .accessibilityIdentifier("backupCreateSubmit")
          if busy { ProgressView("正在用 310000 次密钥派生加密…") }
          if !message.isEmpty {
            Text(message).font(.caption).foregroundStyle(.secondary)
          }
        }
        Section {
          Text("备份包含曲库、歌单、收藏与播放配置；不包含钥匙串密码/Token 与音频文件。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("创建加密备份")
      .toolbar { Button("取消") { dismiss() } }
      .sheet(item: $shareFile) { file in ShareView(url: file.url) }
    }
  }

  private func create() {
    message = ""
    busy = true
    defer { busy = false }
    do {
      try BackupCrypto.validatePassword(password, confirmation: confirmation)
      let data = try BackupService.makeBackup(store: store, player: player, password: password)
      let url = try BackupService.writeTemporary(data)
      password = ""
      confirmation = ""
      message = "已生成 \(url.lastPathComponent)，可通过分享保存到文件 App。"
      shareFile = SharedFile(url: url)
    } catch {
      message = error.localizedDescription
    }
  }
}

struct BackupRestoreSheet: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @Environment(\.dismiss) var dismiss
  let candidate: BackupCandidate
  let onRestored: (BackupPreview) -> Void
  @State private var password = ""
  @State private var preview: BackupPreview?
  @State private var result: BackupRestoreResult?
  @State private var error = ""
  @State private var busy = false

  init(candidate: BackupCandidate, onRestored: @escaping (BackupPreview) -> Void) {
    self.candidate = candidate
    self.onRestored = onRestored
  }

  var body: some View {
    NavigationStack {
      Form {
        if let result {
          restoredSection(result)
        } else if let preview {
          previewSection(preview)
        } else {
          passwordSection
        }
        if !error.isEmpty {
          Section {
            Text(error).foregroundStyle(.red)
              .accessibilityIdentifier("backupRestoreError")
          }
        }
        if busy {
          Section { ProgressView("正在解密备份…") }
        }
      }
      .navigationTitle("从加密备份恢复")
      .toolbar { Button(result == nil ? "取消" : "完成") { dismiss() } }
    }
  }

  @ViewBuilder private var passwordSection: some View {
    Section("备份文件") {
      Text(candidate.name).font(.headline)
      Text(
        ByteCountFormatter.string(
          fromByteCount: Int64(candidate.data.count), countStyle: .file)
      ).font(.caption).foregroundStyle(.secondary)
    }
    Section("密码") {
      SecureField("备份密码", text: $password)
        .accessibilityIdentifier("backupRestorePassword")
      Button {
        unlock()
      } label: {
        Label("解锁并预览", systemImage: "lock.open")
      }
      .disabled(busy || password.count < BackupCrypto.minimumPasswordLength)
      .accessibilityIdentifier("backupRestoreUnlock")
      Text("只在本机解密预览；确认前不会改动当前曲库。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private func previewSection(_ preview: BackupPreview) -> some View {
    Section("备份内容") {
      LabeledContent("设备", value: preview.device)
      LabeledContent("导出时间", value: preview.exportedAtText)
      LabeledContent("曲目", value: "\(preview.trackCount) 首")
      LabeledContent("歌单", value: "\(preview.playlistCount) 个")
      LabeledContent("收藏", value: "\(preview.favoriteCount) 首")
      LabeledContent("应用版本", value: preview.appVersion)
      if let playback = preview.playback, !playback.title.isEmpty {
        LabeledContent(
          "上次播放", value: "\(playback.title)（\(BackupFormat.clock(playback.position))）")
      }
    }
    Section {
      Button {
        restore()
      } label: {
        Label("确认恢复并覆盖当前曲库", systemImage: "arrow.counterclockwise")
      }
      .disabled(busy)
      .accessibilityIdentifier("backupConfirmRestore")
      Button("重新输入密码") {
        self.preview = nil
        password = ""
        error = ""
      }
      Text("恢复前会把当前 library.json 保存为 library.json.before-restore。只接受 awake.backup.ios；其他平台备份会给出明确提示。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private func restoredSection(_ result: BackupRestoreResult) -> some View {
    Section("恢复完成") {
      Text(
        "已恢复 \(result.preview.trackCount) 首曲目、\(result.preview.playlistCount) 个歌单、\(result.preview.favoriteCount) 首收藏。"
      )
      Text("恢复前副本：\(result.safetyCopy.lastPathComponent)")
        .font(.caption).foregroundStyle(.secondary)
      if let playback = result.preview.playback, !playback.title.isEmpty {
        Text("上次播放：\(playback.title)（\(BackupFormat.clock(playback.position))）")
        Button {
          continueBackupPlayback(playback, store: store, player: player)
        } label: {
          Label("继续播放", systemImage: "play.fill")
        }
        .accessibilityIdentifier("continueRestoredPlaybackInSheet")
        Text("不会自动播放；若本机没有对应音频，会提示先导入。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    Section {
      Text("备份不包含钥匙串密码/Token，需要重新填写；音频文件也不在备份中。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func unlock() {
    error = ""
    busy = true
    defer { busy = false }
    do {
      try BackupCrypto.validatePassword(password)
      preview = try BackupService.inspect(candidate.data, password: password)
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func restore() {
    error = ""
    busy = true
    defer { busy = false }
    do {
      let outcome = try BackupService.restore(
        into: store, fileData: candidate.data, password: password)
      result = outcome
      preview = outcome.preview
      onRestored(outcome.preview)
      store.message = "已从加密备份恢复曲库"
    } catch {
      self.error = error.localizedDescription
    }
  }
}


/// AI 服务收进二级页：这一页一年打开两次，放在设置首屏只会把「加个来源」挤走。
struct AISettingsView: View {
  @EnvironmentObject var store: MobileStore
  @State private var curatorKey = ""
  @State private var musicKey = ""

  var body: some View {
    Form {
      Section("AI 策展与反馈分析") {
        TextField("Base URL", text: $store.state.curatorURL).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("模型 ID", text: $store.state.curatorModel).textInputAutocapitalization(.never)
        SecureField("API 密钥（只保存在钥匙串）", text: $curatorKey)
        Button("保存 AI 配置") { saveService("curator") }
      }
      Section("AI 音乐创作 · ElevenLabs") {
        TextField("Music 服务地址", text: $store.state.musicURL).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Picker("模型", selection: $store.state.musicModel) {
          ForEach(["music_v1", "music_v2", "music_v2_5"], id: \.self) { Text($0) }
        }
        SecureField("Music API 密钥", text: $musicKey)
        Button("保存音乐服务") { saveService("music") }
        Text("保存配置不产生生成请求。只有用户主动提交时才调用服务。").font(.caption).foregroundStyle(.secondary)
      }
    }
    .navigationTitle("AI 服务")
    .appSurface()
  }

  private func saveService(_ type: String) {
    do {
      let url = type == "music" ? store.state.musicURL : store.state.curatorURL
      _ = try Network.endpoint(url)
      let key = type == "music" ? musicKey : curatorKey
      let owner =
        type == "music"
        ? store.state.musicCredentialEndpoint : store.state.curatorCredentialEndpoint
      let oldAccount =
        type == "music" ? store.state.musicCredentialAccount : store.state.curatorCredentialAccount
      guard !key.isEmpty || (owner == url && !oldAccount.isEmpty) else {
        throw AppFailure("首次配置或更换服务地址时，请填写密钥")
      }
      let account = key.isEmpty ? oldAccount : type + "." + UUID().uuidString
      if !key.isEmpty { try Secrets.set(key, account: account) }
      if type == "music" {
        store.state.musicCredentialEndpoint = url
        store.state.musicCredentialAccount = account
      } else {
        store.state.curatorCredentialEndpoint = url
        store.state.curatorCredentialAccount = account
      }
      store.save()
      curatorKey = ""
      musicKey = ""
    } catch { store.message = error.localizedDescription }
  }
}

/// 诊断与数据：自检、日志、报告。平时不占首屏，出问题时找得到。
struct DiagnosticsSettingsView: View {
  @EnvironmentObject var store: MobileStore
  @State private var shareFile: SharedFile?

  var body: some View {
    Form {
      Section("自检与日志") {
        Button("导入 / 播放自检", systemImage: "stethoscope") {
          Task { store.message = await Diagnostics.selfTest() }
        }
        .accessibilityIdentifier("importSelfTest")
        Button("分享诊断日志", systemImage: "doc.text.magnifyingglass") {
          Diagnostics.log("用户导出诊断日志")
          shareFile = SharedFile(url: Diagnostics.fileURL)
        }
        .accessibilityIdentifier("shareDiagnostics")
        .disabled(!FileManager.default.fileExists(atPath: Diagnostics.fileURL.path))
      }
      Section("反馈报告") {
        Button("导出评分与软件测试报告") {
          do { shareFile = SharedFile(url: try store.reportURL()) } catch {
            store.message = error.localizedDescription
          }
        }
        Text("报告包含主观评分、反馈文字和软件测试，不包含源密码、API 密钥或设备 UID。仅保存在本机，分享由你发起。").font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("诊断与数据")
    .appSurface()
    .sheet(item: $shareFile) { file in ShareView(url: file.url) }
  }
}
