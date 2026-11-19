import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCaptionCSSProvenanceTests {
    private func card(x:CGFloat = -10.127,y:CGFloat = 20.019,width:CGFloat = 36.65413533834584,
                      padding:CGFloat = 2.613,scale:CGFloat = 1) throws -> NativeTranslationRenderer.Card {
        let raw = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:[
            "id":"css-caption","text":"가나다라마바사 아자차카타파하","x":x,"y":y,"width":width,"height":100,
            "paddingLeft":padding,"paddingRight":padding,"paddingTop":padding,"paddingBottom":padding,
            "fontSize":6,"lineHeight":7.2,"fontScript":"korean","wrappingScript":"korean","sourceTextOnly":false,
            "sourceColorEligible":true,"allowsAutomaticFontRecovery":true,"sourceFrame":[0,0,390,700],"sourceBounds":[0.1,0.1,0.1,0.1]]))
        let item=NativeTranslationRenderer.usedScaledTextItem(raw,scale:scale)
        let style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:6,lineHeight:7.2,horizontalScale:scale)
        return .init(item:item,typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),
            style:style,authoredTextOrigin:CGPoint(x:x,y:y),initialCaptionCSS:.init(item:raw),drawsPanel:false,
            background:NativeTranslationRenderer.color([255,255,255]),usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:6)
    }

    @Test(arguments:0..<8)
    func plateAndRoomShiftSavedAuthoredOriginBeforeParentLocalQuantization(probe:Int) throws {
        let scale=probe&1==0 ? 1.0:0.9
        let parent=probe&2==0 ? CGPoint.zero:CGPoint(x:100.015625,y:200.03125)
        let room=probe&4 != 0
        var baseline=try card(width:80.037,scale:0.9)
        baseline.initialCaptionCSS=nil
        let proposal=NativeTypographyPlateGrowth.Proposal(box:CGRect(x:30.119,y:-8.773,width:90.039,height:110.019),font:8,pitch:9.6,padding:3.113,horizontalScale:scale,room:room,lifting:false)
        let result=try #require(NativeTranslationRenderer.plateGrowthTrial(baseline,proposal,parentOrigin:parent))
        // Literal frozen 8471/8525: saved CSS origin + proposed page box -
        // saved getBoundingClientRect origin. Resolve CSS locally, then scale.
        let x = -10.127+30.119-Double(baseline.item.x)
        let y = 20.019-8.773-Double(baseline.item.y)
        func unit(_ n:Double)->Double {Double((Float(n)*64).rounded(.towardZero))/64}
        #expect(result.authoredTextOrigin == CGPoint(x:x,y:y))
        #expect(abs(Double(result.item.x)-(Double(parent.x)+unit(x-Double(parent.x))+unit(90.039)*(1-scale)/2))<1e-12)
        #expect(abs(Double(result.item.y)-(Double(parent.y)+unit(y-Double(parent.y))))<1e-12)
        #expect(abs(Double(result.item.width)-unit(90.039)*scale)<1e-12)
        #expect(abs(Double(result.item.paddingLeft)-unit(3.113/scale)*scale)<1e-12)
        #expect(baseline.authoredTextOrigin == CGPoint(x:-10.127,y:20.019))
        let record:[String:Any] = ["kind":"plate","probe":probe,"room":room,"scale":scale,
            "parent":[Double(parent.x),Double(parent.y)],"saved":[-10.127,20.019],
            "origin":[Double(baseline.item.x),Double(baseline.item.y)],
            "proposal":[30.119,-8.773,90.039,110.019],"padding":3.113,
            "actualAuthored":[Double(result.authoredTextOrigin!.x),Double(result.authoredTextOrigin!.y)],
            "actualBox":[Double(result.item.x),Double(result.item.y),Double(result.item.width),Double(result.item.height)],
            "actualPadding":[Double(result.item.paddingLeft),Double(result.item.paddingTop)]]
        print("CSS_PROVENANCE "+String(data:try JSONSerialization.data(withJSONObject:record,options:.sortedKeys),encoding:.utf8)!)
    }
}
