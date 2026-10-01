import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeDisplayPeerCapTests {
    private func card(id: String, font: CGFloat, source: [Double], sourceFont: Double? = nil,
                      rotated: Bool = false, overrides: [String: Any] = [:]) throws -> NativeTranslationRenderer.Card {
        var payload: [String: Any] = ["id": id, "text": "검", "x": 250, "y": 570, "width": 100, "height": 120,
            "fontSize": font, "lineHeight": font * 1.2, "paddingTop": 2, "paddingBottom": 2,
            "paddingLeft": 2, "paddingRight": 2, "sourceBounds": source,
            "sourceFrame": [0, 94.43125, 430, 611.1375], "fontScript": "korean", "wrappingScript": "korean",
            "rotation": rotated ? -0.05639989412133417 : 0, "sourceVertical": false]
        if let sourceFont { payload["sourceFontSize"] = sourceFont }
        payload.merge(overrides) { _, replacement in replacement }
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: payload))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: font,
            tracking: -font * 0.012, lineHeight: font * 1.2, optimizesKoreanWrapping: false,
            horizontalWrapping: .keepAllWithEmergency)
        var result = NativeTranslationRenderer.Card(item: item,
            typography: NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style),
            style: style, drawsPanel: false, background: CGColor(gray: 1, alpha: 1), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: font)
        result.rotatesSourcePanels = rotated
        result.sourceBackgroundKind = rotated ? "rotated-panel" : "inpainted"
        result.sourcePanels = [.init(rect: item.rect, background: [250, 250, 150], coverage: [item.rect])]
        result.authoredTextOrigin = item.rect.origin
        return result
    }
    private func fixture(peerOverrides: [String: Any] = [:]) throws -> [NativeTranslationRenderer.Card] {
        // Focused21 page5 source geometry. Only the middle peer qualifies:
        // glyph75.3548/82.2375 and181.1375pt gap; the closer peer's ratio is1.2645.
        [try card(id: "display", font: 65.75, source: [0.5775, 0.7766051011433597, 0.19125, 0.1943711521547933], rotated: true),
         try card(id: "same-style", font: 33.75, source: [0.1025, 0.12752858399296393, 0.2175, 0.3526824978012313], sourceFont: 75.35483140580426, overrides: peerOverrides),
         try card(id: "near-different-size", font: 20, source: [0.81625, 0.8364116094986808, 0.165, 0.10642040457343888])]
    }
    @Test func postGrowthPeerSizeCapsDisplayBeforeLaterHarmony() throws {
        var cards = try fixture()
        let original = cards[0]
        let changes = NativeTranslationRenderer.capRotatedDisplayPeers(cards: &cards, cleanup: nil, hiddenIDs: [], removedIDs: [])
        #expect(changes["display"] == [65.75, 40.5])
        #expect(cards[0].finalFontSize == 40.5)
        #expect(cards[0].item.fontSize == 40.5 && cards[0].style.fontSize == 40.5)
        #expect(abs(cards[0].style.lineHeight - 48.6) < 1e-10)
        #expect(abs(cards[0].style.tracking + 0.486) < 1e-10)
        #expect(cards[0].typography.fits)
        #expect(cards[0].item.rect == original.item.rect && cards[0].item.rotation == original.item.rotation)
        #expect(cards[0].sourcePanels[0].rect == original.sourcePanels[0].rect)
        #expect(cards[0].sourcePanels[0].coverage == original.sourcePanels[0].coverage)
        #expect(cards[0].authoredTextOrigin == original.authoredTextOrigin)
        #expect(cards[1].finalFontSize == 33.75 && cards[2].finalFontSize == 20)
        #expect(NativeTranslationRenderer.capRotatedDisplayPeers(cards: &cards, cleanup: nil, hiddenIDs: [], removedIDs: []).isEmpty)
    }
    @Test func hiddenDistantDifferentScriptAndDifferentGlyphPeersDoNotCap() throws {
        for exclusion in 0..<5 {
            var hidden = Set<String>(), removed = Set<String>()
            var overrides: [String: Any] = [:]
            switch exclusion {
            case 0: hidden.insert("same-style")
            case 1: removed.insert("same-style")
            case 2: overrides["sourceBounds"] = [0.1025, -2, 0.2175, 0.3526824978012313]
            case 3: overrides["fontScript"] = "latin"
            default: overrides["sourceFontSize"] = 40
            }
            var cards = try fixture(peerOverrides: overrides)
            #expect(NativeTranslationRenderer.capRotatedDisplayPeers(cards: &cards, cleanup: nil,
                hiddenIDs: hidden, removedIDs: removed).isEmpty)
            #expect(cards[0].finalFontSize == 65.75)
        }
    }
    @Test func capRetainsBodyFloorAndFixedTracking() throws {
        var cards = try fixture()
        cards[1].finalFontSize = 10
        cards[0].style.trackingScalesWithFont = false
        cards[0].style.tracking = -0.7
        let changes = NativeTranslationRenderer.capRotatedDisplayPeers(cards: &cards, cleanup: nil, hiddenIDs: [], removedIDs: [])
        #expect(changes["display"] == [65.75, 31.75])
        #expect(cards[0].style.tracking == -0.7)
    }
    @Test func malformedSourceGeometryIsRejectedBeforeRendering() throws {
        // Native layout geometry is immutable and validated at decode time;
        // malformed arrays cannot reach the renderer through a valid item.
        let malformedOverrides: [[String: Any]] = [
            ["sourceFrame": [Double]()], ["sourceBounds": [Double]()], ["sourceFrame": [0, 0, 0, 600]]
        ]
        for overrides in malformedOverrides {
            #expect(throws: DecodingError.self) {
                try card(id: "malformed", font: 65.75,
                    source: [0.5775, 0.7766051011433597, 0.19125, 0.1943711521547933],
                    rotated: true, overrides: overrides)
            }
        }
    }

    @Test func uprightControlledOrHiddenTargetsRemainUnchanged() throws {
        for exclusion in 0..<5 {
            var cards = try fixture()
            var hidden = Set<String>()
            switch exclusion {
            case 0: cards[0].item.rotation = 0
            case 1: cards[0].rotatesSourcePanels = false
            case 2: cards[0].item.typesettingText = "검"
            case 3: hidden.insert("display")
            default: cards[0].style.alignsToTop = true
            }
            #expect(NativeTranslationRenderer.capRotatedDisplayPeers(cards: &cards, cleanup: nil,
                hiddenIDs: hidden, removedIDs: []).isEmpty)
            #expect(cards[0].finalFontSize == 65.75)
        }
    }
}
