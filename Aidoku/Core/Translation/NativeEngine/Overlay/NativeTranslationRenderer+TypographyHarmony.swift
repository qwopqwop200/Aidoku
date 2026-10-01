import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    struct TypographyHarmonyOwner {
        let panel: NativeTranslationSourceStylePostPolish.Panel
        let cardID: String
        let panelIndex: Int
    }

    /// Frozen scaleTo/safeAt: a transparent text node may grow inside its
    /// separate owner plate. Restoration alone does not describe CSS background.
    static func scaleTypographyHarmony(_ original: Card, size: CGFloat, peers: [Card],
        frame: CGRect?, owner suppliedOwner: TypographyHarmonyOwner? = nil,
        hiddenIDs: Set<String> = [], removedIDs: Set<String> = [], surfaceFits: ((Card) -> Bool)? = nil) -> Card? {
        guard let before = cardWholeRangeRect(original), before.width > 0,
              original.finalFontSize > 0, size > 0 else { return nil }
        let scale = size / original.finalFontSize
        let ownBackground = original.drawsPanel && original.background.alpha > 0.01
        let owner = suppliedOwner ?? original.sourcePanels.indices.last(where: { !original.sourcePanels[$0].sourceErasure })
            .map { TypographyHarmonyOwner(panel: original.sourcePanels[$0], cardID: original.item.id, panelIndex: $0) } ??
            original.glyphCoverOwnerPanel.map { .init(panel:$0,cardID:original.item.id,panelIndex:-1) }
        if ownBackground && scale > 1 { return nil }
        var proposed = original
        if !ownBackground {
            proposed.item.width *= scale; proposed.item.height *= scale
            proposed.item.paddingLeft *= scale; proposed.item.paddingRight *= scale
            proposed.item.paddingTop *= scale; proposed.item.paddingBottom *= scale
        }
        proposed.style.tracking *= scale
        proposed.style.trackingScalesWithFont = false
        proposed.style.fontSize = size
        proposed.style.lineHeight *= scale
        proposed.item.fontSize = size; proposed.item.lineHeight = proposed.style.lineHeight
        proposed.finalFontSize = size
        proposed.item = usedLayoutItem(proposed.item)
        proposed.typography = remeasureTypography(proposed)
        guard let moved = cardWholeRangeRect(proposed) else { return nil }
        // CSS left/top are assigned in the containing parent's coordinates.
        // LayoutUnit truncates negative fractions toward zero independently of
        // the parent origin; retaining an unquantized shift moves final glyphs.
        let parent = original.captionParentPlate ? owner?.panel.rect.origin ?? .zero : .zero
        func cssUnit(_ value: CGFloat) -> CGFloat { CGFloat((Float(value) * 64).rounded(.towardZero)) / 64 }
        let authored = original.authoredTextOrigin ?? CGPoint(x:original.item.x+original.textShift.x,y:original.item.y+original.textShift.y)
        let rawX = authored.x-parent.x+before.midX-moved.midX
        let rawY = (original.sourceColumnAuthoredTop ?? authored.y)-parent.y+before.midY-moved.midY
        proposed.authoredTextOrigin = CGPoint(x:parent.x+rawX,y:parent.y+rawY)
        proposed.item.x = parent.x + cssUnit(rawX)
        proposed.item.y = parent.y + cssUnit(rawY)
        if original.sourceColumnAuthoredTop != nil { proposed.sourceColumnAuthoredTop = parent.y+rawY }
        proposed.textShift = .zero
        guard let after = cardWholeRangeRect(proposed), after.width > 0,
              floor(after.height / proposed.style.lineHeight + 0.5) ==
                floor(before.height / original.style.lineHeight + 0.5),
              cardScrollFits(proposed, allowance: 1) else { return nil }
        if scale <= 1 {
            return before.insetBy(dx: -1, dy: -1).contains(after) ? proposed : nil
        }
        return safeTypographyHarmony(original, proposed: proposed, peers: peers, frame: frame,
            owner: owner, hiddenIDs:hiddenIDs,removedIDs:removedIDs,surfaceFits: surfaceFits) ? proposed : nil
    }

    static func safeTypographyHarmony(_ original: Card, proposed: Card, peers: [Card], frame: CGRect?,
        owner: TypographyHarmonyOwner?, hiddenIDs:Set<String> = [],removedIDs:Set<String> = [],
        surfaceFits: ((Card) -> Bool)? = nil) -> Bool {
        guard let before = cardWholeRangeRect(original), let after = cardWholeRangeRect(proposed),
              after.width > 0, cardScrollFits(proposed, allowance: 1) else { return false }
        if let frame, !frame.contains(after) { return false }
        let others = peers.filter { $0.item.id != original.item.id && !$0.item.keptLettering }
        let otherInk = others.filter { !hiddenIDs.contains($0.item.id) }.compactMap {cardWholeRangeRect($0)}.filter { $0.width > 0 }
        func inkHits(_ rect: CGRect) -> Int {
            otherInk.filter { rect.minX - 1 < $0.maxX && rect.maxX + 1 > $0.minX &&
                rect.minY - 1 < $0.maxY && rect.maxY + 1 > $0.minY }.count
        }
        guard inkHits(after) <= inkHits(before) else { return false }
        let layers = others.filter { !removedIDs.contains($0.item.id) }.flatMap { other in
            other.sourcePanels.enumerated().compactMap { index, panel -> CGRect? in
                if other.item.id == owner?.cardID && index == owner?.panelIndex { return nil }
                return other.rotatesSourcePanels ? rotatedBounds(panel.rect,
                    about: other.sourcePlateRect, angle: other.item.rotation) : panel.rect
            } + other.backings.map(\.frame) + (other.glyphCoverOwnerPanel.flatMap { panel -> CGRect? in
                guard !(other.item.id == owner?.cardID && owner?.panelIndex == -1) else { return nil }
                return other.rotatesSourcePanels ? rotatedBounds(panel.rect,about:other.sourcePlateRect,angle:other.item.rotation) : panel.rect
            }.map { [$0] } ?? [])
        }
        func layerHits(_ rect: CGRect) -> Int {
            layers.filter { rect.minX - 1 < $0.maxX && rect.maxX + 1 > $0.minX &&
                rect.minY - 0.75 < $0.maxY && rect.maxY + 0.75 > $0.minY }.count
        }
        guard layerHits(after) <= layerHits(before) else { return false }
        if let plate = owner?.panel {
            let coverage = plate.coverage.isEmpty ? [plate.rect] : plate.coverage
            guard let owner = coverage.filter({ $0.minX <= before.midX && before.midX <= $0.maxX && $0.minY <= before.midY && before.midY <= $0.maxY })
                .sorted(by: { $0.width * $0.height > $1.width * $1.height }).first else { return false }
            let padding = max(0, min(3, before.minX - owner.minX, before.minY - owner.minY,
                owner.maxX - before.maxX, owner.maxY - before.maxY))
            return owner.insetBy(dx: padding - 0.5, dy: padding - 0.5).contains(after)
        }
        guard original.sourceBackgroundKind == "inpainted", !original.captionParentPlate,
              layerHits(after) == 0, surfaceFits?(proposed) == true else { return false }
        return true
    }

    static func moveTypographyHarmony(_ original: Card, dx: CGFloat, dy: CGFloat, peers: [Card],
        frame: CGRect?, owner: TypographyHarmonyOwner?, hiddenIDs:Set<String> = [],removedIDs:Set<String> = [],
        surfaceFits:((Card)->Bool)? = nil) -> Card? {
        var proposed = original
        let parent = original.captionParentPlate ? owner?.panel.rect.origin ?? .zero : .zero
        func unit(_ value:CGFloat)->CGFloat { CGFloat((Float(value)*64).rounded(.towardZero))/64 }
        let authored = original.authoredTextOrigin ?? CGPoint(x:original.item.x+original.textShift.x,y:original.item.y+original.textShift.y)
        let oldX=authored.x-parent.x,oldY=(original.sourceColumnAuthoredTop ?? authored.y)-parent.y
        let rawX=oldX+dx,rawY=oldY+dy
        proposed.authoredTextOrigin=CGPoint(x:parent.x+rawX,y:parent.y+rawY)
        // The centred CSS scale transform is unchanged by a left/top shift.
        // Translate the physical box by the used CSS delta; retain its offset
        // from the unscaled authored box instead of replacing it with CSS left.
        proposed.item.x=original.item.x+original.textShift.x+unit(rawX)-unit(oldX)
        proposed.item.y=original.item.y+original.textShift.y+unit(rawY)-unit(oldY)
        proposed.textShift = .zero
        if original.sourceColumnAuthoredTop != nil { proposed.sourceColumnAuthoredTop=parent.y+rawY }
        return safeTypographyHarmony(original,proposed:proposed,peers:peers,frame:frame,owner:owner,
            hiddenIDs:hiddenIDs,removedIDs:removedIDs,surfaceFits:surfaceFits) ? proposed:nil
    }

    static func projectTypographyHarmonyCard(_ item:NativeTranslationLayoutItem, from original:Card) -> Card {
        var card=original
        let retainsChildren=item.typesettingText == original.item.typesettingText && item.typesettingQuoteMode == original.item.typesettingQuoteMode &&
            item.typesettingPreformattedRows == original.item.typesettingPreformattedRows
        let oldX=original.item.x+original.textShift.x,oldY=original.item.y+original.textShift.y
        if item.x != oldX || item.y != oldY { card.authoredTextOrigin=CGPoint(x:item.x,y:item.y) }
        if !retainsChildren { card.style.blockRowHorizontalAlignment=nil }
        card.item=item;card.textShift = .zero
        card.typographyDisplayGrowth=item.typesettingDisplayGrowth
        card.style.fontSize=item.fontSize;card.style.lineHeight=item.lineHeight
        if card.style.trackingScalesWithFont {
            card.style.tracking = original.style.tracking*item.fontSize/original.finalFontSize
        }
        card.style.horizontalScale=item.typesettingWidthScale ?? original.style.horizontalScale
        card.style.koreanQuoteMode=item.typesettingQuoteMode ?? 0
        if let foreground=item.typesettingForeground { card.style.foreground=color(foreground.map { CGFloat($0) }) }
        if let outline=item.typesettingOutlineRGB {
            card.style.outline=color(outline.map { CGFloat($0) });card.style.outlineWidth=item.typesettingOutlineWidth ?? 0
        }
        card.finalFontSize=item.fontSize;card.typography=remeasureTypography(card)
        return card
    }

    /// Harmony observes the cards after plate/restored growth and packing,
    /// including an accepted source-anchor shift. Failed scale trials reuse the
    /// original retained plate search before the restored-surface fallback.
    static func reconcileTypographyHarmony(cards: inout [Card], layout: NativeTranslationLayout,
        restoration: NativeTranslationRestoration.Result, settings: IPhoneOverlaySettings, source: CGImage?,
        growthSession: NativeTypographyPostPolish.RendererGrowthSession, lockedIDs: Set<String>,
        plateSession: PlateGrowthSession? = nil, hiddenIDs: Set<String> = [],removedIDs:Set<String> = []) throws {
        let snapshotOrder = cards
        let snapshot = Dictionary(cards.map { ($0.item.id, $0) }, uniquingKeysWith: { first,_ in first })
        let live = NativeTranslationLayout(imageSize: layout.imageSize, sourceRect: layout.sourceRect, viewport: layout.viewport,
            items: layout.items.map { item in
                guard let card = snapshot[item.id] else { return item }
                var current = card.item
                current.fontSize = card.finalFontSize; current.lineHeight = card.style.lineHeight
                current.x += card.textShift.x; current.y += card.textShift.y
                return current
            }, readableRecoveryRemaining: layout.readableRecoveryRemaining, sourceObjectFit: layout.sourceObjectFit)
        var proposals: [String: [(NativeTranslationLayoutItem, Card)]] = [:]
        var axisCards: [String: Card] = [:]
        var harmonyRows: [[String]] = []
        func pageItem(_ card: Card) -> NativeTranslationLayoutItem {
            var item = card.item
            item.fontSize = card.finalFontSize; item.lineHeight = card.style.lineHeight
            item.x += card.textShift.x; item.y += card.textShift.y
            return item
        }
        func currentCard(_ item: NativeTranslationLayoutItem) -> Card? {
            if let accepted = proposals[item.id]?.last(where: { $0.0 == item }) { return accepted.1 }
            guard var card = axisCards[item.id] ?? snapshot[item.id] else { return nil }
            if item == pageItem(card) { return card }
            card=projectTypographyHarmonyCard(item,from:card)
            return card
        }
        func remember(_ card: Card) -> NativeTranslationLayoutItem {
            let item = pageItem(card)
            proposals[item.id, default: []].append((item, card))
            return item
        }
        func ownerOf(_ original: Card, state: [NativeTranslationLayoutItem]) -> TypographyHarmonyOwner? {
            if original.captionParentPlate, let identity = original.captionParentOwner,
               snapshotOrder.indices.contains(identity.cardIndex) {
                let ownerID = snapshotOrder[identity.cardIndex].item.id
                let liveOwner = state.first(where: { $0.id == ownerID }).flatMap(currentCard) ?? snapshotOrder[identity.cardIndex]
                let panel = identity.panelIndex == -1 ? liveOwner.glyphCoverOwnerPanel :
                    (liveOwner.sourcePanels.indices.contains(identity.panelIndex) ? liveOwner.sourcePanels[identity.panelIndex] : nil)
                if let panel { return .init(panel: panel, cardID: ownerID, panelIndex: identity.panelIndex) }
            }
            return original.sourcePanels.indices.last(where: { !original.sourcePanels[$0].sourceErasure })
                .map { .init(panel: original.sourcePanels[$0],cardID:original.item.id,panelIndex:$0) } ??
                original.glyphCoverOwnerPanel.map { .init(panel:$0,cardID:original.item.id,panelIndex:-1) }
        }
        let result = try NativeTypographyPostPolish.refining(layout: live, restoration: restoration, settings: settings,
            sourceImage: source, growthSession: growthSession, lockedIDs: lockedIDs, phase: .harmony,
            harmonyScale: { item, size, others in
                guard let original = currentCard(item) else { return nil }
                let peers = others.compactMap(currentCard)
                let owner = ownerOf(original, state: others)
                guard let accepted = scaleTypographyHarmony(original, size: size, peers: peers,
                    frame: restoration.cleanupGeometry?.frame, owner: owner,hiddenIDs:hiddenIDs,removedIDs:removedIDs,surfaceFits: { candidate in
                        growthSession.holdsSurface(item: pageItem(candidate), typography: candidate.typography,
                            foreground: candidate.style.foreground)
                    }) else { return nil }
                return remember(accepted)
            }, harmonyPlateGrowth: { item, cap, strict, glyph, others in
                guard let plateSession else { return nil }
                var trialCards = others.compactMap(currentCard)
                guard plateSession.refit(id: item.id, cap: Double(cap), strict: strict,
                    styleGlyph: glyph.map(Double.init) ?? 0, cards: &trialCards) != nil,
                    let accepted = trialCards.first(where: { $0.item.id == item.id }) else { return nil }
                return remember(accepted)
            }, harmonyAxis: { state, boxes, groups in
                harmonyRows=groups.map {$0.members.map {state[$0].id}}
                // Kept lettering remains in the layout as a source obstacle,
                // but has no translated text node/Card. Preserve page indices
                // for Post state while the axis policy observes actual nodes.
                let cardIndices = state.indices.filter { currentCard(state[$0]) != nil }
                var liveCards = cardIndices.compactMap { currentCard(state[$0]) }
                let localIndex = Dictionary(uniqueKeysWithValues: cardIndices.enumerated().map { ($0.element,$0.offset) })
                func mappedLink(_ link: NativeTypographyPostPolish.Link) -> NativeTypographyPostPolish.Link? {
                    guard let a=localIndex[link.a],let b=localIndex[link.b] else { return nil }
                    return .init(a:a,b:b,axis:link.axis,edge:link.edge,gap:link.gap)
                }
                let liveGroups = groups.compactMap { group -> NativeTypographyPostPolish.AlignedGroup? in
                    let indices=group.members.compactMap { localIndex[$0] }
                    guard indices.count>=2 else { return nil }
                    return .init(members:indices,links:group.links.compactMap(mappedLink))
                }
                let liveBoxes = cardIndices.map { boxes[$0] }
                let members = liveCards.indices.map { i -> NativeTypographyHarmonyAxis.Member? in
                    guard let box = liveBoxes[i], !hiddenIDs.contains(liveCards[i].item.id),
                          !lockedIDs.contains(liveCards[i].item.id) else { return nil }
                    return .init(source: box,font:liveCards[i].finalFontSize,pitch:liveCards[i].style.lineHeight)
                }
                let columnLinks = NativeTypographyPostPolish.columnRowLinks(liveBoxes).filter { link in
                    guard let a = members[link.a], let b = members[link.b],
                          !liveCards[link.a].style.vertical, !liveCards[link.b].style.vertical else { return false }
                    func classes(_ i: Int) -> [String] {
                        let sample = restoration.appearances[liveCards[i].item.id]?.sourceSample ?? [:]
                        let ink = NativeSourceColorSampler.rgb(sample["foreground"])
                        let paper = NativeSourceColorSampler.rgb(sample["background"]) ??
                            NativeSourceColorSampler.rgb(liveCards[i].sourcePanels.first?.background)
                        let inkColor: CGColor? = ink.map { values in NativeTranslationRenderer.color(values.map { CGFloat($0) }) }
                        let paperColor: CGColor? = paper.map { values in NativeTranslationRenderer.color(values.map { CGFloat($0) }) }
                        return [NativeTypographyPostPolish.styleColorClass(inkColor),
                            NativeTypographyPostPolish.styleColorClass(paperColor)]
                    }
                    let u=classes(link.a),v=classes(link.b)
                    let same=u.indices.allSatisfy { u[$0] == v[$0] || u[$0] == "?" || v[$0] == "?" }
                    return same && (liveCards[link.a].style.outline != nil) == (liveCards[link.b].style.outline != nil) &&
                        (link.edge != 1 || link.gap <= 1.2 * max(a.source.glyph,b.source.glyph))
                }
                func safelyCommit(_ proposed: Card, at i: Int) -> Bool {
                    let old=liveCards[i], owner=ownerOf(old,state:liveCards.map(pageItem))
                    guard safeTypographyHarmony(old,proposed:proposed,peers:liveCards,
                        frame:restoration.cleanupGeometry?.frame,owner:owner,hiddenIDs:hiddenIDs,removedIDs:removedIDs,surfaceFits: { candidate in
                            growthSession.holdsSurface(item:pageItem(candidate),typography:candidate.typography,
                                foreground:candidate.style.foreground)
                        }) else { return false }
                    liveCards[i]=proposed;return true
                }
                let axisResult = NativeTypographyHarmonyAxis.align(members:members,groups:liveGroups,columnLinks:columnLinks,
                    ink:{ cardWholeRangeRect(liveCards[$0]) ?? .zero },snapshot:{ liveCards[$0] },
                    restore:{ liveCards[$0]=$1 },flush:{ i, edge in
                        var proposed=liveCards[i]
                        proposed.style.horizontalAlignment=edge == 0 ? .left : .right
                        proposed.style.blockRowHorizontalAlignment = proposed.style.horizontalAlignment
                        proposed.typography=remeasureTypography(proposed)
                        return safelyCommit(proposed,at:i)
                    },move:{ i,dx,dy in
                        let old=liveCards[i],owner=ownerOf(old,state:liveCards.map(pageItem))
                        guard let proposed=moveTypographyHarmony(old,dx:dx,dy:dy,peers:liveCards,
                            frame:restoration.cleanupGeometry?.frame,owner:owner,hiddenIDs:hiddenIDs,removedIDs:removedIDs,
                            surfaceFits:{candidate in growthSession.holdsSurface(item:pageItem(candidate),typography:candidate.typography,
                                foreground:candidate.style.foreground)}) else { return false }
                        liveCards[i]=proposed;return true
                    })
                for change in axisResult.moves {
                    liveCards[change.index].harmonyRecord["rowHarmonyAxis"] = [Double(change.dx),Double(change.dy)]
                    if let edge=change.columnEdge {
                        liveCards[change.index].harmonyRecord["columnRowAxis"] = [Double(edge),Double(change.dy)]
                    }
                }
                for (i,edge) in axisResult.flushed { liveCards[i].harmonyRecord["rowHarmonyFlush"] = edge == 0 ? "left":"right" }
                axisCards=Dictionary(liveCards.map { ($0.item.id,$0) },uniquingKeysWith:{first,_ in first})
                let committed=Dictionary(liveCards.map { ($0.item.id,remember($0)) },uniquingKeysWith:{first,_ in first})
                return state.map { committed[$0.id] ?? $0 }
            }, harmonyCohort: { state in
                var liveCards=state.compactMap(currentCard)
                snapTypographyCohorts(cards:&liveCards,restoration:restoration,layout:layout,growthSession:growthSession,
                    plateSession:plateSession,rowGroups:harmonyRows,originalFonts:snapshot.mapValues(\.finalFontSize),
                    beforeCondensed:axisCards,hiddenIDs:hiddenIDs,removedIDs:removedIDs,lockedIDs:lockedIDs,
                    ownerOf:{card,peers in ownerOf(card,state:peers.map(pageItem))})
                let committed=Dictionary(liveCards.map {($0.item.id,remember($0))},uniquingKeysWith:{a,_ in a})
                return state.map {committed[$0.id] ?? $0}
            })
        let byID = Dictionary(result.items.map { ($0.id,$0) }, uniquingKeysWith: { first,_ in first })
        for i in cards.indices {
            guard let item = byID[cards[i].item.id], !lockedIDs.contains(item.id) else { continue }
            if let accepted = proposals[item.id]?.last(where: { $0.0 == item }) {
                cards[i] = accepted.1
                continue
            }
            if let projected=currentCard(item) { cards[i]=projected }
        }
    }
}
