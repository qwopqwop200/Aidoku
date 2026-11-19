// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

@available(iOS 18.0, *)
enum NativeOCRScopeGeometry {
    /// Clockwise quad with its upper cross-edge first. Sorting into left/right
    /// halves turns a clockwise-leaning vertical crop upside down. Select an
    /// actual edge instead, independent of the detector's starting vertex.
    static func canonicalQuad(_ points: [CGPoint]) -> [CGPoint]? {
        guard points.count == 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let center = CGPoint(x: points.reduce(0) { $0 + $1.x } / 4,
                             y: points.reduce(0) { $0 + $1.y } / 4)
        let ordered = points.sorted { atan2($0.y - center.y, $0.x - center.x) < atan2($1.y - center.y, $1.x - center.x) }
        let lengths = (0..<4).map { hypot(ordered[($0 + 1) % 4].x - ordered[$0].x, ordered[($0 + 1) % 4].y - ordered[$0].y) }
        guard let shortest = lengths.min(), shortest > 0 else { return nil }
        let candidates = (0..<4).filter { i in
            let dx = ordered[(i + 1) % 4].x - ordered[i].x
            return dx > 0
        }
        guard let start = candidates.min(by: { a, b in
            abs(ordered[(a + 1) % 4].y - ordered[a].y) / lengths[a]
                < abs(ordered[(b + 1) % 4].y - ordered[b].y) / lengths[b]
        }) else { return nil }
        return (0..<4).map { ordered[(start + $0) % 4] }
    }
}
