// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation
import NaturalLanguage

/// Conservative, on-device source-language detection for OCR text.
///
/// Detection always compares against the complete on-device
/// classification candidate set. The user's source-language filter is applied
/// only after classification so a one-language filter cannot force unrelated
/// text into its sole candidate.
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

    /// OCR covers more Latin languages than Apple's bundled language
    /// recognizer. This set includes the PP-OCRv6 languages backed by Apple's
    /// documented `NLLanguage` identifiers, plus the Tagalog/Filipino raw tags
    /// and lexical refinement already exercised by the simulator suite.
    /// Explicit OCR remains available for every code in
    /// `supportedLanguageCodes`.
    static let automaticallyClassifiableLanguageCodes: Set<String> = [
        "zh", "zh-Hant", "en", "ja", "ca", "hr", "cs", "da", "nl",
        "fi", "fr", "de", "hu", "is", "id", "it", "ms", "no", "pl",
        "pt", "ro", "sk", "es", "sv", "tl", "tr", "vi",
    ]

    /// Natural Language does not consistently produce `tl` directly. Keep
    /// both its legacy tag and Apple's `fil` tag constrained, then canonicalize
    /// and refine the Malay-family result with conservative word evidence.
    private static let recognizerLanguages = [
        "zh-Hans", "zh-Hant", "en", "ja", "ca", "hr", "cs", "da",
        "nl", "fi", "fr", "de", "hu", "is", "id", "it", "ms", "no",
        "pl", "pt", "ro", "sk", "es", "sv", "tl", "fil", "tr", "vi",
    ].map(NLLanguage.init(rawValue:))

    private static let simplifiedChineseMarkers = Set(
        "这们汉语龙发边观开书云专习买产优冲决冻净凉凤划创剂剑剧劝办劳势华协卖卫厅压厌县变叶叹吗听响简"
            .unicodeScalars
    )
    private static let traditionalChineseMarkers = Set(
        "這們臺灣瀏覽螢歡體驗檔啟顯應譯"
            .unicodeScalars
    )

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

    /// `detect` is a pure function of its arguments. A page's regions are
    /// filtered once when OCR is cached and again before requests, each time
    /// creating NaturalLanguage recognizers, so recent results are reused.
    private static let detectionCache = LanguageDetectionLRUCache<
        DetectionKey,
        String?
    >(capacity: 512)

    static func detect(
        _ untrimmedText: String,
        sourceHint: String? = nil
    ) -> String? {
        let key = DetectionKey(text: untrimmedText, sourceHint: sourceHint)
        if case let .some(.some(cached)) = detectionCache.value(for: key) { return cached }
        let detected = detectUncached(untrimmedText, sourceHint: sourceHint)
        detectionCache.insert(detected, for: key)
        return detected
    }

    static func detectUncached(
        _ untrimmedText: String,
        sourceHint: String? = nil
    ) -> String? {
        let text = untrimmedText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !text.isEmpty else { return nil }

        let scalars = text.unicodeScalars
        let alphabeticCount = scalars.reduce(into: 0) { count, scalar in
            if scalar.properties.isAlphabetic {
                count += 1
            }
        }
        guard alphabeticCount > 0 else { return nil }

        let hasKana = scalars.contains(where: isKana)
        let hasHangul = scalars.contains(where: isHangul)
        guard !(hasKana && hasHangul) else { return nil }
        if hasKana {
            return "ja"
        }
        if hasHangul { return nil }

        let hasHan = scalars.contains(where: isHan)
        if hasHan {
            let simplifiedCount = scalars.reduce(into: 0) { count, scalar in
                if simplifiedChineseMarkers.contains(scalar) {
                    count += 1
                }
            }
            let traditionalCount = scalars.reduce(into: 0) { count, scalar in
                if traditionalChineseMarkers.contains(scalar) {
                    count += 1
                }
            }
            if simplifiedCount > traditionalCount {
                return "zh"
            }
            if traditionalCount > simplifiedCount {
                return "zh-Hant"
            }

            // The unified PP-OCRv6 recognizer does not return a per-line
            // language tag. A user-selected OCR source is therefore the
            // native browser's conservative document hint, equivalent to the
            // backend hint used by the original Rust LineLanguageDetector.
            // Use it only for Han-only text after strong simplified/traditional
            // markers have had a chance to win.
            let hasOnlyHanLetters = scalars
                .filter { $0.properties.isAlphabetic && !isSharedProlongedSoundMark($0) }
                .allSatisfy(isHan)
            if hasOnlyHanLetters {
                switch canonicalSourceHint(sourceHint) {
                case "ja":
                    return "ja"
                case "zh":
                    return "zh"
                case "zh-Hant":
                    return "zh-Hant"
                default:
                    break
                }
            }
        }

        // Very short shared-Han labels and Latin abbreviations are ambiguous.
        guard alphabeticCount >= minimumAlphabeticCount else { return nil }
        guard let hypothesis = strongestHypothesis(for: text),
              hypothesis.confidence >= minimumConfidence,
              hypothesis.confidenceGap >= minimumConfidenceGap
        else {
            return nil
        }

        if ["id", "ms", "tl"].contains(hypothesis.languageCode) {
            if let refined = refinedMalayFamilyLanguage(in: text) {
                return refined
            }
            // Apple OS versions that directly identify Malay or Tagalog are
            // authoritative. An `id` fallback without distinguishing words is
            // intentionally left unclassified because all three languages can
            // otherwise collapse into Indonesian.
            return hypothesis.languageCode == "id"
                ? nil
                : hypothesis.languageCode
        }
        if ["da", "no", "sv"].contains(hypothesis.languageCode),
           let refined = refinedScandinavianLanguage(in: text) {
            return refined
        }
        return hypothesis.languageCode
    }

    static func allows(
        _ text: String,
        selectedLanguageCodes: [String],
        sourceHint: String? = nil
    ) -> Bool {
        guard !text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return false
        }
        guard !selectedLanguageCodes.isEmpty else { return true }
        guard let detected = detect(text, sourceHint: sourceHint) else {
            return false
        }
        return selectedLanguageCodes.contains(detected)
    }

    /// Applies the browser's OCR source contract before temporal tracking and
    /// overlay publication. A fixed source is a one-language allowlist. Auto
    /// mode uses the optional multi-language translation-source filter; an
    /// empty auto filter preserves the translate-every-line mode.
    static func allowsOCRText(
        _ text: String,
        configuredSourceLanguage: String,
        automaticLanguageFilter: [String]
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if configuredSourceLanguage != "auto" {
            // Some unified-v6 OCR languages have no Apple NaturalLanguage
            // classifier. Keep those explicit modes usable instead of
            // deleting every recognized line with an impossible classifier.
            guard automaticallyClassifiableLanguageCodes.contains(
                configuredSourceLanguage
            ) else {
                return true
            }
            return allows(
                trimmed,
                selectedLanguageCodes: [configuredSourceLanguage],
                sourceHint: configuredSourceLanguage
            )
        }
        return allows(
            trimmed,
            selectedLanguageCodes: automaticLanguageFilter
        )
    }

    private static func strongestHypothesis(
        for text: String
    ) -> (
        languageCode: String,
        confidence: Double,
        confidenceGap: Double
    )? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = recognizerLanguages
        recognizer.processString(text)

        var confidenceByLanguage: [String: Double] = [:]
        for (language, confidence) in recognizer.languageHypotheses(
            withMaximum: recognizerLanguages.count
        ) {
            guard let canonical = canonicalLanguageCode(
                for: language.rawValue
            ) else {
                continue
            }
            confidenceByLanguage[canonical] = max(
                confidenceByLanguage[canonical, default: 0],
                confidence
            )
        }

        let ranked = confidenceByLanguage.sorted {
            if $0.value == $1.value {
                return $0.key < $1.key
            }
            return $0.value > $1.value
        }
        guard let strongest = ranked.first else { return nil }
        let runnerUpConfidence = ranked.dropFirst().first?.value ?? 0
        return (
            strongest.key,
            strongest.value,
            strongest.value - runnerUpConfidence
        )
    }

    private static func canonicalLanguageCode(
        for recognizerCode: String
    ) -> String? {
        switch recognizerCode
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        {
        case "zh", "zh-cn", "zh-sg", "zh-hans":
            return "zh"
        case "zh-hk", "zh-mo", "zh-tw", "zh-hant":
            return "zh-Hant"
        case "fil", "tl":
            return "tl"
        case "sr", "sr-latn":
            return "sr-Latn"
        case let code where supportedLanguageCodes.contains(code):
            return code
        default:
            return nil
        }
    }

    private static func canonicalSourceHint(_ hint: String?) -> String? {
        switch hint?
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        {
        case "ja", "ja-jp":
            return "ja"
        case "zh", "zh-cn", "zh-sg", "zh-hans":
            return "zh"
        case "zh-hant", "zh-hk", "zh-mo", "zh-tw":
            return "zh-Hant"
        default:
            return nil
        }
    }

    private static func refinedMalayFamilyLanguage(
        in text: String
    ) -> String? {
        let tokens = wordTokens(in: text)
        let scores = [
            ("id", tokens.intersection(indonesianMarkers).count),
            ("ms", tokens.intersection(malayMarkers).count),
            ("tl", tokens.intersection(tagalogMarkers).count),
        ].sorted {
            if $0.1 == $1.1 {
                return $0.0 < $1.0
            }
            return $0.1 > $1.1
        }
        guard let strongest = scores.first,
              strongest.1 >= 2,
              strongest.1 > (scores.dropFirst().first?.1 ?? 0)
        else {
            return nil
        }
        return strongest.0
    }

    private static func refinedScandinavianLanguage(
        in text: String
    ) -> String? {
        let tokens = wordTokens(in: text)
        let scores = [
            ("da", tokens.intersection(danishMarkers).count),
            ("no", tokens.intersection(norwegianMarkers).count),
            ("sv", tokens.intersection(swedishMarkers).count),
        ].sorted {
            if $0.1 == $1.1 {
                return $0.0 < $1.0
            }
            return $0.1 > $1.1
        }
        guard let strongest = scores.first,
              strongest.1 >= 2,
              strongest.1 > (scores.dropFirst().first?.1 ?? 0)
        else {
            return nil
        }
        return strongest.0
    }

    private static func wordTokens(in text: String) -> Set<String> {
        let normalized = text.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        var tokens: Set<String> = []
        tokenizer.enumerateTokens(
            in: normalized.startIndex..<normalized.endIndex
        ) { range, _ in
            let token = String(normalized[range])
            if token.unicodeScalars.contains(
                where: \.properties.isAlphabetic
            ) {
                tokens.insert(token)
            }
            return true
        }
        return tokens
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        // Common punctuation and shared prolonged-sound marks are not
        // sufficient evidence of Japanese without an actual kana letter.
        guard scalar.properties.isAlphabetic,
              !isSharedProlongedSoundMark(scalar) else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
            return true
        default:
            return false
        }
    }

    private static func isSharedProlongedSoundMark(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x30FC || scalar.value == 0xFF70
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
             0xAC00...0xD7AF, 0xD7B0...0xD7FF:
            return true
        default:
            return false
        }
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

/// A small lock-protected least-recently-used memo for deterministic language
/// classification results.
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
