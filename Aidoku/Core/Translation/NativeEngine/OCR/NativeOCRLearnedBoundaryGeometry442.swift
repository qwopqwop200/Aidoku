import Foundation

/// Generic all-angle parameterization for pixel-profile boundary calibration.
/// No instance identity, label, matching decision, or image hash enters features.
enum NativeOCRLearnedBoundaryGeometry442 {
    struct Basis {
        let center: [Double], normal: [Double], along: [Double], bounds: [Double], width: Double
    }
    static func basis(_ q: [[Double]]) -> Basis? {
        guard q.count == 4, q.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
        var best = [0.0, 0.0], length = 0.0
        for i in 0..<4 {
            let e = [q[(i+1)%4][0]-q[i][0],q[(i+1)%4][1]-q[i][1]], l = hypot(e[0],e[1])
            if l > length { length = l; best = e }
        }
        guard length > 0 else { return nil }
        var a = best.map { $0/length }
        if a[1] < 0 || (a[1] == 0 && a[0] < 0) { a = a.map { -$0 } }
        let n = [a[1],-a[0]], c = [q.map { $0[0] }.reduce(0,+)/4,q.map { $0[1] }.reduce(0,+)/4]
        let p = q.map { (($0[0]-c[0])*n[0]+($0[1]-c[1])*n[1],($0[0]-c[0])*a[0]+($0[1]-c[1])*a[1]) }
        let b = [p.map(\.0).min()!,p.map(\.0).max()!,p.map(\.1).min()!,p.map(\.1).max()!]
        let w = b[1]-b[0]
        guard w > 0, w.isFinite else { return nil }
        return Basis(center:c,normal:n,along:a,bounds:b,width:w)
    }
    static func relative(_ q: [[Double]], to reference: [[Double]]) -> [Double]? {
        guard let s = basis(reference), let target = basis(q) else { return nil }
        var angle = atan2(s.along[0]*target.along[1]-s.along[1]*target.along[0],s.along[0]*target.along[0]+s.along[1]*target.along[1])
        while angle > .pi/2 { angle -= .pi }
        while angle < -.pi/2 { angle += .pi }
        let ca = cos(angle), sa = sin(angle)
        func rotate(_ v: [Double]) -> [Double] { [ca*v[0]-sa*v[1],sa*v[0]+ca*v[1]] }
        let n = rotate(s.normal), a = rotate(s.along)
        let p = q.map { (($0[0]-s.center[0])*n[0]+($0[1]-s.center[1])*n[1],($0[0]-s.center[0])*a[0]+($0[1]-s.center[1])*a[1]) }
        let b = [p.map(\.0).min()!,p.map(\.0).max()!,p.map(\.1).min()!,p.map(\.1).max()!]
        return zip(b,s.bounds).map { ($0-$1)/s.width }+[angle]
    }
    static func geometricFeatures(current: [[Double]], metadata: [[[Double]]?], authenticSource50: [Double]?) -> [Double]? {
        guard let s = basis(current), metadata.count == 4 else { return nil }
        let length = s.bounds[3]-s.bounds[2]
        guard length > 0 else { return nil }
        var out = [log(s.width),log(length),length/s.width,s.along[0]*s.along[0]-s.along[1]*s.along[1],2*s.along[0]*s.along[1]]
        for q in metadata {
            if let q, let x = relative(q,to:current) { out += x+[1] }
            else { out += [Double](repeating:0,count:6) }
        }
        if let x = authenticSource50, x.count == 50, x.allSatisfy(\.isFinite) { out += x+[1] }
        else { out += [Double](repeating:0,count:51) }
        return out.count == 80 && out.allSatisfy(\.isFinite) ? out:nil
    }
    static func polygon(residual: [Double], current: [[Double]], frame: [Double]) -> [[Double]]? {
        guard let s = basis(current), residual.count == 5, residual.allSatisfy(\.isFinite),
              frame.count == 2, frame.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let b = (0..<4).map { s.bounds[$0]+s.width*residual[$0] }
        guard b[1] > b[0], b[3] > b[2] else { return nil }
        let ca = cos(residual[4]), sa = sin(residual[4])
        func rotate(_ v: [Double]) -> [Double] { [ca*v[0]-sa*v[1],sa*v[0]+ca*v[1]] }
        let n = rotate(s.normal), a = rotate(s.along)
        let q = [(b[0],b[2]),(b[1],b[2]),(b[1],b[3]),(b[0],b[3])].map { u,v in [s.center[0]+u*n[0]+v*a[0],s.center[1]+u*n[1]+v*a[1]] }
        guard q.allSatisfy({ $0.allSatisfy(\.isFinite) && $0[0] >= 0 && $0[1] >= 0 && $0[0] <= frame[0] && $0[1] <= frame[1] }) else { return nil }
        return q
    }
}
