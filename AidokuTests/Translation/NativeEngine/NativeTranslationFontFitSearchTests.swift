import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeTranslationFontFitSearchTests {
    @Test func rendererRetainsLargestMeasuredQuarterForKoreanFrames() {
        let text = "오늘은 좋은 날이랍니다."
        for width in [CGFloat(24), 40, 90] {
            for height in [CGFloat(24), 48, 90] {
                let size = CGSize(width: width, height: height)
                var style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 17)
                var expected: CGFloat?
                // Measure production line wrapping and glyph bounds, rather
                // than estimating character count or proportional advances.
                for font in stride(from: CGFloat(5), through: 17, by: 0.25) {
                    var probe = style
                    probe.fontSize = font; probe.lineHeight = font * 1.2; probe.tracking = -font * 0.012
                    if NativeTranslationTypography.layout(text: text, in: size, style: probe).fits { expected = font }
                }
                let measured = NativeTranslationRenderer.fitted(text: text, size: size, style: &style)
                if let expected {
                    #expect(style.fontSize == expected)
                    #expect(measured.fits)
                    #expect(measured.visibleUTF16Range.length == text.utf16.count)
                } else {
                    #expect(style.fontSize == 5)
                    #expect(!measured.fits)
                }
            }
        }
    }

    @Test func exactQuarterBoundaryDoesNotLoseReadableSize() {
        let font = NativeTranslationFontFitSearch.largestFitting(minimum: 5, maximum: 17) { $0 <= 10 }
        #expect(font == 10)
    }

    @Test func retainedSizeWasActuallyMeasuredAndNeverOverflows() {
        var measured: [CGFloat] = []
        let font = NativeTranslationFontFitSearch.largestFitting(minimum: 5, maximum: 17) {
            measured.append($0)
            return $0 <= 10.13
        }
        #expect(font == 10)
        #expect(measured.contains(10))
        #expect(measured.contains(10.25))
        #expect(measured.count <= 8)
    }

    @Test func preservesNonQuarterReadabilityFloorAndDeclinesUnfittableContent() {
        #expect(NativeTranslationFontFitSearch.largestFitting(minimum: 5.1, maximum: 5.2) { _ in true } == 5.1)
        #expect(NativeTranslationFontFitSearch.largestFitting(minimum: 5, maximum: 17) { _ in false } == nil)
        #expect(NativeTranslationFontFitSearch.largestFitting(minimum: .nan, maximum: 17) { _ in true } == nil)
    }
}
