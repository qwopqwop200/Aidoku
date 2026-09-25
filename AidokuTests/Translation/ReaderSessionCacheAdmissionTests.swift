import Testing
import UIKit
@testable import Aidoku

@Suite @MainActor
struct ReaderSessionCacheAdmissionTests {
    @Test func nonEvictingReplacementFitsWithoutDoubleCountingExistingBytes() throws {
        let cache = ReaderTranslationSessionCache()
        let source = String(repeating: "a", count: 3 * 1_024 * 1_024)
        let original = ReaderTranslationRegion(id: "line", rect: .zero, source: source, translation: "old")
        try cache.store([original], for: "page")
        let originalBytes = cache.bytes
        var updated = original
        updated.translation = "new"
        try cache.store([updated], for: "page", evict: false)
        #expect(cache.regions(for: "page")?.first?.translation == "new")
        #expect(cache.bytes == originalBytes)
    }

    @Test func nonEvictingReplacementWorksAtEntryLimitWithoutEvictingOtherPages() throws {
        let cache = ReaderTranslationSessionCache()
        for index in 0..<64 { try cache.store([], for: String(index)) }
        let region = ReaderTranslationRegion(id: "line", rect: .zero, source: "hello", translation: "translated")
        try cache.store([region], for: "0", evict: false)
        #expect(cache.regions(for: "0") == [region])
        #expect((0..<64).allSatisfy { cache.contains(String($0)) })
        try cache.store([], for: "overflow", evict: false)
        #expect(!cache.contains("overflow"))
    }

    @Test func rejectedReplacementPreservesExistingValue() throws {
        let cache = ReaderTranslationSessionCache()
        let original = ReaderTranslationRegion(id: "line", rect: .zero, source: "hello", translation: "saved")
        try cache.store([original], for: "page")
        let originalBytes = cache.bytes
        var oversized = original
        oversized.translation = String(repeating: "x", count: ReaderTranslationSessionCache.byteLimit)
        try cache.store([oversized], for: "page", evict: false)
        #expect(cache.regions(for: "page") == [original])
        #expect(cache.bytes == originalBytes)
    }

    @Test(arguments: ["id", "order", "rects", "polygons", "identity"])
    func oversizedRetainedMetadataCannotBypassTheWorkingSetBudget(field: String) throws {
        let cache = ReaderTranslationSessionCache()
        let saved = ReaderTranslationRegion(id: "line", rect: .zero, source: "hello", translation: "saved")
        try cache.store([saved], for: "page")
        let bytes = cache.bytes
        let limit = ReaderTranslationSessionCache.byteLimit
        var oversized = saved
        switch field {
        case "id": oversized = ReaderTranslationRegion(id: String(repeating: "x", count: limit), rect: .zero, source: "")
        case "order": oversized.translationOrderVersion = String(repeating: "x", count: limit)
        case "rects": oversized.auxiliaryInkRects = Array(repeating: .zero, count: limit / MemoryLayout<CGRect>.stride)
        case "polygons": oversized.auxiliaryInkPolygons = [Array(repeating: .zero, count: limit / MemoryLayout<CGPoint>.stride)]
        default: oversized.translationReuseIdentity = Self.identity(contextBytes: limit)
        }
        try cache.store([oversized], for: "page")
        #expect(cache.regions(for: "page") == [saved])
        #expect(cache.bytes == bytes)
    }

    @Test func sharedBatchIdentityIsChargedOnceAndMetadataSurvivesRoundTrip() throws {
        let cache = ReaderTranslationSessionCache()
        let identity = Self.identity(contextBytes: 256 * 1_024)
        var region = ReaderTranslationRegion(id: "line", rect: .zero, source: "hello", translation: "saved")
        region.translationReuseIdentity = identity
        region.auxiliaryInkRects = [CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.1)]
        region.auxiliaryInkPolygons = [[CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.2, y: 0.3)]]
        let regions = Array(repeating: region, count: 32)
        try cache.store(regions, for: "page")
        #expect(cache.regions(for: "page") == regions)
        #expect(cache.bytes >= 256 * 1_024)
        #expect(cache.bytes < 512 * 1_024)
    }

    @Test func splitCacheGeometryPreservesCrossingInkPolygonsAndDropsOutsideInk() throws {
        let crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let crossing = [CGPoint(x: 0.45, y: 0.2), CGPoint(x: 0.6, y: 0.2), CGPoint(x: 0.6, y: 0.3)]
        let outside = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.2, y: 0.3)]
        let inside = [CGPoint(x: 0.7, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.8, y: 0.3)]
        var region = ReaderTranslationRegion(id: "line", rect: CGRect(x: 0.4, y: 0.1, width: 0.4, height: 0.3),
                                             source: "hello", translation: "saved")
        region.polygon = crossing
        region.auxiliaryInkPolygons = [crossing, outside, inside, []]
        let original = region
        let cropped = try #require(region.cropped(to: crop))
        let transformed = [crossing, inside].map { polygon in
            polygon.map { CGPoint(x: ($0.x - crop.minX) / crop.width, y: $0.y) }
        }
        #expect(cropped.auxiliaryInkPolygons == transformed)
        #expect(cropped.polygon == transformed[0])
        #expect(cropped.auxiliaryInkPolygons[0][0].x < 0, "Canvas clipping must preserve the crossing edge's original shape")
        #expect(cropped.rect.minX == 0)
        #expect(cropped.rect.maxX <= 1)
        #expect(region == original)
        #expect(region.cropped(to: .zero) == nil)
    }

    private static func identity(contextBytes: Int) -> NativeTranslationReuseIdentity {
        let endpoint = URL(string: "https://example.invalid/v1")!
        let configuration = RemoteTranslationConfiguration(provider: .openAI, apiProtocol: .chatCompletions,
            baseURL: endpoint.absoluteString, model: "fixture", credentialAccount: "fixture")
        let request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", sourceText: "hello",
            context: [String(repeating: "x", count: contextBytes)])
        return NativeTranslationReuseIdentity(cacheKey: TranslationCacheKey(configuration: configuration,
            endpoint: endpoint, request: request), segmentID: RemoteTranslationRequest.singleSegmentID)
    }

}
