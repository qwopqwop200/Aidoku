import CoreGraphics

extension NativeTranslationRenderer {
    static func clipSkippedCaptionBridges(cards: inout [Card], skippedIDs: Set<String>,
        layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
        finalInks: [CGRect], rememberedPadding: [String: CGFloat] = [:]) {
        let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        let sources = layout.items.filter { !$0.keptLettering }.map { item -> NativeSkippedCaptionBridge.Source in
            let card = cards.first { $0.item.id == item.id }
            return .init(bounds: ([item.sourceBounds] + item.auxiliaryInkRects).compactMap { pageRect($0, frame: frame) },
                font: Double(card?.finalFontSize ?? 10), sourceFont: item.sourceFontSize.map(Double.init),
                priorPadding: Double(rememberedPadding[item.id] ?? 0),
                vertical: item.sourceVertical,
                oversizedUnrestored: card?.sourceRestorationMetadata["sourceErasurePreserved"] == "oversized-unrestored")
        }
        let required = NativeSkippedCaptionBridge.required(sources, inks: finalInks)
        for index in cards.indices where skippedIDs.contains(cards[index].item.id) {
            let card = cards[index]
            guard pageRect(card.item.sourceBounds, frame: frame) != nil,
                  card.sourceRestorationMetadata["sourceErasurePreserved"] != "oversized-unrestored" else { continue }
            for panelIndex in cards[index].sourcePanels.indices {
                let panel = cards[index].sourcePanels[panelIndex]
                let original = panel.captionUnionClipped ? panel.coverage : [panel.rect]
                guard let coverage = NativeSkippedCaptionBridge.coverage(layer: panel.rect, original: original, required: required) else { continue }
                cards[index].sourcePanels[panelIndex].coverage = coverage
                cards[index].sourcePanels[panelIndex].clipped = true
                cards[index].sourcePanels[panelIndex].coverageClip = NativeCSSCoveragePath.declaration(coverage: coverage, origin: panel.rect.origin, commands: .relative)
                cards[index].sourcePanels[panelIndex].captionUnionClipped = true
                cards[index].sourcePanels[panelIndex].sourceBridgeClipped = true
            }
            for backingIndex in cards[index].backings.indices {
                let backing = cards[index].backings[backingIndex]
                let original = backing.coverage.isEmpty ? [backing.frame] : backing.coverage
                guard let coverage = NativeSkippedCaptionBridge.coverage(layer: backing.frame, original: original, required: required) else { continue }
                cards[index].backings[backingIndex].coverage = coverage
                cards[index].backings[backingIndex].clipped = true
                cards[index].backings[backingIndex].coverageClip = NativeCSSCoveragePath.declaration(coverage: coverage, origin: backing.frame.origin, commands: .relative)
                cards[index].backings[backingIndex].captionUnionClipped = true
                cards[index].backings[backingIndex].sourceBridgeClipped = true
            }
        }
    }
}
