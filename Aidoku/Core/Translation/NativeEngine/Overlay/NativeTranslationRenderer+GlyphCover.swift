import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Connected source readability owner, including GlyphCover's transparent
    /// retained plate. Presence does not imply an opaque backing or erasure.
    static func readabilityOwnerPanel(_ card: Card) -> NativeTranslationSourceStylePostPolish.Panel? {
        card.sourcePanels.last(where: { !$0.sourceErasure }) ?? card.glyphCoverOwnerPanel
    }
    /// Execute the anonymous source-aligned GlyphCover stage against the current
    /// cards. Its artwork diffusion does not certify source erasure or glyph fit.
    static func applyGlyphCover(cards: inout [Card], restoration: inout NativeTranslationRestoration.Result,
                               layout: NativeTranslationLayout, source: CGImage?, settings: IPhoneOverlaySettings,
                               gloss: NativeTranslationEffectGloss.Refinement) {
        guard let source, settings.renderedBackgroundOpacity == 1, settings.usesSourceInpainting,
              settings.preserveSourceTextColor, settings.preserveSourceBackgroundColor,
              layout.items.count <= 256 else { return }
        let reader = NativeSourcePixelReader(image: source)
        defer { reader.release() }
        let budget = NativeGlyphCover.Budget()
        func box(_ rect: CGRect) -> [Double] { [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }
        for index in cards.indices {
            let card = cards[index], item = card.item
            // The frozen source reader maps through cleanupImageGeometry.frame,
            // which can differ from the payload frame after object-fit layout.
            let frame = card.cleanupSourceFrame ?? layout.sourceRect
            let scene = NativeGlyphCover.Scene(opacity: settings.renderedBackgroundOpacity,
                inpaintingEnabled: settings.usesSourceInpainting, preserveSourceText: settings.preserveSourceTextColor,
                preserveSourceBackground: settings.preserveSourceBackgroundColor,
                imageSize: CGSize(width: source.width, height: source.height), itemCount: layout.items.count,
                cleanupFrame: box(frame))
            guard !gloss.hiddenIDs.contains(item.id), !gloss.removedLayerIDs.contains(item.id) else { continue }
            let rotated = card.rotatesSourcePanels || (item.rotation != 0 && card.drawsPanel && card.straightenedPanelRect == nil)
            let ownPanels = card.sourcePanels.indices.filter { !card.sourcePanels[$0].sourceErasure }
            // Frozen selection prefers the connected parent; detached plates
            // own this caption only when exactly one plate carries its region.
            // Initial source plates do not establish a caption parent.
            let ownerIndex: Int?
            if rotated { ownerIndex = ownPanels.first }
            else if card.captionParentPlate { ownerIndex = ownPanels.last }
            else { ownerIndex = ownPanels.count == 1 ? ownPanels.first:nil }
            let panel = ownerIndex.map { card.sourcePanels[$0] }
            guard panel != nil || rotated else {
                if !ownPanels.isEmpty { cards[index].glyphCoverReject = "owner" }
                continue
            }
            let nodeIsChild = !rotated && card.captionParentPlate
            let rect = panel?.rect ?? card.straightenedPanelRect ?? item.rect
            guard let background = panel?.background ?? rgb(card.background) else { continue }
            // The source panel follows the same item-centred rotation as draw().
            let theta = rotated ? Double(item.rotation):0, cosine = cos(theta), sine = sin(theta)
            let centre = CGPoint(x: item.rect.midX, y: item.rect.midY)
            var plate = NativeGlyphCover.Plate(
                rect: rotated ? rotatedBounds(rect, about: item.rect, angle: item.rotation):rect,
                size: rect.size, origin: rect.origin,
                transformOrigin: rotated ? CGPoint(x: centre.x-rect.minX, y: centre.y-rect.minY):.zero,
                transform: .init(a: cosine, b: sine, c: -sine, d: cosine), backgroundRGBA: background,
                hasBackgroundImage: panel?.sourceFrameImage != nil || !card.foreignFills.isEmpty,
                frameLines: (panel?.sourceFrameLineCount ?? 0) > 0,
                foreignFills: !card.foreignFills.isEmpty,
                nodeIsChild: nodeIsChild,
                ownedNodeCount: (nodeIsChild ? 1:0) + (panel?.hasForeignChildren == true ? 1:0),
                hasOwnBacking: !card.backings.isEmpty,
                backgroundSharedWithAnotherPlate: cards.indices.contains { other in
                    other != index && cards[other].foreignFills.contains { $0.color == background }
                }, clipped: panel?.clipped == true || panel?.captionUnionClipped == true,
                coverage: panel.map { $0.coverage.map(box) })
            // Rotated panels' clip only limits the source page, not their local coverage.
            if rotated { plate.clipped = false; plate.coverage = nil }
            let others = cards.indices.filter { $0 != index && !gloss.hiddenIDs.contains(cards[$0].item.id) && !gloss.removedLayerIDs.contains(cards[$0].item.id) }
            let sample = restoration.appearances[item.id]?.sourceSample ?? [:]
            let entry = NativeGlyphCover.Entry(id: item.id, text: item.typesettingText ?? item.text,
                mode: rotated ? "rotated-panel":"readability-panel",
                record: card.outlinedRecord, sampledInk: NativeSourceColorSampler.rgb(sample["foreground"] ?? sample["displayForeground"]),
                displayGroup: card.displayGroup != nil,
                sourceBounds: item.sourceBounds.map(Double.init), sourceFrame: item.sourceFrame.map(Double.init),
                sourceFontSize: item.sourceFontSize.map(Double.init), fontSize: Double(card.style.fontSize), plate: plate,
                otherCaptionInks: others.map { cardInkRect(cards[$0]) },
                otherSourceRects: layout.items.filter { $0.id != item.id }.compactMap {
                    pageRect($0.sourceBounds, frame: frame)?.insetBy(dx: -2, dy: -2)
                })
            let attempt: NativeGlyphCover.Attempt
            do {
                attempt = try NativeGlyphCover.attempt(entry: entry, scene: scene, budget: budget) { crop, width, height in
                    try reader.read(x: Double(crop.minX), y: Double(crop.minY), sourceWidth: Double(crop.width),
                        sourceHeight: Double(crop.height), width: width, height: height)
                }
            } catch {
                cards[index].glyphCoverReject = "source"
                restoration.limitations.append("glyph-cover-source-unavailable")
                continue
            }
            cards[index].glyphCoverReject = attempt.rejection
            guard let result = attempt.result, let image = result.image else { continue }
            restoration.patches.append(.init(image: image, rect: result.viewportRect, itemID: item.id,
                cleanupClip: restoration.cleanupGeometry?.clip, independentArtworkCover: true))
            // Frozen canvas assigns each CSS box metric as an independent LayoutUnit.
            // Keep raw source crop geometry as raster evidence and authored clip metadata;
            // the exported repair mask uses the DOM-used rectangle.
            cards[index].glyphCoverPatch = SourcePatch(image: image, rect: usedRect(result.viewportRect),
                cleanupClip: restoration.cleanupGeometry?.clip, authoredCanvasRect: result.viewportRect)
            // Frozen owner stays connected with transparent background. Retain
            // its actual identity/geometry for later source forcing and parent
            // policies while removing it from the opaque source-panel paint list.
            var retainedOwner = panel ?? NativeTranslationSourceStylePostPolish.Panel(
                rect: rect, background: background, coverage: [rect])
            retainedOwner.rotated = rotated
            retainedOwner.sourceFrameImage = nil
            cards[index].glyphCoverOwnerPanel = retainedOwner
            // The artwork patch carries no fabricated layoutSafe mask.
            if let ownerIndex {
                retainCaptionParentOwner(cards: &cards, ownerIndex: index, panelIndex: ownerIndex)
                cards[index].sourcePanels.remove(at: ownerIndex)
            }
            if rotated { cards[index].drawsPanel = false }
            cards[index].style.foreground = color(result.foreground.map { CGFloat($0) })
            cards[index].style.outline = color(result.outline.map { CGFloat($0) })
            cards[index].style.outlineWidth = CGFloat(result.outlineWidth)
            cards[index].style.outlinePaintOrder = .strokeThenFill
            cards[index].strokePreserved = true
            cards[index].sourceStrokeKind = "preserved"
            cards[index].clusterRGB = nil
            cards[index].glyphCoverRecord = result.metadata
            cards[index].typography = remeasureTypography(cards[index])
        }
    }
}
