import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

/// Degenerate geometry and size regressions for the S6/S8/S9 pixel stages.
struct V2ImageRobustnessTests {
    private func block(_ polygon: [CGPoint], bounds: CGRect) -> V2Block {
        let line = V2Line(polygon: polygon, bounds: bounds, vertical: false, detectionScore: 1)
        return V2Block(id: 0, lines: [line], bounds: bounds, polygon: polygon, vertical: false, readingOrder: 0,
                       sourceText: "가나다", balloon: nil)
    }

    private func checkerImage(width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where (x / 3 + y / 3) % 2 == 0 {
                let i = (y * width + x) * 4
                pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0
            }
        }
        return pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    @Test func removalMaskIgnoresHugeNonFiniteAndOffPagePolygons() {
        let width = 300, height = 200
        let rgba = [UInt8](repeating: 255, count: width * height * 4)
        let blocks = [
            // Int(floor(-1e300)) used to trap while computing the block frame.
            block([CGPoint(x: -1e300, y: 50), CGPoint(x: 1e300, y: 50), CGPoint(x: 1e300, y: 150)],
                  bounds: CGRect(x: 0, y: 0, width: 1e300, height: 1e300)),
            block(V2RemovalMask.corners(CGRect(x: -500, y: -500, width: 10, height: 10)), bounds: .zero),
            block([CGPoint(x: CGFloat.nan, y: 1), CGPoint(x: 2, y: 3), CGPoint(x: 4, y: 9)], bounds: .null)
        ]
        let mask = V2RemovalMask.build(rgba: rgba, width: width, height: height, blocks: blocks, layout: [])
        #expect(mask.count == width * height)
        #expect(mask.allSatisfy { $0 == 0 })
        #expect(V2RemovalMask.build(rgba: [], width: -3, height: 5, blocks: blocks, layout: []).isEmpty)
    }

    @Test func oversizedBlockFrameFallsBackToDilatedPolygons() {
        // A 2000 px square line: its padded frame exceeds `maximumBlockPixels`, which the
        // classifier would turn into a multi-GB allocation.
        let width = 2400, height = 2400
        let rect = CGRect(x: 100, y: 100, width: 2000, height: 2000)
        let big = block(V2RemovalMask.corners(rect), bounds: rect)
        let geometry = V2RemovalMask.geometry(big, width: width, height: height)
        #expect((geometry?.frame.pixels ?? 0) > V2RemovalMask.maximumBlockPixels)
        let rgba = [UInt8](repeating: 255, count: width * height * 4)
        let mask = V2RemovalMask.build(rgba: rgba, width: width, height: height, blocks: [big], layout: [])
        let dilation = V2RemovalMask.outputDilation
        // Pixel centres 100...2100 inside the polygon, dilated by `outputDilation` on every side.
        let side = 2001 + 2 * dilation
        #expect(mask.reduce(0) { $0 + ($1 != 0 ? 1 : 0) } == side * side)
        #expect(mask[(100 - dilation) * width + 100 - dilation] == 255)
        #expect(mask[(100 - dilation - 1) * width + 100] == 0)
    }

    @Test func styleSkipsCropsWithoutExteriorAndNonFiniteBounds() throws {
        let image = try #require(checkerImage(width: 200, height: 200))
        let page = V2Page(id: "robustness", image: image)
        // Line polygon covers the whole crop: no exterior pixel, which used to request a
        // histogram of Int32.max entries.
        let cover = [CGPoint(x: -50, y: -50), CGPoint(x: 250, y: -50), CGPoint(x: 250, y: 250), CGPoint(x: -50, y: 250)]
        let blocks = [
            block(cover, bounds: CGRect(x: 50, y: 50, width: 40, height: 40)),
            block(cover, bounds: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)),
            block([CGPoint(x: 0, y: 0), CGPoint(x: 1e300, y: 0), CGPoint(x: 1e300, y: 1e300)],
                  bounds: CGRect(x: 0, y: 0, width: 1e300, height: 1e300))
        ]
        let styled = V2Style.estimate(page, blocks: blocks)
        #expect(styled.count == 3)
        #expect(styled.allSatisfy { $0.style != nil })
    }

    @Test func longWordCaretOffsetsMatchPerIndexQueries() {
        let word = String(repeating: "가나다e\u{301}😀", count: 60)
        let font = V2Layout.font(size: V2Layout.referenceSize)
        let measured = V2Layout.MeasuredText(word, font: font)
        let offsets = measured.paragraphs[0][0].offsets
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]))
        var expected: [CGFloat] = [0]
        var location = 0
        for character in word {
            location += character.utf16.count
            expected.append(CTLineGetOffsetForStringIndex(line, location, nil))
        }
        expected[expected.count - 1] = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        #expect(word.utf16.count > V2Layout.MeasuredText.longWord)
        #expect(offsets == expected)
    }
}
