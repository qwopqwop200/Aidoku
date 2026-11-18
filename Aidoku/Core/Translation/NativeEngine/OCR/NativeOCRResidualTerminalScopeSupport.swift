import CoreGraphics
import Foundation

/// Isolated additive proposal. Only model TEXT-scope uncertainty is relaxed;
/// original source pixels, component flags, owners and the terminal algorithm stay unchanged.
@available(iOS 18.0, *)
enum NativeOCRResidualTerminalScopeSupport {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement
    typealias Scope = NativeOCRSourceComponentMeasurements.Scope
    typealias Component = NativeOCRSourceComponentMeasurements.Component

    static func candidates(_ m: Measurement) -> [NativeOCRResidualCandidate] {
        propose(m, context: nil)
    }
    static func candidates(_ m: Measurement, context: NativeOCRResidualSourceContext) -> [NativeOCRResidualCandidate] {
        propose(m, context: context)
    }

    private static func propose(_ m: Measurement, context: NativeOCRResidualSourceContext?) -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", m.privateSamples >= 4, m.polygon.count == 4,
              m.rect.width.isFinite, m.rect.width >= 5, m.step.isFinite, m.step > 0,
              m.rect.height.isFinite, m.rect.height >= m.rect.width * 2 else { return [] }
        let width = m.rect.width, allowance = width * 0.15
        let roots = m.components.filter { c in
            c.foreignPixels == 0 && c.insidePixels >= 2 &&
                Double(c.ownedPixels) >= max(2, min(8, Double(c.pixels) * 0.04)) &&
                c.bounds.width <= width * 1.3 && c.bounds.height <= width * 2.2 &&
                abs(c.center.x - m.rect.midX) <= width * 0.4
        }
        guard !roots.isEmpty else { return [] }
        var result: [NativeOCRResidualCandidate] = []
        for head in [true, false] {
            let edge = head ? m.rect.minY : m.rect.maxY
            let anchor = m.restore(.init(x: m.rect.midX, y: edge))
            let endRoots = roots.filter { c in
                let gap = head ? max(0, c.bounds.minY - edge) : max(0, edge - c.bounds.maxY)
                return gap <= width * 0.65
            }
            guard !endRoots.isEmpty else { continue }
            let scopes = m.scopes.filter { scope in
                valid(scope.rect) && scope.confidence.isFinite && scope.confidence >= 0.75 &&
                    inside(scope.rect, anchor) && endRoots.contains { inside(scope.rect, m.restore($0.center)) }
            }.sorted { a, b in
                if a.confidence != b.confidence { return a.confidence > b.confidence }
                if a.rect.minX != b.rect.minX { return a.rect.minX < b.rect.minX }
                if a.rect.minY != b.rect.minY { return a.rect.minY < b.rect.minY }
                if a.rect.maxX != b.rect.maxX { return a.rect.maxX < b.rect.maxX }
                return a.rect.maxY < b.rect.maxY
            }.prefix(2)
            var best: NativeOCRResidualCandidate?
            var bestGrowth: CGFloat = 0
            for originalScope in scopes {
                // One original scope per invocation: no arbitrary scope union.
                let relaxedScope = Scope(rect: originalScope.rect.insetBy(dx: -allowance, dy: -allowance),
                                         confidence: originalScope.confidence)
                var relaxed = m
                relaxed.scopes = [relaxedScope]
                var observations = [m]
                let delegated: [NativeOCRResidualCandidate]
                if let context {
                    let wrapped = NativeOCRResidualSourceContext(originals: context.originals, prepared: context.prepared,
                        groups: context.groups, regions: context.regions, layout: context.layout,
                        frameProvider: context.frameProvider, measure: { index, requested in
                            guard index == m.index, requested.count == 4 else { return nil }
                            let b = bounds(requested.map(m.project))
                            let extendsHead = b.minY < m.rect.minY - 1e-7
                            let extendsTail = b.maxY > m.rect.maxY + 1e-7
                            guard head ? extendsHead && !extendsTail : extendsTail && !extendsHead else { return nil }
                            // Nomination is bounded by font-relative scope uncertainty,
                            // not the delegate's larger three-width search allowance.
                            let probe = stretched(m, head: head ? -allowance : 0, tail: head ? 0 : allowance)
                            guard var fresh = context.measure(index, probe) else { return nil }
                            observations.append(fresh)
                            fresh.scopes = [relaxedScope] // The ONLY modified fresh field.
                            return fresh
                        })
                    delegated = NativeOCRResidualTerminalExtension.candidates(relaxed, context: wrapped)
                } else {
                    delegated = NativeOCRResidualTerminalExtension.candidates(relaxed)
                }
                for candidate in delegated where candidate.consumedIndices.isEmpty &&
                    candidate.key.hasPrefix(head ? "terminal-head-" : "terminal-tail-") {
                    guard let recovered = validate(candidate, original: m, observations: observations,
                                                   scope: originalScope, endRoots: endRoots, head: head, allowance: allowance) else { continue }
                    let b = bounds(candidate.polygon.map(m.project))
                    let growth = head ? m.rect.minY - b.minY : b.maxY - m.rect.maxY
                    if growth > bestGrowth {
                        bestGrowth = growth
                        best = .init(key: head ? "scope-terminal-head-rf075-u015-c060-v1" : "scope-terminal-tail-rf075-u015-c060-v1",
                                     polygon: candidate.polygon, supportPoints: candidate.supportPoints + recovered)
                    }
                }
            }
            if let best { result.append(best) }
        }
        return result
    }

    /// Verify actual selected closed components against the SAME original strong
    /// scope and unrelaxed source anchors; never promote white/gray fringe by plausibility.
    private static func validate(_ candidate: NativeOCRResidualCandidate, original m: Measurement,
                                 observations: [Measurement], scope: Scope, endRoots: [Component],
                                 head: Bool, allowance: CGFloat) -> [CGPoint]? {
        guard candidate.polygon.count == 4, !candidate.supportPoints.isEmpty else { return nil }
        let b = bounds(candidate.polygon.map(m.project))
        let growth = head ? m.rect.minY - b.minY : b.maxY - m.rect.maxY
        guard growth >= max(1, m.step), growth <= allowance + min(1.5, m.step * 0.75) + 1e-7 else { return nil }
        let newPoints = candidate.supportPoints.filter {
            !NativeOCRSourceComponentMeasurements.contains(m.polygon, $0, tolerance: 1e-7)
        }
        guard !newPoints.isEmpty, newPoints.contains(where: { distance($0, scope.rect) > 1e-7 }),
              newPoints.allSatisfy({ distance($0, scope.rect) <= allowance + 1e-7 }) else { return nil }
        var fullCells: [CGPoint] = [], matched: [CGPoint] = [], mandatory: [CGPoint] = []
        for observed in observations {
            // guardPoints are already in world coordinates. privateHull is local
            // to THIS observation, including a fresh origin/basis/step. Preserve
            // all native mandatory support, not just delegate-selected components.
            let required = observed.guardPoints + observed.privateHull.map(observed.restore) +
                NativeOCRSourceComponentBounds.visibleForeground(observed)
            guard required.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  required.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6) })
            else { return nil }
            mandatory += required
            for c in observed.components where !c.hull.isEmpty {
                let world = c.hull.map(observed.restore)
                guard world.contains(where: { !NativeOCRSourceComponentMeasurements.contains(m.polygon, $0, tolerance: 1e-7) }),
                      world.allSatisfy({ p in candidate.supportPoints.contains { hypot($0.x - p.x, $0.y - p.y) <= 1e-6 } }) else { continue }
                let cells = corners(c.bounds).map(observed.restore)
                let local = bounds(cells.map(m.project))
                // Reject elongated/wide marks, not semantic categories. A compact
                // unowned border fragment or neighbor can be indistinguishable;
                // contextual peer evidence and final semantic admission are required.
                guard c.foreignPixels == 0, c.pixels >= 2,
                      local.width <= m.rect.width * 0.6, local.height <= m.rect.width * 0.6,
                      abs(local.midX - m.rect.midX) <= m.rect.width * 0.3,
                      max(local.width, local.height) <= max(1, min(local.width, local.height)) * 3,
                      endRoots.contains(where: { root in
                          inside(scope.rect, m.restore(root.center)) &&
                              NativeOCRSourceComponentMeasurements.colourDistance(c.colour, root.colour) <= 40
                      }), cells.allSatisfy({ distance($0, scope.rect) <= allowance + 1e-7 }),
                      cells.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6) }) else { return nil }
                fullCells += cells; matched += world
            }
        }
        // Every newly selected point needs a complete, unchanged closed-component
        // sample-cell envelope; no partial new terminal is admitted.
        guard !fullCells.isEmpty, newPoints.allSatisfy({ p in matched.contains { hypot($0.x - p.x, $0.y - p.y) <= 1e-6 } }) else { return nil }
        return fullCells + mandatory
    }

    private static func stretched(_ m: Measurement, head: CGFloat, tail: CGFloat) -> [CGPoint] {
        m.polygon.map { p in
            let local = m.project(p), t = (local.y - m.rect.minY) / m.rect.height
            return m.restore(.init(x: local.x, y: local.y + head * (1 - t) + tail * t))
        }
    }
    private static func inside(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }
    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(0, r.minX - p.x, p.x - r.maxX), max(0, r.minY - p.y, p.y - r.maxY))
    }
    private static func valid(_ r: CGRect) -> Bool {
        [r.minX, r.maxX, r.minY, r.maxY].allSatisfy(\.isFinite) && r.width > 0 && r.height > 0
    }
    private static func bounds(_ p: [CGPoint]) -> CGRect {
        let x = p.map(\.x), y = p.map(\.y)
        return .init(x: x.min()!, y: y.min()!, width: x.max()! - x.min()!, height: y.max()! - y.min()!)
    }
    private static func corners(_ r: CGRect) -> [CGPoint] {
        [.init(x: r.minX, y: r.minY), .init(x: r.maxX, y: r.minY),
         .init(x: r.maxX, y: r.maxY), .init(x: r.minX, y: r.maxY)]
    }
}
