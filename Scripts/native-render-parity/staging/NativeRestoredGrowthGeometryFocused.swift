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

    @Test(arguments: [false,true])
    func restoredProducerQuantizesGeometryBeforeRemeasuringAndKeepsAuthoredOrigin(controlled: Bool) throws {
        var next = try card(text:"안녕 세상 함께",width:253.5,font:14)
        next.captionParentPlate = true
        next.sourcePanels = [.init(rect:CGRect(x:25.5,y:120,width:280.5,height:120),background:[255,255,255],coverage:[CGRect(x:25.5,y:120,width:280.5,height:120)])]
        next.authoredTextOrigin = CGPoint(x:2.001,y:3.002)
        next.style.horizontalWrapping = .keepAll
        next.style.horizontalWhitespace = .normal
        var item = next.item
        item.x=39.0001;item.y=122.88388671875;item.width=253.505;item.height=111.05
        item.paddingTop=4.50888671875;item.paddingBottom=56.5751953125
        item.paddingLeft=3.008;item.paddingRight=3.008
        item.typesettingText=controlled ? "안녕\n세상\n함께" : nil
        item.typesettingQuoteMode=controlled ? 0 : nil
        item.typesettingBlockDisplay=controlled ? true : nil
        var style = next.style
        NativeTranslationRenderer.syncRestoredPlateTextStyle(item:item,style:&style)
        NativeTranslationRenderer.commitRestoredPlateGrowth(item,to:&next,style:style)
        #expect(next.authoredTextOrigin == CGPoint(x:39.0001,y:122.88388671875))
        #expect(next.item.x == 39 && next.item.y == 122.875)
        #expect(next.item.width == 253.5 && next.item.height == 111.046875)
        #expect(next.item.paddingTop == 4.5 && next.item.paddingBottom == 56.5625)
        #expect(next.item.paddingLeft == 3 && next.item.paddingRight == 3)
        #expect(next.item.contentRect.minY == 127.375)
        #expect(next.captionParentPlate && next.sourcePanels.count == 1)
        #expect(next.sourcePanels[0].rect == CGRect(x:25.5,y:120,width:280.5,height:120))
        #expect(next.style.horizontalWrapping == .keepAll && next.style.horizontalWhitespace == .normal)
        #expect(next.style.usesBlockWordLayout == controlled)
        let measured = NativeTranslationRenderer.remeasureTypography(next)
        #expect(next.typography.rangeBounds == measured.rangeBounds)
        #expect(next.typography.lineRanges == measured.lineRanges)
        #expect(next.textShift == .zero && next.lineOffsets.isEmpty && next.typographyWidth == nil)
        // A size-only commit retains the authored origin rather than deriving
        // a different one from already quantized physical coordinates.
        let authored = next.authoredTextOrigin
        item = next.item;item.height=112.057
        NativeTranslationRenderer.commitRestoredPlateGrowth(item,to:&next,style:next.style)
        #expect(next.authoredTextOrigin == authored && next.item.height == 112.046875)
    }

}
