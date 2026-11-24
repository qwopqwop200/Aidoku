import CoreGraphics
import Foundation

/// S2b: joins detector fragments of one text column or row: stacked along one axis within `maximumGap`
/// thicknesses, of similar thickness, overlapping across it, not straddling a balloon boundary; greedy,
/// smallest normalized gap first, re-testing the merged line.
enum PipelineLineAssembly {
    /// Maximum along-axis gap, in units of the thinner fragment's thickness.
    static var maximumGap: CGFloat { PipelineTuning.current.assemblyMaximumGap }
    /// Minimum cross-axis overlap, in units of the thinner fragment's thickness.
    static var minimumOverlap: CGFloat { PipelineTuning.current.assemblyMinimumOverlap }
    /// Maximum thickness ratio between the two fragments.
    static let maximumRatio: CGFloat = 1.8
    /// A fragment joins along an axis only when `length * aspect >= thickness`.
    static let aspect: CGFloat = 1.25
    /// Maximum along-axis overlap, in units of the shorter fragment's length.
    static let nesting: CGFloat = 0.5
    /// A fragment belongs to the balloon covering at least this share of it.
    static let balloonInside: CGFloat = 0.5
    /// A fragment outside every balloon joins a balloon member only with this share inside it.
    static let balloonOutside: CGFloat = 0.15
    static var balloonMinimumScore: Float { PipelineLayoutRegion.balloonFloor }

    static func assemble(_ lines: [PipelineLine], layout: [PipelineLayoutRegion]) -> [PipelineLine] {
        guard lines.count > 1 else { return lines }
        let balloons = layout.filter {
            $0.kind == .balloon && $0.score >= balloonMinimumScore && !$0.bounds.isEmpty
        }.map(\.bounds)
        // A merge keeps the lower id; admissible pairs are cached and only the merged item's are
        // recomputed (noisy pages reach 3,000 candidates), giving the quadratic rescan's (gap, i, j) choice.
        var items = lines.map { Item(line: $0, box: $0.bounds, owner: owner($0.bounds, balloons)) }
        var alive = [Bool](repeating: true, count: items.count)
        var pairs: [Pair] = []
        func admissible(_ i: Int, _ j: Int) -> Pair? {
            guard let gap = joinGap(items[i].box, items[j].box),
                  layoutAllows(items[i], items[j], balloons) else { return nil }
            return Pair(gap: gap, i: i, j: j)
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
            items[best.i] = Item(line: merged, box: box, owner: owner(box, balloons))
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
        var gap: CGFloat
        var i: Int
        var j: Int

        /// The rescan's order: smaller gap first, then lower i, then lower j.
        func precedes(_ other: Pair) -> Bool { (gap, i, j) < (other.gap, other.i, other.j) }
    }

    private struct Item {
        var line: PipelineLine
        var box: CGRect
        var owner: Int?
    }

    /// Normalized gap when `a` and `b` are fragments of one column or row, else nil.
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
