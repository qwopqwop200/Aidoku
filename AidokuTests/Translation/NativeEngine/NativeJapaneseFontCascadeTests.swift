import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeJapaneseFontCascadeTests {
    @Test func horizontalSevenHundredWeightMatchesObservedJapaneseAndHangulRuns() throws {
        let style = NativeTranslationTypography.Style(fontScript: "japanese", fontSize: 6,
            lineHeight: 7.16015625, optimizesKoreanWrapping: false)
        for (text, expected) in [("こんにちは世界", 41.496), ("안녕하세요, 세계", 39.402), ("여러분!", 17.418)] {
            let attributed = NativeTranslationTypography.attributedString(text: text, style: style)
            let primary = try #require(attributed.attribute(.init(kCTFontAttributeName as String), at: 0,
                effectiveRange: nil)) as! CTFont
            #expect(CTFontCopyPostScriptName(primary) as String == "HiraginoSans-W7")
            let line = CTLineCreateWithAttributedString(attributed)
            #expect(abs(CTLineGetTypographicBounds(line, nil, nil, nil) - expected) < 0.00001)
        }
    }

    @Test func verticalEightHundredWeightRetainsObservedFace() throws {
        let attributed = NativeTranslationTypography.attributedString(text: "日本語",
            style: .init(fontScript: "japanese", fontSize: 20, vertical: true))
        let primary = try #require(attributed.attribute(.init(kCTFontAttributeName as String), at: 0,
            effectiveRange: nil)) as! CTFont
        #expect(CTFontCopyPostScriptName(primary) as String == "HiraginoSans-W8")
    }
}
