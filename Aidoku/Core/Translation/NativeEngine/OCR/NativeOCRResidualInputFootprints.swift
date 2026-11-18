import CoreGraphics
import Foundation

/// Isolated proposal: optional earlier input footprints, never ownership or GT.
/// The caller MUST run the unchanged global safe/caps/semantic gate on every output.
@available(iOS 18.0, *)
enum NativeOCRResidualInputFootprints {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement
    private struct TextScope {
        let rect: CGRect
        let confidence: Double
        let order: Int
    }
    private struct Frame {
        let origin: CGPoint
        let normal: CGPoint
        let along: CGPoint
        init?(_ polygon: [CGPoint]) {
            guard NativeOCRResidualInputFootprints.valid(polygon) else { return nil }
            var edge = CGPoint.zero, squared: CGFloat = 0
            for i in polygon.indices {
                let next = polygon[(i + 1) % 4]
                let candidate = CGPoint(x: next.x - polygon[i].x, y: next.y - polygon[i].y)
                let length = candidate.x * candidate.x + candidate.y * candidate.y
                if length > squared { edge = candidate; squared = length }
            }
            guard squared > 0 else { return nil }
            var axis = CGPoint(x: edge.x / sqrt(squared), y: edge.y / sqrt(squared))
            if axis.y < -1e-12 || (abs(axis.y) <= 1e-12 && axis.x < 0) { axis = .init(x: -axis.x, y: -axis.y) }
            origin = .init(x: polygon.map(\.x).reduce(0, +) / 4, y: polygon.map(\.y).reduce(0, +) / 4)
            along = axis; normal = .init(x: axis.y, y: -axis.x)
        }
        func project(_ p: CGPoint) -> CGPoint {
            let x = p.x - origin.x, y = p.y - origin.y
            return .init(x: x * normal.x + y * normal.y, y: x * along.x + y * along.y)
        }
        func restore(_ p: CGPoint) -> CGPoint {
            .init(x: origin.x + p.x * normal.x + p.y * along.x, y: origin.y + p.x * normal.y + p.y * along.y)
        }
        func quad(_ normal: ClosedRange<CGFloat>, _ along: ClosedRange<CGFloat>) -> [CGPoint] {
            [CGPoint(x: normal.lowerBound, y: along.lowerBound), CGPoint(x: normal.upperBound, y: along.lowerBound),
             CGPoint(x: normal.upperBound, y: along.upperBound), CGPoint(x: normal.lowerBound, y: along.upperBound)].map(restore)
        }
    }

    /// Maximum eight native candidates: original/prepared times direct, hybrid,
    /// and at most two RF normal clips. Existing candidates remain untouched.
    static func candidates(_ m: Measurement, context: NativeOCRResidualSourceContext) -> [NativeOCRResidualCandidate] {
        guard m.kind == "detector" || m.kind == "group", m.status == "measured", m.privateSamples >= 4,
              context.prepared.indices.contains(m.index), valid(m.polygon),
              !context.regions.contains(where: { $0.index == m.index && $0.independent }) else { return [] }
        let support = m.guardPoints + NativeOCRSourceComponentBounds.visibleForeground(m)
        guard !support.isEmpty else { return [] }
        var inputs: [(String, [CGPoint])] = []
        if m.kind == "detector", context.groups[m.index] == nil, context.originals.indices.contains(m.index) {
            inputs.append(("original", context.originals[m.index].polygon))
        }
        inputs.append(("prepared", context.prepared[m.index].polygon))
        let scopes = rankedScopes(m, context: context)
        let members = Set(context.groups[m.index] ?? [m.index])
        let peers = context.regions.filter { $0.index != m.index && !members.contains($0.index) }
        var result: [NativeOCRResidualCandidate] = []
        func append(_ key: String, _ polygon: [CGPoint]) {
            guard valid(polygon), polygon.allSatisfy({ $0.x >= 0 && $0.y >= 0 }),
                  support.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 0.75) }) else { return }
            if let layout = context.layout {
                guard polygon.allSatisfy({ $0.x <= CGFloat(layout.sourceWidth) && $0.y <= CGFloat(layout.sourceHeight) }) else { return }
            }
            // A geometry-only early veto of obvious different normal-band peers.
            // The parent's source masks and semantic gate remain authoritative.
            for peer in peers where peer.polygon.count == 4 {
                let b = bounds(peer.polygon.map(m.project))
                let center = CGPoint(x: peer.polygon.map(\.x).reduce(0, +) / 4, y: peer.polygon.map(\.y).reduce(0, +) / 4)
                let overlap = min(b.maxY, m.rect.maxY) - max(b.minY, m.rect.minY)
                if abs(b.midX - m.rect.midX) >= max(b.width, m.rect.width) * 0.5,
                   overlap >= min(b.height, m.rect.height) * 0.25,
                   NativeOCRSourceComponentMeasurements.contains(polygon, center, tolerance: 0.75),
                   !NativeOCRSourceComponentMeasurements.contains(m.polygon, center, tolerance: 0.75) { return }
            }
            result.append(.init(key: key, polygon: polygon, supportPoints: support))
        }
        for (name, input) in inputs {
            guard let frame = Frame(input) else { continue }
            let source = bounds(input.map(frame.project)), current = bounds(m.polygon.map(frame.project))
            guard source.width > 0, current.height > 0 else { continue }
            append("input-footprint-v1-\(name)-direct", input)
            append("input-footprint-v1-\(name)-axis-normal-current-along",
                   frame.quad(source.minX...source.maxX, current.minY...current.maxY))
            for (rank, scope) in scopes.enumerated() {
                let rf = bounds(corners(scope.rect).map(frame.project))
                let left = max(source.minX, rf.minX), right = min(source.maxX, rf.maxX)
                guard right > left, abs(left - source.minX) + abs(right - source.maxX) >= 1e-7 else { continue }
                append("input-footprint-v1-\(name)-rf-text-c050-r\(rank + 1)-normal-current-along",
                       frame.quad(left...right, current.minY...current.maxY))
            }
        }
        return result
    }

    private static func rankedScopes(_ m: Measurement, context: NativeOCRResidualSourceContext) -> [TextScope] {
        let available: [TextScope]
        if let layout = context.layout {
            available = layout.primitives.compactMap { p in
                p.semanticClass == .text ? .init(rect: p.sourceBounds, confidence: Double(p.confidence), order: p.queryID) : nil
            }
        } else {
            available = m.scopes.enumerated().map { .init(rect: $0.element.rect, confidence: $0.element.confidence, order: $0.offset) }
        }
        let center = CGPoint(x: m.polygon.map(\.x).reduce(0, +) / 4, y: m.polygon.map(\.y).reduce(0, +) / 4)
        let sourceArea = area(m.polygon)
        let ranked = available.compactMap { scope -> (TextScope, Double)? in
            let r = scope.rect
            guard scope.confidence.isFinite, scope.confidence >= 0.5,
                  [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite), r.width > 0, r.height > 0,
                  center.x >= r.minX, center.x <= r.maxX, center.y >= r.minY, center.y <= r.maxY else { return nil }
            let intersection = area(NativeOCRSourceComponentBounds.clip(m.polygon, to: corners(r)))
            guard intersection > 0, sourceArea > 0 else { return nil }
            let overlap = (Double(min(1, max(0, intersection / sourceArea))) * 1e12).rounded() / 1e12
            return (scope, overlap)
        }.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.confidence != b.0.confidence { return a.0.confidence > b.0.confidence }
            return a.0.order < b.0.order
        }
        // Select before checking whether the interval shrinks. A third scope is
        // never promoted because it happens to produce a more attractive crop.
        return ranked.prefix(2).map { $0.0 }
    }

    private static func valid(_ p: [CGPoint]) -> Bool {
        guard p.count == 4, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), area(p) > 1 else { return false }
        let turns = p.indices.map { i -> CGFloat in
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        return turns.allSatisfy({ $0 >= -1e-7 }) || turns.allSatisfy({ $0 <= 1e-7 })
    }
    private static func area(_ p: [CGPoint]) -> CGFloat {
        guard p.count >= 3 else { return 0 }
        return abs(p.indices.reduce(CGFloat(0)) { sum, i in
            let a = p[i], b = p[(i + 1) % p.count]
            return sum + a.x * b.y - b.x * a.y
        }) * 0.5
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
