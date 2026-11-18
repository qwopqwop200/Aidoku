import CoreGraphics
import Foundation

/// Geometry-only local coordinates. No page IDs, labels, text substitutions,
/// detector confidence changes, or automatic upside-down text classification.
enum NativeOCRDirectionGeometry {
    static let policyVersion = "local-direction-v6-manga-production-default"
    @TaskLocal static var mainMangaPolicy = false
    static let paths = ["quoted", "lanes", "missing", "narrow", "large",
                        "dbquad", "quad", "latin", "single", "orientation", "rfOverlap",
                        "groups", "splitJoin", "rfShape", "mixedDirections", "unanchored", "pixelLocal"]

    static func enabled(_ path: String) -> Bool {
        // Explicit A/B selections override the full-frame manga default.
        // Other model tiers and scoped recognition keep their own policy.
        guard let value = ProcessInfo.processInfo.environment["AIDOKU_OCR_ORIENTED_PATHS"] else {
            return mainMangaPolicy && paths.contains(path)
        }
        return value == "all" || value.split(separator: ",").contains(Substring(path))
    }

    static func bounds(_ points: [CGPoint]) -> CGRect {
        points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    static func area(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 3 else { return 0 }
        return abs(polygon.indices.reduce(CGFloat.zero) { value, i in
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            return value + a.x * b.y - a.y * b.x
        }) / 2
    }

    /// Clip the actual convex detector quad, not its screen-axis envelope.
    /// RF queries are axis-aligned detector regions and remain unchanged.
    static func intersectionArea(_ polygon: [CGPoint], _ rect: CGRect) -> CGFloat {
        guard let cycle = cycle(polygon), !rect.isEmpty, !rect.isNull else { return 0 }
        var result = cycle
        for edge in 0..<4 {
            let limit = [rect.minX, rect.maxX, rect.minY, rect.maxY][edge]
            func distance(_ p: CGPoint) -> CGFloat {
                switch edge {
                case 0: return p.x - limit
                case 1: return limit - p.x
                case 2: return p.y - limit
                default: return limit - p.y
                }
            }
            let input = result
            result = []
            guard !input.isEmpty else { return 0 }
            var previous = input.last!, previousDistance = distance(previous)
            for point in input {
                let currentDistance = distance(point)
                if (previousDistance >= 0) != (currentDistance >= 0) {
                    let fraction = previousDistance / (previousDistance - currentDistance)
                    result.append(CGPoint(x: previous.x + (point.x - previous.x) * fraction,
                                          y: previous.y + (point.y - previous.y) * fraction))
                }
                if currentDistance >= 0 { result.append(point) }
                previous = point
                previousDistance = currentDistance
            }
        }
        return area(result)
    }

    static func coverage(_ polygon: [CGPoint], by rect: CGRect) -> CGFloat {
        let denominator = area(polygon)
        return denominator > 0 ? min(1, intersectionArea(polygon, rect) / denominator) : 0
    }

    /// Convex support is transported as a polygon. Its envelope is only an ROI.
    static func intersectionArea(_ polygon: [CGPoint], _ support: [CGPoint]) -> CGFloat {
        guard let clip = cycle(support), let subject = cycle(polygon) else { return 0 }
        var result = subject
        for i in clip.indices {
            let a = clip[i], b = clip[(i+1)%clip.count]
            func d(_ p: CGPoint) -> CGFloat { (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x) }
            let input = result
            guard var previous = input.last else { return 0 }
            result = []
            var dp = d(previous)
            for p in input {
                let dc = d(p)
                if (dc >= 0) != (dp >= 0) {
                    let t = dp/(dp-dc)
                    result.append(CGPoint(x:previous.x+(p.x-previous.x)*t,y:previous.y+(p.y-previous.y)*t))
                }
                if dc >= 0 { result.append(p) }
                previous = p; dp = dc
            }
        }
        return area(result)
    }

    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        Containment(polygon)?.contains(point) == true
    }

    /// Reuse the same validated winding while sampling many points. Rebuilding
    /// a quad's cycle for every probability cell changes no geometric evidence.
    struct Containment {
        private let corners: [CGPoint]

        init?(_ polygon: [CGPoint]) {
            guard let corners = NativeOCRDirectionGeometry.cycle(polygon) else { return nil }
            self.corners = corners
        }

        func contains(_ point: CGPoint) -> Bool {
            for i in 0..<4 {
                let a = corners[i], b = corners[(i+1)%4]
                if !((b.x-a.x)*(point.y-a.y)-(b.y-a.y)*(point.x-a.x) >= -0.000001) { return false }
            }
            return true
        }
    }

    static func compatible(_ polygon: [CGPoint], with frame: Frame) -> Bool {
        guard let q = readingQuad(polygon, vertical:true), let f = Frame(q),
              f.rect.height >= f.rect.width*1.2 else { return false }
        // Detector quads within one text direction can differ slightly in tilt.
        // This is membership tolerance, never permission to rotate an owner quad.
        return abs(f.along.x*frame.along.x+f.along.y*frame.along.y) >= cos(.pi/12) - 0.000001 // fifteen degrees
    }

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

    static func directedQuad(_ points: [CGPoint], longAlong: Bool? = nil) -> [CGPoint]? {
        guard let q = cycle(points) else { return nil }
        guard let longAlong else { return q }
        let a = hypot(q[1].x-q[0].x,q[1].y-q[0].y)+hypot(q[2].x-q[3].x,q[2].y-q[3].y)
        let b = hypot(q[2].x-q[1].x,q[2].y-q[1].y)+hypot(q[3].x-q[0].x,q[3].y-q[0].y)
        if (longAlong && b >= a) || (!longAlong && a >= b) { return q }
        // Cross-edge and along-edge exchange without reflection or AABB loss.
        return [q[3], q[0], q[1], q[2]]
    }

    /// A detector's cyclic vertex index is NOT a measured reading direction.
    /// Resolve an untyped detection to the established upright reading basis,
    /// independently of its first vertex, without flattening/reshaping the quad.
    /// Trusted local-axis crops instead use directedQuad/useProvidedOrder and
    /// retain their explicit direction, including rotations beyond 90 degrees.
    static func readingQuad(_ points: [CGPoint], vertical: Bool? = nil) -> [CGPoint]? {
        guard let q = cycle(points) else { return nil }
        let lengths = (0..<4).map { hypot(q[($0+1)%4].x-q[$0].x,q[($0+1)%4].y-q[$0].y) }
        guard let shortest = lengths.min(), let longest = lengths.max(), shortest > 0 else { return nil }
        let candidates = (0..<4).filter { i in
            let dx=q[(i+1)%4].x-q[i].x, dy=q[(i+1)%4].y-q[i].y
            guard dx > 0 || (vertical != nil && abs(dx) <= 0.000001 && dy < 0 &&
                ["groups","splitJoin","rfShape","mixedDirections","unanchored","pixelLocal"].contains(where:enabled)) else { return false }
            guard let vertical, longest > shortest*1.25 else { return true }
            return vertical ? lengths[i] < (shortest+longest)/2 : lengths[i] > (shortest+longest)/2
        }
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

    static func edgeSize(_ points: [CGPoint]) -> CGSize? {
        guard let p = cycle(points) else { return nil }
        return CGSize(width: (hypot(p[1].x-p[0].x,p[1].y-p[0].y)+hypot(p[2].x-p[3].x,p[2].y-p[3].y))/2,
                      height: (hypot(p[3].x-p[0].x,p[3].y-p[0].y)+hypot(p[2].x-p[1].x,p[2].y-p[1].y))/2)
    }

    struct Frame {
        let origin: CGPoint
        let across: CGPoint
        let along: CGPoint
        let rect: CGRect
        let quad: [CGPoint]

        init?(_ points: [CGPoint], longAlong: Bool = true) {
            guard let q = directedQuad(points, longAlong: longAlong) else { return nil }
            let head = CGPoint(x:(q[0].x+q[1].x)/2,y:(q[0].y+q[1].y)/2)
            let foot = CGPoint(x:(q[2].x+q[3].x)/2,y:(q[2].y+q[3].y)/2)
            let length = hypot(foot.x-head.x,foot.y-head.y)
            guard length > 0.000001 else { return nil }
            let v = CGPoint(x:(foot.x-head.x)/length,y:(foot.y-head.y)/length)
            let u = CGPoint(x:v.y,y:-v.x)
            origin = head; along = v; across = u; quad = q
            rect = NativeOCRDirectionGeometry.bounds(q.map {
                let d = CGPoint(x:$0.x-head.x,y:$0.y-head.y)
                return CGPoint(x:d.x*u.x+d.y*u.y,y:d.x*v.x+d.y*v.y)
            })
        }

        func project(_ p: CGPoint) -> CGPoint {
            let d = CGPoint(x:p.x-origin.x,y:p.y-origin.y)
            return CGPoint(x:d.x*across.x+d.y*across.y,y:d.x*along.x+d.y*along.y)
        }
        func restore(_ p: CGPoint) -> CGPoint {
            CGPoint(x:origin.x+across.x*p.x+along.x*p.y,y:origin.y+across.y*p.x+along.y*p.y)
        }
        func bounds(_ p: [CGPoint]) -> CGRect { NativeOCRDirectionGeometry.bounds(p.map(project)) }
    }

    /// A bounded virtual raster in the anchor's basis. The original image and
    /// original DB probability cells stay immutable; this is sampling only.
    struct Window {
        let frame: Frame
        let rect: CGRect
        let width: Int
        let height: Int
        init?(frame: Frame, world: CGRect, maximumPixels: Int = 4_194_304,
              lattice: CGSize? = nil, latticeOrigin: CGPoint = .zero) {
            self.frame = frame
            let requested = frame.bounds(corners(world)).insetBy(dx:-1,dy:-1)
            if let lattice, lattice.width >= 1, lattice.height >= 1 {
                let origin = frame.project(latticeOrigin)
                let left = origin.x + floor((requested.minX-origin.x)/lattice.width)*lattice.width
                let top = origin.y + floor((requested.minY-origin.y)/lattice.height)*lattice.height
                rect = CGRect(x:left,y:top,
                    width:ceil((requested.maxX-left)/lattice.width)*lattice.width,
                    height:ceil((requested.maxY-top)/lattice.height)*lattice.height)
            } else { rect = requested.integral }
            width = Int(ceil(rect.width)); height = Int(ceil(rect.height))
            guard width > 0, height > 0, width <= maximumPixels / height else { return nil }
        }
        func project(_ p: CGPoint) -> CGPoint {
            let q = frame.project(p); return CGPoint(x:q.x-rect.minX,y:q.y-rect.minY)
        }
        func restore(_ p: CGPoint) -> CGPoint { frame.restore(CGPoint(x:p.x+rect.minX,y:p.y+rect.minY)) }
        func bounds(_ p: [CGPoint]) -> CGRect { NativeOCRDirectionGeometry.bounds(p.map(project)) }
        func rgba(_ bytes: [UInt8], width sourceWidth: Int, height sourceHeight: Int, stride: Int) -> [UInt8]? {
            guard stride >= sourceWidth*4, bytes.count >= stride*sourceHeight else { return nil }
            var result = [UInt8](repeating:255,count:width*height*4)
            for y in 0..<height { for x in 0..<width {
                let p = restore(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
                let xx = Int(floor(p.x)), yy = Int(floor(p.y))
                guard xx >= 0, yy >= 0, xx < sourceWidth, yy < sourceHeight else { continue }
                for c in 0..<4 { result[(y*width+x)*4+c] = bytes[yy*stride+xx*4+c] }
            } }
            return result
        }
    }
}
