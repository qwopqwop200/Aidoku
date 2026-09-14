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
                ],
                context: ["前の字幕"],
                glossary: [.init(source: "猫", target: "고양이")]
            ),
            segmentID: "segment-0"
        )
        let reordered = try identity(
            configuration: configuration,
            request: RemoteTranslationRequest(
                sourceLanguage: "ja",
                targetLanguage: "ko",
                segments: Array(baseRequest.segments.reversed()),
                context: baseRequest.context,
                glossary: baseRequest.glossary
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
            ],
            context: original.context,
            glossary: original.glossary
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
            makeRequest(context: ["다른 문맥"]),
            makeRequest(
                glossary: [.init(source: "猫", target: "냥이")]
            ),
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

    func testProvisionalDisplayAllowsBatchAndContextRefreshOnly()
        throws
    {
        let configuration = makeConfiguration()
        let base = try identity(
            configuration: configuration,
            request: makeRequest()
        )
        let changedBatch = try identity(
            configuration: configuration,
            request: makeRequest(
                context: ["새 문맥"],
                secondText: "바뀐 이웃"
            )
        )
        let changedModel = try identity(
            configuration: makeConfiguration(model: "gpt-5"),
            request: makeRequest()
        )
        let changedLanguage = try identity(
            configuration: configuration,
            request: makeRequest(targetLanguage: "en")
        )
        let changedGlossary = try identity(
            configuration: configuration,
            request: makeRequest(
                glossary: [.init(source: "猫", target: "냥이")]
            )
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
            base.canRemainVisibleWhileRefreshing(expected: changedGlossary)
        )
        XCTAssertFalse(
            base.canRemainVisibleWhileRefreshing(expected: changedOwnText)
        )
    }

    func testProgressiveMergeDropsProvisionalTranslationForChangedOCRText()
        throws
    {
        let configuration = makeConfiguration()
        let oldRequest = makeRequest()
        let nextRequest = makeRequest(
            context: ["새 문맥"],
            secondText: "바뀐 이웃"
        )
        let oldFirst = try identity(
            configuration: configuration,
            request: oldRequest,
            segmentID: "segment-0"
        )
        let oldSecond = try identity(
            configuration: configuration,
            request: oldRequest,
            segmentID: "segment-1"
        )
        let nextFirst = try identity(
            configuration: configuration,
            request: nextRequest,
            segmentID: "segment-0"
        )
        let nextSecond = try identity(
            configuration: configuration,
            request: nextRequest,
            segmentID: "segment-1"
        )
        let items = [
            BrowserOverlayItem(
                rect: .init(x: 0, y: 0, width: 100, height: 20),
                sourceText: "同じ文字",
                translatedText: "기존 첫 번째",
                confidence: 0.95,
                translationReuseIdentity: oldFirst
            ),
            BrowserOverlayItem(
                rect: .init(x: 0, y: 30, width: 100, height: 20),
                sourceText: "次の文字",
                translatedText: "기존 두 번째",
                confidence: 0.95,
                translationReuseIdentity: oldSecond
            ),
        ]

        let merged = NativeProgressiveTranslationOverlay.merge(
            items: items,
            expectedIdentities: [0: nextFirst, 1: nextSecond],
            completedTranslations: [
                0: NativeTranslationReuseValue(
                    identity: nextFirst,
                    translatedText: "새 첫 번째"
                ),
            ]
        )

        XCTAssertEqual(merged.map(\.translatedText), ["새 첫 번째", nil])
        XCTAssertEqual(merged[0].translationReuseIdentity, nextFirst)
        XCTAssertNil(merged[1].translationReuseIdentity)
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
        context: [String] = ["前の字幕"],
        glossary: [TranslationGlossaryEntry] = [
            .init(source: "猫", target: "고양이"),
        ],
        firstText: String = "同じ文字",
        secondText: String = "次の文字"
    ) -> RemoteTranslationRequest {
        RemoteTranslationRequest(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            segments: [
                .init(id: "segment-0", text: firstText),
                .init(id: "segment-1", text: secondText),
            ],
            context: context,
            glossary: glossary
        )
    }
}
