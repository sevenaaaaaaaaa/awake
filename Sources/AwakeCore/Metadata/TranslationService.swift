import Foundation

/// Line-by-line lyrics translation backed by the public Google Translate web endpoint.
///
/// Results are cached in `AwakePaths.translationCache` keyed by the source lines hash and
/// target language, so a translated document is available offline once fetched.
public actor TranslationService {
    public static let shared = TranslationService()

    /// Keep the encoded query comfortably below the ~1800 character URL ceiling.
    private static let batchBudget = 1500
    private static let endpoint = "https://translate.googleapis.com/translate_a/single"

    public init() {}

    /// Translates lines one-for-one. Returns an empty array when nothing could be translated.
    /// Partial failures keep the original text on the affected line so alignment is preserved.
    public func translate(lines: [String], target: String) async -> [String] {
        guard !lines.isEmpty else { return [] }
        let language = Self.languageCode(target)
        guard !language.isEmpty else { return [] }

        let cache = Self.cacheURL(lines: lines, target: language)
        if let cached = JSONFile.read(TranslatedLyrics.self, at: cache),
           cached.lines.count == lines.count,
           !zip(cached.lines, lines).contains(where: { Self.needsRetranslation($0, source: $1) }) {
            return cached.lines
        }
        if lines.allSatisfy({ $0.trimmed.isEmpty }) {
            return lines.map { _ in "" }
        }

        var output = [String](repeating: "", count: lines.count)
        var translatedAny = false
        var start = 0

        while start < lines.count {
            let end = Self.batchEnd(lines, from: start)
            let slice = Array(lines[start..<end])
            if let batch = await translateBatch(slice, target: language) {
                translatedAny = true
                for (offset, value) in batch.enumerated() where start + offset < output.count {
                    output[start + offset] = value
                }
            } else {
                for offset in 0..<slice.count where start + offset < output.count {
                    output[start + offset] = slice[offset]
                }
            }
            start = end
        }

        guard translatedAny else { return [] }

        // The web endpoint occasionally echoes a line unchanged (rate limiting or newline
        // coalescing). Retry those once in isolation; if it still echoes, blank the line so the
        // UI does not show English text masquerading as a translation.
        for index in output.indices where Self.needsRetranslation(output[index], source: lines[index]) {
            try? await Task.sleep(nanoseconds: 220_000_000)
            if let single = await request([lines[index]], target: language),
               let value = single.first,
               !Self.needsRetranslation(value, source: lines[index]) {
                output[index] = value
            } else {
                output[index] = ""
            }
        }

        JSONFile.write(TranslatedLyrics(language: language, lines: output), to: cache)
        return output
    }

    /// Translates a lyrics document, returning nil when no usable translation was produced.
    public func translate(document: LyricsDocument, target: String) async -> TranslatedLyrics? {
        guard !document.lines.isEmpty else { return nil }
        let inputs = document.lines.map { $0.text }
        let output = await translate(lines: inputs, target: target)
        guard output.count == inputs.count, !output.isEmpty else { return nil }
        guard output.contains(where: { !$0.trimmed.isEmpty }) else { return nil }
        return TranslatedLyrics(language: Self.languageCode(target), lines: output)
    }

    // MARK: Cache

    static func cacheURL(lines: [String], target: String) -> URL {
        let hash = lines.joined(separator: "\n").sha256Short
        let language = languageCode(target)
            .lowercased()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return AwakePaths.translationCache.appendingPathComponent("\(hash)-\(language).json")
    }

    static func needsRetranslation(_ translated: String, source: String) -> Bool {
        let sourceText = source.trimmed
        guard !sourceText.isEmpty, translated.trimmed.lowercased() == sourceText.lowercased() else { return false }
        return sourceText.range(of: "[A-Za-z]", options: .regularExpression) != nil
    }

    static func languageCode(_ target: String) -> String {
        target.trimmed.replacingOccurrences(of: " ", with: "-")
    }

    // MARK: Batching

    private static func batchEnd(_ lines: [String], from start: Int) -> Int {
        var end = start
        var used = 0
        while end < lines.count {
            let cost = MetadataHTTP.encodedLength(lines[end]) + 3 // "%0A" separator
            if end > start, used + cost > batchBudget { break }
            used += cost
            end += 1
        }
        return max(end, start + 1)
    }

    /// Translates a chunk, preserving empty lines. Returns nil when every request failed.
    private func translateBatch(_ lines: [String], target: String) async -> [String]? {
        let slots = lines.indices.filter { !lines[$0].trimmed.isEmpty }
        guard !slots.isEmpty else { return lines.map { _ in "" } }

        let payload = slots.map { lines[$0] }
        if let translated = await request(payload, target: target), translated.count == payload.count {
            var result = [String](repeating: "", count: lines.count)
            for (slot, value) in zip(slots, translated) {
                result[slot] = value
            }
            return result
        }

        // Newline-preservation failed (or the endpoint errored): fall back per line so the
        // result always stays aligned with the input.
        var result = [String](repeating: "", count: lines.count)
        var succeeded = 0
        for slot in slots {
            if let single = await request([lines[slot]], target: target),
               let value = single.first,
               !value.trimmed.isEmpty {
                result[slot] = value
                succeeded += 1
            } else {
                result[slot] = lines[slot]
            }
        }
        return succeeded > 0 ? result : nil
    }

    /// Sends one request and splits the translated payload back into lines.
    private func request(_ lines: [String], target: String) async -> [String]? {
        let text = lines.joined(separator: "\n")
        guard !text.trimmed.isEmpty else { return nil }

        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = components?.url else { return nil }
        guard let data = await MetadataHTTP.data(from: url, headers: ["Accept": "*/*"]) else { return nil }
        guard let json = MetadataHTTP.json(data),
              let root = json as? [Any],
              let segments = root.first as? [Any] else {
            return nil
        }

        var translated = ""
        for segment in segments {
            if let parts = segment as? [Any], let piece = parts.first as? String {
                translated += piece
            }
        }
        translated = translated.replacingOccurrences(of: "\u{FEFF}", with: "")
        guard !translated.trimmed.isEmpty else { return nil }

        let newlineNormalized = translated.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = newlineNormalized.components(separatedBy: "\n")
        guard parts.count == lines.count else { return nil }
        return parts
    }
}
