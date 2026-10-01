import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Frozen final-plate linkage follows pixel trims and precedes glyph covers.
    /// Relink rollback is resolved by the pure stage before any card is mutated.
    @discardableResult
    static func linkFinalPlates(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
        layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
        source: CGImage?, settings: IPhoneOverlaySettings) throws -> NativeFinalPlateLinkage.Result {
        var owners: [(card: Int, panel: Int)] = []
        var panels: [NativeFinalPlateLinkage.Panel] = []
        for index in cards.indices {
            let card = cards[index], item = card.item
            let shown = !gloss.removedLayerIDs.contains(item.id)
            let patch = restoration.patches.last { $0.itemID == item.id &&
                ($0.candidate != nil || $0.slantedProof != nil) && $0.candidate?.provisional != true }
            for pi in card.sourcePanels.indices {
                let panel = card.sourcePanels[pi]
                // Every plate remains in the foreign-plate collision query,
                // including rotated ones that cannot themselves be linked.
                let rotated = card.rotatesSourcePanels || panel.rotated
                let box = rotated ? rotatedBounds(panel.rect, about: item.rect, angle: item.rotation) : panel.rect
                let explicitCoverage = panel.clipped || panel.captionUnionClipped || panel.coverage != [panel.rect]
                owners.append((index, pi))
                panels.append(.init(id: item.id, box: box,
                    coverage: rotated ? nil : explicitCoverage ? panel.coverage : nil,
                    color: panel.background, rootChild: true, sourceErasure: panel.sourceErasure,
                    preservedCaption: card.preservedGloss || card.preservedErasure,
                    foreignFills: !card.foreignFills.isEmpty, transformed: rotated,
                    backing: !card.backings.isEmpty, shown: shown,
                    unknownClip: false, restoration: patch?.rect))
            }
            // Frozen foreign-layer selection includes source-rotated-panel.
            if card.drawsPanel && item.rotation != 0 && card.sourcePanels.isEmpty {
                owners.append((index, -1))
                panels.append(.init(id: item.id, box: rotatedBounds(card.straightenedPanelRect ?? item.rect, about: item.rect, angle: item.rotation),
                    coverage: nil, color: rgb(card.background) ?? [], rootChild: true, sourceErasure: false,
                    preservedCaption: false, foreignFills: false, transformed: true, backing: false,
                    shown: shown, unknownClip: false, restoration: nil))
            }
        }
        let nodes = cards.map { card in NativeFinalPlateLinkage.Node(id: card.item.id, ink: cardWholeRangeRect(card) ?? .zero,
            font: Double(card.style.fontSize), shown: !gloss.hiddenIDs.contains(card.item.id) && !gloss.removedLayerIDs.contains(card.item.id),
            transformed: card.effectiveTextRotation != 0, fits: card.typography.fits,
            sampledColors: {
                let sample = restoration.appearances[card.item.id]?.sourceSample ?? [:]
                return [NativeSourceColorSampler.rgb(sample["foreground"] ?? sample["displayForeground"]),NativeSourceColorSampler.rgb(sample["stroke"])].compactMap { $0 }
            }()) }
        let items = layout.items.map { item in NativeFinalPlateLinkage.Item(id: item.id, rotation: Double(item.rotation),
            vertical: item.vertical, sourceVertical: item.sourceVertical, sourceFont: item.sourceFontSize.map { Double($0) },
            sourceBounds: item.sourceBounds.map { Double($0) }, auxiliaryBounds: item.auxiliaryInkRects.map { $0.map { Double($0) } }) }
        let reader = source.map { NativeSourcePixelReader(image: $0) }
        defer { reader?.release() }
        let result = try NativeFinalPlateLinkage.resolve(items: items, nodes: nodes, panels: panels,
            frame: restoration.cleanupGeometry?.frame ?? layout.sourceRect,
            imageSize: source.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
            opacity: settings.renderedBackgroundOpacity, preserveBackground: settings.preserveSourceBackgroundColor,
            milliseconds: { ProcessInfo.processInfo.systemUptime * 1000 }) { crop in
                try Task.checkCancellation()
                return try reader?.read(x: Double(crop.x), y: Double(crop.y), sourceWidth: Double(crop.width),
                    sourceHeight: Double(crop.height), width: crop.width, height: crop.height)
            }
        for link in result.links {
            let owner = owners[link.panelIndex]
            guard owner.panel >= 0 else { continue }
            if link.single {
                cards[owner.card].sourcePanels[owner.panel].rect = link.pieces[0]
                cards[owner.card].sourcePanels[owner.panel].coverage = link.pieces
            } else {
                cards[owner.card].sourcePanels[owner.panel].coverage = link.pieces
                cards[owner.card].sourcePanels[owner.panel].clipped = true
                cards[owner.card].sourcePanels[owner.panel].coverageClip = NativeCSSCoveragePath.declaration(coverage: link.pieces, origin: cards[owner.card].sourcePanels[owner.panel].rect.origin, commands: .absolute)
            }
            if let move = link.move {
                cards[owner.card].textShift.x += move.x
                cards[owner.card].textShift.y += move.y
            }
        }
        return result
    }
}
