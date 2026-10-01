import Foundation

extension NativeTranslationRenderer {
    /// A render-local DOM parent identity. Cards retain their array positions;
    /// -1 denotes the same panel retained transparently after GlyphCover.
    struct CaptionParentOwner: Equatable, Sendable {
        let cardIndex: Int
        let panelIndex: Int
    }

    /// The actual panel.appendChild commit. Sharing is explicit; overlapping
    /// glyphs, matching colours and foreign background fills are not children.
    @discardableResult
    static func attachCaptionParent(cards: inout [Card], childIndex: Int, ownerIndex: Int, panelIndex: Int) -> Bool {
        guard cards.indices.contains(childIndex), cards.indices.contains(ownerIndex),
              panelIndex == -1 ? cards[ownerIndex].glyphCoverOwnerPanel != nil : cards[ownerIndex].sourcePanels.indices.contains(panelIndex)
        else { return false }
        cards[childIndex].captionParentPlate = true
        cards[childIndex].captionParentOwner = .init(cardIndex: ownerIndex, panelIndex: panelIndex)
        return true
    }

    /// A transparent GlyphCover owner is still the original DOM parent. Move
    /// its identity before removing it from the opaque paint array.
    static func retainCaptionParentOwner(cards: inout [Card], ownerIndex: Int, panelIndex: Int) {
        guard cards.indices.contains(ownerIndex), cards[ownerIndex].glyphCoverOwnerPanel != nil,
              cards[ownerIndex].sourcePanels.indices.contains(panelIndex) else { return }
        for index in cards.indices {
            guard let owner = cards[index].captionParentOwner, owner.cardIndex == ownerIndex else { continue }
            if owner.panelIndex == panelIndex {
                cards[index].captionParentOwner = .init(cardIndex: ownerIndex, panelIndex: -1)
            } else if owner.panelIndex > panelIndex {
                cards[index].captionParentOwner = .init(cardIndex: ownerIndex, panelIndex: owner.panelIndex - 1)
            }
        }
    }

    /// Mirrors immediate panel children. A hidden but retained caption remains
    /// a child; caption line wrappers stay inside the caption and do not count.
    static func refreshCaptionOwnerGraph(cards: inout [Card]) {
        for index in cards.indices {
            for panel in cards[index].sourcePanels.indices { cards[index].sourcePanels[panel].hasForeignChildren = false }
            cards[index].glyphCoverOwnerPanel?.hasForeignChildren = false
        }
        for child in cards.indices {
            guard cards[child].captionParentPlate else {
                cards[child].captionParentOwner = nil
                continue
            }
            guard let owner = cards[child].captionParentOwner else { continue }
            guard cards.indices.contains(owner.cardIndex),
                  owner.panelIndex == -1 ? cards[owner.cardIndex].glyphCoverOwnerPanel != nil : cards[owner.cardIndex].sourcePanels.indices.contains(owner.panelIndex)
            else {
                // An explicit owner removal invalidates the identity. It does
                // not manufacture a root append or choose a replacement plate.
                cards[child].captionParentOwner = nil
                continue
            }
            guard child != owner.cardIndex else { continue }
            if owner.panelIndex == -1 { cards[owner.cardIndex].glyphCoverOwnerPanel?.hasForeignChildren = true }
            else { cards[owner.cardIndex].sourcePanels[owner.panelIndex].hasForeignChildren = true }
        }
    }
}
