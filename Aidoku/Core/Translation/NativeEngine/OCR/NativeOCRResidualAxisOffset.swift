import CoreGraphics
import Foundation

/// Reconcile the incoming frame with equally weighted longitudinal glyph bins.
/// Original-cell and terminal certification remains the caller's responsibility.
@available(iOS 18.0, *)
enum NativeOCRResidualAxisOffset {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement

    static func candidates(_ m: Measurement) -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", m.rect.width >= 5, m.rect.height >= m.rect.width * 2,
              m.normal.x.isFinite, m.along.y.isFinite else { return [] }
        let width = m.rect.width
        let primary = m.components.filter { c in
            let overlap = max(0, min(c.bounds.maxX, m.rect.maxX) - max(c.bounds.minX, m.rect.minX))
            return c.foreignPixels == 0 && c.insidePixels >= 2 && !c.hull.isEmpty &&
                CGFloat(c.ownedPixels) >= max(2, min(8, CGFloat(c.pixels) * 0.04)) &&
                overlap >= min(c.bounds.width, width) * 0.4
        }
        guard !primary.isEmpty else { return [] }
        // Keep disconnected dots and matching outlines as support, not as extra
        // centerline votes. Radical count and palette duplication must not weight a glyph.
        let visible = m.components.filter { c in
            guard c.foreignPixels == 0, c.insidePixels >= 2, !c.hull.isEmpty,
                  c.bounds.minY >= m.rect.minY - width * 0.5,
                  c.bounds.maxY <= m.rect.maxY + width * 0.5 else { return false }
            let overlap = max(0, min(c.bounds.maxX, m.rect.maxX) - max(c.bounds.minX, m.rect.minX))
            return overlap >= min(c.bounds.width, width) * 0.4 && primary.contains {
                NativeOCRSourceComponentMeasurements.colourDistance(c.colour, $0.colour) <= 40
            }
        }
        let points = primary.flatMap(\.hull) + visible.flatMap(\.hull) + m.privateHull + m.guardPoints.map(m.project)
        guard points.count >= 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        let binSize = max(width * 0.75, m.rect.height / 48)
        var bins: [Int: CGRect] = [:]
        for c in primary where c.bounds.height <= width * 2.5 {
            let position = (c.center.y - m.rect.minY) / binSize
            guard position.isFinite, abs(position) < 100_000 else { continue }
            let key = Int(floor(position))
            bins[key] = bins[key].map { $0.union(c.bounds) } ?? c.bounds
        }
        let centers = bins.keys.sorted().compactMap { bins[$0] }.map { CGPoint(x: $0.midX, y: $0.midY) }
        guard centers.count >= 3, let first = centers.map(\.y).min(), let last = centers.map(\.y).max(),
              last - first >= max(width * 2, m.rect.height * 0.4) else { return [] }
        var slopes: [CGFloat] = []
        for i in centers.indices {
            for j in centers.indices where j > i {
                let delta = centers[j].y - centers[i].y
                if delta >= (last - first) * 0.3 { slopes.append((centers[j].x - centers[i].x) / delta) }
            }
        }
        guard !slopes.isEmpty else { return [] }
        let slope = median(slopes)
        let angle = atan(slope)
        guard angle.isFinite, abs(angle) <= 8 * .pi / 180 else { return [] }
        let intercept = median(centers.map { $0.x - slope * $0.y })
        let residual = median(centers.map { abs($0.x - slope * $0.y - intercept) })
        guard residual <= width * 0.2 else { return [] }
        let margin = max(m.step, min(2, width * 0.04))
        let worldSupport = points.map(m.restore)
        var result: [NativeOCRResidualCandidate] = []
        if abs(angle) >= 0.25 * .pi / 180 {
            for fraction: CGFloat in [1, 0.5] {
                let beta = angle * fraction
                let cosine = cos(beta), sine = sin(beta)
                let rotated = points.map { CGPoint(x: $0.x * cosine - $0.y * sine,
                                                    y: $0.x * sine + $0.y * cosine) }
                let rect = bounds(rotated).insetBy(dx: -margin, dy: -margin)
                let polygon = corners(rect).map { p in
                    m.restore(.init(x: p.x * cosine + p.y * sine, y: -p.x * sine + p.y * cosine))
                }
                if valid(polygon) {
                    result.append(.init(key: fraction == 1 ? "axis-bins-envelope-v1-full" : "axis-bins-envelope-v1-half",
                                        polygon: polygon, supportPoints: worldSupport))
                }
            }
        }
        // Translation retains at least the original width and along endpoints.
        // Expand if necessary rather than clipping a broad glyph to the fitted center.
        let center = intercept + slope * m.rect.midY
        let shift = center - m.rect.midX
        if abs(shift) >= max(0.5 * m.step, width * 0.025), abs(shift) <= width * 0.3 {
            let support = bounds(points)
            let radius = max(width * 0.5, center - support.minX + margin, support.maxX - center + margin)
            let rect = CGRect(x: center - radius, y: min(m.rect.minY, support.minY - margin),
                              width: radius * 2,
                              height: max(m.rect.maxY, support.maxY + margin) - min(m.rect.minY, support.minY - margin))
            let polygon = corners(rect).map(m.restore)
            if valid(polygon) {
                result.append(.init(key: "axis-bins-center-v1-retain-span", polygon: polygon, supportPoints: worldSupport))
            }
        }
        return result
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) * 0.5 : sorted[middle]
    }

    private static func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return .init(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private static func corners(_ rect: CGRect) -> [CGPoint] {
        [.init(x: rect.minX, y: rect.minY), .init(x: rect.maxX, y: rect.minY),
         .init(x: rect.maxX, y: rect.maxY), .init(x: rect.minX, y: rect.maxY)]
    }

    private static func valid(_ polygon: [CGPoint]) -> Bool {
        polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 }
    }
}
