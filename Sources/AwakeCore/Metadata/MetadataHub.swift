import Foundation

/// "Zero configuration" metadata facade: one call enriches a track with artwork, lyrics and
/// a line-aligned translation. Every step degrades silently, so offline playback keeps working
/// with whatever is already cached.
public actor MetadataHub {
    public static let shared = MetadataHub()

    public struct Enrichment {
        public var artworkPath: String?
        public var lyrics: LyricsDocument?
        public var translation: TranslatedLyrics?

        public init(artworkPath: String? = nil,
                    lyrics: LyricsDocument? = nil,
                    translation: TranslatedLyrics? = nil) {
            self.artworkPath = artworkPath
            self.lyrics = lyrics
            self.translation = translation
        }
    }

    public init() {}

    public func enrich(track: Track, targetLanguage: String) async -> Enrichment {
        // Artwork and lyrics are independent: fetch them concurrently.
        async let artworkTask = ArtworkService.shared.artwork(for: track)
        async let lyricsTask = LyricsService.shared.lyrics(for: track)

        let artworkPath = await artworkTask
        let lyrics = await lyricsTask

        var translation: TranslatedLyrics?
        let language = targetLanguage.trimmed
        if let lyrics, !lyrics.lines.isEmpty, !language.isEmpty {
            translation = await TranslationService.shared.translate(document: lyrics, target: language)
        }

        return Enrichment(artworkPath: artworkPath, lyrics: lyrics, translation: translation)
    }
}
