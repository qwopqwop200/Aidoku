import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeSourceStyleDilationTests {
    @Test func reusingStylePlanesKeepsFractionalPlacementAndRejectsDifferentInputs() throws {
        typealias Paint = NativeSourceStylePaint
        let fill = try NativeMandatoryDisplayStroke.image(
            [0, 0, 0, 255, 0, 0, 0, 55, 0, 0, 0, 0, 0, 0, 0, 223], width: 2, height: 2)
        let otherFill = try NativeMandatoryDisplayStroke.image(
            [0, 0, 0, 1, 0, 0, 0, 55, 0, 0, 0, 0, 0, 0, 0, 223], width: 2, height: 2)
        let style = Paint.Style(sourceFontPixels: 17,
            bands: [.init(rgb: [30, 40, 60], width: 1.5), .init(rgb: [255, 120, 0], width: 0.5)],
            shadow: .init(rgb: [77, 80, 90], offset: [2.25, -1.5]))
        let memo = Paint.PlaneMemo()
        func pixels(_ fill: CGImage, font: CGFloat, origin: CGPoint, memo: Paint.PlaneMemo?) throws -> [UInt8] {
            let context = try #require(CGContext(data: nil, width: 32, height: 31, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            _ = try Paint.paint(style, fill: fill, frame: CGRect(origin: origin, size: CGSize(width: 2, height: 2)),
                                fontPixels: font, mandatoryOutward: 2, pageHeight: 31, context: context, memo: memo)
            let result = try #require(context.makeImage())
            return try NativeMandatoryDisplayStroke.rgba(result)
        }
        let first = CGPoint(x: 12.5, y: 10.25), second = CGPoint(x: 15.25, y: 14.5)
        #expect(try pixels(fill, font: 22, origin: first, memo: memo) == pixels(fill, font: 22, origin: first, memo: nil))
        #expect(memo.hits == 0 && memo.retainedBytes > 0)
        #expect(try pixels(fill, font: 22, origin: second, memo: memo) == pixels(fill, font: 22, origin: second, memo: nil))
        #expect(memo.hits == 1)
        #expect(try pixels(fill, font: 23, origin: first, memo: memo) == pixels(fill, font: 23, origin: first, memo: nil))
        #expect(try pixels(otherFill, font: 22, origin: first, memo: memo) == pixels(otherFill, font: 22, origin: first, memo: nil))
        #expect(memo.hits == 1)
    }

    @Test func symmetricRowsMatchBruteForceDiskAtTheBorders() {
        for (w, h) in [(1, 1), (1, 6), (5, 1), (4, 9), (11, 3), (8, 12), (32, 8)] {
            let alpha = (0..<(w * h)).map { UInt8(($0 * 113 + ($0 % 3) * 37) % 256) }
            expectDiskMatchesOracle(alpha, width: w, height: h)
        }
    }

    @Test func sparseDiskSpansPreserveEdgesAcrossBlankRows() {
        let w = 13, h = 8
        var alpha = [UInt8](repeating: 0, count: w * h)
        expectDiskMatchesOracle(alpha, width: w, height: h)
        alpha[0] = 119
        alpha[w + 4] = 81
        alpha[w + 8] = 197
        alpha[5 * w + 6] = 255
        alpha[w * h - 1] = 221
        expectDiskMatchesOracle(alpha, width: w, height: h)
    }

    private func expectDiskMatchesOracle(_ alpha: [UInt8], width w: Int, height h: Int) {
        for radius in [0, 1, 2, 5, 13] {
            let expected = alpha.indices.map { i in
                alpha.indices.filter { j in
                    let dx = i % w - j % w, dy = i / w - j / w
                    return dx * dx + dy * dy <= radius * radius
                }.map { alpha[$0] }.max() ?? 0
            }
            #expect(NativeSourceStylePaint.dilate(alpha, width: w, height: h, radius: radius) == expected)
        }
    }

    @Test func antialiasedDiskPreservesFractionalWeightsAtTheBorders() {
        for (w, h) in [(1, 7), (8, 1), (4, 9), (11, 3), (32, 8)] {
            let alpha = (0..<(w * h)).map { UInt8(($0 * 113 + 37) % 256) }
            for radius: CGFloat in [0.5, 1.1, 2, 2.97, 9.5] {
                let expected = alpha.indices.map { i in
                    alpha.indices.map { j -> UInt8 in
                        let dx = i % w - j % w, dy = i / w - j / w
                        let weight = min(1, max(0, Double(radius) + 0.5 - hypot(Double(dx), Double(dy))))
                        return UInt8((Double(alpha[j]) * weight).rounded())
                    }.max() ?? 0
                }
                #expect(NativeDiskAlphaMaximum.antialiased(alpha, width: w, height: h, radius: radius) == expected)
            }
        }
    }
}
