import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Run after effect lettering has chosen its surviving nodes/plates. Keep
    /// raster repairs: the dropped source is restored later by kept-lettering.
    static func recoverLines(cards: inout [Card], gloss: inout NativeTranslationEffectGloss.Refinement,
        layout: NativeTranslationLayout, source: CGImage?, settings: IPhoneOverlaySettings) throws -> NativeRecoveredLineProtection.Result {
        // Every production Card retains the page cleanup frame selected before
        // restoration. Recovered source checks use that frame, independent of
        // the original OCR/display descriptor retained in layout.sourceRect.
        let cleanupFrame = cards.compactMap(\.cleanupSourceFrame).first ?? layout.sourceRect
        let cardByID = Dictionary(cards.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        let records = layout.items.map { item -> NativeRecoveredLineProtection.Item in
            let card = cardByID[item.id]
            let visible = card != nil && !gloss.hiddenIDs.contains(item.id) && !gloss.removedLayerIDs.contains(item.id)
            var plates: [NativeRecoveredLineProtection.Plate] = []
            if visible, let card {
                plates += card.sourcePanels.map { panel in
                    .init(rect: card.rotatesSourcePanels ? rotatedBounds(panel.rect, about: card.sourcePlateRect, angle: item.rotation) : panel.rect,
                        color: panel.background)
                }
                plates += card.backings.map { .init(rect: $0.frame, color: $0.color) }
                if let color = item.sourceErasureRGB {
                    plates += columnSourceErasureRects(card, settings: settings).map {
                        .init(rect: $0, color: color.map { Double($0) })
                    }
                }
                // A source-colour-preserving rotated fallback can still paint
                // its plate on the text node rather than a detached panel.
                if card.drawsPanel, item.rotation != 0, settings.preserveSourceBackgroundColor, item.sourceColorEligible {
                    let frame = card.straightenedPanelRect ?? card.sourcePlateRect
                    let rect = card.straightenedPanelRect == nil ? rotatedBounds(frame, about: card.sourcePlateRect, angle: item.rotation) : frame
                    plates.append(.init(rect: rect, color: rgb(card.background)))
                }
            }
            return .init(id: item.id, recoveredLine: item.recoveredLine, sourceBounds: item.sourceBounds.map { Double($0) },
                sourceFontSize: item.sourceFontSize.map { Double($0) }, hasNode: visible, plates: plates)
        }
        guard let source else {
            return try NativeRecoveredLineProtection.evaluate(items: records, cleanupFrame: cleanupFrame, imageSize: .zero,
                opacity: settings.renderedBackgroundOpacity, read: { _ in nil })
        }
        let reader = NativeSourcePixelReader(image: source)
        defer { reader.release() }
        let result = try NativeRecoveredLineProtection.evaluate(items: records, cleanupFrame: cleanupFrame,
            imageSize: CGSize(width: source.width, height: source.height), opacity: settings.renderedBackgroundOpacity) { crop in
            try reader.read(x: Double(crop.x), y: Double(crop.y), sourceWidth: Double(crop.sourceWidth),
                sourceHeight: Double(crop.sourceHeight), width: crop.width, height: crop.height)
        }
        for index in cards.indices where result.droppedIDs.contains(cards[index].item.id) {
            cards[index].sourcePanels.removeAll(); cards[index].backings.removeAll()
            cards[index].drawsPanel = false
            cards[index].sourceLayersSuppressed = true
        }
        gloss.hiddenIDs.formUnion(result.droppedIDs)
        return result
    }
}
