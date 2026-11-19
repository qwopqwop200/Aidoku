// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import XCTest
@testable import Aidoku

final class NativeTranslationReuseIdentityTests: XCTestCase {
    func testExactIdentityReusesOnlyMatchingTranslation() throws {
        let configuration = makeConfiguration()
        let request = makeRequest()
        let identities =
            try NativeTranslationReuseIdentity.identitiesBySegmentID(
                configuration: configuration,
                request: request
            )
        let first = try XCTUnwrap(identities["segment-0"])
        let second = try XCTUnwrap(identities["segment-1"])
        let index = NativeTranslationReuseIndex(values: [
            NativeTranslationReuseValue(
                identity: first,
                translatedText: "첫 번째"
            ),
        ])

        XCTAssertEqual(
            index.value(matching: first)?.translatedText,
            "첫 번째"
        )
        XCTAssertNil(index.value(matching: second))
        XCTAssertNil(index.value(matching: nil))
    }

    func testIdentityIncludesCompleteOrderedBatchAndSegmentPosition()
        throws
    {
        let configuration = makeConfiguration()
        let baseRequest = makeRequest()
        let base = try identity(
            configuration: configuration,
            request: baseRequest,
            segmentID: "segment-0"
        )
        let companionChanged = try identity(
            configuration: configuration,
            request: RemoteTranslationRequest(
                sourceLanguage: "ja",
                targetLanguage: "ko",
                segments: [
                    .init(id: "segment-0", text: "同じ文字"),
                    .init(id: "segment-1", text: "変更された隣の文字"),
                ]
            ),
            segmentID: "segment-0"
        )
        let reordered = try identity(
            configuration: configuration,
            request: RemoteTranslationRequest(
                sourceLanguage: "ja",
                targetLanguage: "ko",
                segments: Array(baseRequest.segments.reversed())
            ),
            segmentID: "segment-0"
        )
        let sameBatchOtherSegment = try identity(
            configuration: configuration,
            request: baseRequest,
            segmentID: "segment-1"
        )

        XCTAssertNotEqual(companionChanged, base)
        XCTAssertNotEqual(reordered, base)
        XCTAssertNotEqual(sameBatchOtherSegment, base)
    }

    func testTrackerIDsDoNotChangeBatchLocalReuseIdentity() throws {
        let configuration = makeConfiguration()
        let original = makeRequest()
        let renumbered = RemoteTranslationRequest(
            sourceLanguage: original.sourceLanguage,
            targetLanguage: original.targetLanguage,
            segments: [
                .init(id: "tracker-900", text: original.segments[0].text),
                .init(id: "tracker-901", text: original.segments[1].text),
            ]
        )
        let originalIdentities =
            try NativeTranslationReuseIdentity.identitiesBySegmentID(
                configuration: configuration,
                request: original
            )
        let renumberedIdentities =
            try NativeTranslationReuseIdentity.identitiesBySegmentID(
                configuration: configuration,
                request: renumbered
            )

        XCTAssertEqual(
            originalIdentities["segment-0"],
            renumberedIdentities["tracker-900"]
        )
        XCTAssertEqual(
            originalIdentities["segment-1"],
            renumberedIdentities["tracker-901"]
        )
    }

    func testIdentityInvalidatesEveryTranslationSemanticFamily()
        throws
    {
        let configuration = makeConfiguration()
        let request = makeRequest()
        let base = try identity(
            configuration: configuration,
            request: request
        )
        let configurationVariants = [
            makeConfiguration(
                provider: .custom,
                apiProtocol: .chatCompletions,
                baseURL: "https://example.com/v1",
                reasoningEffort: .modelDefault
            ),
            makeConfiguration(model: "gpt-5"),
            makeConfiguration(credentialAccount: "rotated"),
            makeConfiguration(credentialGeneration: 8),
            makeConfiguration(instructions: "different instructions"),
            makeConfiguration(reasoningEffort: .high),
        ]
        for variant in configurationVariants {
            XCTAssertNotEqual(
                try identity(
                    configuration: variant,
                    request: request
                ),
                base
            )
        }

        let requestVariants = [
            makeRequest(sourceLanguage: "auto"),
            makeRequest(targetLanguage: "en"),
            makeRequest(firstText: "違う文字"),
        ]
        for variant in requestVariants {
            XCTAssertNotEqual(
                try identity(
                    configuration: configuration,
                    request: variant
                ),
                base
            )
        }
    }

    func testNonSemanticTransportLimitsFollowCacheIdentity()
        throws
    {
        let request = makeRequest()
        let base = try identity(
            configuration: makeConfiguration(timeout: 60),
            request: request
        )
        let transportOnlyChange = try identity(
            configuration: makeConfiguration(timeout: 120),
            request: request
        )

        XCTAssertEqual(transportOnlyChange, base)
    }

    func testProvisionalDisplayAllowsBatchRefreshOnly()
        throws
    {
        let configuration = makeConfiguration()
        let base = try identity(
            configuration: configuration,
            request: makeRequest()
        )
        let changedBatch = try identity(
            configuration: configuration,
            request: makeRequest(secondText: "바뀐 이웃")
        )
        let changedModel = try identity(
            configuration: makeConfiguration(model: "gpt-5"),
            request: makeRequest()
        )
        let changedLanguage = try identity(
            configuration: configuration,
            request: makeRequest(targetLanguage: "en")
        )
        let changedOwnText = try identity(
            configuration: configuration,
            request: makeRequest(firstText: "別の文字")
        )

        XCTAssertTrue(
            base.canRemainVisibleWhileRefreshing(expected: changedBatch)
        )
        XCTAssertFalse(
            base.canRemainVisibleWhileRefreshing(expected: changedModel)
        )
        XCTAssertFalse(
            base.canRemainVisibleWhileRefreshing(expected: changedLanguage)
        )
        XCTAssertFalse(
            base.canRemainVisibleWhileRefreshing(expected: changedOwnText)
        )
    }

    func testSourceBoundRoleFieldsInvalidateProvisionalDisplay() throws {
        let base = try identity(configuration: makeConfiguration(), request: makeRequest())
        let encoded = try JSONEncoder().encode(base.cacheKey)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        // Change each persisted field independently, leaving image bytes,
        // source text, geometry, model and prompt exactly the same.
        for field in ["roleEvidenceSourceImageIdentity", "roleVerificationPolicy"] {
            var changed = object
            changed[field] = "changed-source-or-policy"
            let key = try JSONDecoder().decode(TranslationCacheKey.self,
                from: JSONSerialization.data(withJSONObject: changed))
            let next = NativeTranslationReuseIdentity(cacheKey: key, segmentID: base.segmentID)
            XCTAssertFalse(base.canRemainVisibleWhileRefreshing(expected: next), field)
            XCTAssertFalse(base.hasSameTranslationConfiguration(as: next), field)
        }
    }

    private func identity(
        configuration: RemoteTranslationConfiguration,
        request: RemoteTranslationRequest,
        segmentID: String = "segment-0"
    ) throws -> NativeTranslationReuseIdentity {
        let identities =
            try NativeTranslationReuseIdentity.identitiesBySegmentID(
                configuration: configuration,
                request: request
            )
        return try XCTUnwrap(identities[segmentID])
    }

    private func makeConfiguration(
        provider: RemoteTranslationProvider = .openAI,
        apiProtocol: RemoteTranslationProtocol = .responses,
        baseURL: String = "https://api.openai.com",
        model: String = "gpt-5-mini",
        credentialAccount: String = "openai",
        credentialGeneration: UInt64 = 7,
        instructions: String = "Translate faithfully.",
        reasoningEffort: OpenAIReasoningEffort = .low,
        timeout: TimeInterval = 60
    ) -> RemoteTranslationConfiguration {
        RemoteTranslationConfiguration(
            provider: provider,
            apiProtocol: apiProtocol,
            baseURL: baseURL,
            model: model,
            credentialAccount: credentialAccount,
            credentialGeneration: credentialGeneration,
            instructions: instructions,
            reasoningEffort: reasoningEffort,
            timeout: timeout,
            maximumResponseBytes: 1024 * 1024,
            allowsInsecureLocalhostForDevelopment: false
        )
    }

    private func makeRequest(
        sourceLanguage: String = "ja",
        targetLanguage: String = "ko",
        firstText: String = "同じ文字",
        secondText: String = "次の文字"
    ) -> RemoteTranslationRequest {
        RemoteTranslationRequest(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            segments: [
                .init(id: "segment-0", text: firstText),
                .init(id: "segment-1", text: secondText),
            ]
        )
    }
}
