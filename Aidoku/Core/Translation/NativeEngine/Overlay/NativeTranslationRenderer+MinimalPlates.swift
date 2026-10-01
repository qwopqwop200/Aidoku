import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// The final ink and caption layout stay fixed; only existing flat source
    /// readability plates lose untouched source-paper area.
    static func minimalRestoredPlates(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
        layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result, settings: IPhoneOverlaySettings) {
        guard settings.renderedBackgroundOpacity == 1, settings.usesSourceInpainting,
              layout.items.filter({ !$0.keptLettering }).count <= 256 else { return }
        let visible = cards.filter { !gloss.hiddenIDs.contains($0.item.id) && !gloss.removedLayerIDs.contains($0.item.id) }
        let inks = Dictionary(visible.map { ($0.item.id, cardInkRect($0)) }, uniquingKeysWith: { first, _ in first })
        for index in cards.indices {
            let card = cards[index], item = card.item
            guard !gloss.hiddenIDs.contains(item.id), !gloss.removedLayerIDs.contains(item.id),
                  item.rotation == 0, !item.balancedColumn, !card.displayCardGrowth, !card.rotatesSourcePanels,
                  card.sourcePanels.count == 1, let panel = card.sourcePanels.first,
                  !panel.sourceErasure, !panel.rotated, panel.sourceFrameImage == nil, card.foreignFills.isEmpty,
                  let patch = restoration.patches.last(where: { $0.itemID == item.id && !$0.independentArtworkCover }), patch.slantedProof == nil,
                  (patch.candidate?.erasureComplete ?? restoration.appearances[item.id]?.erasureComplete ?? false),
                  patch.candidate?.provisional != true, let safe = patch.layoutSafe else { continue }
            let raster: NativeTranslationRestoration.Patch.RasterGeometry
            let rgba: [UInt8]
            if let candidate = patch.candidate {
                raster = .init(frame: candidate.frame, imageSize: candidate.imageSize,
                    origin: candidate.descriptor.crop.origin,
                    scale: CGSize(width: candidate.descriptor.sx, height: candidate.descriptor.sy))
                rgba = candidate.rawRGBA
            } else {
                let image = patch.image
                guard let geometry = patch.rasterGeometry, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
                      image.bytesPerRow == image.width * 4, image.alphaInfo == .last,
                      let bytes = image.dataProvider?.data else { continue }
                raster = geometry; rgba = Array(bytes as Data)
            }
            let image = patch.image
            let surface = NativeMinimalRestoredPlate.Surface(width: image.width, height: image.height,
                safe: safe, rgba: rgba, frame: raster.frame, imageSize: raster.imageSize, origin: raster.origin, scale: raster.scale)
            var input = NativeMinimalRestoredPlate.Input(panel: panel.rect, ink: cardInkRect(card), font: Double(card.finalFontSize))
            input.clipped = panel.clipped; input.coverage = panel.coverage.isEmpty ? nil : panel.coverage
            input.sources = layout.items.filter { $0.id != item.id && !$0.keptLettering }.map { other in
                .init(frame: restoration.cleanupGeometry?.frame ?? layout.sourceRect, bounds: ([other.sourceBounds] + other.auxiliaryInkRects).map { $0.map(Double.init) },
                    vertical: other.sourceVertical, sourceFont: other.sourceFontSize.map(Double.init),
                    font: visible.first(where: { $0.item.id == other.id }).map { Double($0.finalFontSize) })
            }
            input.otherInk = inks.filter { $0.key != item.id }.map(\.value)
            guard let proposal = NativeMinimalRestoredPlate.shrink(surface, input: input) else { continue }
            cards[index].sourcePanels[0].rect = proposal.rect
            cards[index].sourcePanels[0].coverage = proposal.coverage
            cards[index].sourcePanels[0].clipped = proposal.clipped
            cards[index].sourcePanels[0].coverageClip = proposal.clipped ? NativeCSSCoveragePath.declaration(coverage: proposal.coverage, origin: proposal.rect.origin, commands: .absolute) : nil
        }
    }
}
