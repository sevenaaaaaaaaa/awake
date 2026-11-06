import Foundation
import AppKit
import Combine
import SwiftUI
import AwakeCore

/// The single source of truth for the Awake window: playback queue, smart metadata,
/// AutoEQ decisions and navigation.
@MainActor
final class AppModel: ObservableObject {
    enum Destination: Hashable {
        case home, albums, artists, songs, favorites
    }

    let library = MusicLibrary()
    let settings = SettingsStore()
    let engine = AudioEngine()
    let resolver = TrackStreamResolver()

    @Published var destination: Destination = .home
    @Published var selectedAlbum: Album?
    @Published var selectedArtist: String?
    @Published var searchText: String = ""

    @Published private(set) var queue: [Track] = []
    @Published private(set) var queueIndex: Int = -1
    @Published private(set) var queueTitle: String = ""

    @Published private(set) var lyrics: LyricsDocument?
    @Published private(set) var translation: TranslatedLyrics?
    @Published private(set) var autoEQDecision: AutoEQDecision?
    @Published var manualEQ: EQCurve?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var palette: ArtworkPalette = .fallback
    @Published private(set) var isLoadingMetadata = false

    @Published var showNowPlaying = false
    @Published var showEQ = false
    @Published var showSources = false
    @Published var showSettings = false
    @Published var showPalette = false
    @Published var showUpdateSheet = false
    @Published private(set) var updatePhase: UpdatePhase = .idle

    @Published private(set) var toast: String?
    @Published private(set) var isResolving = false
    @Published private(set) var didBootstrap = false

    private var resolvedURLs: [String: URL] = [:]
    private var pendingNext: (track: Track, url: URL)?
    private var loadTask: Task<Void, Never>?
    private var metaTask: Task<Void, Never>?
    private var eqTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        library.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        engine.onTrackFinished = { [weak self] in
            Task { @MainActor in self?.handleTrackFinished() }
        }
        engine.onNeedsNextTrack = { [weak self] in
            Task { @MainActor in self?.prepareNext() }
        }
        engine.onTrackStarted = { [weak self] track in
            Task { @MainActor in self?.handleTrackStarted(track) }
        }
    }
    // MARK: - Derived state

    var appVersion: String { Bundle.main.shortVersion }
    var buildNumber: String { Bundle.main.buildNumber }
    var hasUpdate: Bool {
        if case .available = updatePhase { return true }
        return false
    }

    var currentTrack: Track? { engine.currentTrack }
    var isPlaying: Bool { engine.isPlaying }
    var isPaused: Bool { engine.isPaused }
    var elapsed: Double { engine.elapsed }
    var duration: Double { engine.duration }
    var canPlayPrevious: Bool { queueIndex > 0 || engine.elapsed > 3 }
    var canPlayNext: Bool { queueIndex + 1 < queue.count }

    var upNext: Track? {
        guard queue.indices.contains(queueIndex + 1) else { return nil }
        return queue[queueIndex + 1]
    }

    var nowPlayingAlbum: Album? {
        guard let track = currentTrack else { return nil }
        return Album(id: track.albumKey,
                     title: track.album,
                     artist: track.albumArtist,
                     year: track.year,
                     artworkPath: track.artworkPath,
                     tracks: library.tracks.filter { $0.albumKey == track.albumKey })
    }

    var volume: Double {
        get { Double(engine.volume) }
        set {
            engine.volume = Float(newValue)
            settings.settings.volume = newValue
        }
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        // 无界面自检：--update-check 只打印结果，--update-install 走完整替换流程。
        let cliArgs = CommandLine.arguments
        if cliArgs.contains("--update-check") || cliArgs.contains("--update-install") {
            await runUpdateCLI(install: cliArgs.contains("--update-install"))
            return
        }
        AwakePaths.ensure()
        library.load()

        engine.setBitPerfectPreferred(settings.settings.bitPerfect)
        engine.setExclusive(settings.settings.exclusiveMode)
        engine.volume = Float(settings.settings.volume)
        engine.refreshOutputDevice()

        if library.sources.isEmpty, let demo = Self.demoMusicURL() {
            library.addSource(MediaSource(kind: .local, name: "Awake Demo", url: demo.path))
            toast("已发现演示曲库，正在索引…")
        }

        if settings.settings.scanOnLaunch, !library.sources.isEmpty {
            await library.scanAll()
        }

        let args = CommandLine.arguments
        // 调试：--local <dir> 直接加入一个本地来源，便于无 UI 验证特殊格式
        if let index = args.firstIndex(of: "--local"), index + 1 < args.count {
            let source = MediaSource(kind: .local, name: "Local Test", url: args[index + 1])
            library.addSource(source)
            await library.scan(source)
            if let nameIndex = args.firstIndex(of: "--play-file"), nameIndex + 1 < args.count {
                let needle = args[nameIndex + 1]
                if let track = library.tracks.first(where: { $0.locator.hasSuffix(needle) }) {
                    // 调试：让目标曲目排第一，确保它后面始终有下一首，便于验证自动切歌。
                    let rest = library.tracks.filter { $0.id != track.id }
                    play(track, context: [track] + rest, title: "本地测试")
                }
            }
        }
        // 调试：--webdav <url> 直接加入一个 WebDAV 来源，扫描并验证远程取回链路
        if let index = args.firstIndex(of: "--webdav"), index + 1 < args.count {
            let source = MediaSource(kind: .webdav, name: "WebDAV Test", url: args[index + 1])
            library.addSource(source)
            await library.scan(source)
            if let remote = library.tracks.first(where: { $0.sourceID == source.id }) {
                do {
                    let url = try await library.resolveURL(for: remote)
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? 0
                    print("[Awake] webdav resolve ok: \(url.path) \(size) bytes")
                } catch {
                    print("[Awake] webdav resolve failed: \(error)")
                }
                if args.contains("--play-webdav") {
                    play(remote, context: library.tracks, title: "WebDAV")
                }
            }
        }

        if let index = args.firstIndex(of: "--just-updated"), index + 1 < args.count {
            toast("已更新到 \(args[index + 1])")
        }
        if settings.settings.autoCheckUpdates {
            Task { [weak self] in
                await self?.checkForUpdates(force: false)
            }
        }
    }

    static func demoMusicURL() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("DemoMusic"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("DemoMusic"))
        candidates.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("SeeWow/DemoMusic"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    // MARK: - Playback

    func play(_ track: Track, context: [Track]? = nil, title: String = "") {
        let list = (context?.isEmpty == false ? context! : library.tracks)
        queue = list
        queueIndex = list.firstIndex(where: { $0.id == track.id }) ?? 0
        queueTitle = title.isEmpty ? (track.album.isEmpty ? "歌曲" : track.album) : title
        startQueueItem()
    }

    func playAlbum(_ album: Album, startingAt track: Track? = nil) {
        let tracks = library.tracks(in: album)
        guard let first = track ?? tracks.first else { return }
        play(first, context: tracks, title: album.title)
    }

    func playArtist(_ name: String) {
        let tracks = library.tracks.filter { $0.artist == name || $0.albumArtist == name }
        guard let first = tracks.first else { return }
        play(first, context: tracks, title: name)
    }

    func shuffleAll() {
        let shuffled = library.tracks.shuffled()
        guard let first = shuffled.first else { return }
        play(first, context: shuffled, title: "随机播放")
    }

    func togglePlayPause() {
        if engine.currentTrack == nil {
            if let track = queue.indices.contains(queueIndex) ? queue[queueIndex] : library.tracks.first {
                play(track)
            }
            return
        }
        engine.toggle()
    }

    func nextTrack() {
        engine.cancelQueuedNext()
        pendingNext = nil
        guard queueIndex + 1 < queue.count else { return }
        queueIndex += 1
        startQueueItem()
    }

    func previousTrack() {
        if engine.elapsed > 3 {
            engine.seek(to: 0)
            return
        }
        engine.cancelQueuedNext()
        pendingNext = nil
        guard queueIndex > 0 else {
            engine.seek(to: 0)
            return
        }
        queueIndex -= 1
        startQueueItem()
    }

    func seek(to seconds: Double) {
        engine.seek(to: max(0, min(duration, seconds)))
    }

    func toggleFavoriteForCurrent() {
        guard let track = currentTrack else { return }
        library.toggleFavorite(track.id)
        toast(track.favorite ? "已加入收藏" : "已取消收藏")
    }

    private func startQueueItem() {
        guard queue.indices.contains(queueIndex) else { return }
        let track = queue[queueIndex]
        engine.cancelQueuedNext()
        pendingNext = nil
        loadTask?.cancel()
        isResolving = true
        lyrics = nil
        translation = nil
        autoEQDecision = nil
        manualEQ = nil
        loadArtwork(for: track)

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.library.resolveStream(for: track)
                guard !Task.isCancelled else { return }
                self.resolvedURLs[track.id] = stream.url
                self.isResolving = false

                // 远程曲目先落盘：按真实标签替换文件名占位，封面也一起补上。
                // DSD / APE 读取的是原始文件，避免把转码后的 PCM 规格覆盖回曲库。
                var playable = track
                if track.isRemote {
                    let tags = await TagReader.read(url: stream.sourceURL)
                    guard !Task.isCancelled else { return }
                    playable = track.applying(tags)
                    if let art = tags.artwork,
                       let path = LibraryScanner.persistArtwork(art, id: track.id) {
                        playable.artworkPath = path
                    }
                    self.library.update(playable)
                    if self.queue.indices.contains(self.queueIndex) {
                        self.queue[self.queueIndex] = playable
                    }
                    self.loadArtwork(for: playable)
                }

                self.engine.play(url: stream.url,
                                 track: playable,
                                 bitPerfect: self.settings.settings.bitPerfect)
                self.loadMetadata(for: playable)
                self.refreshAutoEQ()
                self.prepareNext()
            } catch {
                guard !Task.isCancelled else { return }
                self.isResolving = false
                self.toast(error.localizedDescription)
            }
        }
    }

    private func handleTrackStarted(_ track: Track) {
        if let index = queue.firstIndex(where: { $0.id == track.id }) {
            queueIndex = index
        }
        library.markPlayed(track.id)
        loadArtwork(for: track)
        loadMetadata(for: track)
        refreshAutoEQ()
        prepareNext()
    }

    private func handleTrackFinished() {
        if engine.hasNextQueued { return }
        if let pending = pendingNext {
            pendingNext = nil
            if let index = queue.firstIndex(where: { $0.id == pending.track.id }) {
                queueIndex = index
            }
            engine.play(url: pending.url,
                        track: pending.track,
                        bitPerfect: settings.settings.bitPerfect)
            return
        }
        guard queueIndex + 1 < queue.count else {
            engine.stop()
            lyrics = nil
            translation = nil
            isLoadingMetadata = false
            autoEQDecision = nil
            return
        }
        queueIndex += 1
        startQueueItem()
    }

    private func prepareNext() {
        guard settings.settings.gapless, queue.indices.contains(queueIndex + 1) else { return }
        let next = queue[queueIndex + 1]
        if resolvedURLs[next.id] != nil, engine.hasNextQueued { return }
        Task { [weak self] in
            guard let self else { return }
            guard let stream = try? await self.library.resolveStream(for: next) else { return }
            guard !Task.isCancelled,
                  self.queue.indices.contains(self.queueIndex),
                  self.currentTrack?.id == self.queue[self.queueIndex].id else { return }
            self.resolvedURLs[next.id] = stream.url

            // 远程曲目在排队时也补齐标签，自动切歌后不会退回文件名占位。
            var playable = next
            if next.isRemote {
                let tags = await TagReader.read(url: stream.sourceURL)
                guard !Task.isCancelled,
                      self.queue.indices.contains(self.queueIndex),
                      self.currentTrack?.id == self.queue[self.queueIndex].id else { return }
                playable = next.applying(tags)
                if let art = tags.artwork,
                   let path = LibraryScanner.persistArtwork(art, id: next.id) {
                    playable.artworkPath = path
                }
                self.library.update(playable)
                if let index = self.queue.firstIndex(where: { $0.id == next.id }) {
                    self.queue[index] = playable
                }
            }

            if !self.engine.enqueueNext(url: stream.url, track: playable) {
                self.pendingNext = (playable, stream.url)
            }
        }
    }
    // MARK: - Smart metadata

    private func loadArtwork(for track: Track) {
        if let path = track.artworkPath, let image = NSImage(contentsOfFile: path) {
            artwork = image
            palette = ArtworkPalette(image: image)
            return
        }
        artwork = nil
        palette = .fallback
    }

    private func loadMetadata(for track: Track) {
        metaTask?.cancel()
        isLoadingMetadata = true
        let current = settings.settings
        metaTask = Task { [weak self] in
            guard let self else { return }
            let enrichment = await MetadataHub.shared.enrich(
                track: track,
                targetLanguage: current.translationEnabled ? current.translationTarget : "")
            guard !Task.isCancelled, self.currentTrack?.id == track.id else { return }
            if let path = enrichment.artworkPath, self.settings.settings.autoFetchArtwork {
                self.library.setArtwork(path, for: track.id)
                if let image = NSImage(contentsOfFile: path) {
                    self.artwork = image
                    self.palette = ArtworkPalette(image: image)
                }
            }
            if self.settings.settings.autoFetchLyrics {
                self.lyrics = enrichment.lyrics
                self.translation = enrichment.translation
            }
            self.isLoadingMetadata = false
        }
    }

    func reloadTranslation() {
        guard let lyrics, settings.settings.translationEnabled else {
            translation = nil
            return
        }
        let target = settings.settings.translationTarget
        Task { [weak self] in
            let result = await TranslationService.shared.translate(document: lyrics, target: target)
            guard let self else { return }
            self.translation = result
        }
    }

    // MARK: - AutoEQ

    func refreshAutoEQ() {
        guard let track = currentTrack else { return }
        guard settings.settings.autoEQ else {
            engine.apply(.flat)
            autoEQDecision = nil
            return
        }
        guard let url = resolvedURLs[track.id] else { return }
        eqTask?.cancel()
        let snapshot = settings.settings
        eqTask = Task { [weak self] in
            guard let self else { return }
            let device = self.engine.outputDevice
            let decision = await AutoEQEngine.shared.decide(
                track: track,
                url: url,
                device: device,
                preference: snapshot.headphoneProfileID,
                intensity: snapshot.autoEQIntensity,
                headroomDB: snapshot.headroomDB,
                analyzeTrack: true)
            guard !Task.isCancelled, self.currentTrack?.id == track.id else { return }
            self.autoEQDecision = decision
            if let manual = self.manualEQ {
                self.engine.apply(manual)
            } else {
                self.engine.apply(decision.curve)
            }
        }
    }

    func setAutoEQEnabled(_ enabled: Bool) {
        settings.settings.autoEQ = enabled
        manualEQ = nil
        if enabled {
            refreshAutoEQ()
        } else {
            engine.apply(.flat)
            autoEQDecision = nil
        }
    }

    func setAutoEQIntensity(_ value: Double) {
        settings.settings.autoEQIntensity = value
        manualEQ = nil
        refreshAutoEQ()
    }

    func setHeadphonePreference(_ id: String) {
        settings.settings.headphoneProfileID = id
        manualEQ = nil
        refreshAutoEQ()
    }

    func previewManualEQ(_ curve: EQCurve) {
        manualEQ = curve
        engine.apply(curve)
    }

    func rememberCurrentSound() {
        guard let manual = manualEQ, let automatic = autoEQDecision?.curve else {
            toast("先拖动几个频段，Awake 才能记住你的偏好")
            return
        }
        Task { [weak self] in
            let delta = await AutoEQEngine.shared.manualDelta(manual: manual, automatic: automatic)
            await AutoEQEngine.shared.learn(delta: delta)
            guard let self else { return }
            self.manualEQ = nil
            self.refreshAutoEQ()
            self.toast("已记住你的听感偏好，下次自动生效")
        }
    }

    func resetListeningProfile() {
        Task { [weak self] in
            await AutoEQEngine.shared.resetLearning()
            guard let self else { return }
            self.refreshAutoEQ()
            self.toast("已重置听感学习")
        }
    }

    // MARK: - Sources

    func addLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加到 Awake"
        panel.message = "选择本地音乐文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addSource(kind: .local,
                  name: url.lastPathComponent,
                  url: url.path,
                  username: "",
                  password: "",
                  token: "")
    }

    func addSource(kind: SourceKind, name: String, url: String,
                   username: String, password: String, token: String) {
        var source = MediaSource(kind: kind,
                                 name: name.trimmed.isEmpty ? kind.title : name.trimmed,
                                 url: url.trimmed,
                                 username: username,
                                 token: token)
        if !password.isEmpty { source.password = password }
        library.addSource(source)
        toast("正在连接 " + source.name)
        Task { [weak self] in
            guard let self else { return }
            await self.library.scan(source)
            if let error = self.library.lastError {
                self.toast(error)
            } else {
                self.toast(source.name + " 已收录 " + String(source.trackCount) + " 首")
            }
        }
    }

    func rescanAll() {
        Task { [weak self] in
            guard let self else { return }
            await self.library.scanAll()
            self.toast("曲库已更新，共 " + String(self.library.tracks.count) + " 首")
        }
    }

    func removeSource(_ id: UUID) {
        library.removeSource(id)
    }

    // MARK: - Updates

    private static let lastUpdateCheckKey = "awake.update.lastCheck"

    private func runUpdateCLI(install: Bool) async {
        do {
            let outcome = try await UpdateChecker.check(currentVersion: appVersion)
            switch outcome {
            case .upToDate(let version):
                print("[awake-update] up-to-date current=\(appVersion) latest=\(version)")
            case .available(let info):
                print("[awake-update] available current=\(info.currentVersion) latest=\(info.version) asset=\(info.assetName) bytes=\(info.assetSize)")
                guard install else { break }
                print("[awake-update] downloading \(info.downloadURL.absoluteString)")
                let zip = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Awake-\(info.version).zip")
                try? FileManager.default.removeItem(at: zip)
                try await UpdateDownloader.download(info, to: zip) { ratio in
                    if ratio >= 1 { print("[awake-update] downloaded") }
                }
                print("[awake-update] unpacking")
                let bundle = try UpdateInstaller.unpack(zip: zip, expectedVersion: info.version)
                try UpdateInstaller.installAndRelaunch(newBundle: bundle,
                                                       destination: Bundle.main.bundleURL,
                                                       version: info.version)
                print("[awake-update] install scheduled, terminating pid=\(ProcessInfo.processInfo.processIdentifier)")
            }
        } catch {
            print("[awake-update] failed: \(error.localizedDescription)")
            exit(2)
        }
        NSApp.terminate(nil)
    }

    func presentUpdates() {
        showUpdateSheet = true
        Task { await checkForUpdates(force: true) }
    }

    /// Called when the update sheet appears; reuses a result that is already on screen.
    func ensureUpdateCheck() {
        if case .idle = updatePhase {
            Task { await checkForUpdates(force: true) }
        }
    }

    func checkForUpdates(force: Bool) async {
        switch updatePhase {
        case .downloading, .installing:
            return
        default:
            break
        }
        if !force,
           let last = UserDefaults.standard.object(forKey: Self.lastUpdateCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        updatePhase = .checking
        do {
            let outcome = try await UpdateChecker.check(currentVersion: appVersion)
            UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckKey)
            switch outcome {
            case .upToDate(let version):
                updatePhase = .upToDate(version: version)
            case .available(let info):
                updatePhase = .available(info)
                if !force {
                    toast("发现新版本 \(info.version)，打开「Awake › 检查更新…」即可安装")
                }
            }
        } catch {
            if force {
                updatePhase = .failed(error.localizedDescription)
                toast(error.localizedDescription)
            } else {
                updatePhase = .idle
            }
        }
    }

    func installAvailableUpdate() {
        guard case .available(let info) = updatePhase else { return }
        Task { await downloadAndInstall(info) }
    }

    private func downloadAndInstall(_ info: UpdateInfo) async {
        updatePhase = .downloading(progress: 0, version: info.version)
        do {
            let zip = FileManager.default.temporaryDirectory
                .appendingPathComponent("Awake-\(info.version).zip")
            try? FileManager.default.removeItem(at: zip)
            try await UpdateDownloader.download(info, to: zip) { ratio in
                Task { @MainActor [weak self] in
                    guard let self,
                          case .downloading(let previous, let version) = self.updatePhase else { return }
                    if ratio - previous >= 0.01 || ratio >= 0.999 {
                        self.updatePhase = .downloading(progress: ratio, version: version)
                    }
                }
            }
            updatePhase = .installing(version: info.version)
            let bundle = try UpdateInstaller.unpack(zip: zip, expectedVersion: info.version)
            try UpdateInstaller.installAndRelaunch(newBundle: bundle,
                                                   destination: Bundle.main.bundleURL,
                                                   version: info.version)
            try? await Task.sleep(nanoseconds: 350_000_000)
            NSApp.terminate(nil)
        } catch {
            updatePhase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Toasts

    func toast(_ message: String) {
        toastTask?.cancel()
        withAnimation(AwakeTheme.spring) { toast = message }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }
}



