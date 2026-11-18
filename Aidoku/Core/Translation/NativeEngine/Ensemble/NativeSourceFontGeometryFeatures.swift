import CoreGraphics
import Foundation

/// Cheap physical geometry scalars for font calibration. No font/model loads,
/// glyph/PCA measurements, pixels, text literals or typography decisions.
enum NativeSourceFontGeometryFeatures {
    enum Failure: Error { case invalidBounds, invalidPolygon }
    static let identity = "font-source-bbox-short-v1"
    static let memberIdentity = "font-source-member-hull-minarea-area-median-v2"

    static func shortSide(bounds: CGRect) throws -> Double {
        let width = Double(bounds.size.width), height = Double(bounds.size.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw Failure.invalidBounds }
        return min(width, height)
    }

    struct OrientedBox: Sendable {
        let short: Double
        let long: Double
        let area: Double
    }

    private static func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> Double {
        Double(b.x - a.x) * Double(p.y - a.y) - Double(b.y - a.y) * Double(p.x - a.x)
    }

    /// Preserve exact point order for already-convex source polygons. The
    /// factory also permits general finite polygons, whose min-area rectangle
    /// must enumerate CONVEX HULL edges, not just original concave edges.
    static func enclosingHull(_ polygon: [CGPoint]) -> [CGPoint] {
        let signedArea = polygon.indices.reduce(0.0) { partial, i in
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            return partial + Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        let sign = signedArea > 0 ? 1.0 : -1.0
        if signedArea != 0 && polygon.indices.allSatisfy({ i in
            polygon.allSatisfy { sign * cross(polygon[i], polygon[(i + 1) % polygon.count], $0) >= -1e-9 }
        }) { return polygon }
        let sorted = polygon.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        var unique: [CGPoint] = []
        for point in sorted where unique.last != point { unique.append(point) }
        guard unique.count > 2 else { return unique }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for point in unique {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in unique.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }

    /// Source geometry only, never a glyph model.
    /// Subtract each edge origin before projection to avoid page-position error.
    static func orientedBox(_ polygon: [CGPoint]) throws -> OrientedBox? {
        guard (3...256).contains(polygon.count), polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw Failure.invalidPolygon
        }
        let polygon = enclosingHull(polygon)
        guard polygon.count >= 3 else { return nil }
        var best: OrientedBox?
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y), length = hypot(dx, dy)
            if length <= 1e-9 { continue }
            let ux = dx / length, uy = dy / length
            var xmin = Double.infinity, xmax = -Double.infinity
            var ymin = Double.infinity, ymax = -Double.infinity
            for point in polygon {
                let x = Double(point.x - a.x), y = Double(point.y - a.y)
                let px = x * ux + y * uy, py = -x * uy + y * ux
                xmin = min(xmin, px); xmax = max(xmax, px)
                ymin = min(ymin, py); ymax = max(ymax, py)
            }
            let width = xmax - xmin, height = ymax - ymin, area = width * height
            if width <= 1e-9 || height <= 1e-9 { continue }
            guard area.isFinite else { throw Failure.invalidPolygon }
            if best == nil || area < best!.area - 1e-9 {
                best = OrientedBox(short: min(width, height), long: max(width, height), area: area)
            }
        }
        return best
    }

    /// Area-weighted median of actual source-member physical thickness. Missing
    /// members return nil; the estimator explicitly falls back to geometry prior,
    /// never manufactures a measured zero or an accepted-font feature context.
    static func memberShortMedian(_ polygons: [[CGPoint]]) throws -> Double? {
        guard polygons.count <= 256 else { throw Failure.invalidPolygon }
        let observed = try polygons.compactMap { try orientedBox($0) }
        guard !observed.isEmpty else { return nil }
        let target = observed.reduce(0) { $0 + $1.area } * 0.5
        let boxes = observed.sorted { $0.short == $1.short ? $0.area < $1.area : $0.short < $1.short }
        var mass = 0.0
        for box in boxes {
            mass += box.area
            if mass >= target { return box.short }
        }
        return boxes.last?.short
    }
}
