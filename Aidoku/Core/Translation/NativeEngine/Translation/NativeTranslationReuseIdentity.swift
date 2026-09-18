// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

/// Identifies one translated segment using the exact cache identity of the
/// remote request that produced it.
///
/// The cache key covers provider, protocol, endpoint, model, credential
/// generation, languages, the complete ordered batch, instructions,
/// reasoning effort, subtitle context, and glossary. `segmentID` then selects
/// one result from that batch. Keeping the complete batch in the identity is
/// intentional: a model can translate the same text differently when its
/// neighboring segments or batch position change.
struct NativeTranslationReuseIdentity: Hashable, Sendable {
    let cacheKey: TranslationCacheKey
    let segmentID: String

    static func identitiesBySegmentID(
        configuration: RemoteTranslationConfiguration,
        request: RemoteTranslationRequest
    ) throws -> [String: Self] {
        try request.validate()
        let endpoint = try configuration.validatedEndpoint()
        let canonicalRequest =
            request.canonicalizedForTranslationSemantics().request
        let cacheKey = TranslationCacheKey(
            configuration: configuration,
            endpoint: endpoint,
            request: canonicalRequest
        )
        return Dictionary(
            uniqueKeysWithValues: request.segments.enumerated().map {
                index, segment in
                (
                    segment.id,
                    Self(
                        cacheKey: cacheKey,
                        segmentID:
                            RemoteTranslationRequest.batchLocalSegmentID(
                                at: index
                            )
                    )
                )
            }
        )
    }

    /// Keeps the last translation visible while only the ordered batch or
    /// rolling subtitle context is refreshed. Cache reuse remains exact; this
    /// weaker comparison is display-only and rejects provider, model,
    /// credential, language, prompt, reasoning, glossary, and the selected
    /// segment's own OCR-text changes.
    func canRemainVisibleWhileRefreshing(
        expected: NativeTranslationReuseIdentity
    ) -> Bool {
        let sourceText = cacheKey.segments.first {
            $0.id == segmentID
        }?.text
        let expectedSourceText = expected.cacheKey.segments.first {
            $0.id == expected.segmentID
        }?.text
        return sourceText != nil &&
            sourceText == expectedSourceText &&
            cacheKey.segments.first(where: { $0.id == segmentID })?.bounds ==
                expected.cacheKey.segments.first(where: { $0.id == expected.segmentID })?.bounds &&
            cacheKey.imageDigest == expected.cacheKey.imageDigest &&
            cacheKey.imageSupportRevision == expected.cacheKey.imageSupportRevision &&
            cacheKey.sfxPolicy == expected.cacheKey.sfxPolicy &&
            cacheKey.version == expected.cacheKey.version &&
            cacheKey.provider == expected.cacheKey.provider &&
            cacheKey.apiProtocol == expected.cacheKey.apiProtocol &&
            cacheKey.endpointNamespace == expected.cacheKey.endpointNamespace &&
            cacheKey.model == expected.cacheKey.model &&
            cacheKey.credentialAccount == expected.cacheKey.credentialAccount &&
            cacheKey.credentialGeneration == expected.cacheKey.credentialGeneration &&
            cacheKey.sourceLanguage == expected.cacheKey.sourceLanguage &&
            cacheKey.targetLanguage == expected.cacheKey.targetLanguage &&
            cacheKey.instructions == expected.cacheKey.instructions &&
            cacheKey.reasoningEffort == expected.cacheKey.reasoningEffort &&
            cacheKey.glossary == expected.cacheKey.glossary
    }

    /// Geometry-only viewport changes may reorder or regroup an otherwise
    /// identical set of OCR regions. The full cache identity deliberately
    /// changes in that case, but an already translated stable region can still
    /// move to its new coordinates without falling back to source text.
    func hasSameTranslationConfiguration(
        as expected: NativeTranslationReuseIdentity
    ) -> Bool {
        cacheKey.imageDigest == expected.cacheKey.imageDigest &&
            cacheKey.imageSupportRevision == expected.cacheKey.imageSupportRevision &&
            cacheKey.sfxPolicy == expected.cacheKey.sfxPolicy &&
            cacheKey.version == expected.cacheKey.version &&
            cacheKey.provider == expected.cacheKey.provider &&
            cacheKey.apiProtocol == expected.cacheKey.apiProtocol &&
            cacheKey.endpointNamespace == expected.cacheKey.endpointNamespace &&
            cacheKey.model == expected.cacheKey.model &&
            cacheKey.credentialAccount == expected.cacheKey.credentialAccount &&
            cacheKey.credentialGeneration == expected.cacheKey.credentialGeneration &&
            cacheKey.sourceLanguage == expected.cacheKey.sourceLanguage &&
            cacheKey.targetLanguage == expected.cacheKey.targetLanguage &&
            cacheKey.instructions == expected.cacheKey.instructions &&
            cacheKey.reasoningEffort == expected.cacheKey.reasoningEffort &&
            cacheKey.glossary == expected.cacheKey.glossary
    }
}

struct NativeTranslationReuseValue: Equatable, Sendable {
    let identity: NativeTranslationReuseIdentity
    let translatedText: String
}

/// Builds a stable partial frame as remote batches complete. Exact/provisional
/// translations from the source frame remain visible until their own
/// replacement arrives, so progressive publication cannot blink a region back
/// to source-only merely because a neighboring provider batch finished first.
enum NativeProgressiveTranslationOverlay {
    static func merge(
        items: [BrowserOverlayItem],
        expectedIdentities:
            [Int: NativeTranslationReuseIdentity],
        completedTranslations:
            [Int: NativeTranslationReuseValue]
    ) -> [BrowserOverlayItem] {
        items.enumerated().map { index, item in
            let expectedIdentity = expectedIdentities[index]
            let completed = completedTranslations[index]
            let canKeepExisting: Bool
            if let oldIdentity = item.translationReuseIdentity,
               let expectedIdentity,
               item.translatedText != nil
            {
                canKeepExisting = oldIdentity == expectedIdentity ||
                    oldIdentity.canRemainVisibleWhileRefreshing(
                        expected: expectedIdentity
                    )
            } else {
                canKeepExisting = false
            }
            return BrowserOverlayItem(
                stableRegionID: item.stableRegionID,
                rect: item.rect,
                sourceText: item.sourceText,
                translatedText:
                    completed?.translatedText ??
                    (canKeepExisting ? item.translatedText : nil),
                confidence: item.confidence,
                sourceOrientation: item.sourceOrientation,
                sourceSingleVerticalColumn:
                    item.sourceSingleVerticalColumn,
                translationReuseIdentity:
                    completed?.identity ??
                    (canKeepExisting
                        ? item.translationReuseIdentity
                        : nil),
                sourcePolygon: item.sourcePolygon, auxiliaryInkRects: item.auxiliaryInkRects
            )
        }
    }
}

/// Exact-match lookup used when carrying visible translations into a newly
/// rendered OCR frame. Missing identities and semantic mismatches deliberately
/// return no value so the normal TranslationService/cache path owns the result.
struct NativeTranslationReuseIndex: Sendable {
    private let valuesByIdentity:
        [NativeTranslationReuseIdentity: NativeTranslationReuseValue]

    init(values: [NativeTranslationReuseValue]) {
        valuesByIdentity = Dictionary(
            values.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func value(
        matching identity: NativeTranslationReuseIdentity?
    ) -> NativeTranslationReuseValue? {
        guard let identity else { return nil }
        return valuesByIdentity[identity]
    }
}
