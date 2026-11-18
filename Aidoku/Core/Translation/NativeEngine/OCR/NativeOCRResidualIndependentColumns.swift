import CoreGraphics
import Foundation

/// Independent-column alternatives. All geometry stays in the measured source frame;
/// ownership support is a view of authentic DB components, never a detector-box union.
@available(iOS 18.0, *)
enum NativeOCRResidualIndependentColumns {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement
    typealias Evidence = NativeOCRDetectorSeedEvidence

    static func candidates(_ m: Measurement) -> [NativeOCRResidualCandidate] {
        guard m.kind == "independent", m.status == "measured", m.rect.width >= 5,
              m.rect.height >= m.rect.width * 2 else { return [] }
        let width = m.rect.width
        let primary = m.components.filter { c in
            c.foreignPixels == 0 && c.insidePixels >= 2 &&
                Double(c.ownedPixels) >= max(2, min(8, Double(c.pixels) * 0.04)) &&
                normalOverlap(c.bounds, m.rect) >= min(c.bounds.width, width) * 0.4
        }
        guard primary.count >= 2 else { return [] }
        // Include complete same-palette outlines, not just the private DB core.
        // This is local envelope fitting; broad terminal recovery belongs to its own provider.
        let selected = m.components.filter { c in
            c.foreignPixels == 0 && c.insidePixels >= 2 && c.bounds.width <= width * 1.5 &&
                c.bounds.height <= max(width * 3, m.rect.height * 0.5) &&
                normalOverlap(c.bounds, m.rect) >= min(c.bounds.width, width) * 0.4 &&
                abs(c.center.x - m.rect.midX) <= width * 0.6 &&
                primary.contains { NativeOCRSourceComponentMeasurements.colourDistance(c.colour, $0.colour) <= 40 }
        }
        let support = m.guardPoints + NativeOCRSourceComponentBounds.visibleForeground(m)
        let points = selected.flatMap(\.hull) + m.privateHull + support.map(m.project)
        guard !points.isEmpty else { return [] }
        var result: [NativeOCRResidualCandidate] = []
        var axes: [(String, CGFloat)] = [("source", 0)]
        if let angled = NativeOCRSourceComponentBounds.proposal(m, gap: 0, axis: 1, padding: 2),
           abs(angled.1.angle) >= 0.2, abs(angled.1.angle) <= 8,
           (angled.1.residual ?? 1) <= 0.12 {
            axes.append(("robust", angled.1.angle * .pi / 180))
        }
        for (axisKey, angle) in axes {
            let c = cos(angle), s = sin(angle)
            let rotated = points.map { CGPoint(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c) }
            let ink = NativeOCRSourceComponentBounds.bounds(rotated)
            for padding: CGFloat in [0.02, 0.06] {
                let margin = max(m.step * 0.5, width * padding)
                let fitted = ink.insetBy(dx: -margin, dy: -margin)
                append(fitted, angle: angle, key: "independent-envelope-\(axisKey)-p\(Int(padding * 100))",
                       measurement: m, support: support, to: &result)
                if angle == 0 {
                    let normalOnly = CGRect(x: fitted.minX, y: min(m.rect.minY, fitted.minY),
                        width: fitted.width, height: max(m.rect.maxY, fitted.maxY) - min(m.rect.minY, fitted.minY))
                    append(normalOnly, angle: 0, key: "independent-normal-p\(Int(padding * 100))",
                           measurement: m, support: support, to: &result)
                }
            }
        }
        return result
    }

    static func candidates(_ m: Measurement, context: NativeOCRResidualSourceContext) -> [NativeOCRResidualCandidate] {
        // Parent supplies supportViews and bounded remeasurement before this call.
        // No recursive measuring, peer consumption or model invocation is needed here.
        candidates(m)
    }

    /// Return original CCs even when their along extent makes whole-CC intersection
    /// less than 50%. A narrow, well-supported corridor must explain nearly all cells.
    /// Any external competing private cell vetoes the component, rather than changing
    /// its runs, seed, owner, probability or provenance to manufacture ownership.
    static func sourceEvidence(index: Int, polygon: [CGPoint], originals: [NativeCoreMLDetectionBox],
                               prepared: [NativeCoreMLDetectionBox], groups: [Int: [Int]]) -> [Evidence] {
        guard index >= prepared.count, index >= 0, groups[index] == nil, polygon.count == 4,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        let context = NativeOCRSourceComponentMeasurements.Context(originals: originals, prepared: prepared,
            groups: groups, scopes: [], frameProvider: { nil })
        guard let m = context.metadata(index: index, polygon: polygon), m.rect.width >= 5,
              m.rect.height >= m.rect.width * 2 else { return [] }
        let owners = originals.compactMap(\.detectorSeedEvidence).filter { $0.isValid && !$0.components.isEmpty }
        var result: [Evidence] = []
        var visited = Set<String>()
        var budget = 0
        var competitionBudget = 0
        for e in owners {
            guard visited.insert(e.ownerID).inserted else { continue }
            let sx = CGFloat(e.sourceWidth) / CGFloat(e.mapFullWidth)
            let sy = CGFloat(e.sourceHeight) / CGFloat(e.mapFullHeight)
            let corridor = m.rect.insetBy(dx: -m.rect.width * 0.15, dy: 0)
            var chosen: [Evidence.Component] = []
            for component in e.components {
                budget += component.pixelCount
                guard budget <= 1_048_576 else { return result }
                var inside = 0, aligned = 0
                var sumX: CGFloat = 0
                var minY = CGFloat.infinity, maxY = -CGFloat.infinity
                var external = Set<Int>()
                for run in component.runs { for x in run.x..<(run.x + run.count) {
                    let p = m.project(.init(x: (CGFloat(x) + 0.5) * sx, y: (CGFloat(run.y) + 0.5) * sy))
                    if p.x >= corridor.minX && p.x <= corridor.maxX { aligned += 1 }
                    if p.x >= m.rect.minX && p.x <= m.rect.maxX && p.y >= m.rect.minY && p.y <= m.rect.maxY {
                        inside += 1; sumX += p.x; minY = min(minY, p.y); maxY = max(maxY, p.y)
                    } else { external.insert(run.y * e.mapFullWidth + x) }
                }}
                guard inside >= 8, aligned * 5 >= component.pixelCount * 4,
                      abs(sumX / CGFloat(inside) - m.rect.midX) <= m.rect.width * 0.3,
                      maxY - minY >= min(m.rect.width * 0.5, m.rect.height * 0.15) else { continue }
                var conflict = false
                if !external.isEmpty {
                    for other in owners where other.ownerID != e.ownerID {
                        guard other.mapFullWidth == e.mapFullWidth, other.mapFullHeight == e.mapFullHeight,
                              other.sourceWidth == e.sourceWidth, other.sourceHeight == e.sourceHeight else { continue }
                        for cc in other.components {
                            competitionBudget += cc.pixelCount
                            guard competitionBudget <= 1_048_576 else { return result }
                            for run in cc.runs {
                                for x in run.x..<(run.x + run.count) where external.contains(run.y * e.mapFullWidth + x) {
                                    conflict = true; break
                                }
                                if conflict { break }
                            }
                            if conflict { break }
                        }
                        if conflict { break }
                    }
                }
                if !conflict { chosen.append(component) }
            }
            guard !chosen.isEmpty else { continue }
            // Ancillary ambiguous/candidate inventories retain their existing meaning.
            // Do not relabel them as private components in this support view.
            result.append(.init(ownerID: e.ownerID, parentBoxIndex: e.parentBoxIndex, provenance: e.provenance,
                threshold: e.threshold, mapOriginX: e.mapOriginX, mapOriginY: e.mapOriginY,
                mapFullWidth: e.mapFullWidth, mapFullHeight: e.mapFullHeight,
                sourceWidth: e.sourceWidth, sourceHeight: e.sourceHeight, components: chosen,
                sourceProbabilityROI: e.sourceProbabilityROI, ownershipVersion: e.ownershipVersion,
                completeCCScan: e.completeCCScan, ambiguousComponents: e.ownershipVersion == 2 ? [] : nil,
                candidateComponents: e.ownershipVersion == 2 ? [] : nil))
        }
        return result
    }

    private static func normalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }

    private static func append(_ rect: CGRect, angle: CGFloat, key: String, measurement m: Measurement,
                               support: [CGPoint], to result: inout [NativeOCRResidualCandidate]) {
        guard !rect.isNull, rect.width.isFinite, rect.height.isFinite,
              rect.width >= m.rect.width * 0.35, rect.width <= m.rect.width * 1.65,
              rect.height >= m.rect.height * 0.55, rect.height <= m.rect.height * 1.35 else { return }
        let c = cos(angle), s = sin(angle)
        let polygon = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map { p in
            m.restore(.init(x: p.x * c + p.y * s, y: -p.x * s + p.y * c))
        }
        guard polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 }),
              support.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 0.75) }) else { return }
        result.append(.init(key: key, polygon: polygon, supportPoints: support))
    }
}
