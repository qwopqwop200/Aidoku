/// Direct retained witnesses only. Recognition confidence orders candidates;
/// measured DB/RF support bounds suppression of overlapping alternatives.
enum NativeOCRPostRecognitionDeduplication {
    static let approvedPolicyVersion = "postrec-retained-witness-iou085-rec-db-rf-v1"
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias D = NativeOCRGeometryDeduplication
    enum Failure: Error { case invalidFeatures }
    struct Replacement: Codable, Sendable {
        let inputIndex: Int
        let retainedIndex: Int
        let polygonIoU: Double
    }
    struct Report: Codable, Sendable {
        let inputCount: Int
        let keptIndices: [Int]
        let replacements: [Replacement]
        let polygonIoUThreshold: Double
    }
    struct Result: Sendable { let output: G.Output; let report: Report }
    static func apply(_ input: G.Output, source166 x: [[Double]]) throws -> Result {
        guard x.count == input.individuals.count, x.allSatisfy({ $0.count == 166 }) else { throw Failure.invalidFeatures }
        let fields = [165, 155, 8, 9]
        let shapes = input.individuals.map { D.Shape($0.polygon) }
        let order = x.indices.filter { i in
            fields.allSatisfy { x[i][$0].isFinite } && shapes[i].convex && shapes[i].area.isFinite && shapes[i].area > 0
        }.sorted { a, b in
            for column in [165, 155, 8] {
                let av = x[a][column], bv = x[b][column]
                if av != bv { return av > bv }
            }
            return a < b
        }
        return suppress(input, shapes: shapes, order: order, threshold: 0.85) { witness, candidate in
            x[witness][165] >= x[candidate][165]
                && x[witness][155] + 0.05 >= x[candidate][155]
                && x[witness][8] + 0.05 >= x[candidate][8]
                && x[witness][9] + 0.02 >= x[candidate][9]
        }
    }

    /// Input order contains only eligible rows, highest-ranked witness first.
    /// The report also exposes the order of its replacements within each witness.
    static func suppress(_ input: G.Output, shapes: [D.Shape], order: [Int], threshold: Double,
                         maySuppress: (Int, Int) -> Bool) -> Result {
        var keep = Array(repeating: true, count: shapes.count)
        var replacements: [Replacement] = []
        let bounds = order.map { Bounds(shapes[$0]) }
        let index = IntervalIndex(bounds)
        var nearby: [Int] = []
        for (rank, witness) in order.enumerated() where keep[witness] {
            func consider(_ otherRank: Int) {
                let candidate = order[otherRank]
                guard keep[candidate], maySuppress(witness, candidate) else { return }
                let iou = D.intersectionIoU(shapes[witness], shapes[candidate], minimum: 0)
                guard iou >= threshold else { return }
                keep[candidate] = false
                replacements.append(.init(inputIndex: candidate, retainedIndex: witness, polygonIoU: iou))
            }
            if let index {
                index.laterOverlaps(of: rank, bounds: bounds, into: &nearby)
                for otherRank in nearby { consider(otherRank) }
            } else {
                let box = bounds[rank]
                for otherRank in (rank + 1)..<order.count where box.overlaps(bounds[otherRank]) {
                    consider(otherRank)
                }
            }
        }
        let indices = keep.indices.filter { keep[$0] }
        return .init(output: G.selecting(input, indices: indices), report: .init(
            inputCount: shapes.count, keptIndices: indices, replacements: replacements, polygonIoUThreshold: threshold))
    }

    /// Compare the original Double extrema directly. A shared edge alone gives zero IoU.
    private struct Bounds {
        let minX, minY, maxX, maxY: Double

        init(_ shape: D.Shape) {
            minX = shape.minX; maxX = shape.maxX
            minY = shape.minY; maxY = shape.maxY
        }

        func overlaps(_ other: Self) -> Bool {
            minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
        }
    }

    /// A balanced interval tree over the less crowded axis. Each midpoint holds the
    /// greatest endpoint in its subtree, including boxes spanning multiple neighbours.
    private struct IntervalIndex {
        let horizontal: Bool
        let ranksByStart: [Int]
        let subtreeEnd: [Double]

        init?(_ bounds: [Bounds]) {
            guard bounds.count > 32 else { return nil }
            var minX = bounds[0].minX, maxX = bounds[0].maxX
            var minY = bounds[0].minY, maxY = bounds[0].maxY
            var widths = 0.0, heights = 0.0
            for b in bounds {
                minX = min(minX, b.minX); maxX = max(maxX, b.maxX)
                minY = min(minY, b.minY); maxY = max(maxY, b.maxY)
                widths += b.maxX - b.minX
                heights += b.maxY - b.minY
            }
            let xOccupancy = widths / (maxX - minX), yOccupancy = heights / (maxY - minY)
            // When most intervals overlap on both axes a rank-ordered scan costs less.
            guard min(xOccupancy, yOccupancy) < Double(bounds.count) / 2 else { return nil }
            let horizontal = xOccupancy < yOccupancy
            self.horizontal = horizontal
            let ranks = bounds.indices.sorted {
                horizontal ? bounds[$0].minX < bounds[$1].minX : bounds[$0].minY < bounds[$1].minY
            }
            ranksByStart = ranks
            var ends = Array(repeating: -Double.infinity, count: ranks.count)
            func build(_ lo: Int, _ hi: Int) -> Double {
                guard lo < hi else { return -Double.infinity }
                let mid = lo + (hi - lo) / 2, box = bounds[ranks[mid]]
                let left = build(lo, mid), right = build(mid + 1, hi)
                ends[mid] = max(horizontal ? box.maxX : box.maxY, max(left, right))
                return ends[mid]
            }
            _ = build(0, ranks.count)
            subtreeEnd = ends
        }

        func laterOverlaps(of rank: Int, bounds: [Bounds], into nearby: inout [Int]) {
            let box = bounds[rank]
            let start = horizontal ? box.minX : box.minY, end = horizontal ? box.maxX : box.maxY
            nearby.removeAll(keepingCapacity: true)
            func visit(_ lo: Int, _ hi: Int) {
                guard lo < hi else { return }
                let mid = lo + (hi - lo) / 2
                guard subtreeEnd[mid] > start else { return }
                visit(lo, mid)
                let otherRank = ranksByStart[mid], other = bounds[otherRank]
                guard (horizontal ? other.minX : other.minY) < end else { return }
                if otherRank > rank && box.overlaps(other) { nearby.append(otherRank) }
                visit(mid + 1, hi)
            }
            visit(0, ranksByStart.count)
            nearby.sort()
        }
    }
}
