import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// S8 V2Style: legacy simple font rule parity and synthetic colour/outline cases.
struct V2StyleTests {
    static func block(id: Int, box: CGRect, text: String, polygons: [[CGPoint]]) -> V2Block {
        let lines = polygons.map { points -> V2Line in
            let xs = points.map(\.x), ys = points.map(\.y)
            let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return V2Line(polygon: points, bounds: bounds, vertical: true, detectionScore: 1)
        }
        return V2Block(id: id, lines: lines, bounds: box, polygon: [], vertical: true, readingOrder: id,
                       sourceText: text, balloon: nil)
    }

    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)]
    }

    /// Page with vertical ink bars (glyph strokes) inside one text column, optionally ringed.
    static func page(background: CGFloat, ink: CGFloat, ring: CGFloat?, ringWidth: CGFloat = 4) -> V2Page {
        let width = 240, height = 320
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: background, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // top-left page coordinates: column x 90...150, y 60...260 -> bottom-left context rects
        // strokes without closed counters (an enclosed counter is a legitimate white-fill candidate)
        let bars = (0..<3).map { CGRect(x: 100 + $0 * 18, y: height - 255, width: 8, height: 190) } +
            (0..<6).map { CGRect(x: 144, y: height - 90 - $0 * 30, width: 6, height: 6) }
        if let ring {
            context.setFillColor(gray: ring, alpha: 1)
            for bar in bars { context.fill(bar.insetBy(dx: -ringWidth, dy: -ringWidth)) }
        }
        context.setFillColor(gray: ink, alpha: 1)
        for bar in bars { context.fill(bar) }
        return V2Page(id: "synthetic", image: context.makeImage()!)
    }

    static let column = block(id: 0, box: CGRect(x: 90, y: 60, width: 60, height: 200), text: "あいうえお",
                              polygons: [rect(90, 60, 60, 200)])

    @Test func fontRuleMatchesLegacySimpleSourceFont() {
        // Reference values from the verified Python port of NativeSimpleSourceFont (minimal policy).
        let a = Self.block(id: 0, box: CGRect(x: 1682.79, y: 74.66, width: 65.9, height: 121.68), text: "ab",
                           polygons: [Self.rect(14, 21, 63, 117)])
        let b = Self.block(id: 1, box: CGRect(x: 100, y: 100, width: 220, height: 380), text: "abcdefghijklmnopqrstuvwx",
                           polygons: [Self.rect(35, 60, 44, 211), [CGPoint(x: 84, y: 58), CGPoint(x: 134, y: 58),
                                                                    CGPoint(x: 137, y: 381), CGPoint(x: 87, y: 382)]])
        #expect(abs(V2SimpleFont.estimate([a])[0] - 59.40744726019504) < 1e-6)
        #expect(abs(V2SimpleFont.estimate([b])[0] - 51.9592137704265) < 1e-6)
        let grouped = V2SimpleFont.estimate([a, b])
        #expect(abs(grouped[0] - 55.68333051531077) < 1e-6 && grouped[0] == grouped[1])
    }

    @Test func plainDarkTextOnWhiteHasDarkFillAndNoStroke() throws {
        let blocks = V2Style.estimate(Self.page(background: 1, ink: 0, ring: nil), blocks: [Self.column])
        let style = try #require(blocks.first?.style)
        #expect(style.fontPixels > 0)
        #expect(max(style.textColor.r, style.textColor.g, style.textColor.b) < 40)
        #expect(style.strokeColor == nil && style.strokeWidth == 0)
        #expect(!style.bold)
    }

    @Test func whiteRingOnGreyIsDetectedAsOutline() throws {
        let blocks = V2Style.estimate(Self.page(background: 0.45, ink: 0, ring: 1), blocks: [Self.column])
        let style = try #require(blocks.first?.style)
        #expect(max(style.textColor.r, style.textColor.g, style.textColor.b) < 40)
        let stroke = try #require(style.strokeColor)
        #expect(min(stroke.r, stroke.g, stroke.b) > 215)
        #expect(style.strokeWidth > 1)
    }

    @Test func emptyBlocksAndDegenerateGeometryDoNotCrash() {
        let page = Self.page(background: 1, ink: 0, ring: nil)
        #expect(V2Style.estimate(page, blocks: []).isEmpty)
        let tiny = Self.block(id: 3, box: CGRect(x: 0, y: 0, width: 1, height: 1), text: "", polygons: [])
        let result = V2Style.estimate(page, blocks: [tiny])
        #expect(result.count == 1 && result[0].style != nil)
    }

    @Test func squaredDistanceMatchesBruteForce() {
        var state: UInt32 = 5
        for (w, h) in [(1, 1), (1, 7), (8, 1), (19, 13)] {
            for density: UInt32 in [0, 3, 50, 100] {
                let target = (0..<(w * h)).map { _ -> Bool in
                    state = state &* 1_664_525 &+ 1_013_904_223
                    return (state >> 8) % 100 < density
                }
                let fast = V2StyleEstimator.squaredDistance(to: target, width: w, height: h)
                for y in 0..<h {
                    for x in 0..<w {
                        var best = Int64(1) << 40
                        for yy in 0..<h {
                            for xx in 0..<w where target[yy * w + xx] {
                                best = min(best, Int64((x - xx) * (x - xx) + (y - yy) * (y - yy)))
                            }
                        }
                        #expect(Int64(fast[y * w + x]) == min(best, Int64(Int32.max)))
                    }
                }
            }
        }
    }
}
