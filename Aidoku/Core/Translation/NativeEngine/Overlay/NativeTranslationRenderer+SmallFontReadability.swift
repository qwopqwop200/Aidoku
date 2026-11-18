import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Recover requested capacity lost when source-panel separation moves a
    /// backing away from its saved text frame. All paint roles and backings are
    /// frozen; admission checks complete ink and both possible peer states.
    static func recoverSeparatedTextCapacity(cards: inout [Card],
                                             requested: [String: NativeTranslationLayoutItem],
                                             surfaces: [String: NativeTextBoxContainment.Surface],
                                             keptOwners: [CGRect], bounds: CGRect, pixels: CGSize,
                                             sourceRect: CGRect, imageSize: CGSize,
                                             pdfDeviceScale: CGFloat) throws -> Set<String> {
        let baseline = cards
        let pixelScale = CGSize(width: imageSize.width / sourceRect.width, height: imageSize.height / sourceRect.height)
        let guardSize = max(0.35, 1 / min(pixelScale.width, pixelScale.height))
        var pixelBudget = 8_000_000, shapeWork = 131_072
        var changed: Set<String> = []
        for index in cards.indices {
            try Task.checkCancellation()
            let base = baseline[index]
            guard !base.typography.fits, base.drawsPanel, base.textPaintDomain == nil,
                  base.unitTextParts.isEmpty, base.effectiveTextRotation == 0,
                  !base.item.vertical, !base.item.sourceTextOnly, base.item.wrappingScript == "korean",
                  base.item.typesettingBlockDisplay != true, base.item.typesettingPreformattedRows != true,
                  let request = requested[base.item.id], valid(request.rect),
                  base.item.width + guardSize < min(request.width, base.sourcePlateRect.width) else { continue }
            let panel = base.sourcePlateRect
            var windows = [panel]
            for peer in baseline.indices where peer != index {
                let ink = cardInkRect(baseline[peer]).insetBy(dx: -guardSize, dy: -guardSize)
                guard valid(ink), panel.intersects(ink) else { continue }
                let contacts = [
                    CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: ink.minY - panel.minY),
                    CGRect(x: panel.minX, y: ink.maxY, width: panel.width, height: panel.maxY - ink.maxY),
                    CGRect(x: panel.minX, y: panel.minY, width: ink.minX - panel.minX, height: panel.height),
                    CGRect(x: ink.maxX, y: panel.minY, width: panel.maxX - ink.maxX, height: panel.height)
                ]
                for contact in contacts where contact.size.width > 2 && contact.size.height > 2
                    && !windows.contains(contact) { windows.append(contact) }
                if windows.count >= 17 { break }
            }
            let text = base.item.typesettingText ?? base.item.text
            var rejections: [String: Int] = [:]
            var accepted: Card?
            frameSearch: for window in windows.prefix(17) {
                for width in [min(request.width, window.width), window.width] {
                    let wanted = CGRect(x: min(max(request.x, window.minX), window.maxX - width),
                        y: window.minY, width: width, height: window.height)
                    let frame = surfaces[base.item.id].flatMap {
                        $0.inscribed(near: wanted, within: window)
                    } ?? (surfaces[base.item.id] == nil ? wanted : .null)
                    guard valid(frame), frame.width > base.item.width else { continue }
                    for pitch in [CGFloat(1.05), 1.2, 1.35] {
                        guard text.utf16.count <= shapeWork else { break frameSearch }
                        shapeWork -= text.utf16.count
                        var trial = base
                        trial.item.x = frame.minX; trial.item.y = frame.minY
                        trial.item.width = frame.width; trial.item.height = frame.height
                        let padding = base.style.outlineWidth / 2 + guardSize
                        trial.item.paddingLeft = padding; trial.item.paddingRight = padding
                        trial.item.paddingTop = padding; trial.item.paddingBottom = padding
                        guard valid(trial.item.contentRect) else { continue }
                        trial.textShift = .zero; trial.typographyWidth = nil; trial.lineOffsets = []
                        trial.style.fontSize = max(base.style.fontSize, min(request.fontSize, base.style.fontSize * 2))
                        trial.style.lineHeight = trial.style.fontSize * pitch + base.style.outlineWidth + guardSize * 2
                        trial.style.horizontalWrapping = .keepAll
                        trial.typography = fitted(text: text, size: trial.item.contentRect.size, style: &trial.style)
                        guard trial.style.fontSize >= base.style.fontSize, trial.typography.fits,
                              NativeTranslationTypography.committedParagraphRawComplete(trial.typography, original: text),
                              trial.typography.lineCount <= base.typography.lineCount else {
                            rejections["complete-fit", default: 0] += 1; continue
                        }
                        if trial.typography.lineCount > 1 {
                            guard NativeTranslationTypography.minimumPaintedRowGap(layout: trial.typography)
                                .map({ $0 >= guardSize }) == true else {
                                rejections["row-gap", default: 0] += 1; continue
                            }
                        }
                        trial.item.fontSize = trial.style.fontSize; trial.item.lineHeight = trial.style.lineHeight
                        trial.finalFontSize = trial.style.fontSize
                        guard smallTextBoxInkIsPreserved(trial, pixelScale: pixelScale, foreignRects: keptOwners,
                            pdfDeviceScale: pdfDeviceScale, remainingPixels: &pixelBudget) else {
                            rejections["ink-clip-or-protection", default: 0] += 1; continue
                        }
                        var proposed = baseline
                        proposed[index] = trial
                        let rejected = try rejectNewReadabilityPeerInk(cards: &proposed, baseline: baseline,
                            changed: [base.item.id], bounds: bounds, pixels: pixels, sourceRect: sourceRect,
                            pdfDeviceScale: pdfDeviceScale)
                        guard rejected.isEmpty else { rejections["peer-ink", default: 0] += 1; continue }
                        accepted = proposed[index]
                        break frameSearch
                    }
                }
            }
            if var accepted {
                accepted.harmonyRecord["separatedTextCapacityRecovered"] = true
                cards[index] = accepted
                changed.insert(base.item.id)
            } else { cards[index].harmonyRecord["separatedTextCapacityRejections"] = rejections }
        }
        let rejected = try rejectNewReadabilityPeerInk(cards: &cards, baseline: baseline, changed: changed,
            bounds: bounds, pixels: pixels, sourceRect: sourceRect, pdfDeviceScale: pdfDeviceScale)
        changed.subtract(rejected)
        return changed
    }

    /// Fixed-frame search; source coverage, paragraph identities and translations
    /// never change. Every accepted proposal also passes actual clipped ink paint.
    static func improveSmallTextBoxes(cards: inout [Card], owners: [String: CGRect],
                                      sourceRect: CGRect, imageSize: CGSize, pdfDeviceScale: CGFloat,
                                      recoverRequestedFont: Bool = false,
                                      denseRequestedFonts: Bool = false) throws -> Set<String> {
        var changed: Set<String> = []
        var pixelBudget = 8_000_000
        var shapeWork = 131_072
        let pixelScale = CGSize(width: imageSize.width / sourceRect.width, height: imageSize.height / sourceRect.height)
        for index in cards.indices {
            try Task.checkCancellation()
            let card = cards[index], item = card.item
            guard item.rotation == 0, item.wrappingScript == "korean", !item.sourceTextOnly,
                  item.typesettingBlockDisplay != true, item.typesettingPreformattedRows != true,
                  card.typography.fits,
                  card.textPaintDomain == nil,
                  card.unitTextParts.isEmpty, card.effectiveTextRotation == 0, card.heavyStrokeWidth == 0,
                  let owner = owners[item.id] else { continue }
            if recoverRequestedFont {
                guard item.fontSize.isFinite, item.fontSize <= 2_048,
                      item.fontSize > card.style.fontSize else { continue }
            } else if card.style.fontSize >= 7.75 { continue }
            let panel = card.sourcePlateRect
            var polygon = card.textBoxClip.isEmpty
                ? [CGPoint(x: panel.minX, y: panel.minY), CGPoint(x: panel.maxX, y: panel.minY),
                   CGPoint(x: panel.maxX, y: panel.maxY), CGPoint(x: panel.minX, y: panel.maxY)]
                : NativeIndependentPanelGutter.clip(card.textBoxClip, to: panel)
            if let clip = card.textBoxBackgroundClip { polygon = NativeIndependentPanelGutter.clip(polygon, to: clip) }
            guard polygon.count >= 3, NativeSmallFontReadabilityPolicy.covered(owner, polygons: [polygon]) else { continue }
            let foreignOwners = owners.filter { $0.key != item.id }.map(\.value)
            let foreignFrames = cards.indices.filter { $0 != index }.map { cards[$0].item.rect }
            // All recipes keep item.rect fixed, so the six-surface work reservation
            // is identical even when font/padding/tracking change. Avoid shaping
            // candidates that the monotonic page budget can never evaluate.
            guard let allocation = smallTextBoxInkAllocation(frame: item.rect, pixelScale: pixelScale),
                  allocation.pixels <= pixelBudget / 6 else { continue }
            let input = NativeSmallFontReadabilityPolicy.Input(text: item.typesettingText ?? item.text,
                frame: item.rect, padding: [item.paddingLeft, item.paddingTop, item.paddingRight, item.paddingBottom],
                style: card.style, paintPolygons: [polygon], foreignRects: foreignOwners + foreignFrames,
                ordinaryKoreanCaption: true)
            let spendShapeWork: (() -> Bool)? = recoverRequestedFont ? {
                let work = max(1, input.text.utf16.count)
                guard work <= shapeWork else { return false }
                shapeWork -= work
                return true
            } : nil
            guard let proposal = NativeSmallFontReadabilityPolicy.search(input, pixelGuard: { proposal in
                var candidate = card
                candidate.item.paddingLeft = proposal.padding[0]; candidate.item.paddingTop = proposal.padding[1]
                candidate.item.paddingRight = proposal.padding[2]; candidate.item.paddingBottom = proposal.padding[3]
                candidate.style = proposal.style; candidate.typography = proposal.layout
                candidate.finalFontSize = proposal.style.fontSize
                return smallTextBoxInkIsPreserved(candidate, pixelScale: pixelScale,
                    foreignRects: foreignOwners + foreignFrames, pdfDeviceScale: pdfDeviceScale,
                    remainingPixels: &pixelBudget)
            }, canEvaluate: { allocation.pixels <= pixelBudget / 6 },
                requestedFontSize: recoverRequestedFont ? item.fontSize : nil,
                spendShapeWork: spendShapeWork,
                denseRequestedFonts: recoverRequestedFont && denseRequestedFonts) else { continue }
            cards[index].item.paddingLeft = proposal.padding[0]; cards[index].item.paddingTop = proposal.padding[1]
            cards[index].item.paddingRight = proposal.padding[2]; cards[index].item.paddingBottom = proposal.padding[3]
            cards[index].style = proposal.style; cards[index].typography = proposal.layout
            cards[index].finalFontSize = proposal.style.fontSize
            changed.insert(item.id)
        }
        return changed
    }

    /// Final backing/clip are frozen. Fitting baselines require a strict font gain;
    /// failed baselines may recover full fit at the unchanged readability floor.
    @discardableResult
    static func improveWaistTextBoxes(cards: inout [Card], surfaces: [String: NativeTextBoxContainment.Surface],
                                      requested: [String: NativeTranslationLayoutItem], owners: [String: CGRect],
                                      sourceRect: CGRect, imageSize: CGSize, pdfDeviceScale: CGFloat,
                                      recordFitRecovery: ((String) -> Void)? = nil,
                                      confirmedClipLossIDs: Set<String> = [],
                                      onlyConfirmedClipLoss: Bool = false,
                                      recordInkRecovery: ((String) -> Void)? = nil) throws -> [String: CGFloat] {
        var previousFonts: [String: CGFloat] = [:]
        var shapeWork = 131_072, pixelBudget = 8_000_000, geometryWork = 131_072
        var clipVerificationPixels = 8_000_000
        let pixelScale = CGSize(width: imageSize.width / sourceRect.width, height: imageSize.height / sourceRect.height)
        func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height) }
        for index in cards.indices {
            try Task.checkCancellation()
            let base = cards[index]
            let repairsClipLoss = confirmedClipLossIDs.contains(base.item.id)
            if onlyConfirmedClipLoss && !repairsClipLoss { continue }
            guard !base.item.sourceTextOnly, !base.item.vertical, base.item.rotation == 0,
                  base.textPaintDomain == nil,
                  base.item.wrappingScript == "korean", base.effectiveTextRotation == 0,
                  base.item.typesettingBlockDisplay != true, base.item.typesettingPreformattedRows != true,
                  base.unitTextParts.isEmpty, base.heavyStrokeWidth == 0,
                  let surface = surfaces[base.item.id], let request = requested[base.item.id],
                  request.fontSize.isFinite, request.fontSize >= BrowserOverlayLayoutPlanner.minimumRenderedFontSize,
                  request.fontSize <= 2_048, request.lineHeight.isFinite,
                  request.lineHeight > 0, request.lineHeight <= 4_096 else { continue }
            let wanted = request.rect.intersection(base.sourcePlateRect)
            guard valid(wanted), repairsClipLoss || !base.typography.fits ||
                (wanted.width > base.item.width && request.fontSize > base.style.fontSize) else { continue }
            let peers = owners.filter { $0.key != base.item.id }.map(\.value)
                + cards.indices.filter { $0 != index }.map { cards[$0].item.rect }
            let hits = peers.map { area(base.item.rect.intersection($0)) }
            let text = base.item.typesettingText ?? base.item.text
            // Reserve UTF16 x the worst-case fitted() entry count, not a candidate-number cap.
            let ticks = max(1, Int(floor(request.fontSize * 4))
                - Int(ceil(BrowserOverlayLayoutPlanner.minimumRenderedFontSize * 4)) + 1)
            let work = max(1, text.utf16.count) * (3 + Int(ceil(log2(Double(ticks) + 1))))
            var best = base
            var bestPreservesInk = base.typography.fits && !repairsClipLoss
            var frames = surface.reducedHeightFrontier(near: wanted, within: base.sourcePlateRect)
            if repairsClipLoss, let full = surface.inscribed(near: wanted, within: base.sourcePlateRect,
                protectedRects: peers) { frames.append(full) }
            if !base.typography.fits || repairsClipLoss {
                // The requested frame is a preferred position, not the capacity
                // ceiling when its current ink is mostly clipped away.
                let available = surface.rect.intersection(base.sourcePlateRect).insetBy(dx: 0.7, dy: 0.7)
                var capacityRequest = wanted
                if repairsClipLoss, valid(available) {
                    capacityRequest.size = available.size
                }
                let widths = surface.capacityWidths(near: capacityRequest, within: base.sourcePlateRect,
                    remainingWork: &geometryWork)
                for width in widths {
                    try Task.checkCancellation()
                    let work = surface.spans.count * 8
                    guard work <= geometryWork else { break }
                    geometryWork -= work
                    var probe = wanted
                    probe.size.width = width
                    if repairsClipLoss, valid(available) { probe.size.height = available.height }
                    probe.origin.x = wanted.midX - width / 2
                    if let full = surface.inscribed(near: probe, within: base.sourcePlateRect,
                        required: CGSize(width: width, height: min(probe.height, available.height))) {
                        frames.append(full)
                    }
                    frames += surface.reducedHeightFrontier(near: probe, within: base.sourcePlateRect)
                }
            }
            var seen: Set<[CGFloat]> = []
            let candidates = frames.filter { seen.insert([$0.minX, $0.minY, $0.width, $0.height]).inserted }.sorted {
                func distance(_ r: CGRect) -> CGFloat { pow(r.midX - wanted.midX, 2) + pow(r.midY - wanted.midY, 2) }
                return $0.height == $1.height ? distance($0) < distance($1) : $0.height > $1.height
            }
            for frame in candidates {
                try Task.checkCancellation()
                guard zip(peers, hits).allSatisfy({
                    area(frame.intersection($0.0)) <= $0.1 + max(1, $0.1) * 1e-12
                }) else { continue }
                guard work <= shapeWork else { break }
                guard let allocation = smallTextBoxInkAllocation(frame: frame, pixelScale: pixelScale),
                      allocation.pixels <= pixelBudget / 6 else { continue }
                shapeWork -= work
                var trial = base
                if repairsClipLoss { trial.sourcePlateOwnerRect = base.sourcePlateRect }
                trial.item.x = frame.minX; trial.item.y = frame.minY
                trial.item.width = frame.width; trial.item.height = frame.height
                guard trial.item.contentRect.width > 0, trial.item.contentRect.height > 0 else { continue }
                trial.style.fontSize = request.fontSize
                trial.style.lineHeight = max(request.fontSize, request.lineHeight)
                trial.style.tracking = -request.fontSize * 0.012
                trial.typography = fitted(text: text, size: trial.item.contentRect.size, style: &trial.style)
                guard trial.typography.fits,
                      !bestPreservesInk || trial.style.fontSize > best.style.fontSize,
                      trial.typography.visibleUTF16Range.location == 0,
                      trial.typography.visibleUTF16Range.length == text.utf16.count else { continue }
                trial.finalFontSize = trial.style.fontSize
                guard smallTextBoxInkIsPreserved(trial, pixelScale: pixelScale, foreignRects: peers,
                    pdfDeviceScale: pdfDeviceScale, remainingPixels: &pixelBudget) else { continue }
                if repairsClipLoss {
                    guard let audit = finalTextClipAudit(trial, pixelScale: pixelScale,
                        pdfDeviceScale: pdfDeviceScale, remainingPixels: &clipVerificationPixels,
                        forceMeasurement: true),
                          audit["status"] as? String == "measured-within-allocation",
                          let modes = audit["modes"] as? [[String: Any]], modes.count == 2,
                          modes.allSatisfy({ ($0["rawOccupiedPixels"] as? Int ?? 0) > 0
                            && ($0["clipLossPixels"] as? Int) == 0 }) else { continue }
                }
                best = trial
                bestPreservesInk = true
                if best.style.fontSize == request.fontSize { break }
            }
            if best.style.fontSize > base.style.fontSize { previousFonts[base.item.id] = base.style.fontSize }
            if !base.typography.fits && best.typography.fits { recordFitRecovery?(base.item.id) }
            if repairsClipLoss && bestPreservesInk { recordInkRecovery?(base.item.id) }
            cards[index] = best
        }
        return previousFonts
    }

    /// Certify only new occupied pixels; arbitrary baseline overlaps are not repaired here.
    /// Frozen B/Q peer states make each certificate independent of subsequent rollbacks.
    /// Any new pair collision has an endpoint in Q[i] \ B[i]; that endpoint is
    /// checked against both possible peer states. Pixels occupied by both B cards
    /// remain allowed, even when those cards retain improvements elsewhere.
    /// This certifies the specified bitmap lattice in both anchor modes, not arbitrary PDF CTMs.
    static func rejectNewReadabilityPeerInk(cards: inout [Card], baseline: [Card], changed: Set<String>,
                                           bounds: CGRect, pixels: CGSize, sourceRect: CGRect,
                                           pdfDeviceScale: CGFloat,
                                           recordRejection: ((String, String) -> Void)? = nil) throws -> Set<String> {
        try Task.checkCancellation()
        guard !changed.isEmpty else { return [] }
        let proposed = cards
        var rejected = changed.subtracting(Set(proposed.map { $0.item.id }))
        func restore(_ index: Int, reason: String) {
            cards[index] = baseline[index]
            rejected.insert(proposed[index].item.id)
            recordRejection?(proposed[index].item.id, reason)
        }
        // Production passes an index-preserving snapshot taken before both searches.
        guard baseline.count == proposed.count,
              zip(baseline, proposed).allSatisfy({ $0.0.item.id == $0.1.item.id }) else {
            cards = baseline
            for id in changed { recordRejection?(id, "index-mismatch") }
            return changed
        }
        for id in rejected { recordRejection?(id, "index-mismatch") }
        guard valid(bounds), valid(sourceRect),
              [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY,
               sourceRect.minX, sourceRect.minY, sourceRect.maxX, sourceRect.maxY].allSatisfy(\.isFinite),
              pixels.width.isFinite, pixels.height.isFinite,
              pixels.width > 0, pixels.height > 0, pixels.width <= 16_384, pixels.height <= 16_384,
              pixels.width.rounded(.towardZero) == pixels.width,
              pixels.height.rounded(.towardZero) == pixels.height,
              pdfDeviceScale.isFinite, pdfDeviceScale > 0 else {
            for index in proposed.indices where changed.contains(proposed[index].item.id) {
                restore(index, reason: "invalid-grid")
            }
            return rejected
        }
        let width = Int(pixels.width), height = Int(pixels.height)
        let sx = pixels.width / bounds.width, sy = pixels.height / bounds.height
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else {
            for index in proposed.indices where changed.contains(proposed[index].item.id) {
                restore(index, reason: "invalid-grid")
            }
            return rejected
        }
        typealias Cover = (left: Int, top: Int, right: Int, bottom: Int)
        func cover(_ card: Card) -> Cover? {
            let rect = card.textPaintDomain?.rect ?? card.sourcePlateRect
            guard card.sourceBackgroundKind == "solid-text-box", valid(rect) else { return nil }
            let values = [floor((rect.minX - bounds.minX) * sx) - 1,
                          floor((rect.minY - bounds.minY) * sy) - 1,
                          ceil((rect.maxX - bounds.minX) * sx) + 1,
                          ceil((rect.maxY - bounds.minY) * sy) + 1]
            guard values.allSatisfy(\.isFinite) else { return nil }
            // Clamp before Int conversion, including entirely off-canvas plates.
            return (Int(max(0, min(CGFloat(width), values[0]))),
                    Int(max(0, min(CGFloat(height), values[1]))),
                    Int(max(0, min(CGFloat(width), values[2]))),
                    Int(max(0, min(CGFloat(height), values[3]))))
        }
        func intersects(_ a: Cover, _ b: Cover) -> Bool {
            a.left < a.right && a.top < a.bottom && b.left < b.right && b.top < b.bottom
                && a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
        }
        func supported(_ card: Card) -> Bool {
            // Small transparency-layer shadows are not raster-equivalent to the full canvas.
            // This gate's callers create plain solid cards, without unit-part reshaping.
            card.style.outlineGlow == 0 && card.outlineGlow == 0 && card.unitTextParts.isEmpty
                && card.style.fontSize.isFinite && card.style.fontSize > 0
                && card.style.outlineWidth.isFinite && card.style.outlineWidth >= 0
                && card.heavyStrokeWidth.isFinite && card.heavyStrokeWidth >= 0
                && card.effectiveTextRotation.isFinite
                && card.textOrigin.x.isFinite && card.textOrigin.y.isFinite
                && valid(card.item.contentRect)
                && [card.item.contentRect.minX, card.item.contentRect.minY,
                    card.item.contentRect.maxX, card.item.contentRect.maxY].allSatisfy(\.isFinite)
                && card.textBoxClip.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        }
        let baseCovers = baseline.map(cover), proposalCovers = proposed.map(cover)
        var remainingWork = 8_000_000
        for index in proposed.indices where changed.contains(proposed[index].item.id) {
            try Task.checkCancellation()
            let before = baseline[index], after = proposed[index]
            guard after.effectiveTextRotation == 0, before.sourcePlateRect == after.sourcePlateRect,
                  before.textPaintDomain == nil, after.textPaintDomain == nil,
                  before.textBoxClip == after.textBoxClip,
                  before.textBoxBackgroundClip == after.textBoxBackgroundClip,
                  before.sourceBackgroundKind == after.sourceBackgroundKind,
                  supported(before), supported(after), let hardCover = proposalCovers[index],
                  hardCover.left < hardCover.right, hardCover.top < hardCover.bottom else {
                restore(index, reason: "clip-changed-or-unsupported-self")
                continue
            }
            var peerStates: [Card] = []
            var collisionCover: Cover?
            func includeIntersection(_ peerCover: Cover) {
                // Both covers already include the device-AA halo on the global lattice.
                let overlap: Cover = (max(hardCover.left, peerCover.left), max(hardCover.top, peerCover.top),
                                      min(hardCover.right, peerCover.right), min(hardCover.bottom, peerCover.bottom))
                if let previous = collisionCover {
                    collisionCover = (min(previous.left, overlap.left), min(previous.top, overlap.top),
                                      max(previous.right, overlap.right), max(previous.bottom, overlap.bottom))
                } else { collisionCover = overlap }
            }
            var unavailable = false
            for peer in proposed.indices where peer != index {
                try Task.checkCancellation()
                // A missing hard clip cannot be used to cull an unsupported peer.
                guard let proposedCover = proposalCovers[peer], let baseCover = baseCovers[peer] else {
                    unavailable = true; break
                }
                if intersects(hardCover, proposedCover) {
                    guard supported(proposed[peer]) else { unavailable = true; break }
                    peerStates.append(proposed[peer])
                    includeIntersection(proposedCover)
                }
                if changed.contains(proposed[peer].item.id), intersects(hardCover, baseCover) {
                    guard supported(baseline[peer]) else { unavailable = true; break }
                    peerStates.append(baseline[peer])
                    includeIntersection(baseCover)
                }
            }
            guard !unavailable else { restore(index, reason: "unsupported-peer"); continue }
            // No possible peer support means no collision, without spending raster work.
            // The separate full-ink preservation guard remains responsible for visibility.
            guard !peerStates.isEmpty, let roi = collisionCover else { continue }
            let roiWidth = roi.right - roi.left, roiHeight = roi.bottom - roi.top
            // Per mode: three clears, three scans, two own draws + all peer states.
            // Draw cost is a bounded raster-pixel reservation, not a CoreText CPU bound.
            let factor = 2 * (8 + peerStates.count)
            guard roiWidth <= remainingWork / factor / roiHeight else {
                restore(index, reason: "work-budget"); continue
            }
            let count = roiWidth * roiHeight
            remainingWork -= count * factor
            var paintRejection = "buffer-unavailable"
            let passes = try autoreleasepool { () throws -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: nil, width: roiWidth, height: roiHeight,
                        bitsPerComponent: 8, bytesPerRow: roiWidth * 4, space: space,
                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                      let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
                // Full output CTM plus an integer device translation; never a fractional ROI origin.
                context.translateBy(x: -CGFloat(roi.left), y: CGFloat(roi.bottom))
                context.scaleBy(x: sx, y: -sy)
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                context.clip(to: sourceRect)
                var newInk = [UInt8](repeating: 0, count: count)
                func clear() throws {
                    for row in 0..<roiHeight {
                        if row.isMultiple(of: 64) { try Task.checkCancellation() }
                        bytes.advanced(by: row * context.bytesPerRow).update(repeating: 0, count: roiWidth * 4)
                    }
                }
                func paint(_ card: Card, snap: CGFloat?) throws {
                    try Task.checkCancellation()
                    withWorkerGraphicsContext(context) {
                        draw(card, context: context, opacity: 1, paintsBackground: false,
                            paintsText: true, paintsSourcePanels: false, pixelSnapScale: snap)
                    }
                }
                for snap: CGFloat? in [nil, pdfDeviceScale] {
                    try clear()
                    try paint(before, snap: snap)
                    for row in 0..<roiHeight {
                        if row.isMultiple(of: 64) { try Task.checkCancellation() }
                        for column in 0..<roiWidth {
                            newInk[row * roiWidth + column] = bytes[row * context.bytesPerRow + column * 4 + 3]
                        }
                    }
                    try clear()
                    try paint(after, snap: snap)
                    var hasNewInk = false
                    for row in 0..<roiHeight {
                        if row.isMultiple(of: 64) { try Task.checkCancellation() }
                        for column in 0..<roiWidth {
                            let pixel = row * roiWidth + column
                            let alpha = bytes[row * context.bytesPerRow + column * 4 + 3]
                            newInk[pixel] = alpha > 0 && newInk[pixel] == 0 ? 1 : 0
                            hasNewInk = hasNewInk || newInk[pixel] != 0
                        }
                    }
                    // This is only the collision ROI: ink may be elsewhere on the plate.
                    // No new occupancy here is safe in this mode, not a visibility failure.
                    guard hasNewInk else { continue }
                    try clear()
                    for peer in peerStates { try paint(peer, snap: snap) }
                    for row in 0..<roiHeight {
                        if row.isMultiple(of: 64) { try Task.checkCancellation() }
                        for column in 0..<roiWidth where newInk[row * roiWidth + column] != 0 {
                            if bytes[row * context.bytesPerRow + column * 4 + 3] > 0 {
                                paintRejection = "collision"
                                return false
                            }
                        }
                    }
                }
                return true
            }
            if !passes { restore(index, reason: paintRejection) }
        }
        try Task.checkCancellation()
        return rejected
    }

    /// Stage a complete caption group at the actual output CTM. Unsupported or
    /// exhausted measurement rejects the proposal, not the incumbent paragraphs.
    /// This checks native bitmap/snapped painter support, not serialized PDF or artwork GT.
    static func stagedCaptionInkPreserved(cards: [Card], indices: [Int], bounds: CGRect,
                                         pixels: CGSize, sourceRect: CGRect, pdfDeviceScale: CGFloat,
                                         remainingSamples: inout Int) throws -> Bool {
        try Task.checkCancellation()
        guard !indices.isEmpty, Set(indices).count == indices.count,
              indices.allSatisfy({ cards.indices.contains($0) }), valid(bounds), valid(sourceRect),
              [pixels.width, pixels.height, pdfDeviceScale].allSatisfy({ $0.isFinite && $0 > 0 }),
              pixels.width <= 16_384, pixels.height <= 16_384,
              pixels.width.rounded(.towardZero) == pixels.width,
              pixels.height.rounded(.towardZero) == pixels.height else { return false }
        let sx = pixels.width / bounds.width, sy = pixels.height / bounds.height
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return false }
        var plans: [(Int, CGRect, Int, Int)] = []
        var cost = 0
        for index in indices {
            let card = cards[index], text = card.item.typesettingText ?? card.item.text
            guard card.effectiveTextRotation == 0, !card.item.vertical, card.unitTextParts.isEmpty,
                  card.heavyStrokeWidth == 0, card.outlineGlow == 0, card.style.outlineGlow == 0,
                  card.style.outlineWidth.isFinite, card.style.outlineWidth >= 0, card.typography.fits,
                  NativeTranslationTypography.committedParagraphRawComplete(card.typography, original: text),
                  valid(card.sourcePlateRect), valid(card.item.rect), valid(cardInkRect(card)),
                  card.textBoxClip.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
            let glyph = card.typography.glyphBounds.reduce(CGRect.null) { $0.union($1) }
                .offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y)
            guard valid(glyph) else { return false }
            let margin = max(8, card.style.outlineWidth * 4 + 2)
            let ink = card.item.rect.union(cardInkRect(card)).union(glyph).insetBy(dx: -margin, dy: -margin)
            let left = floor((ink.minX - bounds.minX) * sx), top = floor((ink.minY - bounds.minY) * sy)
            let right = ceil((ink.maxX - bounds.minX) * sx), bottom = ceil((ink.maxY - bounds.minY) * sy)
            guard [left, top, right, bottom].allSatisfy(\.isFinite), right > left, bottom > top,
                  right - left <= 4_096, bottom - top <= 4_096 else { return false }
            let width = Int(right - left), height = Int(bottom - top)
            guard width <= 1_000_000 / height else { return false }
            let next = cost.addingReportingOverflow(width * height * 6)
            guard !next.overflow else { return false }
            cost = next.partialValue
            plans.append((index, CGRect(x: bounds.minX + left / sx, y: bounds.minY + top / sy,
                width: CGFloat(width) / sx, height: CGFloat(height) / sy), width, height))
        }
        guard cost <= remainingSamples else { return false }
        remainingSamples -= cost // Precharge the entire group, including rejected attempts.
        for (index, frame, width, height) in plans {
            let card = cards[index]
            for snap: CGFloat? in [nil, pdfDeviceScale] {
                try Task.checkCancellation()
                func alpha(_ kind: Int) throws -> [UInt8]? {
                    try Task.checkCancellation()
                    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                          let context = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                          let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
                    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: sx, y: -sy)
                    context.translateBy(x: -frame.minX, y: -frame.minY)
                    if kind == 0 {
                        NativeTranslationTypography.draw(layout: card.typography, in: context, at: card.textOrigin,
                            additionalFillStrokeWidth: 0, outlinePaintOrder: card.style.outlinePaintOrder, pixelSnapScale: snap)
                    } else if kind == 1 {
                        context.clip(to: sourceRect)
                        withWorkerGraphicsContext(context) {
                            draw(card, context: context, opacity: 1, paintsBackground: false,
                                paintsText: true, paintsSourcePanels: false, pixelSnapScale: snap)
                        }
                    } else {
                        context.clip(to: sourceRect)
                        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(card.sourcePlateRect)
                    }
                    var values = [UInt8](repeating: 0, count: width * height)
                    for y in 0..<height {
                        if y.isMultiple(of: 64) { try Task.checkCancellation() }
                        for x in 0..<width { values[y * width + x] = bytes[y * context.bytesPerRow + x * 4 + 3] }
                    }
                    return values
                }
                guard let raw = try alpha(0), let clipped = try alpha(1), let plate = try alpha(2) else { return false }
                var occupied = false
                for pixel in raw.indices {
                    if pixel.isMultiple(of: 16_384) { try Task.checkCancellation() }
                    if raw[pixel] > 0 {
                        occupied = true
                        if raw[pixel] > clipped[pixel] || plate[pixel] != 255 { return false }
                    }
                }
                guard occupied else { return false }
            }
        }
        try Task.checkCancellation()
        return true
    }

    /// Diagnostic-only final-painter comparison. Screening never certifies untested cards.
    static func finalTextClipAudit(_ card: Card, pixelScale: CGSize, pdfDeviceScale: CGFloat,
                                   remainingPixels: inout Int, forceMeasurement: Bool = false,
                                   auditEveryFinalCard: Bool = false) -> [String: Any]? {
        // This opt-in belongs only to the final diagnostics loop. Default calls
        // retain the historical repair screening/admission behavior exactly.
        var evidence: [String: Any] = [:]
        func report(_ status: String, reason: String? = nil, fields: [String: Any] = [:]) -> [String: Any] {
            var result = evidence
            result.merge(fields) { _, new in new }
            result["status"] = status
            if auditEveryFinalCard {
                result["ordinaryClipMeasured"] = status == "measured-within-allocation"
                result["alphaVisibilityLossMeasured"] = status == "measured-within-allocation"
                result["serializedPDFMeasured"] = false
                result["finalCompositeMeasured"] = false
                result["scope"] = "isolated retained-layout bitmap alpha; PDF-snapped bitmap is not serialized PDF raster or final composite"
                if let reason { result["unmeasuredReason"] = reason }
            }
            return result
        }
        if auditEveryFinalCard {
            let original = card.item.typesettingText ?? card.item.text
            let inputCount = original.utf16.prefix(32_769).count
            let shapedCount = card.typography.shapedText.utf16.prefix(32_769).count
            var ownership: [String: Any] = ["status": "unmeasured", "whole": NSNull(),
                "authority": "original-to-shaped UTF16 ledger; separate from retained-frame visibility and alpha clipping"]
            if !card.unitTextParts.isEmpty {
                ownership["unmeasuredReason"] = "unit-text-parts-ownership-unobserved"
            } else if inputCount <= 32_768, shapedCount <= 32_768,
               card.typography.lineCount <= 4_096, card.typography.glyphBounds.count <= 16_384 {
                let coverage = NativeTranslationTypography.sourceOwnershipCoverage(card.typography, originalText: original)
                ownership["inputUTF16Length"] = inputCount
                ownership["shapedUTF16Length"] = shapedCount
                if let coverage {
                    ownership["status"] = "measured"
                    ownership["whole"] = coverage.whole
                    ownership["committedParagraphRawComplete"] = NativeTranslationTypography.committedParagraphRawComplete(
                        card.typography, original: original)
                } else { ownership["unmeasuredReason"] = "unverified-original-to-shaped-ownership" }
            } else { ownership["unmeasuredReason"] = "ownership-work-limit" }
            evidence["originalToShapedOwnership"] = ownership
            evidence["effectiveTextRotation"] = card.effectiveTextRotation.isFinite ? Double(card.effectiveTextRotation) : NSNull()
            evidence["detectorRotationIsNotTextRotation"] = true
            evidence["finalRasterTextCompleteness"] = NSNull()
            evidence["finalSealedGlyphCompleteness"] = NSNull()
            evidence["finalCardMissingGlyphSemantics"] = NSNull()
            evidence["alphaLossPolicy"] = [
                "strict": "Every reference alpha > clipped alpha, including delta 1; never filtered or replaced",
                "visibilityDeltaMinimum": 8, "referenceCoreAlphaMinimum": 128,
                "authority": "Separate uncalibrated 8-bit alpha heuristics, not perceptual or glyph GT; below threshold is not proven Quartz noise",
                "allocationBoundaryZeroAuthority": "Observed reference stays inside this bitmap allocation, not whole expected glyph or composite certification"
            ]
            guard card.effectiveTextRotation.isFinite, card.effectiveTextRotation == 0 else {
                return report("unmeasured", reason: "effective-text-rotation")
            }
            guard !card.item.vertical else { return report("unmeasured", reason: "vertical-text-layout") }
            guard card.unitTextParts.isEmpty else { return report("unmeasured", reason: "unit-text-parts") }
            guard card.heavyStrokeWidth == 0 else { return report("unmeasured", reason: "additional-fill-stroke-unobserved") }
            guard !card.typography.glyphBounds.isEmpty else { return report("unmeasured", reason: "no-retained-glyph-bounds") }
            guard card.typography.glyphBounds.count <= 16_384 else { return report("unmeasured", reason: "glyph-work-limit") }
            guard pixelScale.width.isFinite, pixelScale.height.isFinite, pixelScale.width > 0, pixelScale.height > 0,
                  pdfDeviceScale.isFinite, pdfDeviceScale > 0,
                  card.textOrigin.x.isFinite, card.textOrigin.y.isFinite,
                  !card.item.rect.isNull, !card.item.rect.isInfinite,
                  [card.item.rect.minX, card.item.rect.minY, card.item.rect.width, card.item.rect.height].allSatisfy(\.isFinite),
                  card.item.rect.width > 0, card.item.rect.height > 0,
                  card.style.outlineWidth.isFinite, card.style.outlineWidth >= 0 else {
                return report("unmeasured", reason: "invalid-audit-geometry-or-scale")
            }
            let clip = card.textPaintDomain?.rect ?? card.sourcePlateRect
            let polygon = card.textPaintDomain?.polygon ?? card.textBoxClip
            guard !clip.isNull, !clip.isInfinite, clip.width > 0, clip.height > 0,
                  [clip.minX, clip.minY, clip.width, clip.height].allSatisfy(\.isFinite),
                  polygon.count <= 4_096, polygon.isEmpty || polygon.count >= 3,
                  polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  card.typography.glyphBounds.allSatisfy({
                      !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0 &&
                      [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite)
                  }) else { return report("unmeasured", reason: "invalid-clip-or-glyph-geometry") }
            evidence["clipGeometry"] = polygon.isEmpty ? "rectangle-only" : "rectangle-and-polygon"
            evidence["independentTextDomain"] = card.textPaintDomain != nil
        } else {
            guard !card.textBoxClip.isEmpty, card.item.rotation == 0, !card.item.vertical,
                  card.effectiveTextRotation == 0, card.unitTextParts.isEmpty,
                  card.heavyStrokeWidth == 0, !card.typography.glyphBounds.isEmpty else { return nil }
        }
        let path = CGMutablePath()
        path.addLines(between: card.textBoxClip); path.closeSubpath()
        let bounds = card.typography.glyphBounds.map {
            $0.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y)
        }
        let screened = auditEveryFinalCard ? false : bounds.contains { rect in
            !card.sourcePlateRect.contains(rect) || [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)
            ].contains { !path.contains($0) }
        }
        guard screened || forceMeasurement || auditEveryFinalCard else { return nil }
        var frame = bounds.reduce(card.item.rect) { $0.union($1) }
        let margin = max(4, card.style.outlineWidth * 4 + 1)
        var allocationReportMargin = margin
        frame = frame.insetBy(dx: -margin, dy: -margin)
        if auditEveryFinalCard {
            // Only diagnostic allocation changes. The old capacity rectangle
            // remains the lattice phase reference, not a raster allocation.
            let legacyFrame = frame
            let ink = card.typography.inkBounds
            guard !ink.isNull, !ink.isInfinite, ink.width > 0, ink.height > 0,
                  [ink.minX, ink.minY, ink.width, ink.height].allSatisfy(\.isFinite),
                  card.style.outlineGlow.isFinite, card.style.outlineGlow >= 0,
                  card.typography.lineCount <= 4_096,
                  (card.item.typesettingText ?? card.item.text).utf16.prefix(32_769).count <= 32_768 else {
                return report("unmeasured", reason: "invalid-or-unbounded-full-ink-envelope")
            }
            var snapX: CGFloat = 0, snapY: CGFloat = 0
            for snap: CGFloat? in [nil, pdfDeviceScale] {
                guard let rows = NativeTranslationTypography.horizontalRowMetrics(layout: card.typography,
                    originalText: card.item.typesettingText ?? card.item.text, origin: card.textOrigin,
                    pixelSnapScale: snap), rows.count == card.typography.lineCount, !rows.isEmpty else {
                    return report("unmeasured", reason: "painted-row-snap-envelope-unobserved")
                }
                for row in rows {
                    guard let raw = row["unsnappedBaseline"] as? [Double], raw.count == 2,
                          let painted = row["paintedBaseline"] as? [Double], painted.count == 2,
                          (raw + painted).allSatisfy(\.isFinite) else {
                        return report("unmeasured", reason: "invalid-painted-row-snap-envelope")
                    }
                    snapX = max(snapX, CGFloat(abs(painted[0] - raw[0])))
                    snapY = max(snapY, CGFloat(abs(painted[1] - raw[1])))
                }
            }
            // glyphBounds/inkBounds already include stroke. Glow support is a
            // conservative heuristic; boundary occupancy can veto measurement,
            // but an empty boundary cannot certify every expected glyph.
            let glowMargin = card.style.outlineGlow * 4
            let marginX = max(4, 2 / pixelScale.width) + snapX + glowMargin
            let marginY = max(4, 2 / pixelScale.height) + snapY + glowMargin
            allocationReportMargin = max(marginX, marginY)
            let envelope = bounds.reduce(ink.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y)) { $0.union($1) }
            let padded = envelope.insetBy(dx: -marginX, dy: -marginY)
            // Integer-pixel shifts relative to the historical world phase keep
            // both painters (and both anchors) on the same bitmap lattice.
            let x = legacyFrame.minX + floor((padded.minX - legacyFrame.minX) * pixelScale.width) / pixelScale.width
            let y = legacyFrame.minY + floor((padded.minY - legacyFrame.minY) * pixelScale.height) / pixelScale.height
            frame = CGRect(x: x, y: y, width: padded.maxX - x, height: padded.maxY - y)
            let legacyPixels = ceil(legacyFrame.width * pixelScale.width) * ceil(legacyFrame.height * pixelScale.height)
            evidence["allocationStrategy"] = "full-positioned-glyph-and-ink-envelope; capacity rectangle excluded"
            evidence["legacyCapacityAllocationPixelsEstimate"] = legacyPixels.isFinite ? Double(legacyPixels) as Any : NSNull()
            evidence["allocationMarginsXY"] = [Double(marginX), Double(marginY)]
            evidence["observedMaximumRowSnapDisplacementXY"] = [Double(snapX), Double(snapY)]
            evidence["outlineGlowMargin"] = Double(glowMargin)
            evidence["rasterWorldPhaseReferenceOrigin"] = [Double(legacyFrame.minX), Double(legacyFrame.minY)]
            evidence["referenceEnvelopeCompletenessCertified"] = false
            evidence["allocationUnderestimatePolicy"] = "Occupied reference boundary returns unmeasured; zero edge is only an allocation observation, not glyph completeness"
        }
        let w = ceil(frame.width * pixelScale.width), h = ceil(frame.height * pixelScale.height)
        guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 4096, h <= 4096,
              w * h <= 1_000_000 else { return report("allocation-unsupported", reason: "oversize-or-invalid-allocation") }
        let width = Int(w), height = Int(h), pixels = width * height
        guard pixels <= remainingPixels / 4 else { return report("pixel-budget", reason: "fixed-final-audit-pixel-budget") }
        remainingPixels -= pixels * 4
        if auditEveryFinalCard {
            evidence["allocationFrame"] = [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
            evidence["pixelScale"] = [Double(pixelScale.width), Double(pixelScale.height)]
            evidence["pdfSnapDeviceScale"] = Double(pdfDeviceScale)
            evidence["budgetPixelsCharged"] = pixels * 4
        }
        func alpha(snap: CGFloat?, clipped: Bool) -> [UInt8]? {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: pixelScale.width, y: -pixelScale.height)
            context.translateBy(x: -frame.minX, y: -frame.minY)
            if clipped {
                draw(card, context: context, opacity: 1, paintsBackground: false,
                    paintsText: true, paintsSourcePanels: false, pixelSnapScale: snap)
            } else {
                NativeTranslationTypography.draw(layout: card.typography, in: context, at: card.textOrigin,
                    additionalFillStrokeWidth: 0, outlinePaintOrder: card.style.outlinePaintOrder, pixelSnapScale: snap)
            }
            guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return (0..<pixels).map { bytes[($0 / width) * context.bytesPerRow + ($0 % width) * 4 + 3] }
        }
        func lossObservables(raw: [UInt8], clipped: [UInt8], width: Int) -> [String: Any] {
            // Same alpha arrays, same strict definition. The optional heuristic
            // observables never replace any positive strict loss, including 1.
            let visibilityDeltaMinimum = 8, referenceCoreAlphaMinimum = 128
            var rawPixels = 0, lostPixels = 0, lostAlpha = 0
            var boundaryRawPixels = 0
            var aboveNoisePixels = 0, aboveNoiseAlpha = 0, referenceCorePixels = 0
            var coreLossPixels = 0, coreLossAlpha = 0, coreToNonCorePixels = 0, lostCorePixels = 0
            var maximumDelta = 0
            var left = width, top = raw.count / width, right = -1, bottom = -1
            for index in raw.indices {
                if raw[index] > 0 { rawPixels += 1 }
                if auditEveryFinalCard, raw[index] > 0,
                   index < width || index >= raw.count - width || index % width == 0 || index % width == width - 1 {
                    boundaryRawPixels += 1
                }
                let reference = Int(raw[index]), retained = Int(clipped[index])
                if auditEveryFinalCard, reference >= referenceCoreAlphaMinimum { referenceCorePixels += 1 }
                if raw[index] > clipped[index] {
                    let delta = reference - retained
                    lostPixels += 1; lostAlpha += delta
                    if auditEveryFinalCard {
                        maximumDelta = max(maximumDelta, delta)
                        if delta >= visibilityDeltaMinimum {
                            aboveNoisePixels += 1; aboveNoiseAlpha += delta
                            left = min(left, index % width); right = max(right, index % width)
                            top = min(top, index / width); bottom = max(bottom, index / width)
                            if reference >= referenceCoreAlphaMinimum {
                                coreLossPixels += 1; coreLossAlpha += delta
                                if retained < referenceCoreAlphaMinimum { coreToNonCorePixels += 1 }
                                if retained == 0 { lostCorePixels += 1 }
                            }
                        }
                    }
                }
            }
            var values: [String: Any] = [
                "rawOccupiedPixels": rawPixels, "clipLossPixels": lostPixels, "clipLossAlpha": lostAlpha]
            if auditEveryFinalCard {
                values["referenceAllocationBoundaryOccupiedPixels"] = boundaryRawPixels
                values["referenceWithinAllocationObserved"] = boundaryRawPixels == 0 && rawPixels > 0
                values["aboveNoiseClipLossPixels"] = aboveNoisePixels
                values["aboveNoiseClipLossAlpha"] = aboveNoiseAlpha
                values["belowNoiseThresholdClipLossPixels"] = lostPixels - aboveNoisePixels
                values["referenceCorePixels"] = referenceCorePixels
                values["coreClipLossPixels"] = coreLossPixels
                values["coreClipLossAlpha"] = coreLossAlpha
                values["coreToNonCoreClipLossPixels"] = coreToNonCorePixels
                values["fullyLostCoreClipLossPixels"] = lostCorePixels
                values["maximumClipLossAlphaDelta"] = maximumDelta
                values["aboveNoiseClipLossBounds"] = aboveNoisePixels > 0
                    ? [left, top, right - left + 1, bottom - top + 1] as Any : NSNull()
                values["lossBoundsUnits"] = "integer pixels in allocationFrame bitmap; not source glyph coordinates"
            }
            return values
        }
        var modes: [[String: Any]] = []
        for snap: CGFloat? in [nil, pdfDeviceScale] {
            guard let raw = alpha(snap: snap, clipped: false), let clipped = alpha(snap: snap, clipped: true) else {
                return report("allocation-failed", reason: "bitmap-context-or-alpha-allocation")
            }
            var mode = lossObservables(raw: raw, clipped: clipped, width: width)
            mode["anchor"] = snap == nil ? "bitmap" : "pdf-snapped-bitmap"
            if auditEveryFinalCard {
                let rawPixels = mode["rawOccupiedPixels"] as! Int
                let boundaryRawPixels = mode["referenceAllocationBoundaryOccupiedPixels"] as! Int
                guard rawPixels > 0 else {
                    mode["clipLossPixels"] = NSNull(); mode["clipLossAlpha"] = NSNull()
                    for key in Array(mode.keys) where key.contains("ClipLoss") { mode[key] = NSNull() }
                    return report("unmeasured", reason: "reference-alpha-empty", fields: ["modes": modes + [mode]])
                }
                if boundaryRawPixels > 0 {
                    return report("unmeasured", reason: "reference-reaches-allocation-boundary", fields: ["modes": modes + [mode]])
                }
            }
            modes.append(mode)
        }
        return report("measured-within-allocation", fields: ["allocationPixels": pixels,
            "allocationMargin": Double(allocationReportMargin), "modes": modes,
            "scope": "bitmap lattice, not actual PDF raster or backing-opacity proof"])
    }

    private static func smallTextBoxInkAllocation(frame original: CGRect, pixelScale: CGSize)
        -> (frame: CGRect, width: Int, height: Int, pixels: Int)? {
        let frame = original.insetBy(dx: -4, dy: -4)
        let widthValue = ceil(frame.width * pixelScale.width), heightValue = ceil(frame.height * pixelScale.height)
        guard widthValue.isFinite, heightValue.isFinite, widthValue > 0, heightValue > 0,
              widthValue <= 4096, heightValue <= 4096 else { return nil }
        let width = Int(widthValue), height = Int(heightValue)
        guard width <= 1_000_000 / height else { return nil }
        return (frame, width, height, width * height)
    }

    /// Raw glyph painting is compared to the actual card clipping path and to
    /// its opaque backing. This catches stroke/pixel-snap loss beyond font boxes.
    private static func smallTextBoxInkIsPreserved(_ card: Card, pixelScale: CGSize,
                                                  foreignRects: [CGRect], pdfDeviceScale: CGFloat,
                                                  remainingPixels: inout Int) -> Bool {
        guard let allocation = smallTextBoxInkAllocation(frame: card.item.rect, pixelScale: pixelScale) else { return false }
        let (frame, width, height, pixels) = allocation
        guard pixels <= remainingPixels / 6 else { return false }
        remainingPixels -= pixels * 6
        func alpha(snap: CGFloat?, clipped: Bool, backing: Bool) -> [UInt8]? {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: pixelScale.width, y: -pixelScale.height)
            context.translateBy(x: -frame.minX, y: -frame.minY)
            if backing, let clip = card.textBoxBackgroundClip { context.clip(to: clip) }
            if clipped {
                draw(card, context: context, opacity: 1, paintsBackground: false,
                    paintsText: true, paintsSourcePanels: false, pixelSnapScale: snap)
            } else {
                NativeTranslationTypography.draw(layout: card.typography, in: context, at: card.textOrigin,
                    additionalFillStrokeWidth: 0, outlinePaintOrder: card.style.outlinePaintOrder, pixelSnapScale: snap)
            }
            guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var values = [UInt8](repeating: 0, count: pixels)
            for y in 0..<height {
                for x in 0..<width { values[y * width + x] = bytes[y * context.bytesPerRow + x * 4 + 3] }
            }
            return values
        }
        for snap: CGFloat? in [nil, pdfDeviceScale] {
            guard let raw = alpha(snap: snap, clipped: false, backing: false), raw.contains(where: { $0 > 0 }),
                  let clipped = alpha(snap: snap, clipped: true, backing: false),
                  let covered = alpha(snap: snap, clipped: true, backing: true),
                  zip(raw, clipped).allSatisfy({ $0 <= $1 }),
                  zip(raw, covered).allSatisfy({ $0 <= $1 }) else { return false }
            // Check actual outlined pixels, not just the font's glyph boxes.
            for rect in foreignRects where rect.intersects(frame) {
                let values = [floor((rect.minX - frame.minX) * pixelScale.width),
                              ceil((rect.maxX - frame.minX) * pixelScale.width),
                              floor((rect.minY - frame.minY) * pixelScale.height),
                              ceil((rect.maxY - frame.minY) * pixelScale.height)]
                guard values.allSatisfy(\.isFinite) else { return false }
                // Intersection does not bound endpoints. Clamp before converting
                // so a distant foreign owner cannot trap an otherwise valid card.
                let left = Int(max(0, min(CGFloat(width), values[0])))
                let right = Int(max(0, min(CGFloat(width), values[1])))
                let top = Int(max(0, min(CGFloat(height), values[2])))
                let bottom = Int(max(0, min(CGFloat(height), values[3])))
                guard left < right, top < bottom else { continue }
                for y in top..<bottom {
                    for x in left..<right where raw[y * width + x] > 0 { return false }
                }
            }
        }
        return true
    }
}
