import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeRememberedInkProvenanceTests {
    private func item(x:Double,y:Double,width:Double,height:Double,font:Double,padding:Double,text:String) throws -> NativeTranslationLayoutItem {
        try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:[
            "id":"remember-probe","text":text,"x":x,"y":y,"width":width,"height":height,
            "fontSize":font,"lineHeight":font*1.193359375,
            "paddingTop":padding,"paddingRight":padding,"paddingBottom":padding,"paddingLeft":padding,
            "fontScript":"korean","wrappingScript":"korean","sourceColorEligible":true,"sourceTextOnly":false,
            "allowsAutomaticFontRecovery":true,"sourceFrame":[0,0,390,700],"sourceBounds":[0.1,0.1,0.1,0.1]]))
    }
    private func context(_ item:NativeTranslationLayoutItem)->NativeTypographyPostPolish.Context {
        let layout=NativeTranslationLayout(imageSize:CGSize(width:390,height:700),sourceRect:CGRect(x:0,y:0,width:390,height:700),viewport:CGSize(width:390,height:700),items:[item])
        let settings=IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:3,subtitleContextSentences:0)
        return .init(restoration:.init(patches:[],appearances:[:],limitations:[]),settings:settings,layout:layout,patches:[:],reader:.init(nil))
    }
    @Test(arguments:[false,true]) func remembersAuthoredProfilePlaneWithoutMovingPhysicalCandidate(negative:Bool) throws {
        let item=try item(x:negative ? -10.127:12.482293233082707,y:20.019,width:36.12,height:32.86654135338347,font:10.5,padding:3.06,text:"오케이, 한계네")
        let context=context(item),original=context.candidate(item),used=NativeTypographyPostPolish.usedLayoutItem(item)
        context.rememberInk(original)
        let remembered=try #require(context.growth.rememberedInk[item.id])
        #expect(remembered.frame == original.inkFrame.offsetBy(dx:item.x-used.x,dy:item.y-used.y))
        #expect(context.candidate(item).inkFrame == original.inkFrame)
        #expect(context.candidate(item).shaped.rangeBounds == original.shaped.rangeBounds)
        #expect(remembered.pad == 3.15)
        var later=item;later.x += 30;later.fontSize=8.75
        context.rememberInk(context.candidate(later))
        #expect(context.growth.rememberedInk[item.id]?.frame == remembered.frame)
        #expect(context.growth.rememberedInk[item.id]?.font == 10.5)
    }
    @Test(arguments:[0,1,2,3,4]) func actualCohortCallerRetainsOriginalFrozenProfileFrame(probe:Int) throws {
        let values:[(Double,Double,Double,Double,Double,Double,String,CGRect)] = [
            (12.482293233082707,241.8703007518797,36.12,32.86654135338347,10.5,3.06,"오케이, 한계네",CGRect(x:15.529168233082707,y:245.2921757518797,width:30,height:26)),
            (160.35507518796993,220,44.38,61.33458646616543,10.5,3.44,"그렇다면 알몸이 된 것에 감사해야 하고,",CGRect(x:163.79257518796993,y:219.671875,width:37,height:62)),
            (200.27105263157898,408.890977443609,25,48.139097744360924,5.5,3,"닿고 있어……",CGRect(x:203.27105263157898,y:425.953477443609,width:18.875,height:13)),
            (153.9501879699248,217.5563909774436,16,47.28383458646621,7,2,"앗… 싫어",CGRect(x:155.9501879699248,y:232.1970159774436,width:12,height:18)),
            (344.6686661477914,226.59774436090225,36.08,39.21992481203006,8.75,3.04,"싫어…♡ 이런 건",CGRect(x:347.6999161477914,y:235.20711936090225,width:30,height:21))]
        let v=values[probe],item=try item(x:v.0,y:v.1,width:v.2,height:v.3,font:v.4,padding:v.5,text:v.6)
        let context=context(item)
        _=context.cohort(item,target:probe==1 || probe>=3 ? 8.5:8.75,others:[])
        let remembered=try #require(context.growth.rememberedInk[item.id])
        #expect(remembered.frame == v.7)
        #expect(remembered.font == item.fontSize)
        if probe>=3 {
            // Same native physical whole-contents ink captured before packing.
            // It is held fixed: only the remembered profile's origin changes.
            let ink=probe==3 ? CGRect(x:155.9665,y:232.1875,width:13.699,height:18)
                : CGRect(x:348.1943125,y:235.203125,width:31.1355,height:21)
            let panel=try #require(NativeTranslationSourceStylePostPolish.fallbackPanel(currentInk:ink,
                priorInk:remembered.frame,priorPadding:Double(remembered.pad),font:probe==3 ? 7:8.5,
                frame:CGRect(x:0,y:0,width:390,height:700),sources:[],background:[100,110,120],
                restoredPanelProof:false,insideTextFit:false))
            let used=NativeTranslationRenderer.usedRect(panel.rect)
            #expect(used.width == (probe==3 ? 19.703125:37.625))
            #expect(used.minX == (probe==3 ? 152.9375:344.6875))
        }
    }
}
