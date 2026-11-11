import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @EnvironmentObject var store: MobileStore
  @State private var skinImport = false
  @State private var curatorKey = ""
  @State private var musicKey = ""
  @State private var shareFile: SharedFile?
  @State private var sourceSheet = false
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
        Button("添加 NAS / WebDAV / Plex", systemImage: "plus") { sourceSheet = true }
          .accessibilityIdentifier("addSource")
        ForEach(store.state.sources) { s in
          VStack(alignment: .leading, spacing: 8) {
            Text(s.name).font(.headline)
            Text("\(s.kind.uppercased()) · \(store.state.songs.filter{$0.sourceID==s.id}.count) 首")
              .font(.caption).foregroundStyle(.secondary)
            Button("刷新来源") { Task { await refresh(s) } }.disabled(store.busy)
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
    ) { file in ShareView(url: file.url) }.fileImporter(
      isPresented: $skinImport, allowedContentTypes: [.plainText, .json, .text]
    ) { result in
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
  var body: some View {
    NavigationStack {
      Form {
        Section("来源") {
          Picker("类型", selection: $kind) {
            Text("WebDAV / NAS / 网盘").tag("webdav")
            Text("Plex 音乐库").tag("plex")
          }
          TextField("名称", text: $name)
          TextField("服务器或根目录 URL", text: $url).textInputAutocapitalization(.never).keyboardType(
            .URL)
          if kind == "webdav" {
            TextField("账号（可选）", text: $username).textInputAutocapitalization(.never)
          }
          SecureField(kind == "plex" ? "Plex Token" : "密码 / 应用密码", text: $secret)
        }
        Section {
          Text("只连接你自己添加的服务器。密码和 Token 保存在钥匙串，认证不写入曲目 URL。HTTPS 用于外部服务，局域网地址可使用 HTTP。").font(
            .caption)
          if busy { ProgressView("正在读取自己的曲库…") }
          Button("连接并扫描") { Task { await connect() } }.disabled(busy || name.isEmpty || url.isEmpty)
        }
      }.appSurface().navigationTitle("添加音乐来源").toolbar { Button("完成") { dismiss() }.disabled(busy) }
    }
  }
  func connect() async {
    busy = true
    defer { busy = false }
    do {
      _ = try Network.endpoint(url, localHTTP: true)
      let source = MusicSource(name: name, kind: kind, url: url, username: username)
      let songs = try await SourceService.scan(source, secret: secret)
      try Secrets.set(secret, account: "source." + source.id)
      store.state.sources.append(source)
      store.state.songs.append(contentsOf: songs)
      store.save()
      dismiss()
    } catch { store.message = error.localizedDescription }
  }
}
