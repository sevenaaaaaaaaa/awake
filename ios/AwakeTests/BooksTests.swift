import AVFoundation
import XCTest

@testable import Awake

final class BooksTests: XCTestCase {
  private func song(
    _ id: String, _ title: String, album: String = "三体", artist: String = "刘慈欣",
    duration: Double = 600
  ) -> Song {
    var song = Song(title: title, album: album, duration: duration)
    song.id = id
    song.artist = artist
    return song
  }

  func testChaptersSortNaturallyAndResume() {
    let second = song("b", "第2章 迷", duration: 1200)
    let tenth = song("c", "第10章 尾声", duration: 900)
    let first = song("a", "第1章 序", duration: 600)
    let progress = [
      "album|三体|刘慈欣": BookProgress(
        songID: "b", position: 300, finished: false, updatedAt: Date())
    ]
    let books = BookShelf.shelf([tenth, second, first], progress: progress)
    XCTAssertEqual(books.count, 1)
    XCTAssertEqual(books[0].chapters.map(\.title), ["第1章 序", "第2章 迷", "第10章 尾声"])
    XCTAssertEqual(books[0].listened, 600 + 300, accuracy: 0.5)
    XCTAssertEqual(books[0].currentSongID, "b")
  }

  func testShortMusicIsNotABook() {
    let songs = (0..<4).map { song("\($0)", "歌 \($0)", duration: 240) }
    XCTAssertTrue(BookShelf.shelf(songs, progress: [:]).isEmpty)
    let long = [song("long", "长音频", album: "", duration: 3600)]
    XCTAssertEqual(BookShelf.shelf(long, progress: [:]).count, 1)
  }

  func testWeeklySummaryUsesCurrentWeekWindow() {
    var calendar = Calendar(identifier: .iso8601)
    calendar.firstWeekday = 2
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let empty = WeeklySummary.make(songs: [], listens: [], progress: [:], now: now, calendar: calendar)
    let a = song("a", "A", album: "专辑", duration: 200)
    let b = song("b", "B", album: "专辑", duration: 200)
    let listens = [
      Listen(songID: "a", seconds: 150, at: empty.since.addingTimeInterval(3600)),
      Listen(songID: "b", seconds: 150, at: empty.since.addingTimeInterval(7200)),
      Listen(songID: "b", seconds: 150, at: empty.since.addingTimeInterval(-3600)),
    ]
    let summary = WeeklySummary.make(
      songs: [a, b], listens: listens, progress: [:], now: now, calendar: calendar)
    XCTAssertEqual(summary.plays, 2)
    XCTAssertEqual(summary.seconds, 300, accuracy: 0.5)
    XCTAssertEqual(summary.topSongs.first?.song.id, "a")
    XCTAssertEqual(summary.days.reduce(0) { $0 + $1.seconds }, 300, accuracy: 0.5)
    XCTAssertFalse(summary.lines.isEmpty)
  }

  func testPlannerSplitsChaptersAndDramaSpeakers() {
    let book = TextPlanner.plan(
      title: "", author: "", mode: "book",
      text: "第一章 雨夜\n城市在雨里安静下来。\n第二章 来信\n信躺在门口。")
    XCTAssertEqual(book.chapters.count, 2)
    XCTAssertEqual(book.chapters[0].title, "第一章 雨夜")
    let drama = TextPlanner.plan(
      title: "小戏", author: "", mode: "drama",
      text: "旁白：夜色降临。\n小明：我们走吧。\n小红：等一下。")
    let speakers = drama.chapters[0].segments.map(\.speaker)
    XCTAssertTrue(speakers.contains("小明"))
    XCTAssertTrue(speakers.contains("小红"))
  }

  func testFolderBooksGroupUntaggedChapters() {
    var first = song("f1", "第2章", album: "", duration: 300)
    first.folder = "三体 有声书"
    var second = song("f2", "第10章", album: "", duration: 300)
    second.folder = "三体 有声书"
    let books = BookShelf.shelf([second, first], progress: [:])
    XCTAssertEqual(books.count, 1)
    XCTAssertEqual(books[0].title, "三体 有声书")
    XCTAssertEqual(books[0].chapters.count, 2)
  }

  func testPlexParsesAllConnectionsAndSkipsUnsafeURLs() {
    let rows: [[String: Any]] = [
      [
        "name": "客厅", "clientIdentifier": "abc", "provides": "server",
        "connections": [
          ["uri": "https://192-168-1-5.hash.plex.direct:32400", "local": true, "relay": false],
          ["uri": "http://192.168.1.5:32400", "local": true, "relay": false],
          ["uri": "https://user:pass@example.com:32400", "local": false, "relay": false],
        ],
      ],
      [
        "name": "朋友的服务器", "clientIdentifier": "def", "provides": "server",
        "accessToken": "shared", "connections": [
          ["uri": "https://relay.plex.direct:443", "local": false, "relay": true]
        ],
      ],
    ]
    let servers = PlexAuth.parseServers(rows, token: "account", requireServer: true)
    XCTAssertEqual(servers.count, 3)
    XCTAssertTrue(servers.allSatisfy { URL(string: $0.uri)?.user == nil })
    XCTAssertTrue(servers.contains { $0.connection == "本地 · HTTPS" })
    XCTAssertTrue(servers.contains { $0.connection == "本地 · HTTP" })
    XCTAssertTrue(servers.contains { $0.name == "朋友的服务器" && $0.accessToken == "shared" })
  }

  @MainActor func testSpeechRendererWritesPlayableBook() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MobileStore(root: root)
    let plan = TextPlanner.plan(
      title: "合成测试", author: "测试作者", mode: "book",
      text: "第一章 开始\n你好，这是测试。")
    let songs = try await SpeechRenderer.render(plan, store: store)
    XCTAssertEqual(songs.count, 1)
    let name = try XCTUnwrap(songs.first?.file)
    let url = store.music.appendingPathComponent(name)
    let audio = try AVAudioFile(forReading: url)
    XCTAssertGreaterThan(audio.length, 0)
    XCTAssertEqual(songs.first?.album, "合成测试")
  }

  func testHTMLStripRemovesScriptAndKeepsText() {
    let text = NewsService.stripHTML(
      "<html><head><title>标题</title><style>.a{}</style></head><body><p>第一段 &amp; 内容</p><script>alert(1)</script><p>第二段</p></body></html>"
    )
    XCTAssertTrue(text.contains("第一段 & 内容"))
    XCTAssertTrue(text.contains("第二段"))
    XCTAssertFalse(text.contains("alert"))
  }
}
