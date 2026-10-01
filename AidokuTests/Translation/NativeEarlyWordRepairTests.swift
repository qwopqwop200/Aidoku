import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeEarlyWordRepairTests {
    @Test(arguments:["safe","unregistered","unsafe-surface","budget-zero"])
    func earlyPassRepairsWordsBeforeHarmonyAndKeepsPageBudgets(_ scenario:String) throws {
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
        if scenario=="unsafe-surface" {
            restoration.patches=[.init(image:image,rect:CGRect(x:0,y:0,width:200,height:200),itemID:item.id,
                layoutSafe:Array(repeating:0,count:40000),surfaceLuminance:Array(repeating:255,count:40000),surfaceQuality:["safe":true])]
            session.refresh(restoration:restoration,layout:layout)
        }
        if scenario=="budget-zero" {session.wordRepairRemaining=0}
        session.balloonTypeRemaining=2345;session.balloonSurfaceRemaining=654321;session.restoredLookupRemaining=123456
        let oldEarly=session.wordRepairRemaining,oldLate=session.lateWordRepairRemaining,oldExterior=session.restoredExteriorRemaining
        let beforeCard=card
        var cards=[card]
        NativeTranslationRenderer.repairGrownTypographyWords(cards:&cards,restoration:restoration,layout:layout,
            growthSession:session,hiddenIDs:[],removedIDs:[])
        let accepted=cards[0].harmonyRecord["wordRepair"] != nil
        let after=NativeTypographyPostPolish.profile(cards[0].typography,originalText:item.text)
        let afterBad=after.breaks.filter {NativeTypographyPostPolish.badBreak(text:item.text,offset:$0) && !NativeTypographyPostPolish.reduplicationBreak(text:item.text,offset:$0)}
        #expect(accepted == (scenario=="safe"))
        #expect(session.balloonTypeRemaining==2345 && session.balloonSurfaceRemaining==654321)
        #expect(session.restoredLookupRemaining==123456 && session.restoredExteriorRemaining==oldExterior)
        #expect(session.lateWordRepairRemaining==oldLate)
        if scenario=="safe" {
            #expect(afterBad.isEmpty && cards[0].finalFontSize==9)
            let record=try #require(cards[0].harmonyRecord["wordRepair"] as? [Double])
            #expect(record.count==7 && record[0]>0 && record[2]<=record[1] && record[3]==9 && record[4]==9)
            #expect(NativeTranslationRenderer.lateWordRepairProfile(cards[0]).splits==0)
            #expect(cards[0].item.width>beforeCard.item.width && session.wordRepairRemaining<oldEarly)
            #expect(cards[0].sourcePanels.isEmpty && cards[0].sourcePanelTextFit=="inside")
        } else {
            #expect(cards[0].item==beforeCard.item && cards[0].authoredTextOrigin==beforeCard.authoredTextOrigin)
            #expect(cards[0].typography.rangeBounds==beforeCard.typography.rangeBounds)
            #expect(scenario=="unsafe-surface" ? session.wordRepairRemaining<oldEarly : session.wordRepairRemaining==oldEarly)
        }
    }
    @Test(arguments:[false,true])
    func earlyRepairsAllStemSplitsWhileLateOnlyRepairsBadBreaks(_ late:Bool) {
        var input=NativeLateWordRepair.Input(utf16Length:8,font:9.5,pitchRatio:1.2,sourceGlyph:12,
            source:CGRect(x:40,y:40,width:40,height:40),frame:CGRect(x:0,y:0,width:200,height:200),
            crop:CGRect(x:0,y:0,width:200,height:200),sourceInkLuminance:0)
        input.late=late;input.preGrowthFont=8.5
        let original=NativeLateWordRepair.Profile(ink:[CGRect(x:45,y:50,width:30,height:20)],lines:2,
            splits:1,bad:0,isolated:0,fragments:0,punctuationOnly:0,badStarts:0,badEnds:0)
        var pool=NativeLateWordRepair.Budget(type:10000,surface:20000,exterior:10000,lookup:30000)
        var measured=0,restored=false,acceptCalls=0
        let result=NativeLateWordRepair.repair(input:input,original:original,budget:&pool,
            snapshot:{0},restore:{_ in restored=true},wordWidth:{_ in 25},measure:{proposal in
                measured+=1
                let frame=CGRect(x:proposal.anchor.x-13,y:proposal.anchor.y-5,width:26,height:10)
                return .init(profile:.init(ink:[frame],lines:1,splits:0,bad:0,isolated:0,fragments:0,
                    punctuationOnly:0,badStarts:0,badEnds:0),contentFits:true,live:frame)
            },surface:{_,_,_ in true},accept:{acceptCalls+=1;return false})
        #expect((result != nil) == !late)
        #expect(late ? measured==0 && restored : measured==1 && !restored)
        #expect(acceptCalls==0)
        #expect(pool.type==10000 && pool.surface==20000 && pool.exterior==10000 && pool.lookup==30000)
        #expect(pool.late<1048576)
    }

    @Test(arguments:[false,true])
    func earlyRepairCanReturnGrowthForWholeWordsWithoutLateCondensing(_ late:Bool) {
        var input=NativeLateWordRepair.Input(utf16Length:8,font:9.5,pitchRatio:1.2,sourceGlyph:12,
            source:CGRect(x:40,y:40,width:40,height:40),frame:CGRect(x:0,y:0,width:200,height:200),
            crop:CGRect(x:0,y:0,width:200,height:200),sourceInkLuminance:0)
        input.late=late;input.preGrowthFont=8.5
        let original=NativeLateWordRepair.Profile(ink:[CGRect(x:45,y:50,width:30,height:20)],lines:2,
            splits:1,bad:1,isolated:0,fragments:0,punctuationOnly:0,badStarts:0,badEnds:0)
        var pool=NativeLateWordRepair.Budget(type:10000,surface:20000,exterior:10000,lookup:30000)
        var widths=[Double](),sizes=[Double](),restored=false
        let result=NativeLateWordRepair.repair(input:input,original:original,budget:&pool,
            snapshot:{0},restore:{_ in restored=true},wordWidth:{_ in 25},measure:{proposal in
                widths.append(proposal.condense);sizes.append(proposal.font)
                guard proposal.font==8.5 else{return nil}
                let frame=CGRect(x:proposal.anchor.x-13,y:proposal.anchor.y-5,width:26,height:10)
                return .init(profile:.init(ink:[frame],lines:1,splits:0,bad:0,isolated:0,fragments:0,
                    punctuationOnly:0,badStarts:0,badEnds:0),contentFits:true,live:frame)
            },surface:{_,_,_ in true},accept:{true})
        #expect((result != nil) == !late)
        #expect(restored==late)
        if late {#expect(sizes.allSatisfy{$0>=9.25} && widths.contains(0.9))}
        else {#expect(result?.candidate.font==8.5 && widths.allSatisfy{$0==1})}
        #expect(pool.type==10000 && pool.surface==20000 && pool.exterior==10000 && pool.lookup==30000)
    }

}
