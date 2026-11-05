import Foundation

/// A headphone correction curve shipped with Awake.
///
/// The curves are compact parametric approximations of the popular AutoEQ corrections,
/// expressed relative to a neutral studio target. They are intentionally mild: Awake's
/// AutoEQ applies them scaled by the user's intensity preference, and imported AutoEQ
/// ParametricEQ.txt profiles always take precedence.
public struct HeadphoneProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var brand: String
    public var kind: String
    public var matchKeywords: [String]
    public var note: String
    public var filters: [ParametricFilter]
    public var preamp: Double

    public init(id: String, name: String, brand: String, kind: String,
                matchKeywords: [String], note: String,
                filters: [ParametricFilter], preamp: Double = 0) {
        self.id = id
        self.name = name
        self.brand = brand
        self.kind = kind
        self.matchKeywords = matchKeywords
        self.note = note
        self.filters = filters
        self.preamp = preamp
    }

    public var curve: EQCurve {
        ParametricEQ.response(profile: ParametricEQ.Profile(preamp: preamp, filters: filters))
    }

    public var displayName: String { brand.isEmpty ? name : "\(brand) \(name)" }
}

public enum HeadphoneDatabase {

    public static let genericOverEarID = "generic-over-ear"
    public static let genericInEarID = "generic-in-ear"
    public static let neutralID = "neutral"

    public static let all: [HeadphoneProfile] = [
        HeadphoneProfile(
            id: "apple-airpods-pro-2", name: "AirPods Pro (第 2 代)", brand: "Apple", kind: "真无线",
            matchKeywords: ["airpods pro"],
            note: "接近 Harman 入耳目标，仅补一点下潜、收敛 8k 齿音。",
            filters: [ParametricFilter(kind: .peaking, frequency: 80, gainDB: 3.0, q: 0.7),
                      ParametricFilter(kind: .peaking, frequency: 220, gainDB: -1.0, q: 1.0),
                      ParametricFilter(kind: .peaking, frequency: 4200, gainDB: 1.5, q: 1.4),
                      ParametricFilter(kind: .peaking, frequency: 9000, gainDB: -1.5, q: 2.4)],
            preamp: -2),
        HeadphoneProfile(
            id: "apple-airpods-max", name: "AirPods Max", brand: "Apple", kind: "头戴",
            matchKeywords: ["airpods max"],
            note: "低频略多、中频凹陷，做温和的 Harman 头戴补偿。",
            filters: [ParametricFilter(kind: .peaking, frequency: 65, gainDB: -2.5, q: 0.7),
                      ParametricFilter(kind: .peaking, frequency: 1100, gainDB: 2.0, q: 1.0),
                      ParametricFilter(kind: .peaking, frequency: 3600, gainDB: 1.5, q: 1.2),
                      ParametricFilter(kind: .peaking, frequency: 8500, gainDB: -1.0, q: 2.0)],
            preamp: -2),
        HeadphoneProfile(
            id: "sony-wh-1000xm5", name: "WH-1000XM5", brand: "Sony", kind: "头戴",
            matchKeywords: ["wh-1000xm5", "wh1000xm5"],
            note: "出厂低频抬升明显，-3 dB 收敛 110 Hz，补一点 2.5k 人声。",
            filters: [ParametricFilter(kind: .peaking, frequency: 110, gainDB: -3.0, q: 0.8),
                      ParametricFilter(kind: .peaking, frequency: 420, gainDB: -1.0, q: 1.0),
                      ParametricFilter(kind: .peaking, frequency: 2500, gainDB: 1.5, q: 1.2),
                      ParametricFilter(kind: .peaking, frequency: 6300, gainDB: 0.8, q: 1.6)],
            preamp: -1),
        HeadphoneProfile(
            id: "sony-wh-1000xm4", name: "WH-1000XM4", brand: "Sony", kind: "头戴",
            matchKeywords: ["wh-1000xm4", "wh1000xm4"],
            note: "比 XM5 更厚的低频，收敛 100 Hz 并提亮 3k。",
            filters: [ParametricFilter(kind: .peaking, frequency: 100, gainDB: -3.5, q: 0.7),
                      ParametricFilter(kind: .peaking, frequency: 500, gainDB: -1.0, q: 1.0),
                      ParametricFilter(kind: .peaking, frequency: 3000, gainDB: 1.5, q: 1.1),
                      ParametricFilter(kind: .peaking, frequency: 7000, gainDB: 0.8, q: 1.8)],
            preamp: -1),
        HeadphoneProfile(
            id: "bose-qc45", name: "QuietComfort 45", brand: "Bose", kind: "头戴",
            matchKeywords: ["qc45", "quietcomfort 45", "quietcomfort"],
            note: "中低频偏厚，收敛 100 Hz 并补 3k 清晰度。",
            filters: [ParametricFilter(kind: .peaking, frequency: 100, gainDB: -2.5, q: 0.7),
                      ParametricFilter(kind: .peaking, frequency: 900, gainDB: -1.0, q: 1.2),
                      ParametricFilter(kind: .peaking, frequency: 3200, gainDB: 1.2, q: 1.2)],
            preamp: -1),
        HeadphoneProfile(
            id: "sennheiser-hd600", name: "HD 600", brand: "Sennheiser", kind: "头戴",
            matchKeywords: ["hd 600", "hd600"],
            note: "参考级中频，补下潜、轻微收敛 3.5k 与 6.5k。",
            filters: [ParametricFilter(kind: .lowShelf, frequency: 55, gainDB: 4.0, q: 0.7),
                      ParametricFilter(kind: .peaking, frequency: 3500, gainDB: -1.5, q: 1.2),
                      ParametricFilter(kind: .peaking, frequency: 6500, gainDB: -1.0, q: 2.0),
                      ParametricFilter(kind: .highShelf, frequency: 12000, gainDB: 1.0, q: 0.7)],
            preamp: -4),
        HeadphoneProfile(
            id: "sennheiser-hd650", name: "HD 650", brand: "Sennheiser", kind: "头戴",
            matchKeywords: ["hd 650", "hd650", "hd 6xx"],
            note: "暖厚耐听，补一点超低频、收敛 3k 与 6k 的亮度。",
            filters: [ParametricFilter(kind: .lowShelf, frequency: 50, gainDB: 3.5, q: 0.7),
                      ParametricFilter(kind: .peaking, frequency: 3000, gainDB: -1.0, q: 1.1),
                      ParametricFilter(kind: .peaking, frequency: 6000, gainDB: -1.5, q: 1.8)],
            preamp: -3),
        HeadphoneProfile(
            id: "beyerdynamic-dt770", name: "DT 770 PRO", brand: "Beyerdynamic", kind: "头戴",
            matchKeywords: ["dt 770", "dt770"],
            note: "经典高频峰，重点收敛 5.5k/8k，避免长时间疲劳。",
            filters: [ParametricFilter(kind: .peaking, frequency: 8000, gainDB: -4.0, q: 1.2),
                      ParametricFilter(kind: .peaking, frequency: 5500, gainDB: -2.0, q: 1.5),
                      ParametricFilter(kind: .lowShelf, frequency: 60, gainDB: 1.5, q: 0.7)],
            preamp: -1),
        HeadphoneProfile(
            id: "moondrop-aria", name: "Aria", brand: "Moondrop", kind: "入耳",
            matchKeywords: ["aria", "moondrop"],
            note: "Harman 入耳，补 200 Hz 厚度与 3k 人声，收敛 8k。",
            filters: [ParametricFilter(kind: .peaking, frequency: 200, gainDB: 1.5, q: 0.9),
                      ParametricFilter(kind: .peaking, frequency: 3000, gainDB: 1.5, q: 1.1),
                      ParametricFilter(kind: .peaking, frequency: 8000, gainDB: -2.0, q: 2.0)],
            preamp: -2),
        HeadphoneProfile(
            id: genericOverEarID, name: "通用头戴", brand: "", kind: "头戴",
            matchKeywords: [],
            note: "没有识别到具体型号时的温和补偿：补下潜、收敛 6k 齿音。",
            filters: [ParametricFilter(kind: .lowShelf, frequency: 60, gainDB: 2.0, q: 0.7),
                      ParametricFilter(kind: .peaking, frequency: 6000, gainDB: -1.0, q: 1.8)],
            preamp: -2),
        HeadphoneProfile(
            id: genericInEarID, name: "通用入耳", brand: "", kind: "入耳",
            matchKeywords: [],
            note: "入耳式通用补偿：收敛低频轰鸣、补人声。",
            filters: [ParametricFilter(kind: .peaking, frequency: 120, gainDB: -1.5, q: 0.8),
                      ParametricFilter(kind: .peaking, frequency: 2800, gainDB: 1.5, q: 1.2)],
            preamp: -1),
        HeadphoneProfile(
            id: neutralID, name: "参考平直", brand: "", kind: "参考",
            matchKeywords: [],
            note: "不做耳机补偿，只保留曲目自适应微调。",
            filters: [],
            preamp: 0)
    ]

    public static func profile(id: String) -> HeadphoneProfile? {
        all.first { $0.id == id }
    }

    /// Best-effort match from a CoreAudio device name (AirPods, WH-1000XM5, HD 600 ...).
    public static func match(deviceName: String?) -> HeadphoneProfile? {
        guard let raw = deviceName?.lowercased(), !raw.isEmpty else { return nil }
        for profile in all where !profile.matchKeywords.isEmpty {
            if profile.matchKeywords.contains(where: { raw.contains($0.lowercased()) }) { return profile }
        }
        if raw.contains("耳机") || raw.contains("headphone") || raw.contains("earbud") {
            return profile(id: genericOverEarID)
        }
        return nil
    }

    /// Heuristic for "auto" mode: prefer an exact model match, then a generic
    /// correction when the device looks like headphones, otherwise stay neutral.
    public static func resolve(preference: String, deviceName: String?, isHeadphoneDevice: Bool) -> HeadphoneProfile {
        if preference != "auto", let chosen = profile(id: preference) { return chosen }
        if let matched = match(deviceName: deviceName) { return matched }
        if isHeadphoneDevice { return profile(id: genericOverEarID) ?? all[0] }
        return profile(id: neutralID) ?? all[0]
    }
}
