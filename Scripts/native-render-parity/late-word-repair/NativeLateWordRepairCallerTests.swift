import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeLateWordRepairCallerTests {
    @Test(arguments:["safe","surface-rejected","consistency-rejected","unregistered","malformed-frame","removed-obstacle","mounted-obstacle","hidden-obstacle"])
    func actualLateCallerUsesWholeWordsAndRestoresFailedCandidates(_ scenario:String) throws {
        var payload:[String:Any]=["id":"late-gap","text":"검증합니다","x":40,"y":60,"width":24,"height":50,
            "fontSize":9,"lineHeight":10.8,"paddingTop":3,"paddingBottom":3,"paddingLeft":3,"paddingRight":3,
            "sourceBounds":[0.2,0.3,0.12,0.25],"sourceFrame":[0,0,200,200],"sourceFontSize":8,
            "sourceVertical":true,"sourceColorEligible":true,"sourceTextOnly":false,"allowsAutomaticFontRecovery":true,
            "fontScript":"korean","wrappingScript":"korean"]
        if scenario=="malformed-frame" {
            // Decoding already rejects malformed cards. Exercise the same raw
            // frame admission used by the actual consumer before indexing.
            for frame:[CGFloat] in [[],[0,0,0,200],[0,0,.nan,200],[0,0,200,-1]] {
                #expect(NativeTranslationRenderer.lateWordRepairFrame(frame,cleanupFrame:nil)==nil)
            }
            #expect(NativeTranslationRenderer.lateWordRepairFrame([],cleanupFrame:CGRect(x:0,y:0,width:200,height:200)) != nil)
            return
        }
        let item=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:payload))
        let style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:9,tracking:-0.108,lineHeight:10.8,
            optimizesKoreanWrapping:false,balancesHorizontalLines:false,horizontalWrapping:.keepAllWithEmergency)
        var card=NativeTranslationRenderer.Card(item:item,
            typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),
            style:style,drawsPanel:false,background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,
            lightSurface:true,heavyStrokeWidth:0,finalFontSize:9)
        card.sourceBackgroundKind="inpainted";card.authoredTextOrigin=item.rect.origin
        let before=NativeTypographyPostPolish.profile(card.typography,originalText:item.text)
        let beforeBad=before.breaks.filter {NativeTypographyPostPolish.badBreak(text:item.text,offset:$0) && !NativeTypographyPostPolish.reduplicationBreak(text:item.text,offset:$0)}
        #expect(!beforeBad.isEmpty)
        let context=try #require(CGContext(data:nil,width:200,height:200,bitsPerComponent:8,bytesPerRow:800,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:200,height:200))
        let image=try #require(context.makeImage())
        var restoration=NativeTranslationRestoration.Result()
        restoration.appearances[item.id] = .init(foreground:CGColor(gray:0,alpha:1),background:CGColor(gray:1,alpha:1),
            restored:true,erasureComplete:true,sourceSample:["foreground":[0,0,0],"background":[255,255,255]])
        restoration.patches=[.init(image:image,rect:CGRect(x:0,y:0,width:200,height:200),itemID:item.id,
            layoutSafe:Array(repeating:255,count:40000),surfaceLuminance:Array(repeating:255,count:40000),surfaceQuality:["safe":true])]
        let layout=NativeTranslationLayout(imageSize:CGSize(width:200,height:200),sourceRect:CGRect(x:0,y:0,width:200,height:200),
            viewport:CGSize(width:200,height:200),items:[item])
        let settings=IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,
            textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:3,subtitleContextSentences:0)
        let session=NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,settings:settings,sourceImage:image)
        if scenario=="surface-rejected" {
            restoration.patches=[.init(image:image,rect:CGRect(x:0,y:0,width:200,height:200),itemID:item.id,
                layoutSafe:Array(repeating:0,count:40000),surfaceLuminance:Array(repeating:255,count:40000),surfaceQuality:["safe":true])]
            session.refresh(restoration:restoration,layout:layout)
        }
        var cards=[card]
        if scenario.hasSuffix("obstacle") {
            var peerPayload=payload;peerPayload["id"]="peer";peerPayload["x"]=35;peerPayload["y"]=75;peerPayload["width"]=40;peerPayload["height"]=20;peerPayload["text"]="검증"
            let peerItem=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:peerPayload))
            var peer=card;peer.item=peerItem;peer.typography=NativeTranslationRenderer.remeasureTypography(peer)
            cards.append(peer)
        }
        let beforeItem=cards[0].item,beforeOrigin=cards[0].authoredTextOrigin,beforeRanges=cards[0].typography.rangeBounds
        var budget=NativeLateWordRepair.Budget(type:32768,surface:2097152,exterior:1048576,lookup:4194304)
        let accepted=NativeTranslationRenderer.repairLateTypographyWord(at:0,cards:&cards,restoration:restoration,layout:layout,
            growthSession:session,registered:scenario != "unregistered",textInside:true,hiddenIDs:scenario=="hidden-obstacle" ? ["peer"]:[],removedIDs:scenario=="removed-obstacle" ? ["peer"]:[],budget:&budget,
            accept:{live in scenario != "consistency-rejected" && live[0].finalFontSize==9})
        let after=NativeTypographyPostPolish.profile(cards[0].typography,originalText:item.text)
        let afterBad=after.breaks.filter {NativeTypographyPostPolish.badBreak(text:item.text,offset:$0) && !NativeTypographyPostPolish.reduplicationBreak(text:item.text,offset:$0)}
        #expect(accepted == ((scenario=="safe" || scenario=="removed-obstacle")))
        #expect(budget.type==32768 && budget.surface==2097152 && budget.exterior==1048576 && budget.lookup==4194304)
        if (scenario=="safe" || scenario=="removed-obstacle") {
            #expect(afterBad.isEmpty && cards[0].finalFontSize==9)
            #expect(cards[0].item.typesettingText==item.text && cards[0].item.typesettingQuoteMode==0)
            #expect(cards[0].item.typesettingPreservedBlockWrapper==nil && cards[0].item.typesettingBlockDisplay==true)
            #expect(cards[0].harmonyRecord["lateWordRepair"] as? [Double] == [2,9,9,1])
            #expect(cards[0].item.width>beforeItem.width && budget.late<1048576)
        } else {
            #expect(cards[0].item==beforeItem && cards[0].authoredTextOrigin==beforeOrigin)
            #expect(cards[0].typography.rangeBounds==beforeRanges && afterBad==beforeBad)
            #expect(cards[0].harmonyRecord.isEmpty)
            #expect((scenario=="unregistered" || scenario=="malformed-frame") ? budget.late==1048576 : budget.late<1048576)
        }
    }
    @Test(arguments:["safe","unregistered","scaled","budget-zero"])
    func actualHarmonyEndInvokesRegisteredLateRepairWithRetainedBudgets(_ scenario:String) throws {
        let payload:[String:Any]=["id":"late-gap","text":"검증합니다","x":40,"y":60,"width":24,"height":50,
            "fontSize":9,"lineHeight":10.8,"paddingTop":3,"paddingBottom":3,"paddingLeft":3,"paddingRight":3,
            "sourceBounds":[0.2,0.3,0.12,0.25],"sourceFrame":[0,0,200,200],"sourceFontSize":8,
            "sourceVertical":true,"sourceColorEligible":true,"sourceTextOnly":false,"allowsAutomaticFontRecovery":true,
            "fontScript":"korean","wrappingScript":"korean"]
        let item=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:payload))
        let style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:9,tracking:-0.108,lineHeight:10.8,
            optimizesKoreanWrapping:false,balancesHorizontalLines:false,horizontalWrapping:.keepAllWithEmergency)
        var card=NativeTranslationRenderer.Card(item:item,
            typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),
            style:style,drawsPanel:false,background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,
            lightSurface:true,heavyStrokeWidth:0,finalFontSize:9)
        card.sourceBackgroundKind="inpainted";card.authoredTextOrigin=item.rect.origin
        let before=NativeTypographyPostPolish.profile(card.typography,originalText:item.text)
        let beforeBad=before.breaks.filter {NativeTypographyPostPolish.badBreak(text:item.text,offset:$0) && !NativeTypographyPostPolish.reduplicationBreak(text:item.text,offset:$0)}
        #expect(!beforeBad.isEmpty)
        let context=try #require(CGContext(data:nil,width:200,height:200,bitsPerComponent:8,bytesPerRow:800,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:200,height:200))
        let image=try #require(context.makeImage())
        var restoration=NativeTranslationRestoration.Result()
        restoration.appearances[item.id] = .init(foreground:CGColor(gray:0,alpha:1),background:CGColor(gray:1,alpha:1),
            restored:true,erasureComplete:true,sourceSample:["foreground":[0,0,0],"background":[255,255,255]])
        restoration.patches=[.init(image:image,rect:CGRect(x:0,y:0,width:200,height:200),itemID:item.id,
            layoutSafe:Array(repeating:255,count:40000),surfaceLuminance:Array(repeating:255,count:40000),surfaceQuality:["safe":true])]
        let layout=NativeTranslationLayout(imageSize:CGSize(width:200,height:200),sourceRect:CGRect(x:0,y:0,width:200,height:200),
            viewport:CGSize(width:200,height:200),items:[item])
        let settings=IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,
            textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:3,subtitleContextSentences:0)
        let session=NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,settings:settings,sourceImage:image)
        // Represents the retained Entry and its actual finalized-inside marker,
        // after the original initial capture/finalize stages; no admission bypass
        // is applied to production. The negative fixture leaves capture absent.
        session.context.growth.registered=scenario != "unregistered"
        if scenario != "unregistered" {session.context.growth.admitted.insert(item.id)}
        session.context.growth.finalized.insert(item.id);session.context.growth.restoredInside.insert(item.id)
        card.sourcePanelTextFit="inside"
        if scenario=="scaled" {card.item.typesettingWidthScale=0.9;card.style.horizontalScale=0.9;card.typography=NativeTranslationRenderer.remeasureTypography(card)}
        if scenario=="budget-zero" {session.lateWordRepairRemaining=0}
        session.balloonTypeRemaining=2345;session.balloonSurfaceRemaining=654321;session.restoredLookupRemaining=123456
        let oldLate=session.lateWordRepairRemaining,oldExterior=session.restoredExteriorRemaining
        let beforeCard=card
        var cards=[card]
        try NativeTranslationRenderer.reconcileTypographyHarmony(cards:&cards,layout:layout,restoration:restoration,
            settings:settings,source:image,growthSession:session,lockedIDs:[])
        let accepted=cards[0].harmonyRecord["lateWordRepair"] != nil
        let after=NativeTypographyPostPolish.profile(cards[0].typography,originalText:item.text)
        let afterBad=after.breaks.filter {NativeTypographyPostPolish.badBreak(text:item.text,offset:$0) && !NativeTypographyPostPolish.reduplicationBreak(text:item.text,offset:$0)}
        #expect(accepted == (scenario=="safe"))
        #expect(session.balloonTypeRemaining==2345 && session.balloonSurfaceRemaining==654321)
        #expect(session.restoredLookupRemaining==123456 && session.restoredExteriorRemaining==oldExterior)
        if scenario=="safe" {
            #expect(afterBad.isEmpty && cards[0].finalFontSize==9)
            #expect(cards[0].harmonyRecord["lateWordRepair"] as? [Double] == [2,9,9,1])
            #expect(cards[0].item.width>beforeCard.item.width && session.lateWordRepairRemaining<oldLate)
            #expect(cards[0].sourcePanels.isEmpty && cards[0].sourcePanelTextFit=="inside")
        } else {
            #expect(cards[0].item==beforeCard.item && cards[0].authoredTextOrigin==beforeCard.authoredTextOrigin)
            #expect(cards[0].typography.rangeBounds==beforeCard.typography.rangeBounds)
            #expect(session.lateWordRepairRemaining==oldLate)
        }
    }
    @Test(arguments:[true,false])
    func smallerLateTrialPreservesInheritedEMOrPixelTracking(_ relative:Bool) throws {
        let payload:[String:Any]=["id":"late-tracking","text":"검증합니다","x":40,"y":60,"width":24,"height":50,
            "fontSize":9,"lineHeight":10.8,"paddingTop":3,"paddingBottom":3,"paddingLeft":3,"paddingRight":3,
            "sourceBounds":[0.2,0.3,0.12,0.25],"sourceFrame":[0,0,200,200],"sourceFontSize":8,
            "sourceVertical":true,"sourceColorEligible":true,"sourceTextOnly":false,"allowsAutomaticFontRecovery":true,
            "fontScript":"korean","wrappingScript":"korean"]
        let item=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:payload))
        var style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:9,tracking:-0.108,lineHeight:10.8,
            optimizesKoreanWrapping:false,horizontalWrapping:.keepAllWithEmergency)
        style.trackingScalesWithFont=relative
        let card=NativeTranslationRenderer.Card(item:item,typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),
            style:style,drawsPanel:false,background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:9)
        let c=NativeLateWordRepair.Candidate(rect:CGRect(x:32,y:2,width:40,height:166),font:8.75,condense:1,maxLines:3,anchor:CGPoint(x:52,y:85),pitch:10.5)
        let trial=try #require(NativeTranslationRenderer.lateWordRepairTrial(card,candidate:c))
        let expected:CGFloat=relative ? card.style.tracking*8.75/card.finalFontSize:-0.108
        #expect(trial.style.tracking==expected && trial.style.trackingScalesWithFont==relative)
        #expect(trial.item.typesettingText==item.text && trial.item.typesettingQuoteMode==0)
        #expect(trial.style.fontName==card.style.fontName && trial.style.bold==card.style.bold)
        var expectedStyle=trial.style;expectedStyle.tracking=expected
        let shaped=NativeTranslationTypography.layout(text:trial.item.typesettingText!,in:trial.textLayoutSize,style:expectedStyle)
        #expect(trial.typography.rangeBounds==shaped.rangeBounds)
    }

}
