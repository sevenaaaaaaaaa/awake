import AVFoundation
import Combine
import MediaPlayer

struct RouteInfo: Equatable {
  var uid = "unknown"
  var name = "系统输出"
  var transport = "unknown"
  var rate: Double = 0
}
@MainActor final class MobilePlayer: ObservableObject {
  @Published private(set) var song: Song?
  @Published private(set) var playing = false
  @Published private(set) var position: Double = 0
  @Published private(set) var duration: Double = 0
  @Published private(set) var route = RouteInfo()
  @Published private(set) var preamp: Float = 0
  @Published var error = ""
  @Published var volume: Float = 0.7 { didSet { engine.mainMixerNode.outputVolume = volume } }
  @Published private(set) var enhancement = EnhancementState()
  @Published private(set) var activation: EffectActivation?
  @Published private(set) var effectRevision = 0
  @Published private(set) var effectSurface: UUID?
  private var effectSurfaces: [UUID: Int] = [:]
  private var announcedEffect: UUID?
  @Published var bypassed = false {
    didSet {
      guard oldValue != bypassed else { return }
      if applyEQ(), !bypassed { presentEffect(force: true) }
      if bypassed { activation = nil }
    }
  }
  var unreportedSeconds: Double { listened }
  var onListen: ((Song, Double) -> Void)?
  private let engine = AVAudioEngine(), node = AVAudioPlayerNode(),
    eq = AVAudioUnitEQ(numberOfBands: 31), correction = AVAudioUnitEQ(numberOfBands: 16)
  private var queue: [(Song, URL)] = [], index = 0, generation = 0
  private var files: [AVAudioFile] = [], rate: Double = 48000, anchor: Double = 0,
    timelineOrigin: Double = 0, queuedNext = false
  private var listened: Double = 0, lastPosition: Double = 0, timer: Timer?
  private var observers: [NSObjectProtocol] = []
  private var gains = Array(repeating: Float(0), count: 31), apo = ""
  private var snapshot = EQSnapshot()
  private var lastPresented: EQSnapshot?
  init() {
    engine.attach(node)
    engine.attach(eq)
    engine.attach(correction)
    engine.mainMixerNode.outputVolume = volume
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main)
      { [weak self] n in
        Task { @MainActor in self?.routeChanged(n) }
      })
    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] n in
        Task { @MainActor in self?.interrupted(n) }
      })
    observers.append(
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.pause()
          self?.error = "系统音频服务已重置，请重新播放"
        }
      })
    configureSession(activate: false)
    refreshRoute()
    remoteCommands()
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
  }
  deinit {
    timer?.invalidate()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }
  private func configureSession(activate: Bool = true) {
    do {
      let s = AVAudioSession.sharedInstance()
      try s.setCategory(.playback, mode: .default, options: [.allowAirPlay])
      if activate { try s.setActive(true) }
    } catch { self.error = error.localizedDescription }
  }
  func refreshRoute() {
    let s = AVAudioSession.sharedInstance()
    let p = s.currentRoute.outputs.first
    let t = p?.portType
    let transport =
      t == .bluetoothA2DP || t == .bluetoothLE || t == .bluetoothHFP
      ? "bluetooth"
      : t == .usbAudio ? "usb" : t == .headphones ? "analog" : t == .airPlay ? "airplay" : "builtin"
    route = RouteInfo(
      uid: p?.uid ?? "unknown", name: p?.portName ?? "系统输出", transport: transport,
      rate: s.sampleRate)
  }
  @discardableResult
  func useChain(_ chain: ListeningChain?, announce: Bool = true) -> Bool {
    setEQ(
      chain?.gains ?? Array(repeating: 0, count: 31), apo: chain?.apo ?? "",
      origin: chain?.eqOrigin ?? ((chain?.apo.isEmpty ?? true) ? .manual : .imported),
      profile: chain?.headphone ?? route.name, source: chain?.measurementSource ?? "",
      announce: announce)
  }
  @discardableResult
  func setEQ(
    _ values: [Float], apo: String, origin: EQOrigin = .manual,
    profile: String? = nil, source: String = "", announce: Bool = true
  ) -> Bool {
    do {
      // Configure validates the whole request before touching the live Audio Units.
      let nextPreamp = try EQMath.configure(
        eq, correction: correction, gains: values,
        apo: apo, bypassed: bypassed, rate: rate)
      gains = values
      self.apo = apo
      let verifiedOrigin: EQOrigin =
        origin == .ai && source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? .manual : origin
      snapshot = EQSnapshot(
        gains: values, apo: apo, origin: verifiedOrigin,
        profile: profile ?? route.name, source: source)
      preamp = nextPreamp
      refreshEnhancement()
      if announce { presentEffect() }
      return true
    } catch {
      self.error = error.localizedDescription
      activation = nil
      return false
    }
  }
  @discardableResult private func applyEQ() -> Bool {
    do {
      preamp = try EQMath.configure(
        eq, correction: correction, gains: gains, apo: apo, bypassed: bypassed, rate: rate)
      refreshEnhancement()
      return true
    } catch {
      self.error = error.localizedDescription
      activation = nil
      return false
    }
  }
  private func refreshEnhancement() {
    let parsed = try? EQMath.parse(apo)
    let configured =
      gains.contains { abs($0) >= 0.001 }
      || (parsed?.1.contains { abs($0.gain) >= 0.001 } ?? false) || (parsed?.0 ?? 0) < -0.001
    let graphic = eq.bands.filter { !$0.bypass }.count
    let parametric = correction.bands.filter { !$0.bypass }.count
    enhancement = EnhancementState(
      configured: configured,
      enabled: !bypassed && (graphic + parametric > 0 || abs(preamp) >= 0.001), bypassed: bypassed,
      origin: snapshot.origin, profile: snapshot.profile, source: snapshot.source,
      graphicBands: graphic, correctionBands: parametric, preamp: preamp)
  }
  private func presentEffect(force: Bool = false) {
    guard !bypassed, force || snapshot != lastPresented else { return }
    let previousHadEffect =
      lastPresented.map { $0.gains.contains { abs($0) >= 0.001 } || !$0.apo.isEmpty } ?? false
    lastPresented = snapshot
    guard enhancement.enabled || previousHadEffect else { return }
    // This is a parameter illustration, not an acoustic measurement or a signal meter.
    var display = gains
    if let parsed = try? EQMath.parse(apo) {
      for filter in parsed.1 {
        for i in display.indices {
          let distance = log2(Double(EQMath.frequencies[i]) / filter.frequency)
          let width = max(0.15, 1 / filter.q)
          let weight: Double
          if filter.kind.hasPrefix("LS") {
            weight = 1 / (1 + exp(distance * 4))
          } else if filter.kind.hasPrefix("HS") {
            weight = 1 / (1 + exp(-distance * 4))
          } else {
            weight = exp(-0.5 * pow(distance / width, 2))
          }
          display[i] = max(-12, min(12, display[i] + Float(filter.gain * weight)))
        }
      }
    }
    activation = EffectActivation(state: enhancement, displayGains: display)
    effectRevision += 1
  }
  func dismissEffect(_ id: UUID) { if activation?.id == id { activation = nil } }
  func registerEffectSurface(_ id: UUID, priority: Int?) {
    effectSurfaces[id] = priority
    let top = effectSurfaces.max { lhs, rhs in
      lhs.value == rhs.value ? lhs.key.uuidString < rhs.key.uuidString : lhs.value < rhs.value
    }?.key
    if top != effectSurface { effectSurface = top }
  }
  func announceEffectOnce(_ id: UUID) -> Bool {
    guard announcedEffect != id else { return false }
    announcedEffect = id
    return true
  }
  func play(_ songs: [(Song, URL)], at: Int = 0, from: Double = 0, startPlaying: Bool = true) {
    guard songs.indices.contains(at) else { return }
    tick()
    flushListen()
    generation += 1
    node.stop()
    engine.stop()
    queue = songs
    index = at
    files = []
    queuedNext = false
    do {
      configureSession(activate: startPlaying)
      let file = try AVAudioFile(forReading: songs[at].1)
      rate = file.processingFormat.sampleRate
      guard file.processingFormat.channelCount > 0, file.processingFormat.channelCount <= 8 else {
        throw AppFailure("不支持音频声道")
      }
      engine.disconnectNodeOutput(node)
      engine.disconnectNodeOutput(eq)
      engine.disconnectNodeOutput(correction)
      engine.connect(node, to: eq, format: file.processingFormat)
      engine.connect(eq, to: correction, format: file.processingFormat)
      engine.connect(correction, to: engine.mainMixerNode, format: file.processingFormat)
      duration = Double(file.length) / rate
      guard duration > 0, duration < 86400 else { throw AppFailure("音轨为空或超过 24 小时") }
      anchor = max(0, min(from, max(0, duration - 1 / rate)))
      timelineOrigin = 0
      position = anchor
      lastPosition = anchor
      listened = 0
      song = songs[at].0
      files = [file]
      let start = AVAudioFramePosition(anchor * rate)
      let count = AVAudioFrameCount(file.length - start)
      let token = generation
      node.scheduleSegment(
        file, startingFrame: start, frameCount: count, at: nil,
        completionCallbackType: .dataPlayedBack
      ) { [weak self] _ in Task { @MainActor in self?.finished(token: token) } }
      scheduleNext()
      applyEQ()
      engine.prepare()
      if startPlaying {
        try engine.start()
        node.play()
      }
      playing = startPlaying
      error = ""
      refreshRoute()
      nowPlaying()
    } catch {
      playing = false
      self.error = error.localizedDescription
    }
  }
  private func scheduleNext() {
    guard queue.indices.contains(index + 1), files.count < 2,
      let next = try? AVAudioFile(forReading: queue[index + 1].1), let first = files.first,
      next.processingFormat.sampleRate == rate,
      next.processingFormat.channelCount == first.processingFormat.channelCount
    else { return }
    files.append(next)
    queuedNext = true
    let token = generation
    node.scheduleFile(next, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor in self?.finished(token: token) }
    }
  }
  private func finished(token: Int) {
    guard token == generation, song != nil else { return }
    tick()
    flushListen()
    if queuedNext, index + 1 < queue.count {
      let prior = duration - anchor
      timelineOrigin += prior
      index += 1
      files.removeFirst()
      anchor = 0
      song = queue[index].0
      duration = Double(files[0].length) / rate
      position = 0
      lastPosition = 0
      listened = 0
      queuedNext = false
      scheduleNext()
      nowPlaying()
    } else if index + 1 < queue.count {
      play(queue, at: index + 1)
    } else {
      playing = false
      position = duration
      node.pause()
      engine.pause()
      nowPlaying()
    }
  }
  func pause() {
    tick()
    node.pause()
    playing = false
    flushListen()
    nowPlaying()
  }
  func resume() {
    guard song != nil else { return }
    if duration > 0, position >= duration - 1 / rate {
      play(queue, at: index)
      return
    }
    do {
      configureSession()
      if !engine.isRunning { try engine.start() }
      node.play()
      playing = true
      lastPosition = position
      nowPlaying()
    } catch { self.error = error.localizedDescription }
  }
  func toggle() { if playing { pause() } else { resume() } }
  func seek(_ time: Double) {
    guard song != nil else { return }
    let wasPlaying = playing
    play(queue, at: index, from: time, startPlaying: wasPlaying)
  }
  func next() {
    guard index + 1 < queue.count else { return }
    play(queue, at: index + 1)
  }
  func previous() { if position > 3 { seek(0) } else if index > 0 { play(queue, at: index - 1) } }
  func stop() {
    pause()
    generation += 1
    node.stop()
    engine.stop()
    song = nil
    position = 0
    duration = 0
    queue = []
    files = []
    nowPlaying()
  }
  private func flushListen() {
    if let song, listened > 0 { onListen?(song, listened) }
    listened = 0
  }
  private func tick() {
    guard playing, let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render)
    else { return }
    let next = max(
      0, min(duration, anchor + Double(time.sampleTime) / time.sampleRate - timelineOrigin))
    let delta = next - lastPosition
    if delta.isFinite, delta > 0, delta <= duration { listened += delta }
    lastPosition = next
    position = next
    nowPlaying()
  }
  private func routeChanged(_ notification: Notification) {
    let old = route
    refreshRoute()
    let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(
      AVAudioSession.RouteChangeReason.init(rawValue:))
    if reason == .oldDeviceUnavailable {
      pause()
    } else if old.uid != route.uid, playing {
      let q = queue
      let i = index
      let p = position
      play(q, at: i, from: p)
    }
  }
  private var resumeAfterInterruption = false
  private func interrupted(_ n: Notification) {
    guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    if type == .began {
      resumeAfterInterruption = playing
      pause()
    } else {
      let options = AVAudioSession.InterruptionOptions(
        rawValue: n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
      if resumeAfterInterruption && options.contains(.shouldResume) { resume() }
      resumeAfterInterruption = false
    }
  }
  private func nowPlaying() {
    guard let song else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      return
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: song.title, MPMediaItemPropertyArtist: song.artist,
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
    ]
  }
  private func remoteCommands() {
    let c = MPRemoteCommandCenter.shared()
    c.playCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.resume() }
      return .success
    }
    c.pauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.pause() }
      return .success
    }
    c.nextTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.next() }
      return .success
    }
    c.previousTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.previous() }
      return .success
    }
    c.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      Task { @MainActor in self?.seek(e.positionTime) }
      return .success
    }
  }
}

actor SoftwareBench {
  func run(gains: [Float], apo: String) throws -> BenchResult {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 31)
    let correction = AVAudioUnitEQ(numberOfBands: 16)
    let rate = 48000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    engine.attach(node)
    engine.attach(eq)
    engine.attach(correction)
    engine.connect(node, to: eq, format: format)
    engine.connect(eq, to: correction, format: format)
    engine.connect(correction, to: engine.mainMixerNode, format: format)
    _ = try EQMath.configure(
      eq, correction: correction, gains: gains, apo: apo, bypassed: false, rate: rate)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    let frames = 48000 * 5
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    input.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
      let t = Double(i) / rate
      let sample = Float(
        (sin(2 * Double.pi * 60 * t) + sin(2 * Double.pi * 1000 * t) + sin(2 * Double.pi * 8000 * t))
          * 0.16)
      input.floatChannelData![0][i] = sample
      input.floatChannelData![1][i] = sample
    }
    node.scheduleBuffer(input)
    try engine.start()
    node.play()
    defer {
      node.stop()
      engine.stop()
      engine.disableManualRenderingMode()
    }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    let start = ProcessInfo.processInfo.systemUptime
    var rendered = 0
    var peak: Float = 0
    var sum: Double = 0
    var nonFinite = 0
    var clipped = 0
    var retries = 0
    while rendered < frames {
      let n = AVAudioFrameCount(min(4096, frames - rendered))
      let status = try engine.renderOffline(n, to: output)
      if status != .success {
        retries += 1
        guard retries < 100 else { throw AppFailure("离线渲染未完成") }
        continue
      }
      for c in 0..<2 {
        for i in 0..<Int(output.frameLength) {
          let v = output.floatChannelData![c][i]
          if !v.isFinite {
            nonFinite += 1
            continue
          }
          peak = max(peak, abs(v))
          sum += Double(v * v)
          if abs(v) >= 1 { clipped += 1 }
        }
      }
      rendered += Int(output.frameLength)
    }
    return BenchResult(
      frames: rendered, sampleRate: rate, seconds: ProcessInfo.processInfo.systemUptime - start,
      peak: peak, rms: Float(sqrt(sum / Double(rendered * 2))), nonFinite: nonFinite,
      clipped: clipped, profile: apo.isEmpty ? "31 段 EQ" : "图形 EQ + 参数校正")
  }
}
