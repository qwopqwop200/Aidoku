import Testing
import UIKit
@testable import Aidoku

struct ReaderTranslationBalloonMergerTests {
    private func image(_ boxes: [CGRect]) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 400, height: 400,
            bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(4)
        for box in boxes { context.stroke(box) }
        return try #require(context.makeImage())
    }
    private var columns: [ReaderTranslationRegion] {
        [ReaderTranslationRegion(id: "right", rect: CGRect(x: 0.51, y: 0.4, width: 0.05, height: 0.2),
            source: "明日の", sourceImageAspectRatio: 1, sourceOrientation: .vertical),
         ReaderTranslationRegion(id: "left", rect: CGRect(x: 0.42, y: 0.4, width: 0.05, height: 0.2),
            source: "予定は？", sourceImageAspectRatio: 1, sourceOrientation: .vertical)]
    }
    @Test func joinsEnclosedColumnsInJapaneseOrder() throws {
        let result = ReaderTranslationBalloonMerger.apply(columns,
            image: try image([CGRect(x: 145, y: 135, width: 100, height: 130)]))
        #expect(result.count == 1)
        #expect(result.first?.source == "明日の予定は？")
        #expect(result.first?.id == "right")
    }
    @Test func separateBalloonsAndOpenBackgroundDoNotJoin() throws {
        #expect(ReaderTranslationBalloonMerger.apply(columns, image: try image([])).count == 2)
        #expect(ReaderTranslationBalloonMerger.apply(columns, image: try image([
            CGRect(x: 158, y: 140, width: 38, height: 120),
            CGRect(x: 198, y: 140, width: 38, height: 120)])).count == 2)
    }
    @Test func interveningUnclassifiedColumnPreventsJoining() throws {
        var input = columns
        input.append(.init(id: "middle", rect: CGRect(x: 0.48, y: 0.42, width: 0.02, height: 0.1),
            source: "別の文", sourceImageAspectRatio: 1, sourceOrientation: .unknown))
        #expect(ReaderTranslationBalloonMerger.apply(input,
            image: try image([CGRect(x: 145, y: 135, width: 100, height: 130)])).count == 3)
    }
    @Test func tinyRubyColumnDoesNotJoin() throws {
        var input = columns
        input[1] = ReaderTranslationRegion(id: "ruby", rect: CGRect(x: 0.42, y: 0.4, width: 0.015, height: 0.2),
            source: "よてい", sourceImageAspectRatio: 1, sourceOrientation: .vertical)
        #expect(ReaderTranslationBalloonMerger.apply(input,
            image: try image([CGRect(x: 145, y: 135, width: 100, height: 130)])).count == 2)
    }
    @Test func brightBridgeJoinsMixedColumnBlocksButDarkRuleDoesNot() throws {
        let right = ReaderTranslationRegion(id: "right", rect: CGRect(x: 0.45, y: 0.3, width: 0.1, height: 0.2), source: "明日の予定を", sourceImageAspectRatio: 1, sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
        let left = ReaderTranslationRegion(id: "left", rect: CGRect(x: 0.4, y: 0.32, width: 0.051, height: 0.25), source: "教えてください", sourceImageAspectRatio: 1, sourceOrientation: .vertical, sourceSingleVerticalColumn: true)
        #expect(ReaderTranslationBalloonMerger.apply([right, left], image: try image([])).count == 1)
        #expect(ReaderTranslationBalloonMerger.apply([right, left], image: try image([CGRect(x: 178, y: 80, width: 3, height: 200)])).count == 2)
    }

}
