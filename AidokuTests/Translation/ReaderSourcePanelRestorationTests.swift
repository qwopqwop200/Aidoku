import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderSourcePanelRestorationTests {
    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("MangaQuality") }

    @Test func restorationRequiresReplacementDisplay() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        func eligible(_ translation: String?) throws -> Bool {
            let item = BrowserOverlayItem(rect: CGRect(x: 30, y: 30, width: 80, height: 200),
                sourceText: "テストです", translatedText: translation, confidence: 1, sourceOrientation: .vertical)
            let payload = try #require(NativeTranslationLayoutPlanner.payload(items: [item],
                imageSize: CGSize(width: 300, height: 400), sourceRect: CGRect(x: 0, y: 0, width: 300, height: 400),
                settings: settings, targetLanguage: "ko", viewport: CGSize(width: 300, height: 400)).first)
            return payload["sourcePanelRestorationEligible"] as? Bool == true
        }
        #expect(try eligible(nil) == true)
        #expect(try eligible("시험이랍니다") == true)
        settings.mode = .originalAndTranslation
        #expect(try eligible("시험이랍니다") == false)
    }

    @Test func suppressedRubyRetainsInkThroughArchiveWithoutMovingBody() throws {
        func line(_ text: String, _ rect: CGRect) -> NativeCoreMLOCRLine {
            NativeCoreMLOCRLine(polygon: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)],
                text: text, score: 0.99, orientation: .vertical, orientationIsEstimated: true)
        }
        let body = line("世界だなって", CGRect(x: 192, y: 873, width: 33, height: 146))
        let ruby = line("わたし", CGRect(x: 218, y: 877, width: 16, height: 50))
        let detached = line("わたし", CGRect(x: 90, y: 877, width: 16, height: 50))
        for input in [[body, ruby, detached], [detached, ruby, body]] {
            let merged = NativeOCRTextLineMerger.merge(input, imageWidth: 1000, imageHeight: 1400)
            let row = try #require(merged.first { $0.text == "世界《わたし》だなって" })
            #expect(row.boundingRect == CGRect(x: 192, y: 873, width: 33, height: 146))
            #expect(row.auxiliaryInkRects == [CGRect(x: 218, y: 877, width: 16, height: 50)])
            #expect(merged.count == 2)
            #expect(try JSONDecoder().decode(PaddleOCRLine.self, from: JSONEncoder().encode(row)) == row)
        }
        var region = ReaderTranslationRegion(id: "ruby", rect: CGRect(x: 0.192, y: 0.623, width: 0.033, height: 0.104),
            source: "世界", translation: "세상")
        region.auxiliaryInkRects = [CGRect(x: 0.218, y: 0.626, width: 0.016, height: 0.036)]
        let archive = try ReaderTranslationRegionArchive([region])
        let restored = try ReaderTranslationRegionArchive.regions(base: archive.base, variant: archive.variant)
        #expect(restored == [region])
        let item = try #require(restored.first).overlayItem(index: 0, imageSize: CGSize(width: 1000, height: 1400))
        #expect(item.auxiliaryInkRects.count == 1)
        let payload = try #require(NativeTranslationLayoutPlanner.payload(items: [item],
            imageSize: CGSize(width: 1000, height: 1400), sourceRect: CGRect(x: 0, y: 0, width: 430, height: 602),
            settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: CGSize(width: 430, height: 602)).first)
        #expect((payload["auxiliaryInkRects"] as? [[CGFloat]])?.count == 1)
    }

}
