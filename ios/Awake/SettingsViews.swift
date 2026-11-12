import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @EnvironmentObject var store: MobileStore
  @State private var skinImport = false
  @State private var curatorKey = ""
  @State private var musicKey = ""
  @State private var shareFile: SharedFile?
  @State private var sourceSheet = false
  @State private var folderImport = false
  @State private var fileImport = false
  var body: some View {
    Form {
      Section("外观与皮肤") {
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
        Button("导入 design.md / 皮肤 JSON") { skinImport = true }
          .fileImporter(isPresented: $skinImport, allowedContentTypes: [.plainText, .json, .text]) {
            result in
            do {
              let u = try result.get()
              let access = u.startAccessingSecurityScopedResource()
              defer { if access { u.stopAccessingSecurityScopedResource() } }
              let data = try Data(contentsOf: u, options: .mappedIfSafe)
              guard data.count <= 65536 else { throw AppFailure("皮肤文件不能超过 64 KB") }
              var skin = try Skin.parse(String(decoding: data, as: UTF8.self))
              skin.id = "custom-" + UUID().uuidString
              store.state.customSkins.append(skin)
              store.state.customSkins = Array(store.state.customSkins.suffix(30))
              store.state.skin = skin
              store.save()
            } catch { store.message = error.localizedDescription }
          }
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
      Section("自己的音乐来源") {
        Button("添加 WebDAV / Plex / Telegram", systemImage: "plus") { sourceSheet = true }
          .accessibilityIdentifier("addSource")
        Button("导入音频文件", systemImage: "doc.badge.plus") { fileImport = true }
          .accessibilityIdentifier("importAudioFiles")
          .fileImporter(
            isPresented: $fileImport, allowedContentTypes: [.audio], allowsMultipleSelection: true
          ) { result in
            switch result {
            case .success(let urls): Task { await store.importFiles(urls) }
            case .failure(let error): store.message = error.localizedDescription
            }
          }
        Button("导入本地 / Telegram 下载文件夹", systemImage: "folder") { folderImport = true }
          .accessibilityIdentifier("importFolder")
          .fileImporter(isPresented: $folderImport, allowedContentTypes: [.folder]) { result in
            do {
              let url = try result.get()
              Task { await store.importAudioFolder(url) }
            } catch { store.message = error.localizedDescription }
          }
        ForEach(store.state.sources) { s in
          VStack(alignment: .leading, spacing: 8) {
            Text(s.name).font(.headline)
            Text("\(s.kind.uppercased()) · \(store.state.songs.filter{$0.sourceID==s.id}.count) 首")
              .font(.caption).foregroundStyle(.secondary)
            if s.kind == "telegram" { TelegramSponsoredView(source: s) }
            Button("刷新来源") { Task { await refresh(s) } }.disabled(store.busy)
          }
        }
        if store.busy {
          HStack(spacing: 8) {
            ProgressView()
            Text("正在导入本机音频…").font(.caption)
          }
        }
        Text("NAS 与网盘也可通过文件 App 连接并导入。远程曲目首次播放先下载到本机，随后进入统一 EQ 播放链路；当前 iOS 版不宣称远程即点即流或跨采样率无缝。")
          .font(.caption).foregroundStyle(.secondary)
      }
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
      Section("数据与反馈") {
        Button("导出评分与软件测试报告") {
          do { shareFile = SharedFile(url: try store.reportURL()) } catch {
            store.message = error.localizedDescription
          }
        }
        Text("报告包含主观评分、反馈文字和软件测试，不包含源密码、API 密钥或设备 UID。仅保存在本机，分享由你发起。").font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("关于 Awake") {
        Text(
          "Awake iOS \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")"
        )
        Text("请确认拥有来源与内容的使用权限，在授权范围内个人使用；不要制造或传播侵权内容，请支持正版音乐。应用不提供公共音乐源目录。").font(.caption)
        Text("公开测量与 AI 建议不是实物测量或全网统计。iOS 无法通过这里强制改变蓝牙编码、耳机 ANC 或接收器固件。").font(.caption)
          .foregroundStyle(.secondary)
      }
    }.appSurface().navigationTitle("设置").sheet(isPresented: $sourceSheet) { SourceEditor() }.sheet(
      item: $shareFile
    ) { file in ShareView(url: file.url) }
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
      let rows = try await SourceService.scan(s, secret: Secrets.get("source." + s.id))
      let old = store.state.songs.filter { $0.sourceID == s.id }
      let merged = rows.map { row -> Song in
        if let previous = old.first(where: { $0.locator == row.locator }) {
          var updated = row
          updated.id = previous.id
          updated.favorite = previous.favorite
          updated.file = previous.file
          updated.originalFilename = previous.originalFilename
          updated.artwork = previous.artwork
          updated.lyrics = previous.lyrics
          updated.comment = previous.comment
          if let info = previous.mediaInfo {
            updated.title = previous.title; updated.artist = previous.artist; updated.album = previous.album
            updated.mediaInfo = info
          }
          return updated
        }
        return row
      }
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
  @Environment(\.openURL) private var openURL
  var telegramReady: Bool {
    url.range(of: "/v1/libraries/[a-f0-9]{24}/?$", options: .regularExpression) != nil
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
            if plexServers.count > 1 {
              Picker("服务器", selection: $selectedServer) {
                ForEach(plexServers) { Text($0.name).tag($0.uri) }
              }
              .onChange(of: selectedServer) { _, value in
                if let server = plexServers.first(where: { $0.uri == value }) {
                  url = server.uri
                  secret = server.accessToken
                  plexToken = server.accessToken
                  if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    name = "Plex · " + server.name
                  }
                }
              }
            }
            Text("登录只用于换取这台服务器的访问 Token；密码不会保存在手机上，Token 存入钥匙串。授权在 Safari 完成。")
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
      }.appSurface().navigationTitle("添加音乐来源").toolbar { Button("完成") { dismiss() }.disabled(busy) }
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
      let servers = try await PlexAuth.servers(token: token)
      guard let server = servers.first else {
        throw AppFailure("这个 Plex 账号下没有找到可用的服务器。请确认 Plex 服务器已登录同一账号并在线。")
      }
      plexServers = servers
      selectedServer = server.uri
      url = server.uri
      secret = server.accessToken
      if name.trimmingCharacters(in: .whitespaces).isEmpty { name = "Plex · " + server.name }
      plexNote = "已登录：\(server.name)。点“连接并扫描”读取音乐库。"
      error = ""
    } catch { plexNote = error.localizedDescription }
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
      let source = MusicSource(
        name: name.trimmingCharacters(in: .whitespaces), kind: kind, url: url,
        username: kind == "webdav" ? username : "",
        trustSelfSigned: kind == "webdav" ? trustSelfSigned : false)
      let songs = try await SourceService.scan(source, secret: secret)
      try Secrets.set(secret, account: "source." + source.id)
      let previous = store.state
      store.state.sources.append(source)
      store.state.songs.append(contentsOf: songs)
      do { try store.persist() } catch { store.state = previous; throw error }
      secret = ""
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
