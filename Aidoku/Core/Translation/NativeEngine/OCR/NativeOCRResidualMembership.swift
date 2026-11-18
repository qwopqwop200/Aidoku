import CoreGraphics
import Foundation

/// Group geometry and membership alternatives. Never mutates the detector inventory.
@available(iOS 18.0, *)
enum NativeOCRResidualMembership {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement

    static func candidates(_ m: Measurement) -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", m.kind == "group", m.rect.width >= 5,
              m.rect.height >= m.rect.width * 3 else { return [] }
        return [false, true].compactMap { localFit(m, useAxis: $0) }
    }

    static func candidates(_ m: Measurement, context: NativeOCRResidualSourceContext) -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", m.rect.width >= 5, m.rect.height >= m.rect.width * 3 else { return [] }
        var result = candidates(m)
        guard let layout = context.layout else { return result }
        guard let currentProof = observedSupport(m, context: context) else { return result }
        let width = m.rect.width
        // At most one neighbor on either end; no transitive same-palette chaining.
        var choices: [(NativeOCRResidualSourceContext.Region, CGFloat, Bool)] = []
        for peer in context.regions where peer.index != m.index {
            guard peer.polygon.count == 4 else { continue }
            let rect = bounds(peer.polygon.map(m.project))
            guard rect.width >= width * 0.65, rect.width <= width * 1.4,
                  abs(rect.midX - m.rect.midX) <= width * 0.22,
                  axisAgreement(peer.polygon, along: m.along),
                  rect.height >= width * 0.45 else { continue }
            let before = rect.midY < m.rect.midY
            let gap = before ? m.rect.minY - rect.maxY : rect.minY - m.rect.maxY
            // Overlapping/nested rectangles do not establish a missing-member join.
            guard gap >= 0, gap <= width * 1.6 else { continue }
            let gapTop = before ? rect.maxY : m.rect.maxY
            let gapBottom = before ? m.rect.minY : rect.minY
            let blocked = context.regions.contains { other in
                guard other.index != m.index, other.index != peer.index,
                      other.polygon.count == 4 else { return false }
                let r = bounds(other.polygon.map(m.project))
                let overlap = min(r.maxX, m.rect.maxX) - max(r.minX, m.rect.minX)
                guard r.minY < gapBottom, r.maxY > gapTop, overlap >= min(r.width, width) * 0.4 else { return false }
                guard let observed = context.measure(other.index, other.polygon), observed.status == "measured" else {
                    return true // An unresolved intervening source remains a keepout.
                }
                return observed.components.contains { component in
                    guard component.ownedPixels >= 2 || component.foreignPixels >= 2 else { return false }
                    let ink = bounds(component.hull.map(observed.restore).map(m.project))
                    return ink.minY < gapBottom && ink.maxY > gapTop && ink.maxX > m.rect.minX && ink.minX < m.rect.maxX
                }
            }
            guard !blocked else { continue }
            choices.append((peer, gap, before))
        }
        choices.sort { $0.1 == $1.1 ? $0.0.index < $1.0.index : $0.1 < $1.1 }
        var usedEnds = Set<Bool>()
        for (peer, _, before) in choices {
            guard !usedEnds.contains(before),
                  sharedScope(m.polygon, peer.polygon, frame: m, layout: layout),
                  let measured = context.measure(peer.index, peer.polygon),
                  let peerProof = observedSupport(measured, context: context),
                  currentProof.cells.isDisjoint(with: peerProof.cells),
                  separateGlyphSupport(m, measured, before: before),
                  compatibleInk(m, measured) else { continue }
            let points = protectedInk(m) + protectedInk(measured)
            guard !points.isEmpty else { continue }
            // Retain both complete input regions. No extrapolated endpoints.
            let rect = bounds((m.polygon + peer.polygon + points).map(m.project)).insetBy(dx: -0.5, dy: -0.5)
            let polygon = quad(rect).map(m.restore)
            guard valid(polygon), sharedScope(polygon, peer.polygon, frame: m, layout: layout),
                  corridorClear(polygon, inputs: [m.polygon, peer.polygon], context: context) else { continue }
            var consumed = [peer.index]
            for child in context.regions where child.index != m.index && child.index != peer.index {
                // Sharing owner IDs alone does not make an independent fragment a child.
                guard child.polygon.count == 4,
                      child.polygon.allSatisfy({ contains(peer.polygon, $0) && contains(polygon, $0) }),
                      let childMeasurement = context.measure(child.index, child.polygon),
                      let childProof = observedSupport(childMeasurement, context: context),
                      childProof.cells.isSubset(of: peerProof.cells),
                      protectedInk(childMeasurement).allSatisfy({ contains(polygon, $0) }) else { continue }
                consumed.append(child.index)
            }
            result.append(.init(key: "membership.observed-column-rf.gap1p6.offset0p22." + (before ? "head" : "tail"),
                                polygon: polygon, consumedIndices: Array(Set(consumed)).sorted(), supportPoints: points))
            usedEnds.insert(before)
            if usedEnds.count == 2 { break }
        }
        return result
    }

    static func members(_ index: Int, context: NativeOCRResidualSourceContext) -> Set<Int> {
        Set(context.groups[index] ?? [index])
    }

    struct Cell: Hashable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    struct Support {
        let cells: Set<Cell>
    }

    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        NativeOCRSourceComponentMeasurements.contains(polygon, point, tolerance: 0.01)
    }

    /// Authenticate the particular measured glyph support, not the source's whole
    /// ambiguous inventory. Independent pieces can share an owner/seed while
    /// occupying disjoint detector cells in the current image.
    static func observedSupport(_ m: Measurement, context: NativeOCRResidualSourceContext) -> Support? {
        let glyphs = m.components.filter { $0.ownedPixels >= 2 && $0.foreignPixels == 0 && $0.insidePixels >= 2 }
        guard m.status == "measured", !glyphs.isEmpty,
              m.guardPoints.count >= 4 || m.privateSamples >= 4 else { return nil }
        let requested = Set(m.associatedOwners + m.provisionalOwners)
        let independent = m.kind == "independent" || context.regions.contains { $0.index == m.index && $0.independent }
        guard !independent || !requested.isEmpty else { return nil }
        var evidence: [NativeOCRDetectorSeedEvidence] = []
        if !requested.isEmpty {
            evidence = context.originals.compactMap(\.detectorSeedEvidence).filter { requested.contains($0.ownerID) && $0.isValid }
            guard Set(evidence.map(\.ownerID)) == requested else { return nil }
        } else {
            evidence = members(m.index, context: context).compactMap { index in
                context.originals.indices.contains(index) ? context.originals[index].detectorSeedEvidence : nil
            }.filter(\.isValid)
        }
        guard !evidence.isEmpty else { return nil }
        let owners = Set(evidence.map(\.ownerID))
        let worldBounds = bounds(m.polygon)
        func matches(_ point: CGPoint) -> Bool {
            guard contains(m.polygon, point) else { return false }
            let local = m.project(point)
            return glyphs.contains { $0.hull.count >= 3 && $0.bounds.insetBy(dx: -0.5, dy: -0.5).contains(local) &&
                NativeOCRSourceComponentMeasurements.contains($0.hull, local, tolerance: 0.5) }
        }
        var budget = 120_000, cells = Set<Cell>()
        for e in evidence {
            // Only a parent-resolved measurement can use nondefinitive source cells.
            let resolved = requested.contains(e.ownerID)
            let components = e.components + (resolved ? (e.ambiguousComponents ?? []) +
                (e.candidateComponents ?? []).map(\.component) : [])
            for component in components {
                guard visit(component, evidence: e, within: worldBounds, budget: &budget, body: { point, cell in
                    if matches(point) { cells.insert(cell) }
                    return true
                }) else { return nil }
            }
            if !resolved {
                for component in e.ambiguousComponents ?? [] {
                    guard visit(component, evidence: e, within: worldBounds, budget: &budget,
                                body: { point, _ in !matches(point) }) else { return nil }
                }
                for candidate in e.candidateComponents ?? [] where !Set(candidate.competingOwnerIDs).isSubset(of: owners) {
                    guard visit(candidate.component, evidence: e, within: worldBounds, budget: &budget,
                                body: { point, _ in !matches(point) }) else { return nil }
                }
            }
        }
        guard cells.count >= 4 else { return nil }
        // Authentic private support cannot silently borrow any external original's
        // definitive cells, even if a provisional owner list was supplied.
        for e in context.originals.compactMap(\.detectorSeedEvidence) where !owners.contains(e.ownerID) && e.isValid {
            for component in e.components {
                guard visit(component, evidence: e, within: worldBounds, budget: &budget,
                            body: { point, _ in !matches(point) }) else { return nil }
            }
        }
        return Support(cells: cells)
    }

    /// Walk only actual detector cells inside the bounded source crop. Exhaustion
    /// abstains; a polygon-filled envelope never stands in for observed support.
    static func visit(_ component: NativeOCRDetectorSeedEvidence.Component, evidence: NativeOCRDetectorSeedEvidence,
                      within rect: CGRect, budget: inout Int, body: (CGPoint, Cell) -> Bool) -> Bool {
        let sx = CGFloat(evidence.sourceWidth) / CGFloat(evidence.mapFullWidth)
        let sy = CGFloat(evidence.sourceHeight) / CGFloat(evidence.mapFullHeight)
        for run in component.runs {
            let y = (CGFloat(run.y) + 0.5) * sy
            guard y >= rect.minY, y <= rect.maxY else { continue }
            let first = max(run.x, Int(ceil(rect.minX / sx - 0.5)))
            let end = min(run.x + run.count, Int(floor(rect.maxX / sx - 0.5)) + 1)
            guard first < end else { continue }
            for x in first..<end {
                budget -= 1
                guard budget >= 0,
                      body(.init(x: (CGFloat(x) + 0.5) * sx, y: y),
                           .init(x: x, y: run.y, width: evidence.mapFullWidth, height: evidence.mapFullHeight)) else { return false }
            }
        }
        return true
    }

    static func corridorClear(_ polygon: [CGPoint], inputs: [[CGPoint]], context: NativeOCRResidualSourceContext) -> Bool {
        var budget = 120_000
        for e in context.originals.compactMap(\.detectorSeedEvidence) where e.isValid {
            for component in e.components {
                guard visit(component, evidence: e, within: bounds(polygon), budget: &budget, body: { point, _ in
                    !contains(polygon, point) || inputs.contains { contains($0, point) }
                }) else { return false }
            }
        }
        return true
    }

    static func separateGlyphSupport(_ m: Measurement, _ peer: Measurement, before: Bool) -> Bool {
        func ink(_ measurement: Measurement) -> CGRect {
            bounds(measurement.components.filter { $0.ownedPixels >= 2 && $0.foreignPixels == 0 && $0.insidePixels >= 2 }
                .flatMap { $0.hull.map(measurement.restore).map(m.project) })
        }
        let first = ink(m), second = ink(peer)
        guard !first.isNull, !second.isNull else { return false }
        return before ? second.maxY <= first.minY : first.maxY <= second.minY
    }

    static func compatibleInk(_ a: Measurement, _ b: Measurement) -> Bool {
        let first = a.components.filter { $0.ownedPixels >= 2 && $0.foreignPixels == 0 }
        let second = b.components.filter { $0.ownedPixels >= 2 && $0.foreignPixels == 0 }
        guard !first.isEmpty, !second.isEmpty else { return false }
        func matched(_ components: [NativeOCRSourceComponentMeasurements.Component],
                     against other: [NativeOCRSourceComponentMeasurements.Component]) -> Bool {
            let total = components.reduce(0) { $0 + $1.ownedPixels }
            let matching = components.filter { c in
                other.contains { NativeOCRSourceComponentMeasurements.colourDistance(c.colour, $0.colour) <= 40 }
            }.reduce(0) { $0 + $1.ownedPixels }
            return matching >= max(4, total * 3 / 4)
        }
        return matched(first, against: second) && matched(second, against: first)
    }

    /// Unique high-confidence RF text proof must cover both complete quads and
    /// itself remain a single column. Any intersecting reliable balloon requires
    /// unique complete mask containment, including the intervening corridor.
    static func sharedScope(_ a: [CGPoint], _ b: [CGPoint], frame: Measurement,
                            layout: NativeRFDETRLayoutResult) -> Bool {
        let union = bounds(a + b)
        guard union.minX >= 0, union.minY >= 0,
              union.maxX <= CGFloat(layout.sourceWidth), union.maxY <= CGFloat(layout.sourceHeight) else { return false }
        let texts = layout.primitives.filter {
            $0.semanticClass == .text && $0.confidence >= 0.85 && $0.sourceBounds.contains(union)
        }
        guard texts.count == 1,
              bounds(quad(texts[0].sourceBounds).map(frame.project)).width <= frame.rect.width * 1.7 else { return false }
        let frames = layout.primitives.filter { $0.semanticClass == .frame && $0.confidence >= 0.9 }
        guard !frames.contains(where: { $0.sourceBounds.contains(bounds(a)) != $0.sourceBounds.contains(bounds(b)) }) else {
            return false
        }
        let balloons = layout.primitives.filter {
            $0.semanticClass == .balloon && $0.confidence >= 0.9 && $0.sourceBounds.intersects(union)
        }
        if balloons.isEmpty { return true }
        guard balloons.count == 1, let mask = balloons[0].mask,
              mask.sourceWidth == layout.sourceWidth, mask.sourceHeight == layout.sourceHeight else { return false }
        let left = Int(floor(union.minX)), top = Int(floor(union.minY))
        let right = Int(ceil(union.maxX)), bottom = Int(ceil(union.maxY))
        guard right > left, bottom > top, right - left <= 120_000 / (bottom - top) else { return false }
        for y in top..<bottom { for x in left..<right where !mask.contains(sourceX: x, sourceY: y) { return false } }
        return true
    }

    static func localFit(_ m: Measurement, useAxis: Bool) -> NativeOCRResidualCandidate? {
        let selected = m.components.filter { $0.ownedPixels >= 2 && $0.foreignPixels == 0 && $0.insidePixels >= 2 }
        guard selected.count >= 4 else { return nil }
        var slope: CGFloat = 0
        if useAxis {
            var bins: [Int: [CGPoint]] = [:]
            for c in selected {
                bins[Int(floor((c.center.y - m.rect.minY) / (m.rect.width * 0.5))), default: []].append(c.center)
            }
            let centers = bins.keys.sorted().compactMap { key -> CGPoint? in
                guard let values = bins[key] else { return nil }
                return .init(x: median(values.map(\.x)), y: median(values.map(\.y)))
            }
            guard centers.count >= 4 else { return nil }
            var slopes: [CGFloat] = []
            // Bounded robust fit: no quadratic growth on very tall source groups.
            let stride = max(1, centers.count / 32)
            let sampled = centers.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
            for i in sampled.indices { for j in sampled.indices where j > i {
                let dy = sampled[j].y - sampled[i].y
                if dy >= m.rect.height * 0.25 { slopes.append((sampled[j].x - sampled[i].x) / dy) }
            }}
            guard !slopes.isEmpty else { return nil }
            slope = median(slopes)
            guard abs(slope) <= tan(CGFloat.pi / 45), abs(slope) >= 0.001 else { return nil }
            let intercept = median(centers.map { $0.x - slope * $0.y })
            guard median(centers.map { abs($0.x - slope * $0.y - intercept) }) <= m.rect.width * 0.12 else { return nil }
        }
        let support = protectedInk(m)
        guard !support.isEmpty else { return nil }
        let angle = atan(slope), c = cos(angle), s = sin(angle)
        func rotate(_ p: CGPoint) -> CGPoint { .init(x: p.x * c - p.y * s, y: p.x * s + p.y * c) }
        let rect = bounds(support.map(m.project).map(rotate)).insetBy(dx: -max(1, m.step), dy: -max(1, m.step))
        guard rect.height >= m.rect.height * 0.65, rect.width <= m.rect.width * 1.5 else { return nil }
        let polygon = quad(rect).map { p in m.restore(.init(x: p.x * c + p.y * s, y: -p.x * s + p.y * c)) }
        guard valid(polygon), support.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 0.75) }) else {
            return nil
        }
        return .init(key: useAxis ? "membership.group-axis.theilsen4deg.pad1" : "membership.group-envelope.owned.pad1",
                     polygon: polygon, supportPoints: support)
    }

    static func protectedInk(_ m: Measurement) -> [CGPoint] {
        m.guardPoints + m.privateHull.map(m.restore) +
            NativeOCRSourceComponentBounds.visibleForeground(m) +
            m.components.filter { $0.ownedPixels >= 2 && $0.foreignPixels == 0 }.flatMap { $0.hull.map(m.restore) }
    }

    static func axisAgreement(_ polygon: [CGPoint], along: CGPoint) -> Bool {
        guard polygon.count == 4 else { return false }
        let edges = [CGPoint(x: polygon[1].x - polygon[0].x, y: polygon[1].y - polygon[0].y),
                     CGPoint(x: polygon[3].x - polygon[0].x, y: polygon[3].y - polygon[0].y)]
        let edge = edges.max { hypot($0.x, $0.y) < hypot($1.x, $1.y) }!
        let length = hypot(edge.x, edge.y)
        return length > 0 && abs(edge.x * along.x + edge.y * along.y) / length >= cos(CGFloat.pi / 36)
    }

    static func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
    static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            CGRect(x: min(rect.minX, point.x), y: min(rect.minY, point.y),
                   width: max(rect.maxX, point.x) - min(rect.minX, point.x),
                   height: max(rect.maxY, point.y) - min(rect.minY, point.y))
        }
    }
    static func quad(_ r: CGRect) -> [CGPoint] {
        [.init(x: r.minX, y: r.minY), .init(x: r.maxX, y: r.minY),
         .init(x: r.maxX, y: r.maxY), .init(x: r.minX, y: r.maxY)]
    }
    static func valid(_ polygon: [CGPoint]) -> Bool {
        polygon.count == 4 && polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 }
    }
}
