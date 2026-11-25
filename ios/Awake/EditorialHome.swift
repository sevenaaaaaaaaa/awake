import SwiftUI

/// 首页「编排」：今日精选 / 专题 / 歌单。
///
/// 规则住在 `Editorial`（纯逻辑，swiftc 直接测），这里只负责显示与播放。
/// 之前首页只有一列 SongRow，用户的原话是「推荐太原始」——问题不在歌不够，
/// 在于库里的事实从没被重新组织过：收藏、加入时间、时长、艺人、专辑都是现成的。
struct EditorialHome: View {
  @EnvironmentObject var store: MobileStore
  @EnvironmentObject var player: MobilePlayer

  private var tracks: [Editorial.Track] { EditorialFeed.tracks(state: store.state) }
  private var songsByID: [String: Song] {
    Dictionary(store.state.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
  private var accent: Color { Color(hex: store.state.skin.colors.accent) }
  private var muted: Color { Color(hex: store.state.skin.colors.muted) }
  private var surface: Color { Color(hex: store.state.skin.colors.surface) }
  private var border: Color { Color(hex: store.state.skin.colors.border) }

  var body: some View {
    if !store.state.songs.isEmpty {
      todayPick
      collections
      playlists
    }
  }

  // MARK: - 今日精选

  @ViewBuilder private var todayPick: some View {
    if let pick = Editorial.pick(tracks), let song = songsByID[pick.trackID] {
      AwakeSectionTitle(title: "今日精选", status: "每天重排")
      Button {
        Task { await playSong(song, store: store, player: player) }
      } label: {
        HStack(spacing: DS.Space.m) {
          Cover(
            title: song.title, artwork: song.artwork,
            style: song.mediaInfo?.cover_style ?? "auto", size: 72)
          VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(song.title).font(.headline).lineLimit(1)
            Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
              .font(.footnote).foregroundStyle(muted).lineLimit(1)
            Text(pick.reason)
              .font(.caption).foregroundStyle(muted).lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: DS.Space.xs)
          Image(systemName: "play.circle.fill")
            .font(.system(size: 30))
            .foregroundStyle(accent)
            .accessibilityHidden(true)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: store.state.skin.radius, style: .continuous)
            .fill(surface))
        .overlay(
          RoundedRectangle(cornerRadius: store.state.skin.radius, style: .continuous)
            .stroke(border, lineWidth: 0.6))
      }
      .buttonStyle(.plain)
      .frame(minHeight: 44)
      .accessibilityIdentifier("homeTodayPick")
      .accessibilityLabel("播放今日精选：\(song.title)。\(pick.reason)")
    }
  }

  // MARK: - 专题

  @ViewBuilder private var collections: some View {
    let items = Editorial.collections(tracks)
    if !items.isEmpty {
      AwakeSectionTitle(title: "替你排好的", status: "\(items.count) 组")
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: DS.Space.s) {
          ForEach(items) { collection in
            collectionCard(collection)
          }
        }
        .padding(.vertical, 2)
      }
      // 不豁免的话，横滑会被 RootView 的「切 tab」手势抢走。
      .tabSwipeExempt()
      .accessibilityIdentifier("homeCollections")
    }
  }

  private func collectionCard(_ collection: Editorial.Collection) -> some View {
    let songs = collection.trackIDs.compactMap { songsByID[$0] }
    let lead = songs.first
    return Button {
      Task { await playCollection(songs, title: collection.title) }
    } label: {
      VStack(alignment: .leading, spacing: DS.Space.xs) {
        ZStack(alignment: .bottomTrailing) {
          Cover(
            title: lead?.title ?? collection.title, artwork: lead?.artwork,
            style: lead?.mediaInfo?.cover_style ?? "auto", size: 132)
          Image(systemName: "play.circle.fill")
            .font(.system(size: 26))
            .foregroundStyle(.white.opacity(0.92))
            .padding(6)
            .accessibilityHidden(true)
        }
        Text(collection.title)
          .font(.footnote.weight(.semibold))
          .lineLimit(1)
        Text(collection.subtitle)
          .font(.caption2)
          .foregroundStyle(muted)
          .lineLimit(1)
      }
      .frame(width: 132, alignment: .leading)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("homeCollection-\(collection.id)")
    .accessibilityLabel("播放专题：\(collection.title)，\(collection.subtitle)")
  }

  // MARK: - 歌单

  @ViewBuilder private var playlists: some View {
    let lists = store.state.playlists ?? []
    if !lists.isEmpty {
      AwakeSectionTitle(title: "你的歌单", status: "\(lists.count) 个")
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: DS.Space.s) {
          ForEach(lists) { list in
            NavigationLink {
              PlaylistDetailView(playlistID: list.id)
            } label: {
              VStack(alignment: .leading, spacing: DS.Space.xs) {
                Cover(
                  title: list.name,
                  artwork: list.songIDs.compactMap { songsByID[$0]?.artwork }.first,
                  style: "auto", size: 132)
                Text(list.name).font(.footnote.weight(.semibold)).lineLimit(1)
                Text("\(list.songIDs.count) 首").font(.caption2).foregroundStyle(muted)
              }
              .frame(width: 132, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("homePlaylist-\(list.id)")
          }
        }
        .padding(.vertical, 2)
      }
      .tabSwipeExempt()
      .accessibilityIdentifier("homePlaylists")
    }
  }

  // MARK: - 播放

  /// 专题卡点一下就直接开播，不再多一层详情页。
  /// 只放已经在本机的那些：把 8 首逐个下载会让点击之后半分钟没声音，
  /// 所以播几首说几首，不假装整组都在。
  @MainActor private func playCollection(_ songs: [Song], title: String) async {
    guard !songs.isEmpty else { return }
    let local = songs.compactMap { song -> (Song, URL)? in
      guard let url = store.localURL(song) else { return nil }
      return (song, url)
    }
    guard !local.isEmpty else {
      store.message = "「\(title)」里的歌还没到本机：先在曲库里逐首播一次，或到设置里刷新来源。"
      return
    }
    if local.count < songs.count {
      store.message = "「\(title)」\(songs.count) 首里有 \(local.count) 首在本机，先放这些。"
    }
    player.play(local, at: 0)
  }
}

/// Song -> Editorial.Track 的唯一映射。
/// `listenedSeconds` 用「有没有听感评测记录」填：Awake 不记播放次数，
/// 所以只有评测记录能证明「这首歌被认真听过一遍」。
enum EditorialFeed {
  static func tracks(state: LibraryState) -> [Editorial.Track] {
    let measured = Set(state.listens.map(\.songID))
    return state.songs.map { song in
      Editorial.Track(
        id: song.id, title: song.title, artist: song.artist, album: song.album,
        duration: song.duration, favorite: song.favorite, addedAt: song.addedAt,
        listenedSeconds: measured.contains(song.id) ? 1 : 0)
    }
  }
}
