import CoreGraphics
import Foundation

/// Balloon surface geometry, not a source-glyph mask. Unknown/open surfaces abstain.
enum NativeTextBoxContainment {
    /// A partial surface estimate must not silently truncate accepted source
    /// ownership. Retaining the incumbent is not a containment certificate.
    static func sourcePreservingIntersection(panel: CGRect, surfaceBounds: CGRect, owner: CGRect) -> CGRect {
        let intersection = panel.intersection(surfaceBounds)
        return intersection.contains(owner) ? intersection : panel
    }

    /// Text-only capacity repair is distinct from admitting source-coverage growth.
    /// Identity preserves every incumbent painted/protected location, including
    /// coverage outside an imperfect contour. It does NOT certify that a larger
    /// source witness is covered or that the incumbent panel is balloon-contained.
    struct RetainedLayoutBacking {
        let panel: CGRect

        init?(panel: CGRect, owner: CGRect) {
            func valid(_ rect: CGRect) -> Bool {
                !rect.isNull && !rect.isInfinite && rect.size.width > 0 && rect.size.height > 0
                    && [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            }
            guard valid(panel), valid(owner), panel.contains(owner) else { return nil }
            self.panel = panel
        }

        func accepts(_ candidate: CGRect) -> Bool { candidate == panel }

        func accepts(_ candidate: CGRect, paintedInk: CGRect, surface: Surface) -> Bool {
            accepts(candidate) && panel.contains(paintedInk) && surface.contains(paintedInk)
        }
    }

    /// Freeze at the first admitted backing, before text recovery/refit/trim.
    /// A later, already enlarged rectangle must not become fresh paint authority.
    struct BackingInvariant {
        let baseline: CGRect
        let surface: Surface?
        let protectedRects: [CGRect]

        init?(baseline: CGRect, surface: Surface?, protectedRects: [CGRect]) {
            guard Self.valid(baseline), protectedRects.allSatisfy(Self.valid) else { return nil }
            self.baseline = baseline
            // Unsupported contours stay unknown; do not manufacture a certificate.
            self.surface = surface.flatMap { $0.contains(baseline) ? $0 : nil }
            self.protectedRects = protectedRects
        }

        func admits(_ panel: CGRect, required: CGRect) -> Bool {
            guard addsOnlyRequiredSourceCoverage(panel: panel, baseline: baseline, required: required),
                  surface.map({ $0.contains(panel) }) ?? true else { return false }
            // Protect actual newly painted locations, not just overlap area totals.
            return addedCoverage(panel: panel, baseline: baseline).allSatisfy { strip in
                !protectedRects.contains { target in Self.valid(strip.intersection(target)) }
            }
        }

        private static func valid(_ rect: CGRect) -> Bool {
            !rect.isNull && !rect.isInfinite && rect.size.width > 0 && rect.size.height > 0
                && [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
        }
    }

    private static func addedCoverage(panel: CGRect, baseline: CGRect) -> [CGRect] {
        let retained = panel.intersection(baseline)
        guard !retained.isNull, retained.size.width > 0, retained.size.height > 0 else { return [panel] }
        return [
            CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: retained.minY - panel.minY),
            CGRect(x: panel.minX, y: retained.maxY, width: panel.width, height: panel.maxY - retained.maxY),
            CGRect(x: panel.minX, y: retained.minY, width: retained.minX - panel.minX, height: retained.height),
            CGRect(x: retained.maxX, y: retained.minY, width: panel.maxX - retained.maxX, height: retained.height)
        ].filter { $0.size.width > 0 && $0.size.height > 0 }
    }

    /// Admission for a complete replacement rectangle, not a paint mask.
    /// Translation capacity cannot authorize new backing outside the incumbent.
    /// Only the separately established source-coverage envelope may do so.
    static func addsOnlyRequiredSourceCoverage(panel: CGRect, baseline: CGRect, required: CGRect) -> Bool {
        func valid(_ rect: CGRect) -> Bool {
            !rect.isNull && !rect.isInfinite && rect.size.width > 0 && rect.size.height > 0
                && [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
        }
        guard [panel, baseline, required].allSatisfy(valid), panel.contains(required) else { return false }
        // Exact set containment of every added strip. An area-only comparison
        // could trade an exposed corner for a different, newly painted corner.
        return addedCoverage(panel: panel, baseline: baseline).allSatisfy { required.contains($0) }
    }

    struct Surface {
        let rect: CGRect
        let spans: [(CGFloat, CGFloat)]
        let color: [Double]?
        var colorEvidence: String = "unverified-source-estimate"
        var geometryObserved = false

        private static func valid(_ r: CGRect) -> Bool {
            !r.isNull && !r.isInfinite && r.size.width > 0 && r.size.height > 0
                && [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite)
        }

        var certifiedSpans: Bool {
            guard Self.valid(rect), spans.count >= 2, spans.count <= 1_024,
                  spans.allSatisfy({ $0.0.isFinite && $0.1.isFinite && $0.1 > $0.0
                      && $0.0 >= rect.minX && $0.1 <= rect.maxX }) else { return false }
            // The single polygon representation must not bridge disconnected rows.
            return zip(spans, spans.dropFirst()).allSatisfy {
                min($0.0.1, $0.1.1) > max($0.0.0, $0.1.0)
            }
        }

        var polygon: [CGPoint] {
            guard certifiedSpans else { return [] }
            let step = rect.height / CGFloat(spans.count)
            let left = spans.enumerated().flatMap { row, span in
                [CGPoint(x: span.0, y: rect.minY + CGFloat(row) * step),
                 CGPoint(x: span.0, y: rect.minY + CGFloat(row + 1) * step)]
            }
            let right = spans.enumerated().reversed().flatMap { row, span in
                [CGPoint(x: span.1, y: rect.minY + CGFloat(row + 1) * step),
                 CGPoint(x: span.1, y: rect.minY + CGFloat(row) * step)]
            }
            return left + right
        }

        /// Check every intersected row, not only the surface's bounding box.
        func contains(_ rectangle: CGRect) -> Bool {
            guard certifiedSpans, Self.valid(rectangle), rect.contains(rectangle) else { return false }
            let step = rect.height / CGFloat(spans.count)
            let first = max(0, Int(floor((rectangle.minY - rect.minY) / step)))
            let last = min(spans.count - 1, Int(ceil((rectangle.maxY - rect.minY) / step)) - 1)
            guard first <= last else { return false }
            return (first...last).allSatisfy {
                rectangle.minX >= spans[$0].0 && rectangle.maxX <= spans[$0].1
            }
        }

        /// Refit a rendered bbox without trimming pixels or changing its size.
        /// Pixel-aligned translation keeps a subsequent integral bitmap crop on
        /// the same admitted contour. The complete effect/margin halo is checked.
        func containedRenderBox(_ box: CGRect, within limit: CGRect, margin: CGFloat,
                                protectedRects: [CGRect] = []) -> CGRect? {
            guard certifiedSpans, Self.valid(box), Self.valid(limit), margin.isFinite, margin >= 0 else { return nil }
            func admits(_ candidate: CGRect) -> Bool {
                let padded = candidate.insetBy(dx: -margin, dy: -margin)
                return limit.contains(padded) && contains(padded)
                    && !protectedRects.contains { Self.valid(padded.intersection($0)) }
            }
            if admits(box) { return box }
            func aligned(_ candidate: CGRect) -> CGRect? {
                let dx = (candidate.minX-box.minX).rounded(), dy = (candidate.minY-box.minY).rounded()
                for oy in [CGFloat(0), -1, 1] { for ox in [CGFloat(0), -1, 1] {
                    let proposed = box.offsetBy(dx: dx+ox, dy: dy+oy)
                    if admits(proposed) { return proposed }
                } }
                return nil
            }
            guard let proposed = inscribed(near: box, within: limit, required: box.size,
                accepts: { aligned($0) != nil }, xPlacements: { low, high, _ in
                    let contacts = [box.minX] + protectedRects.flatMap {
                        [$0.minX-margin-box.width, $0.maxX+margin]
                    }
                    return contacts.map { max(low,min(high,$0)) }
                }, boundaryInset: margin) else { return nil }
            return aligned(proposed)
        }

        /// A complete rectangle covering the source owner, not a polygon-shaped fill mask.
        func rectangularPanel(covering owner: CGRect, near wanted: CGRect, within limit: CGRect,
                              accepts: ((CGRect) -> Bool)? = nil, allowsExactCover: Bool = false,
                              boundaryInset: CGFloat = 0.7) -> CGRect? {
            guard certifiedSpans, Self.valid(owner), Self.valid(wanted), Self.valid(limit),
                  limit.contains(owner) else { return nil }
            for trial in 0..<(allowsExactCover ? 13 : 12) {
                let fraction = 1 - CGFloat(trial) / 11
                let width = trial == 12 ? owner.width
                    : max(owner.width + 1.4, owner.width + (wanted.width - owner.width) * fraction)
                let height = trial == 12 ? owner.height
                    : max(owner.height + 1.4, owner.height + (wanted.height - owner.height) * fraction)
                let target = CGRect(x: owner.midX - width / 2, y: owner.midY - height / 2, width: width, height: height)
                if let frame = inscribed(near: target, within: limit, required: target.size,
                    accepts: { $0.contains(owner) && (accepts?($0) ?? true) }, xPlacements: { low, high, _ in
                        [max(low, min(owner.midX - width / 2, high)),
                         max(low, min(owner.minX, high)), max(low, min(owner.maxX - width, high))]
                    }, boundaryInset: boundaryInset, fullClearance: true) { return frame }
            }
            return nil
        }

        func inscribed(near wanted: CGRect, within limit: CGRect, protectedRects: [CGRect] = [],
                       fullClearance: Bool = true) -> CGRect? {
            guard certifiedSpans, Self.valid(wanted), Self.valid(limit) else { return nil }
            let available = rect.intersection(limit).insetBy(dx: 0.7, dy: 0.7)
            guard available.width > 2, available.height > 2 else { return nil }
            // Preserve the requested capacity before shrinking it at one fixed Y.
            // A side lobe can contain the whole frame at a nearby row contact.
            let required = CGSize(width: min(wanted.width, available.width), height: min(wanted.height, available.height))
            var best: CGRect?
            for trial in 0..<12 {
                let height = min(wanted.height, available.height) * (1 - CGFloat(trial) * 0.055)
                let top = min(max(wanted.midY - height / 2, available.minY), available.maxY - height)
                let first = max(0, Int(floor((top - rect.minY) / rect.height * CGFloat(spans.count))))
                let last = min(spans.count - 1, Int(ceil((top + height - rect.minY) / rect.height * CGFloat(spans.count))) - 1)
                guard first <= last else { continue }
                let left = max(available.minX, spans[first...last].map(\.0).max()! + 0.7)
                let right = min(available.maxX, spans[first...last].map(\.1).min()! - 0.7)
                let width = min(wanted.width, right - left)
                guard width > 2 else { continue }
                let x = min(max(wanted.midX - width / 2, left), right - width)
                let candidate = CGRect(x: x, y: top, width: width, height: height)
                if best == nil || width * height > best!.width * best!.height { best = candidate }
            }
            let baseline = best ?? wanted
            let peers = protectedRects.filter(Self.valid)
            func area(_ r: CGRect) -> CGFloat { Self.valid(r) ? r.width * r.height : 0 }
            let previousHits = peers.map { area(baseline.intersection($0)) }
            let admissible: (CGRect) -> Bool = { candidate in
                zip(peers, previousHits).allSatisfy { peer, previous in
                    area(candidate.intersection(peer)) <= previous + max(1, previous) * 1e-12
                }
            }
            // The nearest X can be blocked while the same row has a full-width
            // safe position at a peer edge. Generate exact contact coordinates;
            // keep tolerance solely in admission, never in the edge calculation.
            let placements: ((CGFloat, CGFloat, CGFloat) -> [CGFloat])? = peers.isEmpty ? nil : { low, high, y in
                let preferred = min(max(wanted.midX - required.width / 2, low), high)
                var values = [preferred]
                for (peer, previous) in zip(peers, previousHits) {
                    let vertical = min(y + required.height, peer.maxY) - max(y, peer.minY)
                    guard vertical > 0 else { continue }
                    let allowance = previous / vertical
                    guard allowance < min(required.width, peer.width) else { continue }
                    for x in [peer.minX - required.width + allowance, peer.maxX - allowance]
                        where x >= low && x <= high { values.append(x) }
                }
                return values
            }
            if let full = inscribed(near: wanted, within: limit, required: required,
                                    accepts: peers.isEmpty ? nil : admissible, xPlacements: placements,
                                    fullClearance: fullClearance) { return full }
            return best.flatMap { admissible($0) ? $0 : nil }
        }

        /// Window-intersection width contacts, not just single-band widths. This
        /// expensive fallback is reserved for failed fits and keeps sweep work
        /// available; unsupported/oversized domains preserve the caller's baseline.
        func capacityWidths(near wanted: CGRect, within limit: CGRect, remainingWork: inout Int) -> [CGFloat] {
            guard certifiedSpans, Self.valid(wanted), Self.valid(limit) else { return [] }
            let available = rect.intersection(limit).insetBy(dx: 0.7, dy: 0.7)
            guard Self.valid(available), available.width > 2 else { return [] }
            let count = spans.count
            let reservation = count * (count + 1) / 2
            guard reservation <= remainingWork / 2 else { return [] }
            remainingWork -= reservation
            var widths: Set<CGFloat> = [min(wanted.width, available.width)]
            for first in spans.indices {
                var left = available.minX, right = available.maxX
                for last in first..<count {
                    left = max(left, spans[last].0 + 0.7)
                    right = min(right, spans[last].1 - 0.7)
                    if right - left <= 2 { break }
                    widths.insert(min(wanted.width, right - left))
                }
            }
            return widths.filter { $0 > 2 && $0.isFinite }.sorted(by: >)
        }

        /// Full requested width, reduced height: maximal row windows in O(rows).
        func reducedHeightFrontier(near wanted: CGRect, within limit: CGRect) -> [CGRect] {
            guard certifiedSpans, Self.valid(wanted), Self.valid(limit) else { return [] }
            let available = rect.intersection(limit).insetBy(dx: 0.7, dy: 0.7)
            guard Self.valid(available), wanted.width > 2, wanted.width <= available.width else { return [] }
            let step = rect.height / CGFloat(spans.count)
            guard step.isFinite, step > 0 else { return [] }
            // Sub-ULP rows do not define a representable half-open domain.
            var previousBoundary = rect.minY
            for row in 1...spans.count {
                let boundary = row == spans.count ? rect.maxY : rect.minY + CGFloat(row) * step
                guard boundary > previousBoundary else { return [] }
                previousBoundary = boundary
            }
            let firstBand = max(0, Int(floor((available.minY - rect.minY) / step)))
            let lastBand = min(spans.count - 1, Int(ceil((available.maxY - rect.minY) / step)) - 1)
            guard firstBand <= lastBand else { return [] }
            let lows = spans.map { max(available.minX, $0.0 + 0.7) }
            let highs = spans.map { min(available.maxX, $0.1 - 0.7) }
            var lq: [Int] = [], rq: [Int] = [], lh = 0, rh = 0, first = firstBand
            var previous: (first: Int, frame: CGRect)?
            var result: [CGRect] = []
            lq.reserveCapacity(spans.count); rq.reserveCapacity(spans.count)
            for last in firstBand...lastBand {
                while lq.count > lh, lows[lq.last!] <= lows[last] { lq.removeLast() }
                while rq.count > rh, highs[rq.last!] >= highs[last] { rq.removeLast() }
                lq.append(last); rq.append(last)
                while first <= last, highs[rq[rh]] - lows[lq[lh]] < wanted.width {
                    first += 1
                    while lh < lq.count, lq[lh] < first { lh += 1 }
                    while rh < rq.count, rq[rh] < first { rh += 1 }
                }
                if let previous, previous.first != first { result.append(previous.frame) }
                previous = nil
                guard first <= last else { continue }
                let top = max(available.minY, rect.minY + CGFloat(first) * step)
                let bottom = min(available.maxY, last == spans.count - 1
                    ? rect.maxY : rect.minY + CGFloat(last + 1) * step)
                var height = min(wanted.height, bottom - top)
                guard height > 2 else { continue }
                let y = max(top, min(wanted.midY - height / 2, bottom - height))
                if y + height > bottom { height = min(height, bottom.nextDown - y) }
                guard height > 2, y >= top, y + height <= bottom else { continue }
                let x = max(lows[lq[lh]], min(wanted.midX - wanted.width / 2, highs[rq[rh]] - wanted.width))
                guard x + wanted.width <= highs[rq[rh]] else { continue }
                previous = (first, CGRect(x: x, y: y, width: wanted.width, height: height))
            }
            if let previous { result.append(previous.frame) }
            // Exact duplicates only; height/distance alone cannot dominate peer/ink admission.
            var seen: Set<[CGFloat]> = []
            return result.filter { $0.height < wanted.height && seen.insert([$0.minX, $0.minY, $0.width, $0.height]).inserted }
        }

        /// Nearest fixed-capacity frame in half-open row bands. With admission
        /// constraints an optional generator can include obstacle-edge X contacts.
        /// The two sorted
        /// contact streams and monotone envelopes take O(rows) time and storage;
        /// an optional admission predicate has its own per-candidate cost.
        func inscribed(near wanted: CGRect, within limit: CGRect, required: CGSize,
                       accepts: ((CGRect) -> Bool)? = nil,
                       xPlacements: ((CGFloat, CGFloat, CGFloat) -> [CGFloat])? = nil,
                       boundaryInset: CGFloat = 0.7, fullClearance: Bool = true) -> CGRect? {
            guard certifiedSpans, Self.valid(wanted), Self.valid(limit),
                  boundaryInset.isFinite, boundaryInset >= 0,
                  required.width.isFinite, required.height.isFinite,
                  required.width > 2, required.height > 2 else { return nil }
            if fullClearance, boundaryInset > 0 {
                // Test the entire clearance rectangle, including adjacent row
                // bands above/below its paint. Insetting each visited row alone
                // misses a narrowing band just outside the proposed rectangle.
                let padding = boundaryInset
                let contacts: ((CGFloat, CGFloat, CGFloat) -> [CGFloat])? = xPlacements.map { placements in
                    { low, high, y in placements(low + padding, high + padding, y + padding).map { $0 - padding } }
                }
                return inscribed(near: wanted.insetBy(dx: -padding, dy: -padding), within: limit,
                    required: CGSize(width: required.width + padding * 2, height: required.height + padding * 2),
                    accepts: { expanded in
                        let frame = expanded.insetBy(dx: padding, dy: padding)
                        return accepts?(frame) ?? true
                    }, xPlacements: contacts, boundaryInset: 0)?.insetBy(dx: padding, dy: padding)
            }
            let available = rect.intersection(limit).insetBy(dx: boundaryInset, dy: boundaryInset)
            guard Self.valid(available), required.width <= available.width,
                  required.height <= available.height else { return nil }
            let count = spans.count
            let step = rect.height / CGFloat(count)
            func boundary(_ row: Int) -> CGFloat {
                row == count ? rect.maxY : rect.minY + CGFloat(row) * step
            }
            let low = available.minY, high = available.maxY - required.height
            let preferred = min(max(wanted.midY - required.height / 2, low), high)
            var topEvent = 0, bottomEvent = 0, nextRow = 0, firstRow = 0
            var lowPending = true, highPending = true, preferredPending = true
            var leftQueue: [Int] = [], rightQueue: [Int] = []
            leftQueue.reserveCapacity(count); rightQueue.reserveCapacity(count)
            var leftHead = 0, rightHead = 0
            var best: CGRect?, bestDistance = CGFloat.infinity
            while true {
                let a = topEvent <= count ? boundary(topEvent) : CGFloat.infinity
                let b = bottomEvent <= count ? boundary(bottomEvent) - required.height : CGFloat.infinity
                let c = lowPending ? low : CGFloat.infinity
                let d = highPending ? high : CGFloat.infinity
                let e = preferredPending ? preferred : CGFloat.infinity
                let y = min(a, min(b, min(c, min(d, e))))
                guard y.isFinite else { break }
                if a == y { topEvent += 1 }
                if b == y { bottomEvent += 1 }
                if c == y { lowPending = false }
                if d == y { highPending = false }
                if e == y { preferredPending = false }
                if y < low { continue }
                if y > high { break }
                while nextRow < count, boundary(nextRow) < y + required.height {
                    while leftQueue.count > leftHead,
                          spans[leftQueue[leftQueue.count - 1]].0 <= spans[nextRow].0 { leftQueue.removeLast() }
                    while rightQueue.count > rightHead,
                          spans[rightQueue[rightQueue.count - 1]].1 >= spans[nextRow].1 { rightQueue.removeLast() }
                    leftQueue.append(nextRow); rightQueue.append(nextRow)
                    nextRow += 1
                }
                while firstRow < count, boundary(firstRow + 1) <= y { firstRow += 1 }
                while leftHead < leftQueue.count, leftQueue[leftHead] < firstRow { leftHead += 1 }
                while rightHead < rightQueue.count, rightQueue[rightHead] < firstRow { rightHead += 1 }
                guard leftHead < leftQueue.count, rightHead < rightQueue.count else { continue }
                let left = max(available.minX, spans[leftQueue[leftHead]].0 + boundaryInset)
                let right = min(available.maxX, spans[rightQueue[rightHead]].1 - boundaryInset)
                guard right - left >= required.width else { continue }
                let x = min(max(wanted.midX - required.width / 2, left), right - required.width)
                let positions = xPlacements?(left, right - required.width, y) ?? [x]
                for position in positions where position.isFinite && position >= left && position <= right - required.width {
                    let candidate = CGRect(x: position, y: y, width: required.width, height: required.height)
                    let dx = candidate.midX - wanted.midX, dy = candidate.midY - wanted.midY
                    let distance = dx * dx + dy * dy
                    if distance < bestDistance, accepts?(candidate) ?? true { best = candidate; bestDistance = distance }
                }
            }
            return best
        }

        /// Reposition an already fitted frame without changing its capacity or paint.
        func centered(frame: CGRect, owner: CGRect, within limit: CGRect,
                      otherOwners: [CGRect], otherTextFrames: [CGRect], pixelSize: CGSize) -> CGRect {
            func valid(_ r: CGRect) -> Bool {
                !r.isNull && !r.isInfinite && r.size.width > 0 && r.size.height > 0
                    && [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite)
            }
            func area(_ r: CGRect) -> CGFloat { valid(r) ? r.width * r.height : 0 }
            let px = pixelSize.width, py = pixelSize.height
            guard certifiedSpans, [frame, owner, limit, rect].allSatisfy(valid), px.isFinite, py.isFinite, px > 0, py > 0,
                  spans.count >= 2, spans.count <= 1_024,
                  spans.allSatisfy({ $0.0.isFinite && $0.1.isFinite && $0.1 > $0.0
                      && $0.0 >= rect.minX && $0.1 <= rect.maxX }) else { return frame }
            var cell = limit.intersection(rect)
            let peers = otherOwners.filter { valid($0) && area(rect.intersection($0)) >= area($0) * 0.85 }
            for peer in peers {
                let dx = peer.midX - owner.midX, dy = peer.midY - owner.midY
                var left = cell.minX, right = cell.maxX, top = cell.minY, bottom = cell.maxY
                if abs(dx) / px >= abs(dy) / py {
                    let edge = (peer.midX + owner.midX) / 2
                    if dx > 0 { right = min(right, edge - px) } else { left = max(left, edge + px) }
                } else {
                    let edge = (peer.midY + owner.midY) / 2
                    if dy > 0 { bottom = min(bottom, edge - py) } else { top = max(top, edge + py) }
                }
                guard right > left, bottom > top else { return frame }
                cell = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            }
            guard valid(cell), frame.width <= cell.width, frame.height <= cell.height else { return frame }
            let band = rect.height / CGFloat(spans.count)
            let mass = spans.reduce(CGFloat.zero) { $0 + $1.1 - $1.0 }
            var cx: CGFloat = 0, cy: CGFloat = 0
            for (row, span) in spans.enumerated() {
                let weight = span.1 - span.0
                cx += weight * (span.0 + span.1) / 2
                cy += weight * (rect.minY + (CGFloat(row) + 0.5) * band)
            }
            cx /= mass; cy /= mass
            if !peers.isEmpty { cx = cell.midX; cy = cell.midY }
            let maxDX = 64 * px, maxDY = 64 * py
            let desired = min(max(cy - frame.height / 2, cell.minY), cell.maxY - frame.height)
            let preferred = min(max(desired, frame.minY - maxDY), frame.minY + maxDY)
            let owners = otherOwners.filter(valid), frames = otherTextFrames.filter(valid)
            let ownerHits = owners.map { area(frame.intersection($0)) }
            let textHits = frames.map { area(frame.intersection($0)) }
            let epsilon = max(CGFloat.ulpOfOne * 64, px * py * 1e-6)
            func distance(_ r: CGRect) -> CGFloat {
                pow((r.midX - cx) / px, 2) + pow((r.midY - cy) / py, 2)
            }
            let originalDistance = distance(frame)
            var best = frame, bestDistance = originalDistance
            for y in [preferred, frame.minY, (preferred + frame.minY) / 2] {
                guard y >= cell.minY, y + frame.height <= cell.maxY else { continue }
                let first = max(0, Int(floor((y - rect.minY) / band)))
                let last = min(spans.count - 1, Int(ceil((y + frame.height - rect.minY) / band)) - 1)
                guard first <= last else { continue }
                var left = cell.minX, right = cell.maxX
                for row in first...last {
                    left = max(left, spans[row].0 + px); right = min(right, spans[row].1 - px)
                }
                let low = max(left, frame.minX - maxDX), high = min(right - frame.width, frame.minX + maxDX)
                guard low <= high else { continue }
                let x = min(max(cx - frame.width / 2, low), high)
                let moved = CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
                // The fixed backing already covers the source. The translated frame
                // can move toward the balloon center independently of the old ink.
                guard zip(owners, ownerHits).allSatisfy({ area(moved.intersection($0.0)) <= $0.1 + epsilon }),
                      zip(frames, textHits).allSatisfy({ area(moved.intersection($0.0)) <= $0.1 + epsilon }) else { continue }
                let candidateDistance = distance(moved)
                if candidateDistance < originalDistance - 0.25, candidateDistance < bestDistance {
                    best = moved; bestDistance = candidateDistance
                }
            }
            return best
        }
    }

    static func known(_ interior: NativeTranslationBalloonInterior?, frame: CGRect) -> Surface? {
        guard !frame.isNull, !frame.isInfinite, frame.size.width > 0, frame.size.height > 0,
              [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite),
              let interior, interior.contourVerified, interior.rect.count == 4,
              interior.rect[2] > 0, interior.rect[3] > 0,
              interior.rect.allSatisfy(\.isFinite), interior.spans.count >= 4,
              interior.spans.count <= 2048, interior.spans.count.isMultiple(of: 2) else { return nil }
        let r = interior.normalizedRect
        guard r.width > 0, r.height > 0, CGRect(x: 0, y: 0, width: 1, height: 1).contains(r) else { return nil }
        var spans: [(CGFloat, CGFloat)] = []
        for row in stride(from: 0, to: interior.spans.count, by: 2) {
            let a = interior.spans[row], b = interior.spans[row + 1]
            guard a.isFinite, b.isFinite, a >= Double(r.minX), b <= Double(r.maxX), b > a else { return nil }
            spans.append((frame.minX + CGFloat(a) * frame.width, frame.minX + CGFloat(b) * frame.width))
        }
        let surface = Surface(rect: CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height,
                                    width: r.width * frame.width, height: r.height * frame.height), spans: spans, color: nil)
        return surface.certifiedSpans ? surface : nil
    }

    static func measured(rgba: [UInt8], width: Int, height: Int, roi: CGRect, owner: CGRect,
                         excluding peers: [CGRect] = []) throws -> Surface? {
        guard width >= 8, height >= 8, width <= 320, height <= 320, rgba.count == width * height * 4,
              roi.width > 0, roi.height > 0, roi.contains(owner),
              peers.allSatisfy({ [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite)
                  && $0.width >= 0 && $0.height >= 0 }) else { return nil }
        let dx = roi.width / CGFloat(width), dy = roi.height / CGFloat(height)
        let x0 = max(0, Int((owner.minX - roi.minX) / dx)), x1 = min(width - 1, Int((owner.maxX - roi.minX) / dx))
        let y0 = max(0, Int((owner.minY - roi.minY) / dy)), y1 = min(height - 1, Int((owner.maxY - roi.minY) / dy))
        guard x0 < x1, y0 < y1 else { return nil }
        var bins: [Int: (Int, [Double])] = [:]
        let marginX = max(2, (x1 - x0) / 5), marginY = max(2, (y1 - y0) / 5)
        // Dense source lettering may leave no background sample inside its box.
        for y in stride(from: max(0, y0 - marginY), through: min(height - 1, y1 + marginY), by: max(1, (y1 - y0) / 24)) {
            for x in stride(from: max(0, x0 - marginX), through: min(width - 1, x1 + marginX), by: max(1, (x1 - x0) / 24)) {
                let offset = (y * width + x) * 4
                guard rgba[offset + 3] >= 240 else { continue }
                let rgb = (0..<3).map { Double(rgba[offset + $0]) }
                let key = Int(rgb[0]) / 32 * 64 + Int(rgb[1]) / 32 * 8 + Int(rgb[2]) / 32
                var bin = bins[key] ?? (0, [0, 0, 0])
                bin.0 += 1
                for c in 0..<3 { bin.1[c] += rgb[c] }
                bins[key] = bin
            }
        }
        let colors = bins.keys.sorted { a, b in
            bins[a]!.0 == bins[b]!.0 ? a < b : bins[a]!.0 > bins[b]!.0
        }.prefix(4).map { key in bins[key]!.1.map { $0 / Double(bins[key]!.0) } }
        var best: (score: Double, surface: Surface)?
        var bright = [Bool](repeating: false, count: width * height)
        for index in bright.indices {
            bright[index] = (0..<3).allSatisfy { rgba[index * 4 + $0] >= 220 }
        }
        // Close one sampling-pixel gaps in a thin outline before testing enclosure.
        var expanded = bright, closed = bright
        for y in 1..<(height - 1) { for x in 1..<(width - 1) {
            expanded[y * width + x] = (-1...1).contains { row in
                (-1...1).contains { column in bright[(y + row) * width + x + column] }
            }
        } }
        for y in 1..<(height - 1) { for x in 1..<(width - 1) {
            closed[y * width + x] = (-1...1).allSatisfy { row in
                (-1...1).allSatisfy { column in expanded[(y + row) * width + x + column] }
            }
        } }
        let rim = try rimSurface(wallPixels: closed.indices.filter { closed[$0] }, rgba: rgba,
            width: width, height: height, roi: roi, owner: owner, peers: peers)
        for color in colors {
            try Task.checkCancellation()
            var marked = [UInt8](repeating: 0, count: width * height)
            for index in marked.indices {
                let offset = index * 4
                let distance = (0..<3).reduce(0.0) { sum, c in
                    let difference = Double(rgba[offset + c]) - color[c]
                    return sum + difference * difference
                }
                if rgba[offset + 3] >= 240, distance <= 55 * 55 { marked[index] = 1 }
            }
            for seed in marked.indices where marked[seed] == 1 {
                var queue = [seed], cursor = 0, open = false
                marked[seed] = 2
                var left = [Int](repeating: width, count: height), right = [Int](repeating: -1, count: height)
                var top = height, bottom = -1, sums = [Double](repeating: 0, count: 3), samples = 0
                while cursor < queue.count {
                    if cursor.isMultiple(of: 2048) { try Task.checkCancellation() }
                    let index = queue[cursor], x = index % width, y = index / width
                    cursor += 1
                    open = open || x == 0 || y == 0 || x == width - 1 || y == height - 1
                    left[y] = min(left[y], x); right[y] = max(right[y], x)
                    top = min(top, y); bottom = max(bottom, y)
                    samples += 1
                    for c in 0..<3 { sums[c] += Double(rgba[index * 4 + c]) }
                    for next in [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1,
                                 y > 0 ? index - width : -1, y + 1 < height ? index + width : -1]
                    where next >= 0 && marked[next] == 1 { marked[next] = 2; queue.append(next) }
                }
                guard !open, bottom - top >= 8, samples >= (x1 - x0) * (y1 - y0) / 10 else { continue }
                let envelopePixels = (top...bottom).reduce(0) { $0 + max(0, right[$1] - left[$1] + 1) }
                // A closed white rim also encloses the text, but is not its background surface.
                guard Double(queue.count) >= Double(envelopePixels) * 0.55 else { continue }
                var covered = 0
                for y in y0...y1 { covered += max(0, min(x1, right[y]) - max(x0, left[y]) + 1) }
                let score = Double(covered) / Double((x1 - x0 + 1) * (y1 - y0 + 1))
                guard score >= 0.85, (top...bottom).allSatisfy({ right[$0] >= left[$0] }) else { continue }
                let spans = (top...bottom).map { y in
                    (roi.minX + CGFloat(left[y]) * dx, roi.minX + CGFloat(right[y] + 1) * dx)
                }
                let rect = CGRect(x: spans.map(\.0).min()!, y: roi.minY + CGFloat(top) * dy,
                                  width: spans.map(\.1).max()! - spans.map(\.0).min()!, height: CGFloat(bottom - top + 1) * dy)
                // A solid glyph/test ink block exactly bounded by the OCR box is not a balloon.
                guard rect.width * rect.height >= owner.width * owner.height * 1.08 else { continue }
                let surface = Surface(rect: rect, spans: spans, color: sums.map { $0 / Double(samples) }, geometryObserved: true)
                if best == nil || score > best!.score { best = (score, surface) }
            }
        }
        return rim ?? best?.surface
    }

    /// Estimate paper from the interior face, never from lettering or the exterior ring.
    /// Works with both saved contours and contours measured during this invocation.
    static func faceColor(rgba: [UInt8], width: Int, height: Int, roi: CGRect,
                          surface: Surface, owner: CGRect, excluding peers: [CGRect]) throws -> [Double]? {
        guard surface.certifiedSpans, width >= 8, height >= 8, width <= 320, height <= 320,
              rgba.count == width * height * 4, roi.width > 0, roi.height > 0 else { return nil }
        let dx = roi.width / CGFloat(width), dy = roi.height / CGFloat(height)
        let margin = max(dx, dy) * 2
        let lettering = ([owner] + peers).map { $0.insetBy(dx: -margin, dy: -margin) }
        let local = owner.insetBy(dx: -max(owner.width * 0.5, margin * 4),
                                 dy: -max(owner.height * 0.5, margin * 4))
        var channels = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var blocks: Set<Int> = [], sides: Set<Int> = [], count = 0
        for y in 1..<(height - 1) {
            try Task.checkCancellation()
            let py = roi.minY + (CGFloat(y) + 0.5) * dy
            guard py >= surface.rect.minY + margin, py < surface.rect.maxY - margin else { continue }
            let row = min(surface.spans.count - 1, max(0,
                Int((py - surface.rect.minY) / surface.rect.height * CGFloat(surface.spans.count))))
            let span = surface.spans[row]
            for x in 1..<(width - 1) {
                let point = CGPoint(x: roi.minX + (CGFloat(x) + 0.5) * dx, y: py)
                guard point.x >= span.0 + margin, point.x < span.1 - margin,
                      local.contains(point), !lettering.contains(where: { $0.contains(point) }) else { continue }
                let offset = (y * width + x) * 4
                guard rgba[offset + 3] >= 240 else { continue }
                // Smooth face pixels only: reject outlines, antialiasing and artwork edges.
                var smooth = true
                for channel in 0..<3 {
                    var low = 255, high = 0
                    for yy in (y - 1)...(y + 1) { for xx in (x - 1)...(x + 1) {
                        let value = Int(rgba[(yy * width + xx) * 4 + channel])
                        low = min(low, value); high = max(high, value)
                    } }
                    if high - low > 14 { smooth = false; break }
                }
                guard smooth else { continue }
                for channel in 0..<3 { channels[channel][Int(rgba[offset + channel])] += 1 }
                count += 1; blocks.insert((y / 8) * ((width + 7) / 8) + x / 8)
                sides.insert(point.x < owner.minX ? 0 : point.x >= owner.maxX ? 1 : point.y < owner.minY ? 2 : 3)
            }
        }
        guard count >= 48, blocks.count >= 4, sides.count >= 2 else { return nil }
        func median(_ histogram: [Int], total: Int) -> Double {
            var cumulative = 0
            for value in histogram.indices {
                cumulative += histogram[value]
                if cumulative > total / 2 { return Double(value) }
            }
            return 255
        }
        func quantile(_ histogram: [Int], rank: Int) -> Int {
            var cumulative = 0
            for value in histogram.indices {
                cumulative += histogram[value]
                if cumulative > rank { return value }
            }
            return 255
        }
        let varied = channels.contains {
            quantile($0, rank: count * 9 / 10) - quantile($0, rank: count / 10) >= 24
        }
        // A translucent/gradient face is not one palette mode. A median can
        // select its white half and visibly clash with the shaded half. Use a
        // trimmed least-squares representative, still excluding all source text.
        return channels.map { histogram in
            guard varied else { return median(histogram, total: count) }
            let lower = count / 10, upper = count - lower
            var cumulative = 0, total = 0, sum = 0
            for value in histogram.indices {
                let next = cumulative + histogram[value]
                let admitted = max(0, min(next, upper) - max(cumulative, lower))
                total += admitted; sum += value * admitted; cumulative = next
            }
            return total > 0 ? Double(sum) / Double(total) : median(histogram, total: count)
        }
    }

    /// Tight backing for source coverage and actual painted ink, not layout capacity.
    /// This only shrinks the original complete rectangle; it cannot introduce overlap.
    static func tightPanel(owner: CGRect, paintedInk: CGRect, within panel: CGRect, padding: CGFloat,
                           sourcePadding: CGFloat = 0) -> CGRect? {
        guard padding.isFinite, padding >= 0, sourcePadding.isFinite, sourcePadding >= 0,
              [owner, paintedInk, panel].allSatisfy({ !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0
                  && [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite) }),
              panel.contains(owner), panel.contains(paintedInk) else { return nil }
        let wanted = owner.insetBy(dx: -sourcePadding, dy: -sourcePadding)
            .union(paintedInk).insetBy(dx: -padding, dy: -padding)
        let result = wanted.intersection(panel)
        return result.contains(owner) && result.contains(paintedInk) ? result : nil
    }

    private static func rimSurface(wallPixels: [Int], rgba: [UInt8], width: Int, height: Int,
                                   roi: CGRect, owner: CGRect, peers: [CGRect]) throws -> Surface? {
        var wall = [Bool](repeating: false, count: width * height)
        for index in wallPixels { wall[index] = true }
        var outside = [Bool](repeating: false, count: wall.count), queue: [Int] = []
        func append(_ index: Int) {
            if !wall[index], !outside[index] { outside[index] = true; queue.append(index) }
        }
        for x in 0..<width { append(x); append((height - 1) * width + x) }
        for y in 0..<height { append(y * width); append(y * width + width - 1) }
        var cursor = 0
        while cursor < queue.count {
            if cursor.isMultiple(of: 2048) { try Task.checkCancellation() }
            let index = queue[cursor], x = index % width, y = index / width
            cursor += 1
            if x > 0 { append(index - 1) }; if x + 1 < width { append(index + 1) }
            if y > 0 { append(index - width) }; if y + 1 < height { append(index + width) }
        }
        guard outside.contains(true) else { return nil }
        let dx = roi.width / CGFloat(width), dy = roi.height / CGFloat(height)
        var selected = [Bool](repeating: false, count: wall.count), visited = outside
        for seed in wall.indices where !wall[seed] && !visited[seed] {
            var hole = [seed], head = 0, minX = width, maxX = -1, minY = height, maxY = -1
            visited[seed] = true
            while head < hole.count {
                if head.isMultiple(of: 2048) { try Task.checkCancellation() }
                let index = hole[head], x = index % width, y = index / width
                head += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for next in [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1,
                             y > 0 ? index - width : -1, y + 1 < height ? index + width : -1]
                where next >= 0 && !wall[next] && !visited[next] { visited[next] = true; hole.append(next) }
            }
            let bounds = CGRect(x: roi.minX + CGFloat(minX) * dx, y: roi.minY + CGFloat(minY) * dy,
                                width: CGFloat(maxX - minX + 1) * dx, height: CGFloat(maxY - minY + 1) * dy)
            if bounds.intersects(owner) { for index in hole { selected[index] = true } }
        }
        // Include interior lettering walls, not just paper between glyphs. Otherwise
        // a connected white outline would punch old-lettering notches into the panel.
        func wallDistances(from seeds: [Bool]) throws -> [Int] {
            var distance = [Int](repeating: Int.max, count: wall.count), frontier: [Int] = []
            for index in seeds.indices where seeds[index] { distance[index] = 0; frontier.append(index) }
            var head = 0
            while head < frontier.count {
                if head.isMultiple(of: 2048) { try Task.checkCancellation() }
                let index = frontier[head], x = index % width, y = index / width
                head += 1
                for next in [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1,
                             y > 0 ? index - width : -1, y + 1 < height ? index + width : -1]
                where next >= 0 && wall[next] && distance[next] == Int.max {
                    distance[next] = distance[index] + 1; frontier.append(next)
                }
            }
            return distance
        }
        let holePixels = selected.indices.filter { selected[$0] }
        guard !holePixels.isEmpty else { return nil }
        let holeMinX = holePixels.map { $0 % width }.min()!, holeMaxX = holePixels.map { $0 % width }.max()!
        let holeMinY = holePixels.map { $0 / width }.min()!, holeMaxY = holePixels.map { $0 / width }.max()!
        let innerDistance = try wallDistances(from: selected), outerDistance = try wallDistances(from: outside)
        for index in wall.indices where wall[index] && innerDistance[index] != Int.max {
            let x = index % width, y = index / width
            if x >= holeMinX, x <= holeMaxX, y >= holeMinY, y <= holeMaxY,
               innerDistance[index] + 1 < outerDistance[index] { selected[index] = true }
        }
        // Letter outlines can split the paper into islands whose boxes do not
        // intersect the OCR owner. Reconnect those islands through interior walls.
        var interiorQueue = selected.indices.filter { selected[$0] }, interiorHead = 0
        while interiorHead < interiorQueue.count {
            if interiorHead.isMultiple(of: 2048) { try Task.checkCancellation() }
            let index = interiorQueue[interiorHead], x = index % width, y = index / width
            interiorHead += 1
            for next in [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1,
                         y > 0 ? index - width : -1, y + 1 < height ? index + width : -1]
            where next >= 0 && !selected[next] && !wall[next] && !outside[next] {
                selected[next] = true; interiorQueue.append(next)
            }
        }
        guard !(0..<width).contains(where: { selected[$0] || selected[(height - 1) * width + $0] }),
              !(0..<height).contains(where: { selected[$0 * width] || selected[$0 * width + width - 1] }) else { return nil }
        var left = [Int](repeating: width, count: height), right = [Int](repeating: -1, count: height)
        var top = height, bottom = -1, enclosed = 0
        var colorCandidates: [Int: (count: Int, sums: [Double])] = [:]
        for index in wall.indices where selected[index] {
            let x = index % width, y = index / width
            left[y] = min(left[y], x); right[y] = max(right[y], x)
            top = min(top, y); bottom = max(bottom, y); enclosed += 1
            // These holes provide candidates, never sufficient background proof.
            // A white outline can enclose the pink/black glyph itself.
            guard !wall[index], rgba[index * 4 + 3] >= 240 else { continue }
            let rgb = (0..<3).map { Double(rgba[index * 4 + $0]) }
            guard !rgb.allSatisfy({ $0 >= 200 }) else { continue }
            let key = Int(rgb[0]) / 32 * 64 + Int(rgb[1]) / 32 * 8 + Int(rgb[2]) / 32
            var bin = colorCandidates[key] ?? (0, [0, 0, 0])
            bin.count += 1
            for channel in 0..<3 { bin.sums[channel] += rgb[channel] }
            colorCandidates[key] = bin
        }
        guard bottom - top >= 8, (top...bottom).allSatisfy({ right[$0] >= left[$0] }) else { return nil }
        let envelope = (top...bottom).reduce(0) { $0 + right[$1] - left[$1] + 1 }
        guard Double(enclosed) >= Double(envelope) * 0.55 else { return nil }
        let spans = (top...bottom).map { (roi.minX + CGFloat(left[$0]) * dx, roi.minX + CGFloat(right[$0] + 1) * dx) }
        let rect = CGRect(x: spans.map(\.0).min()!, y: roi.minY + CGFloat(top) * dy,
                          width: spans.map(\.1).max()! - spans.map(\.0).min()!, height: CGFloat(bottom - top + 1) * dy)
        guard rect.width * rect.height >= owner.width * owner.height * 1.08 else { return nil }
        var covered: CGFloat = 0
        for (row, span) in spans.enumerated() {
            let y = rect.minY + (CGFloat(row) + 0.5) * dy
            if y >= owner.minY, y <= owner.maxY { covered += max(0, min(owner.maxX, span.1) - max(owner.minX, span.0)) * dy }
        }
        guard covered >= owner.width * owner.height * 0.85 else { return nil }
        var verifiedColor: [Double]?
        if let key = colorCandidates.keys.sorted().max(by: {
            colorCandidates[$0]!.count < colorCandidates[$1]!.count
        }), let bin = colorCandidates[key] {
            let candidate = bin.sums.map { $0 / Double(bin.count) }
            var support = 0, sideSupport = [Int](repeating: 0, count: 4)
            // Independently verify a hole-derived color on original pixels
            // OUTSIDE the OCR owner. Unconditional exterior-ring replacement
            // is also unsafe: the ring can cross the balloon into the artwork.
            for y in top...bottom {
                try Task.checkCancellation()
                for x in left[y]...right[y] {
                    let point = CGPoint(x: roi.minX + (CGFloat(x) + 0.5) * dx,
                                        y: roi.minY + (CGFloat(y) + 0.5) * dy)
                    guard !owner.contains(point), !peers.contains(where: { $0.contains(point) }) else { continue }
                    let offset = (y * width + x) * 4
                    guard rgba[offset + 3] >= 240,
                          (0..<3).allSatisfy({ abs(Double(rgba[offset + $0]) - candidate[$0]) <= 12 }) else { continue }
                    support += 1
                    let side = point.x < owner.minX ? 0 : point.x >= owner.maxX ? 1 : point.y < owner.minY ? 2 : 3
                    sideSupport[side] += 1
                }
            }
            if support >= 32, sideSupport.filter({ $0 >= 8 }).count >= 2 { verifiedColor = candidate }
        }
        return Surface(rect: rect, spans: spans, color: verifiedColor,
            colorEvidence: verifiedColor == nil ? "rim-candidate-unavailable-or-unsupported" : "owner-exterior-supported-candidate",
            geometryObserved: true)
    }

    /// Partition only overlapping panels; monotonically shrinking boxes cannot introduce new collisions.
    /// Translate free-text frame and backing together, keeping the covered owner set.
    static func sourceAnchored(frame: CGRect, panel: CGRect, owner: CGRect, sourceFrame: CGRect,
                               otherOwners: [CGRect], otherTextFrames: [CGRect], otherPanels: [CGRect],
                               imageSize: CGSize) -> CGPoint {
        guard sourceFrame.width > 0, sourceFrame.height > 0, imageSize.width > 0, imageSize.height > 0 else { return .zero }
        func normalized(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - sourceFrame.minX) / sourceFrame.width,
                   y: (r.minY - sourceFrame.minY) / sourceFrame.height,
                   width: r.width / sourceFrame.width, height: r.height / sourceFrame.height)
        }
        func area(_ r: CGRect) -> CGFloat { r.isNull || r.width <= 0 || r.height <= 0 ? 0 : r.width * r.height }
        func hit(_ a: CGRect, _ b: CGRect) -> CGFloat { area(a.intersection(b)) }
        let f = normalized(frame), p = normalized(panel), o = normalized(owner)
        let owners = otherOwners.map(normalized), frames = otherTextFrames.map(normalized), panels = otherPanels.map(normalized)
        let page = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard area(f) > 0, area(p) > 0, area(o) > 0, page.contains(f), page.contains(p) else { return .zero }
        var left: CGFloat = 0, top: CGFloat = 0, right: CGFloat = 1, bottom: CGFloat = 1
        for peer in owners {
            if min(o.maxY, peer.maxY) > max(o.minY, peer.minY) {
                if peer.maxX <= o.minX { left = max(left, (peer.maxX + o.minX) / 2 + 0.001) }
                if peer.minX >= o.maxX { right = min(right, (peer.minX + o.maxX) / 2 - 0.001) }
            }
            if min(o.maxX, peer.maxX) > max(o.minX, peer.minX) {
                if peer.maxY <= o.minY { top = max(top, (peer.maxY + o.minY) / 2 + 0.001) }
                if peer.minY >= o.maxY { bottom = min(bottom, (peer.minY + o.maxY) / 2 - 0.001) }
            }
        }
        guard right > left, bottom > top else { return .zero }
        let cell = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        let longest = max(imageSize.width, imageSize.height)
        func distance(_ r: CGRect) -> CGFloat {
            pow((r.midX - o.midX) * imageSize.width / longest, 2)
                + pow((r.midY - o.midY) * imageSize.height / longest, 2)
        }
        func score(_ text: CGRect, _ paint: CGRect) -> CGFloat {
            frames.reduce(0) { $0 + hit(text, $1) } + owners.reduce(0) { $0 + hit(paint, $1) }
                + 0.4 * distance(text) + max(0, area(text) - hit(text, cell))
        }
        let xs = Set([f.minX, o.midX - f.width / 2, o.minX, o.maxX - f.width,
                      cell.minX, cell.maxX - f.width, 0, 1 - f.width]).sorted()
        let ys = Set([f.minY, o.midY - f.height / 2, o.minY, o.maxY - f.height,
                      cell.minY, cell.maxY - f.height, 0, 1 - f.height]).sorted()
        let covered = p.intersection(o), oldDistance = distance(f)
        let ownerHits = owners.map { hit(p, $0) }, textHits = frames.map { hit(f, $0) }
        let margin = longest / 512 * 2
        var bestScore = score(f, p), best = CGPoint.zero
        for x in xs { for y in ys {
            let dx = x - f.minX, dy = y - f.minY
            let text = f.offsetBy(dx: dx, dy: dy), paint = p.offsetBy(dx: dx, dy: dy)
            guard page.contains(text), page.contains(paint),
                  covered.isNull || paint.insetBy(dx: -1e-12, dy: -1e-12).contains(covered),
                  distance(text) <= oldDistance + 1e-12 else { continue }
            let padded = paint.insetBy(dx: -margin / imageSize.width, dy: -margin / imageSize.height)
            guard !panels.contains(where: { hit(padded, $0) > 1e-12 }),
                  zip(owners, ownerHits).allSatisfy({ hit(paint, $0.0) <= $0.1 + 1e-12 }),
                  zip(frames, textHits).allSatisfy({ hit(text, $0.0) <= $0.1 + 1e-12 }) else { continue }
            let candidateScore = score(text, paint)
            if candidateScore < bestScore - 1e-12 {
                bestScore = candidateScore; best = CGPoint(x: dx * sourceFrame.width, y: dy * sourceFrame.height)
            }
        } }
        return best
    }

    static func separated(panels: [CGRect], owners: [CGRect], kept: [Bool], gap: CGFloat = 1.5) -> [CGRect] {
        func valid(_ r: CGRect) -> Bool {
            !r.isNull && !r.isInfinite && r.width > 0 && r.height > 0
                && [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite)
        }
        guard panels.count == owners.count, panels.count == kept.count,
              gap.isFinite, gap >= 0, panels.allSatisfy(valid), owners.allSatisfy(valid) else { return panels }
        // Preserve every part of SOURCE already covered by its original panel.
        // No separator may claim success by trimming an overlapping owner.
        let domains = panels.indices.map { panels[$0].intersection(owners[$0]) }
        guard domains.allSatisfy(valid) else { return panels }
        func edge(_ r: CGRect, axis: Int, upper: Bool) -> CGFloat {
            axis == 0 ? (upper ? r.maxX : r.minX) : (upper ? r.maxY : r.minY)
        }
        func trimmed(_ r: CGRect, axis: Int, lower: CGFloat?, upper: CGFloat?) -> CGRect {
            let x0 = axis == 0 ? max(r.minX, lower ?? r.minX) : r.minX
            let y0 = axis == 1 ? max(r.minY, lower ?? r.minY) : r.minY
            let x1 = axis == 0 ? min(r.maxX, upper ?? r.maxX) : r.maxX
            let y1 = axis == 1 ? min(r.maxY, upper ?? r.maxY) : r.maxY
            return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
        }
        let originalEdges = panels.map { [$0.minX, $0.minY, $0.maxX, $0.maxY] }
        var proposedEdges = originalEdges
        // All constraints use one immutable snapshot; intersections commute.
        for a in panels.indices {
            for b in panels.indices where b > a && (!kept[a] || !kept[b]) {
                guard valid(panels[a].intersection(panels[b])) else { continue }
                var best: (low: Int, high: Int, first: CGRect, second: CGRect, loss: CGFloat)?
                for axis in 0...1 {
                    let ca = edge(owners[a], axis: axis, upper: false) + edge(owners[a], axis: axis, upper: true)
                    let cb = edge(owners[b], axis: axis, upper: false) + edge(owners[b], axis: axis, upper: true)
                    guard ca != cb else { continue }
                    let low = ca < cb ? a : b, high = low == a ? b : a
                    let end = edge(kept[low] ? panels[low] : domains[low], axis: axis, upper: true)
                    let start = edge(kept[high] ? panels[high] : domains[high], axis: axis, upper: false)
                    guard start >= end else { continue }
                    // The preferred gutter is not permission to cut SOURCE or
                    // retain a large overlap when a smaller safe gap is possible.
                    let safeGap = min(gap, start - end)
                    let cut = end + (start - end) / 2
                    let first = kept[low] ? panels[low] : trimmed(panels[low], axis: axis, lower: nil, upper: cut - safeGap / 2)
                    let second = kept[high] ? panels[high] : trimmed(panels[high], axis: axis, lower: cut + safeGap / 2, upper: nil)
                    guard valid(first), valid(second), first.contains(domains[low]), second.contains(domains[high]),
                          edge(second, axis: axis, upper: false) >= edge(first, axis: axis, upper: true) else { continue }
                    let loss = 2 - first.width * first.height / (panels[low].width * panels[low].height)
                        - second.width * second.height / (panels[high].width * panels[high].height)
                    if best == nil || loss < best!.loss { best = (low, high, first, second, loss) }
                }
                // Infeasible owners remain overlapping, rather than uncovered.
                guard let best else { continue }
                for (index, cut) in [(best.low, best.first), (best.high, best.second)] where !kept[index] {
                    proposedEdges[index][0] = max(proposedEdges[index][0], cut.minX)
                    proposedEdges[index][1] = max(proposedEdges[index][1], cut.minY)
                    proposedEdges[index][2] = min(proposedEdges[index][2], cut.maxX)
                    proposedEdges[index][3] = min(proposedEdges[index][3], cut.maxY)
                }
            }
        }
        // Construct once: repeated CGRect intersections can round an unchanged
        // rectangle and make even KEPT geometry depend on pair traversal order.
        let result = panels.indices.map { index -> CGRect in
            let b = proposedEdges[index]
            if b == originalEdges[index] { return panels[index] }
            return CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
        }
        guard result.indices.allSatisfy({ valid(result[$0]) && result[$0].contains(domains[$0]) }) else { return panels }
        return result
    }
}
