import CoreGraphics
import Foundation

/// Normal-only alternatives supported by original owned pixels and closed glyph shells.
/// Every proposal preserves the incoming along endpoints and its semantic basis.
@available(iOS 18.0, *)
enum NativeOCRResidualNormalExpansion {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement

    static func candidates(_ m: Measurement) -> [NativeOCRResidualCandidate] {
        var result = [NativeOCRResidualCandidate(key: "normal.keep", polygon: m.polygon)]
        if let candidate = expansion(m, evidence: m, limit: 0.35, key: "normal.owned-shell.v1") {
            result.append(candidate)
        }
        return result
    }

    static func candidates(_ m: Measurement, context: NativeOCRResidualSourceContext) -> [NativeOCRResidualCandidate] {
        var result = candidates(m)
        guard m.status == "measured", m.rect.width > 0, m.rect.height > m.rect.width * 2 else { return result }
        // The measurement kernel supplies its own bounded sampling context. Widen only
        // the requested normal interval; neither this request nor the result extends along.
        for margin: CGFloat in [0.25, 0.35] {
            let roi = m.rect.insetBy(dx: -m.rect.width * margin, dy: 0)
            guard roi.width < roi.height,
                  let measured = context.measure(m.index, polygon(roi, in: m)), measured.status == "measured",
                  let candidate = expansion(m, evidence: measured, limit: margin,
                    key: margin == 0.25 ? "normal.owned-shell.context25.v1" : "normal.owned-shell.context35.v1"),
                  !result.contains(where: { same($0.polygon, candidate.polygon) }) else { continue }
            result.append(candidate)
        }
        return result
    }

    private static func expansion(_ anchor: Measurement, evidence: Measurement, limit: CGFloat,
                                  key: String) -> NativeOCRResidualCandidate? {
        let rect = anchor.rect, width = rect.width
        guard anchor.status == "measured", evidence.status == "measured", width >= 5,
              rect.height > 0, anchor.polygon.count == 4 else { return nil }
        struct Ink {
            let component: NativeOCRSourceComponentMeasurements.Component
            let points: [CGPoint]
            let bounds: CGRect
        }
        let ink: [Ink] = evidence.components.compactMap { component in
            guard component.foreignPixels == 0, !component.hull.isEmpty else { return nil }
            let points = component.hull.map { anchor.project(evidence.restore($0)) }
            let bounds = bounds(points)
            guard bounds.width > 0, bounds.height > 0,
                  bounds.width <= width * 1.7, bounds.height <= width * 2.2,
                  bounds.maxY >= rect.minY, bounds.minY <= rect.maxY else { return nil }
            return Ink(component: component, points: points, bounds: bounds)
        }
        let owned = ink.filter { item in
            let threshold = max(2, min(8, Double(item.component.pixels) * 0.04))
            let overlap = max(0, min(item.bounds.maxX, rect.maxX) - max(item.bounds.minX, rect.minX))
            return Double(item.component.ownedPixels) >= threshold &&
                overlap >= min(item.bounds.width, width) * 0.4
        }
        guard !owned.isEmpty else { return nil }
        let supported = ink.filter { item in
            if item.component.ownedPixels >= max(2, min(8, Int(Double(item.component.pixels) * 0.04))) { return true }
            // An unowned outline must geometrically enclose an owned glyph fragment,
            // or be a nearby fragment of that same source palette. Never flood fill
            // white/background components or grow from unowned shells recursively.
            return owned.contains { seed in
                let a = item.bounds, b = seed.bounds
                let xOverlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
                let yOverlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
                guard xOverlap >= min(a.width, b.width) * 0.6,
                      yOverlap >= min(a.height, b.height) * 0.6,
                      abs(a.midX - b.midX) <= width * 0.2,
                      a.minX >= b.minX - width * 0.25 - 1e-7, a.maxX <= b.maxX + width * 0.25 + 1e-7,
                      a.minY >= b.minY - width * 0.25 - 1e-7, a.maxY <= b.maxY + width * 0.25 + 1e-7 else { return false }
                let samePalette = NativeOCRSourceComponentMeasurements.colourDistance(item.component.colour, seed.component.colour) <= 40
                let encloses = a.contains(CGPoint(x: b.midX, y: b.midY)) &&
                    a.width >= b.width && a.height >= b.height &&
                    CGFloat(item.component.pixels) * evidence.step * evidence.step <= a.width * a.height * 0.8
                return samePalette || encloses
            }
        }
        let support = supported.flatMap(\.points).filter { $0.y >= rect.minY && $0.y <= rect.maxY }
        guard !support.isEmpty else { return nil }
        // A half sampling cell accounts for the measured pixel footprint, not crop padding.
        let radius = evidence.step * 0.5
        let left = min(rect.minX, support.map(\.x).min()! - radius)
        let right = max(rect.maxX, support.map(\.x).max()! + radius)
        guard left >= rect.minX - width * limit, right <= rect.maxX + width * limit,
              rect.minX - left > 0.5 || right - rect.maxX > 0.5 else { return nil }
        let expanded = CGRect(x: left, y: rect.minY, width: right - left, height: rect.height)
        let quad = polygon(expanded, in: anchor)
        guard quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 }) else { return nil }
        // Include the original quad so nonrectangular incoming corners remain protected.
        guard anchor.polygon.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(quad, $0, tolerance: 0.001) }) else { return nil }
        return NativeOCRResidualCandidate(key: key, polygon: quad, supportPoints: support.map(anchor.restore))
    }

    private static func polygon(_ rect: CGRect, in m: Measurement) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map(m.restore)
    }

    private static func bounds(_ points: [CGPoint]) -> CGRect {
        let left = points.map(\.x).min()!, top = points.map(\.y).min()!
        return CGRect(x: left, y: top, width: points.map(\.x).max()! - left, height: points.map(\.y).max()! - top)
    }

    private static func same(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.5 }
    }
}
