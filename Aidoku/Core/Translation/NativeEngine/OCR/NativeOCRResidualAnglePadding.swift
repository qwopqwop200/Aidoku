import CoreGraphics
import Foundation

/// One-sided local padding of complete support rectangles. Ownership is unchanged.
@available(iOS 18.0, *)
enum NativeOCRResidualAnglePadding {
    typealias M = NativeOCRSourceComponentMeasurements.Measurement

    static func candidates(_ m: M, caps: [CGPoint], allowedKeys: Set<String>? = nil) -> [NativeOCRResidualCandidate] {
        guard allowedKeys?.isEmpty != true else { return [] }
        let baseKeys = allowedKeys.map { keys in
            Set(keys.compactMap { key -> String? in
                guard key.hasPrefix("angle-padding-v1-"),
                      let side = key.range(of: "-", options: .backwards) else { return nil }
                let suffix = key[key.index(key.startIndex, offsetBy: "angle-padding-v1-".count)..<side.lowerBound]
                return "angle-envelope-v1-\(suffix)-n0-a0"
            })
        }
        let bases = NativeOCRResidualAngleEnvelope.candidates(m, caps: caps, allowedKeys: baseKeys)
        var result: [NativeOCRResidualCandidate] = []
        for base in bases where base.key.hasSuffix("-n0-a0") {
            let q = base.polygon
            guard q.count == 4 else { continue }
            let x = CGPoint(x: q[1].x - q[0].x, y: q[1].y - q[0].y)
            let y = CGPoint(x: q[3].x - q[0].x, y: q[3].y - q[0].y)
            let width = hypot(x.x, x.y), height = hypot(y.x, y.y)
            guard width > 0, height > 0 else { continue }
            let u = CGPoint(x: x.x / width, y: x.y / width)
            let v = CGPoint(x: y.x / height, y: y.y / height)
            let stem = base.key.replacingOccurrences(of: "angle-envelope-v1-", with: "angle-padding-v1-")
                .replacingOccurrences(of: "-n0-a0", with: "")
            for (side, direction, vertices) in [
                ("left20", CGPoint(x: -u.x, y: -u.y), [0, 3]),
                ("right20", u, [1, 2]),
                ("head20", CGPoint(x: -v.x, y: -v.y), [0, 1]),
                ("tail20", v, [2, 3])
            ] {
                let key = "\(stem)-\(side)"
                if let allowedKeys, !allowedKeys.contains(key) { continue }
                var padded = q
                for index in vertices {
                    padded[index].x += direction.x * width * 0.2
                    padded[index].y += direction.y * width * 0.2
                }
                guard padded.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
                result.append(.init(key: key, polygon: padded, supportPoints: base.supportPoints))
            }
        }
        return result
    }
}
