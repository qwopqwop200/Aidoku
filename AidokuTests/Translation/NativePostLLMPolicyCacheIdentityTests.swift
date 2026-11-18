import Foundation
import Testing
@testable import Aidoku

/// App-hosted CPU contracts only. Never creates a client, transport, OCR
/// service, model, image decoder, or provider request.
@Suite(.serialized) @MainActor
struct NativePostLLMPolicyCacheIdentityTests {
    private typealias Policy = NativePostLLMContentReclassifier.Policy

    @Test func preparedDetectorHeadKeepsReferenceOverlapTieAndFailureSemantics() throws {
        typealias Features = NativeOCRPremergeCandidateFeatures
        func box(_ x: Double) -> [Features.Point] {
            [.init(x: x, y: 0), .init(x: x + 10, y: 0), .init(x: x + 10, y: 10), .init(x: x, y: 10)]
        }
        let reference = box(0)
        let polygon = box(5)
        let boxes: [Features.DetectorBox] = [
            .init(polygon: reference, score: 0.4), .init(polygon: reference, score: 0.9)
        ]
        let inventory = Features.prepareDetectorInventory(boxes)
        let head = try #require(NativePostLLMContentReclassifier.detectorSignals(
            polygon: polygon, baseline: reference, inventory: inventory, recognitionConfidence: 0.8))
        #expect(head == [1, 0.4, 1, 1.0 / 3.0, 0.5])
        let features = Features.extract(polygon: polygon, baseline: reference, detectorBoxes: boxes, rfPrimitives: [],
            recognition: .init(polygon: polygon, text: "字", confidence: 0.8), signalsOnly: true)
        #expect(NativePostLLMContentReclassifier.detectorSignals(from: features) == head)
        #expect(NativePostLLMContentReclassifier.detectorSignals(
            polygon: polygon, baseline: reference, inventory: inventory, recognitionConfidence: .nan) == nil)
        #expect(NativePostLLMContentReclassifier.detectorSignals(
            polygon: polygon, baseline: [], inventory: inventory, recognitionConfidence: 0.8) == nil)
        let bad = Features.prepareDetectorInventory(boxes + [.init(polygon: reference, score: .nan)])
        #expect(NativePostLLMContentReclassifier.detectorSignals(
            polygon: polygon, baseline: reference, inventory: bad, recognitionConfidence: 0.8) == nil)
        let empty = Features.prepareDetectorInventory([])
        #expect(NativePostLLMContentReclassifier.detectorSignals(
            polygon: polygon, baseline: reference, inventory: empty, recognitionConfidence: 0.8) == [0, 0, 0, 0, 0])
    }

    private func settings(_ defaults: UserDefaults) -> ReaderTranslationSettings {
        var value = ReaderTranslationSettings(defaults: defaults)
        value.provider = .custom
        value.custom.apiProtocol = .responses
        value.custom.baseURL = "https://offline-policy-cache.invalid/v1"
        value.model = "offline-policy-fixture"
        value.sourceLanguage = "ja"
        value.targetLanguage = "ko"
        return value
    }

    /// Historical composition, independent of the new policy-local suffix.
    private func legacyTranslationKey(_ settings: ReaderTranslationSettings) -> String {
        let config = settings.configuration
        return ReaderTranslationCacheIdentity.encoded([
            "reader-translation-v7-symbol-preservation-state", NativePostLLMContentReclassifier.policyVersion,
            ReaderTranslationCacheIdentity.ocr(page: "policy-fixture", settings: settings),
            config.provider.rawValue, config.apiProtocol.rawValue, config.baseURL, config.model,
            config.credentialAccount, String(config.credentialGeneration), config.reasoningEffort.rawValue,
            config.instructions, settings.sourceLanguage, settings.targetLanguage, TranslationHTTPCodec.letteringPolicy,
            "literal-recovery-v1-preserve-filters-bounded-isolation",
            "page-image-required-v1", TranslationHTTPCodec.sfxPolicy, TranslationHTTPCodec.backgroundPolicy
        ])
    }

    private func sharedEvidence() throws -> NativePostLLMContentReclassifier.Evidence {
        var features = Array(repeating: 0.0, count: NativeFinalOutputContentFilter.featureNames.count)
        for (name, value) in [("out.rawTextSupport", 0.3), ("out.rawTextShare", 0.8), ("ocrBodyMin", 0.9)] {
            features[try #require(NativeFinalOutputContentFilter.featureNames.firstIndex(of: name))] = value
        }
        return try #require(NativePostLLMContentReclassifier.Evidence(features: features))
    }

    @Test func normalizedDefaultAndEstablishedRollbackRemainTaskScoped() async {
        #expect(NativePostLLMContentReclassifier.defaultPolicy == .normalizedCorroboration)
        #expect(NativePostLLMContentReclassifier.activePolicy == .normalizedCorroboration)
        let child = await NativePostLLMContentReclassifier.$activePolicy.withValue(.established) {
            #expect(NativePostLLMContentReclassifier.activePolicy == .established)
            return await Task { NativePostLLMContentReclassifier.activePolicy }.value
        }
        #expect(child == .established)
        #expect(NativePostLLMContentReclassifier.activePolicy == .normalizedCorroboration)
    }

    @Test func defaultUsesSharedRuleWithoutChangingTranslatedText() throws {
        let evidence = try sharedEvidence()
        let segment = RemoteTranslatedSegment(id: "region-0", text: "기존 번역", isSFX: false, textRole: .background)
        let actual = NativePostLLMContentReclassifier.resolved(segment, evidence: evidence)
        let explicit = NativePostLLMContentReclassifier.resolved(segment, evidence: evidence, policy: .normalizedCorroboration)
        #expect(actual == explicit)
        #expect(actual.textRole == .storyText)
        #expect(actual.isSFX == false)
        #expect(actual.text == segment.text)
    }

    @Test func establishedRollbackKeepsExactLegacyDerivedTranslationKey() throws {
        let name = "PostLLMPolicyCache.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = settings(defaults)
        let legacy = legacyTranslationKey(settings)
        let current = ReaderTranslationCacheIdentity.unfilteredTranslation(page: "policy-fixture", settings: settings)
        let rollback = NativePostLLMContentReclassifier.$activePolicy.withValue(.established) {
            #expect(NativePostLLMContentReclassifier.activePolicy.cacheProjection.isEmpty)
            return ReaderTranslationCacheIdentity.unfilteredTranslation(page: "policy-fixture", settings: settings)
        }
        #expect(rollback == legacy)
        #expect(current != rollback)
        #expect(current == ReaderTranslationCacheIdentity.encoded([
            legacy, "post-llm-derived-translation-v1", Policy.normalizedCorroboration.version
        ]))
        let direct = NativePostLLMContentReclassifier.$activePolicy.withValue(.providerOnly) {
            ReaderTranslationCacheIdentity.unfilteredTranslation(page: "policy-fixture", settings: settings)
        }
        #expect(direct != current && direct != rollback)
    }

    @Test func realOCRIdentityDoesNotDependOnPostLLMPolicy() throws {
        let name = "PostLLMOCRCache.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = settings(defaults)
        let current = ReaderTranslationCacheIdentity.ocr(page: "policy-fixture", settings: settings)
        for policy: Policy in [.established, .providerOnly, .sharedModelCorroboration, .normalizedCorroboration] {
            let scoped = NativePostLLMContentReclassifier.$activePolicy.withValue(policy) {
                ReaderTranslationCacheIdentity.ocr(page: "policy-fixture", settings: settings)
            }
            #expect(scoped == current)
        }
    }

    @Test func rawTranslationCacheAndHTTPBodyDoNotDependOnPostLLMPolicy() throws {
        let config = RemoteTranslationConfiguration(provider: .custom, apiProtocol: .responses,
            baseURL: "https://offline-policy-cache.invalid/v1", model: "offline-policy-fixture",
            credentialAccount: "offline-unused")
        let request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: [
            .init(id: "region-0", text: "テスト", bounds: [0.1, 0.2, 0.3, 0.1])
        ])
        let endpoint = try config.validatedEndpoint()
        let key = TranslationCacheKey(configuration: config, endpoint: endpoint, request: request)
        let body = try TranslationHTTPCodec.requestBody(configuration: config, request: request)
        for policy: Policy in [.established, .providerOnly, .sharedModelCorroboration, .normalizedCorroboration] {
            let scoped = try NativePostLLMContentReclassifier.$activePolicy.withValue(policy) {
                (TranslationCacheKey(configuration: config, endpoint: endpoint, request: request),
                 try TranslationHTTPCodec.requestBody(configuration: config, request: request))
            }
            #expect(scoped.0 == key)
            #expect(scoped.1 == body)
        }
    }

    @Test func providerOnlyRollbackStillDisablesCorrection() throws {
        let evidence = try sharedEvidence()
        let segment = RemoteTranslatedSegment(id: "region-0", text: "기존 번역", isSFX: true, textRole: .sfx)
        let direct = NativePostLLMContentReclassifier.$activePolicy.withValue(.providerOnly) {
            NativePostLLMContentReclassifier.resolved(segment, evidence: evidence)
        }
        #expect(direct == segment)
        #expect(NativePostLLMContentReclassifier.activePolicy == .normalizedCorroboration)
    }
}
