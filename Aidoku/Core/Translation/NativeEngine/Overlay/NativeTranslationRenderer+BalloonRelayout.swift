import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    static func joinedUnitMembers(_ item: NativeTranslationLayoutItem) -> [[CGFloat]]? {
        let b = item.sourceBounds, members = item.unitMemberRects
        guard item.balloonInterior != nil, (2...8).contains(members.count), b.count == 4 else { return nil }
        guard members.allSatisfy({ r in
            r.count == 4 && r.allSatisfy(\.isFinite) && r[2] > 0 && r[3] > 0 &&
            r[0] >= b[0] - 1e-4 && r[1] >= b[1] - 1e-4 &&
            r[0] + r[2] <= b[0] + b[2] + 1e-4 && r[1] + r[3] <= b[1] + b[3] + 1e-4
        }) else { return nil }
        return members.sorted { $0[2] * $0[3] > $1[2] * $1[3] }
    }

    /// One observation budget and one cached contour per page. Failed proposals
    /// never alter a card; packing owns admission and the final geometry commit.
    final class BalloonRelayoutContext {
        let layout: NativeTranslationLayout
        let source: CGImage?
        var restoration: NativeTranslationRestoration.Result
        var cards: [Card]
        var cleanupFrame: CGRect { restoration.cleanupGeometry?.frame ?? layout.sourceRect }
        let estimator = NativeBalloonInteriorEstimator()
        var interiors: [String: NativeBalloonRelayout.Interior] = [:]
        var inspected = Set<String>()

        init(layout: NativeTranslationLayout, source: CGImage?, restoration: NativeTranslationRestoration.Result, cards: [Card]) {
            self.layout = layout; self.source = source; self.restoration = restoration; self.cards = cards
        }

        func refresh(cards: [Card], restoration: NativeTranslationRestoration.Result) {
            self.cards = cards; self.restoration = restoration
        }

        func shape(_ card: Card, rect: CGRect, font: Double, pitch: Double) -> Card {
            var result = card
            result.item.x = rect.minX; result.item.y = rect.minY
            result.authoredTextOrigin = rect.origin
            result.item.width = rect.width; result.item.height = rect.height
            result.item.paddingTop = 0; result.item.paddingRight = 0
            result.item.paddingBottom = 0; result.item.paddingLeft = 0
            result.item.typesettingText = nil; result.item.typesettingQuoteMode = nil; result.item.typesettingBlockDisplay = nil; result.item.typesettingPreformattedRows = nil; result.item.typesettingPreservedBlockWrapper = nil
            result.style.usesBlockWordLayout = false; result.style.usesPreformattedBlockRows = false; result.style.blockWordLayoutUsesTopPadding = false
            result.style.fontSize = CGFloat(font); result.style.lineHeight = CGFloat(pitch)
            result.style.tracking = -CGFloat(font) * 0.012
            result.style.alignsToTop = false
            result.typographyWidth = nil; result.lineOffsets = []; result.textShift = .zero
            result.item = NativeTranslationRenderer.usedLayoutItem(result.item)
            result.typography = NativeTranslationRenderer.remeasureTypography(result, text: result.item.text)
            result.finalFontSize = result.style.fontSize
            return result
        }

        func interior(_ card: Card, sources: [CGRect], unitCount: Int) -> NativeBalloonRelayout.Interior? {
            let item = card.item
            if inspected.contains(item.id) { return interiors[item.id] }
            inspected.insert(item.id)
            let contour = item.balloonInterior
            var observed: NativeBalloonRelayout.Interior?
            if let contour, contour.contourVerified || unitCount >= 2 {
                observed = NativeBalloonRelayout.nativeUnitInterior(frame: cleanupFrame,
                    rect: contour.rect, spans: contour.spans, surfaceRGB: NativeTranslationRenderer.rgb(restoration.appearances[item.id]?.background))
            }
            if observed == nil, let source {
                let union = unitCount > 0 ? NativeTranslationRenderer.pageRect(item.sourceBounds, frame: cleanupFrame) : nil
                observed = estimator.estimate(sourceRects: sources, unitMemberCount: unitCount,
                    sourceUnion: union, frame: cleanupFrame, sourceFontSize: item.sourceFontSize.map { Double($0) }) { rect, width, height in
                    NativeTranslationRenderer.sampleSource(source, rect: rect, frame: self.cleanupFrame, width: width, height: height)
                }
            }
            if let observed { interiors[item.id] = observed }
            return observed
        }

        func relayout(_ entry: NativeCaptionPacking.Entry, input: [NativeCaptionPacking.Entry]) -> NativeCaptionPacking.Relayout? {
            guard let card = cards.first(where: { $0.item.id == entry.id }) else { return nil }
            let item = card.item
            let members = NativeTranslationRenderer.joinedUnitMembers(item)
            let validUnit = members != nil && !entry.unitResidue
            let sourceBounds = (members ?? [item.sourceBounds]) + item.auxiliaryInkRects
            let sources = sourceBounds.compactMap { NativeTranslationRenderer.pageRect($0, frame: cleanupFrame) }
            let unitCount = members?.count ?? 0
            guard let interior = interior(card, sources: sources, unitCount: unitCount) else { return nil }
            let foreignInk = input.filter { $0.id != entry.id && NativeTranslationRenderer.valid($0.ink) }.map(\.ink)
            let foreignSources = layout.items.filter { $0.id != entry.id }.flatMap { other in
                ((NativeTranslationRenderer.joinedUnitMembers(other) ?? [other.sourceBounds]) + other.auxiliaryInkRects).compactMap { NativeTranslationRenderer.pageRect($0, frame: cleanupFrame) }
            }
            var proposal = NativeBalloonRelayout.Entry(text: item.text, renderedText: entry.text, ink: entry.ink,
                source: validUnit ? entry.source : sources.first, frame: cleanupFrame,
                font: entry.font, pitch: Double(card.style.lineHeight), foreign: foreignInk + foreignSources)
            proposal.vertical = item.vertical; proposal.rotation = Double(item.rotation)
            proposal.balancedColumn = item.balancedColumn; proposal.wrappingScript = item.wrappingScript
            proposal.isUnit = validUnit; proposal.tightInterior = interior.tight
            let beforeFlow = NativeTranslationTypography.wordFlow(layout: card.typography, originalText: item.text)
            proposal.strandedBefore = beforeFlow.wordSplits == 0 && beforeFlow.strandedSyllable
            guard let result = NativeBalloonRelayout.relayout(proposal, outside: interior.outside, measure: { candidate in
                let shaped = self.shape(card, rect: candidate.rect, font: candidate.font, pitch: candidate.pitch)
                let flow = NativeTranslationTypography.wordFlow(layout: shaped.typography, originalText: item.text)
                return .init(ink: NativeTranslationRenderer.cardInkRect(shaped),
                    scrollWidth: Double(max(shaped.typography.size.width, shaped.item.contentRect.width)),
                    clientWidth: Double(shaped.item.contentRect.width), splitsWord: flow.wordSplits > 0,
                    strandedSyllable: flow.strandedSyllable)
            }) else { return nil }
            let final = shape(card, rect: result.candidate.rect, font: result.candidate.font, pitch: result.candidate.pitch)
            return .init(ink: result.ink, font: result.candidate.font, sources: sources,
                textRect: result.candidate.rect, linePitch: result.candidate.pitch,
                packingValid: final.typography.fits && NativePanelGeometry.inside(result.ink, final.item.rect, tolerance: 1),
                interiorOutside: interior.outside)
        }
    }
}
