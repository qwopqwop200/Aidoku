import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeMinimalRestoredPlateTests {
    private func fixture(painted: Bool = false, forced: Bool = false, candidateComplete: Bool = true) throws ->
        (NativeTranslationRenderer.Card, NativeTranslationLayout, NativeTranslationRestoration.Result, IPhoneOverlaySettings) {
        let data = Data(#"{"id":"minimal","text":"I","sourceBounds":[0.25,0.25,0.5,0.5],"sourceFrame":[0,0,40,32],"sourceFontSize":8,"x":10,"y":8,"width":20,"height":16,"fontSize":8,"lineHeight":10}"#.utf8)
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: data)
        let size = CGSize(width: 40, height: 32), frame = CGRect(origin: .zero, size: size)
        var original = NativeRestorationPixels(width: 40, height: 32)
        original.rgba = Array(repeating: [UInt8](arrayLiteral: 210, 220, 230, 255), count: original.count).flatMap { $0 }
        var repaired = original
        repaired.rgba = Array(repeating: 0, count: original.count * 4)
        if painted { repaired.rgba.replaceSubrange(164..<168, with: [180, 190, 200, 128]) }
        repaired.layoutSafe = Array(repeating: 1, count: repaired.count)
        repaired.erasureComplete = candidateComplete
        let prepared = NativeSpatialSourceCrop.Prepared(pixels: original, crop: frame,
            source: CGRect(x: 10,y: 8,width: 20,height: 16), box: CGRect(x: 10,y: 8,width: 20,height: 16),
            auxiliary: [], excluded: [], marks: [], leadingRule: false, sx: 1, sy: 1, synthetic: [])
        let candidate = try #require(NativeRestorationCandidate(prepared: prepared, repaired: repaired,
            luminance: Array(repeating: 120,count: repaired.count), imageSize: size, frame: frame, item: item))
        let image = try #require(candidate.image())
        var restoration = NativeTranslationRestoration.Result()
        restoration.patches = [.init(image: image,rect: frame,itemID: item.id,layoutSafe: repaired.layoutSafe,
            finalForcedErasure: forced, candidate: forced ? nil : candidate,
            rasterGeometry: .init(frame: frame,imageSize: size,origin: .zero,scale: CGSize(width: 1,height: 1)))]
        restoration.appearances[item.id] = .init(foreground: nil,background: nil,restored: true,erasureComplete: true)
        let style = NativeTranslationTypography.Style(fontSize: 8)
        let typography = NativeTranslationTypography.layout(text: item.text,in: item.contentRect.size,style: style)
        var card = NativeTranslationRenderer.Card(item: item,typography: typography,style: style,
            drawsPanel: false,background: CGColor(gray: 1,alpha: 1),usesFallbackVeil: false,
            lightSurface: true,heavyStrokeWidth: 0,finalFontSize: 8)
        card.sourcePanels = [.init(rect: frame,background: [210,220,230],coverage: [frame])]
        let layout = NativeTranslationLayout(imageSize: size,sourceRect: frame,viewport: size,items: [item])
        var settings = IPhoneOverlaySettings(visible: true,mode: .translateOnly,colorMode: .white,opacity: 1,
            textPlacement: .replace,subtitlePosition: .bottom,subtitleMaxLines: 2,subtitleContextSentences: 0)
        settings.preserveSourceColors = true
        return (card,layout,restoration,settings)
    }
    @Test func transparentCertifiedPaperShrinksWithoutMovingShapedGlyphs() throws {
        let (card,layout,restoration,settings) = try fixture()
        let ink = NativeTranslationRenderer.cardInkRect(card), baseline = card.sourcePanels[0].rect
        var cards = [card]
        NativeTranslationRenderer.minimalRestoredPlates(cards: &cards,gloss: .init(),layout: layout,
            restoration: restoration,settings: settings)
        let expected = ink.insetBy(dx: -3,dy: -3).intersection(baseline)
        #expect(cards[0].sourcePanels[0].rect == expected)
        #expect(cards[0].sourcePanels[0].coverage == [expected])
        #expect(cards[0].item == card.item && cards[0].finalFontSize == card.finalFontSize)
        #expect(cards[0].textOrigin == card.textOrigin && cards[0].typography.glyphBounds == card.typography.glyphBounds)
    }
    @Test func finalForcedRasterGeometryRetainsPartialAlphaRepairExactlyLikeCandidate() throws {
        let (card,layout,candidate,settings) = try fixture(painted: true)
        let (forcedCard,_,forced,_) = try fixture(painted: true,forced: true)
        var first = [card], second = [forcedCard]
        NativeTranslationRenderer.minimalRestoredPlates(cards: &first,gloss: .init(),layout: layout,restoration: candidate,settings: settings)
        NativeTranslationRenderer.minimalRestoredPlates(cards: &second,gloss: .init(),layout: layout,restoration: forced,settings: settings)
        #expect(first[0].sourcePanels[0].rect == second[0].sourcePanels[0].rect)
        #expect(first[0].sourcePanels[0].rect.minX == 0 && first[0].sourcePanels[0].rect.minY == 0)
        #expect(first[0].sourcePanels[0].rect.width < 40 && first[0].sourcePanels[0].rect.height < 32)
    }
    @Test func sourceFrameImagesGrowthAndProvisionalProofRetainOriginalPlate() throws {
        let (card,layout,restoration,settings) = try fixture()
        var framed = card, grown = card, foreign = card
        framed.sourcePanels[0].sourceFrameImage = restoration.patches[0].image
        grown.displayCardGrowth = true
        foreign.foreignFills = [.init(rect: CGRect(x: 1,y: 2,width: 5,height: 6),color: [30,40,50])]
        for input in [framed,grown,foreign] {
            var cards = [input]
            NativeTranslationRenderer.minimalRestoredPlates(cards: &cards,gloss: .init(),layout: layout,restoration: restoration,settings: settings)
            #expect(cards[0].sourcePanels[0].rect == input.sourcePanels[0].rect)
        }
        restoration.patches[0].candidate?.provisional = true
        var cards = [card]
        NativeTranslationRenderer.minimalRestoredPlates(cards: &cards,gloss: .init(),layout: layout,restoration: restoration,settings: settings)
        #expect(cards[0].sourcePanels[0].rect == card.sourcePanels[0].rect)
    }
    @Test func hiddenCaptionDoesNotReleaseItsSourcePlate() throws {
        let (card,layout,restoration,settings) = try fixture()
        var gloss = NativeTranslationEffectGloss.Refinement()
        gloss.hiddenIDs.insert(card.item.id)
        var cards = [card]
        NativeTranslationRenderer.minimalRestoredPlates(cards: &cards,gloss: gloss,layout: layout,restoration: restoration,settings: settings)
        #expect(cards[0].sourcePanels[0].rect == card.sourcePanels[0].rect)
    }
    @Test(arguments: [true, false])
    func currentCanvasCompletionOverridesStaleAppearanceForPlateShrink(candidateComplete: Bool) throws {
        let (card,layout,initialRestoration,settings) = try fixture(candidateComplete:candidateComplete)
        var restoration = initialRestoration
        let candidate = try #require(restoration.patches[0].candidate)
        #expect(candidate.erasureComplete == candidateComplete)
        restoration.appearances[card.item.id] = .init(foreground:nil,background:nil,restored:true,
            erasureComplete:!candidateComplete)
        let original = card.sourcePanels[0].rect
        let ink = NativeTranslationRenderer.cardInkRect(card)
        var cards = [card]
        NativeTranslationRenderer.minimalRestoredPlates(cards:&cards,gloss:.init(),layout:layout,
            restoration:restoration,settings:settings)
        let expected = candidateComplete ? ink.insetBy(dx:-3,dy:-3).intersection(original):original
        #expect(cards[0].sourcePanels[0].rect == expected)
        #expect(cards[0].item == card.item && cards[0].typography.glyphBounds == card.typography.glyphBounds)
    }
    @Test(arguments: ["inpainted", "readability-panel", "display-restored"])
    func sourceAlignmentReceivesActualBackgroundModeIndependentlyOfCanvasCompletion(mode: String) throws {
        let (original,layout,initialRestoration,_) = try fixture()
        var restoration = initialRestoration
        restoration.appearances[original.item.id] = .init(foreground:nil,background:nil,restored:true,
            erasureComplete:mode != "inpainted")
        for retainsPlate in [false,true] {
            var card = original
            card.sourceBackgroundKind = mode
            if !retainsPlate { card.sourcePanels = [] }
            let entry = try #require(NativeTranslationRenderer.sourceAlignmentEntry(card:card,frame:layout.sourceRect,
                restoration:restoration,gloss:.init()))
            #expect(entry.backgroundKind == mode)
            #expect(entry.source == CGRect(x:10,y:8,width:20,height:16))
            #expect(entry.ink == NativeTranslationRenderer.cardInkRect(card))
        }
    }
}
