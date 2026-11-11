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
    // Conservative control-space headroom. Actual AU rendering is checked by the offline benchmark.
    let positive = filters.map { max(0, $0.gain) }.reduce(0, +)
    guard positive <= 90 else { throw AppFailure("叠加增益过大，请减少提升频段") }
    let preamp = min(parsed.0, Float(-positive - (positive > 0 ? 3 : 0)))
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
