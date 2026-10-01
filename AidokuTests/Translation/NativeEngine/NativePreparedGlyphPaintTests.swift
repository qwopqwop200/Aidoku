import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

struct NativePreparedGlyphPaintTests {
    private let width = 480, height = 240

    private func attributed(_ text: String, extraWidth: CGFloat, splitStroke: Bool = false) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 22, nil)
        let value = NSMutableAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1),
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: 1, alpha: 0.8),
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -8,
            NSAttributedString.Key(kCTKernAttributeName as String): -0.22
        ])
        // Splitting Off|ice is intentionally opt-in: removing this paint boundary
        // can change iOS ligatures and must be refused before glyph reuse.
        if splitStroke, value.length > 3 {
            value.removeAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), range: NSRange(location: 0, length: 3))
        }
        if extraWidth > 0 {
            value.addAttributes([
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1),
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -extraWidth * 100 / CTFontGetSize(font)
            ], range: NSRange(location: 0, length: value.length))
        }
        return value
    }

    private func frames(_ text: NSAttributedString) -> (combined: CTFrame, fill: CTFrame, stroke: CTFrame) {
        let full = NSRange(location: 0, length: text.length)
        let stroke = NSMutableAttributedString(attributedString: text)
        let fill = NSMutableAttributedString(attributedString: text)
        text.enumerateAttributes(in: full) { attributes, range, _ in
            let key = NSAttributedString.Key(kCTStrokeWidthAttributeName as String)
            if let percent = attributes[key] as? NSNumber, percent.doubleValue != 0 {
                stroke.addAttribute(key, value: abs(percent.doubleValue), range: range)
            } else {
                stroke.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                    value: CGColor(gray: 0, alpha: 0), range: range)
            }
        }
        fill.removeAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), range: full)
        fill.removeAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String), range: full)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: 160, height: 100), transform: nil)
        func frame(_ value: NSAttributedString) -> CTFrame {
            CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(value), CFRange(location: 0, length: 0), path, nil)
        }
        return (frame(text), frame(fill), frame(stroke))
    }

    private func pixels(_ paint: (CGContext) throws -> Void) throws -> Data {
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 2, y: -2)
        canvas.translateBy(x: 0.137, y: 0.293)
        try paint(canvas)
        return Data(bytes: try #require(canvas.data), count: width * height * 4)
    }

    private func expectExactPixels(_ actual: Data, _ expected: Data) {
        var mismatchCount = abs(actual.count - expected.count)
        var maximumByteDelta = mismatchCount == 0 ? 0 : 255
        for (actualByte, expectedByte) in zip(actual, expected) {
            let delta = abs(Int(actualByte) - Int(expectedByte))
            if delta > 0 { mismatchCount += 1 }
            maximumByteDelta = max(maximumByteDelta, delta)
        }
        #expect(mismatchCount == 0,
            "Exact pixels required: mismatched bytes=\(mismatchCount), maximum delta=\(maximumByteDelta), sizes=\(actual.count)/\(expected.count)")
    }

    private func lines(_ frame: CTFrame) -> [(CTLine, CGPoint)] {
        let values = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: values.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        return zip(values, origins).map { ($0, CGPoint(x: 20.125 + $1.x, y: 105.375 - $1.y)) }
    }

    @Test(arguments: ["Office affine\nCore Text", "가나다 읽기\n日本語 文字"],
        [(false, CGFloat(0)), (true, CGFloat(0)), (false, CGFloat(0.35)), (true, CGFloat(0.35))])
    func measuredFramePaintMatchesReshapedPasses(text: String, options: (Bool, CGFloat)) throws {
        let (strokeFirst, extraWidth) = options
        let ordinary = attributed(text, extraWidth: 0)
        let legacy = frames(attributed(text, extraWidth: extraWidth))
        let measured = frames(ordinary).combined
        let reference = try pixels { context in
            for isStroke in strokeFirst ? [true, false] : [false, true] {
                for (line, anchor) in lines(isStroke ? legacy.stroke : legacy.fill) {
                    if isStroke {
                        #expect(NativeCTFontStrokePainter.draw(line: line, context: context, anchor: anchor))
                    } else {
                        let prepared = try #require(NativeCTFontHorizontalFillPainter.prepare(line: line))
                        #expect(NativeCTFontHorizontalFillPainter.draw(prepared: prepared, context: context, anchor: anchor))
                    }
                }
            }
        }
        let actual = try pixels { context in
            for isStroke in strokeFirst ? [true, false] : [false, true] {
                for (line, anchor) in lines(measured) {
                    if isStroke {
                        let prepared = try #require(NativeCTFontStrokePainter.prepare(line: line, includesFill: true,
                            additionalFillStrokeWidth: extraWidth))
                        #expect(NativeCTFontStrokePainter.draw(prepared: prepared, context: context, anchor: anchor))
                    } else {
                        let prepared = try #require(NativeCTFontHorizontalFillPainter.prepare(line: line, ignoringStroke: true))
                        #expect(NativeCTFontHorizontalFillPainter.draw(prepared: prepared, context: context, anchor: anchor))
                    }
                }
            }
        }
        expectExactPixels(actual, reference)
        #expect(actual.contains { $0 != 0 })
    }

    @Test func splitStrokeRunBoundariesDeclineBeforePaintingAndRetainLegacyShaping() throws {
        let text = "Office affine\nCore Text"
        let splitWidth = attributed(text, extraWidth: 0, splitStroke: true)
        let splitColor = NSMutableAttributedString(attributedString: attributed(text, extraWidth: 0))
        splitColor.addAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String),
            value: CGColor(gray: 0, alpha: 1), range: NSRange(location: 0, length: 3))
        let untouched = try pixels { _ in }
        for (kind, value) in [("width", splitWidth), ("color", splitColor as NSAttributedString)] {
            let legacy = frames(value)
            let original = try #require(lines(legacy.combined).first)
            let refused = try pixels { context in
                let prepared = NativeCTFontHorizontalFillPainter.prepare(line: original.0, ignoringStroke: true)
                #expect(prepared == nil, "Mixed stroke \(kind) must decline measured glyph reuse")
                if let prepared {
                    NativeCTFontHorizontalFillPainter.draw(prepared: prepared, context: context, anchor: original.1)
                }
            }
            expectExactPixels(refused, untouched)
            // The existing reshaped fill remains paintable; refusing the new
            // fast path never removes or clips the affected text.
            let fallback = try pixels { context in
                for (line, anchor) in lines(legacy.fill) {
                    let prepared = try #require(NativeCTFontHorizontalFillPainter.prepare(line: line))
                    #expect(NativeCTFontHorizontalFillPainter.draw(prepared: prepared, context: context, anchor: anchor))
                }
            }
            #expect(fallback.contains { $0 != 0 })
        }
    }

    @Test func outlineGlowWithEllipseClipMatchesLegacyPassesAndRetainsDrawingState() throws {
        let text = "Office affine\nCore Text", origin = CGPoint(x: 20, y: 20)
        let available = CGSize(width: 160, height: 100)
        var style = NativeTranslationTypography.Style(fontName: "Helvetica-Bold", fontSize: 22,
            foreground: CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1),
            outline: CGColor(gray: 1, alpha: 0.8), outlineWidth: 1.76,
            tracking: -0.22, lineHeight: 30, optimizesKoreanWrapping: false, alignsToTop: true,
            horizontalAlignment: .left, outlineGlow: 3.5, strictLineBreak: true)
        let layout = NativeTranslationTypography.layout(text: text, in: available, style: style)
        let attributed = NativeTranslationTypography.attributedString(text: text, style: style)
        let legacy = frames(attributed)
        let face = try #require(attributed.attribute(NSAttributedString.Key(kCTFontAttributeName as String),
            at: 0, effectiveRange: nil)) as! CTFont
        let pitch = floor(max(style.fontSize, style.lineHeight))
        let ascent = ceil(CTFontGetAscent(face)), descent = ceil(CTFontGetDescent(face))
        let firstBaseline = floor((pitch - ascent - descent) / 2) + ascent
        style.outlineGlow = 0
        let withoutGlow = NativeTranslationTypography.layout(text: text, in: available, style: style)
        for strokeFirst in [false, true] {
            let order: NativeTranslationTypography.OutlinePaintOrder = strokeFirst ? .strokeThenFill : .fillThenStroke
            var referenceTextState: (matrix: CGAffineTransform, position: CGPoint)?
            func render(reference: Bool, glow: Bool = true, clipped: Bool = true) throws -> Data {
                try pixels { context in
                    if clipped {
                        context.addEllipse(in: CGRect(x: 18, y: 15, width: 114, height: 64))
                        context.clip()
                    }
                    context.setFillColor(CGColor(red: 0.7, green: 0.1, blue: 0.2, alpha: 1))
                    context.setStrokeColor(CGColor(red: 0.1, green: 0.8, blue: 0.3, alpha: 1))
                    context.setLineWidth(1.5)
                    context.textMatrix = .identity
                    context.textPosition = CGPoint(x: 7, y: 9)
                    let transform = context.ctm, clip = context.boundingBoxOfClipPath
                    if reference {
                        // Frozen paint structure: reshape stroke/fill frames, then
                        // paint the whole pair inside one outline-glow layer.
                        context.saveGState()
                        context.textMatrix = .identity
                        context.setShadow(offset: .zero, blur: 3.5, color: style.outline)
                        context.beginTransparencyLayer(auxiliaryInfo: nil)
                        for isStroke in strokeFirst ? [true, false] : [false, true] {
                            let frame = isStroke ? legacy.stroke : legacy.fill
                            for (index, line) in (CTFrameGetLines(frame) as! [CTLine]).enumerated() {
                                let anchor = CGPoint(x: origin.x, y: origin.y + firstBaseline + CGFloat(index) * pitch)
                                if isStroke {
                                    #expect(NativeCTFontStrokePainter.draw(line: line, context: context, anchor: anchor))
                                } else {
                                    let prepared = try #require(NativeCTFontHorizontalFillPainter.prepare(line: line))
                                    #expect(NativeCTFontHorizontalFillPainter.draw(prepared: prepared, context: context, anchor: anchor))
                                }
                            }
                        }
                        context.endTransparencyLayer()
                        context.restoreGState()
                    } else {
                        #expect(NativeTranslationTypography.drawPreparedHorizontal(layout: glow ? layout : withoutGlow,
                            in: context, at: origin, outlinePaintOrder: order))
                    }
                    #expect(context.ctm == transform && context.boundingBoxOfClipPath == clip)
                    // The established painter normalizes its text matrix. Keep
                    // the same final text state while preserving CTM and clipping.
                    if reference {
                        referenceTextState = (context.textMatrix, context.textPosition)
                    } else if glow {
                        let previous = try #require(referenceTextState)
                        #expect(context.textMatrix == previous.matrix && context.textPosition == previous.position)
                    }
                    // A following path also catches leaked shadow, color, stroke
                    // width, or loss of the ellipse's actual nonrectangular clip.
                    context.fill(CGRect(x: 109, y: 24, width: 12, height: 7))
                    context.move(to: CGPoint(x: 108, y: 68))
                    context.addLine(to: CGPoint(x: 147, y: 80))
                    context.strokePath()
                }
            }
            let expected = try render(reference: true)
            let actual = try render(reference: false)
            expectExactPixels(actual, expected)
            let glowChangesPixels = actual != (try render(reference: false, glow: false))
            let clippingChangesPixels = actual != (try render(reference: false, clipped: false))
            #expect(glowChangesPixels)
            #expect(clippingChangesPixels)
        }
    }

    @Test func combinedPaintRejectsColorGlyphsBeforePainting() throws {
        let text = NSAttributedString(string: "A😀", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("AppleColorEmoji" as CFString, 22, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -8
        ])
        let line = CTLineCreateWithAttributedString(text)
        #expect(NativeCTFontStrokePainter.prepare(line: line, includesFill: true) == nil)
        #expect(NativeCTFontHorizontalFillPainter.prepare(line: line, ignoringStroke: true) == nil)
    }

    @Test func rendererUsesMeasuredGlyphsOnlyForAdmittedHorizontalOutlines() throws {
        let style = NativeTranslationTypography.Style(fontSize: 18, outline: CGColor(gray: 1, alpha: 1), outlineWidth: 1)
        let horizontal = NativeTranslationTypography.layout(text: "Core Text", in: CGSize(width: 180, height: 80), style: style)
        _ = try pixels { context in
            #expect(NativeTranslationTypography.drawPreparedHorizontal(layout: horizontal, in: context))
        }
        var verticalStyle = style
        verticalStyle.vertical = true
        let vertical = NativeTranslationTypography.layout(text: "日本語", in: CGSize(width: 80, height: 180), style: verticalStyle)
        let empty = try pixels { _ in }
        let refused = try pixels { context in
            #expect(!NativeTranslationTypography.drawPreparedHorizontal(layout: vertical, in: context))
        }
        expectExactPixels(refused, empty)
    }
}
