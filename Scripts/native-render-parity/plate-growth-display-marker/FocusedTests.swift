import CoreGraphics
import Foundation
import Testing
@testable import Aidoku
@Suite struct NativePlateGrowthDisplayMarkerTests {
    private func card(text: String = "달칵!", width: CGFloat = 83.5, font: CGFloat = 42.75, scale: CGFloat = 1,
                      vertical: Bool = false, staleFont: CGFloat? = nil, sourceGlyph: CGFloat? = nil) throws -> NativeTranslationRenderer.Card {
        var fields: [String: Any] = ["id": "scroll-probe", "text": text, "typesettingText": text,
            "typesettingQuoteMode": 0, "fontScript": "korean", "wrappingScript": "korean",
            "sourceBounds": [0.0,0.0,0.5,0.5], "sourceFrame": [0,0,200,200],
            "x": 0, "y": 0, "width": width, "height": 100, "fontSize": staleFont ?? font,
            "lineHeight": (staleFont ?? font) * 1.2, "vertical": vertical]
        if let sourceGlyph { fields["sourceFontSize"] = sourceGlyph }
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: font,
            vertical: vertical, lineHeight: font * 1.2,
            optimizesKoreanWrapping: false, horizontalScale: scale, usesBlockWordLayout: true)
        let typography = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        return NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            drawsPanel: false, background: NativeTranslationRenderer.color([255,255,255]),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: font)
    }
    @Test(arguments: [nil, "balloon", "rotated-plate"] as [String?])
    func restoredCommitUsesCanonicalDisplayMarkerIncludingDeletion(marker: String?) throws {
        var baseline = try card(text:"AB CD",width:80,font:6)
        baseline.typographyDisplayGrowth = "rotated-plate"
        baseline.item.typesettingDisplayGrowth = "rotated-plate"
        var accepted = baseline
        var item = baseline.item
        item.typesettingDisplayGrowth = marker
        item.height += 0.025
        NativeTranslationRenderer.commitRestoredPlateGrowth(item,to:&accepted,style:accepted.style)
        #expect(accepted.item.typesettingDisplayGrowth == marker)
        #expect(accepted.typographyDisplayGrowth == marker)
        // The immutable original retains both marker representations until a
        // candidate is committed, so failed-policy rollback can recover it.
        #expect(baseline.item.typesettingDisplayGrowth == "rotated-plate")
        #expect(baseline.typographyDisplayGrowth == "rotated-plate")
    }
    @Test func persistentPlateRefitsKeepOriginalStateAndApplyStyleGlyphWithoutReset() throws {
        var baseline = try card(text:"안녕 세상",width:80,font:6,sourceGlyph:10)
        baseline.item.allowsAutomaticFontRecovery = true
        baseline.item.typesettingDisplayGrowth = "rotated-plate"
        baseline.typographyDisplayGrowth = "rotated-plate"
        baseline.sourcePanels = [.init(rect:baseline.item.rect,background:[255,255,255],coverage:[baseline.item.rect])]
        var cards = [baseline]
        let layout = NativeTranslationLayout(imageSize:CGSize(width:200,height:200),sourceRect:CGRect(x:0,y:0,width:200,height:200),
            viewport:CGSize(width:200,height:200),items:[baseline.item])
        let settings = IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,
            textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:2,subtitleContextSentences:1)
        let session = NativeTranslationRenderer.PlateGrowthSession()
        try NativeTranslationRenderer.growPlateTypography(cards:&cards,layout:layout,restoration:.init(),
            settings:settings,source:nil,plateSession:session)
        let initial = try #require(session.snapshot)
        #expect(initial.originalFonts[baseline.item.id] == 6)
        cards[0].item.fontSize = 30; cards[0].style.fontSize = 30; cards[0].finalFontSize = 30
        let restoredResult = session.refit(id:baseline.item.id,cap:8.5,strict:true,styleGlyph:0,cards:&cards)
        let restored = try #require(restoredResult)
        #expect(restored == 8.5 && cards[0].finalFontSize == 8.5)
        let elevatedResult = session.refit(id:baseline.item.id,cap:12,strict:true,styleGlyph:20,cards:&cards)
        let elevated = try #require(elevatedResult)
        #expect(elevated > 9.5 && elevated <= 12)
        let reused = try #require(session.snapshot)
        #expect(reused.originalFonts == initial.originalFonts)
        #expect(reused.flatRoomPixels == initial.flatRoomPixels && reused.wideningPixels == initial.wideningPixels)
        var failed = cards
        let failedResult = session.refit(id:baseline.item.id,cap:1,strict:true,styleGlyph:20,cards:&failed)
        #expect(failedResult == nil)
        #expect(failed[0].finalFontSize == 6 && cards[0].finalFontSize == elevated)
        #expect(failed[0].item.typesettingDisplayGrowth == "rotated-plate")
        #expect(failed[0].typographyDisplayGrowth == "rotated-plate")
        session.close()
        #expect(session.snapshot == nil)
        let closedResult = session.refit(id:baseline.item.id,cap:12,strict:true,styleGlyph:20,cards:&cards)
        #expect(closedResult == nil)
    }
}
