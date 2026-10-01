import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeEarlyPlateContrastTests {
    private func fixture(background: [Double], sampled: [Double]) throws ->
        ([NativeTranslationRenderer.Card], NativeTranslationLayout, NativeTranslationRestoration.Result, IPhoneOverlaySettings) {
        let json = #"{"id":"fill","text":"검증","sourceBounds":[0.2,0.2,0.4,0.4],"sourceFrame":[0,0,80,80],"sourceColorEligible":true,"sourceTextOnly":false,"sourceFontSize":10,"x":10,"y":10,"width":60,"height":60,"fontSize":9,"lineHeight":11}"#
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: Data(json.utf8))
        let frame = CGRect(x: 0,y: 0,width: 80,height: 80)
        let layout = NativeTranslationLayout(imageSize: frame.size,sourceRect: frame,viewport: frame.size,items:[item])
        let ink = [70.0,70,135]
        let space = try #require(CGColorSpace(name:CGColorSpace.sRGB))
        let foreground = try #require(CGColor(colorSpace:space,components:ink.map { CGFloat($0)/255 }+[1]))
        let fill = try #require(CGColor(colorSpace:space,components:background.map { CGFloat($0)/255 }+[1]))
        let style = NativeTranslationTypography.Style(fontSize:9,foreground:foreground,lineHeight:11)
        let typography = NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style)
        var card = NativeTranslationRenderer.Card(item:item,typography:typography,style:style,
            drawsPanel:false,background:fill,usesFallbackVeil:false,lightSurface:false,heavyStrokeWidth:0,finalFontSize:9)
        card.sourcePanels=[.init(rect:frame,background:background,coverage:[frame])]
        card.sourceBackgroundKind="readability-panel"; card.captionParentPlate=false
        var restoration=NativeTranslationRestoration.Result()
        restoration.appearances[item.id] = .init(foreground:foreground,background:fill,restored:false,sourceSample:[
            "foreground":sampled,"stroke":[249.0,254,251],"background":background,"captionBackground":background,
            "confidence":["foreground":0.7,"stroke":0.7,"background":0.8]])
        var settings=IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,
            textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:2,subtitleContextSentences:0)
        settings.preserveSourceColors=true
        return ([card],layout,restoration,settings)
    }
    @Test func realSevenBlueInkCorrectsOnDetachedDarkPlateAndFinalOwnerPassDoesNotRevertIt() throws {
        var (cards,layout,restoration,settings)=try fixture(background:[55,65,91],sampled:[70,70,134])
        let result=NativeTranslationRenderer.applyEarlyPlateContrast(cards:&cards,layout:layout,restoration:restoration,settings:settings)
        #expect(result.count==1)
        #expect(NativeTranslationRenderer.rgb(cards[0].style.foreground)==[171,171,200])
        NativeTranslationRenderer.applySourceStyles(to:&cards,restoration:restoration,settings:settings,stage:.finalContrast,itemCount:1)
        #expect(NativeTranslationRenderer.rgb(cards[0].style.foreground)==[171,171,200])
        #expect(cards[0].style.outline==nil)
        #expect(cards[0].captionParentPlate==false)
        #expect(cards[0].sourcePanels.count==1)
    }
    @Test func realTwentyFiveBlueInkDarkensOnDetachedLilacPlateWithoutAdoptingSampledOutline() throws {
        var (cards,layout,restoration,settings)=try fixture(background:[151,140,164],sampled:[70,70,135])
        NativeTranslationRenderer.applyEarlyPlateContrast(cards:&cards,layout:layout,restoration:restoration,settings:settings)
        #expect(NativeTranslationRenderer.rgb(cards[0].style.foreground)==[38,38,74])
        NativeTranslationRenderer.applySourceStyles(to:&cards,restoration:restoration,settings:settings,stage:.finalContrast,itemCount:1)
        #expect(NativeTranslationRenderer.rgb(cards[0].style.foreground)==[38,38,74])
        #expect(cards[0].style.outline==nil)
    }
}
