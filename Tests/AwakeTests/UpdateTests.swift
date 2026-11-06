import XCTest
@testable import AwakeCore

final class UpdateTests: XCTestCase {
    // MARK: - Version

    func testVersionOrdering() throws {
        XCTAssertLessThan(AppVersion("0.1.0")!, AppVersion("0.1.1")!)
        XCTAssertLessThan(AppVersion("0.9.9")!, AppVersion("1.0.0")!)
        XCTAssertLessThan(AppVersion("0.1")!, AppVersion("0.1.1")!)
        XCTAssertFalse(AppVersion("0.2")! < AppVersion("0.2.0")!)
        XCTAssertEqual(AppVersion("v0.1.1")!.description, "0.1.1")
        XCTAssertEqual(AppVersion("0.2.0-beta.1")!.description, "0.2.0")
        XCTAssertNil(AppVersion("nightly"))
        XCTAssertNil(AppVersion(""))
    }

    // MARK: - Asset selection

    func testAssetSelectionPrefersAppleSiliconArchive() {
        let assets = [
            ReleaseAsset(name: "Awake-0.1.1-macos-arm64.zip", size: 30_000_000,
                         browserDownloadURL: URL(string: "https://example.com/arm64.zip")!),
            ReleaseAsset(name: "Awake-0.1.1-macos-x86_64.zip", size: 31_000_000,
                         browserDownloadURL: URL(string: "https://example.com/x86.zip")!),
            ReleaseAsset(name: "checksums.txt", size: 200,
                         browserDownloadURL: URL(string: "https://example.com/checksums.txt")!)
        ]
        XCTAssertEqual(UpdateChecker.selectAsset(from: assets)?.name, "Awake-0.1.1-macos-arm64.zip")
        XCTAssertEqual(UpdateChecker.selectAsset(from: Array(assets.dropFirst()))?.name,
                       "Awake-0.1.1-macos-x86_64.zip")
        XCTAssertNil(UpdateChecker.selectAsset(from: Array(assets.dropFirst(2))))
    }

    // MARK: - Decoding

    func testDecodesGitHubReleasePayload() throws {
        let release = try JSONDecoder().decode(LatestRelease.self, from: Data(payload(tag: "v0.1.1").utf8))
        XCTAssertEqual(release.tagName, "v0.1.1")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/sevenaaaaaaaaa/awake/releases/tag/v0.1.1")
        XCTAssertEqual(release.assets.count, 2)
        XCTAssertEqual(release.assets.first?.size, 30_234_574)
        XCTAssertTrue(release.body?.contains("在线更新") ?? false)
    }

    // MARK: - Check

    func testCheckReportsAvailableUpdate() async throws {
        MockURLProtocol.status = 200
        MockURLProtocol.body = Data(payload(tag: "v0.1.1").utf8)
        let outcome = try await UpdateChecker.check(currentVersion: "0.1.0",
                                                    feed: URL(string: "https://updates.test/latest")!,
                                                    session: Self.session())
        guard case .available(let info) = outcome else {
            return XCTFail("expected available, got \(outcome)")
        }
        XCTAssertEqual(info.version, "0.1.1")
        XCTAssertEqual(info.currentVersion, "0.1.0")
        XCTAssertEqual(info.assetName, "Awake-0.1.1-macos-arm64.zip")
        XCTAssertEqual(info.assetSize, 30_234_574)
        XCTAssertTrue(info.isNewer)
    }

    func testCheckReportsUpToDate() async throws {
        MockURLProtocol.status = 200
        MockURLProtocol.body = Data(payload(tag: "v0.1.1").utf8)
        let outcome = try await UpdateChecker.check(currentVersion: "0.1.1",
                                                    feed: URL(string: "https://updates.test/latest")!,
                                                    session: Self.session())
        XCTAssertEqual(outcome, .upToDate(version: "0.1.1"))
    }

    func testCheckMapsMissingRelease() async {
        MockURLProtocol.status = 404
        MockURLProtocol.body = Data("{}".utf8)
        do {
            _ = try await UpdateChecker.check(currentVersion: "0.1.0",
                                              feed: URL(string: "https://updates.test/latest")!,
                                              session: Self.session())
            XCTFail("expected noRelease")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .noRelease)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCheckRejectsReleaseWithoutCompatibleAsset() async {
        MockURLProtocol.status = 200
        MockURLProtocol.body = Data(payload(tag: "v0.1.2", assets: [
            ("checksums.txt", 128)
        ]).utf8)
        do {
            _ = try await UpdateChecker.check(currentVersion: "0.1.0",
                                              feed: URL(string: "https://updates.test/latest")!,
                                              session: Self.session())
            XCTFail("expected noCompatibleAsset")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .noCompatibleAsset)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Helpers

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func payload(tag: String,
                         assets: [(String, Int)] = [
                            ("Awake-0.1.1-macos-arm64.zip", 30_234_574),
                            ("checksums.txt", 200)
                         ]) -> String {
        let assetJSON = assets.map { name, size in
            """
            {
              "name": "\(name)",
              "size": \(size),
              "browser_download_url": "https://github.com/sevenaaaaaaaaa/awake/releases/download/\(tag)/\(name)"
            }
            """
        }.joined(separator: ",\n")
        return """
        {
          "tag_name": "\(tag)",
          "name": "Awake \(tag)",
          "body": "## 在线更新\\n\\n- 新增原生更新\\n- 修复若干问题",
          "html_url": "https://github.com/sevenaaaaaaaaa/awake/releases/tag/\(tag)",
          "published_at": "2026-11-06T08:00:00Z",
          "assets": [\(assetJSON)]
        }
        """
    }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: Self.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
