import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeRotatedReadabilityTests {
    private func fixture(width: Double = 60,height: Double = 35,text: String = "가나 다라") throws -> (NativeTranslationRenderer.Card,NativeTranslationLayout,IPhoneOverlaySettings) {
        let object: [String:Any] = ["id":"opaque-rotated","text":text,"wrappingScript":"korean","fontScript":"korean",
            "x":100,"y":100,"width":width,"height":height,"fontSize":6,"lineHeight":7.2,"rotation":0.2,"paddingTop":2,"paddingBottom":2,"paddingLeft":2,"paddingRight":2,
            "sourceBounds":[0.3,0.3,0.2,0.15],"sourceFrame":[0,0,300,300]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:object))
        let style = NativeTranslationTypography.Style(fontScript:"korean",fontSize:6,lineHeight:7.2)
        var card = NativeTranslationRenderer.Card(item:item,
            typography:NativeTranslationTypography.layout(text:text,in:item.contentRect.size,style:style),style:style,
            drawsPanel:false,background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:6)
        card.rotatesSourcePanels = true;card.sourceBackgroundKind = "rotated-panel"
        card.sourcePanels = [.init(rect:item.rect,background:[245,245,245],radius:6,coverage:[item.rect])]
        let size = CGSize(width:300,height:300),layout = NativeTranslationLayout(imageSize:size,sourceRect:CGRect(origin:.zero,size:size),viewport:size,items:[item])
        let settings = IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,textPlacement:.replace,
            subtitlePosition:.bottom,subtitleMaxLines:2,subtitleContextSentences:0)
        return (card,layout,settings)
    }
    @Test func actualCoreTextLiftCommitsOpaquePlateAndClip() throws {
        let (card,layout,settings) = try fixture()
        var cards = [card]
        let budget = try NativeTranslationRenderer.liftFinalRotatedReadability(cards:&cards,gloss:.init(),layout:layout,source:nil,settings:settings)
        #expect(budget.lifted == 1)
        #expect(cards[0].finalFontSize >= 8.5 && cards[0].finalFontSize <= 9)
        #expect(cards[0].sourcePlateRect.midX == card.sourcePlateRect.midX)
        #expect(cards[0].sourcePlateRect.midY == card.sourcePlateRect.midY)
        #expect(cards[0].effectiveTextRotation == card.effectiveTextRotation)
        #expect(cards[0].style.foreground == card.style.foreground)
        #expect(cards[0].slantedClip?.count == 4)
        #expect(cards[0].sourcePanels[0].rect.width == cards[0].item.width * cards[0].style.horizontalScale)
        #expect(cards[0].rotatedReadability?["readablePeer"] == "6")
    }
    @Test func grownOpaquePlateRequiresActualFlatPagePixels() throws {
        let (card,layout,settings) = try fixture(width:25,height:12,text:"가나다라 마바사아")
        var paper = NativeRestorationPixels(width:300,height:300)
        paper.rgba = Array(repeating:[UInt8](arrayLiteral:245,245,245,255),count:paper.count).flatMap{$0}
        var art = paper
        art.rgba = Array(repeating:[UInt8](arrayLiteral:50,70,90,255),count:art.count).flatMap{$0}
        var allowed = [card],blocked = [card]
        let paperImage = try #require(paper.image()),artImage = try #require(art.image())
        let accepted = try NativeTranslationRenderer.liftFinalRotatedReadability(cards:&allowed,gloss:.init(),layout:layout,source:paperImage,settings:settings)
        let rejected = try NativeTranslationRenderer.liftFinalRotatedReadability(cards:&blocked,gloss:.init(),layout:layout,source:artImage,settings:settings)
        #expect(accepted.lifted == 1 && accepted.pixels < 786432)
        #expect(rejected.lifted == 0 && rejected.pixels < 786432)
        #expect(blocked[0].item == card.item && blocked[0].finalFontSize == 6)
        #expect(allowed[0].sourcePanels[0].rect.width > card.sourcePanels[0].rect.width || allowed[0].sourcePanels[0].rect.height > card.sourcePanels[0].rect.height)
    }
}
