import CoreText
import Foundation
import Testing
@testable import Aidoku

struct NativeFontSizePrecisionTests {
    // FontDescription stores computedSize as Float. The actual WebKit PDF
    // for this authored size serializes 8.16279, while Double CT creation
    // serializes 8.162791; CSSOM's rounded string is not the input.
    @Test(arguments: ["AppleSDGothicNeo-Bold", "Helvetica-Bold"])
    func namedFontUsesComputedFloatSizeWithoutChangingPolicy(name: String) throws {
        let authored: CGFloat = 8.162790697674419
        let expected: CGFloat = 8.162790298461914
        let text = "AB CD"
        let style = NativeTranslationTypography.Style(fontName: name, fontScript: "latin", fontSize: authored,
            tracking: 0, lineHeight: 12, optimizesKoreanWrapping: false)
        let layout = NativeTranslationTypography.layout(text: text, in: CGSize(width: 200, height: 40), style: style)
        let row = try #require(NativeTranslationTypography.diagnosticRuns(layout: layout).first)
        let primary = try #require(row["primaryFont"] as? [String: Any])
        #expect(primary["fontSize"] as? Double == Double(expected))
        #expect(style.fontSize == authored)
        let referenceFont = CTFontCreateWithName(name as CFString, expected, nil)
        let reference = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): referenceFont]))
        #expect(NativeTranslationTypography.measuredWidth(text: text, style: style) == CGFloat(CTLineGetTypographicBounds(reference, nil, nil, nil)))
    }

    @Test(arguments: [CGFloat(8.162790697674419), CGFloat(10.25)])
    func systemDescriptorUsesTheSameComputedSize(size: CGFloat) throws {
        let style = NativeTranslationTypography.Style(fontScript: "latin", fontSize: size,
            tracking: 0, lineHeight: 14, optimizesKoreanWrapping: false)
        let layout = NativeTranslationTypography.layout(text: "AB", in: CGSize(width: 100, height: 40), style: style)
        let row = try #require(NativeTranslationTypography.diagnosticRuns(layout: layout).first)
        let primary = try #require(row["primaryFont"] as? [String: Any])
        let expected: Double = size == 10.25 ? 10.25 : 8.162790298461914
        #expect(primary["fontSize"] as? Double == expected)
        #expect(style.fontSize == size)
    }
}
