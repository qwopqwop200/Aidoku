import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite @MainActor
struct NativeCaptionFixedBoxReflowTests {
    private func fixture(id:String = "fixed-box") throws -> (NativeTranslationRenderer.Card,NativeTranslationLayout,IPhoneOverlaySettings) {
        let object:[String:Any]=["id":id,"text":"그대의 작은 글씨는 이제 더 넓게 읽힐 것이랍니다",
            "x":130,"y":110,"width":44,"height":60,"fontSize":8,"lineHeight":10,
            "fontScript":"korean","wrappingScript":"korean","allowsAutomaticFontRecovery":true,
            "sourceColorEligible":true,"sourceBounds":[0.3,0.3,0.11,0.2],"sourceFrame":[0,0,400,300]]
        let item=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:object))
        var style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:8,lineHeight:10)
        style.optimizesKoreanWrapping=false;style.balancesHorizontalLines=true
        var card=NativeTranslationRenderer.Card(item:item,
            typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),style:style,
            drawsPanel:false,background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:8)
        let panel=CGRect(x:90,y:80,width:130,height:100)
        card.sourcePanels=[.init(rect:panel,background:[255,255,255],coverage:[panel])]
        let size=CGSize(width:400,height:300)
        let layout=NativeTranslationLayout(imageSize:size,sourceRect:CGRect(origin:.zero,size:size),viewport:size,items:[item])
        var settings=IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,textPlacement:.replace,
            subtitlePosition:.bottom,subtitleMaxLines:2,subtitleContextSentences:0)
        settings.preserveSourceBackgroundColor=true
        return (card,layout,settings)
    }
    @Test func actualCoreTextReflowUsesFinalPlateWithoutChangingFontOrSourceOwnership() throws {
        let (card,layout,settings)=try fixture()
        let before=try #require(NativeTranslationRenderer.captionReflowProfile(card,text:card.item.text))
        #expect(before.lines>1)
        var cards=[card]
        NativeTranslationRenderer.applyCaptionFixedBoxReflow(cards:&cards,layout:layout,settings:settings)
        #expect(cards[0].captionReflow?["kind"] as? String == "inside-fixed-box")
        let after=try #require(NativeTranslationRenderer.captionReflowProfile(cards[0],text:card.item.text))
        #expect(after.lines<before.lines)
        #expect(after.breaks.allSatisfy(before.breaks.contains))
        #expect(cards[0].sourcePanels[0].rect==card.sourcePanels[0].rect)
        #expect(cards[0].sourcePanels[0].coverage==card.sourcePanels[0].coverage)
        #expect(cards[0].style.fontSize==card.style.fontSize && cards[0].finalFontSize==card.finalFontSize)
        #expect(cards[0].item.text==card.item.text && cards[0].item.sourceBounds==card.item.sourceBounds)
        #expect(cards[0].item.paddingLeft==0 && cards[0].item.paddingRight==0)
    }
    @Test func transformedNeighborBoxPreventsTextReflowAcrossItsPhysicalFootprint() throws {
        let (card,layout,settings)=try fixture()
        var obstacle=card
        obstacle.item.x=190;obstacle.item.y=90;obstacle.item.width=8;obstacle.item.height=80;obstacle.item.rotation = .pi/4
        obstacle.sourcePanels=[]
        // The other node is rotated into the candidate ink despite its raw
        // layout rectangle standing outside the caption's original box.
        let physical=NativeTranslationRenderer.physicalTextNodeRect(obstacle)
        #expect(physical.minX<obstacle.item.x)
        var cards=[card,obstacle]
        NativeTranslationRenderer.applyCaptionFixedBoxReflow(cards:&cards,layout:layout,settings:settings)
        #expect(cards[0].captionReflow==nil)
        #expect(cards[0].item==card.item)
    }
    @Test func onlyExplicitWordAwareDeletionMarkerDisablesRegisteredCallback() throws {
        var (card,layout,settings)=try fixture()
        card.item.captionFixedBoxReflowDisabled=true
        var cards=[card]
        NativeTranslationRenderer.applyCaptionFixedBoxReflow(cards:&cards,layout:layout,settings:settings)
        #expect(cards[0].captionReflow==nil && cards[0].item==card.item)
    }
    @Test func physicalNodeBoxAppliesCondenseOnceAndTracksItsMovedTilt() throws {
        var (card,_,_)=try fixture()
        card.item.width=90;card.item.height=50;card.style.horizontalScale=0.9
        card.textShift=CGPoint(x:10,y:-7)
        let box=NativeTranslationRenderer.physicalTextNodeRect(card)
        #expect(box.width==90 && box.height==50)
        #expect(box.minX==card.item.x+10 && box.minY==card.item.y-7)
        card.item.rotation = .pi/4
        let rotated=NativeTranslationRenderer.physicalTextNodeRect(card)
        #expect(abs(rotated.width-140/sqrt(2))<1e-8)
        #expect(abs(rotated.height-140/sqrt(2))<1e-8)
    }
    @Test func declaredFractionalLengthsResolveBeforeCenteredCondense() throws {
        let (card,_,_)=try fixture()
        var declared=card.item
        declared.x=149.9921875;declared.width=100.015625
        declared.paddingLeft=2.015625;declared.paddingRight=3.015625
        let used=NativeTranslationRenderer.usedScaledTextItem(declared,scale:0.9)
        #expect(abs(used.x-154.98515625)<1e-10)
        #expect(abs(used.width-90.0140625)<1e-10)
        #expect(abs(used.paddingLeft-1.8140625)<1e-10)
        #expect(abs(used.paddingRight-2.7140625)<1e-10)
        #expect(used.x != NativeTranslationRenderer.usedLayoutItem(declared).x)
    }
    private func paragraphFixture(readableRemaining:Int? = nil) throws -> (NativeTranslationLayout,IPhoneOverlaySettings) {
        let object:[String:Any] = ["id":"paragraph","text":"그대의 작은 글씨는 이 넓은 상자 안에서 가지런히 읽힐 것이랍니다 공녀의 명령이랍니다",
            "x":80,"y":60,"width":160,"height":180,"fontSize":10,"lineHeight":12,
            "fontScript":"korean","wrappingScript":"korean","allowsAutomaticFontRecovery":true,
            "sourceColorEligible":true,"sourceBounds":[0.2,0.2,0.4,0.6],"sourceFrame":[0,0,400,300]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: object))
        let size=CGSize(width:400,height:300)
        let layout=NativeTranslationLayout(imageSize:size,sourceRect:CGRect(origin:.zero,size:size),viewport:size,items:[item],
            readableRecoveryRemaining:readableRemaining,sourceObjectFit:"contain")
        return (layout,try fixture().2)
    }
    @Test func roomyParagraphCreatesMeasuredReferenceAndTransportsItsSharedDebit() throws {
        let (layout,settings)=try paragraphFixture()
        let refined=try NativeTranslationLayoutPlanner.refining(layout:layout,restoration:.init(),settings:settings)
        let item=try #require(refined.items.first)
        #expect(item.smallTextReference?.paragraphRecovery == true)
        #expect(item.smallTextReferenceResolved == true)
        #expect(item.fontSize <= 12)
        #expect(item.text == layout.items[0].text && item.sourceBounds == layout.items[0].sourceBounds)
        #expect(refined.readableRecoveryRemaining == 2048-item.text.utf16.count)
        #expect(refined.sourceObjectFit == "contain")
        let encoded=try JSONEncoder().encode(refined)
        let replay=try NativeTranslationLayoutPlanner.refining(layout:JSONDecoder().decode(NativeTranslationLayout.self,from:encoded),
            restoration:.init(),settings:settings)
        #expect(replay.readableRecoveryRemaining == refined.readableRecoveryRemaining)
        #expect(replay.sourceObjectFit == refined.sourceObjectFit)
        #expect(replay.items[0] == item)
    }
    @Test func exhaustedReadableBudgetPreventsDynamicParagraphAdmission() throws {
        let (layout,settings)=try paragraphFixture(readableRemaining:0)
        let refined=try NativeTranslationLayoutPlanner.refining(layout:layout,restoration:.init(),settings:settings)
        #expect(refined.items[0].smallTextReference == nil)
        #expect(refined.readableRecoveryRemaining == 0)
    }
    @Test func realForeignParentChildVetoesFinalReleaseUntilItAppendsToRoot() throws {
        let (owner,layout,initialSettings)=try fixture(id:"owner")
        var child=try fixture(id:"foreign").0
        child.sourcePanels=[]
        var cards=[owner,child],settings=initialSettings
        settings.preserveSourceColors=true
        #expect(NativeTranslationRenderer.attachCaptionParent(cards:&cards,childIndex:0,ownerIndex:0,panelIndex:0))
        #expect(NativeTranslationRenderer.attachCaptionParent(cards:&cards,childIndex:1,ownerIndex:0,panelIndex:0))
        NativeTranslationRenderer.refreshCaptionOwnerGraph(cards:&cards)
        #expect(cards[0].sourcePanels[0].hasForeignChildren)
        let context=try #require(CGContext(data:nil,width:8,height:8,bitsPerComponent:8,bytesPerRow:32,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:8,height:8))
        let image=try #require(context.makeImage())
        var restoration=NativeTranslationRestoration.Result()
        restoration.patches=[.init(image:image,rect:owner.sourcePanels[0].rect,itemID:owner.item.id)]
        restoration.appearances[owner.item.id] = .init(foreground:CGColor(gray:0,alpha:1),background:CGColor(gray:1,alpha:1),
            restored:true,erasureComplete:true,sourceGlyphsVerified:true)
        var gloss=NativeTranslationEffectGloss.Refinement()
        gloss.hiddenIDs.insert(child.item.id)
        NativeTranslationRenderer.releaseCertifiedPlates(cards:&cards,restoration:restoration,gloss:gloss,layout:layout,settings:settings)
        #expect(cards[0].sourcePanels.count==1 && !cards[0].glyphPlateReleased)
        #expect(cards[0].sourcePanels[0].rect==owner.sourcePanels[0].rect)
        // Mere overlapping ink remains; only the actual root append removes
        // this child from the source plate's immediate children.
        NativeTranslationRenderer.appendTextToRoot(cards:&cards,index:1)
        NativeTranslationRenderer.refreshCaptionOwnerGraph(cards:&cards)
        #expect(!cards[0].sourcePanels[0].hasForeignChildren)
        NativeTranslationRenderer.releaseCertifiedPlates(cards:&cards,restoration:restoration,gloss:gloss,layout:layout,settings:settings)
        #expect(cards[0].sourcePanels.isEmpty && cards[0].glyphPlateReleased)
    }
    @Test func finalColumnReleaseReplacesControlledBlocksWithWrappingRawText() throws {
        let rawText="드디어 선생님이 왔다",controlledText="드디어\n선생님이\n왔다"
        let object:[String:Any]=["id":"released-column","text":rawText,
            "x":130,"y":110,"width":44,"height":60,"fontSize":8.75,"lineHeight":10.5,
            "fontScript":"korean","wrappingScript":"korean","sourceVertical":true,
            "sourceColorEligible":true,"sourceBounds":[0.3,0.3,0.11,0.2],"sourceFrame":[0,0,400,300],
            "typesettingText":controlledText,"typesettingQuoteMode":3,
            "columnLayout":["x":130,"y":110,"width":24.779,"height":100,
                "fontSize":7.02907,"lineHeight":8.434884,"paddingTop":2,"paddingRight":2,
                "paddingBottom":2,"paddingLeft":2,"balancedColumn":true]]
        let item=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:object))
        var (card,_,settings)=try fixture(id:item.id)
        card.item=item;card.style.fontSize=item.fontSize;card.style.lineHeight=item.lineHeight
        card.style.usesBlockWordLayout=true;card.finalFontSize=item.fontSize
        card.style.horizontalWrapping = .keepAllWithEmergency;card.style.keepsWholeWords=true
        #expect(card.style.horizontalWhitespace == .preWrap)
        card.typography=NativeTranslationRenderer.remeasureTypography(card)
        #expect(card.typography.lineCount==3 && card.style.usesBlockWordLayout)
        let size=CGSize(width:400,height:300)
        let layout=NativeTranslationLayout(imageSize:size,sourceRect:CGRect(origin:.zero,size:size),viewport:size,items:[item])
        settings.preserveSourceColors=true
        let context=try #require(CGContext(data:nil,width:8,height:8,bitsPerComponent:8,bytesPerRow:32,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:8,height:8))
        let image=try #require(context.makeImage())
        var restoration=NativeTranslationRestoration.Result()
        restoration.patches=[.init(image:image,rect:card.sourcePanels[0].rect,itemID:item.id)]
        restoration.appearances[item.id] = .init(foreground:CGColor(gray:0,alpha:1),background:CGColor(gray:1,alpha:1),
            restored:true,erasureComplete:true,sourceGlyphsVerified:true)
        var cards=[card]
        NativeTranslationRenderer.releaseCertifiedPlates(cards:&cards,restoration:restoration,
            gloss:.init(),layout:layout,settings:settings)
        let released=cards[0]
        #expect(released.glyphPlateReleased && released.sourcePanels.isEmpty)
        #expect(!released.item.balancedColumn && released.item.balancedColumn==item.balancedColumn)
        #expect(released.item.typesettingText==nil && released.item.typesettingQuoteMode==nil)
        #expect(!released.style.usesBlockWordLayout)
        #expect(released.style.horizontalWrapping == .normal && !released.style.keepsWholeWords)
        #expect(released.style.horizontalWhitespace == .normal)
        #expect(released.item.text==rawText && released.item.sourceBounds==item.sourceBounds)
        #expect(released.typography.shapedText.unicodeScalars.filter { !$0.properties.isWhitespace }
            == rawText.unicodeScalars.filter { !$0.properties.isWhitespace })
        #expect(released.typography.lineCount==3)
        #expect(released.finalFontSize==CGFloat(7.02907) && released.style.lineHeight==CGFloat(8.434884))
        // Frozen final column uses height:auto in normal block flow. Its CSS
        // height counts used line boxes; painted ink/outline may extend beyond
        // those boxes and is not the height:auto or font-shrink condition.
        let flowHeight = released.item.paddingTop + released.item.paddingBottom
            + CGFloat(released.typography.lineCount) * floor(max(released.finalFontSize,released.style.lineHeight))
        #expect(released.item.height==flowHeight && released.item.height==28)
        let lineBoxes=NativeTranslationTypography.captionLineMetrics(layout:released.typography)
        #expect(lineBoxes.count==3 && lineBoxes.allSatisfy { $0.rect.width<=released.textLayoutSize.width+0.5 })
        // The same narrow raw paragraph with the stale block flag is the
        // previous failure: one overflowing clipped row, not column wrapping.
        var staleStyle=released.style;staleStyle.usesBlockWordLayout=true
        let stale=NativeTranslationTypography.layout(text:rawText,in:released.textLayoutSize,style:staleStyle)
        #expect(stale.lineCount==1 && !stale.fits)
        // A descriptor already admitted as a coordinated column retains that
        // provenance; raw block display alone must not create the marker.
        var admitted=card;admitted.item.balancedColumn=true
        var admittedCards=[admitted]
        NativeTranslationRenderer.releaseCertifiedPlates(cards:&admittedCards,restoration:restoration,
            gloss:.init(),layout:layout,settings:settings)
        #expect(admittedCards[0].glyphPlateReleased && admittedCards[0].item.balancedColumn)
        #expect(admittedCards[0].typography.lineCount==released.typography.lineCount)
    }
    @Test func transparentGlyphCoverRetainsItsActualForeignChildIdentity() throws {
        let (owner,_,_)=try fixture(id:"owner")
        var child=try fixture(id:"foreign").0
        child.sourcePanels=[]
        var cards=[owner,child]
        #expect(NativeTranslationRenderer.attachCaptionParent(cards:&cards,childIndex:0,ownerIndex:0,panelIndex:0))
        #expect(NativeTranslationRenderer.attachCaptionParent(cards:&cards,childIndex:1,ownerIndex:0,panelIndex:0))
        cards[0].glyphCoverOwnerPanel=cards[0].sourcePanels[0]
        NativeTranslationRenderer.retainCaptionParentOwner(cards:&cards,ownerIndex:0,panelIndex:0)
        cards[0].sourcePanels.remove(at:0)
        NativeTranslationRenderer.refreshCaptionOwnerGraph(cards:&cards)
        #expect(cards[0].glyphCoverOwnerPanel?.hasForeignChildren == true)
        #expect(cards[1].captionParentOwner == .init(cardIndex:0,panelIndex:-1))
    }

}
