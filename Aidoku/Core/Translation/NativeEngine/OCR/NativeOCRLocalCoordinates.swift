import CoreGraphics
import Foundation

/// Geometry-only local coordinates. No page IDs, labels, text substitutions,
/// detector confidence changes, or automatic upside-down text classification.
enum NativeOCRDirectionGeometry {
    /// Keep a valid directed cycle exactly. For an unordered input, recover a
    /// cycle anchored at the supplied first vertex, not screen-left halves.
    static func cycle(_ points: [CGPoint]) -> [CGPoint]? {
        guard points.count == 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        func turns(_ p: [CGPoint]) -> [CGFloat] {
            (0..<4).map { i in
                let a = p[i], b = p[(i+1)%4], c = p[(i+2)%4]
                return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
            }
        }
        let cross = turns(points)
        if cross.allSatisfy({ $0 > 0.000001 }) { return points }
        if cross.allSatisfy({ $0 < -0.000001 }) { return [points[0], points[3], points[2], points[1]] }
        let center = CGPoint(x: points.map(\.x).reduce(0,+)/4, y: points.map(\.y).reduce(0,+)/4)
        let sorted = points.sorted { atan2($0.y-center.y,$0.x-center.x) < atan2($1.y-center.y,$1.x-center.x) }
        guard turns(sorted).allSatisfy({ $0 > 0.000001 }), let start = sorted.firstIndex(of: points[0]) else { return nil }
        return (0..<4).map { sorted[(start+$0)%4] }
    }

    /// A detector's cyclic vertex index is NOT a measured reading direction.
    /// Resolve an untyped detection to the established upright reading basis,
    /// independently of its first vertex, without flattening/reshaping the quad.
    static func readingQuad(_ points: [CGPoint]) -> [CGPoint]? {
        guard let q = cycle(points) else { return nil }
        let lengths = (0..<4).map { hypot(q[($0+1)%4].x-q[$0].x,q[($0+1)%4].y-q[$0].y) }
        guard let shortest = lengths.min(), shortest > 0 else { return nil }
        let candidates = (0..<4).filter { i in q[(i+1)%4].x-q[i].x > 0 }
        guard let start = candidates.min(by: { a,b in
            let slopeA = abs(q[(a+1)%4].y-q[a].y)/lengths[a]
            let slopeB = abs(q[(b+1)%4].y-q[b].y)/lengths[b]
            if abs(slopeA-slopeB) > 0.000001 { return slopeA < slopeB }
            let midYA = q[a].y+q[(a+1)%4].y, midYB = q[b].y+q[(b+1)%4].y
            if abs(midYA-midYB) > 0.000001 { return midYA < midYB }
            return q[a].x+q[(a+1)%4].x < q[b].x+q[(b+1)%4].x
        }) else { return nil }
        return (0..<4).map { q[(start+$0)%4] }
    }
}
