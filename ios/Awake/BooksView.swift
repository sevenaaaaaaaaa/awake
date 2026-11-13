import SwiftUI
import UniformTypeIdentifiers

struct BooksHubView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @State private var section = 0
  @State private var narration: SpeechPlan?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Picker("听书功能", selection: $section) {
          Text("书架").tag(0)
          Text("AI 拆书 / 拆剧").tag(1)
          Text("新闻播报").tag(2)
        }.pickerStyle(.segmented).accessibilityIdentifier("booksHubPicker")

        if section == 0 {
          ShelfSection(books: store.books()) { plan in narration = plan }
        } else if section == 1 {
          SpeechStudioSection(onNarrate: { narration = $0 })
        } else {
          NewsSection(onNarrate: { narration = $0 })
        }
      }.padding(20)
    }
    .appSurface()
    .navigationTitle("听书与播报")
    .sheet(item: $narration) { plan in NarratorSheet(plan: plan) }
  }
}

private struct ShelfSection: View {
  @EnvironmentObject var store: MobileStore
  let books: [Book]
  let onNarrate: (SpeechPlan) -> Void

  var body: some View {
    if books.isEmpty {
      Panel {
        Label("书架还空着", systemImage: "book.closed").font(.headline)
        Text("导入有声书文件夹（m4b / mp3 / m4a）后，会按专辑或书名归并；也可以到「AI 拆书」把一段文字变成可朗读的章节。")
          .font(.subheadline).foregroundStyle(.secondary)
      }
    } else {
      ForEach(books) { book in
        NavigationLink {
          BookDetailView(book: book)
        } label: {
          BookRow(book: book)
        }.buttonStyle(.plain)
      }
    }
  }
}

private struct BookRow: View {
  @EnvironmentObject var store: MobileStore
  let book: Book

  var body: some View {
    Panel {
      HStack(spacing: 14) {
        Cover(title: book.title, artwork: book.artwork, size: 62)
        VStack(alignment: .leading, spacing: 6) {
          Text(book.title).font(.headline).lineLimit(2)
          Text("\(book.author.isEmpty ? "未知作者" : book.author) · \(book.chapters.count) 章 · \(book.listenedLabel)")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          ProgressView(value: book.percent).tint(Color(hex: store.state.skin.colors.accent))
          Text(book.finished ? "已听完" : "\(Int(book.percent * 100))%")
            .font(.caption2).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: book.finished ? "checkmark.circle" : "play.circle")
          .font(.title3).foregroundStyle(Color(hex: store.state.skin.colors.accent))
      }
    }
  }
}

struct BookDetailView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  let book: Book

  private var currentIndex: Int {
    guard let id = book.currentSongID else { return 0 }
    return book.chapters.firstIndex { $0.id == id } ?? 0
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 18) {
          Cover(title: book.title, artwork: book.artwork, size: 120)
          VStack(alignment: .leading, spacing: 8) {
            Text(book.title).font(.title2.bold())
            Text(book.author.isEmpty ? "未知作者" : book.author).foregroundStyle(.secondary)
            Text("\(book.chapters.count) 章 · \(book.listenedLabel) / \(Int(book.total / 60)) 分钟")
              .font(.caption).foregroundStyle(.secondary)
            ProgressView(value: book.percent).tint(Color(hex: store.state.skin.colors.accent))
          }
        }
        Button {
          Task {
            await playBook(book, chapterIndex: currentIndex, store: store, player: player)
          }
        } label: {
          Label(book.listened > 0 ? "继续听" : "开始听", systemImage: "play.fill")
            .frame(maxWidth: .infinity)
        }.buttonStyle(AwakeButtonStyle())
          .accessibilityIdentifier("continueBook")

        VStack(spacing: 0) {
          ForEach(Array(book.chapters.enumerated()), id: \.offset) { index, chapter in
            Button {
              Task { await playBook(book, chapterIndex: index, store: store, player: player) }
            } label: {
              HStack(spacing: 12) {
                Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                  Text(chapter.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                  Text(clock(chapter.duration)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if player.song?.id == chapter.id {
                  Image(systemName: "waveform").foregroundStyle(Color(hex: store.state.skin.colors.accent))
                } else {
                  Image(systemName: "play").font(.caption).foregroundStyle(.secondary)
                }
              }.padding(.vertical, 11)
            }.buttonStyle(.plain)
            Divider()
          }
        }
      }.padding(20)
    }
    .appSurface()
    .navigationTitle(book.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

@MainActor func playBook(
  _ book: Book, chapterIndex: Int, store: MobileStore, player: MobilePlayer
) async {
  guard book.chapters.indices.contains(chapterIndex) else { return }
  let chapter = book.chapters[chapterIndex]
  guard let url = store.localURL(chapter) else {
    store.message = "这一章的音频还不在本机，请先导入或缓存对应文件。"
    return
  }
  var queue: [(Song, URL)] = []
  var target = 0
  for song in book.chapters {
    guard let file = store.localURL(song) else { continue }
    if song.id == chapter.id { target = queue.count }
    queue.append((song, file))
  }
  let from = book.currentSongID == chapter.id ? book.position : 0
  player.play(queue, at: target, from: from)
}

private struct SpeechStudioSection: View {
  @EnvironmentObject var store: MobileStore
  let onNarrate: (SpeechPlan) -> Void
  @State private var mode = "book"
  @State private var title = ""
  @State private var author = ""
  @State private var text = ""
  @State private var plan: SpeechPlan?
  @State private var importing = false
  @State private var cloud = false
  @State private var rendering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker("模式", selection: $mode) {
        Text("有声书（拆书）").tag("book")
        Text("广播剧（拆剧）").tag("drama")
      }.pickerStyle(.segmented)

      Panel {
        TextField("书名 / 剧名（可留空）", text: $title)
        TextField("作者（可选）", text: $author)
        Button {
          importing = true
        } label: {
          Label("导入 .txt / .md", systemImage: "folder")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { result in
          do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            text = try String(contentsOf: url, encoding: .utf8)
            if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
          } catch { store.message = error.localizedDescription }
        }
        TextEditor(text: $text)
          .frame(minHeight: 170)
          .padding(8)
          .background(Color(hex: store.state.skin.colors.bg).opacity(0.5))
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay(alignment: .topLeading) {
            if text.isEmpty {
              Text("粘贴小说、文章或剧本全文。拆剧建议每行写成「角色：台词」。")
                .font(.caption).foregroundStyle(.secondary).padding(16).allowsHitTesting(false)
            }
          }
        if !store.state.curatorModel.isEmpty {
          Toggle("用云端 AI 智能分章（会发送本次文本）", isOn: $cloud)
            .font(.caption)
        }
        Button {
          Task { await preview() }
        } label: {
          Label("预览分章", systemImage: "text.append").frame(maxWidth: .infinity)
        }.buttonStyle(AwakeButtonStyle())
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)

        Text("分章与朗读都在本机完成；生成有声书会写入本机曲库并进入听书书架。")
          .font(.caption2).foregroundStyle(.secondary)
      }

      if let plan {
        Panel {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(plan.title).font(.headline)
              Text("\(plan.chapters.count) 章 · \(plan.chapters.reduce(0) { $0 + $1.segments.reduce(0) { $0 + $1.text.count } }) 字")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("开始朗读", systemImage: "waveform") { onNarrate(plan) }
              .buttonStyle(.bordered)
          }
          HStack {
            Button {
              generate(plan)
            } label: {
              Label(rendering ? "正在合成…" : "生成有声书", systemImage: "square.and.arrow.down")
            }.buttonStyle(.borderedProminent).disabled(rendering)
            if rendering { ProgressView().controlSize(.small) }
          }
          if let note = plan.note {
            Text(note).font(.caption2).foregroundStyle(.secondary)
          }
          ForEach(Array(plan.chapters.prefix(30).enumerated()), id: \.offset) { index, chapter in
            HStack {
              Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 22)
              Text(chapter.title).font(.subheadline).lineLimit(1)
              Spacer()
              Text("\(chapter.segments.count) 段").font(.caption2).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
          }
        }
      }

      if !store.speechPlans.isEmpty {
        Panel {
          Text("最近拆分").font(.headline)
          ForEach(Array(store.speechPlans.prefix(5))) { saved in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(saved.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(saved.chapters.count) 章 · \(saved.mode == "drama" ? "广播剧" : "有声书")")
                  .font(.caption2).foregroundStyle(.secondary)
              }
              Spacer()
              Button("朗读") { onNarrate(saved) }.buttonStyle(.bordered)
              Button(role: .destructive) {
                store.speechPlans.removeAll { $0.id == saved.id }
                store.saveSpeechPlans()
              } label: { Image(systemName: "trash") }
            }.padding(.vertical, 5)
          }
        }
      }
    }
  }

  private func preview() async {
    let local = TextPlanner.plan(title: title, author: author, mode: mode, text: text)
    var result = local
    if cloud, !store.state.curatorModel.isEmpty {
      do {
        let key = try store.curatorSecret()
        result = try await TextPlanner.cloudPlan(
          title: title, author: author, mode: mode, text: text,
          base: store.state.curatorURL, model: store.state.curatorModel, key: key)
      } catch {
        result.note = "云端分章失败：\(error.localizedDescription)；已改用本地分章"
      }
    }
    plan = result
    store.speechPlans.removeAll { $0.id == result.id }
    store.speechPlans.insert(result, at: 0)
    store.speechPlans = Array(store.speechPlans.prefix(20))
    store.saveSpeechPlans()
  }

  private func generate(_ plan: SpeechPlan) {
    rendering = true
    Task {
      do {
        let songs = try await SpeechRenderer.render(plan, store: store)
        store.state.songs.append(contentsOf: songs)
        var lists = store.state.playlists ?? []
        lists.append(
          Playlist(name: plan.title, songIDs: songs.map(\.id), note: "AI 拆书"))
        store.state.playlists = lists
        store.save()
        store.message = "已生成《\(plan.title)》\(songs.count) 章，可在听书书架播放"
      } catch {
        store.message = "生成有声书失败：\(error.localizedDescription)"
      }
      rendering = false
    }
  }

}

private struct NewsSection: View {
  @EnvironmentObject var store: MobileStore
  let onNarrate: (SpeechPlan) -> Void
  @State private var link = ""
  @State private var textTitle = ""
  @State private var text = ""
  @State private var loading = false
  @State private var importing = false
  @State private var importingAudio = false
  @State private var cloud = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Panel {
        TextField("新闻 / 文章链接", text: $link)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        Button {
          addLink()
        } label: {
          Label(loading ? "正在读取…" : "加入播报列表", systemImage: "plus")
            .frame(maxWidth: .infinity)
        }.buttonStyle(AwakeButtonStyle())
          .disabled(loading || link.trimmingCharacters(in: .whitespaces).isEmpty)
        Divider()
        TextField("标题（可选）", text: $textTitle)
        TextEditor(text: $text)
          .frame(minHeight: 100)
          .padding(8)
          .background(Color(hex: store.state.skin.colors.bg).opacity(0.5))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        HStack {
          Button("添加文本") { addText() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
          Button("导入 .eml 邮件") { importing = true }
          Button("导入播客音频") { importingAudio = true }
        }.font(.caption)
        Text("只读取你给的链接或本地文件；不登录邮箱，不上传未勾选的内容。")
          .font(.caption2).foregroundStyle(.secondary)
      }

      if store.newsItems.isEmpty {
        Panel {
          Label("还没有导入内容", systemImage: "newspaper").font(.headline)
          Text("加一条公开链接、粘贴正文，或选择一封 .eml 邮件。").font(.subheadline)
            .foregroundStyle(.secondary)
        }
      } else {
        ForEach(store.newsItems.prefix(12)) { item in
          Panel {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(item.source) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                  .font(.caption2).foregroundStyle(.secondary)
                Text(String(item.text.prefix(120)) + "…").font(.caption).foregroundStyle(.secondary).lineLimit(2)
              }
              Spacer()
              Button(role: .destructive) {
                store.newsItems.removeAll { $0.id == item.id }
                store.saveNews()
              } label: { Image(systemName: "xmark.circle") }
            }
          }
        }
        if !store.state.curatorModel.isEmpty {
          Toggle("用云端 AI 摘要（会发送所选内容）", isOn: $cloud).font(.caption)
        }
        Button {
          narrate()
        } label: {
          Label("生成 AI 新闻播报", systemImage: "waveform").frame(maxWidth: .infinity)
        }.buttonStyle(AwakeButtonStyle())
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "eml") ?? .data, .plainText]) { result in
      do {
        let url = try result.get()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let item = NewsService.parseEml(raw, fallback: url.deletingPathExtension().lastPathComponent)
        store.newsItems.insert(item, at: 0)
        store.saveNews()
      } catch { store.message = error.localizedDescription }
    }
    .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
      if case .success(let urls) = result { Task { await store.importFiles(urls) } }
    }
  }

  private func narrate() {
    let items = Array(store.newsItems.prefix(8))
    guard !items.isEmpty else { return }
    if cloud, !store.state.curatorModel.isEmpty {
      Task {
        do {
          let key = try store.curatorSecret()
          let plan = try await NewsService.cloudPlan(
            items, title: "", base: store.state.curatorURL,
            model: store.state.curatorModel, key: key)
          onNarrate(plan)
        } catch {
          store.message = "云端摘要失败：\(error.localizedDescription)；已改用本地摘要"
          onNarrate(NewsService.plan(items, title: ""))
        }
      }
    } else {
      onNarrate(NewsService.plan(items, title: ""))
    }
  }

  private func addLink() {
    loading = true
    Task {
      do {
        let item = try await NewsService.fetch(link)
        store.newsItems.insert(item, at: 0)
        store.newsItems = Array(store.newsItems.prefix(300))
        store.saveNews()
        link = ""
      } catch { store.message = error.localizedDescription }
      loading = false
    }
  }

  private func addText() {
    let item = NewsItem(
      title: textTitle.isEmpty ? "粘贴的新闻" : textTitle, source: "文本", text: text)
    store.newsItems.insert(item, at: 0)
    store.newsItems = Array(store.newsItems.prefix(300))
    store.saveNews()
    textTitle = ""
    text = ""
  }
}

struct NarratorSheet: View {
  @Environment(\.dismiss) var dismiss
  let plan: SpeechPlan
  @StateObject private var narrator = SpeechNarrator()

  var body: some View {
    NavigationStack {
      VStack(spacing: 22) {
        Image(systemName: "waveform.circle").font(.system(size: 72, weight: .ultraLight))
          .foregroundStyle(Color.accentColor)
        Text(narrator.title.isEmpty ? plan.title : narrator.title)
          .font(.title2.bold()).multilineTextAlignment(.center)
        if narrator.totalChapters > 1 {
          Text("第 \(narrator.chapterIndex + 1) / \(narrator.totalChapters) 章 · \(narrator.chapterTitle)")
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        ProgressView(value: narrator.progress).tint(.accentColor)
        HStack(spacing: 28) {
          Button {
            narrator.toggle()
          } label: {
            Image(systemName: narrator.paused ? "play.circle.fill" : "pause.circle.fill")
              .font(.system(size: 58))
          }.disabled(!narrator.speaking && !narrator.paused)
          Button {
            narrator.stop()
            dismiss()
          } label: {
            Image(systemName: "stop.circle").font(.title)
          }
        }
        if narrator.finished {
          Button("再听一次") { _ = narrator.play(plan) }.buttonStyle(.bordered)
        }
        Text("系统语音直接朗读；锁屏后仍可继续播放。")
          .font(.caption2).foregroundStyle(.secondary)
      }.padding(28)
      .navigationTitle("正在朗读")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("完成") { dismiss() } }
      .onAppear { _ = narrator.play(plan) }
      .onDisappear { narrator.stop() }
    }
  }
}

struct WeeklySummaryView: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer
  @State private var summary: WeeklySummary?

  private let labels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

  var body: some View {
    ScrollView {
      if let summary {
        VStack(alignment: .leading, spacing: 18) {
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatCard(label: "本周聆听", value: summary.minutes >= 60 ? "\(summary.minutes / 60) 小时" : "\(summary.minutes) 分钟")
            StatCard(label: "完整播放", value: "\(summary.plays) 首")
            StatCard(label: "不同艺人", value: "\(summary.artistCount)")
            StatCard(label: "新增曲目", value: "\(summary.newSongs)")
            StatCard(label: "听书进度", value: "\(summary.bookCount) 本")
            StatCard(label: "收藏", value: "\(store.state.songs.filter(\.favorite).count) 首")
          }
          Panel {
            Text("这一周的声场").font(.headline)
            HStack(alignment: .bottom, spacing: 10) {
              let maxSeconds = max(600, summary.days.map(\.seconds).max() ?? 0)
              ForEach(summary.days) { day in
                VStack(spacing: 6) {
                  Text(day.seconds < 60 ? (day.seconds > 0 ? "\(Int(day.seconds))″" : "—") : "\(Int(day.seconds / 60))′")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                  RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: store.state.skin.colors.accent).opacity(day.seconds > 0 ? 0.85 : 0.12))
                    .frame(height: max(3, 90 * day.seconds / maxSeconds))
                  Text(labels[day.index]).font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
              }
            }.frame(height: 130, alignment: .bottom)
          }
          if !summary.topSongs.isEmpty {
            Panel {
              Text("反复心动").font(.headline)
              ForEach(Array(summary.topSongs.enumerated()), id: \.offset) { index, row in
                Button {
                  Task { await playSong(row.song, store: store, player: player) }
                } label: {
                  HStack {
                    Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(row.song.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                      Text(row.song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("\(row.plays) 次").font(.caption).foregroundStyle(.secondary)
                  }.padding(.vertical, 5)
                }.buttonStyle(.plain)
              }
            }
          }
          if !summary.topArtists.isEmpty {
            Panel {
              Text("声音的主人").font(.headline)
              ForEach(Array(summary.topArtists.enumerated()), id: \.offset) { _, row in
                HStack {
                  Text(row.artist).font(.subheadline).lineLimit(1)
                  Spacer()
                  Text("\(Int((row.seconds / 60).rounded())) 分钟").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
              }
            }
          }
          Panel {
            Label("这一周，我听见的你", systemImage: "sparkles").font(.headline)
            ForEach(summary.lines, id: \.self) { line in
              Text(line).font(.subheadline).foregroundStyle(.secondary)
            }
            Text("统计来自本机收听记录（\(summary.since.formatted(date: .numeric, time: .omitted)) – \(summary.until.addingTimeInterval(-1).formatted(date: .numeric, time: .omitted))），不会上传。")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }.padding(20)
      } else {
        ProgressView().padding(40)
      }
    }
    .appSurface()
    .navigationTitle("本周总结")
    .onAppear { summary = store.weeklySummary() }
  }
}

private struct StatCard: View {
  @EnvironmentObject var store: MobileStore
  let label: String
  let value: String

  var body: some View {
    Panel {
      Text(label.uppercased()).font(.caption2.monospaced()).tracking(1).foregroundStyle(.secondary)
      Text(value).font(.title2.bold()).foregroundStyle(Color(hex: store.state.skin.colors.accent))
    }
  }
}
