import Foundation
import AVFoundation
import Accelerate

/// Real-time 32-band spectrum for the visualizer. Runs on the audio render thread,
/// so it keeps its own scratch buffers and only publishes a finished array.
public final class SpectrumAnalyzer {
    public let bandCount: Int
    public private(set) var levels: [Float]

    private let fftSize: Int
    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var samples: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]
    private var smoothed: [Float]
    private var bandEdges: [(Int, Int)]
    private var sampleRate: Float

    public init(bandCount: Int = 32, fftSize: Int = 1024, sampleRate: Float = 48000) {
        self.bandCount = bandCount
        self.fftSize = fftSize
        self.log2n = vDSP_Length(log2(Float(fftSize)).rounded())
        self.sampleRate = sampleRate
        levels = Array(repeating: 0, count: bandCount)
        window = Array(repeating: 0, count: fftSize)
        samples = Array(repeating: 0, count: fftSize)
        real = Array(repeating: 0, count: fftSize / 2)
        imag = Array(repeating: 0, count: fftSize / 2)
        magnitudes = Array(repeating: 0, count: fftSize / 2)
        smoothed = Array(repeating: 0, count: bandCount)
        bandEdges = []
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        rebuildBands()
    }

    deinit {
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
    }

    public func updateSampleRate(_ rate: Double) {
        let value = Float(max(8000, rate))
        guard abs(value - sampleRate) > 1 else { return }
        sampleRate = value
        rebuildBands()
    }

    private func rebuildBands() {
        let minHz: Float = 40
        let maxHz: Float = min(18000, sampleRate / 2)
        let nyquistBins = fftSize / 2
        var edges: [(Int, Int)] = []
        for i in 0..<bandCount {
            let low = minHz * powf(maxHz / minHz, Float(i) / Float(bandCount))
            let high = minHz * powf(maxHz / minHz, Float(i + 1) / Float(bandCount))
            var lowBin = Int(low * Float(fftSize) / sampleRate)
            var highBin = Int(high * Float(fftSize) / sampleRate)
            lowBin = max(1, min(nyquistBins - 1, lowBin))
            highBin = max(lowBin + 1, min(nyquistBins, highBin))
            edges.append((lowBin, highBin))
        }
        bandEdges = edges
    }

    /// Feed a tap buffer; returns the smoothed 0...1 band levels.
    public func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return levels }
        let count = min(Int(buffer.frameLength), fftSize)
        guard count >= 64 else { return levels }

        let source = channels[0]
        vDSP_vclr(&samples, 1, vDSP_Length(fftSize))
        vDSP_vmul(source, 1, window, 1, &samples, 1, vDSP_Length(count))
        if count < fftSize { vDSP_vclr(samples.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: count) }, 1, vDSP_Length(fftSize - count)) }

        guard let setup = fftSetup else { return levels }
        var output = DSPSplitComplex(realp: &real, imagp: &imag)
        samples.withUnsafeBufferPointer { pointer in
            pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complex in
                vDSP_ctoz(complex, 2, &output, 1, vDSP_Length(fftSize / 2))
            }
        }
        vDSP_fft_zrip(setup, &output, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&output, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

        let scale = 2.0 / Float(fftSize)
        var updated = smoothed
        for i in 0..<bandCount {
            let (low, high) = bandEdges[i]
            var peak: Float = 0
            for bin in low..<high { peak = max(peak, magnitudes[bin]) }
            let amplitude = peak * scale
            let db = 20 * log10(max(amplitude, 1e-7))
            // -62 dB floor, 0 dB ceiling.
            let normalized = max(0, min(1, (db + 62) / 62))
            // Fast attack, slow release for a musical feel.
            let previous = smoothed[i]
            updated[i] = normalized > previous ? normalized : previous * 0.82 + normalized * 0.18
        }
        smoothed = updated
        levels = updated
        return updated
    }

    public func reset() {
        smoothed = Array(repeating: 0, count: bandCount)
        levels = smoothed
    }
}
