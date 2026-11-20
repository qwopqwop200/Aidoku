// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.

/// Identifies one translated segment using the exact cache identity of the
/// remote request that produced it.
///
/// The cache key covers provider, protocol, endpoint, model, credential
/// generation, languages, the complete ordered batch, instructions,
/// reasoning effort. `segmentID` then selects
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
        let cacheKey = TranslationCacheKey(
            configuration: configuration, endpoint: endpoint,
            request: request.canonicalizedForTranslationSemantics().request
        )
        return Dictionary(uniqueKeysWithValues: request.segments.enumerated().map { index, segment in
            (segment.id, Self(cacheKey: cacheKey, segmentID: RemoteTranslationRequest.batchLocalSegmentID(at: index)))
        })
    }

    /// Keeps the last translation visible while only the ordered batch
    /// is refreshed. Cache reuse remains exact; this
    /// weaker comparison is display-only and rejects provider, model,
    /// credential, language, prompt, reasoning, and the selected
    /// segment's own OCR-text changes.
    func canRemainVisibleWhileRefreshing(expected: NativeTranslationReuseIdentity) -> Bool {
        guard let sourceSegment = cacheKey.segments.first(where: { $0.id == segmentID }),
              let expectedSegment = expected.cacheKey.segments.first(where: { $0.id == expected.segmentID }) else { return false }
        return sourceSegment.text == expectedSegment.text &&
            sourceSegment.bounds == expectedSegment.bounds &&
            hasSameTranslationConfiguration(as: expected)
    }

    /// Geometry-only viewport changes may reorder or regroup an otherwise
    /// identical set of OCR regions. The full cache identity deliberately
    /// changes in that case, but an already translated stable region can still
    /// move to its new coordinates without falling back to source text.
    func hasSameTranslationConfiguration(as expected: NativeTranslationReuseIdentity) -> Bool {
        cacheKey.imageDigest == expected.cacheKey.imageDigest &&
            cacheKey.roleVerificationPolicy == expected.cacheKey.roleVerificationPolicy &&
            cacheKey.imageSupportRevision == expected.cacheKey.imageSupportRevision &&
            cacheKey.sfxPolicy == expected.cacheKey.sfxPolicy &&
            cacheKey.backgroundPolicy == expected.cacheKey.backgroundPolicy &&
            cacheKey.letteringPolicy == expected.cacheKey.letteringPolicy &&
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
            cacheKey.reasoningEffort == expected.cacheKey.reasoningEffort
    }
}
