import CoreGraphics
import Foundation

/// Optional source-only alternatives. Caller retains unchanged global safe/semantic admission.
@available(iOS 18.0, *)
enum NativeOCRResidualAsymmetricSupport {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement

    static func candidates(_ m: Measurement, caps: [CGPoint], allowedKeys: Set<String>? = nil) -> [NativeOCRResidualCandidate] {
        if let allowedKeys, allowedKeys.isEmpty { return [] }
        guard m.status == "measured", m.rect.width.isFinite, m.rect.width > 0 else { return [] }
        let points = m.guardPoints + NativeOCRSourceComponentBounds.visibleForeground(m) + caps
        guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        let support = NativeOCRSourceComponentMeasurements.convexHull(points)
        let local = support.map(m.project)
        guard local.count >= 3 else { return [] }
        let b = NativeOCRSourceComponentBounds.bounds(local)
        guard b.width > 1e-9, b.height > 1e-9 else { return [] }
        let w = m.rect.width
        var parameters: [[CGFloat]] = []
        let alongPairs: [[CGFloat]] = [[0, 0.1], [0.1, 0], [0, 0.25], [0.25, 0], [0, 0.5], [0.5, 0],
                                      [0.1, 0.4], [0.4, 0.1], [0.25, 0.5], [0.5, 0.25], [0.5, 0.5]]
        for n: CGFloat in [0, 0.1, 0.25] {
            for pair in alongPairs { parameters.append([n, n, pair[0], pair[1]]) }
        }
        let normalPairs: [[CGFloat]] = [[0, 0.1], [0.1, 0], [0, 0.25], [0.25, 0], [0, 0.5], [0.5, 0], [0.1, 0.4], [0.4, 0.1]]
        for pair in normalPairs {
            for a: CGFloat in [0, 0.25, 0.5] { parameters.append([pair[0], pair[1], a, a]) }
        }
        let gaps = [b.minX - m.rect.minX, m.rect.maxX - b.maxX, b.minY - m.rect.minY, m.rect.maxY - b.maxY]
            .map { min(0.5, max(0, $0 / w)) }
        for n: CGFloat in [0, 0.1, 0.25] {
            for a: CGFloat in [0, 0.1, 0.25] {
                parameters.append(zip(gaps, [n, n, a, a]).map { max($0.0, $0.1) })
            }
        }
        // Polygon centroid uses the complete convex support, never pixel/vertex quantiles.
        var twiceArea: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for i in local.indices {
            let p = local[i], q = local[(i + 1) % local.count]
            let cross = p.x * q.y - q.x * p.y
            twiceArea += cross; cx += (p.x + q.x) * cross; cy += (p.y + q.y) * cross
        }
        guard twiceArea.isFinite, abs(twiceArea) > 1e-9 else { return [] }
        let centroid = CGPoint(x: cx / (3 * twiceArea), y: cy / (3 * twiceArea))
        // Opposite the support mass: retain a sparse both-axis whitespace alternative.
        for n: CGFloat in [0.1, 0.25, 0.5] {
            for a: CGFloat in [0.1, 0.25, 0.5] {
                parameters.append([centroid.x >= b.midX - w * 1e-9 ? n : 0, centroid.x < b.midX - w * 1e-9 ? n : 0,
                                   centroid.y >= b.midY - w * 1e-9 ? a : 0, centroid.y < b.midY - w * 1e-9 ? a : 0])
            }
        }
        var seen = Set<[Int64]>(), output: [NativeOCRResidualCandidate] = []
        for (index, p) in parameters.enumerated() {
            let suffix = index < 10 ? "0\(index)" : "\(index)"
            let key = "asymmetric-support-v1-p\(suffix)"
            guard seen.insert(p.map { Int64(($0 * 1e12).rounded()) }).inserted else { continue }
            if let allowedKeys, !allowedKeys.contains(key) { continue }
            let r = CGRect(x: b.minX - w * p[0], y: b.minY - w * p[2],
                           width: b.width + w * (p[0] + p[1]), height: b.height + w * (p[2] + p[3]))
            let polygon = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(m.restore)
            guard r.width * r.height > 2, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  support.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 1e-6) }) else { continue }
            output.append(.init(key: key, polygon: polygon, supportPoints: support))
        }
        return output
    }

    /// Prefer the explicit-caps overload in the bank; this wrapper has no inferred caps.
    static func candidates(_ m: Measurement, allowedKeys: Set<String>? = nil) -> [NativeOCRResidualCandidate] {
        candidates(m, caps: [], allowedKeys: allowedKeys)
    }
}
