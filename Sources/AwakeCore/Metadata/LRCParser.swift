import Foundation

// MARK: - Lyrics models

/// A single lyric line. `time` is nil for unsynchronized (plain) lyrics.
public struct LyricsLine: Codable, Hashable {
    public var time: Double?
    public var text: String

    public init(time: Double?, text: String) {
        self.time = time
        self.text = text
    }
}

/// A parsed lyrics document. `plain` is always derived from `lines`.
public struct LyricsDocument: Codable, Hashable {
    public var lines: [LyricsLine]
    public var isSynced: Bool
    public var source: String
    /// Plain text projection of `lines`; regenerated on construction and decoding.
    public var plain: String

    public init(lines: [LyricsLine], isSynced: Bool, source: String) {
        self.lines = lines
        self.isSynced = isSynced
        self.source = source
        self.plain = Self.plainText(from: lines)
    }

    private enum CodingKeys: String, CodingKey {
        case lines, isSynced, source, plain
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lines = try container.decodeIfPresent([LyricsLine].self, forKey: .lines) ?? []
        self.lines = lines
        self.isSynced = try container.decodeIfPresent(Bool.self, forKey: .isSynced)
            ?? lines.contains { $0.time != nil }
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        if let stored = try container.decodeIfPresent(String.self, forKey: .plain), !stored.isEmpty {
            self.plain = stored
        } else {
            self.plain = Self.plainText(from: lines)
        }
    }

    static func plainText(from lines: [LyricsLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }
}

/// A line-by-line translation of a lyrics document.
public struct TranslatedLyrics: Codable, Hashable {
    public var language: String
    public var lines: [String]

    public init(language: String, lines: [String]) {
        self.language = language
        self.lines = lines
    }
}

// MARK: - LRC parser

public enum LRCParser {
    /// Matches `[mm:ss]`, `[mm:ss.xx]` and `[mm:ss.xxx]` timestamps (also `mm:ss:xx`).
    private static let timestampRegex = try! NSRegularExpression(
        pattern: "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]",
        options: []
    )

    /// Matches LRC metadata tags such as `[ar:Artist]` or `[offset:+200]`.
    private static let metadataRegex = try! NSRegularExpression(
        pattern: "^\\[(ti|ar|al|au|by|offset|re|ve|length|tool|encoding|language|kana|#)\\s*:[^\\]]*\\]$",
        options: [.caseInsensitive]
    )

    /// Parses an LRC (or plain text) lyrics payload into displayable lines.
    ///
    /// - Supports several timestamps on one physical line.
    /// - Drops metadata tags and empty lyric lines.
    /// - Returns lines in chronological order whenever every line is timed.
    public static func parse(_ text: String) -> [LyricsLine] {
        let normalized = normalize(text)
        var lines: [LyricsLine] = []

        for raw in normalized.components(separatedBy: "\n") {
            let line = raw.trimmed
            guard !line.isEmpty else { continue }

            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            let timestamps = timestampRegex.matches(in: line, range: fullRange)

            if timestamps.isEmpty {
                if metadataRegex.firstMatch(in: line, range: fullRange) != nil { continue }
                lines.append(LyricsLine(time: nil, text: line))
                continue
            }

            // Build the lyric text by removing every timestamp occurrence.
            var lyric = ""
            var cursor = 0
            for match in timestamps {
                if match.range.location > cursor {
                    lyric += nsLine.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                }
                cursor = match.range.location + match.range.length
            }
            if cursor < nsLine.length {
                lyric += nsLine.substring(from: cursor)
            }
            lyric = lyric.trimmed
            guard !lyric.isEmpty else { continue }

            for match in timestamps {
                guard let time = timeValue(match, in: nsLine) else { continue }
                lines.append(LyricsLine(time: time, text: lyric))
            }
        }

        // Sort chronologically only when the whole payload is timed (stable on ties).
        if !lines.isEmpty, lines.allSatisfy({ $0.time != nil }) {
            let indexed = lines.enumerated()
            lines = indexed.sorted { lhs, rhs in
                let l = lhs.element.time ?? 0
                let r = rhs.element.time ?? 0
                if l == r { return lhs.offset < rhs.offset }
                return l < r
            }.map(\.element)
        }
        return lines
    }

    /// True when the payload contains at least one timed lyric line.
    public static func isSynced(_ text: String) -> Bool {
        parse(text).contains { $0.time != nil }
    }

    // MARK: Private

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func timeValue(_ match: NSTextCheckingResult, in nsLine: NSString) -> Double? {
        guard match.numberOfRanges >= 3,
              let minutes = Int(nsLine.substring(with: match.range(at: 1))),
              let seconds = Int(nsLine.substring(with: match.range(at: 2))) else {
            return nil
        }
        var fraction = 0.0
        if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound {
            let raw = nsLine.substring(with: match.range(at: 3))
            if let value = Double(raw) {
                fraction = value / pow(10.0, Double(raw.count))
            }
        }
        return Double(minutes * 60 + seconds) + fraction
    }
}
