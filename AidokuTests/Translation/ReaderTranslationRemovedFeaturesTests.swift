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
        let settings = ReaderTranslationSettings(defaults: defaults)
        #expect(!settings.configuration.instructions.contains("AIDOKU_SKIP"))
        #expect(!settings.configuration.instructions.contains("attached page image"))
        let regions = ["ガチャ", "ああ", "今日は晴れ"].enumerated().map {
            ReaderTranslationRegion(id: String($0.offset), rect: CGRect(x: 0.1, y: Double($0.offset) * 0.2, width: 0.1, height: 0.1), source: $0.element)
        }
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
}
