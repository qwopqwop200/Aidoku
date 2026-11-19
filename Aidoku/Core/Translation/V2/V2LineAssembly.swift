import CoreGraphics
import Foundation

/// S2b: joins detector fragments of one text column (vertical) or row (horizontal).
///
/// The DB detector often splits one lettered column into 2-4 components (a gap
/// at small kana, punctuation or a faint stroke). Two fragments are joined when
/// they are stacked along one axis with a gap of at most `gap` line
/// thicknesses, have similar thickness, overlap across the axis, neither runs
/// clearly across the joining axis, and they do not straddle a balloon
/// boundary. Joins are applied greedily, smallest normalized gap first, and the
/// merged line is re-tested against the remaining fragments. Recall-first:
/// parameters were fitted on the GT train split (individual_premerge_bbox).
/// Python reference: the out-of-repo research scripts (scripts-detection)/assemble.py (kept bit-identical).
enum V2LineAssembly {
    struct Parameters: Sendable, Equatable {
        /// Maximum along-axis gap, in units of the thinner fragment's thickness.
        var gap: CGFloat = 1.5
        /// Minimum cross-axis overlap, in units of the thinner fragment's thickness.
        var overlap: CGFloat = 0.6
        /// Maximum thickness ratio between the two fragments.
        var ratio: CGFloat = 1.8
        /// A fragment joins along an axis only when `length * aspect >= thickness`.
        var aspect: CGFloat = 1.25
        /// Maximum along-axis overlap, in units of the shorter fragment's length.
        var nesting: CGFloat = 0.5
        /// A fragment belongs to the balloon covering at least this share of it.
        var balloonInside: CGFloat = 0.5
        /// A fragment outside every balloon may join a balloon member only when at
        /// least this share of it lies inside that balloon.
        var balloonOutside: CGFloat = 0.15
        var balloonMinimumScore: Float = 0.5

        static let standard = Parameters()
    }

    static func assemble(_ lines: [V2Line], layout: [V2LayoutRegion]) -> [V2Line] {
        assemble(lines, layout: layout, parameters: .standard)
    }

    static func assemble(_ lines: [V2Line], layout: [V2LayoutRegion], parameters: Parameters) -> [V2Line] {
        guard lines.count > 1 else { return lines }
        let balloons = layout.filter {
            $0.kind == .balloon && $0.score >= parameters.balloonMinimumScore && !$0.bounds.isEmpty
        }.map(\.bounds)
        // Items keep stable ids (input order); a merge keeps the lower id and drops the higher, so id
        // order is the array order of the original quadratic rescan. Admissible pairs are cached and
        // only the merged item's pairs are recomputed, so each merge is O(pairs + n) instead of O(n^2)
        // (noisy pages reach the detector's 3,000-candidate cap). Same pairs, same (gap, i, j) choice.
        var items = lines.map { Item(line: $0, box: $0.bounds, owner: owner($0.bounds, balloons, parameters)) }
        var alive = [Bool](repeating: true, count: items.count)
        var pairs: [Pair] = []
        func admissible(_ i: Int, _ j: Int) -> Pair? {
            guard let gap = joinGap(items[i].box, items[j].box, parameters),
                  layoutAllows(items[i], items[j], balloons, parameters) else { return nil }
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
            merged.polygon = [
                CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)
            ]
            merged.bounds = box
            merged.vertical = box.height >= box.width
            merged.detectionScore = max(a.line.detectionScore, b.line.detectionScore)
            items[best.i] = Item(line: merged, box: box, owner: owner(box, balloons, parameters))
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
        var line: V2Line
        var box: CGRect
        var owner: Int?
    }

    /// Normalized gap when `a` and `b` are fragments of one column or row, else nil.
    static func joinGap(_ a: CGRect, _ b: CGRect, _ parameters: Parameters) -> CGFloat? {
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
                  lengthA * parameters.aspect >= thicknessA, lengthB * parameters.aspect >= thicknessB,
                  max(thicknessA, thicknessB) <= parameters.ratio * thickness,
                  crossOverlap >= parameters.overlap * thickness,
                  gap <= parameters.gap * thickness,
                  gap >= -parameters.nesting * min(lengthA, lengthB)
            else { continue }
            let normalized = max(gap, 0) / thickness
            if best.map({ normalized < $0 }) ?? true { best = normalized }
        }
        return best
    }

    private static func layoutAllows(_ a: Item, _ b: Item, _ balloons: [CGRect], _ parameters: Parameters) -> Bool {
        switch (a.owner, b.owner) {
        case let (x?, y?): x == y
        case let (x?, nil): coverage(b.box, balloons[x]) >= parameters.balloonOutside
        case let (nil, y?): coverage(a.box, balloons[y]) >= parameters.balloonOutside
        case (nil, nil): true
        }
    }

    private static func owner(_ box: CGRect, _ balloons: [CGRect], _ parameters: Parameters) -> Int? {
        var best: Int?
        var bestCoverage: CGFloat = 0
        for (index, balloon) in balloons.enumerated() {
            let value = coverage(box, balloon)
            if value > bestCoverage {
                bestCoverage = value
                best = index
            }
        }
        return bestCoverage >= parameters.balloonInside ? best : nil
    }

    /// Share of `box`'s area inside `region`.
    private static func coverage(_ box: CGRect, _ region: CGRect) -> CGFloat {
        guard box.width > 0, box.height > 0 else { return 0 }
        let width = max(0, min(box.maxX, region.maxX) - max(box.minX, region.minX))
        let height = max(0, min(box.maxY, region.maxY) - max(box.minY, region.minY))
        return width * height / (box.width * box.height)
    }
}
