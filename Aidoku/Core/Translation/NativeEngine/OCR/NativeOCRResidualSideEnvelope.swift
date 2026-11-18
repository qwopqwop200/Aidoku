import CoreGraphics
import Foundation

/// Small four-side menu around complete source-supported glyphs. Side positions
/// come from full component hulls, never clipped glyph quantiles or target labels.
@available(iOS 18.0, *)
enum NativeOCRResidualSideEnvelope {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement
    typealias Component = NativeOCRSourceComponentMeasurements.Component

    static func candidates(_ m: Measurement) -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", m.step.isFinite, m.step > 0,
              m.rect.width.isFinite, m.rect.height.isFinite,
              m.rect.width >= 5, m.rect.height >= 5 else { return [] }
        let seeds = m.components.filter { c in
            c.foreignPixels == 0 && c.insidePixels >= 2 && !c.hull.isEmpty &&
                Double(c.ownedPixels) >= max(2, min(8, Double(c.pixels) * 0.04)) && overlaps(c.bounds, m.rect)
        }
        guard !seeds.isEmpty else { return [] }
        var colours: [SIMD3<Int>] = []
        for c in seeds where !colours.contains(c.colour) { colours.append(c.colour) }
        let complete = m.components.filter { c in
            c.foreignPixels == 0 && c.insidePixels >= 2 && !c.hull.isEmpty && overlaps(c.bounds, m.rect) &&
                colours.contains { NativeOCRSourceComponentMeasurements.colourDistance(c.colour, $0) <= 40 }
        }
        guard !complete.isEmpty else { return [] }
        // Private cells and already visible same-palette ink remain protected even
        // when they are absent from the complete-component selection above.
        let local = complete.flatMap(\.hull) + m.privateHull +
            (m.guardPoints + NativeOCRSourceComponentBounds.visibleForeground(m)).map(m.project)
        guard local.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), !local.isEmpty else { return [] }
        let protectedHull = NativeOCRSourceComponentMeasurements.convexHull(local)
        let support = protectedHull.map(m.restore)
        let envelope = NativeOCRSourceComponentBounds.bounds(protectedHull)
        guard envelope.width > 0, envelope.height > 0 else { return [] }
        // Ink area / hull perimeter is an observed thickness proxy, not a claimed
        // pen-width estimate. Median affects padding only; no glyph is discarded.
        let thicknesses = seeds.compactMap { c -> CGFloat? in
            guard c.hull.count >= 3, c.pixels > 0 else { return nil }
            let perimeter = c.hull.indices.reduce(CGFloat(0)) { total, i in
                let a = c.hull[i], b = c.hull[(i + 1) % c.hull.count]
                return total + hypot(b.x - a.x, b.y - a.y)
            }
            guard perimeter.isFinite, perimeter > 0 else { return nil }
            return min(m.rect.width * 0.12, max(m.step * 0.5, CGFloat(c.pixels) * m.step * m.step * 2 / perimeter))
        }
        let thickness = thicknesses.isEmpty ? m.step : NativeOCRSourceComponentBounds.median(thicknesses)
        let margins: [(String, CGFloat)] = [
            ("grid", m.step * 0.5),
            ("ink-quarter", max(m.step, thickness * 0.25)),
            ("ink-half", max(m.step * 1.5, thickness * 0.5))
        ]
        var result: [NativeOCRResidualCandidate] = []
        for (name, margin) in margins {
            let e = envelope.insetBy(dx: -margin, dy: -margin), old = m.rect
            let sides: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                ("normal", e.minX, old.minY, e.maxX, old.maxY),
                ("left", e.minX, old.minY, old.maxX, old.maxY),
                ("right", old.minX, old.minY, e.maxX, old.maxY),
                ("head", old.minX, e.minY, old.maxX, old.maxY),
                ("tail", old.minX, old.minY, old.maxX, e.maxY),
                ("full", e.minX, e.minY, e.maxX, e.maxY),
                ("normal-head", e.minX, e.minY, e.maxX, old.maxY),
                ("normal-tail", e.minX, old.minY, e.maxX, e.maxY)
            ]
            for (mode, left, top, right, bottom) in sides {
                guard right > left, bottom > top else { continue }
                let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                // The menu corrects local margins, not membership or distant text.
                guard rect.width >= m.rect.width * 0.35, rect.width <= m.rect.width * 1.7,
                      rect.height >= m.rect.height * 0.5, rect.height <= m.rect.height * 1.35,
                      protectedHull.allSatisfy({ p in
                          p.x >= left - 1e-7 && p.x <= right + 1e-7 && p.y >= top - 1e-7 && p.y <= bottom + 1e-7
                      }) else { continue }
                let polygon = [CGPoint(x: left, y: top), CGPoint(x: right, y: top),
                               CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)].map(m.restore)
                guard polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 }),
                      !same(polygon, m.polygon), !result.contains(where: { same($0.polygon, polygon) }) else { continue }
                result.append(.init(key: "side-envelope-v1-\(mode)-\(name)", polygon: polygon, supportPoints: support))
            }
        }
        return result
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let normal = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        return normal >= min(a.width, b.width) * 0.4
    }

    private static func same(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) <= 1e-6 }
    }
}
