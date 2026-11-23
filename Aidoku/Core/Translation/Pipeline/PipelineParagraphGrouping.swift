import Foundation
import CoreGraphics

/// Model-free paragraph graph over pipeline lines. RF boxes are hints, never contours.
enum PipelineParagraphGrouping {
    /// Minimum fraction of a line inside an owning balloon for an edge to
    /// a line of that balloon (legacy 0.9; the pipeline selects 0.7).
    static let balloonEdgeCoverage: CGFloat = 0.7
    /// Neighbouring columns/rows may overlap across by up to this many glyphs and still be parallel
    /// (tight or slanted columns; legacy 0.25). Merge GT, train folds: 0.6-1.0 is one plateau,
    /// fragmentation 28 -> 19 with no extra wrong joins; dev exact pages 169 -> 172.
    static let parallelOverlap: CGFloat = 0.6
    struct Scope {
        let owner: Int
        let box: CGRect
        let confidence: Double
    }
    struct Input {
        let polygon: [CGPoint]
        let vertical: Bool
        let confidence: Double
        var source = ""
    }
    struct Group {
        let members: [Int]
        let readingOrder: [Int]
        let polygon: [CGPoint]
        let vertical: Bool
        /// Ruby lines erased with the group but not part of its text.
        var readings: [Int] = []
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
        let p = input.polygon, vertical = input.vertical
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
        // Neighbours may overlap by up to half the shorter one (a fragment cut off a column end).
        return zip(sorted, sorted.dropFirst()).allSatisfy { i, j in
            along[i][1] - along[j][0] <= min(along[i][1] - along[i][0], along[j][1] - along[j][0])/2
        } ? sorted : nil
    }

    /// Correct only order within a contiguous run of one unambiguous column.
    /// Cross-column run order and grouping are untouched.
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

    private static func key(_ box: CGRect) -> [CGFloat] { [box.minX, box.minY, box.maxX, box.maxY] }
    private static func less(_ a: [CGFloat], _ b: [CGFloat]) -> Bool { a.lexicographicallyPrecedes(b) }
    private static func distance(_ a: Atom, _ b: Atom) -> (gap: CGFloat, isParallel: Bool)? {
        guard a.along.x*b.along.x+a.along.y*b.along.y >= cos(.pi/12),
              let direction = unit(.init(x: a.along.x+b.along.x, y: a.along.y+b.along.y)) else { return nil }
        let vertical = a.input.vertical
        let cross = vertical ? CGPoint(x: direction.y, y: -direction.x) : CGPoint(x: -direction.y, y: direction.x)
        let x = extents(a.input.polygon, along: direction, cross: cross)
        let y = extents(b.input.polygon, along: direction, cross: cross)
        let ga = x.high-x.low, gb = y.high-y.low, glyph = min(ga, gb)
        guard glyph > 0 else { return nil }
        let fits = max(ga, gb) <= glyph*2
        let sharedText = a.text.map { x in b.text.map { !x.isDisjoint(with: $0) } ?? false } ?? false
        let ag = max(x.start, y.start)-min(x.end, y.end), cg = max(x.low, y.low)-min(x.high, y.high)
        // Same-column continuation: a 2 glyph gap, 4 below an unclosed quote; a shared RF text scope
        // lifts the width-fit limit, and one RF balloon allows a wider gutter.
        let sameBalloon = a.balloon != nil && a.balloon?.owner == b.balloon?.owner
        let sameLimit = glyph*(hasOpenQuote((x.start <= y.start ? a : b).input.source) ? 4 : 2)
        let parallelLimit = glyph*(sameBalloon ? 1.25 : 1)
        let epsilon = max(max(x.maxULP, y.maxULP), max(max(glyph.ulp, sameLimit.ulp), max(ag.ulp, cg.ulp)))*4
        // A one- or two-glyph fragment cut off a column or row end continues it, measured in the full line's glyphs.
        let fragments = [a, b].map { $0.input.source.filter { !$0.isWhitespace }.count <= 2 }
        if fragments[0] != fragments[1] {
            let (f, o) = fragments[0] ? (x, y) : (y, x)
            let thick = o.high-o.low
            if f.high-f.low <= thick*1.3, overlap([f.low, f.high], [o.low, o.high]) >= (f.high-f.low)/2,
               ag >= -(f.end-f.start)/2, ag <= thick*1.5 {
                return (max(0, ag)/thick, false)
            }
        }
        let same = (fits || sharedText) && max(0, -cg) >= glyph/2 && ag >= -glyph/4 && ag <= sameLimit+epsilon
        let shorter = min(x.end-x.start, y.end-y.start)
        let parallel = fits && cg >= -glyph*parallelOverlap && cg <= parallelLimit+epsilon
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

    // Legacy utterance boundaries (NativeParagraphFragmentGrouping+Pipeline 128-257, 1874, 2757).
    private static func opens(_ text: String) -> Bool { text.first { !$0.isWhitespace }.map { "「『“\"".contains($0) } ?? false }
    private static func closes(_ text: String) -> Bool {
        text.last { !$0.isWhitespace && $0 != "♡" && $0 != "♥" }.map { "。.!?！？…」』".contains($0) } ?? false
    }
    private static func hasOpenQuote(_ text: String) -> Bool {
        let pairs: [Character: Character] = ["「": "」", "『": "』", "（": "）", "(": ")", "“": "”"]
        var stack: [Character] = []
        for c in text {
            if let closing = pairs[c] { stack.append(closing) } else if stack.last == c { stack.removeLast() }
        }
        return !stack.isEmpty
    }
    /// Two components that must stay separate paragraphs.
    private static func utteranceBoundary(_ x: [Int], _ y: [Int], atoms: [Atom], sharedText: Bool) -> Bool {
        let vertical = atoms[x[0]].input.vertical
        func text(_ ids: [Int]) -> String {
            ids.sorted {
                let a = atoms[$0].box, b = atoms[$1].box
                return vertical ? (a.midX, b.minY) > (b.midX, a.minY) : (a.midY, a.minX) < (b.midY, b.minX)
            }.map { atoms[$0].input.source }.joined()
        }
        func box(_ ids: [Int]) -> CGRect { ids.reduce(CGRect.null) { $0.union(atoms[$1].box) } }
        func thickness(_ i: Int) -> CGFloat { vertical ? atoms[i].box.width : atoms[i].box.height }
        let a = text(x), b = text(y), p = box(x), q = box(y)
        if opens(a) && closes(a) && opens(b) && closes(b) { return true }
        // Along = y for columns, x for rows; cross the other axis.
        let along = vertical ? (min(p.maxY, q.maxY) - max(p.minY, q.minY)) : (min(p.maxX, q.maxX) - max(p.minX, q.minX))
        let cross = vertical ? (min(p.maxX, q.maxX) - max(p.minX, q.minX)) : (min(p.maxY, q.maxY) - max(p.minY, q.minY))
        if opens(a) && opens(b) {
            let glyph = min(x.map(thickness).min()!, y.map(thickness).min()!)
            let leading = (vertical ? p.minY <= q.minY : p.minX <= q.minX) ? a : b
            return !(hasOpenQuote(leading) && cross >= glyph*0.75 && -along <= glyph*2)
        }
        guard vertical, closes(a) || closes(b), !sharedText else { return false }
        let widths = (x+y).map(thickness).sorted(), glyph = widths[widths.count/2]
        return -cross > glyph*0.75 && along >= min(p.height, q.height)*0.25
    }

    /// Nil means invalid geometry, not an empty or filtered page.
    static func group(_ inputs: [Input], textScopes: [Scope], balloons: [Scope],
                      joins: ((Int, Int) -> CGFloat?)? = nil) -> [Group]? {
        guard inputs.allSatisfy({ $0.polygon.count >= 3 && $0.polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite } }),
              (textScopes+balloons).allSatisfy({
                  !$0.box.isNull && [$0.box.minX, $0.box.minY, $0.box.maxX, $0.box.maxY].allSatisfy(\.isFinite)
                      && $0.confidence.isFinite
              }) else { return nil }
        var atoms = inputs.map { input -> Atom in
            let box = bounds(input.polygon)
            let owners = balloons.filter { $0.confidence >= Double(PipelineLayoutRegion.balloonFloor) && PipelineLineAssembly.coverage(box, $0.box) >= 0.9 }
            let text = Set(textScopes.filter { $0.confidence >= 0.25 && PipelineLineAssembly.coverage(box, $0.box) >= 0.8 }.map(\.owner))
            return .init(input: input, box: box, along: axis(input), balloon: owners.count == 1 ? owners[0] : nil,
                         text: text.isEmpty ? nil : text)
        }
        var parent = Array(atoms.indices)
        var owners = atoms.map { $0.balloon?.owner }, texts = atoms.map(\.text), members = atoms.indices.map { [$0] }
        func find(_ index: Int) -> Int {
            var i = index
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        // A one-glyph line's direction is a guess: it may join a column or a row (legacy P:4447-4460).
        func guessed(_ atom: Atom) -> Bool { atom.input.source.filter { !$0.isWhitespace }.count == 1 }
        func flipped(_ atom: Atom) -> Atom {
            let input = Input(polygon: atom.input.polygon, vertical: !atom.input.vertical, confidence: atom.input.confidence,
                              source: atom.input.source)
            return .init(input: input, box: atom.box, along: axis(input), balloon: atom.balloon, text: atom.text)
        }
        func quoted(_ root: Int) -> Bool { members[root].contains { atoms[$0].input.source.contains(where: "「」『』".contains) } }
        let rails = rubyRails(atoms)
        var edges: [Edge] = []
        for i in atoms.indices where rails[i] == nil { for j in (i+1)..<atoms.count where rails[j] == nil {
            var a = atoms[i], b = atoms[j]
            if a.input.vertical != b.input.vertical {
                if guessed(b) { b = flipped(b) } else if guessed(a) { a = flipped(a) } else { continue }
            }
            if let x = a.balloon, let y = b.balloon, x.owner != y.owner { continue }
            if let known = a.balloon {
                if PipelineLineAssembly.coverage(b.box, known.box) < balloonEdgeCoverage { continue }
            } else if let known = b.balloon, PipelineLineAssembly.coverage(a.box, known.box) < balloonEdgeCoverage { continue }
            guard let relation = distance(a, b) ?? joins?(i, j).map({ ($0, false) }) else { continue }
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
            // SFX guard: a component outside every RF text scope and without a quote mark never joins quoted speech.
            if (texts[a] == nil) != (texts[b] == nil), quoted(texts[a] == nil ? b : a), !quoted(texts[a] == nil ? a : b) { continue }
            let shared = texts[a].flatMap { x in texts[b].map { x.intersection($0) } }
            if utteranceBoundary(members[a], members[b], atoms: atoms, sharedText: shared != nil) { continue }
            if atoms[a].input.vertical != atoms[b].input.vertical {
                guard let side = [b, a].first(where: { members[$0].allSatisfy { guessed(atoms[$0]) } }) else { continue }
                for k in members[side] { atoms[k] = flipped(atoms[k]) }
            }
            let text = shared ?? texts[a] ?? texts[b]
            parent[b] = a; owners[a] = owners[a] ?? owners[b]; texts[a] = text; members[a] += members[b]
            if !atoms[edge.first].input.vertical { horizontalForest.append(edge) }
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
        let groups = finalized.filter { rails[$0[0]] == nil }.map { members -> Group in
            let vertical = atoms[members[0]].input.vertical
            // Opposed or non-finite axes (overflowing polygon coordinates) can sum to no direction.
            let direction = unit(members.reduce(CGPoint.zero) { .init(x: $0.x+atoms[$1].along.x, y: $0.y+atoms[$1].along.y) })
                .flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
                ?? (vertical ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0))
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
            return .init(members: members, readingOrder: readingOrder, polygon: polygon, vertical: vertical)
        }
        return groups.map { group in
            var group = group
            group.readings = rails.keys.sorted().filter { group.members.contains(rails[$0]!) }
            return group
        }
    }

    /// Legacy intercolumn ruby (NativeParagraphFragmentGrouping 66-134): a kana-only singleton
    /// column at most 1/1.5 as wide, just right of ONE kanji column and within its extent, is
    /// erased with that host and never translated, unless it continues another column end to end.
    private static func rubyRails(_ atoms: [Atom]) -> [Int: Int] {
        func kana(_ s: Unicode.Scalar) -> Bool {
            (0x3041...0x3096).contains(s.value) || (0x30A1...0x30FA).contains(s.value) || [0x3099, 0x309A, 0x30FC].contains(s.value)
        }
        func kanji(_ s: Unicode.Scalar) -> Bool { (0x3400...0x9FFF).contains(s.value) || (0xF900...0xFAFF).contains(s.value) }
        var rails: [Int: Int] = [:]
        for (i, rail) in atoms.enumerated() where rail.input.vertical {
            let c = rail.box, text = rail.input.source.unicodeScalars
            guard c.height > c.width, !text.isEmpty, text.allSatisfy(kana) else { continue }
            let hosts = atoms.indices.filter { j in
                let h = atoms[j].box, size = h.width, gap = c.minX - h.maxX
                return j != i && atoms[j].input.vertical && h.height > size && c.width*1.5 <= size
                    && atoms[j].input.source.unicodeScalars.contains(where: kanji)
                    && gap >= -size/4 && gap <= size/2 && c.midX > h.maxX - size/4
                    && c.minY >= h.minY - size/4 && c.maxY <= h.maxY + size/4
            }
            guard hosts.count == 1, let host = hosts.first else { continue }
            let continues = atoms.indices.contains { j in
                let p = atoms[j].box, glyph = min(c.width, p.width)
                let gap = max(c.minY, p.minY) - min(c.maxY, p.maxY)
                return j != i && j != host && atoms[j].input.vertical && max(c.width, p.width) >= atoms[host].box.width*0.75
                    && max(c.width, p.width) <= glyph*1.8 && abs(c.midX - p.midX) <= glyph/2
                    && gap >= -min(c.height, p.height)/4 && gap <= glyph*0.75
            }
            if !continues { rails[i] = host }
        }
        return rails
    }
}
