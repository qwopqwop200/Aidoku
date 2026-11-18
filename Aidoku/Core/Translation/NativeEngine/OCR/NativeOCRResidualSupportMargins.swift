import CoreGraphics
import Foundation

/// Source-scale whitespace alternatives around complete observed support.
/// Source provenance remains unchanged; these are recognition crops, not erasure masks.
@available(iOS 18.0, *)
enum NativeOCRResidualSupportMargins {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement

    static func assess(_ m: Measurement, caps: [CGPoint], allowedKeys: Set<String>? = nil) -> [NativeOCRResidualCandidate] {
        if let allowedKeys, allowedKeys.isEmpty { return [] }
        guard m.status == "measured", m.rect.width.isFinite, m.rect.width > 0 else { return [] }
        let points = m.guardPoints + NativeOCRSourceComponentBounds.visibleForeground(m) + caps
        guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        let support = NativeOCRSourceComponentMeasurements.convexHull(points)
        guard support.count >= 3 else { return [] }
        let local = support.map(m.project)
        guard local.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        let bounds = NativeOCRSourceComponentBounds.bounds(local)
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        var result: [NativeOCRResidualCandidate] = []
        for normal in [0, 5, 10, 15, 20, 25] {
            for along in [0, 5, 10, 15, 20, 25] {
                let key = "support-margin-v1-n\(normal)-a\(along)"
                if let allowedKeys, !allowedKeys.contains(key) { continue }
                let rect = bounds.insetBy(dx: -m.rect.width * CGFloat(normal) / 100,
                                         dy: -m.rect.width * CGFloat(along) / 100)
                let polygon = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map(m.restore)
                guard polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                      rect.width * rect.height > 2,
                      support.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 1e-6) }) else {
                    continue
                }
                result.append(.init(key: key, polygon: polygon, supportPoints: support))
            }
        }
        return result
    }
}
