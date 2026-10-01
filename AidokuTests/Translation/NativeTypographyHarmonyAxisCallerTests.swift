import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeTypographyHarmonyAxisCallerTests {
    private var settings: IPhoneOverlaySettings {
        IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,
            textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:3,subtitleContextSentences:0)
    }
    private func fixture(tightOwner: Bool, verticalSource: Bool, sourceEligible:Bool = true,sourceSpacing:Double = 30) throws ->
        ([NativeTranslationRenderer.Card], NativeTranslationLayout, NativeTranslationRestoration.Result) {
        var cards: [NativeTranslationRenderer.Card] = []
        var restoration = NativeTranslationRestoration.Result()
        for i in 0..<2 {
            let descriptor: [String: Any] = ["id":"axis-\(i)","text":"검증문",
                "x":40+i*30,"y":60+i*20,"width":20,"height":40,"fontSize":5.5,"lineHeight":6.5634765625,
                "paddingTop":3,"paddingRight":3,"paddingBottom":3,"paddingLeft":3,
                "fontScript":"korean","wrappingScript":"korean","sourceVertical":verticalSource,
                "sourceBounds":[(40+Double(i)*sourceSpacing)/200,verticalSource ? 0.2:0.2+Double(i)*0.4,0.06,verticalSource ? 0.4:0.2],"sourceFrame":[0,0,200,200],
                "sourceFontSize":8,"sourceColorEligible":sourceEligible,"sourceTextOnly":false,"allowsAutomaticFontRecovery":true]
            let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                from: JSONSerialization.data(withJSONObject:descriptor))
            let style = NativeTranslationTypography.Style(fontScript:"korean",fontSize:5.5,lineHeight:6.5634765625,
                optimizesKoreanWrapping:false,balancesHorizontalLines:true,horizontalWrapping:.keepAllWithEmergency)
            var card = NativeTranslationRenderer.Card(item:item,
                typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),
                style:style,drawsPanel:false,background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,
                lightSurface:true,heavyStrokeWidth:0,finalFontSize:5.5)
            let ink = try #require(NativeTranslationRenderer.cardWholeRangeRect(card))
            let owner = tightOwner ? ink : CGRect(x:Double(30+i*30),y:20,width:40,height:140)
            card.sourcePanels = [.init(rect:owner,background:[240,240,240],coverage:[owner])]
            card.sourceBackgroundKind = "readability-panel"
            restoration.appearances[item.id] = .init(foreground:CGColor(gray:0,alpha:1),
                background:CGColor(gray:0.94,alpha:1),restored:false,sourceSample:["foreground":[0,0,0],"background":[240,240,240]])
            cards.append(card)
        }
        return (cards,.init(imageSize:CGSize(width:200,height:200),sourceRect:CGRect(x:0,y:0,width:200,height:200),
            viewport:CGSize(width:200,height:200),items:cards.map(\.item)),restoration)
    }

    @Test func sourceColumnAxisMovesTransparentTextInsideItsExistingOwner() throws {
        var (cards,layout,restoration) = try fixture(tightOwner:false,verticalSource:true)
        let before = cards
        let session = NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,
            settings:settings,sourceImage:nil)
        try NativeTranslationRenderer.reconcileTypographyHarmony(cards:&cards,layout:layout,restoration:restoration,
            settings:settings,source:nil,growthSession:session,lockedIDs:[])
        #expect(cards[0].item.y == before[0].item.y)
        #expect(cards[1].item.y == before[1].item.y-20)
        #expect(cards.map(\.finalFontSize) == [5.5,5.5])
        #expect(cards.map { $0.sourcePanels[0].rect } == before.map { $0.sourcePanels[0].rect })
        #expect(cards.allSatisfy { restoration.appearances[$0.item.id]?.restored == false && $0.textShift == .zero })
    }


    @Test(arguments:[false,true])
    func retainedSourceDescriptorsDoNotSkipAxisTrials(tightOwner:Bool) throws {
        var (cards,layout,restoration)=try fixture(tightOwner:tightOwner,verticalSource:true)
        let before=cards
        var payload=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(cards[0].item)) as? [String:Any])
        payload["id"]="kept-source";payload["keptLettering"]=true;payload["text"]=""
        let kept=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:payload))
        var items=layout.items;items.insert(kept,at:1)
        layout = .init(imageSize:layout.imageSize,sourceRect:layout.sourceRect,viewport:layout.viewport,items:items,
            readableRecoveryRemaining:layout.readableRecoveryRemaining,sourceObjectFit:layout.sourceObjectFit)
        let session=NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,
            settings:settings,sourceImage:nil)
        try NativeTranslationRenderer.reconcileTypographyHarmony(cards:&cards,layout:layout,restoration:restoration,
            settings:settings,source:nil,growthSession:session,lockedIDs:[])
        #expect(cards[1].item.y == before[1].item.y-(tightOwner ? 0:20))
        #expect(cards.map(\.finalFontSize) == before.map(\.finalFontSize))
        #expect(cards.map { $0.sourcePanels[0].rect } == before.map { $0.sourcePanels[0].rect })
        #expect(layout.items[1] == kept)
    }

    @Test(arguments:[false,true]) func sameFontAxisRejectsUnrelatedSourceAndInsufficientOwner(tightOwner:Bool) throws {
        var (cards,layout,restoration) = try fixture(tightOwner:tightOwner,verticalSource:tightOwner)
        let before = cards
        let session = NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,
            settings:settings,sourceImage:nil)
        try NativeTranslationRenderer.reconcileTypographyHarmony(cards:&cards,layout:layout,restoration:restoration,
            settings:settings,source:nil,growthSession:session,lockedIDs:[])
        #expect(cards.map(\.item.rect) == before.map(\.item.rect))
        #expect(cards.map(\.finalFontSize) == [5.5,5.5])
        #expect(cards.map { $0.sourcePanels[0].rect } == before.map { $0.sourcePanels[0].rect })
    }
    @Test(arguments:[CGFloat(2.01),CGFloat(-2.01)])
    func scaledAxisTranslatesPhysicalBoxByUsedAuthoredCSSDelta(_ delta:CGFloat) throws {
        let (cards,_,_) = try fixture(tightOwner:false,verticalSource:true)
        var original=cards[0]
        original.item.x=105;original.item.width=90;original.item.typesettingWidthScale=0.9
        original.style.horizontalScale=0.9
        original.authoredTextOrigin=CGPoint(x:100.01,y:original.item.y)
        original.typography=NativeTranslationRenderer.remeasureTypography(original)
        let plate=NativeTranslationSourceStylePostPolish.Panel(rect:CGRect(x:80,y:20,width:150,height:140),
            background:[240,240,240],coverage:[CGRect(x:80,y:20,width:150,height:140)])
        original.sourcePanels=[plate]
        let owner=NativeTranslationRenderer.TypographyHarmonyOwner(panel:plate,cardID:original.item.id,panelIndex:0)
        let shifted=try #require(NativeTranslationRenderer.moveTypographyHarmony(original,dx:delta,dy:0,
            peers:[original],frame:nil,owner:owner))
        #expect(shifted.item.x == (delta > 0 ? 107.015625:103))
        #expect(shifted.authoredTextOrigin?.x == 100.01+delta)
        #expect(shifted.style.horizontalScale == 0.9 && shifted.item.width == 90)
        #expect(shifted.sourcePanels[0].rect == plate.rect)
        #expect(NativeTranslationRenderer.moveTypographyHarmony(original,dx:100,dy:0,
            peers:[original],frame:nil,owner:owner) == nil)
    }


    @Test func retainedAuthoredShiftIsAppliedOnce() throws {
        let (cards,_,_)=try fixture(tightOwner:false,verticalSource:true)
        var original=cards[0]
        original.textShift=CGPoint(x:3,y:2)
        original.authoredTextOrigin=CGPoint(x:original.item.x+3,y:original.item.y+2)
        let panel=original.sourcePanels[0]
        let owner=NativeTranslationRenderer.TypographyHarmonyOwner(panel:panel,cardID:original.item.id,panelIndex:0)
        let before=try #require(NativeTranslationRenderer.cardWholeRangeRect(original))
        let moved=try #require(NativeTranslationRenderer.moveTypographyHarmony(original,dx:2,dy:1,
            peers:[original],frame:nil,owner:owner))
        let after=try #require(NativeTranslationRenderer.cardWholeRangeRect(moved))
        #expect(after.minX == before.minX+2 && after.minY == before.minY+1)
        #expect(moved.authoredTextOrigin == CGPoint(x:45,y:63))
        #expect(moved.textShift == .zero)
        let scaled=try #require(NativeTranslationRenderer.scaleTypographyHarmony(original,size:5.75,
            peers:[original],frame:nil,owner:owner))
        let ink=try #require(NativeTranslationRenderer.cardWholeRangeRect(scaled))
        #expect(abs(ink.midX-before.midX)<1.0/64 && abs(ink.midY-before.midY)<1.0/64)
    }

    @Test(arguments:[false,true])
    func blockChildFlushMovesBothWholeRowsAndScalars(_ toRight:Bool) throws {
        let (cards,_,_)=try fixture(tightOwner:false,verticalSource:false)
        var original=cards[0]
        original.item.width=40
        original.item.typesettingText="검증문\n검문"
        original.item.typesettingQuoteMode=0
        original.style.usesBlockWordLayout=true
        original.typography=NativeTranslationRenderer.remeasureTypography(original)
        var proposed=original
        proposed.style.horizontalAlignment=toRight ? .right:.left
        proposed.style.blockRowHorizontalAlignment=proposed.style.horizontalAlignment
        proposed.typography=NativeTranslationRenderer.remeasureTypography(proposed)
        let before=try #require(NativeTranslationRenderer.cardWholeRangeRect(original))
        let after=try #require(NativeTranslationRenderer.cardWholeRangeRect(proposed))
        #expect(toRight ? after.minX > before.minX:after.minX < before.minX)
        #expect(proposed.typography.rangeBounds.first?.minX != original.typography.rangeBounds.first?.minX)
        #expect(after.minY == before.minY && after.height == before.height)
    }

    @Test func harmonyMembershipDoesNotBorrowExpensiveGrowthAdmission() throws {
        let (_,layout,restoration)=try fixture(tightOwner:false,verticalSource:true,sourceEligible:false,sourceSpacing:28)
        let session=NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,
            settings:settings,sourceImage:nil)
        _ = try NativeTypographyPostPolish.refining(layout:layout,restoration:restoration,settings:settings,
            sourceImage:nil,growthSession:session,phase:.initial)
        var called=false
        _ = try NativeTypographyPostPolish.refining(layout:layout,restoration:restoration,settings:settings,
            sourceImage:nil,growthSession:session,phase:.harmony,harmonyAxis:{state,boxes,groups in
                called=true
                #expect(boxes.count == 2 && boxes.allSatisfy { $0?.valid == true })
                #expect(groups.count == 1 && groups[0].members.count == 2)
                return state
            })
        #expect(called)
    }

    @Test func laterUnkeyedCondensedProposalKeepsParentFlushButReplacesChildMargins() throws {
        let (cards,_,_)=try fixture(tightOwner:false,verticalSource:false)
        var flushed=cards[0]
        flushed.item.typesettingText="검증문\n검문";flushed.item.typesettingQuoteMode=0
        flushed.style.horizontalAlignment = .left;flushed.style.blockRowHorizontalAlignment = .left
        flushed.authoredTextOrigin=CGPoint(x:40.01,y:60.01)
        var resized=flushed.item
        resized.fontSize=6;resized.lineHeight=7.2
        let sizeOnly=NativeTranslationRenderer.projectTypographyHarmonyCard(resized,from:flushed)
        #expect(sizeOnly.style.horizontalAlignment == .left && sizeOnly.style.blockRowHorizontalAlignment == .left)
        #expect(sizeOnly.authoredTextOrigin == flushed.authoredTextOrigin)
        resized.typesettingWidthScale=0.9;resized.typesettingText="검증\n문 검문"
        let condensed=NativeTranslationRenderer.projectTypographyHarmonyCard(resized,from:flushed)
        #expect(condensed.style.horizontalAlignment == .left && condensed.style.blockRowHorizontalAlignment == nil)
        #expect(condensed.style.horizontalScale == 0.9 && condensed.finalFontSize == 6)
        #expect(condensed.sourcePanels[0].rect == flushed.sourcePanels[0].rect)
    }

    @Test(arguments: [false, true])
    func rowLabelsFollowCurrentAppliedBackgroundInsteadOfSampledSource(_ coloredPlate: Bool) throws {
        var (cards, oldLayout, restoration) = try fixture(tightOwner: false, verticalSource: false)
        for i in cards.indices {
            let data = try JSONEncoder().encode(cards[i].item)
            let object = try JSONSerialization.jsonObject(with: data)
            var descriptor = try #require(object as? [String: Any])
            descriptor["sourceBounds"] = [(40 + Double(i) * 30) / 200, 0.2, 0.06, 0.2]
            cards[i].item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                from: JSONSerialization.data(withJSONObject: descriptor))
        }
        let sampledPaper = NativeTranslationRenderer.color([135, 221, 208])
        restoration.appearances[cards[0].item.id] = .init(foreground: CGColor(gray: 0, alpha: 1),
            background: sampledPaper, restored: false,
            sourceSample: ["foreground": [0, 0, 0], "background": [135, 221, 208]])
        if coloredPlate { cards[0].sourcePanels[0].background = [135, 221, 208] }
        let layout = NativeTranslationLayout(imageSize: oldLayout.imageSize, sourceRect: oldLayout.sourceRect,
            viewport: oldLayout.viewport, items: cards.map(\.item))
        let before = cards
        let session = NativeTypographyPostPolish.rendererGrowthSession(layout: layout, restoration: restoration,
            settings: settings, sourceImage: nil)
        try NativeTranslationRenderer.reconcileTypographyHarmony(cards: &cards, layout: layout, restoration: restoration,
            settings: settings, source: nil, growthSession: session, lockedIDs: [])
        #expect(cards[0].item.y == before[0].item.y)
        #expect(cards[1].item.y == before[1].item.y - (coloredPlate ? 0 : 20))
        #expect(cards.map(\.finalFontSize) == before.map(\.finalFontSize))
        #expect(cards.map { $0.sourcePanels[0].rect } == before.map { $0.sourcePanels[0].rect })
        #expect(cards.map { $0.item.sourceBounds } == before.map { $0.item.sourceBounds })
    }

}
