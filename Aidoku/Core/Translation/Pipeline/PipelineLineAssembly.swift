import CoreGraphics
import Foundation

/// S2b: joins detector fragments of one text column or row. Candidate pairs (stacked along one axis, loosely
/// aligned) are scored by a logistic pair model on 22 scale-free features; greedy, most probable join first,
/// re-scoring the merged line, while the probability is at least the model's threshold.
enum PipelineLineAssembly {
    /// Maximum along-axis gap of the hand rule (`joinGap`, a model feature), in thinner thicknesses.
    static var maximumGap: CGFloat { PipelineTuning.current.assemblyMaximumGap }
    /// Minimum cross-axis overlap of the hand rule, in units of the thinner fragment's thickness.
    static var minimumOverlap: CGFloat { PipelineTuning.current.assemblyMinimumOverlap }
    /// Hand rule: maximum thickness ratio between the two fragments.
    static let maximumRatio: CGFloat = 1.8
    /// Hand rule: a fragment joins along an axis only when `length * aspect >= thickness`.
    static let aspect: CGFloat = 1.25
    /// Hand rule: maximum along-axis overlap, in units of the shorter fragment's length.
    static let nesting: CGFloat = 0.5
    /// A fragment belongs to the balloon covering at least this share of it.
    static let balloonInside: CGFloat = 0.5
    /// A fragment outside every balloon joins a balloon member only with this share inside it.
    static let balloonOutside: CGFloat = 0.15
    static var balloonMinimumScore: Float { PipelineLayoutRegion.balloonFloor }
    /// RF text regions at or above this score feed the shared-text-region feature.
    static let textMinimumScore: Float = 0.3

    /// Candidate gate: thickness ratio, along gap and cross overlap (thinner thicknesses), along overlap
    /// (shorter length) and `length * gateAspect >= thickness`.
    static let gateRatio: CGFloat = 5
    static let gateGap: CGFloat = 3
    static let gateOverlap: CGFloat = 0.3
    static let gateNesting: CGFloat = 1
    static let gateAspect: CGFloat = 4

    /// Logistic pair model (Resources/Translation/PipelineLineJoin.json, fit on TRAIN pages against GT line labels by
    /// Scripts/pipeline/tools/retrain/assembly/train.py): standardized features in `features` order, joined while
    /// the pair probability is at least `threshold`.
    struct Model: Decodable, Sendable {
        let features: [String]
        let threshold: Double
        let mean: [Double]
        let scale: [Double]
        let weights: [Double]
        let bias: Double
    }

    static let model: Model? = {
        var urls = [Bundle.main.url(forResource: "PipelineLineJoin", withExtension: "json")].compactMap { $0 }
        if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] {
            urls.append(URL(fileURLWithPath: root).appendingPathComponent("Aidoku/Resources/Translation/PipelineLineJoin.json"))
        }
        return urls.lazy.compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(Model.self, from: $0) }.first
    }()

    /// The joined lines (the input unchanged without the model file).
    static func assemble(_ lines: [PipelineLine], layout: [PipelineLayoutRegion]) -> [PipelineLine] {
        guard lines.count > 1, let model else { return lines }
        let balloons = layout.filter {
            $0.kind == .balloon && $0.score >= balloonMinimumScore && !$0.bounds.isEmpty
        }.map(\.bounds)
        let texts = layout.filter { $0.kind == .text && $0.score >= textMinimumScore }.map(\.bounds)
        // A merge keeps the lower id; admissible pairs are cached and only the merged item's are
        // rescored, giving the quadratic rescan's (1 - p, i, j) choice.
        var items = lines.map {
            Item(line: $0, box: $0.bounds, owner: owner($0.bounds, balloons),
                 flags: [$0.vertical], scores: [Double($0.detectionScore)])
        }
        var alive = [Bool](repeating: true, count: items.count)
        var pairs: [Pair] = []
        func admissible(_ i: Int, _ j: Int) -> Pair? {
            guard let p = probability(model, items[i], items[j], balloons, texts), p >= model.threshold else { return nil }
            return Pair(gap: 1 - p, i: i, j: j)
        }
        for i in items.indices {
            for j in (i + 1)..<items.count {
                if let pair = admissible(i, j) { pairs.append(pair) }
            }
        }
        while var best = pairs.first {
            for pair in pairs.dropFirst() where pair.precedes(best) { best = pair }
            let a = items[best.i]
            let b = items[best.j]
            let box = a.box.union(b.box)
            var merged = a.line
            merged.polygon = PipelineRemovalMask.corners(box)
            merged.bounds = box
            merged.vertical = box.height >= box.width
            merged.detectionScore = max(a.line.detectionScore, b.line.detectionScore)
            items[best.i] = Item(line: merged, box: box, owner: owner(box, balloons),
                                 flags: a.flags + b.flags, scores: a.scores + b.scores)
            alive[best.j] = false
            pairs.removeAll { $0.i == best.i || $0.j == best.i || $0.i == best.j || $0.j == best.j }
            for other in items.indices where alive[other] && other != best.i {
                let pair = other < best.i ? admissible(other, best.i) : admissible(best.i, other)
                if let pair { pairs.append(pair) }
            }
        }
        return items.indices.filter { alive[$0] }.map { items[$0].line }
    }

    private struct Pair {
        var gap: Double
        var i: Int
        var j: Int

        /// The rescan's order: smaller gap first, then lower i, then lower j.
        func precedes(_ other: Pair) -> Bool { (gap, i, j) < (other.gap, other.i, other.j) }
    }

    private struct Item {
        var line: PipelineLine
        var box: CGRect
        var owner: Int?
        /// Detector `vertical` flags and scores of the fragments joined so far.
        var flags: [Bool]
        var scores: [Double]
    }

    /// Join probability of `a` (lower id) and `b`, nil outside the candidate gate.
    private static func probability(_ model: Model, _ a: Item, _ b: Item, _ balloons: [CGRect],
                                    _ texts: [CGRect]) -> Double? {
        guard let f = features(a, b, balloons, texts) else { return nil }
        var z = 0.0
        for k in f.indices { z += (f[k] - model.mean[k]) / model.scale[k] * model.weights[k] }
        z += model.bias
        return 1 / (1 + exp(-z))
    }

    /// The model's features on the gate axis with the smallest normalized gap: axis, thickness ratio, gap,
    /// cross overlap and offset, lengths, detector-flag agreement, scores, balloon relation, shared RF text
    /// region, the hand rule, fragment count, merged aspect and along overlap.
    private static func features(_ x: Item, _ y: Item, _ balloons: [CGRect], _ texts: [CGRect]) -> [Double]? {
        let a = x.box
        let b = y.box
        var best: (n: CGFloat, vertical: Bool, t: CGFloat, tA: CGFloat, tB: CGFloat,
                   lA: CGFloat, lB: CGFloat, co: CGFloat, gap: CGFloat)?
        for vertical in [true, false] {
            let tA = vertical ? a.width : a.height
            let tB = vertical ? b.width : b.height
            let lA = vertical ? a.height : a.width
            let lB = vertical ? b.height : b.width
            let co = vertical
                ? min(a.maxX, b.maxX) - max(a.minX, b.minX)
                : min(a.maxY, b.maxY) - max(a.minY, b.minY)
            let gap = vertical
                ? max(a.minY, b.minY) - min(a.maxY, b.maxY)
                : max(a.minX, b.minX) - min(a.maxX, b.maxX)
            let t = min(tA, tB)
            guard t > 0, max(tA, tB) <= gateRatio * t, co >= gateOverlap * t, gap <= gateGap * t,
                  gap >= -gateNesting * min(lA, lB), lA * gateAspect >= tA, lB * gateAspect >= tB
            else { continue }
            let n = max(gap, 0) / t
            if best.map({ n < $0.n }) ?? true { best = (n, vertical, t, tA, tB, lA, lB, co, gap) }
        }
        guard let g = best else { return nil }
        let v = g.vertical
        let thick = max(g.tA, g.tB)
        let (thinLength, thickLength) = g.tA <= g.tB ? (g.lA, g.lB) : (g.lB, g.lA)
        let centreA = v ? (a.minX + a.maxX) / 2 : (a.minY + a.maxY) / 2
        let centreB = v ? (b.minX + b.maxX) / 2 : (b.minY + b.maxY) / 2
        let flags = x.flags + y.flags
        let scores = x.scores + y.scores
        let agree = Double(flags.filter { $0 == v }.count) / Double(flags.count)
        let relation: Double = switch (x.owner, y.owner) {
        case (nil, nil): 0
        case let (p?, q?): p == q ? 1 : 3
        default: 2
        }
        let layoutOK = layoutAllows(x, y, balloons)
        let shared = texts.map { min(coverage(a, $0), coverage(b, $0)) }.max() ?? 0
        let rule = joinGap(a, b) != nil && layoutOK
        let union = a.union(b)
        let length = v ? union.height : union.width
        let width = v ? union.width : union.height
        return [
            v ? 1 : 0, thick / g.t, g.gap / g.t, g.co / g.t, g.co / thick, abs(centreA - centreB) / g.t,
            thinLength / g.t, thickLength / thick, thinLength / thick,
            min(g.lA / g.tA, g.lB / g.tB), max(g.lA / g.tA, g.lB / g.tB),
            agree, scores.min() ?? 0, scores.max() ?? 0, relation, layoutOK ? 1 : 0, shared, rule ? 1 : 0,
            Double(flags.count), length / width, g.gap / thick, -g.gap / max(1e-9, min(g.lA, g.lB))
        ]
    }

    /// Normalized gap when `a` and `b` are fragments of one column or row by the hand rule, else nil.
    static func joinGap(_ a: CGRect, _ b: CGRect) -> CGFloat? {
        var best: CGFloat?
        for vertical in [true, false] {
            let thicknessA = vertical ? a.width : a.height
            let thicknessB = vertical ? b.width : b.height
            let lengthA = vertical ? a.height : a.width
            let lengthB = vertical ? b.height : b.width
            let crossOverlap = vertical
                ? min(a.maxX, b.maxX) - max(a.minX, b.minX)
                : min(a.maxY, b.maxY) - max(a.minY, b.minY)
            let gap = vertical
                ? max(a.minY, b.minY) - min(a.maxY, b.maxY)
                : max(a.minX, b.minX) - min(a.maxX, b.maxX)
            let thickness = min(thicknessA, thicknessB)
            guard thickness > 0,
                  lengthA * aspect >= thicknessA, lengthB * aspect >= thicknessB,
                  max(thicknessA, thicknessB) <= maximumRatio * thickness,
                  crossOverlap >= minimumOverlap * thickness,
                  gap <= maximumGap * thickness,
                  gap >= -nesting * min(lengthA, lengthB)
            else { continue }
            let normalized = max(gap, 0) / thickness
            if best.map({ normalized < $0 }) ?? true { best = normalized }
        }
        return best
    }

    private static func layoutAllows(_ a: Item, _ b: Item, _ balloons: [CGRect]) -> Bool {
        switch (a.owner, b.owner) {
        case let (x?, y?): x == y
        case let (x?, nil): coverage(b.box, balloons[x]) >= balloonOutside
        case let (nil, y?): coverage(a.box, balloons[y]) >= balloonOutside
        case (nil, nil): true
        }
    }

    private static func owner(_ box: CGRect, _ balloons: [CGRect]) -> Int? {
        var best: Int?
        var bestCoverage: CGFloat = 0
        for (index, balloon) in balloons.enumerated() {
            let value = coverage(box, balloon)
            if value > bestCoverage {
                bestCoverage = value
                best = index
            }
        }
        return bestCoverage >= balloonInside ? best : nil
    }

    /// Share of `box`'s area inside `region` (shared with `PipelineParagraphGrouping`).
    static func coverage(_ box: CGRect, _ region: CGRect) -> CGFloat {
        guard box.width > 0, box.height > 0 else { return 0 }
        let width = max(0, min(box.maxX, region.maxX) - max(box.minX, region.minX))
        let height = max(0, min(box.maxY, region.maxY) - max(box.minY, region.minY))
        return width * height / (box.width * box.height)
    }
}
