import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    static func fitLatePageEdges(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement, layout: NativeTranslationLayout) {
        for i in cards.indices {
            let card = cards[i], item = card.item
            let frame = card.cleanupSourceFrame ?? layout.sourceRect
            guard valid(frame) else { continue }
            guard item.rotation == 0, !gloss.hiddenIDs.contains(item.id), !gloss.removedLayerIDs.contains(item.id) else { continue }
            var proposal: Card?
            let result = NativePageEdgeFit.fit(ink: cardWholeRangeRect(card) ?? .zero, frame: frame,
                font: Double(card.style.fontSize), pitch: Double(card.style.lineHeight),
                plated: card.captionParentPlate,
                allowsResize: item.allowsAutomaticFontRecovery) { font, pitch in
                var measured = card
                measured.style.fontSize = CGFloat(font); measured.style.lineHeight = CGFloat(pitch)
                measured.style.tracking = -CGFloat(font) * 0.012; measured.finalFontSize = CGFloat(font)
                measured.typography = remeasureTypography(measured)
                proposal = measured
                return cardWholeRangeRect(measured) ?? .zero
            }
            guard let result else { continue }
            if result.outcome == "unresolved" { cards[i].edgeFit = result.outcome; continue }
            var next = result.outcome == "shrink" ? proposal ?? card : card
            next.textShift.x = CGFloat((Float(item.x + card.textShift.x + result.shift.x) * 64).rounded(.towardZero)) / 64 - item.x
            next.textShift.y = CGFloat((Float(item.y + card.textShift.y + result.shift.y) * 64).rounded(.towardZero)) / 64 - item.y
            next.edgeFit = result.outcome
            cards[i] = next
        }
    }
}
