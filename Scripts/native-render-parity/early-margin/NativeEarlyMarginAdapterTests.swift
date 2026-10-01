import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeEarlyMarginAdapterTests {
    private func fixture(text: String = "검증", complete: Bool = true, local: Bool = true) throws -> (
        NativeTranslationLayout, NativeTranslationRenderer.Card, NativeTranslationRestoration.Result,
        NativeRestorationCandidate, CGImage, IPhoneOverlaySettings, NativeTypographyPostPolish.RendererGrowthSession) {
        let value: [String:Any] = ["id":"early","text":text,"sourceTextOnly":false,"sourceBounds":[0.4,0.4,0.2,0.2],
            "sourceFrame":[20,30,160,160],"sourceFontSize":16,"x":84,"y":102,"width":32,"height":16,
            "fontSize":12,"lineHeight":14.4,"fontScript":"korean","wrappingScript":text == "ABC" ? "latin":"korean","sourceColorEligible":true]
        let item=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:value))
        let frame=CGRect(x:20,y:30,width:160,height:160)
        let layout=NativeTranslationLayout(imageSize:CGSize(width:160,height:160),sourceRect:frame,
            viewport:CGSize(width:200,height:220),items:[item])
        var source=NativeRestorationPixels(width:160,height:160)
        source.rgba=[UInt8](repeating:255,count:source.count*4)
        for x0 in [70,82] { for y in 72..<87 { for x in x0..<x0+4 {
            source.rgba.replaceSubrange((y*160+x)*4..<(y*160+x)*4+4,with:[20,20,20,255])
        } } }
        let image=try #require(source.image())
        var original=NativeRestorationPixels(width:80,height:80)
        original.rgba=[UInt8](repeating:255,count:original.count*4)
        var repaired=original
        repaired.layoutSafe=[UInt8](repeating:complete ? 1:0,count:repaired.count)
        repaired.erasureComplete=complete;repaired.sourceErasureVerified=complete;repaired.glyphsVerified=complete
        repaired.localProposal=local;repaired.sourceCorePixels=120;repaired.sourceRemainingInk=complete ? 0:120
        let prepared=NativeSpatialSourceCrop.Prepared(pixels:original,crop:CGRect(x:40,y:40,width:80,height:80),
            source:CGRect(x:64,y:64,width:32,height:32),box:CGRect(x:24,y:24,width:32,height:32),
            auxiliary:[],excluded:[],marks:[],leadingRule:false,sx:1,sy:1,synthetic:[])
        let candidate=try #require(NativeRestorationCandidate(prepared:prepared,repaired:repaired,
            luminance:[UInt8](repeating:255,count:repaired.count),imageSize:layout.imageSize,frame:frame,item:item))
        let patch=NativeTranslationRestoration.Patch(image:try #require(candidate.image()),rect:CGRect(x:60,y:70,width:80,height:80),
            itemID:item.id,candidate:candidate,rasterGeometry:.init(frame:frame,imageSize:layout.imageSize,
                origin:prepared.crop.origin,scale:CGSize(width:1,height:1)))
        var restoration=NativeTranslationRestoration.Result();restoration.patches=[patch]
        let black=NativeTranslationRenderer.color([20,20,20]),white=NativeTranslationRenderer.color([255,255,255])
        restoration.appearances[item.id] = .init(foreground:black,background:white,restored:true,erasureComplete:complete,
            sourceGlyphsVerified:complete,provisional:local)
        let style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:12,foreground:black,lineHeight:14.4)
        let shaped=NativeTranslationTypography.layout(text:text,in:item.contentRect.size,style:style)
        let panel=NativeTranslationSourceStylePostPolish.Panel(rect:CGRect(x:78,y:88,width:44,height:44),
            background:[255,255,255],coverage:[CGRect(x:78,y:88,width:44,height:44)])
        let card=NativeTranslationRenderer.Card(item:item,typography:shaped,style:style,sourcePanels:[panel],drawsPanel:false,
            background:white,usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:12)
        var settings=IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,
            textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:3,subtitleContextSentences:0)
        settings.preserveSourceColors=true
        let growth=NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restoration,settings:settings,sourceImage:image)
        growth.context.growth.admitted.insert(item.id)
        growth.context.rememberInk(growth.context.candidate(item))
        return (layout,card,restoration,candidate,image,settings,growth)
    }
    @Test func actualNormalCallbackReleasesPlateAndCommitsOriginalLocalProposal() throws {
        let (layout,card,initial,candidate,image,settings,growth)=try fixture()
        var cards=[card],restoration=initial
        let balloons=NativeTranslationRenderer.BalloonRelayoutContext(layout:layout,source:image,restoration:restoration,cards:cards)
        NativeTranslationRenderer.applyEarlyMargins(cards:&cards,restoration:&restoration,layout:layout,source:image,
            settings:settings,growth:growth,balloons:balloons)
        #expect(cards[0].sourceBackgroundKind == "inpainted")
        #expect(cards[0].sourceRestorationMetadata["balloonFontFit"] == "restored-surface")
        #expect(cards[0].sourcePanels.isEmpty && cards[0].restoredSurfaceFontFit)
        #expect(restoration.patches[0].candidate === candidate)
        NativeTranslationRenderer.commitLocalRestorationProposals(cards:&cards,restoration:&restoration)
        #expect(restoration.patches.count == 1 && !candidate.provisional)
        #expect(cards[0].sourceRestorationMetadata["localRestorationCommitted"] == "true")
        #expect(restoration.patches[0].rasterGeometry?.frame == layout.sourceRect)
    }
    @Test func actualLargerPaperReplacesCandidateAndKeepsIndependentSourceCertificate() throws {
        let (layout,card,initial,old,image,settings,growth)=try fixture(complete:false,local:false)
        var cards=[card],restoration=initial
        let balloons=NativeTranslationRenderer.BalloonRelayoutContext(layout:layout,source:image,restoration:restoration,cards:cards)
        NativeTranslationRenderer.applyEarlyMargins(cards:&cards,restoration:&restoration,layout:layout,source:image,
            settings:settings,growth:growth,balloons:balloons)
        let next=try #require(restoration.patches.first?.candidate)
        #expect(next !== old && next.surface.width == 160 && next.surface.height == 160)
        #expect(next.descriptor.crop == CGRect(x:0,y:0,width:160,height:160))
        #expect(next.frame == old.frame && next.sourceBounds == old.sourceBounds)
        #expect(!next.localRestorationProposal && !next.provisional && next.partialErasureCertified)
        #expect(cards[0].sourceRestorationMetadata["partialMainbodyProof"] == "enclosed-paper-ink")
        #expect(restoration.paperProposalRemaining == 2_097_152-160*160)
        NativeTranslationRenderer.commitLocalRestorationProposals(cards:&cards,restoration:&restoration)
        #expect(restoration.patches.count == 1 && cards[0].sourcePanels.isEmpty)
    }
    @Test func actualRejectedLargerPaperRestoresOldBuffersRevisionAndRemovesUncommittedLocalCanvas() throws {
        let (layout,card,initial,old,image,settings,growth)=try fixture(text:"ABC",complete:false)
        var cards=[card],restoration=initial
        let surface=old.beginTrial(),oldData=try #require(old.image()?.dataProvider?.data) as Data
        let balloons=NativeTranslationRenderer.BalloonRelayoutContext(layout:layout,source:image,restoration:restoration,cards:cards)
        NativeTranslationRenderer.applyEarlyMargins(cards:&cards,restoration:&restoration,layout:layout,source:image,
            settings:settings,growth:growth,balloons:balloons)
        #expect(restoration.patches[0].candidate === old && old.descriptor.crop.width == 80)
        #expect(old.rawRGBA == surface.rgba && old.safe == surface.safe && old.luminance == surface.luminance)
        #expect(old.revision == 2 && cards[0].item == card.item && cards[0].style.fontSize == card.style.fontSize)
        let restoredData=try #require(restoration.patches[0].image.dataProvider?.data) as Data
        #expect(restoredData == oldData && restoration.paperProposalRemaining == 2_097_152-160*160)
        #expect(cards[0].sourcePanels.count == 1 && cards[0].sourceRestorationMetadata["localRestorationCommitted"] == nil)
        old.provisional=false // Immutable original proposal mark still controls cleanup.
        NativeTranslationRenderer.commitLocalRestorationProposals(cards:&cards,restoration:&restoration)
        #expect(restoration.patches.isEmpty && cards[0].sourcePanels.count == 1)
    }
}
