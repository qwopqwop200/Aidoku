import CoreGraphics
import Foundation

/// Mutable surface access deliberately stays separate from glyph measurement.
/// The caller supplies actual final-layout trials and keeps their complete layout snapshots.
protocol NativeFinalRestorationCandidate: AnyObject {
    var trialSurface: NativeResidualTopology.Surface { get set }
}

enum NativeFinalRestorationTrial {
    struct Geometry {
        var imageSize: CGSize
        var frame: CGRect
        var cropOrigin: CGPoint
        var scale: CGSize
        var sourceBounds: [Double]
        var auxiliaryInkRects: [[Double]] = []
        var sourceFontSize: Double?
    }
    struct BalloonInput {
        var geometry: Geometry
        var plate: CGRect
        var budgetAvailable = true
        var erasureComplete = false
        var partialErasureCertified = false
        var provisional = false
        var localProposalDetached = false
        var canvasConnected = true
        var canvasOwnedByRoot = true
        var canvasHidden = false
        var sourcePanelAlreadyReleased = false
        var rotation: Double = 0
        var balancedColumn = false
        var nodePresent = true
        var plateConnected = true
        var nodeHidden = false
        var nodeScaled = false
        var parentIsRoot = true
        var parentIsPlate = false
        var sourceErasureRestored = false
        var residualRefusedOnCurrentSurfaceAndPlate = false
    }
    struct BalloonCallbacks {
        /// Original entry.restorationFitEligible(true), remeasured after every surface mutation.
        var restorationFitEligible: () -> Bool
        /// Original entry.completeResidualErasure; nil means the owned residual cannot be completed.
        var completeResidualErasure: () -> (() -> Void)?
        var sourceResidualFilled: () -> Double
        /// Original fitBalloon(false,true,true,true), with actual shaped glyph/surface admission.
        var fitBalloon: () -> Bool
        /// Called before fit when the node was parented by its plate, preserving its measured world rectangle.
        var liftNodeFromPlate: () -> Void
        /// Restore CSS, original plate parent and next sibling after a rejected glyph trial.
        var restoreNodeToPlate: () -> Void
        var attachProposal: () -> Void
        var detachProposal: () -> Void
        /// Original commitRestorationFit, backing removal, and sourceErasureRestored||'late-restoration'.
        var commitRestorationFit: (_ enclosedSpecks: Int?, _ localProposalCommitted: Bool) -> Void
    }
    final class BalloonBudget {
        var searches = 0
        var successfulFits = 0
    }
    struct BalloonOutcome: Equatable {
        var accepted = false
        var searched = false
        var enclosedSpecks: Int?
        var localProposalCommitted = false
    }

    static func balloonSafeFit(candidate: any NativeFinalRestorationCandidate, input: BalloonInput,
                               budget: BalloonBudget, callbacks: BalloonCallbacks) -> BalloonOutcome {
        var outcome = BalloonOutcome()
        let proposal = input.provisional && input.localProposalDetached
        let surface = candidate.trialSurface
        guard input.budgetAvailable, budget.searches < 3, input.erasureComplete, !input.partialErasureCertified,
              proposal || (!input.provisional && input.canvasConnected && input.canvasOwnedByRoot && !input.canvasHidden),
              !input.sourcePanelAlreadyReleased, input.rotation == 0 || input.rotation.isNaN, !input.balancedColumn,
              input.nodePresent, input.plateConnected, !input.nodeHidden, !input.nodeScaled,
              input.parentIsRoot || input.parentIsPlate, surface.width > 0, surface.height > 0,
              surface.width <= 262_144 / surface.height else { return outcome }
        if !input.sourceErasureRestored && !callbacks.restorationFitEligible() &&
            surface.coreClear != true && surface.innerCoreClear != true { return outcome }
        let g = input.geometry
        if NativeResidualTopology.hiddenForeignRepaint(width: surface.width, height: surface.height,
            imageSize: g.imageSize, frame: g.frame, cropOrigin: g.cropOrigin, scale: g.scale,
            sourceFontSize: g.sourceFontSize, sourceBounds: g.sourceBounds, auxiliaryInkRects: g.auxiliaryInkRects,
            plate: input.plate, detachedProposal: proposal, rgba: surface.rgba) != 0 { return outcome }
        if proposal { callbacks.attachProposal() }
        var repaired = candidate.trialSurface
        let specks = NativeResidualTopology.fillEnclosedSpecks(surface: &repaired)
        candidate.trialSurface = repaired
        func undoSpecks() {
            if let specks { var current = candidate.trialSurface; specks.restore(&current); candidate.trialSurface = current }
        }
        var undoResidual: (() -> Void)?
        if !input.sourceErasureRestored && !callbacks.restorationFitEligible() {
            if !input.residualRefusedOnCurrentSurfaceAndPlate { undoResidual = callbacks.completeResidualErasure() }
            let font = g.sourceFontSize.flatMap { $0 == 0 || $0.isNaN ? nil : $0 } ?? 8
            let glyph = max(4, font * Double(g.imageSize.width) / Double(g.frame.width) * Double(g.scale.width))
            if undoResidual == nil || callbacks.sourceResidualFilled() > max(24, glyph * glyph * 0.25) || !callbacks.restorationFitEligible() {
                undoResidual?(); undoSpecks(); if proposal { callbacks.detachProposal() }; return outcome
            }
        }
        if input.parentIsPlate { callbacks.liftNodeFromPlate() }
        budget.searches += 1; outcome.searched = true
        if !callbacks.fitBalloon() {
            if input.parentIsPlate { callbacks.restoreNodeToPlate() }
            undoResidual?(); undoSpecks(); if proposal { callbacks.detachProposal() }; return outcome
        }
        outcome.accepted = true
        outcome.enclosedSpecks = specks == nil ? nil : candidate.trialSurface.enclosedSpecks
        outcome.localProposalCommitted = proposal
        callbacks.commitRestorationFit(outcome.enclosedSpecks, proposal)
        budget.successfulFits += 1
        return outcome
    }

    struct MarginCoverage {
        var viewportRects: [CGRect]
        var regions: [[Double]]
        var core: [[Double]]
        var glyphSize: Double
    }
    /// Source-size fringes are intersected with the existing plate, then mapped
    /// to the reconstruction's own crop. A broader neighboring canvas is never extrapolated.
    static func marginCoverage(geometry g: Geometry, sourceFrame: CGRect, oldPlate: CGRect,
                               padding: CGSize, displayedFontSize: Double) -> MarginCoverage? {
        let bounds = [g.sourceBounds] + g.auxiliaryInkRects
        guard bounds.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) && $0[2] > 0 && $0[3] > 0 }) else { return nil }
        let coverage = bounds.compactMap { b -> CGRect? in
            let l = max(Double(oldPlate.minX), Double(sourceFrame.minX) + b[0] * Double(sourceFrame.width) - Double(padding.width))
            let t = max(Double(oldPlate.minY), Double(sourceFrame.minY) + b[1] * Double(sourceFrame.height) - Double(padding.height))
            let r = min(Double(oldPlate.maxX), Double(sourceFrame.minX) + (b[0] + b[2]) * Double(sourceFrame.width) + Double(padding.width))
            let bottom = min(Double(oldPlate.maxY), Double(sourceFrame.minY) + (b[1] + b[3]) * Double(sourceFrame.height) + Double(padding.height))
            return r > l && bottom > t ? CGRect(x: l, y: t, width: r - l, height: bottom - t) : nil
        }
        let iw = Double(g.imageSize.width), ih = Double(g.imageSize.height), sx = Double(g.scale.width), sy = Double(g.scale.height)
        let x = Double(g.cropOrigin.x), y = Double(g.cropOrigin.y)
        let regions = coverage.map { r in
            [((Double(r.minX - g.frame.minX) * iw / Double(g.frame.width)) - x) * sx,
             ((Double(r.minY - g.frame.minY) * ih / Double(g.frame.height)) - y) * sy,
             Double(r.width) * iw / Double(g.frame.width) * sx, Double(r.height) * ih / Double(g.frame.height) * sy]
        }
        let core = bounds.map { b in [(b[0] * iw - x) * sx, (b[1] * ih - y) * sy, b[2] * iw * sx, b[3] * ih * sy] }
        let font = g.sourceFontSize.flatMap { $0 == 0 || $0.isNaN ? nil : $0 } ?? displayedFontSize
        return MarginCoverage(viewportRects: coverage, regions: regions, core: core,
            glyphSize: max(4, font * iw / Double(g.frame.width) * sx))
    }
    /// The initial chromatic-glyph proof exemption is intentionally absent
    /// when rechecking pixels inherited from another reconstruction.
    static func certifiesEarlyMargin(surface: NativeResidualTopology.Surface, coverage: MarginCoverage,
                                     sourceVertical: Bool, sourceSingleColumn: Bool, restorationMethod: String?,
                                     sourceGlyphsVerified: Bool, sourceErasureVerified: Bool, groupRecheck: Bool = false) -> Bool {
        let glyphProof = restorationMethod == "chromatic-balloon-glyphs" && sourceGlyphsVerified
        if (groupRecheck || !glyphProof) && sourceVertical && !sourceSingleColumn &&
            NativeResidualTopology.hasAttachedLeadingInk(safe: surface.safe, width: surface.width, height: surface.height,
                core: coverage.core, glyph: coverage.glyphSize) { return false }
        let ownedBodyClear = sourceErasureVerified && ((!groupRecheck && glyphProof) ||
            !NativeResidualTopology.hasResidualLettering(safe: surface.safe, width: surface.width, height: surface.height,
                regions: coverage.core, glyphSize: coverage.glyphSize))
        return ownedBodyClear || NativeResidualTopology.restoredErasureCovers(safe: surface.safe, width: surface.width,
            height: surface.height, regions: coverage.regions, glyphSize: coverage.glyphSize, core: coverage.core)
    }

    struct ShortCaptionInput {
        var geometry: Geometry
        var plate: CGRect
        var inpaintingEnabled = true
        var opacity: Double = 1
        var erasureComplete = false
        var provisional = false
        var partialErasureCertified = false
        var rotation: Double = 0
        var sourceSingleColumn = false
        var text = ""
        var sourceRemainingInk: Double?
        var canvasConnected = true
        var nodePresent = true
        var plateCount = 1
        var parentIsRoot = true
        var parentIsPlate = false
        /// Source world rectangles from every other item's sourceBounds and auxiliaryInkRects.
        var otherSourceRects: [CGRect] = []
        var fontSize: Double = 8
    }
    struct ShortCaptionOutcome: Equatable {
        var accepted = false
        var unsafe: Int?
        var strokeWidth: Double?
        var enclosedSpecks: Int?
        /// Frozen final short-caption style, applied only after surface admission.
        static let foreground = [40.0, 40, 48]
        static let stroke = [250.0, 250, 250]
    }
    static func shortCaption(candidate: any NativeFinalRestorationCandidate, input: ShortCaptionInput) -> ShortCaptionOutcome {
        var outcome = ShortCaptionOutcome()
        let initial = candidate.trialSurface, g = input.geometry, w = initial.width, h = initial.height
        guard input.inpaintingEnabled, input.opacity == 1, input.erasureComplete, !input.provisional,
              !input.partialErasureCertified, input.rotation == 0 || input.rotation.isNaN, input.sourceSingleColumn,
              g.auxiliaryInkRects.isEmpty, input.text.unicodeScalars.count <= 12, w > 0, h > 0, w <= 65_536 / h,
              let remaining = input.sourceRemainingInk, remaining.isFinite, remaining <= 8, input.canvasConnected,
              input.nodePresent, input.plateCount == 1, input.parentIsRoot || input.parentIsPlate,
              initial.safe.count == w * h, g.sourceBounds.count == 4, g.sourceBounds.allSatisfy(\.isFinite) else { return outcome }
        if input.otherSourceRects.contains(where: { other in
            other.minX < input.plate.maxX && other.maxX > input.plate.minX &&
            other.minY < input.plate.maxY && other.maxY > input.plate.minY
        }) { return outcome }
        var surface = initial
        let undo = NativeResidualTopology.fillEnclosedSpecks(surface: &surface)
        candidate.trialSurface = surface
        let source = g.sourceBounds, iw = Double(g.imageSize.width), ih = Double(g.imageSize.height)
        let sx = Double(g.scale.width), sy = Double(g.scale.height), x = Double(g.cropOrigin.x), y = Double(g.cropOrigin.y)
        let l = max(0, ceil((source[0] * iw - x) * sx)), t = max(0, ceil((source[1] * ih - y) * sy))
        let r = min(Double(w), floor(((source[0] + source[2]) * iw - x) * sx))
        let bottom = min(Double(h), floor(((source[1] + source[3]) * ih - y) * sy))
        guard [l, t, r, bottom].allSatisfy(\.isFinite) else {
            if let undo { undo.restore(&surface); candidate.trialSurface = surface }; return outcome
        }
        var unsafe = 0, unresolved = false, visited = [Bool](repeating: false, count: w * h)
        let glyph = max(4, (g.sourceFontSize ?? 0) * iw / Double(g.frame.width) * sx)
        if l < r && t < bottom { for yy in Int(t)..<Int(bottom) { for xx in Int(l)..<Int(r) {
            let start = yy * w + xx
            if surface.safe[start] != 0 { continue }
            unsafe += 1
        } } }
        outcome.unsafe = unsafe
        if l < r && t < bottom { for yy in Int(t)..<Int(bottom) { for xx in Int(l)..<Int(r) {
            let start = yy * w + xx
            if surface.safe[start] != 0 || visited[start] { continue }
            var queue = [start], head = 0, edge = false, x0 = xx, x1 = xx, y0 = yy, y1 = yy
            visited[start] = true
            while head < queue.count {
                let i = queue[head], px = i % w, py = i / w; head += 1
                x0 = min(x0, px); x1 = max(x1, px); y0 = min(y0, py); y1 = max(y1, py)
                if px == 0 || py == 0 || px == w - 1 || py == h - 1 { edge = true }
                for v in max(0, py - 1)...min(h - 1, py + 1) { for u in max(0, px - 1)...min(w - 1, px + 1) {
                    let j = v * w + u
                    if surface.safe[j] == 0 && !visited[j] { visited[j] = true; queue.append(j) }
                } }
            }
            if !edge || Double(max(x1 - x0, y1 - y0)) < glyph * 0.5 { unresolved = true }
        } } }
        if unresolved || Double(unsafe) > (r - l) * (bottom - t) * 0.05 {
            if let undo { undo.restore(&surface); candidate.trialSurface = surface }; return outcome
        }
        outcome.accepted = true; outcome.strokeWidth = min(0.7, input.fontSize * 0.045)
        outcome.enclosedSpecks = undo == nil ? nil : surface.enclosedSpecks
        return outcome
    }
}
