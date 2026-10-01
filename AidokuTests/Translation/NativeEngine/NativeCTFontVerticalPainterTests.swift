import CoreGraphics
import CoreText
import Foundation
import Testing
import UIKit
@testable import Aidoku

struct NativeCTFontVerticalPainterTests {
    private func frame(stroke: CGFloat) -> CTFrame {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 24
        paragraph.maximumLineHeight = 24
        paragraph.lineBreakMode = .byCharWrapping
        let text = NSAttributedString(string: "天地玄黄宇宙洪荒", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Semibold" as CFString, 20, nil),
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String): true,
            .paragraphStyle: paragraph,
            .kern: 0,
            NSAttributedString.Key(kCTTrackingAttributeName as String): 1,
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): stroke,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        return CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(x: 0, y: 0, width: 480, height: 154), transform: nil),
            [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary)
    }

    private func pixels(_ paint: (CGContext) -> Void) -> Data {
        let context = CGContext(data: nil, width: 960, height: 308, bitsPerComponent: 8, bytesPerRow: 960 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 308))
        context.translateBy(x: 0, y: 308)
        context.scaleBy(x: 2, y: -2)
        paint(context)
        return Data(bytes: context.data!, count: 960 * 308 * 4)
    }

    @Test func preparedUprightFillPreservesNativeGlyphTransportAndGraphicsState() throws {
        let frame = frame(stroke: 0)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        #expect(lines.count > 1)
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let prepared = try lines.map { try #require(NativeCTFontVerticalPainter.prepare(line: $0)) }
        let reference = pixels { context in
            context.translateBy(x: 0, y: 154)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
        }
        var stateRestored = true
        let actual = pixels { context in
            context.textMatrix = CGAffineTransform(rotationAngle: 0.2)
            context.textPosition = CGPoint(x: 4, y: 5)
            for (line, origin) in zip(prepared, origins) {
                let matrix = context.textMatrix, position = context.textPosition, transform = context.ctm
                #expect(NativeCTFontVerticalPainter.draw(prepared: line, context: context,
                    anchor: CGPoint(x: origin.x, y: 154 - origin.y)))
                stateRestored = stateRestored && matrix == context.textMatrix && position == context.textPosition && transform == context.ctm
            }
        }
        #expect(actual == reference)
        #expect(stateRestored)
    }

    @Test func strokeOrLaterUnsupportedLineRefusesBeforeWholeFramePaint() {
        let fill = CTFrameGetLines(frame(stroke: 0)) as! [CTLine]
        let stroke = CTFrameGetLines(frame(stroke: 8)) as! [CTLine]
        #expect(!fill.isEmpty && !stroke.isEmpty)
        #expect(stroke.allSatisfy { NativeCTFontVerticalPainter.prepare(line: $0) == nil })
        let horizontal = CTLineCreateWithAttributedString(NSAttributedString(string: "guard", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        ]))
        let allLines = fill + [horizontal]
        let prepared = allLines.compactMap { NativeCTFontVerticalPainter.prepare(line: $0) }
        #expect(prepared.count < allLines.count)
        let untouched = pixels { _ in }
        let result = pixels { context in
            // Whole-frame fallback admission must precede any accepted-line draw.
            guard prepared.count == allLines.count else { return }
            for line in prepared { NativeCTFontVerticalPainter.draw(prepared: line, context: context, anchor: .zero) }
        }
        #expect(result == untouched)
    }
}
