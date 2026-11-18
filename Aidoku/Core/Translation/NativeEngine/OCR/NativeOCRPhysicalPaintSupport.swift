import Foundation

/// Live source support: live source CC cells define contact, never inferred ownership.
/// Reference records, physical measurements, model scores and output geometry are immutable.
/// No GT, page switch, coordinate lookup table, image color or new model is consulted.
enum NativeOCRPhysicalPaintSupport {
    struct Point: Codable, Hashable {
        let x: Double
        let y: Double
    }
    struct Run: Codable {
        let x: Int
        let y: Int
        let count: Int
    }
    struct Component: Codable {
        let token: String
        let mapWidth: Int
        let mapHeight: Int
        let sourceWidth: Int
        let sourceHeight: Int
        let runs: [Run]
    }
    struct RF: Codable {
        let canonicalClass: Int
        let confidence: Double
        let polygon: [Point]
    }
    struct Candidate: Codable {
        let polygon: [Point]
        let quality: Double?
        let bboxConfidence: Double?
        let detector: Double?
        let recognition: Double?
        let rfText: Double?
        let physical: Bool
        let halo: Bool
        let completeInk: Bool
        let family: String
    }
    struct Input: Codable {
        let sourceSHA256: String
        let fullReferenceSHA256: String
        let fullReferenceCount: Int
        let components: [Component]
        let rf: [RF]
        let rfAllQueries: Int
        let candidates: [Candidate]
        let finalIndices: [Int]
        let admittedIndices: [Int]
        let selectedIndices: [Int]
    }
    struct Replacement: Codable {
        let inputIndex: Int
        let witnessIndex: Int
        let cohort: Int
        let haloPreserved: Bool
        let exactCCCellCover: Bool
    }
    struct Output: Codable {
        let name: String
        let kept: [Int]
        let replacements: [Replacement]
        let missingEvidence: [Int]
        let cohorts: Int
    }
    struct Cell {
        let point: Point
        let cc: Int
    }
    struct Support {
        let components: [Int]
        let cells: Set<Int>
        let rfScope: Int
    }
    struct Cohort: Hashable {
        let components: [Int]
        let rfScope: Int
    }
    static func valid(_ p: [Point]) -> Bool {
        guard p.count == 4, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let crosses = (0..<4).map { i in cross(p[i], p[(i + 1) % 4], p[(i + 2) % 4]) }
        return crosses.allSatisfy { $0 > 0 } || crosses.allSatisfy { $0 < 0 }
    }
    static func cross(_ a: Point, _ b: Point, _ c: Point) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
    static func contains(_ q: [Point], _ p: Point) -> Bool {
        var positive = true
        var negative = true
        for i in 0..<4 {
            let v = cross(q[i], q[(i + 1) % 4], p)
            positive = positive && v >= -1e-9
            negative = negative && v <= 1e-9
        }
        return positive || negative
    }
    static func encloses(_ a: [Point], _ b: [Point]) -> Bool { b.allSatisfy { contains(a, $0) } }
    static func area(_ p: [Point]) -> Double {
        guard p.count >= 3 else { return 0 }
        return abs(p.indices.reduce(0.0) { s, i in s + p[i].x * p[(i + 1) % p.count].y - p[i].y * p[(i + 1) % p.count].x }) / 2
    }
    static func iou(_ a: [Point], _ b: [Point]) -> Double {
        var clipped = a
        let orientation = (b.indices.reduce(0.0) { $0 + b[$1].x * b[($1 + 1) % b.count].y - b[$1].y * b[($1 + 1) % b.count].x }) >= 0 ? 1.0 : -1.0
        for i in b.indices {
            let p = b[i]
            let q = b[(i + 1) % b.count]
            let previous = clipped
            guard var start = previous.last else { return 0 }
            clipped = []
            var d = orientation * cross(p, q, start)
            for end in previous {
                let e = orientation * cross(p, q, end)
                if (d >= 0) != (e >= 0) {
                    let f = d / (d - e)
                    clipped.append(.init(x: start.x + f * (end.x - start.x), y: start.y + f * (end.y - start.y)))
                }
                if e >= 0 { clipped.append(end) }
                start = end
                d = e
            }
        }
        let intersection = area(clipped)
        return intersection / max(Double.leastNormalMagnitude, area(a) + area(b) - intersection)
    }
    final class Bank {
        let input: Input
        let cells: [Cell]
        let support: [Support?]
        init(_ input: Input) {
            self.input = input
            var cells: [Cell] = []
            var seen = Set<String>()
            for (cc, c) in input.components.enumerated() where seen.insert(c.token).inserted {
                guard c.mapWidth > 0, c.mapHeight > 0, c.sourceWidth > 0, c.sourceHeight > 0 else { continue }
                let sx = Double(c.sourceWidth) / Double(c.mapWidth)
                let sy = Double(c.sourceHeight) / Double(c.mapHeight)
                for run in c.runs where run.x >= 0 && run.y >= 0 && run.count > 0 && run.x + run.count <= c.mapWidth && run.y < c.mapHeight {
                    for x in run.x..<(run.x + run.count) {
                        cells.append(.init(point: .init(x: (Double(x) + 0.5) * sx, y: (Double(run.y) + 0.5) * sy), cc: cc))
                    }
                }
            }
            cells.sort { $0.point.y == $1.point.y ? $0.point.x < $1.point.x : $0.point.y < $1.point.y }
            self.cells = cells
            var centers: [Int: Point] = [:]
            var sums: [Int: (Double, Double, Int)] = [:]
            for cell in cells {
                let old = sums[cell.cc] ?? (0, 0, 0)
                sums[cell.cc] = (old.0 + cell.point.x, old.1 + cell.point.y, old.2 + 1)
            }
            for (cc, v) in sums { centers[cc] = .init(x: v.0 / Double(v.2), y: v.1 / Double(v.2)) }
            var rfScopes: [[Int]: Int] = [:]
            var support: [Support?] = []
            for c in input.candidates {
                guard Self.available(c), input.rfAllQueries == 300, !cells.isEmpty else {
                    support.append(nil)
                    continue
                }
                let minY = c.polygon.map(\.y).min()!
                let maxY = c.polygon.map(\.y).max()!
                let minX = c.polygon.map(\.x).min()!
                let maxX = c.polygon.map(\.x).max()!
                var low = 0
                var high = cells.count
                while low < high {
                    let m = low + (high - low) / 2
                    if cells[m].point.y < minY { low = m + 1 } else { high = m }
                }
                var hits = Set<Int>()
                var cc = Set<Int>()
                var i = low
                while i < cells.count, cells[i].point.y <= maxY {
                    let p = cells[i].point
                    if p.x >= minX, p.x <= maxX, contains(c.polygon, p) {
                        hits.insert(i)
                        cc.insert(cells[i].cc)
                    }
                    i += 1
                }
                guard !hits.isEmpty else {
                    support.append(nil)
                    continue
                }
                // An RF scope is measured support, not an ownership assignment. A missing
                // primitive uses the source-bound all300 field already measured for this row.
                let tokens = cc.sorted()
                let best: Int
                if let cached = rfScopes[tokens] {
                    best = cached
                } else {
                    var chosen = -1
                    var score = 0.0
                    for (j, r) in input.rf.enumerated()
                    where [1, 3].contains(r.canonicalClass) && r.confidence.isFinite && r.confidence > 0 && valid(r.polygon) {
                        let count = tokens.reduce(0) { $0 + (contains(r.polygon, centers[$1]!) ? 1 : 0) }
                        let value = Double(count) / Double(tokens.count) * r.confidence
                        if value > score {
                            score = value
                            chosen = j
                        }
                    }
                    best = chosen
                    rfScopes[tokens] = best
                }
                support.append(.init(components: cc.sorted(), cells: hits, rfScope: best))
            }
            self.support = support
        }
        static func available(_ c: Candidate) -> Bool {
            guard valid(c.polygon), let q = c.quality, let b = c.bboxConfidence, let r = c.recognition, let rf = c.rfText else { return false }
            return [q, b, r, rf].allSatisfy { $0.isFinite } && (0.085...1).contains(b)
        }
        /// physical: same CC footprint + exact covered-cell superset; halo requires
        /// direct enclosure. evidence: also preserves source observations. canonical:
        /// body candidates use whole-CC contact identity; halo still never contracts.
        func select(indices: [Int], minimumDirectOverlap: Double = 0.85) -> Output {
            let rows = input.candidates
            let order = indices.sorted {
                let a = rows[$0].quality ?? -Double.infinity
                let b = rows[$1].quality ?? -Double.infinity
                if a != b { return a > b }
                return $0 < $1
            }
            var kept: [Int] = []
            var replacements: [Replacement] = []
            var missing: [Int] = []
            var cohorts: [Cohort: [Int]] = [:]
            var cohortIDs: [Cohort: Int] = [:]
            for i in order {
                let c = rows[i]
                guard let s = support[i] else {
                    kept.append(i)
                    missing.append(i)
                    continue
                }
                let key = Cohort(components: s.components, rfScope: s.rfScope)
                if cohortIDs[key] == nil { cohortIDs[key] = cohortIDs.count }
                var witness: Int?
                if c.physical {
                    for j in cohorts[key, default: []] {
                        let w = rows[j]
                        if !w.physical { continue }
                        if minimumDirectOverlap > 0 && iou(c.polygon, w.polygon) < minimumDirectOverlap { continue }
                        // A witnessed outer stroke is never contracted into a core localization.
                        if c.halo && (!w.halo || !encloses(w.polygon, c.polygon)) { continue }
                        if c.completeInk && (!w.completeInk || !encloses(w.polygon, c.polygon)) { continue }
                        if !s.cells.isSubset(of: support[j]!.cells) { continue }
                        // No untrusted synthetic boundary or transferred provenance is emitted.
                        witness = j
                        break
                    }
                }
                if let j = witness {
                    replacements.append(
                        .init(
                            inputIndex: i, witnessIndex: j, cohort: cohortIDs[key]!, haloPreserved: !c.halo || encloses(rows[j].polygon, c.polygon),
                            exactCCCellCover: s.cells.isSubset(of: support[j]!.cells)))
                } else {
                    kept.append(i)
                    cohorts[key, default: []].append(i)
                }
            }
            return .init(
                name: "physical-paint-direct", kept: kept.sorted(), replacements: replacements, missingEvidence: missing, cohorts: cohortIDs.count)
        }
    }
}
