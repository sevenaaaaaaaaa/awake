import Foundation

/// A single parametric EQ filter in the AutoEQ / Equalizer APO vocabulary.
public struct ParametricFilter: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case peaking = "PK"
        case lowShelf = "LS"
        case highShelf = "HS"
        case lowPass = "LP"
        case highPass = "HP"
        case notch = "NO"
    }

    public var kind: Kind
    public var frequency: Double
    public var gainDB: Double
    public var q: Double

    public init(kind: Kind, frequency: Double, gainDB: Double = 0, q: Double = 0.7) {
        self.kind = kind
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
    }
}

/// Parses Equalizer APO / AutoEQ "ParametricEQ.txt" profiles and evaluates their
/// magnitude response on Awake's 31-band grid.
public enum ParametricEQ {

    public struct Profile: Codable, Equatable, Sendable {
        public var preamp: Double
        public var filters: [ParametricFilter]

        public init(preamp: Double = 0, filters: [ParametricFilter] = []) {
            self.preamp = preamp
            self.filters = filters
        }

        public var isEmpty: Bool { filters.isEmpty && abs(preamp) < 0.01 }
    }

    /// Parses lines such as:
    /// Preamp: -6.2 dB
    /// Filter 1: ON PK Fc 105 Hz Gain 5.5 dB Q 0.70
    /// Filter 2: ON LS Fc 80 Hz Gain 4.0 dB Q 0.71
    public static func parse(_ text: String) -> Profile {
        var preamp: Double = 0
        var filters: [ParametricFilter] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmed
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("preamp:") {
                let numbers = extractNumbers(line)
                if let first = numbers.first { preamp = first }
                continue
            }
            guard lower.contains("filter") else { continue }
            // Only active filters: "ON" (some profiles use "ON PK").
            guard lower.contains(" on ") || lower.contains(": on") || lower.contains("on pk") || lower.contains("on ls") || lower.contains("on hs") else { continue }
            var kind: ParametricFilter.Kind?
            if lower.contains(" pk ") { kind = .peaking }
            else if lower.contains(" ls ") { kind = .lowShelf }
            else if lower.contains(" hs ") { kind = .highShelf }
            else if lower.contains(" lp ") { kind = .lowPass }
            else if lower.contains(" hp ") { kind = .highPass }
            else if lower.contains(" no ") { kind = .notch }
            guard let kind else { continue }

            let fc = value(after: ["fc", "freq"], in: lower, original: line)
            let gain = value(after: ["gain"], in: lower, original: line)
            let q = value(after: ["q"], in: lower, original: line) ?? 0.707
            guard let frequency = fc, frequency > 10 else { continue }
            filters.append(ParametricFilter(kind: kind, frequency: frequency, gainDB: gain ?? 0, q: max(0.1, q)))
        }
        return Profile(preamp: preamp, filters: filters)
    }

    /// Convert a parsed profile into 31 dB gains at the given sample rate.
    public static func response(profile: Profile, sampleRate: Double = 48000) -> EQCurve {
        var gains = [Float](repeating: 0, count: EQBand.count)
        for (index, frequency) in EQBand.frequencies.enumerated() {
            var total = 0.0
            for filter in profile.filters {
                total += magnitudeDB(filter: filter, at: Double(frequency), sampleRate: sampleRate)
            }
            gains[index] = Float(max(-24, min(24, total)))
        }
        return EQCurve(gains: gains, preamp: Float(profile.preamp))
    }

    // MARK: - Biquad math (RBJ cookbook)

    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    }

    static func coefficients(_ filter: ParametricFilter, sampleRate: Double) -> Biquad {
        let f0 = max(10, min(filter.frequency, sampleRate * 0.49))
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosW = cos(w0)
        let sinW = sin(w0)
        let A = pow(10, filter.gainDB / 40)
        let q = max(0.05, filter.q)
        var b = Biquad()

        switch filter.kind {
        case .peaking:
            let alpha = sinW / (2 * q)
            let a0 = 1 + alpha / A
            b.b0 = (1 + alpha * A) / a0
            b.b1 = (-2 * cosW) / a0
            b.b2 = (1 - alpha * A) / a0
            b.a1 = (-2 * cosW) / a0
            b.a2 = (1 - alpha / A) / a0
        case .lowShelf:
            let alpha = sinW / 2 * sqrt((A + 1 / A) * (1 - 1) + 2)
            let a0 = (A + 1) + (A - 1) * cosW + 2 * sqrt(A) * alpha
            b.b0 = A * ((A + 1) - (A - 1) * cosW + 2 * sqrt(A) * alpha) / a0
            b.b1 = 2 * A * ((A - 1) - (A + 1) * cosW) / a0
            b.b2 = A * ((A + 1) - (A - 1) * cosW - 2 * sqrt(A) * alpha) / a0
            b.a1 = -2 * ((A - 1) + (A + 1) * cosW) / a0
            b.a2 = ((A + 1) + (A - 1) * cosW - 2 * sqrt(A) * alpha) / a0
        case .highShelf:
            let alpha = sinW / 2 * sqrt((A + 1 / A) * (1 - 1) + 2)
            let a0 = (A + 1) - (A - 1) * cosW + 2 * sqrt(A) * alpha
            b.b0 = A * ((A + 1) + (A - 1) * cosW + 2 * sqrt(A) * alpha) / a0
            b.b1 = -2 * A * ((A - 1) + (A + 1) * cosW) / a0
            b.b2 = A * ((A + 1) + (A - 1) * cosW - 2 * sqrt(A) * alpha) / a0
            b.a1 = 2 * ((A - 1) - (A + 1) * cosW) / a0
            b.a2 = ((A + 1) - (A - 1) * cosW - 2 * sqrt(A) * alpha) / a0
        case .lowPass:
            let alpha = sinW / (2 * q)
            let a0 = 1 + alpha
            b.b0 = ((1 - cosW) / 2) / a0
            b.b1 = (1 - cosW) / a0
            b.b2 = ((1 - cosW) / 2) / a0
            b.a1 = (-2 * cosW) / a0
            b.a2 = (1 - alpha) / a0
        case .highPass:
            let alpha = sinW / (2 * q)
            let a0 = 1 + alpha
            b.b0 = ((1 + cosW) / 2) / a0
            b.b1 = -(1 + cosW) / a0
            b.b2 = ((1 + cosW) / 2) / a0
            b.a1 = (-2 * cosW) / a0
            b.a2 = (1 - alpha) / a0
        case .notch:
            let alpha = sinW / (2 * q)
            let a0 = 1 + alpha
            b.b0 = 1 / a0
            b.b1 = (-2 * cosW) / a0
            b.b2 = 1 / a0
            b.a1 = (-2 * cosW) / a0
            b.a2 = (1 - alpha) / a0
        }
        return b
    }

    static func magnitudeDB(filter: ParametricFilter, at frequency: Double, sampleRate: Double) -> Double {
        let b = coefficients(filter, sampleRate: sampleRate)
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(-w), sin1 = sin(-w)
        let cos2 = cos(-2 * w), sin2 = sin(-2 * w)
        let numRe = b.b0 + b.b1 * cos1 + b.b2 * cos2
        let numIm = b.b1 * sin1 + b.b2 * sin2
        let denRe = 1 + b.a1 * cos1 + b.a2 * cos2
        let denIm = b.a1 * sin1 + b.a2 * sin2
        let num = sqrt(numRe * numRe + numIm * numIm)
        let den = sqrt(denRe * denRe + denIm * denIm)
        guard den > 1e-12 else { return 0 }
        return 20 * log10(max(1e-9, num / den))
    }

    // MARK: - Line helpers

    private static func extractNumbers(_ line: String) -> [Double] {
        let pattern = "[-+]?[0-9]*\\.?[0-9]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap {
            Double(ns.substring(with: $0.range))
        }
    }

    private static func value(after keywords: [String], in lower: String, original: String) -> Double? {
        for keyword in keywords {
            guard let range = lower.range(of: keyword) else { continue }
            let tail = String(original[range.upperBound...])
            if let value = extractNumbers(tail).first { return value }
        }
        return nil
    }
}
