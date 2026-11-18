import CoreGraphics
import Foundation

/// Optional source-only alternatives. Actual terminal caps must be supplied after
/// the bank computes them; no GT, peer consumption, sampling or global state.
@available(iOS 18.0, *)
enum NativeOCRResidualSupportMinimumRectangle {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement

    struct Assessment {
        let candidates: [NativeOCRResidualCandidate]
        let features: [Double]
    }

    /// Append after the existing sixteen bank features, in this order. Positive
    /// clearance means empty margin; negative means support beyond the input.
    /// All four clearances use the incoming normal width, including head/tail.
    static let featureNames = [
        "supportLeftClearanceWidths", "supportRightClearanceWidths",
        "supportHeadClearanceWidths", "supportTailClearanceWidths",
        "supportMinimumRectangleAngleDegrees", "supportMinimumRectangleAreaRatio"
    ]
    static let fallbackFeatures: [Double] = [0, 0, 0, 0, 0, 1]

    static func candidates(_ m: Measurement, caps: [CGPoint]) -> [NativeOCRResidualCandidate] {
        assess(m, caps: caps).candidates
    }

    static func features(_ m: Measurement, caps: [CGPoint]) -> [Double] {
        assess(m, caps: caps).features
    }

    /// Use this once when both candidates and features are needed. The support
    /// hull, constrained orientation search and complete envelope are shared.
    static func assess(_ m: Measurement, caps: [CGPoint]) -> Assessment {
        let empty = Assessment(candidates: [], features: fallbackFeatures)
        let area = m.rect.width * m.rect.height
        guard m.polygon.count == 4, m.polygon.allSatisfy(finite), finite(m.origin),
              finite(m.normal), finite(m.along), m.rect.width > 0, m.rect.height > 0,
              m.rect.minX.isFinite, m.rect.minY.isFinite, m.rect.maxX.isFinite, m.rect.maxY.isFinite,
              area.isFinite, area > 0,
              abs(hypot(m.normal.x, m.normal.y) - 1) <= 1e-6,
              abs(hypot(m.along.x, m.along.y) - 1) <= 1e-6,
              abs(m.normal.x * m.along.x + m.normal.y * m.along.y) <= 1e-6 else { return empty }
        let points = m.guardPoints + NativeOCRSourceComponentBounds.visibleForeground(m) + caps
        guard points.count >= 3, points.allSatisfy(finite) else { return empty }
        let projected = points.map(m.project), incoming = m.polygon.map(m.project)
        guard projected.allSatisfy(finite), incoming.allSatisfy(finite) else { return empty }
        let local = NativeOCRSourceComponentMeasurements.convexHull(projected)
        let hullArea = polygonArea(local)
        guard local.count >= 3, hullArea.isFinite, hullArea > 1e-9 else { return empty }
        let limit = CGFloat.pi * 8 / 180
        var angles: [CGFloat] = [-limit, 0, limit]
        for i in local.indices {
            let a = local[i], b = local[(i + 1) % local.count]
            let dx = b.x - a.x, dy = b.y - a.y
            guard hypot(dx, dy) > 1e-9 else { continue }
            // A hull edge may align with either rectangle edge. Wrap by a quarter
            // turn in the local frame, independently of its world orientation.
            var angle = (atan2(dx, dy) + .pi / 4).truncatingRemainder(dividingBy: .pi / 2)
            if angle < 0 { angle += .pi / 2 }
            angle -= .pi / 4
            guard abs(angle) <= limit + 1e-12 else { continue }
            angle = max(-limit, min(limit, angle))
            if !angles.contains(where: { abs($0 - angle) <= 1e-12 }) { angles.append(angle) }
        }
        // On each interval between hull-edge events, the active extrema are
        // fixed: width-height is A*cos(angle)+B*sin(angle). The long-side
        // feasibility boundary can therefore have one interior zero here.
        // Include it: a constrained minimum need not occur at a hull edge.
        let events = angles.sorted()
        for i in 0..<(events.count - 1) {
            var low = events[i], high = events[i + 1]
            var lowDifference = aspectDifference(local, angle: low)
            let highDifference = aspectDifference(local, angle: high)
            guard lowDifference.isFinite, highDifference.isFinite,
                  lowDifference != 0, highDifference != 0,
                  (lowDifference > 0) != (highDifference > 0) else { continue }
            for _ in 0..<60 {
                let middle = low + (high - low) / 2
                if middle == low || middle == high { break }
                let difference = aspectDifference(local, angle: middle)
                if difference == 0 { low = middle; high = middle; break }
                if (difference > 0) == (lowDifference > 0) {
                    low = middle; lowDifference = difference
                } else {
                    high = middle
                }
            }
            let root = low + (high - low) / 2
            if !angles.contains(root) { angles.append(root) }
        }
        var best: (angle: CGFloat, rect: CGRect)?
        for angle in angles {
            let rect = NativeOCRSourceComponentBounds.bounds(local.map { rotate($0, angle: angle) })
            guard valid(rect), rect.height + 1e-9 >= rect.width else { continue }
            if let old = best {
                let candidateArea = rect.width * rect.height, oldArea = old.rect.width * old.rect.height
                if candidateArea > oldArea { continue }
                if candidateArea == oldArea {
                    if abs(angle) > abs(old.angle) { continue }
                    if abs(angle) == abs(old.angle), angle >= old.angle { continue }
                }
            }
            best = (angle, rect)
        }
        guard let best else { return empty }
        let supportBounds = NativeOCRSourceComponentBounds.bounds(local)
        let values = [
            (supportBounds.minX - m.rect.minX) / m.rect.width,
            (m.rect.maxX - supportBounds.maxX) / m.rect.width,
            (supportBounds.minY - m.rect.minY) / m.rect.width,
            (m.rect.maxY - supportBounds.maxY) / m.rect.width,
            best.angle * 180 / .pi, best.rect.width * best.rect.height / area
        ].map(Double.init)
        guard values.allSatisfy(\.isFinite) else { return empty }
        let support = local.map(m.restore)
        var result: [NativeOCRResidualCandidate] = []
        // Keep both families, including when their geometry coincides. Their keys
        // are stable across sources and match the metadata capacity audit.
        for (family, angle) in [("bounded-mar", best.angle), ("incoming-axis-control", CGFloat(0))] {
            let rotated = local.map { rotate($0, angle: angle) }
            let rect = NativeOCRSourceComponentBounds.bounds(rotated)
            let original = NativeOCRSourceComponentBounds.bounds(incoming.map { rotate($0, angle: angle) })
            for retain in [false, true] {
                let top = retain ? min(rect.minY, original.minY) : rect.minY
                let bottom = retain ? max(rect.maxY, original.maxY) : rect.maxY
                for (name, pad) in [("0", CGFloat(0)), ("05", CGFloat(0.5)), ("1", CGFloat(1))] {
                    let bounds = CGRect(x: rect.minX - pad, y: top - pad,
                        width: rect.width + 2 * pad, height: bottom - top + 2 * pad)
                    guard valid(bounds), bounds.height + 1e-9 >= bounds.width,
                          bounds.width * bounds.height > 2 else { continue }
                    let polygon = corners(bounds).map { m.restore(rotate($0, angle: -angle)) }
                    guard polygon.allSatisfy({ finite($0) && $0.x >= 0 && $0.y >= 0 }),
                          support.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 1e-6) }) else {
                        continue
                    }
                    let span = retain ? "retain-span" : "tight"
                    result.append(.init(key: "support-minrect-v1-\(family)-\(span)-p\(name)",
                        polygon: polygon, supportPoints: support))
                }
            }
        }
        return .init(candidates: result, features: values)
    }

    /// Add only support-complete blends rejected by the legacy whole-parent
    /// corner gate. Call with already accepted native base parents, after the
    /// original sixteen features are finalized; the downstream gate is unchanged.
    static func supportBlends(_ m: Measurement, caps: [CGPoint], parents: [NativeOCRResidualCandidate])
        -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", validBlendQuad(m.polygon) else { return [] }
        let mandatory = m.guardPoints + NativeOCRSourceComponentBounds.visibleForeground(m) + caps
        guard mandatory.allSatisfy(finite) else { return [] }
        let baseHull = NativeOCRSourceComponentMeasurements.convexHull(mandatory)
        // Ambiguous duplicate keys must not silently select a parent that lacks
        // another parent's fresh support. Native collection normally deduplicates.
        var counts: [String: Int] = [:]
        for parent in parents { counts[parent.key, default: 0] += 1 }
        var result: [NativeOCRResidualCandidate] = []
        for parent in parents {
            guard counts[parent.key] == 1, blendParentAllowed(parent.key), parent.consumedIndices.isEmpty,
                  validBlendQuad(parent.polygon), parent.supportPoints.allSatisfy(finite) else { continue }
            let hull = NativeOCRSourceComponentMeasurements.convexHull(baseHull + parent.supportPoints)
            let area = polygonArea(hull)
            guard hull.count >= 3, area.isFinite, area > 1e-9 else { continue }
            for (suffix, fraction) in [("25", CGFloat(0.25)), ("50", CGFloat(0.5)), ("75", CGFloat(0.75))] {
                let polygon = NativeOCRSourceComponentBounds.interpolate(m.polygon, proposal: parent.polygon, fraction: fraction)
                guard validBlendQuad(polygon),
                      !parent.polygon.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 1e-7) }),
                      hull.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 1e-3) }) else {
                    continue
                }
                let key = "support-blend-v1-\(parent.key)-f\(suffix)"
                guard key.utf8.count < 160 else { continue }
                result.append(.init(key: key, polygon: polygon, supportPoints: hull))
            }
        }
        return result
    }

    private static func blendParentAllowed(_ key: String) -> Bool {
        let allowed = key.hasPrefix("side-envelope-v1-") || key.hasPrefix("normal.owned-shell") ||
            key.hasPrefix("normal-complete-v1-") || key.hasPrefix("axis-bins-")
        // Conservative literal exclusion also covers head/tail side submodes.
        return allowed && !key.contains("|") && !key.contains(" >> ") &&
            !key.contains("terminal") && !key.contains("head") && !key.contains("tail") &&
            !key.contains("trim") && !key.contains("membership") && !key.contains("footprint")
    }

    private static func validBlendQuad(_ points: [CGPoint]) -> Bool {
        guard points.count == 4, points.allSatisfy({ finite($0) && $0.x >= 0 && $0.y >= 0 }),
              polygonArea(points).isFinite, polygonArea(points) > 2 else { return false }
        let turns = points.indices.map { i -> CGFloat in
            let a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        return turns.allSatisfy({ $0 > 1e-9 }) || turns.allSatisfy({ $0 < -1e-9 })
    }

    private static func aspectDifference(_ points: [CGPoint], angle: CGFloat) -> CGFloat {
        let r = NativeOCRSourceComponentBounds.bounds(points.map { rotate($0, angle: angle) })
        return r.width - r.height
    }

    private static func finite(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite }

    private static func valid(_ r: CGRect) -> Bool {
        r.minX.isFinite && r.minY.isFinite && r.maxX.isFinite && r.maxY.isFinite &&
            r.width >= 0 && r.height >= 0 && (r.width * r.height).isFinite
    }

    private static func rotate(_ p: CGPoint, angle: CGFloat) -> CGPoint {
        .init(x: p.x * cos(angle) - p.y * sin(angle), y: p.x * sin(angle) + p.y * cos(angle))
    }

    private static func corners(_ r: CGRect) -> [CGPoint] {
        [.init(x: r.minX, y: r.minY), .init(x: r.maxX, y: r.minY),
         .init(x: r.maxX, y: r.maxY), .init(x: r.minX, y: r.maxY)]
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        abs(points.indices.reduce(CGFloat(0)) { sum, i in
            let a = points[i], b = points[(i + 1) % points.count]
            return sum + a.x * b.y - b.x * a.y
        }) / 2
    }
}
