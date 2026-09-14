import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

struct ReaderTranslationPanelIntegrationTests {
    @Test func explicitDirectionChangesRequestOrderButPreservesRegionMapping() {
        let name = "panel-order-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        var regions = (0..<3).map { ReaderTranslationRegion(id: "r\($0)", rect: .init(x: 0, y: 0, width: 0.1, height: 0.1), source: "台詞\($0)") }
        regions[0].translationOrder = 1; regions[1].translationOrder = 0; regions[2].translationOrder = 2
        #expect(ReaderTranslationService.plans(regions: regions, settings: settings).flatMap(\.request.segments).map(\.id) == ["r0", "r1", "r2"])
        let oldKey = ReaderTranslationCacheIdentity.translation(page: "p", settings: settings)
        let oldOCR = ReaderTranslationCacheIdentity.ocr(page: "p", settings: settings)
        settings.rightToLeftPanelOrder = true
        let plans = ReaderTranslationService.plans(regions: regions, settings: settings)
        #expect(plans.flatMap(\.request.segments).map(\.id) == ["r1", "r0", "r2"])
        #expect(plans.first?.inputIndicesBySegmentID["r1"] == 1)
        #expect(plans.first?.inputIndicesBySegmentID["r0"] == 0)
        #expect(ReaderTranslationCacheIdentity.translation(page: "p", settings: settings) != oldKey)
        #expect(ReaderTranslationCacheIdentity.ocr(page: "p", settings: settings) == oldOCR)
        regions[1].translationOrder = nil
        #expect(ReaderTranslationService.plans(regions: regions, settings: settings).flatMap(\.request.segments).map(\.id) == ["r0", "r1", "r2"])
    }
}
