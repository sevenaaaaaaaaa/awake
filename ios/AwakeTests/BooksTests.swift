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

  func testHTMLStripRemovesScriptAndKeepsText() {
    let text = NewsService.stripHTML(
      "<html><head><title>标题</title><style>.a{}</style></head><body><p>第一段 &amp; 内容</p><script>alert(1)</script><p>第二段</p></body></html>"
    )
    XCTAssertTrue(text.contains("第一段 & 内容"))
    XCTAssertTrue(text.contains("第二段"))
    XCTAssertFalse(text.contains("alert"))
  }
}
