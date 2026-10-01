import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

struct NativeHorizontalGlobalFillPainterTests {
    private func line(stroke: Bool = false) -> CTLine {
        let text = NSMutableAttributedString(string: "Core Text", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 20, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        if stroke {
            text.addAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), value: 8,
                range: NSRange(location: 5, length: 4))
        }
        return CTLineCreateWithAttributedString(text)
    }
    private func pixels(_ paint: (CGContext) -> Void) -> Data {
        let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 400 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        context.translateBy(x: 0, y: 200)
        context.scaleBy(x: 2, y: -2)
        paint(context)
        return Data(bytes: context.data!, count: 400 * 200 * 4)
    }

    @Test func preparedGlobalPositionsPreserveGlyphsAndRestoreTextState() throws {
        let line = line(), point = CGPoint(x: 20, y: 60)
        let prepared = try #require(NativeCTFontHorizontalFillPainter.prepare(line: line))
        let reference = pixels { context in
            context.translateBy(x: point.x, y: point.y)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
        }
        var restored = false
        let actual = pixels { context in
            context.textMatrix = CGAffineTransform(rotationAngle: 0.2)
            context.textPosition = CGPoint(x: 4, y: 5)
            let matrix = context.textMatrix, position = context.textPosition, transform = context.ctm
            #expect(NativeCTFontHorizontalFillPainter.draw(prepared: prepared, context: context, anchor: point))
            restored = matrix == context.textMatrix && position == context.textPosition && transform == context.ctm
        }
        #expect(actual == reference)
        #expect(restored)
    }

    @Test func completeLinePreflightRejectsLaterStrokeAndCondensedLayers() {
        let fill = line(), mixed = line(stroke: true)
        #expect((CTLineGetGlyphRuns(mixed) as! [CTRun]).count > 1)
        #expect(NativeCTFontHorizontalFillPainter.prepare(line: mixed) == nil)
        #expect(NativeCTFontHorizontalFillPainter.prepare(line: fill, horizontalScale: 0.9) == nil)
        let untouched = pixels { _ in }
        let refused = pixels { context in
            if let prepared = NativeCTFontHorizontalFillPainter.prepare(line: mixed) {
                NativeCTFontHorizontalFillPainter.draw(prepared: prepared, context: context, anchor: CGPoint(x: 20, y: 60))
            }
        }
        #expect(refused == untouched)
    }
}
