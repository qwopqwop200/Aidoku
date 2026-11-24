import Foundation
import NaturalLanguage

/// Conservative on-device source-language detection for OCR text. The user's
/// filter applies after classification, so it cannot force text into its sole candidate.
enum AutomaticSourceLanguageDetector {
    static let supportedLanguageCodes: Set<String> = [
        "zh", "zh-Hant", "en", "ja",
        "fr", "de", "it", "es", "pt", "nl", "pl", "ro", "cs", "sv",
        "no", "da", "fi", "hu", "tr", "vi", "id", "ms", "az", "af",
        "bs", "hr", "cy", "et", "ga", "is", "ku", "lt", "lv", "mt",
        "mi", "oc", "sk", "sl", "sq", "sw", "tl", "uz", "la",
        "sr-Latn", "ca", "eu", "gl", "lb", "rm", "qu",
    ]

    private static let minimumAlphabeticCount = 3
    private static let minimumConfidence = 0.45
    private static let minimumConfidenceGap = 0.15

    /// The PP-OCRv6 languages Apple's `NLLanguage` recognizer can classify (OCR covers more).
    static let automaticallyClassifiableLanguageCodes: Set<String> = [
        "zh", "zh-Hant", "en", "ja", "ca", "hr", "cs", "da", "nl",
        "fi", "fr", "de", "hu", "is", "id", "it", "ms", "no", "pl",
        "pt", "ro", "sk", "es", "sv", "tl", "tr", "vi",
    ]

    /// Natural Language does not consistently produce `tl`: constrain both `tl` and `fil`,
    /// then canonicalize and refine the Malay-family result with word evidence.
    private static let recognizerLanguages = [
        "zh-Hans", "zh-Hant", "en", "ja", "ca", "hr", "cs", "da",
        "nl", "fi", "fr", "de", "hu", "is", "id", "it", "ms", "no",
        "pl", "pt", "ro", "sk", "es", "sv", "tl", "fil", "tr", "vi",
    ].map(NLLanguage.init(rawValue:))

    private static let simplifiedChineseMarkers = Set(
        "这们汉语龙发边观开书云专习买产优冲决冻净凉凤划创剂剑剧劝办劳势华协卖卫厅压厌县变叶叹吗听响简".unicodeScalars
    )
    private static let traditionalChineseMarkers = Set("這們臺灣瀏覽螢歡體驗檔啟顯應譯".unicodeScalars)

    private static let indonesianMarkers: Set<String> = [
        "akhir", "bahwa", "kantor", "karena", "lanjutkan", "pengaturan",
        "pemerintah", "peramban", "pekan", "silakan", "terjemahkan",
        "tombol", "warga",
    ]
    private static let malayMarkers: Set<String> = [
        "ayat", "bahawa", "butang", "hujung", "ialah", "kerajaan",
        "kerana", "laman", "meneruskan", "pelayar", "pengecaman",
        "pejabat", "rakyat", "rancangan", "sila", "tetapan",
    ]
    private static let tagalogMarkers: Set<String> = [
        "aklat", "aming", "ang", "ay", "bagong", "bansa", "buong",
        "iyong", "kasama", "katapusan", "magpatuloy", "mahilig",
        "maligayang", "mamamayan", "manood", "mga", "naglunsad",
        "pahina", "palabas", "pamahalaan", "pamilya", "piliin",
        "pindutan", "pilipinas", "programa", "tuwing", "upang", "wika",
    ]
    private static let danishMarkers: Set<String> = [
        "browseren", "dansk", "detaljeret", "genkende", "pålidelig",
        "sprog", "sproggenkendelse", "sætning", "undersøge",
    ]
    private static let norwegianMarkers: Set<String> = [
        "gjenkjenne", "gjenkjenner", "måte", "nettleser", "nettleseren",
        "norsk", "norske", "pålitelig", "språkgjenkjenning", "undersøke",
    ]
    private static let swedishMarkers: Set<String> = [
        "detaljerad", "igenkänning", "kontrollera", "mening", "pålitlig",
        "språk", "svensk", "svenska", "webbläsare", "webbläsaren",
    ]

    private struct DetectionKey: Hashable {
        let text: String
        let sourceHint: String?
    }

    /// `detect` is pure and runs repeatedly for the same page regions.
    private static let detectionCache = LanguageDetectionLRUCache<DetectionKey, String?>(capacity: 512)

    static func detect(_ untrimmedText: String, sourceHint: String? = nil) -> String? {
        let key = DetectionKey(text: untrimmedText, sourceHint: sourceHint)
        if case let .some(.some(cached)) = detectionCache.value(for: key) { return cached }
        let detected = detectUncached(untrimmedText, sourceHint: sourceHint)
        detectionCache.insert(detected, for: key)
        return detected
    }

    private static func detectUncached(_ untrimmedText: String, sourceHint: String?) -> String? {
        let text = untrimmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let scalars = text.unicodeScalars
        let alphabeticCount = scalars.filter(\.properties.isAlphabetic).count
        guard alphabeticCount > 0 else { return nil }

        let hasKana = scalars.contains(where: isKana)
        let hasHangul = scalars.contains(where: isHangul)
        guard !(hasKana && hasHangul) else { return nil }
        if hasKana { return "ja" }
        if hasHangul { return nil }

        if scalars.contains(where: isHan) {
            let simplifiedCount = scalars.filter { simplifiedChineseMarkers.contains($0) }.count
            let traditionalCount = scalars.filter { traditionalChineseMarkers.contains($0) }.count
            if simplifiedCount > traditionalCount { return "zh" }
            if traditionalCount > simplifiedCount { return "zh-Hant" }

            // OCR has no per-line language tag, so a fixed source is the hint: only for
            // Han-only text, after the simplified/traditional markers had a chance to win.
            let hasOnlyHanLetters = scalars
                .filter { $0.properties.isAlphabetic && !isSharedProlongedSoundMark($0) }
                .allSatisfy(isHan)
            // canonicalSourceHint yields only ja, zh or zh-Hant.
            if hasOnlyHanLetters, let hint = canonicalSourceHint(sourceHint) { return hint }
        }

        // Very short shared-Han labels and Latin abbreviations are ambiguous.
        guard alphabeticCount >= minimumAlphabeticCount else { return nil }
        guard let hypothesis = strongestHypothesis(for: text),
              hypothesis.confidence >= minimumConfidence,
              hypothesis.confidenceGap >= minimumConfidenceGap else { return nil }

        if ["id", "ms", "tl"].contains(hypothesis.languageCode) {
            if let refined = refinedLanguage(
                in: text, markers: [("id", indonesianMarkers), ("ms", malayMarkers), ("tl", tagalogMarkers)]
            ) {
                return refined
            }
            // A direct Malay or Tagalog result is authoritative; a bare `id` stays
            // unclassified because all three languages can collapse into Indonesian.
            return hypothesis.languageCode == "id" ? nil : hypothesis.languageCode
        }
        if ["da", "no", "sv"].contains(hypothesis.languageCode),
           let refined = refinedLanguage(
               in: text, markers: [("da", danishMarkers), ("no", norwegianMarkers), ("sv", swedishMarkers)]
           ) {
            return refined
        }
        return hypothesis.languageCode
    }

    static func allows(_ text: String, selectedLanguageCodes: [String], sourceHint: String? = nil) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !selectedLanguageCodes.isEmpty else { return true }
        guard let detected = detect(text, sourceHint: sourceHint) else { return false }
        return selectedLanguageCodes.contains(detected)
    }

    /// A fixed source is a one-language allowlist; auto mode uses the optional filter
    /// (empty translates every line).
    static func allowsOCRText(
        _ text: String,
        configuredSourceLanguage: String,
        automaticLanguageFilter: [String]
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if configuredSourceLanguage != "auto" {
            // Without an Apple classifier for the language, keep every line.
            guard automaticallyClassifiableLanguageCodes.contains(configuredSourceLanguage) else { return true }
            return allows(trimmed, selectedLanguageCodes: [configuredSourceLanguage], sourceHint: configuredSourceLanguage)
        }
        return allows(trimmed, selectedLanguageCodes: automaticLanguageFilter)
    }

    private static func strongestHypothesis(
        for text: String
    ) -> (languageCode: String, confidence: Double, confidenceGap: Double)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = recognizerLanguages
        recognizer.processString(text)

        var confidenceByLanguage: [String: Double] = [:]
        for (language, confidence) in recognizer.languageHypotheses(withMaximum: recognizerLanguages.count) {
            guard let canonical = canonicalLanguageCode(for: language.rawValue) else { continue }
            confidenceByLanguage[canonical] = max(confidenceByLanguage[canonical, default: 0], confidence)
        }

        let ranked = confidenceByLanguage.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let strongest = ranked.first else { return nil }
        let runnerUpConfidence = ranked.dropFirst().first?.value ?? 0
        return (strongest.key, strongest.value, strongest.value - runnerUpConfidence)
    }

    private static func canonicalLanguageCode(for recognizerCode: String) -> String? {
        switch recognizerCode.replacingOccurrences(of: "_", with: "-").lowercased() {
        case "zh", "zh-cn", "zh-sg", "zh-hans": "zh"
        case "zh-hk", "zh-mo", "zh-tw", "zh-hant": "zh-Hant"
        case "fil", "tl": "tl"
        case "sr", "sr-latn": "sr-Latn"
        case let code where supportedLanguageCodes.contains(code): code
        default: nil
        }
    }

    private static func canonicalSourceHint(_ hint: String?) -> String? {
        switch hint?.replacingOccurrences(of: "_", with: "-").lowercased() {
        case "ja", "ja-jp": "ja"
        case "zh", "zh-cn", "zh-sg", "zh-hans": "zh"
        case "zh-hant", "zh-hk", "zh-mo", "zh-tw": "zh-Hant"
        default: nil
        }
    }

    /// A refinement needs at least two marker words and a strict lead.
    private static func refinedLanguage(in text: String, markers: [(String, Set<String>)]) -> String? {
        let tokens = wordTokens(in: text)
        let scores: [(String, Int)] = markers.map { ($0.0, tokens.intersection($0.1).count) }
            .sorted { (a: (String, Int), b: (String, Int)) -> Bool in a.1 == b.1 ? a.0 < b.0 : a.1 > b.1 }
        guard let strongest = scores.first, strongest.1 >= 2,
              strongest.1 > (scores.dropFirst().first?.1 ?? 0) else { return nil }
        return strongest.0
    }

    private static func wordTokens(in text: String) -> Set<String> {
        let normalized = text.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        var tokens: Set<String> = []
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            let token = String(normalized[range])
            if token.unicodeScalars.contains(where: \.properties.isAlphabetic) {
                tokens.insert(token)
            }
            return true
        }
        return tokens
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        // Common punctuation and shared prolonged-sound marks are not
        // sufficient evidence of Japanese without an actual kana letter.
        guard scalar.properties.isAlphabetic, !isSharedProlongedSoundMark(scalar) else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: return true
        default: return false
        }
    }

    private static func isSharedProlongedSoundMark(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x30FC || scalar.value == 0xFF70
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF: true
        default: false
        }
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }
}

/// A small lock-protected LRU memo for deterministic classification results.
final class LanguageDetectionLRUCache<Key: Hashable, Value>: @unchecked Sendable {
    private struct Entry {
        let value: Value
        var recency: UInt64
    }

    private let lock = NSLock()
    private let capacity: Int
    private var clock: UInt64 = 0
    private var entries: [Key: Entry] = [:]

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Returns `.some(value)` for a cached entry (the value itself may be nil).
    func value(for key: Key) -> Value?? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            clock &+= 1
            entry.recency = clock
            entries[key] = entry
            return .some(entry.value)
        }
    }

    func insert(_ value: Value, for key: Key) {
        lock.withLock {
            clock &+= 1
            entries[key] = Entry(value: value, recency: clock)
            guard entries.count > capacity,
                  let oldest = entries.min(by: { $0.value.recency < $1.value.recency })?.key
            else { return }
            entries.removeValue(forKey: oldest)
        }
    }
}
