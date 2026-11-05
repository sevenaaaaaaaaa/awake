import Foundation
import AVFoundation
import Combine
import CoreAudio

public enum AudioEngineError: LocalizedError {
    case cannotOpen(URL)
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): return "无法打开音频文件：\(url.lastPathComponent)"
        case .unsupportedFormat: return "不支持的音频格式"
        }
    }
}

/// The playback core: one AVAudioEngine graph (player -> 31-band EQ -> mixer), a 32-band
/// spectrum tap for the visualizer, hardware volume control and gapless queueing.
///
/// Design notes
/// - Volume is applied on the *device* so the float pipeline stays unity and bit-perfect.
/// - The engine graph adopts the track's native sample rate. The output device is asked to
///   match it; when it cannot (Bluetooth), CoreAudio resamples and we stop claiming bit-perfect.
/// - Gapless is achieved by scheduling the next AVAudioFile on the same player node before the
///   current one ends; AVAudioPlayerNode renders queued files back to back.
@MainActor
public final class AudioEngine: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var isPlaying = false
    @Published public private(set) var isPaused = false
    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var elapsed: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var spectrum: [Float] = Array(repeating: 0, count: 32)
    @Published public private(set) var level: Float = 0
    @Published public private(set) var outputDevice: AudioOutputDevice?
    @Published public private(set) var isBitPerfect = false
    @Published public private(set) var isExclusive = false
    @Published public private(set) var eqCurve: EQCurve = .flat
    @Published public private(set) var lastError: String?
    @Published public private(set) var hasNextQueued = false

    public var volume: Float = 0.85 {
        didSet { applyVolume() }
    }

    /// Called when the queue has no next track and the current one reached its end.
    public var onTrackFinished: (() -> Void)?
    /// Called when the UI should ask for the next track (remaining <= threshold, nothing queued).
    public var onNeedsNextTrack: (() -> Void)?
    /// Called after a gapless transition completed.
    public var onTrackStarted: ((Track) -> Void)?

    // MARK: - Engine graph

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 31)
    private let analyzer = SpectrumAnalyzer()
    private var tapInstalled = false
    private var tapCounter = 0

    // MARK: - Playback bookkeeping

    private var file: AVAudioFile?
    private var activeFormat: AVAudioFormat?
    private var baseFrame: AVAudioFramePosition = 0        // absolute frame at player timeline 0
    private var trackStartTick: AVAudioFramePosition = 0   // player timeline of current track start
    private var scheduledFrames: AVAudioFramePosition = 0  // frames scheduled since player.play()
    private var generation = 0
    private var endSignaled = false
    private var pendingNext: (track: Track, tick: AVAudioFramePosition)?
    private var pendingNextFile: AVAudioFile?
    private var uiTimer: Timer?
    private var activityToken: NSObjectProtocol?
    private var deviceObserver: AudioObjectPropertyListenerBlock?
    private var needsNextSignaled = false
    private var exclusiveMode = false
    private var bitPerfectPreferred = true

    public init() {
        attachGraph()
        refreshOutputDevice()
        observeDeviceChanges()
    }

    deinit {
        uiTimer?.invalidate()
        if let observer = deviceObserver { AudioDeviceController.removeDefaultDeviceObserver(observer) }
    }

    // MARK: - Public control

    public func play(url: URL, track: Track, startAt: Double = 0, bitPerfect: Bool = true) {
        bitPerfectPreferred = bitPerfect
        do {
            let opened = try AVAudioFile(forReading: url)
            let format = opened.processingFormat
            try prepareGraph(for: format)
            generation += 1
            endSignaled = false
            pendingNext = nil
            pendingNextFile = nil
            hasNextQueued = false
            needsNextSignaled = false
            file = opened
            currentTrack = track
            let total = Double(opened.length) / format.sampleRate
            duration = track.duration > 0 ? max(track.duration, 1) : total
            baseFrame = AVAudioFramePosition(max(0, min(startAt, total - 0.05)) * format.sampleRate)
            trackStartTick = 0
            scheduledFrames = 0
            elapsed = startAt
            isPaused = false
            player.stop()
            scheduleSegment(from: baseFrame, file: opened, format: format)
            startEngineIfNeeded()
            player.play()
            isPlaying = true
            beginPlaybackActivity()
            updateBitPerfect()
            startUITimer()
            installTapIfNeeded()
        } catch {
            lastError = error.localizedDescription
            isPlaying = false
            isPaused = false
            endPlaybackActivity()
            print("[Awake] playback failed: \(error)")
        }
    }

    public func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        isPaused = true
        endPlaybackActivity()
        updateBitPerfect()
    }

    public func resume() {
        guard isPaused, file != nil else { return }
        if !engine.isRunning { try? engine.start() }
        player.play()
        isPlaying = true
        isPaused = false
        beginPlaybackActivity()
        updateBitPerfect()
    }

    public func toggle() {
        if isPlaying { pause() } else { resume() }
    }

    public func stop() {
        generation += 1
        player.stop()
        file = nil
        pendingNext = nil
        pendingNextFile = nil
        hasNextQueued = false
        isPlaying = false
        isPaused = false
        elapsed = 0
        duration = 0
        baseFrame = 0
        trackStartTick = 0
        scheduledFrames = 0
        spectrum = Array(repeating: 0, count: 32)
        level = 0
        analyzer.reset()
        currentTrack = nil
        uiTimer?.invalidate()
        uiTimer = nil
        endPlaybackActivity()
    }

    public func seek(to seconds: Double) {
        guard let file, let format = activeFormat else { return }
        let frame = AVAudioFramePosition(max(0, min(seconds, duration - 0.05)) * format.sampleRate)
        let wasPlaying = isPlaying
        generation += 1
        player.stop()
        pendingNext = nil
        pendingNextFile = nil
        hasNextQueued = false
        needsNextSignaled = false
        endSignaled = false
        baseFrame = frame
        trackStartTick = 0
        scheduledFrames = 0
        elapsed = Double(frame) / format.sampleRate
        scheduleSegment(from: frame, file: file, format: format)
        if wasPlaying {
            startEngineIfNeeded()
            player.play()
        }
    }

    /// Queue the next track for truly gapless playback. Returns false when the file's format
    /// cannot be rendered by the current graph (caller keeps it for a normal transition).
    @discardableResult
    public func enqueueNext(url: URL, track: Track) -> Bool {
        guard let activeFormat, isPlaying else { return false }
        guard let nextFile = try? AVAudioFile(forReading: url) else { return false }
        let nextFormat = nextFile.processingFormat
        guard abs(nextFormat.sampleRate - activeFormat.sampleRate) < 0.5,
              nextFormat.channelCount == activeFormat.channelCount,
              nextFile.length > 0 else { return false }

        pendingNext = (track, scheduledFrames)
        pendingNextFile = nextFile
        hasNextQueued = true
        let token = generation
        player.scheduleFile(nextFile, at: nil) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.scheduledFrames = 0
            }
        }
        scheduledFrames += nextFile.length
        return true
    }

    public func cancelQueuedNext() {
        guard hasNextQueued else { return }
        // AVAudioPlayerNode cannot remove a single queued file; a fresh segment re-schedules cleanly.
        let resumeAt = elapsed
        let wasPlaying = isPlaying
        guard let file, let format = activeFormat else { return }
        generation += 1
        player.stop()
        let frame = AVAudioFramePosition(max(0, resumeAt) * format.sampleRate)
        baseFrame = frame
        trackStartTick = 0
        scheduledFrames = file.length - frame
        pendingNext = nil
        pendingNextFile = nil
        hasNextQueued = false
        scheduleSegment(from: frame, file: file, format: format)
        if wasPlaying { player.play() }
    }

    public func setExclusive(_ enabled: Bool) {
        exclusiveMode = enabled
        guard let device = AudioDeviceController.defaultOutputDevice() else { return }
        _ = AudioDeviceController.setHogMode(enabled, deviceID: device.id)
        isExclusive = AudioDeviceController.isHogged(deviceID: device.id)
    }

    public func apply(_ curve: EQCurve) {
        eqCurve = curve
        for (index, band) in equalizer.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = EQBand.frequencies[min(index, EQBand.frequencies.count - 1)]
            band.bandwidth = 0.45
            band.gain = curve.gains[min(index, curve.gains.count - 1)]
            band.bypass = false
        }
        equalizer.globalGain = curve.preamp
        updateBitPerfect()
    }

    public func setBitPerfectPreferred(_ value: Bool) {
        bitPerfectPreferred = value
        updateBitPerfect()
    }

    public func refreshOutputDevice() {
        outputDevice = AudioDeviceController.defaultOutputDevice()
        if let device = outputDevice { analyzer.updateSampleRate(device.sampleRate) }
        updateBitPerfect()
    }

    public var secondsRemaining: Double { max(0, duration - elapsed) }

    public var progress: Double { duration > 0 ? max(0, min(1, elapsed / duration)) : 0 }

    // MARK: - Graph setup

    private func attachGraph() {
        engine.attach(player)
        engine.attach(equalizer)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        engine.connect(player, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
    }

    private func prepareGraph(for format: AVAudioFormat) throws {
        if let current = activeFormat,
           abs(current.sampleRate - format.sampleRate) < 0.5,
           current.channelCount == format.channelCount,
           engine.isRunning {
            return
        }
        let wasRunning = engine.isRunning
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(equalizer)
        engine.connect(player, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        activeFormat = format
        analyzer.updateSampleRate(format.sampleRate)
        if bitPerfectPreferred, let device = AudioDeviceController.defaultOutputDevice(), abs(device.sampleRate - format.sampleRate) > 0.5 {
            _ = AudioDeviceController.setSampleRate(format.sampleRate, deviceID: device.id)
            outputDevice = AudioDeviceController.describe(device.id, isDefault: true)
        }
        engine.prepare()
        if wasRunning { try engine.start() }
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch {
            lastError = "音频引擎启动失败：\(error.localizedDescription)"
        }
    }

    private func scheduleSegment(from frame: AVAudioFramePosition, file: AVAudioFile, format: AVAudioFormat) {
        let remaining = file.length - frame
        guard remaining > 0 else { return }
        let token = generation
        let count = AVAudioFrameCount(min(remaining, Int64(UInt32.max)))
        player.scheduleSegment(file, startingFrame: frame, frameCount: count, at: nil) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.scheduledFrames = 0
            }
        }
        scheduledFrames = max(0, remaining)
    }

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        tapInstalled = true
        let analyzer = self.analyzer
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            let bands = analyzer.process(buffer)
            var energy: Float = 0
            if let data = buffer.floatChannelData {
                let n = Int(buffer.frameLength)
                if n > 0 {
                    var sum: Float = 0
                    let channel = data[0]
                    var index = 0
                    while index < n { sum += channel[index] * channel[index]; index += 4 }
                    energy = sqrt(sum / Float(max(1, n / 4)))
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tapCounter &+= 1
                guard self.tapCounter % 3 == 0 else { return }
                self.spectrum = bands
                self.level = min(1, max(0, energy * 2.2))
            }
        }
    }

    private func observeDeviceChanges() {
        deviceObserver = AudioDeviceController.observeDefaultDeviceChange { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshOutputDevice()
                if let device = self.outputDevice, let format = self.activeFormat, abs(device.sampleRate - format.sampleRate) > 1 {
                    // Device changed to something that cannot match; let CoreAudio resample.
                    self.updateBitPerfect()
                }
            }
        }
    }

    // MARK: - Volume

    private func applyVolume() {
        let clamped = max(0, min(1, volume))
        guard let device = AudioDeviceController.defaultOutputDevice() else {
            engine.mainMixerNode.outputVolume = clamped
            return
        }
        if AudioDeviceController.setVolume(clamped, deviceID: device.id) {
            engine.mainMixerNode.outputVolume = 1.0
        } else {
            engine.mainMixerNode.outputVolume = clamped
        }
    }

    // MARK: - Position & transitions

    /// 播放时阻止 App Nap 节流定时器与音频渲染；暂停/停止后立即归还。
    private func beginPlaybackActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .automaticTerminationDisabled],
            reason: "Awake 正在播放音乐"
        )
    }

    private func endPlaybackActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    private func startUITimer() {
        uiTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer
    }

    private func tick() {
        guard let format = activeFormat, let file else { return }
        let sample = currentPlayerSample()
        if isPlaying {
            let positionFrames = baseFrame + max(0, sample - trackStartTick)
            elapsed = min(duration, Double(positionFrames) / format.sampleRate)
            // 播放器自然结束时 lastRenderTime 会变成 nil，sample 归零；
            // 极短曲目可能在结束判定前就走到这里，必须按“已停止且无无缝后续”补一次收尾。
            if !player.isPlaying, scheduledFrames <= 0, !hasNextQueued, !endSignaled {
                elapsed = duration
            }
        }

        if let pending = pendingNext, sample >= pending.tick {
            commitPendingTransition(pending, format: format)
        }

        if isPlaying, !hasNextQueued, !needsNextSignaled, duration - elapsed < 20 {
            needsNextSignaled = true
            onNeedsNextTrack?()
        }

        if isPlaying, !hasNextQueued, elapsed >= duration - 0.12, !endSignaled {
            endSignaled = true
            isPlaying = false
            isPaused = false
            endPlaybackActivity()
            _ = file
            onTrackFinished?()
        }
    }

    private func commitPendingTransition(_ pending: (track: Track, tick: AVAudioFramePosition), format: AVAudioFormat) {
        currentTrack = pending.track
        trackStartTick = pending.tick
        baseFrame = 0
        duration = pending.track.duration > 0 ? pending.track.duration : Double(max(1, pendingNextFile?.length ?? 1)) / format.sampleRate
        elapsed = 0
        pendingNext = nil
        pendingNextFile = nil
        hasNextQueued = false
        needsNextSignaled = false
        endSignaled = false
        onTrackStarted?(pending.track)
        updateBitPerfect()
    }

    private func currentPlayerSample() -> AVAudioFramePosition {
        guard let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return playerTime.sampleTime
    }

    private func updateBitPerfect() {
        guard let device = outputDevice, let format = activeFormat else {
            isBitPerfect = false
            return
        }
        let rateMatches = abs(device.sampleRate - format.sampleRate) < 1
        isBitPerfect = bitPerfectPreferred && isPlaying && !isPaused && rateMatches && eqCurve.isFlat
    }
}
