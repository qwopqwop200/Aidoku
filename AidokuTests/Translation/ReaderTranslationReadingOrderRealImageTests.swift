import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Opt-in local-image integration test. No translation provider or LLM is used.
@Suite(.serialized)
@MainActor
struct ReaderTranslationReadingOrderRealImageTests {
    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("ReadingOrder") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("run.json").path)))
    func realOCRPreservesRegionIdentityAndProducesReadingOrder() async throws {
        let folder = Self.directory
        let fixtures = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("run.json"))) as? [[String: String]])
        let suite = "ReadingOrderRealImages." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.rightToLeftPanelOrder = true
        settings.filterJapaneseSFX = false
        settings.filterJapaneseSFXContext = false
        for fixture in fixtures {
            let name = try #require(fixture["file"])
            let image = try #require(UIImage(contentsOfFile: folder.appendingPathComponent(name).path))
            let pixels = try #require(image.cgImage)
            let regions = try await ReaderOCRService.shared.recognize(image: pixels, configuration: ReaderOCRConfiguration())
            #expect(!regions.isEmpty || fixture["allowEmptyOCR"] == "true", "Unexpected empty OCR: \(name)")
            let inputs = regions.map { ReaderTranslationPanelOrder.Input(rect: $0.rect, isVertical: $0.sourceOrientation == .vertical) }
            let start = Date()
            let ranks = ReaderTranslationPanelOrder.rightToLeftRanks(image: pixels, inputs: inputs)
            let elapsed = Date().timeIntervalSince(start) * 1000
            #expect(ranks.count == regions.count)
            #expect(Set(ranks) == Set(regions.indices))
            let prepared = ReaderTranslationImagePreparation.apply(regions, image: image, settings: settings)
            #expect(prepared.map(\.id) == regions.map(\.id))
            #expect(prepared.map(\.rect) == regions.map(\.rect))
            #expect(prepared.map(\.source) == regions.map(\.source))
            if regions.count > 1 { #expect(prepared.compactMap(\.translationOrder) == ranks) }
            var leftToRight = settings
            leftToRight.rightToLeftPanelOrder = false
            #expect(ReaderTranslationImagePreparation.apply(regions, image: image, settings: leftToRight)
                .map(\.translationOrder) == regions.map(\.translationOrder))
            let records: [[String: Any]] = zip(regions, ranks).map { region, rank in
                ["id": region.id, "x": Double(region.rect.minX), "y": Double(region.rect.minY),
                 "w": Double(region.rect.width), "h": Double(region.rect.height),
                 "vertical": region.sourceOrientation == .vertical, "text": region.source, "rank": rank]
            }
            let result: [String: Any] = ["id": fixture["id"] ?? name, "boxes": records, "ranks": ranks,
                "milliseconds": elapsed, "language": fixture["language"] ?? "unknown", "file": name]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent(name + ".json"))
        }
    }
}
