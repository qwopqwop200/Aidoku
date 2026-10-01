import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeTypographyHarmonyScaleTests {
    private func caption(_ id: String = "owned-scale") throws -> NativeTranslationRenderer.Card {
        let descriptor: [String: Any] = ["id":id, "text":"검증문",
            "x":40,"y":40,"width":18,"height":54,"fontSize":5,"lineHeight":6,
            "paddingTop":3,"paddingRight":3,"paddingBottom":3,"paddingLeft":3,
            "fontScript":"korean","wrappingScript":"korean", "sourceBounds":[0.2,0.2,0.1,0.3], "sourceFrame":[0,0,200,200]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from:JSONSerialization.data(withJSONObject:descriptor))
        let style = NativeTranslationTypography.Style(fontScript:"korean",fontSize:5,lineHeight:6,
            optimizesKoreanWrapping:false,balancesHorizontalLines:true)
        var card = NativeTranslationRenderer.Card(item:item,
            typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),
            style:style,drawsPanel:false,background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,
            lightSurface:true,heavyStrokeWidth:0,finalFontSize:5)
        card.captionParentPlate = true
        card.sourceBackgroundKind = "readability-panel"
        card.sourcePanels = [.init(rect:CGRect(x:35,y:30,width:30,height:75),background:[240,240,240],
            coverage:[CGRect(x:35,y:30,width:30,height:75)])]
        return card
    }
    @Test func transparentTextGrowsInsideSeparateOwnerWithoutRestoration() throws {
        let original = try caption(), before = try #require(NativeTranslationRenderer.cardWholeRangeRect(original))
        let next = try #require(NativeTranslationRenderer.scaleTypographyHarmony(original,size:6.75,
            peers:[original],frame:CGRect(x:0,y:0,width:200,height:200)))
        let after = try #require(NativeTranslationRenderer.cardWholeRangeRect(next))
        #expect(next.finalFontSize == 6.75)
        #expect(next.item.width > original.item.width && next.item.height > original.item.height)
        // CSS independently truncates the proposed left/top to a 1/64px unit.
        #expect(abs(before.midX-after.midX) < 1.0/64 && abs(before.midY-after.midY) < 1.0/64)
        let parent = original.sourcePanels[0].rect.origin
        #expect((next.item.x-parent.x)*64 == ((next.item.x-parent.x)*64).rounded(.towardZero))
        #expect((next.item.y-parent.y)*64 == ((next.item.y-parent.y)*64).rounded(.towardZero))
        #expect(next.textShift == .zero)
        #expect(next.sourcePanels[0].rect == original.sourcePanels[0].rect)
        #expect(next.sourceBackgroundKind == "readability-panel")
        #expect(next.item.typesettingQuoteMode == original.item.typesettingQuoteMode)
    }
    @Test func negativeFractionalOriginUsesActualParentCoordinateUnits() throws {
        var original = try caption()
        // A detached child begins at its owner's left edge. Enlargement places
        // its CSS left before that origin while its glyphs remain in coverage.
        original.textShift = CGPoint(x:0.0078125,y:0.0078125)
        let plate = NativeTranslationSourceStylePostPolish.Panel(
            rect: CGRect(x:40,y:20,width:45,height:100),background:[240,240,240],
            coverage:[CGRect(x:40,y:20,width:45,height:100)])
        original.sourcePanels = []
        var ownerCard = try caption("plate-owner")
        ownerCard.sourcePanels = [plate]
        ownerCard.item.x = 150; ownerCard.item.y = 150
        let owner = NativeTranslationRenderer.TypographyHarmonyOwner(
            panel: plate,cardID:ownerCard.item.id,panelIndex:0)
        let next = try #require(NativeTranslationRenderer.scaleTypographyHarmony(original,size:6.75,
            peers:[original,ownerCard],frame:CGRect(x:0,y:0,width:200,height:200),owner:owner))
        let relativeX = next.item.x-plate.rect.minX
        #expect(relativeX < 0)
        #expect(relativeX*64 == (relativeX*64).rounded(.towardZero))
        #expect((next.item.y-plate.rect.minY)*64 == ((next.item.y-plate.rect.minY)*64).rounded(.towardZero))
        #expect(next.textShift == .zero)
        #expect(next.sourcePanels.isEmpty && ownerCard.sourcePanels[0].rect == plate.rect)
        let before = try #require(NativeTranslationRenderer.cardWholeRangeRect(original))
        let after = try #require(NativeTranslationRenderer.cardWholeRangeRect(next))
        #expect(abs(before.midX-after.midX) < 1.0/64 && abs(before.midY-after.midY) < 1.0/64)
    }
    @Test func PaintedTextNodeCannotUseTransparentParentGrowth() throws {
        var original = try caption(); original.drawsPanel = true
        #expect(NativeTranslationRenderer.scaleTypographyHarmony(original,size:6.75,
            peers:[original],frame:nil) == nil)
        #expect(original.finalFontSize == 5 && original.item.width == 18)
    }
    @Test func ownerCoverageMustHoldGrownInkWithExistingMargin() throws {
        var original = try caption()
        let before = try #require(NativeTranslationRenderer.cardWholeRangeRect(original))
        original.sourcePanels[0].coverage = [before]
        #expect(NativeTranslationRenderer.scaleTypographyHarmony(original,size:6.75,
            peers:[original],frame:nil) == nil)
        #expect(original.sourcePanels[0].coverage == [before])
    }
}
