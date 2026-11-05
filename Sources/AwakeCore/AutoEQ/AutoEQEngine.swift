import Foundation

/// Long-lived, on-device listener model. Every manual EQ move nudges a 31-band bias,
/// so Awake converges on the sound this listener actually prefers without ever asking.
public struct ListenerProfile: Codable, Equatable, Sendable {
    public var bias: [Float]
    public var sampleCount: Int
    public var updatedAt: Date

    public init(bias: [Float] = Array(repeating: 0, count: EQBand.count),
                sampleCount: Int = 0,
                updatedAt: Date = Date()) {
        var normalized = bias
        if normalized.count < EQBand.count { normalized += Array(repeating: 0, count: EQBand.count - normalized.count) }
        self.bias = Array(normalized.prefix(EQBand.count))
        self.sampleCount = sampleCount
        self.updatedAt = updatedAt
    }

    public static func load() -> ListenerProfile {
        JSONFile.read(ListenerProfile.self, at: AwakePaths.autoeqFile) ?? ListenerProfile()
    }

    public func save() {
        JSONFile.write(self, to: AwakePaths.autoeqFile)
    }

    public var biasCurve: EQCurve {
        EQCurve(gains: bias.map { max(-4, min(4, $0)) }, preamp: 0)
    }

    /// Exponential moving average with a slow learning rate.
    public mutating func learn(delta: [Float]) {
        guard delta.count == EQBand.count else { return }
        for i in 0..<EQBand.count {
            let target = max(-4, min(4, bias[i] * 0.85 + delta[i] * 0.15))
            bias[i] = target
        }
        sampleCount += 1
        updatedAt = Date()
        save()
    }

    public mutating func reset() {
        bias = Array(repeating: 0, count: EQBand.count)
        sampleCount = 0
        updatedAt = Date()
        save()
    }
}

public struct AutoEQDecision: Equatable, Sendable {
    public var curve: EQCurve
    public var headphone: HeadphoneProfile
    public var trackProfile: TrackAcousticProfile?
    public var reason: String
    public var confidence: Double
    public var usedListenerBias: Bool

    public init(curve: EQCurve, headphone: HeadphoneProfile, trackProfile: TrackAcousticProfile?,
                reason: String, confidence: Double, usedListenerBias: Bool) {
        self.curve = curve
        self.headphone = headphone
        self.trackProfile = trackProfile
        self.reason = reason
        self.confidence = confidence
        self.usedListenerBias = usedListenerBias
    }
}

/// Decides the correction curve for one track on one output device.
///
/// Layers, in order:
/// 1. headphone correction (built-in, or an imported AutoEQ ParametricEQ profile)
/// 2. track-aware adaptation (bass-heavy / bright / dark material gets a gentler touch)
/// 3. learned listener bias from previous manual adjustments
/// 4. intensity scaling + headroom
public actor AutoEQEngine {

    public static let shared = AutoEQEngine()

    private var listener: ListenerProfile
    private var importedProfiles: [String: HeadphoneProfile] = [:]

    public init() {
        listener = ListenerProfile.load()
    }

    public func currentListenerProfile() -> ListenerProfile { listener }

    public func learn(delta: [Float]) {
        listener.learn(delta: delta)
    }

    public func resetLearning() {
        listener.reset()
    }

    /// Import an AutoEQ ParametricEQ.txt and register it as a selectable profile.
    @discardableResult
    public func importParametricEQ(name: String, text: String, sampleRate: Double = 48000) -> HeadphoneProfile? {
        let parsed = ParametricEQ.parse(text)
        guard !parsed.filters.isEmpty else { return nil }
        let profile = HeadphoneProfile(
            id: "imported-" + name.lowercased().replacingOccurrences(of: " ", with: "-"),
            name: name,
            brand: "导入",
            kind: "AutoEQ",
            matchKeywords: [],
            note: "从 AutoEQ ParametricEQ.txt 导入（\(parsed.filters.count) 个滤波器）。",
            filters: parsed.filters,
            preamp: parsed.preamp)
        importedProfiles[profile.id] = profile
        return profile
    }

    public func imported() -> [HeadphoneProfile] { Array(importedProfiles.values) }

    public func decide(track: Track, url: URL, device: AudioOutputDevice?,
                       preference: String, intensity: Double, headroomDB: Double,
                       analyzeTrack: Bool = true) async -> AutoEQDecision {
        let headphone = HeadphoneDatabase.resolve(preference: preference,
                                                  deviceName: device?.name,
                                                  isHeadphoneDevice: device?.isHeadphones ?? false)
        var curve = headphone.curve
        var reasons: [String] = []
        var confidence = 0.55

        if headphone.id != HeadphoneDatabase.neutralID {
            reasons.append("已匹配「\(headphone.displayName)」校正曲线")
            confidence += 0.18
        } else {
            reasons.append("未识别到耳机型号，使用参考平直")
        }

        var trackProfile: TrackAcousticProfile?
        if analyzeTrack {
            trackProfile = await TrackSpectrumAnalyzer.profile(for: track, url: url)
        }

        if let profile = trackProfile {
            var adaptive = EQCurve.flat
            if profile.isBassHeavy {
                adaptive = adaptive.adding(bump(center: 90, width: 1.1, gain: -1.2))
                reasons.append("曲目低频偏重，收敛 90 Hz")
            }
            if profile.isBright {
                adaptive = adaptive.adding(bump(center: 7500, width: 1.0, gain: -1.4))
                reasons.append("曲目偏亮，收敛 7.5 kHz")
            } else if profile.isDark {
                adaptive = adaptive.adding(bump(center: 6000, width: 1.2, gain: 1.2))
                reasons.append("曲目偏暗，提亮 6 kHz")
            }
            if profile.rmsDB > -9 {
                adaptive = adaptive.adding(bump(center: 70, width: 1.0, gain: -0.8))
                reasons.append("响度很高，减少低频堆积")
            }
            curve = curve.adding(adaptive)
            confidence += 0.15
        }

        let usedBias = listener.sampleCount > 0
        if usedBias {
            curve = curve.adding(listener.biasCurve)
            reasons.append("叠加你的听感偏好（\(listener.sampleCount) 次学习）")
            confidence += 0.1
        }

        let scaled = curve.scaled(by: Float(max(0, min(1.2, intensity))))
        let limited = scaled.flattened(above: 9)
        let boost = max(0, limited.maxGain)
        let preamp = -(boost + 0.8) + Float(min(0, headroomDB))
        let final = EQCurve(gains: limited.gains, preamp: preamp)

        return AutoEQDecision(curve: final,
                              headphone: headphone,
                              trackProfile: trackProfile,
                              reason: reasons.joined(separator: " · "),
                              confidence: min(0.98, confidence),
                              usedListenerBias: usedBias)
    }

    /// Used by the UI when the user drags a band: returns the delta between the
    /// user's curve and the automatic curve, which becomes training data.
    public func manualDelta(manual: EQCurve, automatic: EQCurve) -> [Float] {
        zip(manual.gains, automatic.gains).map { $0 - $1 }
    }

    private func bump(center: Float, width: Float, gain: Float) -> EQCurve {
        var gains = [Float](repeating: 0, count: EQBand.count)
        for (index, frequency) in EQBand.frequencies.enumerated() {
            let distance = log2(max(20, frequency) / center) / width
            gains[index] = gain * exp(-0.5 * distance * distance)
        }
        return EQCurve(gains: gains)
    }
}

extension EQCurve {
    func adding(_ other: EQCurve) -> EQCurve {
        var result = gains
        for i in 0..<min(result.count, other.gains.count) { result[i] += other.gains[i] }
        return EQCurve(gains: result, preamp: preamp + other.preamp)
    }
}
