import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeDisplayLetteringRestorationTests {
    private func fixture() throws -> (NativeTranslationRenderer.Card,NativeTranslationLayout,CGImage,IPhoneOverlaySettings) {
        let value: [String:Any] = ["id":"display","text":"I","sourceBounds":[6.25/88,8.5/72,75.5/88,55.0/72],
            "sourceFrame":[0,0,88,72],"sourceFontSize":36,"x":20,"y":20,"width":48,"height":28,
            "fontSize":16,"lineHeight":19.2,"fontScript":"latin","wrappingScript":"word",
            "sourceColorEligible":true,"allowsAutomaticFontRecovery":true]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:value))
        var pixels = NativeRestorationPixels(width:88,height:72)
        pixels.rgba = Array(repeating:[UInt8](arrayLiteral:130,130,130,255),count:pixels.count).flatMap { $0 }
        var letters: [(Int,Int)] = []
        for offset in [20,48] { for y in 22..<48 { for x in offset..<offset+17 where x<offset+6 || x>=offset+11 || y>=32 && y<38 { letters.append((x,y)) } } }
        for (x,y) in letters { for yy in y-3...y+3 { for xx in x-3...x+3 { pixels.rgba.replaceSubrange((yy*88+xx)*4..<(yy*88+xx)*4+3,with:[240,240,240]) } } }
        for (x,y) in letters { pixels.rgba.replaceSubrange((y*88+x)*4..<(y*88+x)*4+3,with:[15,15,15]) }
        let image = try #require(pixels.image()),frame = CGRect(x:0,y:0,width:88,height:72)
        let style = NativeTranslationTypography.Style(fontSize:16)
        let type = NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style)
        var card = NativeTranslationRenderer.Card(item:item,typography:type,style:style,drawsPanel:false,
            background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:16)
        card.sourceBackgroundKind = "readability-panel"
        card.sourcePanels = [.init(rect:frame,background:[130,130,130],coverage:[frame])]
        let layout = NativeTranslationLayout(imageSize:frame.size,sourceRect:frame,viewport:frame.size,items:[item])
        var settings = IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,textPlacement:.replace,
            subtitlePosition:.bottom,subtitleMaxLines:2,subtitleContextSentences:0)
        settings.preserveSourceColors = true
        return (card,layout,image,settings)
    }
    @Test func actualPixelMaskAndCoreTextTrialReplaceOneReadabilityPlate() throws {
        let (initial,layout,image,settings) = try fixture()
        var card = initial
        card.item.typesettingQuoteMode = 3; card.style.usesBlockWordLayout = true
        card.item.typesettingPreservedBlockWrapper = true; card.item.typesettingBlockDisplay = true
        card.style.blockWordLayoutUsesTopPadding = true
        card.item.typesettingPreformattedRows = true; card.style.usesPreformattedBlockRows = true
        card.foreignFills = [.init(rect: CGRect(x: 2,y: 3,width: 4,height: 5),color: [40,50,60])]
        card.sourcePlateOwnerRect = card.sourcePanels[0].rect
        var cards = [card],restoration = NativeTranslationRestoration.Result()
        restoration.cleanupGeometry = .init(frame: layout.sourceRect, clip: CGRect(x: 5, y: 5, width: 70, height: 60))
        var metadata: [String:NativeTranslationRenderer.DisplayCohortMetadata] = [card.item.id:.init(backgroundKind:"readability-panel",strokeKind:"none",surfaceRange:nil)]
        let report = try NativeTranslationRenderer.restoreDisplayLettering(cards:&cards,gloss:.init(),layout:layout,
            restoration:&restoration,settings:settings,source:image,metadata:&metadata)
        #expect(report.acceptedIDs == [card.item.id])
        #expect(restoration.patches.count == 1 && cards[0].sourcePanels.isEmpty)
        #expect(cards[0].foreignFills.isEmpty && cards[0].sourcePlateOwnerRect == nil)
        #expect(cards[0].displayRestored && cards[0].sourceBackgroundKind == "display-restored")
        #expect(cards[0].item.typesettingQuoteMode == nil && !cards[0].style.usesBlockWordLayout)
        #expect(cards[0].item.typesettingPreservedBlockWrapper == nil && cards[0].item.typesettingBlockDisplay == nil)
        #expect(!cards[0].style.blockWordLayoutUsesTopPadding)
        #expect(cards[0].item.typesettingPreformattedRows == nil && !cards[0].style.usesPreformattedBlockRows)
        #expect(cards[0].textZ == 3 && (cards[0].textRootOrder ?? 0) > 0)
        #expect(cards[0].sourceStrokeKind == "preserved" && cards[0].style.outlineWidth >= 2)
        #expect(cards[0].finalFontSize >= 36*0.4 && cards[0].finalFontSize > card.finalFontSize)
        #expect(report.remainingColour == 393216-88*72 && report.remainingBlackWhite == 262144-88*72)
        let patch = try #require(restoration.patches.first),bytes = try #require(patch.image.dataProvider?.data) as Data
        #expect(bytes[3] == 0 && bytes[(34*88+22)*4+3] == 255)
        #expect(patch.rasterGeometry?.frame == layout.sourceRect && patch.cleanupClip == restoration.cleanupGeometry?.clip)
        #expect(metadata[card.item.id]?.backgroundKind == "display-restored")
    }
    @Test func absentActualBackgroundModeDoesNotInferPermissionFromPlateGeometry() throws {
        let (card,layout,image,settings) = try fixture()
        var cards = [card],restoration = NativeTranslationRestoration.Result()
        var metadata: [String:NativeTranslationRenderer.DisplayCohortMetadata] = [:]
        let report = try NativeTranslationRenderer.restoreDisplayLettering(cards:&cards,gloss:.init(),layout:layout,
            restoration:&restoration,settings:settings,source:image,metadata:&metadata)
        #expect(report.acceptedIDs.isEmpty && restoration.patches.isEmpty)
        #expect(report.remainingColour == 393216 && report.remainingBlackWhite == 262144)
        #expect(cards[0].sourcePanels[0].rect == card.sourcePanels[0].rect)
    }
    @Test func foreignSourceInsideOwnedBoxVetoesBeforeSpendingPixelBudget() throws {
        let (card,layout,image,settings) = try fixture()
        let foreign = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:Data(#"{"id":"foreign","text":"X","sourceBounds":[0.3,0.3,0.1,0.1],"sourceFrame":[0,0,88,72],"x":26,"y":22,"width":9,"height":9,"fontSize":8,"lineHeight":10}"#.utf8))
        let joined = NativeTranslationLayout(imageSize:layout.imageSize,sourceRect:layout.sourceRect,viewport:layout.viewport,items:[card.item,foreign])
        var cards = [card],restoration = NativeTranslationRestoration.Result()
        var metadata: [String:NativeTranslationRenderer.DisplayCohortMetadata] = [card.item.id:.init(backgroundKind:"readability-panel",strokeKind:"none",surfaceRange:nil)]
        let report = try NativeTranslationRenderer.restoreDisplayLettering(cards:&cards,gloss:.init(),layout:joined,
            restoration:&restoration,settings:settings,source:image,metadata:&metadata)
        #expect(report.acceptedIDs.isEmpty && restoration.patches.isEmpty && report.remainingColour == 393216)
        #expect(cards[0].sourcePanels.count == 1)
    }
}
