import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationProviderTests {
    @Test func autosavePreservesIncompleteFormWithoutAllowingNetworkUse() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        settings.provider = .custom
        settings.custom.baseURL = "https://"
        settings.model = ""
        settings.automaticallyTranslate = false
        settings.ocr.confidenceThreshold = 0.75
        settings.ocr.detectorPixelThreshold = 0.25
        settings.ocr.detectorConfidenceThreshold = 0.55
        settings.ocr.detectorMinimumBoxSide = 2
        settings.overlay.opacity = 0.5
        settings.translationSourceLanguages = ["ja"]
        try settings.autosave(defaults: fixture.defaults, credentialStore: fixture.keys)
        let restored = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(restored.custom == settings.custom)
        #expect(restored.configuration.instructions == RemoteTranslationConfiguration.defaultInstructions)
        #expect(!restored.automaticallyTranslate)
        #expect(restored.ocr.confidenceThreshold == 0.75)
        #expect(restored.ocr.detectorPixelThreshold == 0.25)
        #expect(restored.ocr.detectorConfidenceThreshold == 0.55)
        #expect(restored.ocr.detectorMinimumBoxSide == 2)
        #expect(restored.overlay.opacity == 0.5)
        #expect(restored.translationSourceLanguages == ["ja"])
        #expect(throws: RemoteTranslationError.self) { try restored.validate() }
    }

    @Test(arguments: IPhoneOCRModelTier.allCases)
    func legacyOCRSettingsPreservePreferencesAndModelThresholds(tier: IPhoneOCRModelTier) throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        let legacy = """
        {"modelTier":"\(tier.rawValue)","detectorMaximumSide":800,"recognizerMaximumWidth":1200,"confidenceThreshold":0.85}
        """
        fixture.defaults.set(tier.rawValue, forKey: ReaderTranslationSettings.keyPrefix + "modelTier")
        fixture.defaults.set(Data(legacy.utf8), forKey: ReaderTranslationSettings.keyPrefix + "ocr")
        let restored = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(restored.ocr.modelTier == tier)
        #expect(restored.ocr.detectorMaximumSide == 800)
        #expect(restored.ocr.recognizerMaximumWidth == 1_184)
        #expect(restored.ocr.confidenceThreshold == 0.85)
        let original = NativeCoreMLOCRModelProfile.profile(for: tier).postprocessConfiguration
        #expect(restored.ocr.detectorPostprocessConfiguration == original)
        #expect(ReaderOCRConfiguration(modelTier: tier).detectorPostprocessConfiguration == original)
        try restored.autosave(defaults: fixture.defaults, credentialStore: fixture.keys)
        #expect(ReaderTranslationSettings(defaults: fixture.defaults).ocr == restored.ocr)
    }

    @Test(arguments: [Int.min, 0, 31, 32, 800, 1_184, 1_280, Int.max])
    func readerResolutionIsBoundedForRuntimePersistenceAndCacheIdentity(limit: Int) throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        let original = settings
        #expect(original.ocr.detectorMaximumSide == 1_184)
        #expect(original.ocr.recognizerMaximumWidth == 1_184)
        settings.ocr.detectorMaximumSide = limit
        settings.ocr.recognizerMaximumWidth = limit
        let expectedLimit = min(max(limit, 32), 1_184)
        #expect(settings.ocrConfiguration.detectorMaximumSide == expectedLimit)
        #expect(settings.ocrConfiguration.recognizerMaximumWidth == expectedLimit)
        #expect(NativeCoreMLRecognitionPreprocessor.targetHeight == 48)
        let usesDefaultResolution = expectedLimit == 1_184
        #expect(settings.hasSameTranslation(as: original) == usesDefaultResolution)
        #expect((ReaderTranslationCacheIdentity.ocr(page: "page", settings: settings) ==
                 ReaderTranslationCacheIdentity.ocr(page: "page", settings: original)) == usesDefaultResolution)
        #expect((ReaderTranslationCacheIdentity.translation(page: "page", settings: settings) ==
                 ReaderTranslationCacheIdentity.translation(page: "page", settings: original)) == usesDefaultResolution)
        fixture.defaults.set(try JSONEncoder().encode(settings.ocr), forKey: ReaderTranslationSettings.keyPrefix + "ocr")
        let migrated = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(migrated.ocr.detectorMaximumSide == expectedLimit)
        #expect(migrated.ocr.recognizerMaximumWidth == expectedLimit)
        try settings.autosave(defaults: fixture.defaults, credentialStore: fixture.keys)
        let restored = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(restored.ocr.detectorMaximumSide == expectedLimit)
        #expect(restored.ocr.recognizerMaximumWidth == expectedLimit)
        let data = try #require(fixture.defaults.data(forKey: ReaderTranslationSettings.keyPrefix + "ocr"))
        let saved = try JSONDecoder().decode(ReaderOCRConfiguration.self, from: data)
        #expect(saved.detectorMaximumSide == expectedLimit)
        #expect(saved.recognizerMaximumWidth == expectedLimit)
    }

    @Test func readerResolutionLimitsRemainIndependent() {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        settings.ocr.detectorMaximumSide = 2_000
        settings.ocr.recognizerMaximumWidth = 800
        #expect(settings.ocrConfiguration.detectorMaximumSide == 1_184)
        #expect(settings.ocrConfiguration.recognizerMaximumWidth == 800)
        settings.ocr.detectorMaximumSide = 640
        settings.ocr.recognizerMaximumWidth = 2_000
        #expect(settings.ocrConfiguration.detectorMaximumSide == 640)
        #expect(settings.ocrConfiguration.recognizerMaximumWidth == 1_184)
    }

    @Test(arguments: IPhoneOCRModelTier.allCases)
    func legacyModelOnlySettingUsesOriginalDetectorThresholds(tier: IPhoneOCRModelTier) {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(tier.rawValue, forKey: ReaderTranslationSettings.keyPrefix + "modelTier")
        let restored = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(restored.ocr.modelTier == tier)
        #expect(restored.ocr.detectorPostprocessConfiguration == NativeCoreMLOCRModelProfile.profile(for: tier).postprocessConfiguration)
    }

    @Test(arguments: [-0.05, 1.05, Double.nan, Double.infinity])
    func invalidDetectorThresholdsCannotBeSaved(value: Double) throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        for field in [\ReaderOCRConfiguration.detectorPixelThreshold, \.detectorConfidenceThreshold] {
            var settings = ReaderTranslationSettings(defaults: fixture.defaults)
            settings.ocr[keyPath: field] = value
            #expect(throws: RemoteTranslationError.self) { try settings.validate() }
            let safe = settings.ocr.detectorPostprocessConfiguration
            #expect((0...1).contains(safe.threshold))
            #expect((0...1).contains(safe.boxThreshold))
        }
    }

    @Test func detectorSettingsWithoutMinimumSizePreserveSavedThresholds() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        let legacy = """
        {"modelTier":"tiny","detectorMaximumSide":800,"recognizerMaximumWidth":1200,"confidenceThreshold":0.85,
         "detectorPixelThreshold":0.35,"detectorConfidenceThreshold":0.65}
        """
        fixture.defaults.set(Data(legacy.utf8), forKey: ReaderTranslationSettings.keyPrefix + "ocr")
        let settings = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(settings.ocr == ReaderOCRConfiguration(modelTier: .tiny, detectorMaximumSide: 800,
                    recognizerMaximumWidth: 1_184, confidenceThreshold: 0.85,
                    detectorPixelThreshold: 0.35, detectorConfidenceThreshold: 0.65, detectorMinimumBoxSide: 3))
    }

    @Test(arguments: [-1.0, 21.0, Double.nan, Double.infinity])
    func invalidMinimumDetectorSizeCannotBeSaved(value: Double) {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        settings.ocr.detectorMinimumBoxSide = value
        #expect(throws: RemoteTranslationError.self) { try settings.validate() }
        #expect((0...20).contains(settings.ocr.detectorPostprocessConfiguration.minimumBoxSide))
    }

    @Test func detectorThresholdChangesInvalidateOCRAndTranslationReuse() {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        let settings = ReaderTranslationSettings(defaults: fixture.defaults)
        let ocrKey = ReaderTranslationCacheIdentity.ocr(page: "page", settings: settings)
        let translationKey = ReaderTranslationCacheIdentity.translation(page: "page", settings: settings)
        for field in [\ReaderOCRConfiguration.detectorPixelThreshold, \.detectorConfidenceThreshold, \.detectorMinimumBoxSide] {
            var changed = settings
            changed.ocr[keyPath: field] += 0.05
            #expect(!settings.hasSameTranslation(as: changed))
            #expect(ReaderTranslationCacheIdentity.ocr(page: "page", settings: changed) != ocrKey)
            #expect(ReaderTranslationCacheIdentity.translation(page: "page", settings: changed) != translationKey)
            #expect(changed.ocr.confidenceThreshold == settings.ocr.confidenceThreshold)
        }
    }

    @Test func autosaveRetainsCredentialGenerationAndServerIsolation() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        try settings.autosave(defaults: fixture.defaults, apiKey: "original-key", credentialStore: fixture.keys)
        // A later form write must not roll back the generation from the key write.
        settings.model = ""
        try settings.autosave(defaults: fixture.defaults, credentialStore: fixture.keys)
        #expect(ReaderTranslationSettings(defaults: fixture.defaults).credentialGeneration == 1)
        #expect(try fixture.keys.secret(for: "openai") == "original-key")
        settings.provider = .custom
        settings.custom.baseURL = "https://translator.example/v1"
        let account = settings.selectedCredentialAccount
        defer { try? fixture.keys.deleteSecret(for: account) }
        try settings.autosave(defaults: fixture.defaults, apiKey: "custom-key", credentialStore: fixture.keys)
        settings.custom.baseURL = "https://other.example/v1"
        try settings.autosave(defaults: fixture.defaults, credentialStore: fixture.keys)
        #expect(try !fixture.keys.containsSecret(for: settings.selectedCredentialAccount))
        #expect(try fixture.keys.secret(for: account) == "custom-key")
        #expect(try fixture.keys.secret(for: "openai") == "original-key")
        #expect(ReaderTranslationSettings(defaults: fixture.defaults).credentialGeneration == 2)
    }

    @Test func existingOpenAISettingsAndKeySurviveProviderSwitches() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set("existing-model", forKey: ReaderTranslationSettings.keyPrefix + "model")
        fixture.defaults.set("high", forKey: ReaderTranslationSettings.keyPrefix + "reasoningEffort")
        try fixture.keys.save("original-openai-key", for: "openai")
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(settings.provider == .openAI)
        #expect(settings.model == "existing-model")
        #expect(settings.reasoningEffort == .high)
        #expect(settings.configuration.credentialAccount == "openai")

        settings.provider = .custom
        settings.custom.baseURL = "https://translator.example/v1"
        settings.model = "custom-model"
        settings.custom.apiProtocol = .chatCompletions
        try settings.save(defaults: fixture.defaults, apiKey: "custom-only-key", credentialStore: fixture.keys)
        let customAccount = settings.selectedCredentialAccount
        defer { try? fixture.keys.deleteSecret(for: customAccount) }
        var restored = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(restored.provider == .custom)
        #expect(restored.model == "custom-model")
        #expect(restored.configuration.apiProtocol == .chatCompletions)
        #expect(try restored.configuration.validatedEndpoint().absoluteString == "https://translator.example/v1/chat/completions")
        #expect(restored.credentialGeneration == 1)
        #expect(try fixture.keys.secret(for: restored.selectedCredentialAccount) == "custom-only-key")

        restored.provider = .openAI
        #expect(restored.model == "existing-model")
        #expect(restored.reasoningEffort == .high)
        #expect(try fixture.keys.secret(for: restored.selectedCredentialAccount) == "original-openai-key")
        try restored.save(defaults: fixture.defaults)
        restored = ReaderTranslationSettings(defaults: fixture.defaults)
        restored.provider = .custom
        #expect(restored.custom == settings.custom)
        #expect(restored.selectedCredentialAccount == customAccount)
    }

    @Test func customKeysAreBoundToServerURLAndPathButNotModelOrProtocol() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        settings.provider = .custom
        settings.custom.baseURL = "https://translator.example/tenant-a/v1"
        settings.model = "model-a"
        let account = settings.selectedCredentialAccount
        defer { try? fixture.keys.deleteSecret(for: account) }
        try settings.save(defaults: fixture.defaults, apiKey: "tenant-a-key", credentialStore: fixture.keys)
        settings.model = "model-b"
        settings.reasoningEffort = .high
        settings.custom.apiProtocol = .chatCompletions
        #expect(settings.configuration.reasoningEffort == .high)
        #expect(try fixture.keys.secret(for: settings.selectedCredentialAccount) == "tenant-a-key")
        settings.custom.baseURL = "https://translator.example/tenant-b/v1"
        #expect(settings.selectedCredentialAccount != account)
        #expect(try !fixture.keys.containsSecret(for: settings.selectedCredentialAccount))
        settings.custom.baseURL = "https://another.example/tenant-a/v1"
        #expect(try !fixture.keys.containsSecret(for: settings.selectedCredentialAccount))
        settings.custom.baseURL = " https://translator.example/tenant-a/v1 \n"
        #expect(settings.selectedCredentialAccount == account)
        settings.custom.apiProtocol = .responses
        #expect(settings.configuration.reasoningEffort == .high)
    }

    @Test func invalidSaveCannotReplaceAKeyOrPreferences() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        try settings.save(defaults: fixture.defaults, apiKey: "original-key", credentialStore: fixture.keys)
        let original = fixture.defaults.dictionaryRepresentation() as NSDictionary
        settings.model = ""
        #expect(throws: RemoteTranslationError.self) {
            try settings.save(defaults: fixture.defaults, apiKey: "uncommitted-key", credentialStore: fixture.keys)
        }
        #expect(try fixture.keys.secret(for: "openai") == "original-key")
        #expect(fixture.defaults.dictionaryRepresentation() as NSDictionary == original)
        settings.provider = .custom
        settings.model = "custom-model"
        settings.custom.baseURL = "http://192.168.1.10:8000/v1"
        #expect(throws: RemoteTranslationError.self) {
            try settings.save(defaults: fixture.defaults, apiKey: "uncommitted-key", credentialStore: fixture.keys)
        }
        #expect(try !fixture.keys.containsSecret(for: settings.selectedCredentialAccount))
        #expect(fixture.defaults.dictionaryRepresentation() as NSDictionary == original)
    }

    @Test func deletingCustomKeyDoesNotDeleteOpenAIKeyOrCommitDraft() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        try settings.save(defaults: fixture.defaults, apiKey: "openai-key", credentialStore: fixture.keys)
        settings.provider = .custom
        settings.custom.baseURL = "https://translator.example"
        settings.model = "custom-model"
        try fixture.keys.save("custom-key", for: settings.selectedCredentialAccount)
        defer { try? fixture.keys.deleteSecret(for: settings.selectedCredentialAccount) }
        try settings.deleteKey(defaults: fixture.defaults, credentialStore: fixture.keys)
        #expect(try !fixture.keys.containsSecret(for: settings.selectedCredentialAccount))
        #expect(try fixture.keys.secret(for: "openai") == "openai-key")
        let saved = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(saved.provider == .openAI)
        #expect(saved.model == "gpt-5-mini")
        #expect(saved.credentialGeneration == 2)
        #expect(settings.credentialGeneration == saved.credentialGeneration)
    }
}

private struct ProviderSettingsFixture {
    let suite = "AidokuTests.Provider.\(UUID().uuidString)"
    let keys = KeychainTranslationCredentialStore(service: "AidokuTests.Provider.Keys.\(UUID().uuidString)")
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? keys.deleteSecret(for: "openai")
    }
}
