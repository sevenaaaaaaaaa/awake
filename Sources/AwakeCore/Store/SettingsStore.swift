import Foundation

public struct AwakeSettings: Codable, Equatable {
    public var autoEQ: Bool = true
    public var autoEQIntensity: Double = 0.8
    public var headphoneProfileID: String = "auto"
    public var translationEnabled: Bool = true
    public var translationTarget: String = "zh-CN"
    public var autoFetchLyrics: Bool = true
    public var autoFetchArtwork: Bool = true
    public var bitPerfect: Bool = true
    public var gapless: Bool = true
    public var exclusiveMode: Bool = false
    public var scanOnLaunch: Bool = true
    public var showVisualizer: Bool = true
    public var volume: Double = 0.85
    public var headroomDB: Double = -3.0
    public var autoCheckUpdates: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case autoEQ, autoEQIntensity, headphoneProfileID, translationEnabled, translationTarget
        case autoFetchLyrics, autoFetchArtwork, bitPerfect, gapless, exclusiveMode
        case scanOnLaunch, showVisualizer, volume, headroomDB, autoCheckUpdates
    }

    /// Lenient decoding so adding settings never resets an existing profile.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AwakeSettings()
        autoEQ = try c.decodeIfPresent(Bool.self, forKey: .autoEQ) ?? d.autoEQ
        autoEQIntensity = try c.decodeIfPresent(Double.self, forKey: .autoEQIntensity) ?? d.autoEQIntensity
        headphoneProfileID = try c.decodeIfPresent(String.self, forKey: .headphoneProfileID) ?? d.headphoneProfileID
        translationEnabled = try c.decodeIfPresent(Bool.self, forKey: .translationEnabled) ?? d.translationEnabled
        translationTarget = try c.decodeIfPresent(String.self, forKey: .translationTarget) ?? d.translationTarget
        autoFetchLyrics = try c.decodeIfPresent(Bool.self, forKey: .autoFetchLyrics) ?? d.autoFetchLyrics
        autoFetchArtwork = try c.decodeIfPresent(Bool.self, forKey: .autoFetchArtwork) ?? d.autoFetchArtwork
        bitPerfect = try c.decodeIfPresent(Bool.self, forKey: .bitPerfect) ?? d.bitPerfect
        gapless = try c.decodeIfPresent(Bool.self, forKey: .gapless) ?? d.gapless
        exclusiveMode = try c.decodeIfPresent(Bool.self, forKey: .exclusiveMode) ?? d.exclusiveMode
        scanOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .scanOnLaunch) ?? d.scanOnLaunch
        showVisualizer = try c.decodeIfPresent(Bool.self, forKey: .showVisualizer) ?? d.showVisualizer
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume
        headroomDB = try c.decodeIfPresent(Double.self, forKey: .headroomDB) ?? d.headroomDB
        autoCheckUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? d.autoCheckUpdates
    }

    public static func load() -> AwakeSettings {
        JSONFile.read(AwakeSettings.self, at: AwakePaths.settingsFile) ?? AwakeSettings()
    }

    public func save() {
        JSONFile.write(self, to: AwakePaths.settingsFile)
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: AwakeSettings {
        didSet { scheduleSave() }
    }
    private var saveTask: Task<Void, Never>?

    public init(settings: AwakeSettings = .load()) {
        self.settings = settings
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = settings
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { snapshot.save() }
        }
    }
}
