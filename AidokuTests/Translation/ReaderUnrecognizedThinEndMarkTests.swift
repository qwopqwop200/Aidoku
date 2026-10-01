import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct ReaderUnrecognizedThinEndMarkTests {
    private enum Mark: Equatable { case valid, wide, borderConnected, secondStroke, differentColor, absent }
    private func image(_ mark: Mark) throws -> CGImage {
        let width = 300, height = 300
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        func fill(_ box: CGRect, color: [UInt8]) {
            for y in Int(box.minY)..<Int(box.maxY) { for x in Int(box.minX)..<Int(box.maxX) {
                let p = (y * width + x) * 4
                for c in 0..<3 { bytes[p + c] = color[c] }
            } }
        }
        let pink: [UInt8] = [220, 20, 120]
        for (x, ys) in [(95, [52, 65, 80, 97]), (150, [54, 70, 86, 105, 124, 142]), (205, [56, 72, 88, 107, 126, 141])] {
            for y in ys { fill(CGRect(x: x, y: y, width: 20, height: 6), color: pink) }
        }
        if mark != .absent {
            let box: CGRect = mark == .wide ? CGRect(x: 97, y: 113, width: 16, height: 77)
                : mark == .borderConnected ? CGRect(x: 104, y: 82, width: 3, height: 140)
                : CGRect(x: 104, y: 113, width: 3, height: 77)
            fill(box, color: mark == .differentColor ? [20, 80, 220] : pink)
            if mark == .secondStroke { fill(CGRect(x: 112, y: 113, width: 3, height: 77), color: pink) }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func normalized(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX / 300, y: box.minY / 300, width: box.width / 300, height: box.height / 300)
    }
    private var source: ReaderTranslationRegion {
        var region = ReaderTranslationRegion(id: "caption", rect: normalized(CGRect(x: 80, y: 40, width: 160, height: 130)),
            source: "これは例文です", confidence: 0.95, sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
        region.auxiliaryInkRects = [CGRect(x: 95, y: 50, width: 20, height: 60),
            CGRect(x: 150, y: 52, width: 20, height: 100), CGRect(x: 205, y: 54, width: 20, height: 95)].map(normalized)
        region.auxiliaryInkPolygons = region.auxiliaryInkRects.map { b in
            [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
        }
        region.balloonInterior = .init(rect: CGRect(x: 0.2, y: 0.05, width: 0.65, height: 0.8),
            center: CGPoint(x: 0.5, y: 0.4), spans: (0..<32).flatMap { _ in [0.2, 0.85] }, contourVerified: true)
        return region
    }

    @Test func measuredStrokeExtendsInkWithoutInventingTextOrGrowingTheCaption() throws {
        let pixels = try image(.valid), original = source
        let result = ReaderTranslationChromaticBalloon.attachingUnrecognizedThinEndMarks([original], image: pixels)
        #expect(result.count == 1)
        #expect(result[0].source == original.source)
        #expect(result[0].rect == original.rect)
        #expect(result[0].confidence == original.confidence)
        try #require(result[0].auxiliaryInkRects.count == 4)
        let stroke = try #require(result[0].auxiliaryInkRects.last)
        #expect(stroke.intersects(normalized(CGRect(x: 104, y: 113, width: 3, height: 77))))
        #expect(stroke.maxY >= 185.0 / 300)
        #expect(stroke.width <= 5.0 / 300)
        #expect(ReaderTranslationChromaticBalloon.attachingUnrecognizedThinEndMarks(result, image: pixels) == result)
    }

    @Test func auxiliaryInkLimitIncludesTheNewMeasuredStroke() throws {
        let pixels = try image(.valid)
        let unrelated = normalized(CGRect(x: 1, y: 1, width: 1, height: 1))
        let polygon = [CGPoint(x: unrelated.minX, y: unrelated.minY), CGPoint(x: unrelated.maxX, y: unrelated.minY),
            CGPoint(x: unrelated.maxX, y: unrelated.maxY), CGPoint(x: unrelated.minX, y: unrelated.maxY)]
        var belowLimit = source
        belowLimit.auxiliaryInkRects += Array(repeating: unrelated, count: 60)
        belowLimit.auxiliaryInkPolygons += Array(repeating: polygon, count: 60)
        try #require(belowLimit.auxiliaryInkRects.count == 63)
        let recovered = ReaderTranslationChromaticBalloon.attachingUnrecognizedThinEndMarks([belowLimit], image: pixels)
        #expect(recovered[0].auxiliaryInkRects.count == 64)
        var atLimit = belowLimit
        atLimit.auxiliaryInkRects.append(unrelated)
        atLimit.auxiliaryInkPolygons.append(polygon)
        try #require(atLimit.auxiliaryInkRects.count == 64)
        #expect(ReaderTranslationChromaticBalloon.attachingUnrecognizedThinEndMarks([atLimit], image: pixels) == [atLimit])
    }

    @Test func artworkRulesAndUnsupportedContextsStayUnchanged() throws {
        let original = source
        for mark in [Mark.absent, .wide, .borderConnected, .secondStroke, .differentColor] {
            #expect(try ReaderTranslationChromaticBalloon.attachingUnrecognizedThinEndMarks([original], image: image(mark)) == [original])
        }
        let pixels = try image(.valid)
        var missingColumn = original; missingColumn.auxiliaryInkRects.removeLast()
        #expect(ReaderTranslationChromaticBalloon.attachingUnrecognizedThinEndMarks([missingColumn], image: pixels) == [missingColumn])
        var noContour = original; noContour.balloonInterior?.contourVerified = false
        #expect(ReaderTranslationChromaticBalloon.attachingUnrecognizedThinEndMarks([noContour], image: pixels) == [noContour])
        var weak = original; weak.confidence = 0.79
        #expect(ReaderTranslationChromaticBalloon.attachingUnrecognizedThinEndMarks([weak], image: pixels) == [weak])
        var blocked = original
        blocked.balloonInterior = .init(rect: original.balloonInterior!.rect, center: original.balloonInterior!.center,
            spans: (0..<32).flatMap { _ in [0.4, 0.85] }, contourVerified: true)
        #expect(ReaderTranslationChromaticBalloon.attachingUnrecognizedThinEndMarks([blocked], image: pixels) == [blocked])
        var staggered = original
        staggered.auxiliaryInkRects[1].origin.y += 0.1
        #expect(ReaderTranslationChromaticBalloon.attachingUnrecognizedThinEndMarks([staggered], image: pixels) == [staggered])
        let foreign = ReaderTranslationRegion(id: "other", rect: normalized(CGRect(x: 102, y: 145, width: 8, height: 20)), source: "別")
        #expect(ReaderTranslationChromaticBalloon.attachingUnrecognizedThinEndMarks([original, foreign], image: pixels) == [original, foreign])
    }
}
