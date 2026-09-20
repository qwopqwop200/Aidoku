import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct ReaderTranslationRemovedFeaturesTests {
    @Test func legacyFlagsCannotAttachImagesOrFilterSounds() throws {
        let name = "AidokuTests.RemovedFeatures.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "Reader.translation.sendImageForTranslation")
        defaults.set(true, forKey: "Reader.translation.automaticallyExcludeSFX")
        defaults.set(true, forKey: "Reader.translation.filterJapaneseSFX")
        defaults.set(true, forKey: "Reader.translation.filterJapaneseSFXContext")
        defaults.set("Legacy custom instruction", forKey: "Reader.translation.instructions")
        let settings = ReaderTranslationSettings(defaults: defaults)
        #expect(settings.configuration.instructions == RemoteTranslationConfiguration.defaultInstructions)
        #expect(!settings.configuration.instructions.contains("AIDOKU_SKIP"))
        #expect(!settings.configuration.instructions.contains("attached page image"))
        let regions = ["ガチャ", "ああ", "今日は晴れ"].enumerated().map {
            ReaderTranslationRegion(id: String($0.offset), rect: CGRect(x: 0.1, y: Double($0.offset) * 0.2, width: 0.1, height: 0.1), source: $0.element)
        }
        #expect(ReaderTranslationLanguageFilter.apply(regions, settings: settings) == regions)
        #expect(!ReaderTranslationImagePreparation.needsImage(regions, settings: settings))
        let requests = try ReaderTranslationService.requests(regions: regions, settings: settings)
        #expect(requests.flatMap(\.segments).map(\.text) == regions.map(\.source))
        for request in requests {
            let body = try TranslationHTTPCodec.requestBody(configuration: settings.configuration, request: request)
            let text = String(decoding: body, as: UTF8.self)
            #expect(!text.contains("input_image"))
            #expect(!text.contains("image_url"))
            #expect(!text.contains("base64"))
        }
    }

    @Test func metadataUsesInternalContextAndNeverRestoresCustomInstructions() throws {
        let name = "AidokuTests.RemovedPrompt.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("Legacy custom instruction", forKey: "Reader.translation.instructions")
        let settings = ReaderTranslationSettings(defaults: defaults)
        for kind in TitleTranslationKind.allCases {
            let metadata = TitleTranslation.effectiveSettings(settings, kind: kind)
            #expect(metadata.configuration.instructions.hasPrefix(RemoteTranslationConfiguration.defaultInstructions))
            #expect(!metadata.configuration.instructions.contains("Legacy custom instruction"))
            #expect(TitleTranslation.effectiveSettings(metadata, kind: kind).configuration == metadata.configuration)
            if kind != .tag { #expect(!metadata.metadataInstructions.isEmpty) }
            try metadata.autosave(defaults: defaults)
            #expect(ReaderTranslationSettings(defaults: defaults).configuration.instructions == RemoteTranslationConfiguration.defaultInstructions)
        }
    }

    @Test func oldDictionaryEvidenceDoesNotInvalidateCachedText() throws {
        let region = ReaderTranslationRegion(id: "sound", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                                             source: "ドン", translation: "쿵")
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ReaderTranslationStoredRegion(region))) as? [String: Any])
        legacy["sfxEnclosedBackground"] = true
        let restored = try JSONDecoder().decode(ReaderTranslationStoredRegion.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.region == region)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        #expect(saved["sfxEnclosedBackground"] == nil)
    }

    @Test @MainActor
    func retiredFontAndExpansionPreferencesUseAutomaticBoundedLayout() throws {
        let original = ReaderTranslationSettings.defaultOverlay
        let encoded = try JSONEncoder().encode(original)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let source = CGRect(x: 220, y: 80, width: 24, height: 150)
        let viewport = CGSize(width: 390, height: 715)
        func layout(_ settings: IPhoneOverlaySettings) -> BrowserOverlayCardLayout {
            BrowserOverlayLayoutPlanner.plan(source: source,
                text: "세로 문장을 이미지 영역 안에서 자동으로 맞춥니다", vertical: false,
                settings: settings, viewport: viewport, occupied: [], sourceVertical: true)
        }
        let expected = layout(original)
        for policy in ["sourceBounds", "unrestricted", "panelConstrained"] {
            legacy["fontSizing"] = "fixed"
            legacy["fixedFontSizePoints"] = 64
            legacy["expansionPolicy"] = policy
            let data = try JSONSerialization.data(withJSONObject: legacy)
            let restored = try JSONDecoder().decode(IPhoneOverlaySettings.self, from: data)
            #expect(restored == original)
            let actual = layout(restored)
            #expect(actual.rect == expected.rect)
            #expect(actual.maximumFontSize == expected.maximumFontSize)
            #expect(CGRect(origin: .zero, size: viewport).contains(actual.rect))
            let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
            #expect(saved["fontSizing"] == nil)
            #expect(saved["fixedFontSizePoints"] == nil)
            #expect(saved["expansionPolicy"] == nil)
        }
    }

    @Test func appearanceSelectionUpdatesSourceColorsAndPaletteTogether() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.appearance = .source
        #expect(settings.preserveSourceTextColor && settings.preserveSourceBackgroundColor)
        #expect(settings.usesSourceInpainting)
        for appearance in [IPhoneOverlayAppearance.white, .dark] {
            settings.appearance = appearance
            #expect(!settings.preserveSourceTextColor && !settings.preserveSourceBackgroundColor)
            #expect(!settings.usesSourceInpainting)
            let restored = try JSONDecoder().decode(IPhoneOverlaySettings.self, from: JSONEncoder().encode(settings))
            #expect(restored.appearance == appearance)
            #expect(restored.colorMode == settings.colorMode)
        }
        settings.appearance = .source
        let restored = try JSONDecoder().decode(IPhoneOverlaySettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.appearance == .source)
        #expect(restored.usesSourceInpainting)
    }


    @Test func retiredAutomaticPaletteMigratesToWhiteWithoutResettingOtherSettings() throws {
        var original = ReaderTranslationSettings.defaultOverlay
        original.opacity = 0.42
        original.inpaintingEnabled = false
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy["colorMode"] = "auto"
        let restored = try JSONDecoder().decode(IPhoneOverlaySettings.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored == original)
        #expect(restored.appearance == .white)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        #expect(saved["colorMode"] as? String == "white")
    }

}
