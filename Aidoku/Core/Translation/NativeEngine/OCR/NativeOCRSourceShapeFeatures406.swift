import Foundation
import CoreGraphics

/// Source measurements only. Fixed dimensional costs; no page/source identities or GT.
enum NativeOCRSourceShapeFeatures406 {
    typealias K = NativeOCRSharedBoundary396
    typealias Roles = SourceFillRimRole405
    static let names = ["observedSourceSupportCoverage", "observedAreaFit", "normalExtentFit", "alongExtentFit",
                        "observedCenterFit", "observedAxisFit", "RFIntervalAgreement", "fallbackStability"]
    struct Context {
        let support: [CGPoint]
        let supportMode: String
        let genuineFillCount: Int
        let supportConfidence: Double
        let basis: K.Basis
        let nativeW: CGFloat
        let normalBounds: ClosedRange<CGFloat>
        let alongBounds: ClosedRange<CGFloat>
        let normalRadius: CGFloat
        let alongRadius: CGFloat
        let axis: CGPoint?
        let rf: K.RF?
        func project(_ p: CGPoint) -> CGPoint {
            let d = CGPoint(x: p.x - basis.origin.x, y: p.y - basis.origin.y)
            return .init(x: d.x * basis.normal.x + d.y * basis.normal.y,
                         y: d.x * basis.along.x + d.y * basis.along.y)
        }
        func features(_ q: [CGPoint], fallback: [CGPoint]) -> [Double]? {
            guard NativeOCRSourceShapeFeatures406.valid(q), NativeOCRSourceShapeFeatures406.valid(fallback) else { return nil }
            let p = q.map(project), n0 = p.map(\.x).min()!, n1 = p.map(\.x).max()!
            let a0 = p.map(\.y).min()!, a1 = p.map(\.y).max()!
            let ns = normalBounds.upperBound - normalBounds.lowerBound + 2 * normalRadius
            let als = alongBounds.upperBound - alongBounds.lowerBound + 2 * alongRadius
            let corners = [CGPoint(x: -0.5, y: -0.5), CGPoint(x: 0.5, y: -0.5),
                           CGPoint(x: 0.5, y: 0.5), CGPoint(x: -0.5, y: 0.5)]
            let enclosed = support.reduce(0) { total, point in
                total + (corners.allSatisfy { K.contains(q, CGPoint(x: point.x + $0.x, y: point.y + $0.y)) } ? 1 : 0)
            }
            let bodyArea = max(1, ns * als), qa = NativeOCRSourceShapeFeatures406.area(q)
            let areaError = abs(log(max(1e-9, Double(qa / bodyArea))))
            let nc = (n0 + n1 - normalBounds.lowerBound - normalBounds.upperBound) * 0.5
            let ac = (a0 + a1 - alongBounds.lowerBound - alongBounds.upperBound) * 0.5
            let major = NativeOCRSourceShapeFeatures406.majorAxis(q)
            let axisError: CGFloat
            if let axis, let major { axisError = max(0, 1 - pow(axis.x * major.x + axis.y * major.y, 2)) }
            else { axisError = 0 }
            var rfAgreement = 0.0
            if let rf {
                let b = rf.bounds
                let r = [CGPoint(x: b[0], y: b[1]), CGPoint(x: b[2], y: b[1]),
                         CGPoint(x: b[2], y: b[3]), CGPoint(x: b[0], y: b[3])].map(project)
                let rn0 = r.map(\.x).min()!, rn1 = r.map(\.x).max()!
                let ra0 = r.map(\.y).min()!, ra1 = r.map(\.y).max()!
                let along = NativeOCRSourceShapeFeatures406.interval(a0, a1, ra0, ra1)
                let normal = rn1 - rn0 <= 2.5 * nativeW ? NativeOCRSourceShapeFeatures406.interval(n0, n1, rn0, rn1) : along
                rfAgreement = Double((along + normal) * 0.5) * min(1, max(0, rf.confidence))
            }
            let values = [supportConfidence * Double(enclosed) / Double(support.count), -min(8, areaError),
                -min(8, Double(abs(n1 - n0 - ns) / max(nativeW, ns))),
                -min(8, Double(abs(a1 - a0 - als) / max(nativeW, als))),
                -min(8, Double(hypot(nc / nativeW, ac / max(nativeW, als)))),
                -Double(axisError), rfAgreement, NativeOCRSourceShapeFeatures406.stability(q, fallback: fallback, nativeW: nativeW)]
            return values.allSatisfy(\.isFinite) ? values : nil
        }
    }
    static func prepare(actualOld: [CGPoint], basis: K.Basis, nativeW: CGFloat,
                        evidence: K.Evidence, observation: Roles.Output) -> Context? {
        guard valid(actualOld), nativeW.isFinite, nativeW > 0, observation.roles.count == evidence.body.count,
              observation.roles.count == evidence.rgba.width * evidence.rgba.height else { return nil }
        let rgba = evidence.rgba
        var points = observation.roles.indices.compactMap { i -> CGPoint? in
            guard observation.isPositiveFill(atActualLocalPixelIndex: i) else { return nil }
            return CGPoint(x: rgba.origin.x + CGFloat(i % rgba.width) + 0.5,
                           y: rgba.origin.y + CGFloat(i / rgba.width) + 0.5)
        }
        let genuineFillCount = points.count
        var mode = "actual-RGB-bilateral-fill-samples", confidence = 1.0
        if points.count < 12 {
            points = evidence.body.indices.compactMap { i -> CGPoint? in
                guard evidence.body[i] != 0 else { return nil }
                let point = CGPoint(x: rgba.origin.x + CGFloat(i % rgba.width) + 0.5,
                    y: rgba.origin.y + CGFloat(i / rgba.width) + 0.5)
                return evidence.privateAt(point) ? point : nil
            }
            mode = "actual-GG-contrast-with-original-native-root-support"; confidence = 0.75
        }
        if points.count < 12 {
            points = evidence.nativeCellCenters.filter { p in
                p.x >= rgba.origin.x && p.x < rgba.origin.x + CGFloat(rgba.width) &&
                p.y >= rgba.origin.y && p.y < rgba.origin.y + CGFloat(rgba.height)
            }
            mode = "original-native-model-support-not-a-fill-or-ownership-mask"; confidence = 0.5
        }
        guard points.count >= 12 else { return nil }
        if points.count > 8192 {
            let originals = points
            points = (0..<8192).map { originals[$0 * (originals.count - 1) / 8191] }
        }
        func projected(_ p: CGPoint) -> CGPoint {
            let d = CGPoint(x: p.x - basis.origin.x, y: p.y - basis.origin.y)
            return .init(x: d.x * basis.normal.x + d.y * basis.normal.y,
                         y: d.x * basis.along.x + d.y * basis.along.y)
        }
        let p = points.map(projected), n0 = p.map(\.x).min()!, n1 = p.map(\.x).max()!
        let a0 = p.map(\.y).min()!, a1 = p.map(\.y).max()!
        guard n1 > n0, a1 > a0 else { return nil }
        let mean = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                           y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        var xx: CGFloat = 0, yy: CGFloat = 0, xy: CGFloat = 0
        for point in points { let x = point.x - mean.x, y = point.y - mean.y; xx += x*x; yy += y*y; xy += x*y }
        let separation = hypot(xx - yy, 2 * xy) / max(1e-9, xx + yy)
        let angle = atan2(2 * xy, xx - yy) * 0.5
        let axis: CGPoint? = separation >= 0.25 ? CGPoint(x: cos(angle), y: sin(angle)) : nil
        let old = actualOld.map(projected), on0 = old.map(\.x).min()!, on1 = old.map(\.x).max()!
        let oa0 = old.map(\.y).min()!, oa1 = old.map(\.y).max()!
        var best: (Double, K.RF)?
        for rf in evidence.rf where rf.confidence >= 0.4 {
            let b = rf.bounds
            let r = [CGPoint(x: b[0], y: b[1]), CGPoint(x: b[2], y: b[1]),
                     CGPoint(x: b[2], y: b[3]), CGPoint(x: b[0], y: b[3])].map(projected)
            let rn0 = r.map(\.x).min()!, rn1 = r.map(\.x).max()!, ra0 = r.map(\.y).min()!, ra1 = r.map(\.y).max()!
            let alongRatio = (ra1 - ra0) / max(nativeW, oa1 - oa0)
            guard (0.4...2.5).contains(alongRatio), rn1 - rn0 <= 4 * max(nativeW, on1 - on0),
                  max(0, min(rn1, on1) - max(rn0, on0)) > 0,
                  max(0, min(ra1, oa1) - max(ra0, oa0)) > 0 else { continue }
            let match = Double(interval(oa0, oa1, ra0, ra1)) * min(1, rf.confidence)
            if best == nil || match > best!.0 { best = (match, rf) }
        }
        return .init(support: points, supportMode: mode, genuineFillCount: genuineFillCount, supportConfidence: confidence,
            basis: basis, nativeW: nativeW, normalBounds: n0...n1,
            alongBounds: a0...a1, normalRadius: (abs(basis.normal.x) + abs(basis.normal.y)) * 0.5,
            alongRadius: (abs(basis.along.x) + abs(basis.along.y)) * 0.5, axis: axis, rf: best?.1)
    }
    static func rebased(_ features: [Double], polygon: [CGPoint], fallback: [CGPoint], nativeW: CGFloat) -> [Double]? {
        guard features.count == names.count, features.allSatisfy(\.isFinite), valid(polygon), valid(fallback), nativeW > 0 else { return nil }
        var values = features; values[7] = stability(polygon, fallback: fallback, nativeW: nativeW); return values
    }
    private static func stability(_ q: [CGPoint], fallback: [CGPoint], nativeW: CGFloat) -> Double {
        let qc = CGPoint(x: q.map(\.x).reduce(0,+)/4, y: q.map(\.y).reduce(0,+)/4)
        let bc = CGPoint(x: fallback.map(\.x).reduce(0,+)/4, y: fallback.map(\.y).reduce(0,+)/4)
        let shift = hypot(qc.x-bc.x, qc.y-bc.y) / nativeW
        let size = abs(log(max(1e-9, Double(area(q)/max(1e-9, area(fallback))))))
        let direction: Double
        if let a=majorAxis(q), let b=majorAxis(fallback) { direction = Double(max(0,1-pow(a.x*b.x+a.y*b.y,2))) }
        else { direction = 0 }
        return -min(8, Double(shift) + size + direction)
    }
    private static func area(_ q: [CGPoint]) -> CGFloat {
        let o=q[0]; return abs((0..<4).reduce(CGFloat(0)) { s,i in
            let a=q[i],b=q[(i+1)%4];return s+(a.x-o.x)*(b.y-o.y)-(b.x-o.x)*(a.y-o.y)
        })*0.5
    }
    private static func majorAxis(_ q: [CGPoint]) -> CGPoint? {
        let edges=(0..<4).map { CGPoint(x:q[($0+1)%4].x-q[$0].x,y:q[($0+1)%4].y-q[$0].y) }
        guard let e=edges.max(by:{hypot($0.x,$0.y)<hypot($1.x,$1.y)}), hypot(e.x,e.y)>0 else{return nil}
        let length=hypot(e.x,e.y);return .init(x:e.x/length,y:e.y/length)
    }
    private static func interval(_ a: CGFloat,_ b: CGFloat,_ c: CGFloat,_ d: CGFloat) -> CGFloat {
        max(0,min(b,d)-max(a,c))/max(1e-9,max(b,d)-min(a,c))
    }
    private static func valid(_ q: [CGPoint]) -> Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite})else{return false}
        let turns=(0..<4).map { i -> CGFloat in
            let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4];return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        return turns.allSatisfy({$0>1e-8}) || turns.allSatisfy({$0 < -1e-8})
    }
}
