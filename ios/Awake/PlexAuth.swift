import Foundation

/// Plex 账号授权（PIN）流程与服务器发现。
/// 只访问 plex.tv 的公开 PIN 接口；真正播放仍由用户选中的服务器地址与 Token 完成。
enum PlexAuth {
  struct Pin { let id: Int; let code: String }

  struct Server: Identifiable, Hashable {
    var id: String { clientID }
    let clientID: String
    let name: String
    let uri: String
    let accessToken: String
    let owned: Bool
  }

  static let product = "Awake"

  static var clientID: String {
    let key = "awake.plex.clientID"
    if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty { return value }
    let value = UUID().uuidString.lowercased()
    UserDefaults.standard.set(value, forKey: key)
    return value
  }

  private static let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 20
    c.timeoutIntervalForResource = 40
    c.httpShouldSetCookies = false
    return URLSession(configuration: c)
  }()

  private static var headers: [String: String] {
    [
      "X-Plex-Client-Identifier": clientID,
      "X-Plex-Product": product,
      "X-Plex-Version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "0",
      "Accept": "application/json",
    ]
  }

  static func createPin() async throws -> Pin {
    guard let url = URL(string: "https://plex.tv/api/v2/pins?strong=true") else {
      throw AppFailure("Plex 地址无效")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    let json = try await object(request)
    guard let id = json["id"] as? Int ?? (json["id"] as? NSNumber)?.intValue,
      let code = json["code"] as? String, !code.isEmpty
    else { throw AppFailure("Plex 没有返回授权码，请稍后重试") }
    return Pin(id: id, code: code)
  }

  /// 返回 authToken；用户尚未在浏览器完成授权时返回 nil。
  static func poll(_ pin: Pin) async throws -> String? {
    guard let url = URL(string: "https://plex.tv/api/v2/pins/\(pin.id)?code=\(pin.code)") else {
      throw AppFailure("Plex 地址无效")
    }
    var request = URLRequest(url: url)
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    let json = try await object(request)
    if let token = json["authToken"] as? String, !token.isEmpty { return token }
    return nil
  }

  static func authURL(_ pin: Pin) -> URL {
    let context = "context%5Bdevice%5D%5Bproduct%5D=Awake"
    return URL(
      string:
        "https://app.plex.tv/auth#?clientID=\(clientID)&code=\(pin.code)&(context)"
    )!
  }

  static func servers(token: String) async throws -> [Server] {
    guard
      let url = URL(
        string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeClients=1")
    else { throw AppFailure("Plex 地址无效") }
    var request = URLRequest(url: url)
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
    let data = try await raw(request)
    guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw AppFailure("Plex 服务器列表格式无法识别")
    }
    var result: [Server] = []
    for row in rows {
      guard let provides = row["provides"] as? String, provides.contains("server"),
        let connections = row["connections"] as? [[String: Any]]
      else { continue }
      let serverToken = (row["accessToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? token
      let chosen = connection(connections)
      guard let chosen else { continue }
      result.append(
        Server(
          clientID: row["clientIdentifier"] as? String ?? UUID().uuidString,
          name: row["name"] as? String ?? "Plex 服务器",
          uri: chosen,
          accessToken: serverToken,
          owned: row["owned"] as? Bool ?? false))
    }
    return result.sorted { ($0.owned ? 0 : 1, $0.name) < ($1.owned ? 0 : 1, $1.name) }
  }

  private static func connection(_ connections: [[String: Any]]) -> String? {
    var ranked: [(Int, String)] = []
    for connection in connections {
      guard let uri = connection["uri"] as? String, !uri.isEmpty else { continue }
      let relay = connection["relay"] as? Bool ?? false
      let local = connection["local"] as? Bool ?? false
      let https = uri.lowercased().hasPrefix("https://")
      let score = relay ? 4 : (https ? (local ? 1 : 0) : 2)
      ranked.append((score, uri.hasSuffix("/") ? String(uri.dropLast()) : uri))
    }
    return ranked.sorted { $0.0 < $1.0 }.first?.1
  }

  private static func object(_ request: URLRequest) async throws -> [String: Any] {
    let data = try await raw(request)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AppFailure("Plex 返回了无法识别的数据")
    }
    return json
  }

  private static func raw(_ request: URLRequest) async throws -> Data {
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw AppFailure("Plex 没有返回 HTTP 响应")
      }
      guard (200..<300).contains(http.statusCode) else {
        if http.statusCode == 401 {
          throw AppFailure("Plex 授权已失效（401），请重新登录")
        }
        throw AppFailure("Plex 返回 HTTP \(http.statusCode)，请检查网络后重试")
      }
      return data
    } catch let error as AppFailure {
      throw error
    } catch {
      throw AppFailure("连接 Plex 失败：\(error.localizedDescription)。中国大陆网络可能需要代理才能访问 plex.tv。")
    }
  }
}
