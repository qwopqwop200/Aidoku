import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    static func holdLateReadableFloor(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
        layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result, settings: IPhoneOverlaySettings) {
        guard settings.renderedBackgroundOpacity == 1, layout.items.count <= 256 else { return }
        for i in cards.indices {
            let card = cards[i], item = card.item
            // Before this phase, zero-rotation condensation uses independent
            // CSS scale. The original excludes transforms, not that scale.
            guard item.rotation == 0, !item.vertical, card.effectiveTextRotation == 0,
                  !gloss.hiddenIDs.contains(item.id), !gloss.removedLayerIDs.contains(item.id),
                  !card.captionParentPlate, card.sourceBackgroundKind == "inpainted" else { continue }
            var candidate: Card?
            let result = NativeLateBalloonStages.readableFloor(font: Double(card.style.fontSize), pitch: Double(card.style.lineHeight),
                before: cardInkRect(card), frame: restoration.cleanupGeometry?.frame ?? layout.sourceRect,
                neighbors: cards.indices.filter { $0 != i && !gloss.hiddenIDs.contains(cards[$0].item.id) && !gloss.removedLayerIDs.contains(cards[$0].item.id) }.map { cardInkRect(cards[$0]) }) { font, pitch in
                var shaped = card
                shaped.style.fontSize = CGFloat(font); shaped.style.lineHeight = CGFloat(pitch); shaped.style.tracking = -CGFloat(font)*0.012
                shaped.finalFontSize = CGFloat(font)
                shaped.typography = remeasureTypography(shaped)
                candidate = shaped
                return .init(ink: cardInkRect(shaped), scrollWidth: Double(max(shaped.typography.size.width, shaped.textLayoutSize.width)),
                    clientWidth: Double(shaped.textLayoutSize.width), scrollHeight: Double(max(shaped.typography.size.height, shaped.textLayoutSize.height)),
                    clientHeight: Double(shaped.textLayoutSize.height))
            }
            if result != nil, var candidate {
                candidate.readableFloorHeld = [Double(card.style.fontSize), Double(candidate.style.fontSize)]
                cards[i] = candidate
            }
        }
    }

    static func clipLateBalloonPanels(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
        layout: NativeTranslationLayout, settings: IPhoneOverlaySettings, balloons: BalloonRelayoutContext) {
        guard settings.renderedBackgroundOpacity == 1, layout.items.count <= 256, balloons.source != nil else { return }
        let visible = cards.filter { !gloss.hiddenIDs.contains($0.item.id) && !gloss.removedLayerIDs.contains($0.item.id) }
        let ink = visible.flatMap { card -> [(bare: CGRect, padded: CGRect)] in
            let pad = max(3, min(6, card.style.fontSize * 0.3))
            return cardPageLineRects(card).map { ($0, $0.insetBy(dx: -pad, dy: -pad)) }
        }
        func sources(_ item: NativeTranslationLayoutItem) -> [CGRect] {
            ((joinedUnitMembers(item) ?? [item.sourceBounds]) + item.auxiliaryInkRects).compactMap { pageRect($0, frame: balloons.cleanupFrame) }
        }
        for i in cards.indices {
            let card = cards[i], item = card.item
            guard item.rotation == 0, !item.balancedColumn, !card.rotatesSourcePanels,
                  !gloss.removedLayerIDs.contains(item.id), card.sourcePanels.contains(where: {
                      !$0.sourceErasure && !$0.rotated && $0.rect.width >= 4 && $0.rect.height >= 4
                  }) else { continue }
            let members = joinedUnitMembers(item), own = sources(item)
            guard !own.isEmpty, let interior = balloons.interior(card, sources: own, unitCount: members?.count ?? 0) else { continue }
            let verified = interior.native && item.balloonInterior?.contourVerified == true
            let unit = (members != nil && interior.native) || verified
            let requiredSources = verified ? [] : own + layout.items.filter { $0.id != item.id }.flatMap(sources).map { $0.insetBy(dx: -3, dy: -3) }
            let required = requiredSources + ink.map { unit ? $0.bare:$0.padded }
            for p in cards[i].sourcePanels.indices {
                let panel = cards[i].sourcePanels[p]
                guard !panel.sourceErasure, !panel.rotated, panel.rect.width >= 4, panel.rect.height >= 4, panel.background.count == 3,
                      zip(panel.background, interior.surfaceRGB).allSatisfy({ abs($0 - $1) <= 40 }) else { continue }
                guard let result = NativeLateBalloonStages.clip(panel: panel.rect, coverage: panel.coverage.isEmpty ? [panel.rect]:panel.coverage,
                    required: required, interior: interior.rect, scale: interior.scale, width: interior.width, height: interior.height, fill: interior.fill) else { continue }
                cards[i].sourcePanels[p].coverage = result.coverage
                cards[i].sourcePanels[p].clipped = true
                cards[i].sourcePanels[p].coverageClip = NativeCSSCoveragePath.declaration(coverage: result.coverage, origin: panel.rect.origin, commands: .relative)
                cards[i].sourcePanels[p].captionUnionClipped = true
                cards[i].sourcePanels[p].balloonInteriorClipped = result.removedPixels
            }
        }
    }

    static func centerLateBalloonBodies(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
        layout: NativeTranslationLayout, settings: IPhoneOverlaySettings) {
        guard settings.renderedBackgroundOpacity == 1 else { return }
        for i in cards.indices {
            let card = cards[i], item = card.item
            guard item.rotation == 0, !item.vertical, !gloss.hiddenIDs.contains(item.id), !gloss.removedLayerIDs.contains(item.id),
                  let contour = item.balloonInterior, contour.contourVerified,
                  let shape = NativeTypographyPostPolish.balloonShape(rect: contour.rect, center: contour.center, spans: contour.spans, frame: card.cleanupSourceFrame ?? layout.sourceRect)
            else { continue }
            var accepted: Card?
            let parent = card.captionParentPlate ? readabilityOwnerPanel(card)?.rect : nil
            let result = NativeLateBalloonStages.centeredShift(ink: cardInkRect(card), center: shape.center, font: Double(card.style.fontSize),
                parent: parent, neighbors: cards.indices.filter { $0 != i && !gloss.hiddenIDs.contains(cards[$0].item.id) && !gloss.removedLayerIDs.contains(cards[$0].item.id) }.map { cardInkRect(cards[$0]) },
                outside: shape.outside) { shift in
                var next = card
                // CSS left/top belong to the containing block, not the page.
                // Quantize the relative lengths before adding its physical origin.
                let origin = parent?.origin ?? .zero
                next.textShift.x = CGFloat((Float(item.x + card.textShift.x - origin.x + shift.x) * 64).rounded(.towardZero)) / 64 + origin.x - item.x
                next.textShift.y = CGFloat((Float(item.y + card.textShift.y - origin.y + shift.y) * 64).rounded(.towardZero)) / 64 + origin.y - item.y
                accepted = next
                return cardInkRect(next)
            }
            if let result, var accepted {
                accepted.balloonCenterShift = result
                cards[i] = accepted
            }
        }
    }
}
