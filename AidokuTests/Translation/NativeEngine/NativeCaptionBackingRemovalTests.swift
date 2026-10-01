import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCaptionBackingRemovalTests {
    private func entry(id: String = "2", sourceTextOnly: Bool = false, source: CGRect? = nil) -> NativeTranslationCaptionPanelPolish.Entry {
        let owner = CGRect(x: 238.890625, y: 233.765625, width: 24, height: 115.546875)
        var entry = NativeTranslationCaptionPanelPolish.Entry(id: id, sourceTextOnly: sourceTextOnly,
            rotation: 0, vertical: false, lettering: nil, wrappingScript: "korean", font: 7,
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            sources: [source ?? CGRect(x: 242.406015, y: 237.26291, width: 13.2, height: 109)],
            balancedColumn: false, column: nil, columnPaddingTop: 0,
            ink: CGRect(x: 241.921875, y: 265.46875, width: 17.921875, height: 50),
            panels: [.init(rect: owner, background: [58, 72, 68], coverage: [owner])])
        entry.backings = [.init(frame: owner,
            coverage: [CGRect(x: 239.921875, y: 263.46875, width: 21.921875, height: 54)],
            color: [58, 72, 68])]
        return entry
    }

    @Test(arguments: ["equal", "different-color", "outside-full-box", "exact-tolerance", "transformed", "partial-clip", "ineligible-node"])
    func removesOnlySameColorCloneInsideSingleFlatOwner(mode: String) {
        var value = entry(sourceTextOnly: mode == "ineligible-node")
        switch mode {
        case "different-color": value.backings[0].color = [58, 72, 69]
        case "outside-full-box": value.backings[0].frame.origin.x -= 0.251
        case "exact-tolerance": value.backings[0].frame.origin.x -= 0.25; value.backings[0].frame.size.width += 0.5
        case "transformed": value.panels[0].isFlat = false
        case "partial-clip":
            value.panels[0].clipped = true; value.panels[0].captionUnionClipped = true
            value.panels[0].coverage = [CGRect(x: 240, y: 240, width: 5, height: 5)]
        default: break
        }
        let result = NativeTranslationCaptionPanelPolish.polish([value], opacity: 1, kept: [])
        let removes = ["equal", "exact-tolerance", "ineligible-node"].contains(mode)
        #expect(result[0].backings.isEmpty == removes)
        #expect(result[0].ink == value.ink)
    }

    @Test func removesCloneBeforeNeighborSpacingNarrowsItsOwner() {
        let original = entry()
        var neighbor = entry(id: "3", source: CGRect(x: 264, y: 237, width: 15, height: 109))
        neighbor.ink = CGRect(x: 264, y: 265, width: 15, height: 50)
        neighbor.panels[0].rect = CGRect(x: 259, y: 233.765625, width: 25, height: 115.546875)
        neighbor.panels[0].coverage = [neighbor.panels[0].rect]; neighbor.backings = []
        let result = NativeTranslationCaptionPanelPolish.polish([original, neighbor], opacity: 1, kept: [])
        #expect(result[0].backings.isEmpty)
        #expect(result[0].panels[0].rect.width < original.backings[0].frame.width)
        #expect(!NativeTranslationCaptionPanelPolish.contains(result[0].panels[0].rect, original.backings[0].frame))
    }

    @Test(arguments: [false, true])
    func actualCaptionAdapterTransportsBackingRemovalAndRetainsOutsideClone(outside: Bool) throws {
        let fields: [String: Any] = ["id": "backing", "text": "AB", "x": 20, "y": 20,
            "width": 60, "height": 60, "fontSize": 8, "lineHeight": 10,
            "paddingTop": 3, "paddingRight": 3, "paddingBottom": 3, "paddingLeft": 3,
            "sourceFrame": [0, 0, 100, 100], "sourceBounds": [0.3, 0.3, 0.2, 0.2],
            "sourceTextOnly": false, "wrappingScript": "korean"]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontSize: 8,
            foreground: NativeTranslationRenderer.color([255, 255, 255]), lineHeight: 10)
        let typography = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        var card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            drawsPanel: false, background: NativeTranslationRenderer.color([58, 72, 68]),
            usesFallbackVeil: false, lightSurface: false, heavyStrokeWidth: 0, finalFontSize: 8)
        card.sourcePanels = [.init(rect: item.rect, background: [58, 72, 68], coverage: [item.rect])]
        let clone = CGRect(x: outside ? 19.749 : 20, y: 20, width: 60, height: 60)
        card.backings = [.init(frame: clone, coverage: [CGRect(x: 30, y: 30, width: 10, height: 10)], color: [58, 72, 68])]
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 100, height: 100),
            sourceRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            viewport: CGSize(width: 100, height: 100), items: [item])
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white,
            opacity: 1, textPlacement: .replace, subtitlePosition: .bottom,
            subtitleMaxLines: 3, subtitleContextSentences: 0)
        var cards = [card]
        NativeTranslationRenderer.polishCaptionPanels(cards: &cards, glossCards: [], gloss: .init(),
            layout: layout, settings: settings, source: nil)
        #expect(cards[0].backings.isEmpty == !outside)
        #expect(cards[0].item == item)
        #expect(cards[0].style.fontSize == card.style.fontSize)
        #expect(cards[0].sourcePanels[0].rect == card.sourcePanels[0].rect)
    }
}
