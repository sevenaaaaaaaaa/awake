import AVFoundation
import Foundation

struct EQFilter: Codable, Equatable {
  var kind: String
  var frequency: Double
  var gain: Double
  var q: Double
}
enum EQMath {
  static let frequencies: [Float] = [
    20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250,
    1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
  ]
  static func parse(_ text: String) throws -> (Float, [EQFilter]) {
    guard text.utf8.count <= 65536 else { throw AppFailure("参数文件过大") }
    var preamp: Float = 0
    var filters: [EQFilter] = []
    for line in text.components(separatedBy: .newlines) {
      let w = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      guard let first = w.first else { continue }
      if first.lowercased() == "preamp:" {
        guard w.count >= 2, let p = Float(w[1]), p.isFinite, (-40...0).contains(p) else {
          throw AppFailure("前级应为 -40 到 0 dB")
        }
        preamp = p
      }
      if first.lowercased() != "filter" { continue }
      if w.contains("OFF") { continue }
      guard let on = w.firstIndex(of: "ON"), w.indices.contains(on + 1) else {
        throw AppFailure("滤波器格式无效")
      }
      let type = w[on + 1].uppercased()
      guard ["PK", "LS", "LSC", "HS", "HSC"].contains(type) else {
        throw AppFailure("只支持 PK / LSC / HSC 参数滤波器")
      }
      func number(_ key: String) throws -> Double {
        guard let i = w.firstIndex(of: key), w.indices.contains(i + 1), let n = Double(w[i + 1]),
          n.isFinite
        else { throw AppFailure("缺少或无效的 \(key)") }
        return n
      }
      let f = try number("Fc")
      let g = try number("Gain")
      let q = try number("Q")
      guard (10...22000).contains(f), abs(g) <= 18, (0.1...20).contains(q) else {
        throw AppFailure("参数超出支持范围")
      }
      filters.append(.init(kind: type, frequency: f, gain: g, q: q))
      guard filters.count <= 16 else { throw AppFailure("最多支持 16 个参数滤波器") }
    }
    guard !filters.isEmpty else { throw AppFailure("文件没有可用参数滤波器") }
    return (preamp, filters)
  }
  /// 整条曲线在 20 Hz–Nyquist 上的复合峰值（dB）。
  ///
  /// 每段按 RBJ 峰值滤波器算幅频响应，再在网格频率上各段相加（串联即 dB 相加）。
  /// 只用于前级余量计算，所以网格取 1/12 倍频程左右，够密也够快。
  static func peakGainDB(_ filters: [EQFilter], rate: Double) -> Float {
    guard !filters.isEmpty else { return 0 }
    let nyquist = rate / 2
    let top = min(20000, nyquist * 0.98)
    var peak = 0.0
    var frequency = 20.0
    while frequency < top {
      var total = 0.0
      for filter in filters where abs(filter.gain) >= 0.01 {
        let fc = min(filter.frequency, nyquist * 0.98)
        let a = pow(10, filter.gain / 40)
        let w0 = 2 * Double.pi * fc / rate
        let w = 2 * Double.pi * frequency / rate
        let alpha = sin(w0) / (2 * filter.q)
        let b0 = 1 + alpha * a, b1 = -2 * cos(w0), b2 = 1 - alpha * a
        let a0 = 1 + alpha / a, a1 = -2 * cos(w0), a2 = 1 - alpha / a
        let numRe = b0 + b1 * cos(-w) + b2 * cos(-2 * w)
        let numIm = b1 * sin(-w) + b2 * sin(-2 * w)
        let denRe = a0 + a1 * cos(-w) + a2 * cos(-2 * w)
        let denIm = a1 * sin(-w) + a2 * sin(-2 * w)
        let magnitude = (numRe * numRe + numIm * numIm).squareRoot()
          / max((denRe * denRe + denIm * denIm).squareRoot(), 1e-12)
        total += 20 * log10(max(magnitude, 1e-6))
      }
      peak = max(peak, total)
      frequency *= 1.06
    }
    return Float(peak)
  }

  static func bandwidth(q: Double) -> Float {
    Float(min(5, max(0.05, 2 * asinh(1 / (2 * q)) / log(2))))
  }
  static func configure(
    _ eq: AVAudioUnitEQ, correction: AVAudioUnitEQ, gains: [Float], apo: String, bypassed: Bool,
    rate: Double
  ) throws -> Float {
    guard gains.count == 31, gains.allSatisfy({ $0.isFinite && abs($0) <= 12 }) else {
      throw AppFailure("EQ 需要 31 个有效增益")
    }
    let parsed =
      apo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? (Float(0), [EQFilter]()) : try parse(apo)
    var filters = zip(frequencies, gains).map {
      EQFilter(kind: "PK", frequency: Double($0), gain: Double($1), q: 4.318)
    }
    filters.append(contentsOf: parsed.1)
    // 余量按「复合频响的真实峰值」算，而不是把每段的正增益相加：
    // 31 段峰值滤波器中心频率各不相同，同一频率上几乎不会同时抬满；
    // 相加会得到一个虚高的前级衰减，用户每调一次 EQ 就掉一次音量（0.9.32 修的就是这个）。
    let positive = filters.map { max(0, $0.gain) }.reduce(0, +)
    guard positive <= 90 else { throw AppFailure("叠加增益过大，请减少提升频段") }
    let peak = peakGainDB(filters, rate: rate)
    // 峰值再加 1 dB 安全余量；最多压到 −24 dB，避免一段误设把音量压没。
    let preamp = max(-24, min(parsed.0, Float(-max(0, peak + 1))))
    if bypassed {
      for b in eq.bands + correction.bands { b.bypass = true }
      eq.globalGain = 0
      correction.globalGain = 0
      return 0
    }
    eq.globalGain = preamp
    correction.globalGain = 0
    for (i, band) in (eq.bands + correction.bands).enumerated() {
      guard i < filters.count else {
        band.bypass = true
        continue
      }
      let f = filters[i]
      band.frequency = Float(min(f.frequency, max(100, rate * 0.49)))
      band.gain = Float(f.gain)
      band.bandwidth = bandwidth(q: f.q)
      band.filterType =
        f.kind == "PK"
        ? .parametric : (f.kind.hasPrefix("LS") ? .resonantLowShelf : .resonantHighShelf)
      band.bypass = bypassed || abs(f.gain) < 0.001 || f.frequency >= rate * 0.5
    }
    return preamp
  }
}

/// 把 CoreAudio / AVFoundation 抛出的 NSError 变成用户能看懂的一句话。
///
/// 0.9.1 的 iOS 包一开 App 就弹过 `The operation couldn't be completed. (OSStatus error -50.)`：
/// 用户看不出是哪个动作失败，也不知道该做什么，只知道「它坏了」。
/// 这里统一翻译一次，码值留在括号里，便于按日志检索。
enum AudioFailure {
  static func describe(_ error: Error, action: String) -> String {
    let ns = error as NSError
    let isAudio =
      ns.domain == NSOSStatusErrorDomain || ns.domain == "com.apple.coreaudio.avfaudio"
    if !isAudio {
      // 自己抛的业务错误（AppFailure 等）已经是一句中文，保留原文。
      if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
        return "\(action)失败：\(described)"
      }
      return "\(action)失败：\(ns.localizedDescription)"
    }
    return "\(action)失败：\(hint(for: ns.code))（OSStatus \(ns.code)）"
  }
  private static func hint(for code: Int) -> String {
    switch code {
    case -50: return "系统音频通道没准备好或被其他应用占用，先退出正在播放的应用再试"
    case -10868: return "这个音频格式系统不认"
    case -10875: return "音频引擎没能启动"
    case 1954115647: return "文件不是系统能解码的音频"
    case 2003334207: return "文件是空的，没有音频数据"
    default: return "系统音频返回了一个错误"
    }
  }
}
