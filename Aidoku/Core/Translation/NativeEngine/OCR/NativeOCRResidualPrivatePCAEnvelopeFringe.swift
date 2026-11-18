import Foundation
import CoreGraphics

/// Additive geometry proposal only. Does not grant owner/erasure rights.
/// Caller must retain the existing source/frame/foreign-private/semantic guards.
@available(iOS 18.0, *)
enum NativeOCRResidualPrivatePCAEnvelopeFringe {
    /// Accumulate EACH accepted, Float-rounded LOCAL privatePoint at the native
    /// privatePoints.append site, including points outside the incoming quad.
    /// Never accumulate hull vertices, guardPoints, or RGB sampled points instead.
    struct PrivateMoments {
        private(set) var count = 0
        private(set) var meanX: Double = 0
        private(set) var meanY: Double = 0
        private(set) var xx: Double = 0
        private(set) var xy: Double = 0
        private(set) var yy: Double = 0

        mutating func append(_ local: CGPoint) {
            count += 1
            let x = Double(local.x), y = Double(local.y)
            let dx = x - meanX, dy = y - meanY
            meanX += dx / Double(count); meanY += dy / Double(count)
            xx += dx * (x - meanX)
            xy += dx * (y - meanY)
            yy += dy * (y - meanY)
        }
    }

    static func candidates(
        _ m: NativeOCRSourceComponentMeasurements.Measurement,
        privateMoments p: PrivateMoments,
        inherited: [CGPoint], originalGuard: [CGPoint],
        visibleForeground: [CGPoint], protectedCaps: [CGPoint]
    ) -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", m.polygon.count == 4, inherited.count == 4,
              p.count >= 8, p.count == m.privateSamples else { return [] }
        func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
        func direction(_ q: [CGPoint]) -> CGPoint? {
            let a = CGPoint(x: q[1].x - q[0].x, y: q[1].y - q[0].y)
            let b = CGPoint(x: q[3].x - q[0].x, y: q[3].y - q[0].y)
            let e = hypot(a.x, a.y) >= hypot(b.x, b.y) ? a : b
            let length = hypot(e.x, e.y)
            return length > 1e-9 ? CGPoint(x: e.x / length, y: e.y / length) : nil
        }
        guard let base = direction(m.polygon), let oldAlong = direction(inherited) else { return [] }
        let n = Double(p.count - 1), xx = p.xx / n, xy = p.xy / n, yy = p.yy / n
        let gap = hypot(xx - yy, 2 * xy)
        let large = (xx + yy + gap) / 2, small = (xx + yy - gap) / 2
        guard large.isFinite, large >= 3 * max(small, 1e-9), gap > 0 else { return [] }
        let angle = atan2(2 * xy, xx - yy) / 2
        var along = CGPoint(x: cos(angle) * m.normal.x + sin(angle) * m.along.x,
                            y: cos(angle) * m.normal.y + sin(angle) * m.along.y)
        let length = hypot(along.x, along.y)
        guard length > 0 else { return [] }
        along.x /= length; along.y /= length
        if dot(along, base) < 0 { along.x = -along.x; along.y = -along.y }
        let alignment = dot(along, base)
        guard alignment >= cos(12 * .pi / 180), abs(alignment) <= 1 - 1e-10 else { return [] }
        let normal = CGPoint(x: along.y, y: -along.x)
        let fullSupport = m.guardPoints + originalGuard + visibleForeground + protectedCaps + m.privateHull.map(m.restore)
        guard fullSupport.count >= 3,
              fullSupport.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        let origin = m.origin
        func relative(_ point: CGPoint) -> CGPoint { .init(x: point.x - origin.x, y: point.y - origin.y) }
        let projected = fullSupport.map { point -> CGPoint in
            let r = relative(point); return .init(x: dot(r, normal), y: dot(r, along))
        }
        let x0 = projected.map(\.x).min()! - 1, x1 = projected.map(\.x).max()! + 1
        var y0 = projected.map(\.y).min()!, y1 = projected.map(\.y).max()!
        guard x1 > x0, y1 > y0 else { return [] }
        func polygon() -> [CGPoint] {
            [CGPoint(x: x0, y: y0), .init(x: x1, y: y0), .init(x: x1, y: y1), .init(x: x0, y: y1)].map {
                .init(x: origin.x + $0.x * normal.x + $0.y * along.x,
                      y: origin.y + $0.x * normal.y + $0.y * along.y)
            }
        }
        let oldSpan = inherited.map { dot(relative($0), oldAlong) }
        let newSpan = polygon().map { dot(relative($0), oldAlong) }
        let cosine = dot(along, oldAlong)
        guard cosine > 0.5 else { return [] }
        y0 -= max(0, newSpan.min()! - oldSpan.min()!) / cosine
        y1 += max(0, oldSpan.max()! - newSpan.max()!) / cosine
        let result = polygon()
        guard result.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        return [.init(key: "private-pca-normal1-retain-prior-along-turning-component-veto-v1", polygon: result, supportPoints: fullSupport)]
    }
}
