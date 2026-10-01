import CoreGraphics
import CoreText
import Testing
@testable import Aidoku

@Suite struct NativeFixedLinePitchTests {
    @Test(arguments: [6.0, 8.5, 12.0, 31.5])
    func explicitHorizontalPitchIncludesJapaneseFontLeading(size: Double) throws {
        try verifyPitch(size: size, text: "こ\nん\n界")
    }

    @Test func capturedSixPointJapaneseAndKoreanLinesRetainSevenPointPitch() throws {
        try verifyPitch(size: 6, text: "こ\n안\n界")
    }

    private func verifyPitch(size: Double, text: String) throws {
        let pitch = size * 1.2
        let style = NativeTranslationTypography.Style(fontScript: "japanese", fontSize: size,
            lineHeight: pitch, optimizesKoreanWrapping: false)
        let layout = NativeTranslationTypography.layout(text: text, in: CGSize(width: 100, height: 220), style: style)
        let attributed = NativeTranslationTypography.attributedString(text: layout.shapedText, style: style)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed),
            CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 220), transform: nil), nil)
        let count = CFArrayGetCount(CTFrameGetLines(frame))
        #expect(count == 3)
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let expected = CGFloat(floor(max(size, pitch)))
        for row in 1..<count {
            #expect(origins[row - 1].y - origins[row].y == expected)
        }
        #expect(layout.shapedText == text)
    }
}
