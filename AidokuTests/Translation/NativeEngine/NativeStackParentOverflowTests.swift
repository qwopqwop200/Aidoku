import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeStackParentOverflowTests {
    private func card(id: String) throws -> NativeTranslationRenderer.Card {
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: Data(
            "{\"id\":\"\(id)\",\"text\":\"한  글\",\"sourceBounds\":[0.25,0.25,0.5,0.5],\"sourceFrame\":[0,0,40,32],\"x\":10,\"y\":8,\"width\":20,\"height\":16,\"fontSize\":8,\"lineHeight\":10}".utf8))
        let style = NativeTranslationTypography.Style(fontSize: 8)
        let typography = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        var card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            drawsPanel: false, background: CGColor(gray: 1, alpha: 1), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 8)
        card.sourcePanels = [.init(rect: item.rect, background: [220,230,240], coverage: [item.rect], overflowClip: true)]
        return card
    }

    private func constraints(_ cards: [NativeTranslationRenderer.Card], index: Int) -> [(CGPoint) -> Bool] {
        let identity = cards[index].captionParentPlate ? cards[index].captionParentOwner : nil
        var own: [(rect: CGRect, sourceRotated: Bool)] = []
        var parent: NativeTranslationSourceStylePostPolish.Panel?
        for cardIndex in cards.indices {
            let card = cards[cardIndex]
            for panelIndex in card.sourcePanels.indices where !card.sourcePanels[panelIndex].sourceErasure {
                let panel = card.sourcePanels[panelIndex]
                let key = NativeTranslationRenderer.CaptionParentOwner(cardIndex: cardIndex, panelIndex: panelIndex)
                if key == identity { parent = panel }
                if card.item.id == cards[index].item.id || key == identity {
                    own.append((rect: panel.rect, sourceRotated: card.rotatesSourcePanels))
                }
            }
            if let panel = card.glyphCoverOwnerPanel {
                let key = NativeTranslationRenderer.CaptionParentOwner(cardIndex: cardIndex, panelIndex: -1)
                if key == identity { parent = panel }
                if card.item.id == cards[index].item.id || key == identity {
                    own.append((rect: panel.rect, sourceRotated: panel.rotated))
                }
            }
        }
        return NativeTranslationRenderer.stackClipConstraints(own: own, parent: parent)
    }

    @Test func ordinaryOwnParentAlwaysRetainsRectangleConstraintAndOverflow() throws {
        var cards = [try card(id: "own")]
        #expect(NativeTranslationRenderer.attachCaptionParent(cards: &cards, childIndex: 0, ownerIndex: 0, panelIndex: 0))
        let before = cards[0], clips = constraints(cards, index: 0)
        #expect(clips.count == 1)
        #expect(clips[0](CGPoint(x: before.sourcePanels[0].rect.maxX + 0.5, y: before.sourcePanels[0].rect.midY)))
        #expect(!clips[0](CGPoint(x: before.sourcePanels[0].rect.maxX + 0.5001, y: before.sourcePanels[0].rect.midY)))
        #expect(!NativeTranslationRenderer.releaseStackParentOverflow(cards: &cards, index: 0, hasClipConstraints: !clips.isEmpty))
        #expect(cards[0].sourcePanels[0].overflowClip)
        #expect(cards[0].sourcePanels[0].rect == before.sourcePanels[0].rect)
        #expect(cards[0].sourcePanels[0].coverage == before.sourcePanels[0].coverage)
        #expect(cards[0].item == before.item && cards[0].typography.glyphBounds == before.typography.glyphBounds)
        #expect(cards[0].captionParentOwner == before.captionParentOwner)
    }

    @Test(arguments: ["clipped", "detached", "missing-parent", "removed-parent", "source-erasure"])
    func actualAncestorClipAndDetachedStatesRetainOverflow(state: String) throws {
        var cards = [try card(id: state)]
        cards[0].rotatesSourcePanels = true
        #expect(NativeTranslationRenderer.attachCaptionParent(cards: &cards, childIndex: 0, ownerIndex: 0, panelIndex: 0))
        switch state {
        case "clipped": cards[0].sourcePanels[0].clipped = true
        case "detached": cards[0].captionParentPlate = false
        case "missing-parent": cards[0].captionParentOwner = nil
        case "removed-parent": cards[0].captionParentOwner = .init(cardIndex: 0, panelIndex: 7)
        default: cards[0].sourcePanels[0].sourceErasure = true
        }
        let clips = constraints(cards, index: 0)
        #expect(clips.count == (state == "clipped" ? 1 : 0))
        #expect(!NativeTranslationRenderer.releaseStackParentOverflow(cards: &cards, index: 0, hasClipConstraints: !clips.isEmpty))
        #expect(cards[0].sourcePanels[0].overflowClip)
    }

    @Test func staleClipMarkersOnRotatedParentDoNotSubstituteForCurrentCSSClipPath() throws {
        var cards = [try card(id: "stale")]
        cards[0].rotatesSourcePanels = true
        #expect(NativeTranslationRenderer.attachCaptionParent(cards: &cards, childIndex: 0, ownerIndex: 0, panelIndex: 0))
        cards[0].sourcePanels[0].captionUnionClipped = true
        cards[0].sourcePanels[0].sourceBridgeClipped = true
        let clips = constraints(cards, index: 0)
        #expect(clips.isEmpty && !cards[0].sourcePanels[0].clipped)
        #expect(NativeTranslationRenderer.releaseStackParentOverflow(cards: &cards, index: 0, hasClipConstraints: !clips.isEmpty))
        #expect(!cards[0].sourcePanels[0].overflowClip)
        #expect(cards[0].sourcePanels[0].captionUnionClipped && cards[0].sourcePanels[0].sourceBridgeClipped)
    }

    @Test(arguments: [false, true], [false, true])
    func acceptedSharedAndTransparentParentsUseTheirExactIdentity(transparent: Bool, rotated: Bool) throws {
        var cards = [try card(id: "owner"), try card(id: "child")]
        cards[1].sourcePanels.removeAll()
        cards[0].rotatesSourcePanels = rotated
        cards[0].sourcePanels[0].rotated = rotated
        if transparent {
            cards[0].glyphCoverOwnerPanel = cards[0].sourcePanels[0]
            cards[0].sourcePanels.removeAll()
        }
        #expect(NativeTranslationRenderer.attachCaptionParent(cards: &cards, childIndex: 1,
            ownerIndex: 0, panelIndex: transparent ? -1 : 0))
        let clips = constraints(cards, index: 1)
        #expect(clips.count == (rotated ? 0 : 1))
        #expect(NativeTranslationRenderer.releaseStackParentOverflow(cards: &cards, index: 1, hasClipConstraints: !clips.isEmpty) == rotated)
        if transparent { #expect(cards[0].glyphCoverOwnerPanel?.overflowClip == !rotated) }
        else { #expect(cards[0].sourcePanels[0].overflowClip == !rotated) }
    }

    @Test func extraOrdinaryOwnedPlatePreventsRotatedParentOverflowRelease() throws {
        var cards = [try card(id: "mixed-owner"), try card(id: "mixed-child")]
        cards[0].rotatesSourcePanels = true
        #expect(NativeTranslationRenderer.attachCaptionParent(cards: &cards, childIndex: 1, ownerIndex: 0, panelIndex: 0))
        let clips = constraints(cards, index: 1)
        #expect(clips.count == 1)
        #expect(!NativeTranslationRenderer.releaseStackParentOverflow(cards: &cards, index: 1, hasClipConstraints: !clips.isEmpty))
        #expect(cards[0].sourcePanels[0].overflowClip && cards[1].sourcePanels[0].overflowClip)
    }
}
