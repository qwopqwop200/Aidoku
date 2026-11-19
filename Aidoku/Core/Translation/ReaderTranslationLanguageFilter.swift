import Foundation
import NaturalLanguage

/// Apply the source-language policy after raw OCR caching, before requests or overlays.
enum ReaderTranslationLanguageFilter {
    /// A provider can append a stray OCR fragment after a complete Korean
    /// sentence. Drop only a separate, multi-character Han/kana tail after
    /// sentence punctuation; names embedded in the sentence remain intact.
    static func removingForeignScriptTail(_ translation: String, target: String) -> String {
        guard canonical(target) == "ko" else { return translation }
        // A source-script vowel-length mark inside an otherwise Korean word is
        // not an independent symbol. Preserve its rhythm without a hybrid word.
        let originalScalars = Array(translation.unicodeScalars)
        func hangul(_ scalar: Unicode.Scalar) -> Bool {
            (0xAC00...0xD7A3).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value) ||
                (0x3130...0x318F).contains(scalar.value)
        }
        let normalized = originalScalars.indices.map { index -> String in
            let scalar = originalScalars[index]
            guard (scalar.value == 0x30FC || scalar.value == 0xFF70), index > 0,
                  hangul(originalScalars[index - 1]),
                  (index + 1 == originalScalars.count ||
                    !(0x3040...0x30FF).contains(originalScalars[index + 1].value)) else { return String(scalar) }
            return "~"
        }.joined()
        let translation = normalized
        let scalars = Array(translation.unicodeScalars)
        func korean(_ scalar: Unicode.Scalar) -> Bool {
            (0xAC00...0xD7A3).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value) ||
                (0x3130...0x318F).contains(scalar.value)
        }
        func foreign(_ scalar: Unicode.Scalar) -> Bool {
            (0x3040...0x30FF).contains(scalar.value) || (0xFF66...0xFF9D).contains(scalar.value) ||
                (0x3400...0x9FFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
        }
        let end = scalars.lastIndex { !CharacterSet.whitespacesAndNewlines.contains($0) }.map { $0 + 1 } ?? 0
        guard end > 0 else { return translation }
        var start = end
        while start > 0 && foreign(scalars[start - 1]) { start -= 1 }
        guard end - start >= 2, start > 0,
              CharacterSet.whitespacesAndNewlines.contains(scalars[start - 1]) else { return translation }
        let prefix = String(String.UnicodeScalarView(scalars[..<start]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.unicodeScalars.filter(korean).count >= 4,
              let last = prefix.last, "!?！？…。".contains(last) else { return translation }
        return prefix
    }

    /// A Japanese sentence re-punctuated by the provider is not a Korean translation.
    /// Exact copies remain valid for explicit SFX/background preservation; short names
    /// and quoted terms remain outside this narrow rejection.
    static func isUntranslatedJapaneseReply(source: String, translation: String, target: String,
                                           preservesExactSource: Bool = true) -> Bool {
        guard canonical(target) == "ko",
              (!preservesExactSource || source.trimmingCharacters(in: .whitespacesAndNewlines) !=
                translation.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        if containsCopiedJapaneseClause(source: source, translation: translation) { return true }
        func kana(_ scalar: Unicode.Scalar) -> Bool {
            (0x3040...0x30FF).contains(scalar.value) || (0xFF66...0xFF9D).contains(scalar.value)
        }
        let letters = translation.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard letters.count >= 20, letters.filter(kana).count >= 2,
              source.unicodeScalars.filter(kana).count >= 2 else { return false }
        return !letters.contains {
            (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value) ||
                (0x3130...0x318F).contains($0.value)
        }
    }

    /// A Korean fragment must not certify an otherwise copied Japanese clause.
    /// Require a long source-matching run with substantial hiragana grammar; names,
    /// short interjections and explicitly quoted terms are not enough evidence.
    private static func containsCopiedJapaneseClause(source: String, translation: String) -> Bool {
        func japanese(_ scalar: Unicode.Scalar) -> Bool {
            (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value) ||
                (0xFF66...0xFF9D).contains(scalar.value)
        }
        func normalized(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter(japanese)))
        }
        let sourceLetters = normalized(source)
        func copiedClause(_ run: String) -> Bool {
            let text = run.trimmingCharacters(in: .whitespacesAndNewlines)
            for (opening, closing) in [("「", "」"), ("『", "』"), ("\"", "\""), ("“", "”")] {
                if text.hasPrefix(opening), text.hasSuffix(closing) { return false }
            }
            let letters = normalized(text)
            let hiragana = letters.unicodeScalars.filter { (0x3041...0x3096).contains($0.value) }.count
            return letters.count >= 10 && hiragana >= 5 && sourceLetters.contains(letters)
        }
        var run = ""
        for scalar in translation.unicodeScalars {
            if japanese(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                CharacterSet.punctuationCharacters.contains(scalar) {
                run.unicodeScalars.append(scalar)
            } else {
                if copiedClause(run) { return true }
                run = ""
            }
        }
        return copiedClause(run)
    }

    /// Image-admitted dialogue copied in Japanese is not a Korean translation,
    /// even for a one-kana reply. Keep ambiguous roles and names without kana
    /// outside this bounded recovery.
    static func untranslatedAdmittedDialogueIDs(
        request: RemoteTranslationRequest, result: RemoteTranslationBatchResult
    ) -> Set<String> {
        guard canonical(request.targetLanguage) == "ko", request.imageJPEG != nil else { return [] }
        func kana(_ scalar: Unicode.Scalar) -> Bool { (0x3041...0x30FA).contains(scalar.value) }
        func japanese(_ scalar: Unicode.Scalar) -> Bool {
            kana(scalar) || (0x3400...0x9FFF).contains(scalar.value)
        }
        func normalized(_ text: String) -> String? {
            let letters = text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { $0.properties.isAlphabetic }
            guard letters.contains(where: kana), letters.allSatisfy(japanese) else { return nil }
            // OCR often misses the small form of a kana. This is orthographic
            // equivalence only; do not fuzzy-match different sentence content.
            let small = Array("ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ")
            let full = Array("あいうえおつやゆよわアイウエオツヤユヨワ")
            let mapping = Dictionary(uniqueKeysWithValues: zip(small, full))
            return String(String(String.UnicodeScalarView(letters)).map { mapping[$0] ?? $0 })
        }
        let sources = Dictionary(request.segments.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        return Set(result.translations.compactMap { output in
            guard output.isSFX == false, output.textRole == .dialogue,
                  let source = sources[output.id],
                  let original = normalized(source),
                  normalized(TranslationHTTPCodec.decodingLeakedEscapes(in: output.text, source: source)) == original
            else { return nil }
            return output.id
        })
    }

    /// Shared completed-provider check for the reader service and native host CLI.
    /// Classifier-preserved effects and exact source copies keep their existing policy.
    static func isWrongLanguage(_ segment: RemoteTranslatedSegment, source: String, target: String,
                                preservesExactSource: Bool = true) -> Bool {
        guard segment.isSFX != true else { return false }
        let displayedText = TranslationHTTPCodec.decodingLeakedEscapes(in: segment.text, source: source)
        return isUntranslatedJapaneseReply(source: source, translation: displayedText, target: target, preservesExactSource: preservesExactSource)
    }

    static func containsWrongLanguage(_ translations: [RemoteTranslatedSegment], request: RemoteTranslationRequest) -> Bool {
        let sources = Dictionary(request.segments.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        return translations.contains { segment in
            guard let source = sources[segment.id] else { return false }
            return isWrongLanguage(segment, source: source, target: request.targetLanguage)
        }
    }

    /// Geometrically established balloon prose cannot be silently kept as Japanese in a Korean page.
    /// Short names, effects, signs and unverified background components remain preservation candidates.
    static func requiresBalloonTranslation(_ region: ReaderTranslationRegion, translation: String, target: String) -> Bool {
        let recoveredQuote = region.sourceOrientation == .vertical && region.unitMemberRects.count >= 2 &&
            ReaderTranslationQuotedStack.isBoundedQuote(region.source)
        guard canonical(target) == "ko", region.balloonInterior?.contourVerified == true || recoveredQuote,
              region.source.trimmingCharacters(in: .whitespacesAndNewlines) == translation.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        let letters = region.source.unicodeScalars.filter { $0.properties.isAlphabetic }
        let kana = letters.filter { (0x3040...0x30FF).contains($0.value) }
        return letters.count >= (recoveredQuote ? 2 : 10) && kana.count >= (recoveredQuote ? 1 : 3) &&
            !letters.contains { (0xAC00...0xD7A3).contains($0.value) }
    }

    static func containsUntranslatedJapaneseReply(_ regions: [ReaderTranslationRegion], target: String) -> Bool {
        regions.contains { region in
            region.translation.map { isUntranslatedJapaneseReply(source: region.source, translation: $0, target: target) || requiresBalloonTranslation(region, translation: $0, target: target) } ?? false
        }
    }

    /// Only skip confident, unmixed text. Short Latin tags and romanized titles remain eligible.
    static func isAlreadyTargetLanguage(_ text: String, target: String) -> Bool {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return false }
        let language = canonical(target)
        let hangul: (Unicode.Scalar) -> Bool = {
            (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value) ||
                (0x3130...0x318F).contains($0.value)
        }
        if language == "ko" { return letters.allSatisfy(hangul) }
        if letters.contains(where: hangul) { return false }
        let han: (Unicode.Scalar) -> Bool = {
            (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
        }
        let kana: (Unicode.Scalar) -> Bool = {
            (0x3040...0x30FF).contains($0.value) || (0xFF66...0xFF9D).contains($0.value)
        }
        if language == "ja" {
            return letters.contains(where: kana) && letters.allSatisfy { kana($0) || han($0) }
        }
        if language == "zh" || language == "zh-Hant" {
            return letters.allSatisfy(han) && AutomaticSourceLanguageDetector.detect(text) == language
        }
        guard letters.count >= 20, !letters.contains(where: han), !letters.contains(where: kana) else { return false }
        let key = TargetLanguageKey(text: text, language: language)
        if case let .some(.some(cached)) = targetLanguageCache.value(for: key) { return cached }
        let result = isConfidentlyUnmixed(text, language: language)
        targetLanguageCache.insert(result, for: key)
        return result
    }

    private struct TargetLanguageKey: Hashable {
        let text: String
        let language: String
    }

    /// `apply` runs when OCR is cached and again before requests. The
    /// NaturalLanguage decision is deterministic for the same text/target.
    private static let targetLanguageCache = LanguageDetectionLRUCache<TargetLanguageKey, Bool>(capacity: 512)

    private static func isConfidentlyUnmixed(_ text: String, language: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }),
              best.key.rawValue == language, best.value >= 0.95 else { return false }
        // A confident foreign word is evidence of mixed-language metadata.
        for word in text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) where word.count >= 4 {
            recognizer.reset()
            recognizer.processString(String(word))
            if let wordLanguage = recognizer.languageHypotheses(withMaximum: 1).first,
               wordLanguage.value >= 0.9, wordLanguage.key.rawValue != language { return false }
        }
        return true
    }

    static func canonical(_ code: String) -> String { code == "zh-Hans" ? "zh" : code }

    static func normalized(_ codes: [String]) -> [String] { Set(codes.map(canonical)).sorted() }

    /// Nil preserves the existing all-language cache. Fixed sources with no Apple
    /// classifier also keep the permissive fallback.
    static func identity(settings: ReaderTranslationSettings) -> [String]? {
        var language = languageIdentity(settings: settings)
        if settings.usesOCRLanguagePolicy, settings.modelTier.restrictedSourceLanguageCodes != nil {
            language = ["ocr-source-manga-v2-neutral-symbols"] + (language ?? [])
        }
        if settings.filterBackgroundWithLLM { language = (language ?? []) + [TranslationHTTPCodec.backgroundPolicy] }
        if settings.filterSFXWithLLM { language = (language ?? []) + [TranslationHTTPCodec.sfxPolicy] }
        return language
    }

    private static func languageIdentity(settings: ReaderTranslationSettings) -> [String]? {
        let source = canonical(settings.sourceLanguage)
        if source == "auto" {
            let languages = normalized(settings.translationSourceLanguages)
            return languages.isEmpty ? nil : ["source-filter-v3-excluded-source-ownership", "auto"] + languages
        }
        guard AutomaticSourceLanguageDetector.automaticallyClassifiableLanguageCodes.contains(source) else { return nil }
        return ["source-filter-v3-excluded-source-ownership", "fixed", source]
    }

    /// Classify against the complete language set first. Never force Latin text
    /// into Japanese/Chinese by constraining the classifier to the model's list.
    static func allowsModelSource(_ text: String, tier: IPhoneOCRModelTier) -> Bool {
        if isLanguageNeutralSymbols(text) { return true }
        guard let supported = tier.restrictedSourceLanguageCodes else { return true }
        if let detected = AutomaticSourceLanguageDetector.detect(text) { return supported.contains(detected) }
        // Short shared Han names/interjections are often unclassifiable. Retain
        // those source owners without admitting other scripts or Latin-only text.
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        func cjk(_ scalar: Unicode.Scalar) -> Bool {
            (0x3040...0x30FF).contains(scalar.value) || (0xFF66...0xFF9D).contains(scalar.value) ||
                (0x3400...0x9FFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
        }
        return letters.contains(where: cjk) && letters.allSatisfy {
            cjk($0) || (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
        }
    }

    /// Punctuation and symbols have no source language to reject. They still
    /// pass through the ordinary provider SFX/background classification.
    static func isLanguageNeutralSymbols(_ text: String) -> Bool {
        let scalars = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        return !scalars.isEmpty && scalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) ||
                CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    static func apply(_ regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) -> [ReaderTranslationRegion] {
        regions.filter { allowsSource($0.source, settings: settings) }
    }

    /// The per-text rule of `apply`. `tier` names the recognizer that read the
    /// text (V2 always uses the manga recognizer, independent of the OCR setting).
    static func allowsSource(_ text: String, settings: ReaderTranslationSettings,
                             tier: IPhoneOCRModelTier? = nil) -> Bool {
        let source = canonical(settings.sourceLanguage)
        let languages = normalized(settings.translationSourceLanguages)
        return isLanguageNeutralSymbols(text) ||
            ((!settings.usesOCRLanguagePolicy || allowsModelSource(text, tier: tier ?? settings.modelTier)) &&
            !isAlreadyTargetLanguage(text, target: settings.targetLanguage) &&
            AutomaticSourceLanguageDetector.allowsOCRText(text, configuredSourceLanguage: source, automaticLanguageFilter: languages))
    }

    /// V2 cache identity of `allowsV2Source` (manga recognizer, shared-Han recall).
    static let v2SourcePolicy = "v2-source-filter-v2-manga-shared-han"

    /// V2 block rule: the legacy per-text rule, plus recall for Han-only
    /// dialogue (names, short replies) that NaturalLanguage cannot split
    /// between Japanese and Chinese. Such text is admitted whenever any
    /// Han-script language is allowed; other scripts follow the legacy rule.
    static func allowsV2Source(_ text: String, settings: ReaderTranslationSettings) -> Bool {
        if allowsSource(text, settings: settings, tier: .manga) { return true }
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        let han: (Unicode.Scalar) -> Bool = {
            (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }
        guard !letters.isEmpty, letters.allSatisfy(han) else { return false }
        let source = canonical(settings.sourceLanguage)
        let allowed = source == "auto" ? normalized(settings.translationSourceLanguages) : [source]
        let hanLanguages: Set<String> = ["ja", "zh", "zh-Hant"]
        return (allowed.isEmpty || allowed.contains(where: hanLanguages.contains)) &&
            !isAlreadyTargetLanguage(text, target: settings.targetLanguage)
    }

    /// Keep filtered-out lettering as an explicit source owner during composition.
    /// Only eligible IDs receive provider text; excluded OCR geometry stays intact.
    static func preservingExcludedSource(
        original: [ReaderTranslationRegion], translated: [ReaderTranslationRegion], eligibleIDs: Set<String>
    ) -> [ReaderTranslationRegion] {
        let completed = Dictionary(translated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return original.map { source in
            if eligibleIDs.contains(source.id) { return completed[source.id] ?? source }
            var kept = source
            kept.translation = source.source
            kept.translationReuseIdentity = nil
            return kept
        }
    }

    /// NaturalLanguage classification must not block reader gestures.
    static func applyOffMain(
        _ regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings
    ) async throws -> [ReaderTranslationRegion] {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = apply(regions, settings: settings)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
