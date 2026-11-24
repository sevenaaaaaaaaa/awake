import SwiftUI

/// 批量刮削的界面：按专辑分组，逐张或全部补齐；运行中可停，结束后给失败清单。
struct BatchScrapeView: View {
  @EnvironmentObject var store: MobileStore
  @StateObject private var scraper = BatchScraper()
  @State private var task: Task<Void, Never>?

  var body: some View {
    Form {
      Section("全部") {
        Button("补全全部（\(store.state.songs.count) 首）") {
          start(store.state.songs)
        }.disabled(scraper.running || store.state.songs.isEmpty)
        if scraper.running {
          ProgressView(value: Double(scraper.done), total: Double(max(scraper.total, 1))) {
            Text("\(scraper.done)/\(scraper.total)").font(.caption)
          }
          Button("停止", role: .destructive) { task?.cancel() }
        }
        AwakeNote(text: "顺序请求，约每秒一次；只补缺的歌词与封面，已有内容不覆盖。关掉页面会中断。")
      }
      if scraper.finished {
        Section("结果") {
          Text("完成 \(scraper.done) 首 · 失败 \(scraper.failures.count) 条")
          ForEach(scraper.failures) { failure in
            VStack(alignment: .leading, spacing: 2) {
              Text("\(failure.title) · \(failure.step)").font(.caption)
              Text(failure.message).font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
      }
      Section("按专辑 / 文件夹") {
        ForEach(BatchScraper.groups(store.state.songs)) { group in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(group.title).font(.subheadline)
              Text(group.detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("补这张") { start(group.songs) }.disabled(scraper.running)
          }
        }
      }
    }
    .appSurface()
    .navigationTitle("批量补全资料")
    .onDisappear { task?.cancel() }
  }

  private func start(_ songs: [Song]) {
    task?.cancel()
    task = Task { await scraper.run(songs, store: store) }
  }
}
