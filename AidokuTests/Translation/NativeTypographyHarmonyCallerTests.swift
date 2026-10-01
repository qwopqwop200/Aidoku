import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeTypographyHarmonyCallerTests {
    @Test(arguments: [false, true])
    func pageStyleHarmonyUsesLiveTransparentOwnerInsteadOfRestoredBoolean(_ paintedSelf: Bool) throws {
        let frame = CGRect(x:0,y:0,width:300,height:300)
        let positions = [CGPoint(x:40,y:40),CGPoint(x:180,y:40),CGPoint(x:110,y:190)]
        var cards: [NativeTranslationRenderer.Card] = []
        for index in 0..<3 {
            let origin = positions[index], font: CGFloat = index == 0 ? 5 : 6.75
            let descriptor: [String: Any] = ["id":"harmony-\(index)","text":"검증문",
                "x":origin.x,"y":origin.y,"width":18,"height":54,"fontSize":font,"lineHeight":font*1.2,
                "paddingTop":3,"paddingRight":3,"paddingBottom":3,"paddingLeft":3,
                "fontScript":"korean","wrappingScript":"korean","sourceColorEligible":true, "allowsAutomaticFontRecovery":true,
                "sourceFontSize":10,"sourceBounds":[Double(origin.x/300),Double(origin.y/300),0.06,0.18],
                "sourceFrame":[0,0,300,300]]
            let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                from:JSONSerialization.data(withJSONObject:descriptor))
            let style = NativeTranslationTypography.Style(fontScript:"korean",fontSize:font,lineHeight:font*1.2,
                optimizesKoreanWrapping:false,balancesHorizontalLines:true)
            var card = NativeTranslationRenderer.Card(item:item,
                typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),
                style:style,drawsPanel:index == 0 && paintedSelf,background:CGColor(gray:1,alpha:1),
                usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:font)
            card.captionParentPlate = true; card.sourceBackgroundKind = "readability-panel"
            let plate = CGRect(x:origin.x-10,y:origin.y-10,width:40,height:90)
            card.sourcePanels = [.init(rect:plate,background:[240,240,240],coverage:[plate])]
            cards.append(card)
        }
        let originals = cards
        let layout = NativeTranslationLayout(imageSize:frame.size,sourceRect:frame,viewport:frame.size,items:cards.map(\.item))
        let settings = IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,
            textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:3,subtitleContextSentences:0)
        let restoration = NativeTranslationRestoration.Result()
        let growth = NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,
            settings:settings,sourceImage:nil)
        try NativeTranslationRenderer.reconcileTypographyHarmony(cards:&cards,layout:layout,
            restoration:restoration,settings:settings,source:nil,growthSession:growth,lockedIDs:[])
        #expect(cards[0].finalFontSize == (paintedSelf ? 5 : 6.75))
        #expect(cards[0].sourcePanels[0].rect == originals[0].sourcePanels[0].rect)
        #expect(cards[0].captionParentPlate)
        #expect(cards[0].sourceBackgroundKind == "readability-panel")
    }
}
