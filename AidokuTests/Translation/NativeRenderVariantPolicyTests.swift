import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct NativeRenderVariantPolicyTests {
    @Test func defaultsAddNoRenderKeyMaterial() {
        #expect(NativeRenderVariantPolicy.make(font: nil, mask: [:],
            localBoundary: false, supportedContour: false).isEmpty)
        #expect(NativeAcceptedSourceFontInference.cachePolicy == nil)
        #expect(NativeAcceptedSourceFontInference.selectedEstimatorIdentity == "accepted-font198-v1")
        // Projection contract remains generic; this is not an enabled runtime experiment.
        let font = "fixture-font-policy"
        let policies = [
            NativeRenderVariantPolicy.make(font: font, mask: [:], localBoundary: false, supportedContour: false),
            NativeRenderVariantPolicy.make(font: nil,
                mask: ["originalMaskChromaticFringePolicy": "source-color-connected-component-fringe-v1"],
                localBoundary: false, supportedContour: false),
            NativeRenderVariantPolicy.make(font: nil,
                mask: ["sourceBackedRFProtectionPolicy": "selected-primary-rgb-over-estimated-rf-v1"],
                localBoundary: false, supportedContour: false),
            NativeRenderVariantPolicy.make(font: nil, mask: [:], localBoundary: true, supportedContour: false),
            NativeRenderVariantPolicy.make(font: nil, mask: [:], localBoundary: false, supportedContour: true)
        ]
        #expect(policies.allSatisfy { !$0.isEmpty })
        #expect(Set(policies.map(ReaderTranslationCacheIdentity.encoded)).count == policies.count)
    }

    @Test func contourVariantsChangeRenderButNotOCRorProviderIdentity() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        func identities() -> [String] {
            [ReaderTranslationCacheIdentity.ocr(page: "variants", settings: settings),
             ReaderTranslationCacheIdentity.translation(page: "variants", settings: settings),
             ReaderTranslationCacheIdentity.render(page: "variants", settings: settings,
                imageSize: CGSize(width: 100, height: 100), viewport: CGSize(width: 100, height: 100),
                scale: 1, aspectFit: true, crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                dark: false, letteringFontKey: "variant-policy-font")]
        }
        let established = EnsembleCandidate03.withLocalRFBoundarySupport(false) {
            NativeEnsembleLayoutContour.withSupportedEstimatedContour(false) { identities() }
        }
        let supported = EnsembleCandidate03.withLocalRFBoundarySupport(true) {
            NativeEnsembleLayoutContour.withSupportedEstimatedContour(true) { identities() }
        }
        #expect(established[0] == supported[0])
        #expect(established[1] == supported[1])
        #expect(established[2] != supported[2])
    }

    @Test func simpleTypesettingSeparatesRenderedCacheWithoutRepeatingOCRorProvider() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        func identities() -> [String] {
            [ReaderTranslationCacheIdentity.ocr(page: "simple-typesetting", settings: settings),
             ReaderTranslationCacheIdentity.translation(page: "simple-typesetting", settings: settings),
             ReaderTranslationCacheIdentity.render(page: "simple-typesetting", settings: settings,
                imageSize: CGSize(width: 100, height: 100), viewport: CGSize(width: 100, height: 100),
                scale: 1, aspectFit: true, crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                dark: false, letteringFontKey: "variant-policy-font")]
        }
        let accepted = NativeSimpleTextLayout.withEnabled(false) {
            #expect(NativeRenderVariantPolicy.projection["simpleTextLayout"] == nil)
            return identities()
        }
        let simple = NativeSimpleTextLayout.withEnabled(true) { identities() }
        #expect(accepted[0] == simple[0])
        #expect(accepted[1] == simple[1])
        #expect(accepted[2] != simple[2])
        NativeSimpleTextLayout.withEnabled(true) {
            #expect(NativeRenderVariantPolicy.projection["simpleTextLayout"] == NativeSimpleTextLayout.version)
        }
    }

    @Test func selectedSimpleDefaultKeepsExplicitLegacyOverrideScoped() {
        let expectedDefault = ProcessInfo.processInfo.environment["AIDOKU_SIMPLE_TEXT_LAYOUT"] != "0"
        #expect(NativeSimpleTextLayout.enabled == expectedDefault)
        NativeSimpleTextLayout.withEnabled(false) {
            #expect(!NativeSimpleTextLayout.enabled)
            #expect(NativeRenderVariantPolicy.projection["simpleTextLayout"] == nil)
        }
        #expect(NativeSimpleTextLayout.enabled == expectedDefault)
        NativeSimpleTextLayout.withEnabled(true) {
            #expect(NativeRenderVariantPolicy.projection["simpleTextLayout"] == NativeSimpleTextLayout.version)
        }
        #expect(NativeSimpleTextLayout.enabled == expectedDefault)
    }
}
