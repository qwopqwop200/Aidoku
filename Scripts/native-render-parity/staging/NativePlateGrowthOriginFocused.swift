import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativePlateGrowthScrollTests {
    private func card(text: String = "달칵!", width: CGFloat = 83.5, font: CGFloat = 42.75, scale: CGFloat = 1,
                      vertical: Bool = false, staleFont: CGFloat? = nil, sourceGlyph: CGFloat? = nil) throws -> NativeTranslationRenderer.Card {
        var fields: [String: Any] = ["id": "scroll-probe", "text": text, "typesettingText": text,
            "typesettingQuoteMode": 0, "fontScript": "korean", "wrappingScript": "korean",
            "sourceBounds": [0.0,0.0,0.5,0.5], "sourceFrame": [0,0,200,200],
            "x": 0, "y": 0, "width": width, "height": 100, "fontSize": staleFont ?? font,
            "lineHeight": (staleFont ?? font) * 1.2, "vertical": vertical]
        if let sourceGlyph { fields["sourceFontSize"] = sourceGlyph }
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: font,
            vertical: vertical, lineHeight: font * 1.2,
            optimizesKoreanWrapping: false, horizontalScale: scale, usesBlockWordLayout: true)
        let typography = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        return NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            drawsPanel: false, background: NativeTranslationRenderer.color([255,255,255]),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: font)
    }

    @Test(arguments: [1.0,0.9])
    func plateTrialRetainsAuthoredCSSOriginBeforePhysicalQuantization(scale: Double) throws {
        var baseline = try card(text:"AB CD",width:80,font:10)
        baseline.authoredTextOrigin = CGPoint(x:5.125,y:6.875)
        let proposal = NativeTypographyPlateGrowth.Proposal(box:CGRect(x:1.127,y:2.783,width:80,height:100),
            font:12,pitch:14.4,padding:3,horizontalScale:scale,room:false,lifting:false)
        let candidate = try #require(NativeTranslationRenderer.plateGrowthTrial(baseline,proposal))
        // The authored CSS layout box precedes scale and LayoutUnit rounding.
        // Its origin remains available for subsequent parent-local CSS writes.
        #expect(candidate.authoredTextOrigin == proposal.box.origin)
        #expect(candidate.item.rect.origin != candidate.authoredTextOrigin)
        var retained = candidate
        NativeTranslationRenderer.preparePlateGrowthCard(&retained,preservingControlledChildren:false)
        #expect(retained.authoredTextOrigin == candidate.authoredTextOrigin)
    }

}
