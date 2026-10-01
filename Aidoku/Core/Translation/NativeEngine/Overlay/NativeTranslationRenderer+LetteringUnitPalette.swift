import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Frozen lettering-unit policy14104–14223, after display cohorts and before
    /// display-column grouping. All entries observe one pre-stage snapshot.
    @discardableResult
    static func applyLetteringUnitPalette(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
        layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
        settings: IPhoneOverlaySettings) -> NativeLetteringUnitPalette.Result {
        struct Owner { let index: Int; let panel: Int?; let box: CGRect; let background: [Double] }
        let visible = cards.indices.filter { !gloss.hiddenIDs.contains(cards[$0].item.id) && !gloss.removedLayerIDs.contains(cards[$0].item.id) }
        var owners: [String: Owner] = [:]
        var members: [NativeLetteringUnitPalette.Member] = []
        func valid(_ rgb: [Double]?) -> [Double]? {
            guard let rgb, rgb.count == 3, rgb.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }) else { return nil }
            return rgb
        }
        for index in visible {
            let card = cards[index], item = card.item
            guard !(item.typesettingText ?? item.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  card.glyphCoverRecord == nil else { continue }
            let rotated = card.rotatesSourcePanels || (item.rotation != 0 && card.drawsPanel && card.straightenedPanelRect == nil)
            let ownerIndex = rotated ? card.sourcePanels.firstIndex(where: { !$0.sourceErasure })
                : card.sourcePanels.lastIndex(where: { !$0.sourceErasure })
            let panel = ownerIndex.map { card.sourcePanels[$0] }
            guard panel != nil || rotated, panel?.hasForeignChildren != true,
                  let plate = valid(panel?.background ?? rgb(card.background)),
                  let fill = valid(rgb(card.style.foreground)), let glyph = item.sourceFontSize, glyph >= 18 else { continue }
            let sample = restoration.appearances[item.id]?.sourceSample ?? [:]
            let ring = card.outlinedRecord ?? card.outlineEvidence?.ringData ?? sample["outlinedLettering"] as? [String: Any]
            let sampled = valid(NativeSourceColorSampler.rgb(sample["foreground"] ?? sample["displayForeground"]))
            let core = ["outline", "paper"].contains(ring?["kind"] as? String ?? "") ? valid(NativeSourceColorSampler.rgb(ring?["core"])) : nil
            guard let source = sampled ?? core else { continue }
            let surface = (ring?["surface"] as? [NSNumber]).flatMap { $0.count >= 3 ? valid($0.prefix(3).map(\.doubleValue)) : nil }
            let frame = panel?.rect ?? card.straightenedPanelRect ?? item.rect
            let box = rotated ? rotatedBounds(frame, about: item.rect, angle: item.rotation) : frame
            owners[item.id] = Owner(index: index, panel: ownerIndex, box: box, background: plate)
            members.append(.init(id: item.id, box: box, plate: plate, fill: fill, source: source, surface: surface,
                glyph: Double(glyph), font: Double(card.style.fontSize),
                stroke: card.style.outlineWidth > 0 ? valid(rgb(card.style.outline)) : nil,
                strokeWidth: Double(card.style.outlineWidth), vertical: item.vertical))
        }
        // Foreign fills belong to readability panels even when that panel is
        // not admitted as a member, and may need the newly selected colour.
        var panelOwners: [(card: Int, panel: Int)] = []
        var panels: [NativeLetteringUnitPalette.Panel] = []
        for index in cards.indices {
            let card = cards[index]
            for pi in card.sourcePanels.indices {
                let panel = card.sourcePanels[pi]
                panelOwners.append((index,pi))
                var entry = NativeLetteringUnitPalette.Panel(id: card.item.id,color: panel.background,
                    fills: panel.sourceErasure ? [] : card.foreignFills.map { .init(rect: $0.rect,color: $0.color,
                        backgroundPosition: $0.backgroundPosition,backgroundSize: $0.backgroundSize) })
                entry.owner = owners[card.item.id]?.panel == pi
                panels.append(entry)
            }
        }
        let result = NativeLetteringUnitPalette.resolve(members: members,
            neighbors: visible.map { .init(id: cards[$0].item.id, ink: cardInkRect(cards[$0]), fill: rgb(cards[$0].style.foreground)) },
            panels: panels, itemCount: layout.items.count, opacity: settings.renderedBackgroundOpacity,
            preserveText: settings.preserveSourceTextColor, preserveBackground: settings.preserveSourceBackgroundColor)
        for update in result.updates {
            guard let owner = owners[update.id] else { continue }
            let index = owner.index
            if let panel = owner.panel { cards[index].sourcePanels[panel].background = update.plate }
            else { cards[index].background = color(update.plate.map { CGFloat($0) }) }
            for backing in cards[index].backings.indices { cards[index].backings[backing].color = update.plate }
            let removedStroke = update.stroke == nil && cards[index].style.outlineWidth > 0
            cards[index].style.foreground = color(update.fill.map { CGFloat($0) })
            cards[index].style.outline = update.stroke.map { color($0.map { CGFloat($0) }) }
            cards[index].style.outlineWidth = CGFloat(update.strokeWidth)
            if update.stroke != nil { cards[index].style.outlinePaintOrder = .strokeThenFill }
            else if removedStroke { cards[index].style.outlinePaintOrder = .fillThenStroke }
            cards[index].strokePreserved = update.stroke != nil
            if removedStroke { cards[index].sourceStrokeKind = "none" }
            cards[index].clusterRGB = nil
            var record: [String: Any] = ["plate": [update.oldPlate, update.plate]]
            if update.oldFill != update.fill { record["fill"] = [update.oldFill, update.fill] }
            cards[index].letteringUnitRecord = record
            cards[index].typography = remeasureTypography(cards[index])
        }
        for (offset,panel) in result.panels.enumerated() {
            let owner = panelOwners[offset]
            // The card's foreign pieces are owned by its readability panel;
            // source-erasure layers retain their own background untouched.
            if !cards[owner.card].sourcePanels[owner.panel].sourceErasure {
                let frame = cards[owner.card].sourcePanels[owner.panel].rect
                cards[owner.card].foreignFills = panel.fills.map { fill in
                    .init(rect: fill.rect,color: fill.color,
                        backgroundPosition: panel.backgroundRewritten
                            ? CGPoint(x:fill.rect.minX-frame.minX,y:fill.rect.minY-frame.minY) : fill.backgroundPosition,
                        backgroundSize: panel.backgroundRewritten ? fill.rect.size : fill.backgroundSize)
                }
            }
        }
        return result
    }
}
