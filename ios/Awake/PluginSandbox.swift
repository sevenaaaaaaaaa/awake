import Foundation
import WebKit

/// 插件搜索回来的一条（沙箱 → Swift 的扁平结构）。
struct PluginHit: Identifiable, Hashable {
  var id: String { itemID.isEmpty ? rawJSON : itemID }
  var title: String
  var artist: String
  var album: String
  var duration: Double
  var artwork: String
  var itemID: String
  /// 原始 musicItem 的 JSON：播放时要靠它解析直链，所以整条存进 locator。
  var rawJSON: String
}

/// 插件沙箱：离屏 WKWebView 里跑 `ui/src/plugins.ts` 的编译产物（Resources/pluginSandbox.js）。
///
/// 分工照抄桌面：JS 负责插件 ABI 与 CryptoJS，Swift 只提供两件事——插件代码、fetch 通道。
/// fetch 走 `awakeHttp` 消息桥，回落 URLSession，因此不受 WebView 的 CORS 约束。
@MainActor
final class PluginSandbox: NSObject {
  static let shared = PluginSandbox()

  /// 和桌面 plugin_http 同口径的上限。
  static let maxResponseBytes = 8 * 1024 * 1024
  static let maxRequestBytes = 2 * 1024 * 1024
  static let timeout: TimeInterval = 15

  private var webView: WKWebView?
  private var readyContinuations: [CheckedContinuation<Void, Error>] = []
  private var isReady = false

  private func bridgeScript() -> String {
    return """
    (function () {
      var inflight = new Map();
      window.__awakeHttpResolve = function (id, payload) {
        var resolve = inflight.get(id);
        if (!resolve) { return; }
        inflight.delete(id);
        resolve(payload);
      };
      function http(req) {
        return new Promise(function (resolve) {
          var id = String(Date.now()) + "-" + String(Math.random()).slice(2);
          inflight.set(id, resolve);
          try {
            window.webkit.messageHandlers.awakeHttp.postMessage({
              id: id,
              url: req.url,
              method: req.method || "GET",
              headers: req.headers || [],
              body: req.body || null,
              body_base64: req.body_base64 || null
            });
          } catch (e) {
            inflight.delete(id);
            resolve({ status: 0, url: req.url, headers: [], body_base64: "", error: String(e) });
          }
        });
      }
      AwakeSandbox.configurePluginHost({
        readCode: function () { return Promise.reject(new Error("iOS 沙箱不经读盘取代码")); },
        http: http
      });
      window.__awake = {
        validate: function (code) {
          var r = AwakeSandbox.validatePluginCode(code);
          return { platform: r.platform, hasSearch: r.hasSearch };
        },
        search: async function (code, query, page) {
          var exports = AwakeSandbox.instantiatePlugin(code);
          if (typeof exports.search !== "function") {
            throw new Error("这个插件没有实现 search");
          }
          var raw = await exports.search(query, page, "music");
          var norm = AwakeSandbox.normalizeSearch(raw);
          return {
            isEnd: norm.isEnd,
            items: norm.items.map(function (i) {
              return {
                title: i.title,
                artist: i.artist,
                album: i.album,
                duration: i.duration,
                artwork: i.artwork,
                itemID: i.id === null || i.id === undefined ? "" : String(i.id),
                raw: i.raw
              };
            })
          };
        },
        resolve: async function (code, itemJSON) {
          var exports = AwakeSandbox.instantiatePlugin(code);
          if (typeof exports.getMediaSource !== "function") {
            throw new Error("这个插件没有实现 getMediaSource，无法播放");
          }
          var item = JSON.parse(itemJSON);
          var raw = await exports.getMediaSource(item, "standard");
          var norm = AwakeSandbox.normalizeMediaSource(raw);
          if (!norm) { throw new Error("插件没有给出可播放的地址"); }
          return { url: norm.url, headers: norm.headers };
        }
      };
    })();
    """
  }

  private func makeWebView() throws -> WKWebView {
    guard let resource = Bundle.main.url(forResource: "pluginSandbox", withExtension: "js"),
      let library = try? String(contentsOf: resource, encoding: .utf8)
    else { throw AppFailure("沙箱脚本 pluginSandbox.js 缺失") }
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    let controller = WKUserContentController()
    controller.addUserScript(
      WKUserScript(source: library, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    controller.addUserScript(
      WKUserScript(source: bridgeScript(), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    controller.add(self, name: "awakeHttp")
    config.userContentController = controller
    let view = WKWebView(frame: .zero, configuration: config)
    view.navigationDelegate = self
    view.isOpaque = false
    view.loadHTMLString("<html><body></body></html>", baseURL: nil)
    return view
  }

  private func ensureReady() async throws -> WKWebView {
    if let view = webView, isReady { return view }
    if webView == nil {
      webView = try makeWebView()
    }
    if isReady, let view = webView { return view }
    try await withCheckedThrowingContinuation { continuation in
      readyContinuations.append(continuation)
    }
    guard let view = webView else { throw AppFailure("沙箱没有起来") }
    return view
  }

  func validate(_ code: String) async throws -> (platform: String, hasSearch: Bool) {
    let view = try await ensureReady()
    let value = try await view.callAsyncJavaScript(
      "return window.__awake.validate(code);",
      arguments: ["code": code], in: nil, contentWorld: .page)
    guard let dict = value as? [String: Any] else {
      throw AppFailure("沙箱没有返回校验结果")
    }
    return (dict["platform"] as? String ?? "", dict["hasSearch"] as? Bool ?? false)
  }

  func search(code: String, query: String, page: Int) async throws -> [PluginHit] {
    let view = try await ensureReady()
    let value = try await view.callAsyncJavaScript(
      "return await window.__awake.search(code, query, page);",
      arguments: ["code": code, "query": query, "page": page], in: nil, contentWorld: .page)
    guard let dict = value as? [String: Any] else {
      throw AppFailure("插件没有返回搜索结果")
    }
    let items = dict["items"] as? [[String: Any]] ?? []
    return items.map { item in
      var json = "{}"
      if let raw = item["raw"], let data = try? JSONSerialization.data(withJSONObject: raw) {
        json = String(decoding: data, as: UTF8.self)
      }
      return PluginHit(
        title: item["title"] as? String ?? "",
        artist: item["artist"] as? String ?? "",
        album: item["album"] as? String ?? "",
        duration: (item["duration"] as? NSNumber)?.doubleValue ?? 0,
        artwork: item["artwork"] as? String ?? "",
        itemID: item["itemID"] as? String ?? "",
        rawJSON: json)
    }
  }

  /// 让插件把一条 musicItem 解析成可播放地址 + 请求头（S3）。
  func resolve(code: String, itemJSON: String) async throws -> (url: String, headers: [[String]]) {
    let view = try await ensureReady()
    let value = try await view.callAsyncJavaScript(
      "return await window.__awake.resolve(code, itemJSON);",
      arguments: ["code": code, "itemJSON": itemJSON], in: nil, contentWorld: .page)
    guard let dict = value as? [String: Any], let url = dict["url"] as? String, !url.isEmpty else {
      throw AppFailure("插件没有给出可播放的地址")
    }
    let headers = dict["headers"] as? [[String]] ?? []
    return (url, headers)
  }
}

extension PluginSandbox: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isReady = true
    let waiters = readyContinuations
    readyContinuations = []
    for waiter in waiters { waiter.resume() }
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    let waiters = readyContinuations
    readyContinuations = []
    for waiter in waiters { waiter.resume(throwing: error) }
  }
}

extension PluginSandbox: WKScriptMessageHandler {
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.name == "awakeHttp", let body = message.body as? [String: Any],
      let id = body["id"] as? String
    else { return }
    Task { await forward(id: id, body: body) }
  }

  private func forward(id: String, body: [String: Any]) async {
    do {
      let result = try await PluginHTTP.perform(body)
      let payload: [String: Any] = [
        "status": result.status,
        "url": result.url,
        "headers": result.headers,
        "body_base64": result.data.base64EncodedString(),
      ]
      try await resolve(id: id, payload: payload)
    } catch {
      try? await resolve(
        id: id,
        payload: [
          "status": 0, "url": body["url"] as? String ?? "", "headers": [] as [Any],
          "body_base64": "", "error": error.localizedDescription,
        ])
    }
  }

  private func resolve(id: String, payload: [String: Any]) async throws {
    guard let view = webView else { return }
    let data = try JSONSerialization.data(withJSONObject: payload)
    let json = String(decoding: data, as: UTF8.self)
    let idData = try JSONSerialization.data(withJSONObject: [id])
    let idJSON = String(decoding: idData, as: UTF8.self)
    let quotedID = String(idJSON.dropFirst().dropLast())
    _ = try await view.evaluateJavaScript(
      "window.__awakeHttpResolve(\(quotedID), \(json));")
  }
}

/// 沙箱的 fetch 落到这里：地址、方法、体量、超时都有上限，只放 http/https。
enum PluginHTTP {
  struct Result {
    var status: Int
    var url: String
    var headers: [[String]]
    var data: Data
  }

  static func perform(_ body: [String: Any]) async throws -> Result {
    let raw = (body["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { throw AppFailure("插件请求了不支持的地址协议：\(raw.prefix(80))") }
    var request = URLRequest(url: url)
    request.httpMethod = (body["method"] as? String ?? "GET").uppercased()
    request.timeoutInterval = PluginSandbox.timeout
    for pair in body["headers"] as? [[String]] ?? [] where pair.count >= 2 {
      request.setValue(pair[1], forHTTPHeaderField: pair[0])
    }
    if let text = body["body"] as? String, !text.isEmpty {
      guard text.utf8.count <= PluginSandbox.maxRequestBytes else {
        throw AppFailure("插件请求体超过 2 MB")
      }
      request.httpBody = Data(text.utf8)
    } else if let encoded = body["body_base64"] as? String, !encoded.isEmpty {
      guard let data = Data(base64Encoded: encoded) else { throw AppFailure("请求体不是合法 base64") }
      guard data.count <= PluginSandbox.maxRequestBytes else {
        throw AppFailure("插件请求体超过 2 MB")
      }
      request.httpBody = data
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw AppFailure("插件请求没有拿到 HTTP 响应")
    }
    guard data.count <= PluginSandbox.maxResponseBytes else {
      throw AppFailure("插件响应超过 8 MB，已拒绝")
    }
    var headers: [[String]] = []
    for (key, value) in http.allHeaderFields {
      headers.append([String(describing: key), String(describing: value)])
    }
    return Result(
      status: http.statusCode, url: http.url?.absoluteString ?? raw, headers: headers, data: data)
  }
}
