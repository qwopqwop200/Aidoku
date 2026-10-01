import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativePaintAdmissionSafetyTests {
    @Test func oversizedRasterDimensionsRejectBeforeIntegerMultiplication() throws {
        let image = try #require(NativeRestorationPixels(width: 1, height: 1).image())
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        for (width, height) in [(Int.max, 2), (2, Int.max), (Int.max, Int.max)] {
            #expect(NativeRestorationPixels(image: image, width: width, height: height) == nil)
            #expect(NativeTranslationRenderer.sampleSource(image, rect: rect, frame: rect,
                width: width, height: height) == nil)
        }
    }

    @Test func hugeFinitePolygonClipsToTheSameOwnershipAsAnOrdinaryEnclosingPolygon() throws {
        func polygon(_ extent: CGFloat) -> [CGPoint] {
            [CGPoint(x: -extent, y: -extent), CGPoint(x: extent, y: -extent),
             CGPoint(x: extent, y: extent), CGPoint(x: -extent, y: extent)]
        }
        let bounded = try #require(NativeSourceGlyphSegmentation.geometryMask(width: 16, height: 16,
            polygons: [polygon(32)]))
        let huge = try #require(NativeSourceGlyphSegmentation.geometryMask(width: 16, height: 16,
            polygons: [polygon(1e30)]))
        #expect(huge.mask == bounded.mask && huge.core == bounded.core)
        #expect(huge.core == Array(repeating: 1, count: 256))
    }

    @Test func offCanvasBoxesRejectBeforeUnsafeConversions() {
        let rgba = Array(repeating: UInt8(255), count: 16 * 16 * 4)
        let palette = NativeSourceGlyphSegmentation.Palette(foreground: [0, 0, 0], background: [255, 255, 255])
        for origin in [CGFloat(1e30), CGFloat(-1e30)] {
            let box = CGRect(x: origin, y: origin, width: 20, height: 60)
            #expect(NativeSourceGlyphSegmentation.forcedTextMask(rgba: rgba, width: 16, height: 16,
                box: box, palette: palette) == nil)
            #expect(NativeSourceGlyphSegmentation.inferVerticalRuby(raw: Array(repeating: 0, count: 256),
                rgba: rgba, width: 16, height: 16, box: box, background: [255, 255, 255]).isEmpty)
        }
    }

    @Test func malformedOutlineBackgroundRejectsBeforeRGBDistance() throws {
        let width = 32, height = 24
        var rgba = Array(repeating: UInt8(255), count: width * height * 4)
        for left in [5, 17] {
            for y in 8...10 {
                for x in left...(left + 2) {
                    for channel in 0..<3 { rgba[(y * width + x) * 4 + channel] = 0 }
                }
            }
        }
        let box = CGRect(x: 3, y: 3, width: 23, height: 16)
        let valid = NativeSourceGlyphSegmentation.Palette(foreground: [0, 0, 0],
            background: [255, 255, 255], stroke: [200, 200, 200])
        _ = try #require(NativeSourceGlyphSegmentation.forcedTextMask(rgba: rgba, width: width,
            height: height, box: box, palette: valid))
        let malformed = NativeSourceGlyphSegmentation.Palette(foreground: [0, 0, 0],
            background: [255], stroke: [200, 200, 200])
        #expect(NativeSourceGlyphSegmentation.forcedTextMask(rgba: rgba, width: width,
            height: height, box: box, palette: malformed) == nil)
    }
}
