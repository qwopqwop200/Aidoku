import CoreGraphics
import Foundation

enum NativeSlantedGeometry {
    final class Failures { var reasons: [String] = [] }
    struct Options {
        var failures: Failures?
        var auxiliary: [[Double]] = []
        var auxiliaryPolygons: [[[Double]]] = []
        var inferredRubyExclusions: [[Double]] = []
        var inferRuby = false
        var cover: [Double]?
        var chromaticBalloon = false
    }
    struct Local {
        let width: Int
        let height: Int
        let box: [Double]
        let auxiliary: [[Double]]
        let exclusions: [[Double]]
    }
    static func valid(_ r: [Double]) -> Bool { r.count == 4 && r.allSatisfy(\.isFinite) && r[2] > 0 && r[3] > 0 }
    static func stable(_ v: Double) -> Double { floor(v * 1e7 + 0.5) / 1e7 }
    static func localGeometry(box: [Double], angle: Double, vertical: Bool = false, options: Options = Options()) -> Local {
        let invalid = Local(width: 0, height: 0, box: [], auxiliary: [], exclusions: [])
        guard valid(box), angle.isFinite else { return invalid }
        let c = cos(angle), s = sin(angle), cx = box[0] + box[2] / 2, cy = box[1] + box[3] / 2
        func transform(_ r: [Double]) -> [[Double]] {
            [[r[0], r[1]], [r[0] + r[2], r[1]], [r[0] + r[2], r[1] + r[3]], [r[0], r[1] + r[3]]].map { point in
                [(point[0] - cx) * c + (point[1] - cy) * s + box[2] / 2,
                 -(point[0] - cx) * s + (point[1] - cy) * c + box[3] / 2]
            }
        }
        var auxiliary = options.auxiliary.filter(valid).prefix(32).map { r -> [[Double]] in
            let q = transform(r), ac = abs(c), asin = abs(s), det = ac * ac - asin * asin
            let rw = (r[2] * ac - r[3] * asin) / det, rh = (r[3] * ac - r[2] * asin) / det
            if abs(det) >= 0.15 && rw >= 2 && rh >= 2 && rw <= box[2] * 1.2 && rh <= box[3] * 1.2 {
                let x = q.reduce(0) { $0 + $1[0] } / 4, y = q.reduce(0) { $0 + $1[1] } / 4
                return [[x - rw / 2, y - rh / 2], [x + rw / 2, y - rh / 2], [x + rw / 2, y + rh / 2], [x - rw / 2, y + rh / 2]]
            }
            return q
        }
        let polygons = options.auxiliaryPolygons.filter { $0.count == 4 && $0.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) } }.prefix(32)
        if !polygons.isEmpty {
            auxiliary = polygons.map { q in q.map { point in
                [(point[0] - cx) * c + (point[1] - cy) * s + box[2] / 2,
                 -(point[0] - cx) * s + (point[1] - cy) * c + box[3] / 2]
            } }
        }
        let exclusions = options.inferredRubyExclusions.filter(valid).prefix(256).map(transform)
        let ruby = options.inferRuby ? min(96, (vertical ? box[2] : box[3]) * 0.8) : 0
        let cover = options.cover.flatMap { valid($0) ? transform($0) : nil } ?? []
        let extent = auxiliary.flatMap { $0 } + cover
        let left = min(0, extent.map { $0[0] }.min() ?? .infinity) - 24
        let top = min(vertical ? 0 : -ruby, extent.map { $0[1] }.min() ?? .infinity) - 24
        let right = max(box[2] + (vertical ? ruby : 0), extent.map { $0[0] }.max() ?? -.infinity) + 24
        let bottom = max(box[3], extent.map { $0[1] }.max() ?? -.infinity) + 24
        let spanX = stable(right - left), spanY = stable(bottom - top)
        let roundedWidth = ceil(spanX), roundedHeight = ceil(spanY)
        guard roundedWidth.isFinite, roundedHeight.isFinite, roundedWidth > 0, roundedHeight > 0,
              roundedWidth < Double(Int.max), roundedHeight < Double(Int.max),
              roundedWidth <= Double(Int.max) / roundedHeight else { return invalid }
        let lw = Int(roundedWidth), lh = Int(roundedHeight)
        guard lw <= Int.max / lh else { return invalid }
        let dx = (Double(lw) - spanX) / 2, dy = (Double(lh) - spanY) / 2
        func bounds(_ q: [[Double]]) -> [Double] {
            let xs = q.map { $0[0] - left + dx }, ys = q.map { $0[1] - top + dy }
            return [xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!].map(stable)
        }
        return Local(width: lw, height: lh, box: [-left + dx, -top + dy, box[2], box[3]].map(stable),
                     auxiliary: auxiliary.map(bounds), exclusions: exclusions.map(bounds))
    }

    static func rotatedCard(cx: Double, cy: Double, width: Double, height: Double, angle: Double, margin: Double = 0) -> [[Double]] {
        let c = cos(angle), s = sin(angle), a = width / 2 + margin, b = height / 2 + margin
        return [[-a, -b], [a, -b], [a, b], [-a, b]].map { [cx + $0[0] * c - $0[1] * s, cy + $0[0] * s + $0[1] * c] }
    }
    static func convexOverlap(_ p: [[Double]], _ q: [[Double]]) -> Bool {
        if p.isEmpty || q.isEmpty { return p.isEmpty && q.isEmpty }
        for poly in [p, q] { for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count], nx = b[1] - a[1], ny = a[0] - b[0]
            let pd = p.map { $0[0] * nx + $0[1] * ny }, qd = q.map { $0[0] * nx + $0[1] * ny }
            if pd.max()! <= qd.min()! || qd.max()! <= pd.min()! { return false }
        } }
        return true
    }
    static func convexDepth(_ p: [[Double]], _ q: [[Double]]) -> Double {
        if p.isEmpty || q.isEmpty { return p.isEmpty && q.isEmpty ? .infinity : 0 }
        var least = Double.infinity
        for poly in [p, q] { for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count], length = hypot(b[0] - a[0], b[1] - a[1])
            let divisor = length == 0 ? 1 : length, nx = (b[1] - a[1]) / divisor, ny = (a[0] - b[0]) / divisor
            let pd = p.map { $0[0] * nx + $0[1] * ny }, qd = q.map { $0[0] * nx + $0[1] * ny }
            if pd.max()! <= qd.min()! || qd.max()! <= pd.min()! { return 0 }
            least = min(least, pd.max()! - qd.min()!, qd.max()! - pd.min()!)
        } }
        return least
    }
    static func pointInConvex(_ poly: [[Double]], point: [Double]) -> Bool {
        var sign = 0
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let c = (b[0] - a[0]) * (point[1] - a[1]) - (b[1] - a[1]) * (point[0] - a[0])
            if abs(c) < 1e-9 { continue }
            let current = c < 0 ? -1 : 1
            if sign != 0 && current != sign { return false }
            sign = current
        }
        return true
    }
    static func clipConvex(subject: [[Double]], clip: [[Double]]) -> [[Double]] {
        var area = 0.0
        for i in clip.indices { let a = clip[i], b = clip[(i + 1) % clip.count]; area += a[0] * b[1] - a[1] * b[0] }
        let winding = area < 0 ? -1.0 : 1.0
        var out = subject
        for i in clip.indices {
            if out.isEmpty { break }
            let a = clip[i], b = clip[(i + 1) % clip.count]
            func side(_ p: [Double]) -> Double { ((b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])) * winding }
            let input = out; out = []
            for j in input.indices {
                let p = input[j], q = input[(j + 1) % input.count], sp = side(p), sq = side(q)
                if sp >= 0 { out.append(p) }
                if (sp >= 0) != (sq >= 0) { let t = sp / (sp - sq); out.append([p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t]) }
            }
        }
        return out
    }
    static func localRects(_ rects: [[Double]], box: [Double], angle: Double) -> [[Double]] {
        let c = cos(angle), s = sin(angle), cx = box[0] + box[2] / 2, cy = box[1] + box[3] / 2
        return rects.map { r in
            let q = [[r[0], r[1]], [r[2], r[1]], [r[2], r[3]], [r[0], r[3]]].map { point in
                [(point[0] - cx) * c + (point[1] - cy) * s + box[2] / 2,
                 -(point[0] - cx) * s + (point[1] - cy) * c + box[3] / 2]
            }
            return [q.map { $0[0] }.min()!, q.map { $0[1] }.min()!, q.map { $0[0] }.max()!, q.map { $0[1] }.max()!]
        }
    }
    static func rect(_ r: [Double]) -> CGRect { CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
    static func array(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
}
