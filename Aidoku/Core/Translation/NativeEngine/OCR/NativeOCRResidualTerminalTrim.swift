import CoreGraphics
import Foundation

/// Inward, one-ended alternatives only. The caller retains the unchanged source
/// and applies its baseline/terminal-proof acceptance guards to these proposals.
@available(iOS 18.0, *)
enum NativeOCRResidualTerminalTrim {
    static func candidates(_ m: NativeOCRSourceComponentMeasurements.Measurement) -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", m.polygon.count == 4, m.step.isFinite, m.step > 0,
              m.rect.width.isFinite, m.rect.height.isFinite, m.rect.width >= 5,
              m.rect.height >= m.rect.width * 2, m.privateSamples >= 4,
              !m.privateHull.isEmpty, !m.guardPoints.isEmpty else { return [] }
        let primary = m.components.filter { component in
            normalOverlap(component.bounds, m.rect) && component.insidePixels >= 2 &&
                Double(component.ownedPixels) >= max(2, min(8, Double(component.pixels) * 0.04)) &&
                !component.hull.isEmpty
        }
        guard !primary.isEmpty else { return [] }
        // Do not rank terminal components by area or occupancy. A small unowned
        // dot or white outline is still protected when it matches owned ink.
        let visible = m.components.filter { component in
            guard component.insidePixels > 0, !component.hull.isEmpty,
                  normalOverlap(component.bounds, m.rect) else { return false }
            return component.ownedPixels > 0 || (component.foreignPixels == 0 && primary.contains {
                NativeOCRSourceComponentMeasurements.colourDistance(component.colour, $0.colour) <= 40
            })
        }
        var lower = CGFloat.greatestFiniteMagnitude, upper = -CGFloat.greatestFiniteMagnitude
        for component in visible {
            lower = min(lower, max(m.rect.minY, component.bounds.minY))
            upper = max(upper, min(m.rect.maxY, component.bounds.maxY))
        }
        var support = m.guardPoints
        support += m.privateHull.map(m.restore)
        support += visible.flatMap { $0.hull.map(m.restore) }.filter {
            NativeOCRSourceComponentMeasurements.contains(m.polygon, $0)
        }
        guard support.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        // Candidates are convex, so the support hull protects the same points
        // without attaching every original DB cell to every alternative.
        support = NativeOCRSourceComponentMeasurements.convexHull(support)
        for point in support.map(m.project) {
            lower = min(lower, point.y); upper = max(upper, point.y)
        }
        guard lower.isFinite, upper.isFinite,
              upper - lower >= max(m.rect.width * 0.5, m.rect.height * 0.35) else { return [] }
        let local = m.polygon.map(m.project)
        guard local.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        let order = local.indices.sorted { local[$0].y == local[$1].y ? $0 < $1 : local[$0].y < local[$1].y }
        let head = Array(order.prefix(2)), tail = Array(order.suffix(2))
        // The movable vertices must form an actual end edge, not a diagonal.
        guard (head[0] + 1) % 4 == head[1] || (head[1] + 1) % 4 == head[0] else { return [] }
        var result: [NativeOCRResidualCandidate] = []
        for (label, fraction): (String, CGFloat) in [("04", 0.04), ("10", 0.10)] {
            let padding = max(1.5 * m.step, fraction * m.rect.width)
            let minimumTrim = max(2 * m.step, 0.10 * m.rect.width)
            for isHead in [true, false] {
                let edge = isHead ? head : tail
                let current = isHead ? edge.map { local[$0].y }.max()! : edge.map { local[$0].y }.min()!
                let target = isHead ? lower - padding : upper + padding
                let delta = target - current
                guard isHead ? delta >= minimumTrim : delta <= -minimumTrim else { continue }
                var polygon = m.polygon
                for index in edge {
                    // Translate only the selected edge along the measured axis.
                    // Opposite world vertices remain bit-for-bit unchanged.
                    polygon[index] = .init(x: polygon[index].x + delta * m.along.x,
                                           y: polygon[index].y + delta * m.along.y)
                }
                guard valid(polygon), polygon.allSatisfy({
                    $0.x >= 0 && $0.y >= 0 && NativeOCRSourceComponentMeasurements.contains(m.polygon, $0, tolerance: 1e-6)
                }), support.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(polygon, $0) }) else { continue }
                result.append(.init(key: "terminal-trim-v1|\(isHead ? "head" : "tail")|pad\(label)",
                                    polygon: polygon, supportPoints: support))
            }
        }
        return result
    }

    private static func normalOverlap(_ component: CGRect, _ source: CGRect) -> Bool {
        let overlap = max(0, min(component.maxX, source.maxX) - max(component.minX, source.minX))
        return component.width > 0 && overlap >= min(component.width, source.width) * 0.4
    }

    private static func valid(_ polygon: [CGPoint]) -> Bool {
        guard polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        var sign: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % 4], c = polygon[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard abs(cross) > 1e-7 else { return false }
            if sign == 0 { sign = cross }
            if sign * cross <= 0 { return false }
        }
        return true
    }
}
