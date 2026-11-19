import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct BrowserOverlayMeasurementCacheTests {

    @Test @MainActor func measurementStringReusePreservesWrappingAndCompleteLayout() throws {
        let variants: [BrowserOverlayDisplayVariant] = [
            .plain("정말로이렇게길게붙여쓴대사도괜찮을까", vertical: false),
            .plain("너무 늦었어. 지금이라도 돌아가야 해!", vertical: false),
            .plain("明日はきっと大丈夫。", vertical: true),
            .plain("Supercalifragilisticexpialidocious!", vertical: false),
            .init(content: .originalAndTranslation(source: "明日は大丈夫", translation: "내일은 괜찮을 거야", separator: "\n"), vertical: false)
        ]
        let cache = BrowserOverlayTextMeasurementCache()
        for variant in variants {
            for font: CGFloat in [6, 8, 11, 16, 22] {
                let boundary = variant.minimumUnbrokenWidth(fontSize: font)
                for width: CGFloat in [8, 30, 55, 100, 190, boundary - 0.51, boundary - 0.49] where width > 0 {
                    let reference = variant.measuredSize(width: width, fontSize: font)
                    #expect(variant.measuredSize(width: width, fontSize: font, measurementCache: cache) == reference)
                }
            }
        }
        #expect(cache.measurementStringHits > 0)
        let items = (0..<12).map { index in
            BrowserOverlayItem(rect: CGRect(x: 40 + index % 3 * 250, y: 40 + index / 3 * 260, width: 170, height: 180),
                sourceText: "明日はきっと大丈夫だから", translatedText: "내일은 분명 괜찮을 테니까. \(index)",
                confidence: 1, sourceOrientation: .vertical)
        }
        for mode in [ReaderTranslationSettings.defaultOverlay.mode, .originalAndTranslation] {
            var settings = ReaderTranslationSettings.defaultOverlay
            settings.mode = mode
            func run(_ reuse: Bool) throws -> (payload: Data, hits: Int) {
                let cache = BrowserOverlayTextMeasurementCache(reusesMeasurementStrings: reuse)
                let result = NativeTranslationLayoutPlanner.payload(items: items,
                    imageSize: CGSize(width: 800, height: 1200), sourceRect: CGRect(x: 0, y: 0, width: 390, height: 585),
                    settings: settings, targetLanguage: "ko", viewport: CGSize(width: 390, height: 780), measurementCache: cache)
                return (try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), cache.measurementStringHits)
            }
            let reference = try run(false), optimized = try run(true)
            #expect(reference.hits == 0)
            #expect(optimized.payload == reference.payload)
        }
    }
}
