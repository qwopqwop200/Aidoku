// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.

/// One translated segment, identified by the exact cache key of its request. The
/// whole ordered batch is part of the identity: neighbors can change a translation.
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

    /// Display-only: keeps the last translation visible while only its neighbors
    /// change. Cache reuse stays exact; any other key or own-segment change rejects.
    func canRemainVisibleWhileRefreshing(expected: NativeTranslationReuseIdentity) -> Bool {
        guard let sourceSegment = cacheKey.segments.first(where: { $0.id == segmentID }),
              let expectedSegment = expected.cacheKey.segments.first(where: { $0.id == expected.segmentID }) else { return false }
        return sourceSegment.text == expectedSegment.text &&
            sourceSegment.bounds == expectedSegment.bounds &&
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
