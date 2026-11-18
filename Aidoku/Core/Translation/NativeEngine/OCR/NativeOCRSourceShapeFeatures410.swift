import Foundation
import CoreGraphics

/// Source measurements only. Fixed dimensional costs; no page/source identities or GT.
enum NativeOCRSourceShapeFeatures410 {
    typealias K = NativeOCRSharedBoundary396
    typealias Roles = SourceContrastRole408
    static let names = ["observedSourceSupportCoverage", "observedAreaFit", "normalExtentFit", "alongExtentFit",
                        "observedCenterFit", "observedAxisFit", "RFIntervalAgreement", "fallbackStability"]
    struct Context {
        let support: [CGPoint]
        let supportMode: String
        let genuineFillCount: Int
        let stableRimCount: Int
        let aaTransitionCount: Int
        let actualLocalIndices: [Int]
        let receipt: [String: Any]
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
            guard NativeOCRSourceShapeFeatures410.valid(q), NativeOCRSourceShapeFeatures410.valid(fallback) else { return nil }
            let p = q.map(project), n0 = p.map(\.x).min()!, n1 = p.map(\.x).max()!
            let a0 = p.map(\.y).min()!, a1 = p.map(\.y).max()!
            let ns = normalBounds.upperBound - normalBounds.lowerBound + 2 * normalRadius
            let als = alongBounds.upperBound - alongBounds.lowerBound + 2 * alongRadius
            let corners = [CGPoint(x: -0.5, y: -0.5), CGPoint(x: 0.5, y: -0.5),
                           CGPoint(x: 0.5, y: 0.5), CGPoint(x: -0.5, y: 0.5)]
            let enclosed = support.reduce(0) { total, point in
                total + (corners.allSatisfy { K.contains(q, CGPoint(x: point.x + $0.x, y: point.y + $0.y)) } ? 1 : 0)
            }
            let bodyArea = max(1, ns * als), qa = NativeOCRSourceShapeFeatures410.area(q)
            let areaError = abs(log(max(1e-9, Double(qa / bodyArea))))
            let nc = (n0 + n1 - normalBounds.lowerBound - normalBounds.upperBound) * 0.5
            let ac = (a0 + a1 - alongBounds.lowerBound - alongBounds.upperBound) * 0.5
            let major = NativeOCRSourceShapeFeatures410.majorAxis(q)
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
                let along = NativeOCRSourceShapeFeatures410.interval(a0, a1, ra0, ra1)
                let normal = rn1 - rn0 <= 2.5 * nativeW ? NativeOCRSourceShapeFeatures410.interval(n0, n1, rn0, rn1) : along
                rfAgreement = Double((along + normal) * 0.5) * min(1, max(0, rf.confidence))
            }
            let values = [supportConfidence * Double(enclosed) / Double(support.count), -min(8, areaError),
                -min(8, Double(abs(n1 - n0 - ns) / max(nativeW, ns))),
                -min(8, Double(abs(a1 - a0 - als) / max(nativeW, als))),
                -min(8, Double(hypot(nc / nativeW, ac / max(nativeW, als)))),
                -Double(axisError), rfAgreement, NativeOCRSourceShapeFeatures410.stability(q, fallback: fallback, nativeW: nativeW)]
            return values.allSatisfy(\.isFinite) ? values : nil
        }
    }
    struct Sample {
        let index: Int
        let point: CGPoint
        let role: Roles.Role
        let row: Int
        let component: Int
        let witness: Roles.PixelWitness
    }
    // Rebind every positive sample to actual bytes/membership/DB/RF/source row.
    // No GG/native support fallback and no whole-CC role propagation.
    static func validatedSamples(basis: K.Basis, evidence e: K.Evidence,
                                 observation o: Roles.Output, includeAA: Bool = false) -> [Sample]? {
        let r = e.rgba, w = r.width, h = r.height
        guard w > 2, h > 2, w <= 600_000 / h, r.bytesPerRow >= w * 4,
              r.bytesPerRow <= Int.max / h, r.bytes.count == h * r.bytesPerRow,
              e.body.count == w * h, o.roles.count == w * h,
              [r.origin, basis.origin, basis.normal, basis.along].allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              abs(hypot(basis.normal.x, basis.normal.y) - 1) < 1e-6,
              abs(hypot(basis.along.x, basis.along.y) - 1) < 1e-6,
              abs(basis.normal.x * basis.along.x + basis.normal.y * basis.along.y) < 1e-6,
              e.detectors.count <= 64, e.rf.count <= 160,
              e.rf.allSatisfy({ $0.bounds.count == 4 && $0.bounds.allSatisfy({ $0.isFinite }) && $0.confidence.isFinite }),
              o.rows.count <= 4096, o.components.count <= 20_000,
              o.receipt["family"] as? String == "source-contrast-role408",
              o.receipt["status"] as? String == "source-role-observations-only",
              o.receipt["RGBAWidth"] as? Int == w, o.receipt["RGBAHeight"] as? Int == h,
              o.receipt["wholeComponentRolePropagation"] as? Bool == false else { return nil }
        func world(_ i: Int) -> CGPoint { .init(x: r.origin.x + CGFloat(i % w) + 0.5, y: r.origin.y + CGFloat(i / w) + 0.5) }
        func accepted(_ role: Roles.Role) -> Bool {
            role == .fill || role == .unoutlinedPositive || role == .stableRimCore || (includeAA && role == .aaTransition)
        }
        var components: [Int: Roles.ComponentRole] = [:]
        for c in o.components {
            guard components[c.componentID] == nil, c.sampledPixelRolesOnly else { return nil }
            components[c.componentID] = c
        }
        var samples: [Int: Sample] = [:], queries = 0, visits = 0
        let alongRadius = (abs(basis.along.x) + abs(basis.along.y)) * 0.5
        for (rowIndex, row) in o.rows.enumerated() {
            guard row.seed >= 0, row.seed < w*h, row.along.isFinite,
                  row.low.fill.contains(row.seed), row.high.fill.contains(row.seed),
                  (row.low.path + row.high.path).allSatisfy({ i in
                      guard i >= 0, i < w*h else { return false }
                      let p = world(i)
                      let a = (p.x - basis.origin.x) * basis.along.x + (p.y - basis.origin.y) * basis.along.y
                      return abs(a - row.along) <= alongRadius + 1e-6
                  }) else { return nil }
            guard let c = components[row.componentID], c.closedAtCapture,
                  c.directlyRooted || c.connectedRootComponentID != nil,
                  c.role == .fill || c.role == .unoutlinedPositive else { continue }
            let fill = Set(row.low.fill + row.high.fill)
            let rim = Set(row.low.stableRim + row.high.stableRim)
            let aa = Set(row.low.rimOrAA + row.high.rimOrAA).subtracting(rim)
            for v in row.witnesses {
                visits += 1
                guard visits <= 2_000_000, v.localIndex >= 0, v.localIndex < w*h else { return nil }
                let i = v.localIndex, role = o.role(atActualLocalPixelIndex: i)
                guard accepted(role) else { continue }
                let justified = (role == .fill || role == .unoutlinedPositive) ? fill.contains(i) :
                    role == .stableRimCore ? rim.contains(i) : aa.contains(i)
                guard justified else { continue }
                let p = world(i), offset = (i / w) * r.bytesPerRow + (i % w) * 4
                guard v.center == p, v.rgb == (0..<3).map({ Int(r.bytes[offset+$0]) }),
                      r.bytes[offset+3] == 255, v.rootGG == (e.body[i] != 0), v.actualNativeRootCell == e.privateAt(p) else { return nil }
                for j in v.detectorArrayPositions {
                    queries += 1
                    guard queries <= 2_000_000, j >= 0, j < e.detectors.count, e.detectors[j].cells.contains(p) else { return nil }
                }
                for j in v.nativeRootDetectorArrayPositions {
                    guard v.detectorArrayPositions.contains(j), j >= 0, j < e.detectors.count, e.detectors[j].nativeRoot else { return nil }
                }
                for j in v.rfArrayPositions {
                    queries += 1
                    guard queries <= 2_000_000, j >= 0, j < e.rf.count, e.rf[j].confidence >= 0.4, e.rf[j].contains(p) else { return nil }
                }
                if samples[i] == nil { samples[i] = .init(index: i, point: p, role: role, row: rowIndex, component: row.componentID, witness: v) }
            }
        }
        let positive = Set(o.roles.indices.filter { accepted(o.role(atActualLocalPixelIndex: $0)) })
        guard positive == Set(samples.keys) else { return nil }
        return samples.keys.sorted().map { samples[$0]! }
    }
    static func prepare(actualOld: [CGPoint], basis: K.Basis, nativeW: CGFloat,
                        evidence: K.Evidence, observation: Roles.Output, includeAA: Bool = false) -> Context? {
        guard valid(actualOld), nativeW.isFinite, nativeW > 0,
              let all = validatedSamples(basis: basis, evidence: evidence, observation: observation, includeAA: includeAA),
              all.count >= 12, Set(all.map(\.row)).count >= 3 else { return nil }
        let genuineFillCount = all.filter { $0.role == .fill || $0.role == .unoutlinedPositive }.count
        let stableRimCount = all.filter { $0.role == .stableRimCore }.count
        let aaTransitionCount = all.filter { $0.role == .aaTransition }.count
        // Evidence confidence is a schema coefficient, not ownership/probability.
        let mode = includeAA ? "actual408-positive-fill-stable-rim-and-AA" : "actual408-positive-fill-and-stable-rim"
        let confidence = 1.0
        var selected = all
        if selected.count > 8192 {
            // Retain true observed extrema as well as representative samples.
            func proj(_ s: Sample) -> CGPoint {
                let d = CGPoint(x: s.point.x-basis.origin.x,y:s.point.y-basis.origin.y)
                return .init(x:d.x*basis.normal.x+d.y*basis.normal.y,y:d.x*basis.along.x+d.y*basis.along.y)
            }
            let nLow = all.min { proj($0).x < proj($1).x }!, nHigh = all.max { proj($0).x < proj($1).x }!
            let aLow = all.min { proj($0).y < proj($1).y }!, aHigh = all.max { proj($0).y < proj($1).y }!
            var chosen: [Int: Sample] = [:]
            for v in [nLow,nHigh,aLow,aHigh] { chosen[v.index] = v }
            for k in 0..<8188 { let v=all[k*(all.count-1)/8187];chosen[v.index]=v }
            selected = chosen.keys.sorted().map { chosen[$0]! }
        }
        let points = selected.map(\.point)
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
        return .init(support: points, supportMode: mode, genuineFillCount: genuineFillCount,
            stableRimCount: stableRimCount, aaTransitionCount: aaTransitionCount,
            actualLocalIndices: selected.map(\.index),
            receipt: ["family":"source-shape-features410","roleObserver":"source-contrast-role408",
                "fillPixels":genuineFillCount,"stableRimPixels":stableRimCount,"AAPixels":aaTransitionCount,
                "allValidatedVisualSamples":all.count,"featureSamples":points.count,
                "includeAA":includeAA,"nativeOrGGFallbackUsed":false,"unknownPixelsPromoted":false,
                "ownershipClaimed":false,"admissionGranted":false], supportConfidence: confidence,
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
