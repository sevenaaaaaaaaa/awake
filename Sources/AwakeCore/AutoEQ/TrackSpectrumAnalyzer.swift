import Foundation
import AVFoundation
import Accelerate

/// A compact fingerprint of how a track is balanced in the frequency domain.
/// Used by AutoEQ to adapt the correction to the material instead of applying
/// the same curve to everything.
public struct TrackAcousticProfile: Codable, Equatable, Sendable {
    public var lowDB: Float       // 20-250 Hz, relative to full-band average
    public var midDB: Float       // 250-4000 Hz
    public var highDB: Float      // 4k-16k
    public var tilt: Float        // dB per octave regression, 100 Hz - 10 kHz
    public var centroid: Float    // Hz
    public var rmsDB: Float       // dBFS
    public var sampleRate: Int
    public var analyzedAt: Date
    public var signature: String

    public var isBassHeavy: Bool { lowDB - midDB > 4 }
    public var isBright: Bool { highDB - midDB > 3 }
    public var isDark: Bool { highDB - midDB < -5 }
    public var isQuiet: Bool { rmsDB < -26 }
}

public enum TrackSpectrumAnalyzer {

    public static func signature(for track: Track) -> String {
        "\(track.fileSize)-\(Int(track.modified.timeIntervalSince1970))-\(track.sampleRate)"
    }

    /// Cached profile for a track, analyzed on demand.
    public static func profile(for track: Track, url: URL) async -> TrackAcousticProfile? {
        let expected = signature(for: track)
        let cacheURL = AwakePaths.analysisCache.appendingPathComponent(track.id + ".json")
        if let cached = JSONFile.read(TrackAcousticProfile.self, at: cacheURL), cached.signature == expected {
            return cached
        }
        let analyzed = await Task.detached(priority: .utility) { () -> TrackAcousticProfile? in
            try? analyze(url: url, signature: expected)
        }.value
        if let analyzed { JSONFile.write(analyzed, to: cacheURL) }
        return analyzed
    }

    /// Reads three short windows (15% / 45% / 75%) of the file and averages their
    /// power spectrum. Deliberately cheap: < 300 ms for a 5 minute track.
    public static func analyze(url: URL, signature: String) throws -> TrackAcousticProfile {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0, format.channelCount > 0 else {
            throw AudioEngineError.unsupportedFormat
        }

        let fftSize = 2048
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw AudioEngineError.unsupportedFormat
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let binCount = fftSize / 2
        var accumulated = [Double](repeating: 0, count: binCount)
        var frames = 0
        var sumSquares: Double = 0
        var sampleCount: Double = 0

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(fftSize)) else {
            throw AudioEngineError.unsupportedFormat
        }

        var real = [Float](repeating: 0, count: binCount)
        var imag = [Float](repeating: 0, count: binCount)
        var windowed = [Float](repeating: 0, count: fftSize)
        var magnitudes = [Float](repeating: 0, count: binCount)

        let fractions: [Double] = [0.15, 0.45, 0.75]
        for fraction in fractions {
            let startFrame = AVAudioFramePosition(Double(file.length) * fraction)
            file.framePosition = min(startFrame, max(0, file.length - AVAudioFramePosition(fftSize)))
            var framesRead = 0
            let targetFrames = Int(sampleRate * 6)
            while framesRead < targetFrames {
                buffer.frameLength = AVAudioFrameCount(fftSize)
                try file.read(into: buffer, frameCount: AVAudioFrameCount(fftSize))
                let n = Int(buffer.frameLength)
                guard n > 64, let channel = buffer.floatChannelData?[0] else { break }

                var localSum: Float = 0
                vDSP_vsq(channel, 1, &windowed, 1, vDSP_Length(n))
                vDSP_sve(windowed, 1, &localSum, vDSP_Length(n))
                sumSquares += Double(localSum)
                sampleCount += Double(n)

                vDSP_vclr(&windowed, 1, vDSP_Length(fftSize))
                vDSP_vmul(channel, 1, window, 1, &windowed, 1, vDSP_Length(n))

                var output = DSPSplitComplex(realp: &real, imagp: &imag)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: binCount) { complex in
                        vDSP_ctoz(complex, 2, &output, 1, vDSP_Length(binCount))
                    }
                }
                vDSP_fft_zrip(setup, &output, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&output, 1, &magnitudes, 1, vDSP_Length(binCount))

                for bin in 1..<binCount {
                    let value = Double(magnitudes[bin])
                    accumulated[bin] += value * value
                }
                frames += 1
                framesRead += n
            }
        }

        guard frames > 0 else { throw AudioEngineError.unsupportedFormat }

        let binHz = sampleRate / Double(fftSize)
        func bandPower(_ low: Double, _ high: Double) -> Double {
            let lowBin = max(1, Int(low / binHz))
            let highBin = min(binCount - 1, Int(high / binHz))
            guard highBin > lowBin else { return 0 }
            var sum = 0.0
            for bin in lowBin...highBin { sum += accumulated[bin] }
            return sum / Double(highBin - lowBin + 1)
        }

        let low = bandPower(20, 250)
        let mid = bandPower(250, 4000)
        let high = bandPower(4000, min(16000, sampleRate / 2 - 1))
        let full = bandPower(20, min(16000, sampleRate / 2 - 1))
        func rel(_ value: Double) -> Float {
            guard value > 0, full > 0 else { return 0 }
            return Float(10 * log10(value / full))
        }

        // Spectral centroid.
        var weighted = 0.0
        var total = 0.0
        for bin in 1..<binCount {
            let frequency = Double(bin) * binHz
            guard frequency > 40, frequency < 16000 else { continue }
            weighted += frequency * accumulated[bin]
            total += accumulated[bin]
        }
        let centroid = total > 0 ? Float(weighted / total) : 0

        // Tilt: least squares slope of dB over log2(f), 100 Hz - 10 kHz.
        var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0, count = 0.0
        for bin in 1..<binCount {
            let frequency = Double(bin) * binHz
            guard frequency >= 100, frequency <= 10000 else { continue }
            let power = accumulated[bin]
            guard power > 0 else { continue }
            let x = log2(frequency)
            let y = 10 * log10(power)
            sumX += x; sumY += y; sumXX += x * x; sumXY += x * y; count += 1
        }
        var tilt: Double = 0
        if count > 2 {
            let denominator = count * sumXX - sumX * sumX
            if abs(denominator) > 1e-9 {
                tilt = (count * sumXY - sumX * sumY) / denominator
            }
        }

        let rms = sampleCount > 0 ? sqrt(sumSquares / sampleCount) : 0
        let rmsDB = rms > 0 ? Float(20 * log10(rms)) : -96

        return TrackAcousticProfile(
            lowDB: rel(low),
            midDB: rel(mid),
            highDB: rel(high),
            tilt: Float(max(-6, min(6, tilt))),
            centroid: centroid,
            rmsDB: max(-96, rmsDB),
            sampleRate: Int(sampleRate),
            analyzedAt: Date(),
            signature: signature)
    }
}
