import CoreGraphics
import Foundation

/// Tighten only the source-normal envelope. The caller retains the adopted
/// polygon as its no-op and applies the shared source/cap/foreground guards.
@available(iOS 18.0, *)
enum NativeOCRResidualNormalContraction {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement
    typealias Component = NativeOCRSourceComponentMeasurements.Component

    static func candidates(_ m: Measurement) -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", m.polygon.count == 4,
              m.step.isFinite, m.step > 0, valid(m.rect),
              m.polygon.allSatisfy({ finite($0) }),
              m.privateHull.allSatisfy({ finite($0) }),
              m.guardPoints.allSatisfy({ finite($0) }) else { return [] }
        let width = m.rect.width
        let components = m.components.filter { valid($0.bounds) && !$0.hull.isEmpty && $0.hull.allSatisfy({ finite($0) }) }
        let primary = components.filter { c in
            Double(c.ownedPixels) >= max(2, min(8, Double(c.pixels) * 0.04)) &&
                c.insidePixels >= 2 && normalOverlap(c.bounds, m.rect) >= min(c.bounds.width, width) * 0.4
        }
        guard !primary.isEmpty else { return [] }
        let top = primary.map(\.bounds.minY).min()!, bottom = primary.map(\.bounds.maxY).max()!
        // A few isolated samples must not stand in for a complete glyph chain.
        guard bottom - top >= max(width * 0.5, m.rect.height * 0.45) else { return [] }

        let visible = components.filter { c in
            guard c.foreignPixels == 0, c.insidePixels >= 2,
                  normalOverlap(c.bounds, m.rect) >= min(c.bounds.width, width) * 0.4 else { return false }
            return primary.contains { source in
                let samePalette = NativeOCRSourceComponentMeasurements.colourDistance(c.colour, source.colour) <= 40
                // A differently colored enclosing component may be the outer
                // outline. Keep its complete bounds, not just interior seed cells.
                let enclosingShell = c.bounds.contains(source.center) &&
                    c.bounds.width >= source.bounds.width && c.bounds.height >= source.bounds.height
                return samePalette || enclosingShell
            }
        }
        let selected = primary + visible
        // Component bounds enclose whole sampled pixel cells; hull vertices alone
        // describe their centers. Never fit a median width or discard broad caps.
        let points = selected.flatMap(\.hull) + m.privateHull + m.guardPoints.map(m.project)
        guard !points.isEmpty, points.allSatisfy({ finite($0) }) else { return [] }
        let minimum = min(selected.map(\.bounds.minX).min()!, points.map(\.x).min()!)
        let maximum = max(selected.map(\.bounds.maxX).max()!, points.map(\.x).max()!)
        let local = m.polygon.map(m.project)
        guard local.allSatisfy({ finite($0) }) else { return [] }
        let support = points.map(m.restore)
        var result: [NativeOCRResidualCandidate] = []
        // Two stable sampling/width-normalized margins. No endpoint or axis fit.
        for (key, sampleMargin, widthMargin) in [
            ("normal-complete-v1-s050-w010", CGFloat(0.5), CGFloat(0.01)),
            ("normal-complete-v1-s100-w025", CGFloat(1), CGFloat(0.025))
        ] {
            let margin = max(m.step * sampleMargin, width * widthMargin)
            let lo = max(m.rect.minX, minimum - margin), hi = min(m.rect.maxX, maximum + margin)
            guard lo.isFinite, hi.isFinite, hi > lo,
                  width - (hi - lo) > max(1e-6, m.step * 0.1) else { continue }
            let scale = (hi - lo) / width
            let polygon = local.map { p in
                m.restore(.init(x: lo + (p.x - m.rect.minX) * scale, y: p.y))
            }
            guard polygon.allSatisfy({ finite($0) && $0.x >= 0 && $0.y >= 0 }) else { continue }
            result.append(.init(key: key, polygon: polygon, supportPoints: support))
        }
        return result
    }

    private static func finite(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite }

    private static func valid(_ r: CGRect) -> Bool {
        r.origin.x.isFinite && r.origin.y.isFinite && r.width.isFinite && r.height.isFinite && r.width > 0 && r.height > 0
    }

    private static func normalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }
}
