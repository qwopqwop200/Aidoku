import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Bounded source-backed recovery. No cached-input repair or runtime PDF observer.
enum NativeSourceBootstrapBirth {
    typealias R = NativeTranslationRenderer
    enum Domain: String { case observedSurface, unassignedIncumbentRectangle }
    struct Proposal {
        let owner: CGRect
        let incumbent: CGRect
        let panel: CGRect
        let frame: CGRect
        let surface: NativeTextBoxContainment.Surface?
        let fixedOtherOwners: [CGRect]
        var sourcePanelColorObserved = false
        var domain: Domain { surface == nil ? .unassignedIncumbentRectangle : .observedSurface }
    }
    struct Budget {
        static let maximumBirths = 2
        static let maximumAlphaPixels = 8_000_000
        private(set) var charged = 0
        mutating func reserve(_ count: Int) -> Bool {
            guard count > 0, count <= Self.maximumAlphaPixels - charged else { return false }
            charged += count
            return true
        }
    }
    struct Admission {
        let accepted: Bool
        let reason: String
        var clipPixels = 0
        var peerPixels = 0
        var occupied = 0
        var audit: [String: Any] {
            ["accepted": accepted, "reason": reason, "clipPixels": clipPixels,
             "peerPixels": peerPixels, "occupiedAcrossModes": occupied,
             "modes": ["bitmap", "PDF-snapped-bitmap"], "serializedPDFMeasured": false]
        }
    }
    static func propose(owner: CGRect, panel: CGRect, incumbent: CGRect, sourceRect: CGRect,
                        surface: NativeTextBoxContainment.Surface?, peers: [CGRect], fixedOtherOwners: [CGRect], hasText: Bool) -> Proposal? {
        guard hasText, [owner,panel,incumbent,sourceRect].allSatisfy(R.valid),
              sourceRect.contains(incumbent), incumbent.contains(owner) else { return nil }
        let retained = panel.contains(owner) ? panel : incumbent
        guard incumbent.contains(retained), retained.contains(owner),
              surface.map({ $0.contains(owner) && $0.contains(retained) }) ?? true else { return nil }
        let frame: CGRect
        if let surface {
            guard let found = surface.inscribed(near: owner, within: retained, protectedRects: peers,
                fullClearance: false), surface.contains(found) else { return nil }
            frame = found.intersection(owner)
        } else { frame = owner }
        guard R.valid(frame), frame.width > 2, frame.height > 2,
              owner.contains(frame), retained.contains(frame) else { return nil }
        return Proposal(owner: owner, incumbent: incumbent, panel: retained, frame: frame, surface: surface,
                        fixedOtherOwners: fixedOtherOwners)
    }
    static func admit(card: R.Card, proposal: Proposal, peers: [R.Card], sourceBaselinePanels: [R.Card], fixedOwners: [CGRect],
                      bounds: CGRect, sourceRect: CGRect, pixels: CGSize, pdfScale: CGFloat,
                      budget: inout Budget) throws -> Admission {
        func reject(_ reason: String) -> Admission { Admission(accepted: false, reason: reason) }
        let panel = card.sourcePlateRect
        guard proposal.sourcePanelColorObserved, R.valid(panel), panel.contains(proposal.owner),
              proposal.incumbent.contains(panel), bounds.contains(panel), sourceRect.contains(panel),
              proposal.surface.map({ $0.contains(proposal.owner) && $0.contains(panel) }) ?? true else {
            return reject("source-panel-domain-or-color-unproven")
        }
        // Other source obligations may overlap an incumbent opaque peer plate.
        // Never authorize newly covering any part not already covered by one complete old plate.
        for owner in fixedOwners {
            let hit = panel.intersection(owner)
            if R.valid(hit), !sourceBaselinePanels.contains(where: { $0.drawsPanel && $0.sourcePlateRect.contains(hit) }) {
                return reject("new-panel-over-other-fixed-source-owner")
            }
        }
        return try admitAlpha(card: card, peers: peers, bounds: bounds, sourceRect: sourceRect,
                              pixels: pixels, pdfScale: pdfScale, budget: &budget)
    }
    static func admitAlpha(card: R.Card, peers: [R.Card], bounds: CGRect, sourceRect: CGRect,
                           pixels: CGSize, pdfScale: CGFloat, budget: inout Budget) throws -> Admission {
        func reject(_ reason: String) -> Admission { Admission(accepted: false, reason: reason) }
        let panel = card.sourcePlateRect
        let text = card.item.typesettingText ?? card.item.text
        guard R.bootstrapSupportsCard(card),
              NativeTranslationTypography.committedParagraphRawComplete(card.typography, original: text),
              NativeTranslationTypography.sourceOwnershipCoverage(card.typography, originalText: text)?.whole == true else {
            return reject("unsupported-or-incomplete-saved-UTF16")
        }
        let sx = pixels.width / bounds.width, sy = pixels.height / bounds.height
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0, pdfScale.isFinite, pdfScale > 0 else { return reject("invalid-grid") }
        // Global output-lattice ROI, not a fractional local bitmap phase.
        let ink = card.typography.inkBounds.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y)
        guard R.valid(ink), bounds.contains(ink) else { return reject("raw-ink-envelope-outside-output") }
        let envelope = ink.union(panel).insetBy(dx: -max(2, 2/sx), dy: -max(2, 2/sy))
        let left = floor((envelope.minX-bounds.minX)*sx), top = floor((envelope.minY-bounds.minY)*sy)
        let right = ceil((envelope.maxX-bounds.minX)*sx), bottom = ceil((envelope.maxY-bounds.minY)*sy)
        guard [left,top,right,bottom].allSatisfy(\.isFinite), right-left > 0, bottom-top > 0,
              right-left <= 4096, bottom-top <= 4096 else { return reject("invalid-ROI") }
        let width = Int(right-left), height = Int(bottom-top), count = width*height
        let roi = CGRect(x: bounds.minX+left/sx, y: bounds.minY+top/sy,
                         width: CGFloat(width)/sx, height: CGFloat(height)/sy)
        var relevant: [R.Card] = []
        for peer in peers {
            let domain = peer.textPaintDomain?.rect ?? peer.sourcePlateRect
            guard R.valid(domain) else { return reject("unknown-peer-domain") }
            if R.valid(roi.intersection(domain)) {
                guard R.bootstrapSupportsCard(peer) else { return reject("unsupported-nearby-peer") }
                relevant.append(peer)
            }
        }
        // Charge both modes, all clears/scans and every own/peer draw. No refunds.
        let factor = 2*(8+relevant.count)
        guard count <= Budget.maximumAlphaPixels/factor, budget.reserve(count*factor) else { return reject("alpha-work-budget") }
        try Task.checkCancellation()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return reject("alpha-allocation") }
        context.translateBy(x: -left, y: bottom)
        context.scaleBy(x: sx, y: -sy)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        func paint(_ cards: [R.Card], snap: CGFloat?, raw: Bool = false) throws -> [UInt8] {
            try Task.checkCancellation()
            bytes.update(repeating: 0, count: count*4)
            context.saveGState()
            if !raw { context.clip(to: sourceRect) }
            R.withWorkerGraphicsContext(context) {
                for original in cards {
                    var c = original
                    if raw { c.textPaintDomain = R.TextPaintDomain(rect: bounds, polygon: [], within: bounds) }
                    R.draw(c, context: context, opacity: 1, paintsBackground: false, paintsText: true,
                           paintsSourcePanels: false, pixelSnapScale: snap)
                }
            }
            context.restoreGState()
            return (0..<count).map { bytes[$0*4+3] }
        }
        var loss = 0, collisions = 0, occupied = 0
        for snap: CGFloat? in [nil,pdfScale] {
            let raw = try paint([card], snap: snap, raw: true)
            let retained = try paint([card], snap: snap)
            let peer = try paint(relevant, snap: snap)
            var modeOccupied = 0
            for i in raw.indices {
                if raw[i] > 0, i < width || i >= count-width || i%width == 0 || i%width == width-1 {
                    return reject("raw-alpha-allocation-boundary-unknown")
                }
                if raw[i] > retained[i] { loss += 1 }
                if retained[i] > 0 { modeOccupied += 1 }
                if retained[i] > 0 && peer[i] > 0 { collisions += 1 }
            }
            guard modeOccupied > 0 else { return reject("no-retained-glyph-alpha") }
            occupied += modeOccupied
        }
        return Admission(accepted: loss == 0 && collisions == 0, reason: loss > 0 ? "strict-alpha-clip" : collisions > 0 ? "born-empty-peer-collision" : "bounded-two-mode-alpha",
                         clipPixels: loss, peerPixels: collisions, occupied: occupied)
    }
}

extension NativeTranslationRenderer {
    static func bootstrapSupportsCard(_ c: Card) -> Bool {
        c.sourceBackgroundKind == "solid-text-box" && c.effectiveTextRotation == 0
            && c.unitTextParts.isEmpty && c.style.outlineGlow == 0 && c.outlineGlow == 0
            && c.heavyStrokeWidth == 0 && c.style.fontSize.isFinite && c.style.fontSize > 0
            && c.style.outlineWidth.isFinite && c.style.outlineWidth >= 0
            && c.textOrigin.x.isFinite && c.textOrigin.y.isFinite
    }
}

extension NativeTranslationRenderer {
    // Conservative structural paint-change screen for deterministic plain solid Cards.
    // It is not a serialized-PDF certificate; offline native proof validates every actual changed owner.
    static func bootstrapPaintUnchanged(_ a: Card, _ b: Card) -> Bool {
        a.item == b.item && a.textOrigin == b.textOrigin && a.textShift == b.textShift
            && a.lineOffsets == b.lineOffsets && a.authoredTextOrigin == b.authoredTextOrigin
            && a.sourcePlateRect == b.sourcePlateRect && a.straightenedPanelRect == b.straightenedPanelRect
            && a.drawsPanel == b.drawsPanel && a.background == b.background
            && a.textBoxClip == b.textBoxClip && a.textBoxBackgroundClip == b.textBoxBackgroundClip
            && a.textPaintDomain?.rect == b.textPaintDomain?.rect && a.textPaintDomain?.polygon == b.textPaintDomain?.polygon
            && a.usesFallbackVeil == b.usesFallbackVeil && a.heavyStrokeWidth == b.heavyStrokeWidth
            && a.style.fontName == b.style.fontName && a.style.fontScript == b.style.fontScript
            && a.style.fontSize == b.style.fontSize && a.style.bold == b.style.bold && a.style.vertical == b.style.vertical
            && a.style.foreground == b.style.foreground && a.style.outline == b.style.outline
            && a.style.outlineWidth == b.style.outlineWidth && a.style.outlinePaintOrder == b.style.outlinePaintOrder
            && a.style.tracking == b.style.tracking && a.style.lineHeight == b.style.lineHeight
            && a.style.horizontalScale == b.style.horizontalScale
            && a.typography.shapedText == b.typography.shapedText && a.typography.glyphBounds == b.typography.glyphBounds
            && a.typography.inkBounds == b.typography.inkBounds && a.typography.size == b.typography.size
            && a.typography.lineCount == b.typography.lineCount
    }
    static func bootstrapPlainWorld(_ cards: [Card]) -> Bool {
        cards.allSatisfy { c in bootstrapSupportsCard(c) && c.sourcePanels.isEmpty && c.backings.isEmpty
            && c.foreignFills.isEmpty && !c.captionParentPlate && !c.glyphPlateReleased
            && c.glyphCoverPatch == nil && c.glyphCoverOwnerPanel == nil && c.columnFrameImages.isEmpty }
    }
}
