import CoreGraphics
import Foundation

/// Temporary sampling views only: never replace original ownership or erasure evidence.
@available(iOS 18.0, *)
enum NativeOCRResidualEvidence {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement

    static func candidates(_ m: Measurement, context: NativeOCRResidualSourceContext) -> [NativeOCRResidualCandidate] {
        guard context.prepared.indices.contains(m.index),
              !context.regions.contains(where: { $0.index == m.index && $0.independent }) else { return [] }
        return candidates(m)
    }

    /// Two existing contour fits, only after the parent has verified provisional RGB support.
    /// The caller retains its unchanged incumbent as a separate no-op alternative.
    static func candidates(_ m: Measurement) -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", m.kind == "detector" || m.kind == "group",
              !m.provisionalOwners.isEmpty, m.privateSamples >= 4,
              m.components.contains(where: { $0.ownedPixels >= 2 && $0.foreignPixels == 0 }) else { return [] }
        let support = m.guardPoints + m.privateHull.map(m.restore) + NativeOCRSourceComponentBounds.visibleForeground(m)
        guard !support.isEmpty else { return [] }
        var result: [NativeOCRResidualCandidate] = []
        for axis in 0...1 {
            guard let proposal = NativeOCRSourceComponentBounds.proposal(m, gap: 0, axis: CGFloat(axis), padding: 2),
                  support.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(proposal.0, $0, tolerance: 0.75) }),
                  !result.contains(where: { previous in
                      zip(previous.polygon, proposal.0).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1e-6 }
                  }) else { continue }
            result.append(.init(key: "evidence-verified-contour-a\(axis)-gap0-pad2", polygon: proposal.0,
                                supportPoints: support))
        }
        return result
    }

    /// Retain complete measured CCs that have member-local support and no external owner.
    /// No cells, probabilities, seeds, or original inventory entries are synthesized.
    static func sourceEvidence(index: Int, polygon: [CGPoint], originals: [NativeCoreMLDetectionBox],
                               prepared: [NativeCoreMLDetectionBox], groups: [Int: [Int]]) -> [NativeOCRDetectorSeedEvidence] {
        guard prepared.indices.contains(index), validPolygon(polygon), originals.count <= 4096 else { return [] }
        let members = groups[index] ?? [index]
        guard !members.isEmpty, members.count <= 64, Set(members).count == members.count,
              members.allSatisfy({ originals.indices.contains($0) }) else { return [] }
        let memberSet = Set(members)
        let sources = members.compactMap { originals[$0].detectorSeedEvidence }
        guard sources.count == members.count, let first = sources.first,
              sources.allSatisfy({ $0.isValid && $0.ownershipVersion == 2 && $0.completeCCScan == true &&
                  $0.mapFullWidth == first.mapFullWidth && $0.mapFullHeight == first.mapFullHeight &&
                  $0.mapOriginX == first.mapOriginX && $0.mapOriginY == first.mapOriginY &&
                  $0.sourceWidth == first.sourceWidth && $0.sourceHeight == first.sourceHeight }) else { return [] }
        let ownerIDs = Set(sources.map(\.ownerID))
        guard ownerIDs.count == sources.count,
              members.allSatisfy({ validPolygon(originals[$0].polygon) }) else { return [] }
        // An external owner is never made internal by polygon proximity or a group envelope.
        var foreign: [(polygon: [CGPoint], bounds: CGRect)] = []
        var foreignSeeds = Set<Int>()
        for i in originals.indices where !memberSet.contains(i) {
            let box = originals[i]
            guard validPolygon(box.polygon) else { return [] }
            foreign.append((box.polygon, bounds(box.polygon)))
            if let e = box.detectorSeedEvidence {
                guard !ownerIDs.contains(e.ownerID) else { return [] }
                if e.isValid, e.mapFullWidth == first.mapFullWidth, e.mapFullHeight == first.mapFullHeight,
                   e.sourceWidth == first.sourceWidth, e.sourceHeight == first.sourceHeight {
                    // Exclusive CCs, and uniquely contained candidates, have an external claimant.
                    foreignSeeds.formUnion(e.components.map(\.seed))
                    foreignSeeds.formUnion((e.candidateComponents ?? []).map { $0.component.seed })
                }
            }
        }
        let memberPolygons = members.map { originals[$0].polygon }
        let memberBounds = memberPolygons.map(bounds)
        let queryBounds = bounds(polygon)
        let roi = queryBounds.insetBy(dx: -queryBounds.width * 0.15, dy: -queryBounds.height * 0.15)
        let sx = CGFloat(first.sourceWidth) / CGFloat(first.mapFullWidth)
        let sy = CGFloat(first.sourceHeight) / CGFloat(first.mapFullHeight)
        var checkedCells = 0, pointChecks = 0
        var cache: [Int: Bool] = [:]
        var seen: [Int: NativeOCRDetectorSeedEvidence.Component] = [:]
        var contradictory = false
        var budgetExceeded = false
        func supported(_ component: NativeOCRDetectorSeedEvidence.Component) -> Bool {
            if let prior = seen[component.seed], prior != component { contradictory = true; return false }
            seen[component.seed] = component
            if let answer = cache[component.seed] { return answer }
            cache[component.seed] = false
            guard !foreignSeeds.contains(component.seed) else { return false }
            let points = component.runs.flatMap { run in
                [CGPoint(x: (CGFloat(run.x) + 0.5) * sx, y: (CGFloat(run.y) + 0.5) * sy),
                 CGPoint(x: (CGFloat(run.x + run.count) - 0.5) * sx, y: (CGFloat(run.y) + 0.5) * sy)]
            }
            let extent = bounds(points)
            guard overlaps(extent, roi) else { return false }
            let nearbyForeign = foreign.filter { overlaps($0.bounds, extent) }
            var touchesROI = false
            for run in component.runs {
                for x in run.x..<(run.x + run.count) {
                    checkedCells += 1
                    guard checkedCells <= 262_144 else { budgetExceeded = true; return false }
                    let point = CGPoint(x: (CGFloat(x) + 0.5) * sx, y: (CGFloat(run.y) + 0.5) * sy)
                    touchesROI = touchesROI || contains(roi, point)
                    var member = false
                    for j in memberPolygons.indices where contains(memberBounds[j], point) {
                        pointChecks += 1
                        guard pointChecks <= 1_048_576 else { budgetExceeded = true; return false }
                        if contains(memberPolygons[j], point) { member = true; break }
                    }
                    guard member else { return false }
                    for peer in nearbyForeign where contains(peer.bounds, point) {
                        pointChecks += 1
                        guard pointChecks <= 1_048_576 else { budgetExceeded = true; return false }
                        if contains(peer.polygon, point) { return false }
                    }
                }
            }
            cache[component.seed] = touchesROI
            return touchesROI
        }
        var result: [NativeOCRDetectorSeedEvidence] = []
        for source in sources {
            var selected = source.components.filter(supported)
            let promotedAmbiguous = (source.ambiguousComponents ?? []).filter(supported)
            // Outside-cell ratios are not ownership permission. Every competitor must be
            // an original member, and the actual cells must still pass external exclusion.
            let promotedCandidates = (source.candidateComponents ?? []).filter {
                $0.competingOwnerIDs.allSatisfy(ownerIDs.contains) && supported($0.component)
            }
            selected += promotedAmbiguous + promotedCandidates.map(\.component)
            guard !selected.isEmpty else { continue }
            let selectedSeeds = Set(selected.map(\.seed))
            let view = NativeOCRDetectorSeedEvidence(ownerID: source.ownerID, parentBoxIndex: source.parentBoxIndex,
                provenance: source.provenance, threshold: source.threshold, mapOriginX: source.mapOriginX,
                mapOriginY: source.mapOriginY, mapFullWidth: source.mapFullWidth, mapFullHeight: source.mapFullHeight,
                sourceWidth: source.sourceWidth, sourceHeight: source.sourceHeight, components: selected,
                sourceProbabilityROI: source.sourceProbabilityROI, ownershipVersion: source.ownershipVersion,
                completeCCScan: source.completeCCScan,
                ambiguousComponents: (source.ambiguousComponents ?? []).filter { !selectedSeeds.contains($0.seed) },
                candidateComponents: (source.candidateComponents ?? []).filter { !selectedSeeds.contains($0.component.seed) })
            guard view.isValid else { return [] }
            result.append(view)
        }
        guard !contradictory, !budgetExceeded else { return [] }
        return result
    }

    private static func validPolygon(_ polygon: [CGPoint]) -> Bool {
        guard (3...32).contains(polygon.count), polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let area = polygon.indices.reduce(CGFloat(0)) { total, i in
            let next = polygon[(i + 1) % polygon.count]
            return total + polygon[i].x * next.y - next.x * polygon[i].y
        }
        return area.isFinite && abs(area) > 1e-6
    }

    private static func bounds(_ points: [CGPoint]) -> CGRect {
        CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
               width: points.map(\.x).max()! - points.map(\.x).min()!,
               height: points.map(\.y).max()! - points.map(\.y).min()!)
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }

    private static func contains(_ rect: CGRect, _ p: CGPoint) -> Bool {
        p.x >= rect.minX && p.x <= rect.maxX && p.y >= rect.minY && p.y <= rect.maxY
    }

    private static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[previous], b = polygon[i]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if abs(cross) <= 1e-8, p.x >= min(a.x, b.x), p.x <= max(a.x, b.x),
               p.y >= min(a.y, b.y), p.y <= max(a.y, b.y) { return true }
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = i
        }
        return inside
    }
}
