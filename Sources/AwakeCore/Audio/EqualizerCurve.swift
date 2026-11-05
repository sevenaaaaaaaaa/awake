import Foundation

/// ISO one-third-octave centers used by Awake's graphic EQ and by the AutoEQ matcher.
public enum EQBand {
    public static let frequencies: [Float] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160,
        200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
        2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000,
        20000
    ]

    public static var count: Int { frequencies.count }

    public static func label(for index: Int) -> String {
        let f = frequencies[max(0, min(frequencies.count - 1, index))]
        if f >= 1000 {
            let k = f / 1000
            return k == k.rounded() ? String(format: "%.0fk", k) : String(format: "%.1fk", k)
        }
        return String(format: "%.0f", f)
    }
}

/// A 31-band correction curve in dB plus a preamp (headroom) in dB.
public struct EQCurve: Codable, Equatable, Sendable {
    public var gains: [Float]
    public var preamp: Float

    public init(gains: [Float], preamp: Float = 0) {
        var normalized = gains
        if normalized.count < EQBand.count { normalized += Array(repeating: 0, count: EQBand.count - normalized.count) }
        if normalized.count > EQBand.count { normalized = Array(normalized.prefix(EQBand.count)) }
        self.gains = normalized
        self.preamp = preamp
    }

    public static let flat = EQCurve(gains: Array(repeating: 0, count: EQBand.count), preamp: 0)

    public var isFlat: Bool {
        gains.allSatisfy { abs($0) < 0.05 } && abs(preamp) < 0.05
    }

    public var maxGain: Float { gains.max() ?? 0 }
    public var minGain: Float { gains.min() ?? 0 }

    /// Clamp every band to +-limit dB.
    public func limited(to limit: Float) -> EQCurve {
        EQCurve(gains: gains.map { max(-limit, min(limit, $0)) }, preamp: preamp)
    }

    /// Scale a correction by 0...1 so users can dial the character without losing it.
    public func scaled(by factor: Float) -> EQCurve {
        let f = max(0, min(1.4, factor))
        return EQCurve(gains: gains.map { $0 * f }, preamp: preamp * f)
    }

    /// Preamp so the boosted curve never clips: -(max boost) - safety margin.
    public func headroomCurve(margin: Float = 1.0) -> EQCurve {
        let boost = max(0, maxGain)
        return EQCurve(gains: gains, preamp: min(preamp, -(boost + margin)))
    }

    public func flattened(above limit: Float) -> EQCurve {
        EQCurve(gains: gains.map { max(-limit, min(limit, $0)) }, preamp: preamp)
    }

    /// Add a tilt: positive brightens, negative warms.
    public func tilted(dBPerOctave: Float, pivot: Float = 1000) -> EQCurve {
        var result = gains
        for (i, f) in EQBand.frequencies.enumerated() {
            let octaves = log2(max(20, f) / pivot)
            result[i] += dBPerOctave * octaves
        }
        return EQCurve(gains: result, preamp: preamp)
    }
}
