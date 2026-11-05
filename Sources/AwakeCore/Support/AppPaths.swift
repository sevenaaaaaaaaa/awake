import Foundation

public enum AwakePaths {
    public static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["AWAKE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Awake", isDirectory: true)
    }

    public static var libraryFile: URL { root.appendingPathComponent("library.json") }
    public static var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public static var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public static var artworkCache: URL { cache.appendingPathComponent("artwork", isDirectory: true) }
    public static var lyricsCache: URL { cache.appendingPathComponent("lyrics", isDirectory: true) }
    public static var translationCache: URL { cache.appendingPathComponent("translation", isDirectory: true) }
    public static var audioCache: URL { cache.appendingPathComponent("audio", isDirectory: true) }
    public static var analysisCache: URL { cache.appendingPathComponent("analysis", isDirectory: true) }
    public static var transcodeCache: URL { cache.appendingPathComponent("transcoded", isDirectory: true) }
    public static var autoeqFile: URL { root.appendingPathComponent("autoeq.json") }

    @discardableResult
    public static func ensure() -> Bool {
        let dirs = [root, cache, artworkCache, lyricsCache, translationCache, audioCache, analysisCache, transcodeCache]
        for dir in dirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return true
    }

    public static func artworkFile(for trackID: String) -> URL {
        artworkCache.appendingPathComponent(trackID + ".jpg")
    }

    public static func transcodeFile(for trackID: String) -> URL {
        transcodeCache.appendingPathComponent(trackID + ".flac")
    }

    public static func transcodeRecordFile(for trackID: String) -> URL {
        transcodeCache.appendingPathComponent(trackID + ".json")
    }
}
