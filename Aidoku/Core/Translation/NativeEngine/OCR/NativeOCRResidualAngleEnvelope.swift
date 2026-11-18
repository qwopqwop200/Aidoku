import CoreGraphics
import Foundation

/// Bounded source-frame rotations of the complete observed support envelope.
/// Geometry context only: does not acquire DB ownership or consume peers.
@available(iOS 18.0, *)
enum NativeOCRResidualAngleEnvelope {
    typealias M = NativeOCRSourceComponentMeasurements.Measurement
    static func candidates(_ m: M, caps: [CGPoint], allowedKeys: Set<String>? = nil) -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", m.polygon.count == 4, m.rect.width > 0,
              allowedKeys?.isEmpty != true else { return [] }
        let support = NativeOCRSourceComponentMeasurements.convexHull(
            m.guardPoints + NativeOCRSourceComponentBounds.visibleForeground(m) + caps)
        guard support.count >= 3, support.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        let local = support.map(m.project), incoming = m.polygon.map(m.project)
        var result: [NativeOCRResidualCandidate] = []
        let angles: [(String, CGFloat)] = [("m4", -4), ("m2", -2), ("m1", -1), ("m05", -0.5),
            ("0", 0), ("p05", 0.5), ("p1", 1), ("p2", 2), ("p4", 4)]
        let pads: [(String, CGFloat, CGFloat)] = [("n0-a0", 0, 0), ("n0-a05", 0, 0.05),
            ("n10-a10", 0.1, 0.1), ("n25-a25", 0.25, 0.25)]
        for (angleName, degrees) in angles {
            let radians = degrees * .pi / 180, c = cos(radians), s = sin(radians)
            func rotate(_ p: CGPoint) -> CGPoint { .init(x: p.x * c - p.y * s, y: p.x * s + p.y * c) }
            func restore(_ p: CGPoint) -> CGPoint { m.restore(.init(x: p.x * c + p.y * s, y: -p.x * s + p.y * c)) }
            let observed = NativeOCRSourceComponentBounds.bounds(local.map(rotate))
            let original = NativeOCRSourceComponentBounds.bounds(incoming.map(rotate))
            for retain in [false, true] {
                let low = retain ? min(observed.minY, original.minY) : observed.minY
                let high = retain ? max(observed.maxY, original.maxY) : observed.maxY
                for (padName, normalPad, alongPad) in pads {
                    let key = "angle-envelope-v1-\(angleName)-r\(retain ? 1 : 0)-\(padName)"
                    if let allowedKeys, !allowedKeys.contains(key) { continue }
                    let r = CGRect(x: observed.minX - normalPad * m.rect.width, y: low - alongPad * m.rect.width,
                        width: observed.width + 2 * normalPad * m.rect.width,
                        height: high - low + 2 * alongPad * m.rect.width)
                    guard r.width > 0, r.height >= r.width, r.width * r.height > 2 else { continue }
                    let q = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                        CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(restore)
                    guard q.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 }),
                          support.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(q, $0, tolerance: 1e-6) }) else { continue }
                    result.append(.init(key: key, polygon: q, supportPoints: support))
                }
            }
        }
        return result
    }
}
