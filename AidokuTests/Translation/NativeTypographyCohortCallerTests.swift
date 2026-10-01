import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeTypographyCohortCallerTests {
    private var settings:IPhoneOverlaySettings {.init(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,
        textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:3,subtitleContextSentences:0)}
    private func fixture()->([NativeTranslationRenderer.Card],NativeTranslationLayout,NativeTranslationRestoration.Result) {
        var cards:[NativeTranslationRenderer.Card]=[]
        var restoration=NativeTranslationRestoration.Result()
        for i in 0..<3 {
            let font:CGFloat=[9,6.5,7][i],y:CGFloat=[20,55,120][i],x:CGFloat=i==2 ? 120:20
            let payload:[String:Any]=["id":"snap-\(i)","text":"검증","x":x,"y":y,"width":30,"height":40,
                "fontSize":font,"lineHeight":font*1.2,"paddingTop":3,"paddingBottom":3,"paddingLeft":3,"paddingRight":3,
                "sourceBounds":[x/200,y/200,0.04,0.08],"sourceFrame":[0,0,200,200],"sourceFontSize":8,
                "sourceVertical":true,"sourceColorEligible":false,"sourceTextOnly":false,"allowsAutomaticFontRecovery":i<2,
                "fontScript":"korean","wrappingScript":"korean"]
            let item=try! JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:payload))
            let style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:font,lineHeight:font*1.2,
                optimizesKoreanWrapping:false,horizontalWrapping:.keepAllWithEmergency)
            var card=NativeTranslationRenderer.Card(item:item,
                typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),
                style:style,drawsPanel:i != 0,background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,
                lightSurface:true,heavyStrokeWidth:0,finalFontSize:font)
            card.authoredTextOrigin=item.rect.origin
            card.sourcePanels=[.init(rect:item.rect.insetBy(dx:-8,dy:-8),background:[240,240,240],coverage:[item.rect.insetBy(dx:-8,dy:-8)])]
            card.sourceBackgroundKind="readability-panel"
            if i==0 {card.plateGrowthRecord=["grew":9,"entering":["font":7.5]]}
            restoration.appearances[item.id] = .init(foreground:nil,background:nil,restored:false,sourceSample:["foreground":[0,0,0],"background":[240,240,240]])
            cards.append(card)
        }
        return (cards,.init(imageSize:CGSize(width:200,height:200),sourceRect:CGRect(x:0,y:0,width:200,height:200),
            viewport:CGSize(width:200,height:200),items:cards.map(\.item)),restoration)
    }
    @Test func acceptsReadableGiveBackWhileRetainingExternalPagePeer() throws {
        var (cards,layout,restoration)=fixture();let before=cards
        let session=NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,settings:settings,sourceImage:nil)
        NativeTranslationRenderer.snapTypographyCohorts(cards:&cards,restoration:restoration,layout:layout,growthSession:session,
            plateSession:nil,rowGroups:[],originalFonts:[:],beforeCondensed:[:],hiddenIDs:[],removedIDs:[],lockedIDs:[],ownerOf:{card,_ in
                .init(panel:card.sourcePanels[0],cardID:card.item.id,panelIndex:0)
            })
        #expect(cards[0].finalFontSize==8.5)
        #expect(!cards[0].style.trackingScalesWithFont)
        #expect(cards[1].finalFontSize==before[1].finalFontSize && cards[2].finalFontSize==7)
        #expect(cards[0].harmonyRecord["cohortSnap"] as? [Double] == [9,8.5])
        #expect(cards.map {$0.sourcePanels[0].rect} == before.map {$0.sourcePanels[0].rect})
        #expect(cards[0].style.horizontalAlignment == before[0].style.horizontalAlignment)
    }


    @Test func actualHarmonyCallbackCommitsLateCohortAfterItsEarlierPasses() throws {
        var (cards,layout,restoration)=fixture()
        let before=cards
        let session=NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,settings:settings,sourceImage:nil)
        try NativeTranslationRenderer.reconcileTypographyHarmony(cards:&cards,layout:layout,restoration:restoration,
            settings:settings,source:nil,growthSession:session,lockedIDs:[])
        #expect(cards[0].finalFontSize==8.5)
        #expect(cards[0].harmonyRecord["cohortSnap"] as? [Double] == [9,8.5])
        #expect(cards[0].sourcePanels[0].rect == before[0].sourcePanels[0].rect)
    }

    @Test func excludedRowPeerVetoRestoresWholeCandidateState() throws {
        var (cards,layout,restoration)=fixture()
        var payload=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(cards[2].item)) as? [String:Any])
        payload["id"]="blocked-row";payload["fontSize"]=10;payload["lineHeight"]=12
        let item=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:payload))
        var peer=cards[2];peer.item=item;peer.style.fontSize=10;peer.style.lineHeight=12;peer.finalFontSize=10
        peer.typography=NativeTranslationRenderer.remeasureTypography(peer);cards.append(peer)
        cards[0].style.horizontalAlignment = .left
        cards[0].typography=NativeTranslationRenderer.remeasureTypography(cards[0])
        let before=cards[0]
        let session=NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,settings:settings,sourceImage:nil)
        NativeTranslationRenderer.snapTypographyCohorts(cards:&cards,restoration:restoration,layout:layout,growthSession:session,
            plateSession:nil,rowGroups:[["snap-0","blocked-row"]],originalFonts:[:],beforeCondensed:[:],hiddenIDs:[],removedIDs:[],lockedIDs:[],ownerOf:{card,_ in
                .init(panel:card.sourcePanels[0],cardID:card.item.id,panelIndex:0)
            })
        #expect(cards[0].item==before.item && cards[0].finalFontSize==9)
        #expect(cards[0].style.horizontalAlignment == .left && cards[0].style.tracking == before.style.tracking)
        #expect(cards[0].authoredTextOrigin == before.authoredTextOrigin && cards[0].harmonyRecord.isEmpty)
        #expect(cards[0].sourcePanels[0].rect == before.sourcePanels[0].rect)
    }
    @Test func unchangedCardIdentitySurvivesActualHarmonyCohortRoundTrip() throws {
        let (all,initialLayout,restoration)=fixture()
        var layout=initialLayout
        var card=all[2]
        card.item.typesettingText="검증";card.item.typesettingQuoteMode=0
        card.item.typesettingBlockDisplay=true;card.item.typesettingPreservedBlockWrapper=true
        card.item.typesettingPreformattedRows=nil
        card.authoredTextOrigin=CGPoint(x:120.003,y:120.009)
        card.textShift=CGPoint(x:0.21875,y:-0.125)
        card.style.horizontalAlignment = .left;card.style.blockRowHorizontalAlignment = .right
        card.typography=NativeTranslationRenderer.remeasureTypography(card)
        let before=card
        var cards=[card]
        layout=NativeTranslationLayout(imageSize:layout.imageSize,sourceRect:layout.sourceRect,viewport:layout.viewport,items:[card.item])
        let session=NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,settings:settings,sourceImage:nil)
        try NativeTranslationRenderer.reconcileTypographyHarmony(cards:&cards,layout:layout,restoration:restoration,
            settings:settings,source:nil,growthSession:session,lockedIDs:[])
        #expect(cards[0].item==before.item && cards[0].finalFontSize==before.finalFontSize)
        #expect(cards[0].textShift==before.textShift && cards[0].authoredTextOrigin==before.authoredTextOrigin)
        #expect(cards[0].typography.rangeBounds==before.typography.rangeBounds && cards[0].harmonyRecord.isEmpty)
        #expect(cards[0].style.horizontalAlignment == .left && cards[0].style.blockRowHorizontalAlignment == .right)
        #expect(cards[0].sourcePanels[0].rect==before.sourcePanels[0].rect)
    }

    @Test func acceptedDisplayMarkerDecodesAndProjectsTransactionally() throws {
        let (cards,_,_)=fixture()
        #expect(cards[0].item.typesettingDisplayGrowth == nil)
        var marked=cards[0].item;marked.typesettingDisplayGrowth="balloon"
        let decoded=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONEncoder().encode(marked))
        let proposed=NativeTranslationRenderer.projectTypographyHarmonyCard(decoded,from:cards[0])
        #expect(proposed.typographyDisplayGrowth == "balloon" && proposed.item.typesettingDisplayGrowth == "balloon")
        let deleted=NativeTranslationRenderer.projectTypographyHarmonyCard(cards[0].item,from:proposed)
        #expect(deleted.typographyDisplayGrowth==nil && deleted.item.typesettingDisplayGrowth==nil)
        let rolledBack=cards[0]
        #expect(rolledBack.typographyDisplayGrowth == nil && rolledBack.item.typesettingDisplayGrowth == nil)
    }

    @Test(arguments:["slanted","balloon","rotated-plate"])
    func literalDisplayGrowthModeExcludesSnap(_ mode:String) throws {
        var (cards,layout,restoration)=fixture();cards[0].typographyDisplayGrowth=mode
        let before=cards[0]
        let session=NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,settings:settings,sourceImage:nil)
        NativeTranslationRenderer.snapTypographyCohorts(cards:&cards,restoration:restoration,layout:layout,growthSession:session,
            plateSession:nil,rowGroups:[],originalFonts:[:],beforeCondensed:[:],hiddenIDs:[],removedIDs:[],lockedIDs:[],ownerOf:{card,_ in
                .init(panel:card.sourcePanels[0],cardID:card.item.id,panelIndex:0)
            })
        #expect(cards[0].finalFontSize==before.finalFontSize && cards[0].item==before.item)
        #expect(cards[0].typographyDisplayGrowth==mode && cards[0].harmonyRecord.isEmpty)
    }
}
