import Foundation
import CoreGraphics

/// The shared, model-free paragraph graph. RF boxes are hints, never contours.
/// No text, platform API, page identity, cache or provider is read here.
enum NativeSimpleParagraphGrouping {
    static let policyVersion = "simple-paragraph-v2-literal-native-same125-parallel100-scale200-rftext-component-ulp4-conflict-060-030-vertical-endfree-v1-column-order-v3-row-boundary-v1"
    struct Scope {
        let owner: Int
        let box: CGRect
        let confidence: Double
    }
    struct Input {
        let polygon: [CGPoint]
        let orientation: BrowserOCRSourceOrientation
        let operation: Int
        let confidence: Double
        var source = ""
    }
    struct Group {
        let members: [Int]
        let representative: Int
        let readingOrder: [Int]
        let polygon: [CGPoint]
        let orientation: BrowserOCRSourceOrientation
        let singleVerticalColumn: Bool
    }
    private struct Atom {
        let input: Input
        let box: CGRect
        let along: CGPoint
        let balloon: Scope?
        let text: Set<Int>?
    }
    private struct Edge {
        let distance: CGFloat
        let low: [CGFloat]
        let high: [CGFloat]
        let first: Int
        let second: Int
    }
    private static func unit(_ v: CGPoint) -> CGPoint? {
        let length = hypot(v.x, v.y)
        return length > 0 ? CGPoint(x: v.x/length, y: v.y/length) : nil
    }
    private static func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()!-xs.min()!, height: ys.max()!-ys.min()!)
    }
    private static func axis(_ input: Input) -> CGPoint {
        let p = input.polygon, vertical = input.orientation == .vertical
        var result: CGPoint? = nil
        if p.count == 4 {
            result = vertical ? unit(.init(x: p[3].x+p[2].x-p[0].x-p[1].x, y: p[3].y+p[2].y-p[0].y-p[1].y))
                : unit(.init(x: p[1].x+p[2].x-p[0].x-p[3].x, y: p[1].y+p[2].y-p[0].y-p[3].y))
        }
        var v = result ?? (vertical ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0))
        if (vertical ? v.y : v.x) < 0 { v = .init(x: -v.x, y: -v.y) }
        return v
    }
    private struct Extents {
        var start: CGFloat, end: CGFloat, low: CGFloat, high: CGFloat
        var maxULP: CGFloat { max(max(start.ulp, end.ulp), max(low.ulp, high.ulp)) }
    }
    private static func extents(_ points: [CGPoint], along: CGPoint, cross: CGPoint) -> Extents {
        var span = Extents(start: .infinity, end: -.infinity, low: .infinity, high: -.infinity)
        for p in points {
            let a = p.x*along.x + p.y*along.y, c = p.x*cross.x + p.y*cross.y
            span.start = min(span.start, a)
            span.end = max(span.end, a)
            span.low = min(span.low, c)
            span.high = max(span.high, c)
        }
        return span
    }
    private static func intervals(_ points: [CGPoint], _ along: CGPoint, _ vertical: Bool) -> ([CGFloat], [CGFloat], CGPoint) {
        let cross = vertical ? CGPoint(x: along.y, y: -along.x) : CGPoint(x: -along.y, y: along.x)
        let span = extents(points, along: along, cross: cross)
        return ([span.start, span.end], [span.low, span.high], cross)
    }
    private static func overlap(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat { max(0, min(a[1], b[1])-max(a[0], b[0])) }
    private static func commonColumn(_ indices: [Int], cross: [[CGFloat]]) -> Bool {
        let shared = indices.map { cross[$0][1] }.min()! - indices.map { cross[$0][0] }.max()!
        return shared >= indices.map { cross[$0][1] - cross[$0][0] }.min()! / 2
    }

    private static func orderedDisjoint(_ indices: [Int], along: [[CGFloat]]) -> [Int]? {
        let sorted = indices.sorted { along[$0][0] == along[$1][0] ? $0 < $1 : along[$0][0] < along[$1][0] }
        return zip(sorted, sorted.dropFirst()).allSatisfy { along[$0.0][1] <= along[$0.1][0] } ? sorted : nil
    }

    /// Correct only order within a contiguous run of one unambiguous column.
    /// Cross-column run order and all grouping/representative metadata are untouched.
    private static func orderColumnRuns(_ legacy: [Int], along: [[CGFloat]], cross: [[CGFloat]]) -> [Int] {
        var parents = Array(legacy.indices)
        func root(_ i: Int) -> Int {
            var node = i
            while parents[node] != node {
                parents[node] = parents[parents[node]]
                node = parents[node]
            }
            return node
        }
        for i in parents.indices {
            for j in (i + 1)..<parents.count where commonColumn([i, j], cross: cross) {
                let a = root(i), b = root(j)
                parents[b] = a
            }
        }
        let columns = Dictionary(grouping: Array(parents.indices), by: root)
        var lane = [Int?](repeating: nil, count: parents.count)
        for (id, column) in columns where column.count > 1 {
            // Pairwise overlaps may chain across columns; require a common strip.
            guard commonColumn(column, cross: cross), orderedDisjoint(column, along: along) != nil else { continue }
            for index in column { lane[index] = id }
        }
        var order = legacy
        var start = 0
        while start < legacy.count {
            guard let id = lane[legacy[start]] else { start += 1; continue }
            var end = start + 1
            while end < legacy.count && lane[legacy[end]] == id { end += 1 }
            if end - start > 1, let sorted = orderedDisjoint(Array(legacy[start..<end]), along: along) {
                order.replaceSubrange(start..<end, with: sorted)
            }
            start = end
        }
        return order
    }

    private static func coverage(_ a: CGRect, _ b: CGRect) -> CGFloat {
        guard a.width > 0, a.height > 0 else { return 0 }
        let width = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let height = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        return width*height/(a.width*a.height)
    }
    private static func key(_ box: CGRect) -> [CGFloat] { [box.minX, box.minY, box.maxX, box.maxY] }
    private static func less(_ a: [CGFloat], _ b: [CGFloat]) -> Bool { a.lexicographicallyPrecedes(b) }
    private static func distance(_ a: Atom, _ b: Atom) -> (gap: CGFloat, isParallel: Bool)? {
        guard a.along.x*b.along.x+a.along.y*b.along.y >= cos(.pi/12),
              let direction = unit(.init(x: a.along.x+b.along.x, y: a.along.y+b.along.y)) else { return nil }
        let vertical = a.input.orientation == .vertical
        let cross = vertical ? CGPoint(x: direction.y, y: -direction.x) : CGPoint(x: -direction.y, y: direction.x)
        let x = extents(a.input.polygon, along: direction, cross: cross)
        let y = extents(b.input.polygon, along: direction, cross: cross)
        let ga = x.high-x.low, gb = y.high-y.low, glyph = min(ga, gb)
        guard glyph > 0, max(ga, gb) <= glyph*2 else { return nil }
        let ag = max(x.start, y.start)-min(x.end, y.end), cg = max(x.low, y.low)-min(x.high, y.high)
        let sameLimit = glyph*1.25, parallelLimit = glyph
        let epsilon = max(max(x.maxULP, y.maxULP), max(max(glyph.ulp, sameLimit.ulp), max(ag.ulp, cg.ulp)))*4
        let same = max(0, -cg) >= glyph/2 && ag >= -glyph/4 && ag <= sameLimit+epsilon
        let shorter = min(x.end-x.start, y.end-y.start)
        let parallel = cg >= -glyph/4 && cg <= parallelLimit+epsilon
            && max(0, -ag) >= shorter/2 && shorter >= glyph*1.5
            && (vertical || min(abs(x.start-y.start), abs(x.end-y.end)) <= glyph*1.5)
        return same || parallel ? (max(0, same ? ag : cg)/glyph, !same) : nil
    }

    /// Evaluate the nearest source rows on each side of an accepted tree edge.
    /// A shared RF box is not enough to make two separately set rows one paragraph.
    private static func hasHorizontalRowBoundary(_ left: [Int], _ right: [Int], atoms: [Atom]) -> Bool {
        let both = left+right
        guard let direction = unit(both.sorted().reduce(CGPoint.zero, {
            .init(x: $0.x+atoms[$1].along.x, y: $0.y+atoms[$1].along.y)
        })) else { return false }
        let frames = Dictionary(uniqueKeysWithValues: both.map { ($0, intervals(atoms[$0].input.polygon, direction, false)) })
        var nearest: (gap: CGFloat, i: Int, j: Int)?
        for i in left { for j in right {
            let a = frames[i]!.1, b = frames[j]!.1
            let gap = max(a[0], b[0])-min(a[1], b[1])
            if gap < 0 { return false }
            if nearest == nil || gap < nearest!.gap { nearest = (gap, i, j) }
        } }
        guard let (gap, i, j) = nearest else { return false }
        func measure(_ index: Int) -> (extent: [CGFloat], height: CGFloat, width: CGFloat, advance: CGFloat)? {
            let (extent, cross, _) = frames[index]!
            let height = cross[1]-cross[0], width = extent[1]-extent[0]
            let source = atoms[index].input.source.filter { !$0.isWhitespace }
            let count = source.count
            guard count > 0, height > 0, width > 0 else { return nil }
            let full = source.unicodeScalars.filter { scalar in
                switch scalar.value {
                case 0x2E80...0xA4CF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x323AF: true
                default: false
                }
            }.count
            let advance = width/CGFloat(count)
            return 2*full >= count && advance >= height*0.75 ? (extent, height, width, advance) : nil
        }
        guard let a = measure(i), let b = measure(j),
              overlap(a.extent, b.extent) >= 0.8*min(a.width, b.width) else { return false }
        let shorter = min(a.height, b.height)
        return gap >= 0.75*shorter || max(a.height, b.height) >= 1.25*shorter ||
            (gap >= 0.45*shorter && (max(a.width, b.width) >= 1.2*min(a.width, b.width) ||
                max(a.advance, b.advance) >= 1.25*min(a.advance, b.advance)))
    }

    /// Try removing one edge from the existing horizontal component. Using the
    /// accepted forest prevents unrelated candidate edges from reconnecting it.
    private static func splitHorizontalRows(_ members: [Int], links: [Edge], atoms: [Atom]) -> [[Int]] {
        guard members.count > 1, !links.isEmpty, let first = members.first else { return [members] }
        var neighbors: [Int: [(Int, Int)]] = [:]
        for (index, edge) in links.enumerated() {
            neighbors[edge.first, default: []].append((edge.second, index))
            neighbors[edge.second, default: []].append((edge.first, index))
        }
        for cut in links.indices {
            var seen: Set<Int> = [first]
            var stack = [first]
            while let i = stack.popLast() {
                for (j, edgeIndex) in neighbors[i] ?? [] where edgeIndex != cut {
                    if seen.insert(j).inserted { stack.append(j) }
                }
            }
            let left = members.filter { seen.contains($0) }
            let right = members.filter { !seen.contains($0) }
            if !right.isEmpty, hasHorizontalRowBoundary(left, right, atoms: atoms) { return [left, right] }
        }
        return [members]
    }

    /// Nil means invalid geometry, not an empty or filtered page.
    static func group(_ inputs: [Input], textScopes: [Scope], balloons: [Scope]) -> [Group]? {
        guard inputs.allSatisfy({ $0.polygon.count >= 3 && $0.polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite } }),
              (textScopes+balloons).allSatisfy({ !$0.box.isNull && [$0.box.minX, $0.box.minY, $0.box.maxX, $0.box.maxY].allSatisfy(\.isFinite) && $0.confidence.isFinite }) else { return nil }
        let atoms = inputs.map { input -> Atom in
            let box = bounds(input.polygon)
            let orientation = input.orientation == .unknown ? (box.height > box.width ? BrowserOCRSourceOrientation.vertical : .horizontal) : input.orientation
            let normalized = Input(polygon: input.polygon, orientation: orientation, operation: input.operation,
                confidence: input.confidence, source: input.source)
            let owners = balloons.filter { $0.confidence >= 0.5 && coverage(box, $0.box) >= 0.9 }
            let text = Set(textScopes.filter { $0.confidence >= 0.25 && coverage(box, $0.box) >= 0.8 }.map(\.owner))
            return .init(input: normalized, box: box, along: axis(normalized), balloon: owners.count == 1 ? owners[0] : nil, text: text.isEmpty ? nil : text)
        }
        var parent = Array(atoms.indices)
        var owners = atoms.map { $0.balloon?.owner }, texts = atoms.map(\.text)
        func find(_ index: Int) -> Int {
            var i = index
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        var edges: [Edge] = []
        for i in atoms.indices { for j in (i+1)..<atoms.count {
            let a = atoms[i], b = atoms[j]
            guard a.input.operation == b.input.operation, a.input.orientation == b.input.orientation else { continue }
            if let x = a.balloon, let y = b.balloon, x.owner != y.owner { continue }
            if let known = a.balloon {
                if coverage(b.box, known.box) < 0.9 { continue }
            } else if let known = b.balloon, coverage(a.box, known.box) < 0.9 { continue }
            guard let relation = distance(a, b) else { continue }
            // Keep weak unsupported parallel atoms separate; do not drop their source.
            let ca = a.input.confidence, cb = b.input.confidence
            if relation.isParallel, ca.isFinite, cb.isFinite,
               min(ca, cb) < 0.60, abs(ca - cb) >= 0.30,
               a.text.map({ x in b.text.map { x.isDisjoint(with: $0) } ?? true }) ?? true {
                continue
            }
            let x = key(a.box), y = key(b.box)
            edges.append(.init(distance: relation.gap, low: less(x, y) ? x : y, high: less(x, y) ? y : x, first: i, second: j))
        } }
        edges.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.low != $1.low { return less($0.low, $1.low) }
            if $0.high != $1.high { return less($0.high, $1.high) }
            if $0.first != $1.first { return $0.first < $1.first }
            return $0.second < $1.second
        }
        var horizontalForest: [Edge] = []
        for edge in edges {
            let a = find(edge.first), b = find(edge.second)
            guard a != b else { continue }
            if let x = owners[a], let y = owners[b], x != y { continue }
            if let x = texts[a], let y = texts[b], x.isDisjoint(with: y) { continue }
            let text = texts[a].flatMap { x in texts[b].map { x.intersection($0) } } ?? texts[a] ?? texts[b]
            parent[b] = a; owners[a] = owners[a] ?? owners[b]; texts[a] = text
            if atoms[edge.first].input.orientation == .horizontal { horizontalForest.append(edge) }
        }
        var components: [[Int]] = [], rootIndex: [Int: Int] = [:]
        for i in atoms.indices {
            let root = find(i)
            if rootIndex[root] == nil { rootIndex[root] = components.count; components.append([]) }
            components[rootIndex[root]!].append(i)
        }
        let horizontalLinks = Dictionary(grouping: horizontalForest) { find($0.first) }
        let finalized = components.flatMap { members -> [[Int]] in
            guard let links = horizontalLinks[find(members[0])] else { return [members] }
            return splitHorizontalRows(members, links: links, atoms: atoms)
        }.sorted { $0[0] < $1[0] }
        return finalized.map { members in
            let vertical = atoms[members[0]].input.orientation == .vertical
            let direction = unit(members.reduce(CGPoint.zero) { .init(x: $0.x+atoms[$1].along.x, y: $0.y+atoms[$1].along.y) })!
            let (a, c, cross) = intervals(members.flatMap { atoms[$0].input.polygon }, direction, vertical)
            let legacyOrder = members.sorted {
                let x = atoms[$0].box, y = atoms[$1].box
                let xa = vertical ? -x.midX : x.midY, ya = vertical ? -y.midX : y.midY
                if xa != ya { return xa < ya }
                let xb = vertical ? x.minY : x.minX, yb = vertical ? y.minY : y.minX
                return xb == yb ? $0 < $1 : xb < yb
            }
            let corners = vertical ? [(a[0], c[0]), (a[0], c[1]), (a[1], c[1]), (a[1], c[0])]
                : [(a[0], c[0]), (a[1], c[0]), (a[1], c[1]), (a[0], c[1])]
            let polygon = members.count == 1 ? atoms[members[0]].input.polygon : corners.map {
                CGPoint(x: $0.0*direction.x+$0.1*cross.x, y: $0.0*direction.y+$0.1*cross.y)
            }
            let projections = members.map { intervals(atoms[$0].input.polygon, direction, vertical) }
            let crossSpans = projections.map { $0.1 }
            let single = vertical && commonColumn(Array(members.indices), cross: crossSpans)
            var readingOrder = legacyOrder
            if vertical, members.count > 1 {
                let along = projections.map { $0.0 }
                if single {
                    if let sequence = orderedDisjoint(Array(members.indices), along: along) {
                        readingOrder = sequence.map { members[$0] }
                    }
                } else if members.count > 2 {
                    let indexByMember = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($0.element, $0.offset) })
                    readingOrder = orderColumnRuns(legacyOrder.map { indexByMember[$0]! }, along: along, cross: crossSpans)
                        .map { members[$0] }
                }
            }
            return .init(members: members, representative: legacyOrder[0], readingOrder: readingOrder, polygon: polygon,
                orientation: atoms[members[0]].input.orientation, singleVerticalColumn: single)
        }
    }
}
