import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCaptionPanelWholeRangeTests {
    @Test func columnAlignmentObservesSelectedSpanBoxesRatherThanOnlyTheirGlyphs() throws {
        let fields: [String:Any] = ["id":"selected-spans","text":"A B","typesettingText":"A\nB",
            "typesettingPreformattedRows":true,"typesettingBlockDisplay":true,
            "x":20,"y":20,"width":30,"height":60,"fontSize":8,"lineHeight":28,
            "paddingTop":0,"paddingRight":0,"paddingBottom":0,"paddingLeft":0,
            "sourceBounds":[0.2,0.2,0.1,0.1],"sourceFrame":[0,0,100,100],
            "sourceTextOnly":false,"balancedColumn":true,"wrappingScript":"korean",
            "columnLayout":["x":20,"y":20,"width":30,"height":60,"fontSize":8,"lineHeight":28,
                "paddingTop":0,"paddingRight":0,"paddingBottom":0,"paddingLeft":0,"balancedColumn":true]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:fields))
        let style = NativeTranslationTypography.Style(fontSize:8,foreground:NativeTranslationRenderer.color([0,0,0]),
            lineHeight:28,usesPreformattedBlockRows:true,blockWordLayoutUsesTopPadding:true)
        let typography = NativeTranslationTypography.layout(text:"A\nB",in:item.contentRect.size,style:style)
        let card = NativeTranslationRenderer.Card(item:item,typography:typography,style:style,drawsPanel:false,
            background:NativeTranslationRenderer.color([255,255,255]),usesFallbackVeil:false,lightSurface:true,
            heavyStrokeWidth:0,finalFontSize:8)
        let selected = try #require(NativeTranslationRenderer.cardWholeRangeRect(card))
        #expect(selected.minY == 20 && selected.maxY == 76)
        #expect(NativeTranslationRenderer.cardInkRect(card).minY > 20)
        let layout = NativeTranslationLayout(imageSize:CGSize(width:100,height:100),sourceRect:CGRect(x:0,y:0,width:100,height:100),
            viewport:CGSize(width:100,height:100),items:[item])
        let settings = IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,
            textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:3,subtitleContextSentences:0)
        var cards = [card]
        NativeTranslationRenderer.polishCaptionPanels(cards:&cards,glossCards:[],gloss:.init(),layout:layout,settings:settings,source:nil)
        #expect(cards[0].item.y == 20)
        #expect(cards[0].item.sourceBounds == item.sourceBounds && cards[0].item.sourceFrame == item.sourceFrame)
        #expect(NativeTranslationRenderer.cardWholeRangeRect(cards[0]) == selected)
        // Glyph-only input demonstrably moves the node upward, unlike the
        // original selectNodeContents Range which includes both SPAN boxes.
        let slot=CGRect(x:20,y:20,width:30,height:60)
        let wrong = NativeTranslationCaptionPanelPolish.Entry(id:item.id,sourceTextOnly:false,rotation:0,vertical:false,
            lettering:nil,wrappingScript:"korean",font:8,frame:layout.sourceRect,sources:[],balancedColumn:true,
            column:slot,columnPaddingTop:0,ink:NativeTranslationRenderer.cardInkRect(card),panels:[])
        #expect(NativeTranslationCaptionPanelPolish.polish([wrong],opacity:1,kept:[])[0].shift.y < 0)
    }
}
