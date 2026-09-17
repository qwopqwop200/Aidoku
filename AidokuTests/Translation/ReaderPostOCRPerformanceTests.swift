import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderPostOCRPerformanceTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("OCRDeviceBenchmark/manifest.json").path)))
    func completedBackgroundComponentsPreserveRealPageGroups() throws {
        struct Fixture: Decodable {
            struct Line: Decodable { let polygon: [[CGFloat]] }
            let id: String; let image: String; let lines: [Line]
        }
        let directory = URL.documentsDirectory.appendingPathComponent("OCRDeviceBenchmark")
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        var rows: [[String: Any]] = []
        for fixture in fixtures {
            let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent(fixture.image).path)?.cgImage)
            let inputs = fixture.lines.enumerated().map { index, line in
                let xs = line.polygon.map { $0[0] }, ys = line.polygon.map { $0[1] }
                return ReaderTranslationEnclosedBackground.Input(id: String(index), text: "text",
                    rect: CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
            }
            for alternate in [false, true] {
                var referenceMS = 0.0, optimizedMS = 0.0
                for pass in 0..<6 {
                    var reference: [[String]] = [], optimized: [[String]] = []
                    func run(_ reuse: Bool) -> [[String]] {
                        let start = ProcessInfo.processInfo.systemUptime
                        let result = ReaderTranslationEnclosedBackground.enclosedRegionGroups(in: image,
                            candidateInputs: inputs, coordinateSize: CGSize(width: image.width, height: image.height),
                            checkingAlternateSeeds: alternate, reusingCompletedComponents: reuse)
                        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        if reuse { optimizedMS += elapsed } else { referenceMS += elapsed }
                        return result
                    }
                    if pass % 2 == 0 { reference = run(false); optimized = run(true) }
                    else { optimized = run(true); reference = run(false) }
                    #expect(reference == optimized, "Grouping changed for \(fixture.id)")
                }
                rows.append(["id": fixture.id, "alternate": alternate, "referenceMS": referenceMS, "optimizedMS": optimizedMS])
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("post-ocr-background.json"), options: .atomic)
        print("BACKGROUND_BENCH reference_ms=\(rows.reduce(0.0) { $0 + ($1["referenceMS"] as! Double) }) optimized_ms=\(rows.reduce(0.0) { $0 + ($1["optimizedMS"] as! Double) })")
    }

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
        var referenceMS = 0.0, optimizedMS = 0.0, hits = 0
        for pass in 0..<8 {
            var settings = ReaderTranslationSettings.defaultOverlay
            if pass % 2 == 1 { settings.mode = .originalAndTranslation }
            func run(_ reuse: Bool) -> [[String: Any]] {
                let cache = BrowserOverlayTextMeasurementCache(reusesMeasurementStrings: reuse)
                let start = ProcessInfo.processInfo.systemUptime
                let result = BrowserPageImageOverlayRenderer.layoutPayload(items: items,
                    imageSize: CGSize(width: 800, height: 1200), sourceRect: CGRect(x: 0, y: 0, width: 390, height: 585),
                    settings: settings, targetLanguage: "ko", viewport: CGSize(width: 390, height: 780), measurementCache: cache)
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                if reuse { optimizedMS += elapsed; hits += cache.measurementStringHits } else { referenceMS += elapsed }
                return result
            }
            let reference: [[String: Any]], optimized: [[String: Any]]
            if pass % 2 == 0 { reference = run(false); optimized = run(true) }
            else { optimized = run(true); reference = run(false) }
            #expect(try JSONSerialization.data(withJSONObject: reference, options: [.sortedKeys]) ==
                JSONSerialization.data(withJSONObject: optimized, options: [.sortedKeys]))
        }
        let summary: [String: Any] = ["referenceMS": referenceMS, "optimizedMS": optimizedMS, "attributeHits": hits]
        try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            .write(to: URL.documentsDirectory.appendingPathComponent("post-ocr-layout.json"), options: .atomic)
        print("ATTRIBUTE_LAYOUT_BENCH reference_ms=\(referenceMS) optimized_ms=\(optimizedMS) hits=\(hits)")
    }
}
