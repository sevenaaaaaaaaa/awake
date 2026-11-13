import Foundation

/// Plex 账号授权（PIN）流程、服务器发现、线路探测与音乐库分区。
/// 只访问 plex.tv 的公开接口；真正播放仍由用户选中的服务器地址与 Token 完成。
enum PlexAuth {
  struct Pin { let id: Int; let code: String }

  struct Server: Identifiable, Hashable {
    var id: String { clientID + "|" + uri }
    let clientID: String
    let name: String
    let uri: String
    let accessToken: String
    /// 「本地 / 远程 / 中继 · HTTPS」。
    let connection: String
    let owned: Bool
  }

  struct Section: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let title: String
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
    URL(
      string:
        "https://app.plex.tv/auth#?clientID=\(clientID)&code=\(pin.code)&context%5Bdevice%5D%5Bproduct%5D=Awake"
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
    var result = parseServers(rows, token: token, requireServer: true)
    if result.isEmpty {
      // 某些 Plex 版本对共享服务器的 provides 标注不完整。
      result = parseServers(rows, token: token, requireServer: false)
    }
    return result.sorted {
      if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      return rank($0.connection) < rank($1.connection)
    }
  }

  static func parseServers(
    _ rows: [[String: Any]], token: String, requireServer: Bool
  ) -> [Server] {
    var result: [Server] = []
    var seen = Set<String>()
    for row in rows {
      if requireServer {
        guard let provides = row["provides"] as? String, provides.contains("server") else {
          continue
        }
      }
      guard let connections = row["connections"] as? [[String: Any]] else { continue }
      let serverToken = (row["accessToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? token
      let clientID = row["clientIdentifier"] as? String ?? UUID().uuidString
      let name = row["name"] as? String ?? "Plex 服务器"
      for connection in connections {
        guard let uri = connection["uri"] as? String,
          let parsed = URL(string: uri),
          ["http", "https"].contains(parsed.scheme ?? ""),
          parsed.host != nil, parsed.user == nil, parsed.password == nil
        else { continue }
        let clean = uri.hasSuffix("/") ? String(uri.dropLast()) : uri
        guard seen.insert(clientID + "|" + clean).inserted else { continue }
        let relay = connection["relay"] as? Bool ?? false
        let local = connection["local"] as? Bool ?? false
        let secure = (parsed.scheme ?? "") == "https"
        let label = relay ? "中继" : (local ? "本地" : "远程")
        result.append(
          Server(
            clientID: clientID, name: name, uri: clean, accessToken: serverToken,
            connection: label + " · " + (secure ? "HTTPS" : "HTTP"),
            owned: row["owned"] as? Bool ?? false))
      }
    }
    return result
  }

  private static func rank(_ connection: String) -> Int {
    if connection.hasPrefix("本地") { return connection.contains("HTTPS") ? 0 : 2 }
    if connection.hasPrefix("远程") { return connection.contains("HTTPS") ? 1 : 3 }
    if connection.hasPrefix("中继") { return 4 }
    return 5
  }

  static func probe(_ server: Server) async -> Bool {
    guard let url = URL(string: server.uri + "/identity") else { return false }
    var request = URLRequest(url: url)
    request.timeoutInterval = 8
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    request.setValue(server.accessToken, forHTTPHeaderField: "X-Plex-Token")
    do {
      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { return false }
      return (200..<300).contains(http.statusCode)
    } catch { return false }
  }

  static func sections(_ server: Server) async throws -> [Section] {
    guard let url = URL(string: server.uri + "/library/sections") else {
      throw AppFailure("Plex 地址无效")
    }
    var request = URLRequest(url: url)
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    request.setValue(server.accessToken, forHTTPHeaderField: "X-Plex-Token")
    let data = try await raw(request)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let container = json["MediaContainer"] as? [String: Any],
      let rows = container["Directory"] as? [[String: Any]]
    else { throw AppFailure("Plex 音乐库列表格式无法识别") }
    return rows.compactMap { row in
      guard let key = row["key"] as? String, !key.isEmpty else { return nil }
      let type = row["type"] as? String ?? ""
      guard ["artist", "music"].contains(type) else { return nil }
      return Section(key: key, title: row["title"] as? String ?? "音乐库")
    }
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
