import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderInpaintingTests {
    @Test func retiredSwitchFollowsSourceAppearanceOnLoadAndSave() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = ReaderTranslationSettings.defaultOverlay
        legacy.appearance = .source
        legacy.inpaintingEnabled = false
        legacy.opacity = 0.65
        defaults.set(try JSONEncoder().encode(legacy), forKey: ReaderTranslationSettings.keyPrefix + "overlay")
        var settings = ReaderTranslationSettings(defaults: defaults)
        #expect(settings.overlay.usesSourceInpainting)
        #expect(settings.overlay.opacity == 0.65)
        settings.overlay.inpaintingEnabled = false
        try settings.save(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).overlay.usesSourceInpainting)
    }

    @Test func settingsGateDefaultsAndLegacyDecoding() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        #expect(settings.inpaintingEnabled)
        #expect(!settings.usesSourceInpainting)
        settings.preserveSourceTextColor = true
        #expect(!settings.usesSourceInpainting)
        settings.preserveSourceColors = true
        #expect(settings.usesSourceInpainting)
        settings.inpaintingEnabled = false
        #expect(!settings.usesSourceInpainting)
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(IPhoneOverlaySettings.self, from: encoded) == settings)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "inpaintingEnabled")
        let decoded = try JSONDecoder().decode(IPhoneOverlaySettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.usesSourceInpainting)
        settings.preserveSourceColors = false
        #expect(!settings.preserveSourceTextColor && !settings.preserveSourceBackgroundColor)
    }

    @Test func inpaintingChangesRenderIdentityOnly() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.overlay.preserveSourceColors = true
        let ocr = ReaderTranslationCacheIdentity.ocr(page: "page", settings: settings)
        let translation = ReaderTranslationCacheIdentity.translation(page: "page", settings: settings)
        func render(_ value: ReaderTranslationSettings) -> String {
            ReaderTranslationCacheIdentity.render(page: "page", settings: value,
                imageSize: CGSize(width: 600, height: 800), viewport: CGSize(width: 430, height: 800),
                scale: 3, aspectFit: true, crop: CGRect(x: 0, y: 0, width: 1, height: 1), dark: false)
        }
        let before = render(settings)
        settings.overlay.inpaintingEnabled = false
        #expect(render(settings) != before)
        #expect(ReaderTranslationCacheIdentity.ocr(page: "page", settings: settings) == ocr)
        #expect(ReaderTranslationCacheIdentity.translation(page: "page", settings: settings) == translation)
    }

    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("InpaintingQuality") }

}
