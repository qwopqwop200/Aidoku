import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    static func preserveLetteringPolarity(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
        layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result, settings: IPhoneOverlaySettings) {
        guard settings.renderedBackgroundOpacity == 1, settings.preserveSourceTextColor,
              settings.preserveSourceBackgroundColor, layout.items.count <= 256 else { return }
        let snapshot = cards
        var kept: [(Int, Int?, NativePolarityLegibility.Decision)] = []
        for index in snapshot.indices {
            let card = snapshot[index], item = card.item
            guard item.sourceColorEligible, !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !gloss.hiddenIDs.contains(item.id), !gloss.removedLayerIDs.contains(item.id) else { continue }
            let owner = card.sourcePanels.lastIndex(where: { !$0.sourceErasure })
            let rotated = card.rotatesSourcePanels || (item.rotation != 0 && card.drawsPanel && card.straightenedPanelRect == nil)
            guard owner != nil || rotated else { continue }
            let panel = owner.map { card.sourcePanels[$0] }
            guard panel?.sourceFrameImage == nil, card.foreignFills.isEmpty else { continue }
            let plate = panel?.background ?? rgb(card.background)
            let sourceSample = restoration.appearances[item.id]?.sourceSample ?? [:]
            let ring = card.outlinedRecord ?? [:]
            let actualOwner = panel ?? .init(rect: card.straightenedPanelRect ?? item.rect, background: plate ?? [],
                coverage: [card.straightenedPanelRect ?? item.rect])
            var ownerCard = card
            ownerCard.rotatesSourcePanels = rotated
            let others = snapshot.indices.filter { $0 != index &&
                !gloss.hiddenIDs.contains(snapshot[$0].item.id) && !gloss.removedLayerIDs.contains(snapshot[$0].item.id) &&
                !snapshot[$0].item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                panelMeetsInk(actualOwner, owner: ownerCard, ink: cardInkRect(snapshot[$0]))
            }
            let entry = NativePolarityLegibility.Entry(plate: plate, fill: rgb(card.style.foreground),
                source: NativeRestorationPixels.rgb(sourceSample["foreground"])?.channels,
                backing: NativeRestorationPixels.rgb(sourceSample["background"])?.channels,
                confidence: (sourceSample["confidence"] as? [String: Any])?["foreground"] as? Double ?? 0,
                font: Double(card.style.fontSize), strokeWidth: Double(card.style.outlineWidth), strokePreserved: card.strokePreserved,
                ringAction: ring["action"] as? String, ringKind: ring["kind"] as? String, ringCore: ring["core"] as? [Double],
                sharedOwner: panel?.hasForeignChildren == true,
                foreignOwner: snapshot.indices.contains { other in other != index &&
                    snapshot[other].foreignFills.contains { $0.color == plate }
                }, otherInks: others.map { rgb(snapshot[$0].style.foreground) })
            let decision = NativePolarityLegibility.resolve(entry)
            cards[index].polarityRejection = decision.rejection
            if decision.fill != nil { kept.append((index, owner, decision)) }
        }
        for (index, owner, decision) in kept {
            guard let fill = decision.fill, let plate = decision.plate else { continue }
            let originalFill = rgb(cards[index].style.foreground) ?? [], originalPlate = owner.map { cards[index].sourcePanels[$0].background } ?? rgb(cards[index].background) ?? []
            if plate != originalPlate {
                if let owner { cards[index].sourcePanels[owner].background = plate }
                else { cards[index].background = color(plate.map { CGFloat($0) }) }
                for backing in cards[index].backings.indices { cards[index].backings[backing].color = plate }
            }
            cards[index].style.foreground = color(fill.map { CGFloat($0) })
            if cards[index].style.outlineWidth > 0 {
                cards[index].style.outline = nil; cards[index].style.outlineWidth = 0; cards[index].strokePreserved = false
                cards[index].style.outlinePaintOrder = .fillThenStroke
            }
            cards[index].clusterRGB = nil
            cards[index].polarityRecord = ["fill": [originalFill, fill], "plate": [originalPlate, plate]]
            cards[index].typography = remeasureTypography(cards[index])
        }
    }
}
