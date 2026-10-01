import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeLateWordRepairGapTests {
    @Test func lateHarmonyLeavesAnInPlaceBadBreakWithoutASizeGrowth() throws {
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
        var cards=[card]
        try NativeTranslationRenderer.reconcileTypographyHarmony(cards:&cards,layout:layout,restoration:restoration,
            settings:settings,source:image,growthSession:session,lockedIDs:[])
        let after=NativeTypographyPostPolish.profile(cards[0].typography,originalText:item.text)
        let afterBad=after.breaks.filter {NativeTypographyPostPolish.badBreak(text:item.text,offset:$0) && !NativeTypographyPostPolish.reduplicationBreak(text:item.text,offset:$0)}
        #expect(afterBad==beforeBad && cards[0].item==item && cards[0].finalFontSize==9)
        let whole=try #require(NativeTranslationRenderer.cardWholeRangeRect(cards[0]))
        let advance=try #require(NativeTranslationTypography.canvasTextMetrics(text:item.text,style:style)).advance
        let report:[String:Any]=["advance":advance,"tracking":style.tracking,"text":item.text,"font":9,"node":[item.x,item.y,item.width,item.height],"ink":[whole.minX,whole.minY,whole.width,whole.height],
            "nativeBeforeBad":beforeBad,"nativeAfterBad":afterBad,"lines":before.lines,"nativeCandidateUnchanged":cards[0].item==item,
            "scope":"Actual macOS CoreText production Harmony callback and full white restoration; no iOS raster equivalence inferred."]
        let path=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/native-render-parity/late-word-repair/native-counterexample.json")
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:path)
    }
}
