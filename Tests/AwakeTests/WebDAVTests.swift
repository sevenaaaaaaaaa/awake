import XCTest
@testable import AwakeCore

final class WebDAVTests: XCTestCase {
    func testMultistatusParsing() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
          <d:response><d:href>/dav/a%20b.flac</d:href><d:propstat><d:prop><d:getcontentlength>42</d:getcontentlength></d:prop></d:propstat></d:response>
        </d:multistatus>
        """
        let entries = WebDAVMultistatus.parse(Data(xml.utf8))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].href, "/dav/a%20b.flac")
        XCTAssertEqual(entries[1].size, 42)
    }

    func testLiveScan() async throws {
        guard let address = ProcessInfo.processInfo.environment["AWAKE_DAV_URL"] else {
            throw XCTSkip("AWAKE_DAV_URL 未设置")
        }
        let source = MediaSource(kind: .webdav, name: "Live", url: address)
        let tracks = try await WebDAVMusicProvider().scan(source: source) { _, _ in }
        print("LIVE_TRACKS \(tracks.map(\.locator))")
        XCTAssertGreaterThan(tracks.count, 0)
    }
}
