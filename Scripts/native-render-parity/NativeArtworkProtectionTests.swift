import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeArtworkProtectionTests {
    private func fixture(safe: Bool = true) throws -> (NativeTranslationRenderer.Card,NativeTranslationLayout,NativeTranslationRestoration.Result,IPhoneOverlaySettings) {
        let object: [String:Any] = ["id":"artwork","text":"ARTWORK PROTECTION","wrappingScript":"latin","sourceColorEligible":true,
            "sourceTextOnly":false,"sourceBounds":[0.49,0.49,0.02,0.02],"sourceFrame":[0,0,400,180],"sourceFontSize":24,
            "x":40,"y":50,"width":320,"height":80,"fontSize":24,"lineHeight":28.8,
            "paddingTop":2,"paddingRight":2,"paddingBottom":2,"paddingLeft":2]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:object))
        let size = CGSize(width:400,height:180),frame = CGRect(origin:.zero,size:size)
        let style = NativeTranslationTypography.Style(fontSize:24,lineHeight:28.8)
        var card = NativeTranslationRenderer.Card(item:item,
            typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),style:style,
            drawsPanel:false,background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:24)
        card.sourcePanels = [.init(rect:item.rect,background:[255,255,255],coverage:[item.rect])]
        card.sourceBackgroundKind = "readability-panel"
        var original = NativeRestorationPixels(width:400,height:180)
        original.rgba = Array(repeating:[UInt8](arrayLiteral:255,255,255,255),count:original.count).flatMap{$0}
        var repaired = original;repaired.layoutSafe = Array(repeating:safe ? 1:0,count:repaired.count);repaired.erasureComplete = true
        let source = CGRect(x:196,y:88.2,width:8,height:3.6)
        let prepared = NativeSpatialSourceCrop.Prepared(pixels:original,crop:frame,source:source,box:source,
            auxiliary:[],excluded:[],marks:[],leadingRule:false,sx:1,sy:1,synthetic:[])
        let candidate = try #require(NativeRestorationCandidate(prepared:prepared,repaired:repaired,
            luminance:Array(repeating:255,count:repaired.count),imageSize:size,frame:frame,item:item))
        candidate.cacheProof(residualLettering:false)
        let image = try #require(candidate.image())
        var restoration = NativeTranslationRestoration.Result()
        restoration.patches = [.init(image:image,rect:frame,itemID:item.id,candidate:candidate)]
        restoration.appearances[item.id] = .init(foreground:CGColor(gray:0,alpha:1),background:CGColor(gray:1,alpha:1),
            restored:false,erasureComplete:true,sourceSample:["foreground":[0.0,0.0,0.0],"background":[255.0,255.0,255.0]])
        let layout = NativeTranslationLayout(imageSize:size,sourceRect:frame,viewport:size,items:[item])
        var settings = IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,textPlacement:.replace,
            subtitlePosition:.bottom,subtitleMaxLines:2,subtitleContextSentences:0)
        settings.preserveSourceColors = true
        return (card,layout,restoration,settings)
    }
    private func query(_ session: NativeTypographyPostPolish.RendererGrowthSession) -> NativeTranslationRenderer.ArtworkSurfaceQuery {
        {card,rects,foreground,budget in
            guard let range = session.inspectSurface(item:card.item,typography:card.typography,rects:rects,lookupBudget:&budget) else { return false }
            guard let rgb = NativeTranslationRenderer.rgb(foreground) else { return false }
            let ink = NativeSourceColorSampler.luminance(rgb)
            let contrast = ink<range[0] ? (range[0]+0.05)/(ink+0.05):ink>range[1] ? (ink+0.05)/(range[1]+0.05):1
            return contrast>=4.5
        }
    }
    @Test func actualNativeMaskReleasesOwnedPlateAtAcceptedFrozenLineFont() throws {
        let (card,layout,initial,settings) = try fixture()
        var restoration = initial,cards = [card]
        let session = NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,settings:settings,sourceImage:nil)
        let budget = try NativeTranslationRenderer.protectInitialArtwork(cards:&cards,restoration:&restoration,layout:layout,
            source:nil,settings:settings,surfaceQuery:query(session))
        #expect(cards[0].sourcePanels.isEmpty)
        #expect(cards[0].sourceBackgroundKind == "inpainted" && restoration.appearances[card.item.id]?.restored == true)
        #expect(cards[0].artworkRecord?["artworkFit"] == "restored-surface")
        #expect(cards[0].finalFontSize<card.finalFontSize && cards[0].finalFontSize>=18)
        #expect(cards[0].typography.lineCount == card.typography.lineCount)
        #expect(budget.surface<1_048_576 && budget.probePixels == 32768)
    }
    @Test func actualOriginalArtworkRiskShrinksCaptionButKeepsErasurePlate() throws {
        let (card,layout,initial,settings) = try fixture(safe:false)
        var art = NativeRestorationPixels(width:400,height:180)
        art.rgba = Array(repeating:[UInt8](arrayLiteral:255,255,255,255),count:art.count).flatMap{$0}
        let oldInk = card.typography.rangeBounds.map { $0.offsetBy(dx:card.textOrigin.x,dy:card.textOrigin.y) }.reduce(CGRect.null) { $0.union($1) }
        for y in 0..<art.height { for x in 0..<art.width {
            let px = Double(x)+0.5
            if px>=oldInk.minX && px<=oldInk.minX+10 || px>=oldInk.maxX-10 && px<=oldInk.maxX {
                art.rgba.replaceSubrange((y*art.width+x)*4..<(y*art.width+x)*4+4,with:[0,0,0,255])
            }
        } }
        let image = try #require(art.image())
        var restoration = initial,cards = [card]
        let session = NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,settings:settings,sourceImage:image)
        let budget = try NativeTranslationRenderer.protectInitialArtwork(cards:&cards,restoration:&restoration,layout:layout,
            source:image,settings:settings,surfaceQuery:query(session))
        #expect(cards[0].artworkRecord?["artworkFit"] == "smaller-caption")
        #expect(cards[0].sourcePanels.count == 1 && cards[0].sourcePanels[0].rect == card.sourcePanels[0].rect)
        #expect(cards[0].sourceBackgroundKind == card.sourceBackgroundKind && restoration.appearances[card.item.id]?.restored == false)
        #expect(cards[0].finalFontSize<card.finalFontSize && budget.probePixels == 31744)
    }
    @Test func unsafeRestorationRollsBackAllMeasuredGeometryAndPlate() throws {
        let (card,layout,initial,settings) = try fixture(safe:false)
        var restoration = initial,cards = [card]
        let session = NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,settings:settings,sourceImage:nil)
        _ = try NativeTranslationRenderer.protectInitialArtwork(cards:&cards,restoration:&restoration,layout:layout,
            source:nil,settings:settings,surfaceQuery:query(session))
        #expect(cards[0].artworkRecord == nil && cards[0].item == card.item)
        #expect(cards[0].textOrigin == card.textOrigin && cards[0].style.fontSize == card.style.fontSize)
        #expect(cards[0].sourcePanels[0].rect == card.sourcePanels[0].rect)
        #expect(cards[0].typography.rangeBounds == card.typography.rangeBounds)
    }
    @Test func sharedSourceOwnershipKeepsPlateDespiteSafeOwnMask() throws {
        let (card,layout,initial,settings) = try fixture()
        var data = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(card.item)) as? [String:Any])
        data["id"] = "foreign-source";data["sourceTextOnly"] = true
        let other = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:data))
        let shared = NativeTranslationLayout(imageSize:layout.imageSize,sourceRect:layout.sourceRect,viewport:layout.viewport,items:[card.item,other])
        var restoration = initial,cards = [card]
        let session = NativeTypographyPostPolish.rendererGrowthSession(layout:shared,restoration:restoration,settings:settings,sourceImage:nil)
        let budget = try NativeTranslationRenderer.protectInitialArtwork(cards:&cards,restoration:&restoration,layout:shared,
            source:nil,settings:settings,surfaceQuery:query(session))
        #expect(cards[0].artworkRecord == nil && cards[0].item == card.item)
        #expect(cards[0].sourcePanels.count == 1 && cards[0].sourcePanels[0].rect == card.sourcePanels[0].rect)
        #expect(budget.surface == 1_048_576)
    }

}
