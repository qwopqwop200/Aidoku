import Foundation
import CoreGraphics

/// S4 paragraph grouping, a cascade over line pairs: obvious joins by rule, the ambiguous pairs by a 7-feature
/// logistic resolver, its unsure band by the nearest-column fallback rule. RF boxes are hints, never contours.
/// Fitted on the train folds (benchmark `cascade_abstain` with 7 features, constants in `Model`), plus three
/// residual rules (port-eval/stageopt/grouping2, `hyb`): stacked pieces in one RF text box join, horizontal CJK lines
/// of different char pitch never join, vertical columns bridged by misoriented rows of their RF text box join.
enum PipelineParagraphGrouping {
    struct Input {
        let polygon: [CGPoint]
        let bounds: CGRect
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

    /// A line in reading axes: `u` across (increasing to the next column / row), `v` along the line.
    private struct Line {
        var u0: CGFloat, u1: CGFloat, v0: CGFloat, v1: CGFloat
        let vertical: Bool
        /// Across thickness, at least 1 px (feature scale).
        let width: CGFloat
        /// Thickness over the page-median line thickness.
        let relative: CGFloat
        /// SFX, art or a blob: joins at most one partner.
        let junk: Bool
        /// RF text/balloon regions holding 80% of the line.
        let regions: Set<Int>
        /// The RF text box and the balloon holding most (>= 50%) of the line.
        let textBox: Int?
        let balloon: Int?
        let letters: Int
        let ends: Bool
        let cjk: CGFloat
        /// Along length over letters (0 without text).
        let pitch: CGFloat
    }

    /// Candidate pair (i, j): j is i's next column / row (`next`), stacked below it in one column, or overlapping it.
    private enum Kind { case next, stacked, overlap }

    /// Resolver: logistic regression over standardized features (gap in median thicknesses, head offset, same RF text
    /// box, same balloon, first line ends a sentence, CJK share, relative thickness), its abstain band, and the R2 pitch
    /// ratio: horizontal CJK lines whose char pitch differs more than this are different paragraphs (title over
    /// subtitle; nil = no veto). Resources/Translation/PipelineGrouping.json, fit on TRAIN pages by
    /// Scripts/pipeline/tools/retrain/grouping/train.py (Python reference: ref.py). Without it the resolver abstains.
    struct Model: Decodable, Sendable {
        let features: [String]
        let mean: [CGFloat]
        let scale: [CGFloat]
        let weights: [CGFloat]
        let bias: CGFloat
        let joinAbove: CGFloat
        let cutBelow: CGFloat
        let pitchRatio: CGFloat?

        static let shared: Model? = {
            var urls = [Bundle.main.url(forResource: "PipelineGrouping", withExtension: "json")].compactMap { $0 }
            if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] {
                urls.append(URL(fileURLWithPath: root).appendingPathComponent("Aidoku/Resources/Translation/PipelineGrouping.json"))
            }
            let names = ["gap_med", "head", "rftext_same", "balloon_same", "A_end", "min_cjk", "max_wn"]
            return urls.lazy.compactMap { try? Data(contentsOf: $0) }
                .compactMap { try? JSONDecoder().decode(Model.self, from: $0) }
                .first { $0.features == names && [$0.mean, $0.scale, $0.weights].allSatisfy { $0.count == names.count } }
        }()
    }

    private static let sentenceEnds = Set("。．.！!？?…‥」』）)〉》】♡♥♪".unicodeScalars)

    /// Nil means invalid geometry, not an empty page.
    static func group(_ inputs: [Input], layout: [PipelineLayoutRegion]) -> [Group]? {
        guard inputs.allSatisfy({
            $0.polygon.count >= 3 && $0.polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite } && edges($0.bounds).allSatisfy(\.isFinite)
        }) else { return nil }
        let layout = layout.filter { edges($0.bounds).allSatisfy(\.isFinite) }
        let (lines, median) = prepare(inputs, layout: layout)
        let root = cascade(lines, median: median)
        let rails = rubyRails(inputs)
        var components: [[Int]] = [], rootIndex: [Int: Int] = [:]
        for i in inputs.indices where rails[i] == nil {
            if rootIndex[root[i]] == nil { rootIndex[root[i]] = components.count; components.append([]) }
            components[rootIndex[root[i]]!].append(i)
        }
        return components.map { members in
            var group = assemble(members, inputs)
            group.readings = rails.keys.sorted().filter { members.contains(rails[$0]!) }
            return group
        }
    }

    private static func edges(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.maxX, r.maxY] }

    /// Share of `b`'s area inside `r`.
    private static func frac(_ b: CGRect, _ r: CGRect) -> CGFloat {
        let ix = max(0, min(b.maxX, r.maxX) - max(b.minX, r.minX)) * max(0, min(b.maxY, r.maxY) - max(b.minY, r.minY))
        return ix / max(1e-6, (b.maxX - b.minX) * (b.maxY - b.minY))
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x2E80...0xA4CF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF: true
        default: false
        }
    }

    /// The lines in reading axes and the page-median line thickness.
    private static func prepare(_ inputs: [Input], layout: [PipelineLayoutRegion]) -> ([Line], CGFloat) {
        let thick = inputs.map { min($0.bounds.maxX - $0.bounds.minX, $0.bounds.maxY - $0.bounds.minY) }.sorted()
        let median = thick.isEmpty ? 1 : max(1, thick[thick.count / 2])
        let scopes = layout.filter { $0.kind == .text || $0.kind == .balloon }.map(\.bounds)
        let texts = layout.filter { $0.kind == .text }.map(\.bounds)
        let balloons = layout.filter { $0.kind == .balloon }.map(\.bounds)
        let sfx = layout.filter { $0.kind == .sfx }.map(\.bounds)
        /// The region holding most of `b` (first on ties), if it holds at least half.
        func owner(_ b: CGRect, _ regions: [CGRect]) -> Int? {
            var best: (Int, CGFloat)?
            for (k, r) in regions.enumerated() where best == nil || frac(b, r) > best!.1 { best = (k, frac(b, r)) }
            return best.flatMap { $0.1 >= 0.5 ? $0.0 : nil }
        }
        let lines = inputs.map { input in
            let b = input.bounds
            let (u0, u1, v0, v1) = input.vertical ? (-b.maxX, -b.minX, b.minY, b.maxY) : (b.minY, b.maxY, b.minX, b.maxX)
            let text = input.source.unicodeScalars.filter { !$0.properties.isWhitespace }
            let inScope = scopes.map { frac(b, $0) }.max() ?? 0, inSFX = sfx.map { frac(b, $0) }.max() ?? 0
            let relative = (u1 - u0) / median
            let junk = (inScope < 0.5 && (relative > 1.6 || input.confidence < 0.8 || inSFX > 0.5)) || (inScope < 0.9 && relative > 1.6)
            return Line(u0: u0, u1: u1, v0: v0, v1: v1, vertical: input.vertical, width: max(1, u1 - u0), relative: relative,
                        junk: junk, regions: Set(scopes.indices.filter { frac(b, scopes[$0]) >= 0.8 }),
                        textBox: owner(b, texts), balloon: owner(b, balloons), letters: text.count,
                        ends: text.last.map(sentenceEnds.contains) ?? false,
                        cjk: text.isEmpty ? 0 : CGFloat(text.filter(isCJK).count) / CGFloat(text.count),
                        pitch: text.isEmpty ? 0 : max(1, v1 - v0) / CGFloat(text.count))
        }
        return (lines, median)
    }

    private static func candidates(_ lines: [Line]) -> [(i: Int, j: Int, kind: Kind)] {
        var out: [(i: Int, j: Int, kind: Kind)] = []
        for (i, a) in lines.enumerated() {
            let wi = a.u1 - a.u0
            for (j, b) in lines.enumerated() where j != i && b.vertical == a.vertical {
                let wj = b.u1 - b.u0, w = (wi + wj) / 2
                let ov = min(a.v1, b.v1) - max(a.v0, b.v0), uov = min(a.u1, b.u1) - max(a.u0, b.u0)
                if ov > 0, uov > 0, ov * uov > 0.3 * min(wi * (a.v1 - a.v0), wj * (b.v1 - b.v0)) {
                    if i < j { out.append((i, j, .overlap)) }
                    continue
                }
                if ov > 0, b.u0 >= a.u0 + 0.5 * wi, b.u0 - a.u1 < 3 * w {
                    out.append((i, j, .next))
                } else if uov > 0.5 * min(wi, wj), b.v0 >= a.v1 - 0.2 * w, b.v0 - a.v1 < 3 * w {
                    out.append((i, j, .stacked))
                }
            }
        }
        return out
    }

    private struct Pair: Hashable { let i: Int, j: Int }

    /// The fallback rule: each line links to its nearest next column passing hand geometry rules; an aligned (loose)
    /// link is dropped where the chain around it is over 3x tighter.
    private static func fallbackLinks(_ lines: [Line], _ cand: [(i: Int, j: Int, kind: Kind)]) -> Set<Pair> {
        var byLine: [Int: [Int]] = [:], order: [Int] = []
        for c in cand where c.kind == .next {
            if byLine[c.i] == nil { order.append(c.i) }
            byLine[c.i, default: []].append(c.j)
        }
        var link: [Int: (j: Int, tight: Bool, gap: CGFloat)] = [:], linkOrder: [Int] = []
        for i in order where !lines[i].junk {
            let a = lines[i], wi = a.u1 - a.u0
            let options = byLine[i]!.filter { !lines[$0].junk }.sorted { x, y in
                let gx: CGFloat = lines[x].u0 - a.u1, gy: CGFloat = lines[y].u0 - a.u1
                return gx != gy ? gx < gy : x < y
            }
            for j in options {
                let b = lines[j], wj = b.u1 - b.u0, gap = b.u0 - a.u1
                let ov = min(a.v1, b.v1) - max(a.v0, b.v0), w = (wi + wj) / 2, head = abs(b.v0 - a.v0)
                let short = min(a.v1 - a.v0, b.v1 - b.v0), wr = max(wi, wj) / max(1e-6, min(wi, wj))
                if !a.regions.isEmpty, !b.regions.isEmpty, a.regions.isDisjoint(with: b.regions) { continue }
                if wr > 3.2 { continue }
                if !a.vertical, wr > 1.2, min(a.letters, b.letters) > 0, max(a.letters, b.letters) <= 5 { continue }
                var kind = 0
                if gap < 0.5 * w && (ov >= 0.75 * short || (ov >= 0.5 * short && wr < 1.5)) {
                    kind = 1
                } else if short - ov > max((1 - 0.9) * short, 0.7 * w) {
                    kind = 0
                } else if a.vertical {
                    kind = gap < 0.55 * w ? 1 : (gap < 0.9 * w && head < 0.8 * w ? 2 : 0)
                } else {
                    kind = gap < 1.2 * w ? 1 : 0
                }
                if kind > 0 {
                    link[i] = (j, kind == 1, gap / w); linkOrder.append(i)
                    break
                }
            }
        }
        var into: [Int: [CGFloat]] = [:]
        for i in linkOrder where link[i]!.tight { into[link[i]!.j, default: []].append(link[i]!.gap) }
        var accepted = Set<Pair>()
        for i in linkOrder {
            let (j, tight, gap) = link[i]!
            if !tight {
                var around = into[i] ?? []
                if let next = link[j], next.tight { around.append(next.gap) }
                if let tightest = around.min(), tightest < 0.33 * gap { continue }
            }
            accepted.insert(Pair(i: i, j: j))
        }
        return accepted
    }

    /// Union-find roots of the cascade's joins.
    private static func cascade(_ lines: [Line], median: CGFloat) -> [Int] {
        let cand = candidates(lines), fallback = fallbackLinks(lines, cand)
        // Nearest next-column gap out of / into each line, for the candidate rank.
        var outGap = [CGFloat](repeating: 9, count: lines.count), inGap = outGap
        for c in cand where c.kind == .next {
            let w = (lines[c.i].width + lines[c.j].width) / 2, g = (lines[c.j].u0 - lines[c.i].u1) / w
            outGap[c.i] = min(outGap[c.i], g); inGap[c.j] = min(inGap[c.j], g)
        }
        let model = Model.shared
        var joins: [(Pair, CGFloat)] = []
        for c in cand {
            let a = lines[c.i], b = lines[c.j], w = (a.width + b.width) / 2
            let wr = max(a.width, b.width) / min(a.width, b.width)
            let gap: CGFloat, ov: CGFloat, head: CGFloat
            if c.kind == .stacked {
                gap = (b.v0 - a.v1) / w; ov = (min(a.u1, b.u1) - max(a.u0, b.u0)) / min(a.width, b.width); head = abs(b.u0 - a.u0) / w
            } else {
                gap = (b.u0 - a.u1) / w; ov = (min(a.v1, b.v1) - max(a.v0, b.v0)) / max(1, min(a.v1 - a.v0, b.v1 - b.v0))
                head = abs(b.v0 - a.v0) / w
            }
            let rankI = c.kind == .next ? gap - outGap[c.i] : 0, rankJ = c.kind == .next ? gap - inGap[c.j] : 0
            let regionsDiffer = !a.regions.isEmpty && !b.regions.isEmpty && a.regions.isDisjoint(with: b.regions)
            let isFallback = fallback.contains(Pair(i: c.i, j: c.j))
            let junk = (a.junk ? 1 : 0) + (b.junk ? 1 : 0)
            let sameText = a.textBox != nil && a.textBox == b.textBox
            // Rules: a detector-split column inside one RF text box joins; horizontal CJK lines of different pitch never do.
            let stackedPiece = c.kind == .stacked && a.vertical && sameText && junk == 0
            if let ratio = model?.pitchRatio, c.kind == .next, !a.vertical, min(a.cjk, b.cjk) >= 0.5, min(a.letters, b.letters) >= 2,
               max(a.pitch, b.pitch) > ratio * min(a.pitch, b.pitch) { continue }
            // Stage 1: obvious joins (each tier 100% precise on the train folds).
            var core = stackedPiece || c.kind == .next && a.vertical && junk == 0 && gap < 0.45 && ov >= 0.9 && wr < 1.3 && !regionsDiffer
                && rankI <= 1e-9 && rankJ <= 1e-9
            core = core || (isFallback && a.vertical && gap < 0.55)
            core = core || (c.kind == .overlap && junk == 0 && wr < 2 && ov >= 0.8 && !regionsDiffer)
            core = core || (c.kind != .stacked && junk == 1 && ov >= 0.8 && gap < 0.5 && wr < 1.3)
            // Stage 2 on link-like pairs (a column further away never joins directly); stage 3 in the unsure band.
            let eligible = c.kind != .next || min(rankI, rankJ) <= 0.3 || isFallback
            var p: CGFloat = 1, resolved = isFallback
            if let m = model {
                let x: [CGFloat] = [gap * w / median, head,
                                    sameText ? 1 : 0, a.balloon != nil && a.balloon == b.balloon ? 1 : 0,
                                    a.ends ? 1 : 0, min(a.cjk, b.cjk), max(a.relative, b.relative)]
                var z = m.bias
                for k in x.indices { z += (x[k] - m.mean[k]) / m.scale[k] * m.weights[k] }
                p = 1 / (1 + exp(-z))
                resolved = p >= m.joinAbove || (p > m.cutBelow && isFallback)
            }
            if core || (eligible && resolved) { joins.append((Pair(i: c.i, j: c.j), p)) }
        }
        var parent = Array(lines.indices)
        func find(_ index: Int) -> Int {
            var i = index
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        // A junk line joins at most its strongest non-junk partner.
        var strongest: [Int: (CGFloat, Pair)] = [:]
        for (pair, p) in joins {
            let ja = lines[pair.i].junk, jb = lines[pair.j].junk
            if ja && jb { continue }
            if ja || jb {
                let k = ja ? pair.i : pair.j
                if strongest[k] == nil || p > strongest[k]!.0 { strongest[k] = (p, pair) }
            } else {
                let x = find(pair.i), y = find(pair.j)
                if x != y { parent[y] = x }
            }
        }
        for pair in strongest.values.map(\.1) + bridges(lines) {
            let x = find(pair.i), y = find(pair.j)
            if x != y { parent[y] = x }
        }
        return lines.indices.map(find)
    }

    /// Two vertical columns of one RF text box with two or more horizontal lines of that box centred between them:
    /// the detector read the middle columns as rows. Joins the columns and the rows.
    private static func bridges(_ lines: [Line]) -> [Pair] {
        var out: [Pair] = []
        for (i, a) in lines.enumerated() where a.vertical && !a.junk && a.textBox != nil {
            for (j, b) in lines.enumerated() where j != i && b.vertical && !b.junk && b.textBox == a.textBox {
                let w = (a.width + b.width) / 2
                guard b.u0 - a.u1 > 0.5 * w, min(a.v1, b.v1) - max(a.v0, b.v0) >= 0.3 * min(a.v1 - a.v0, b.v1 - b.v0) else { continue }
                let rows = lines.indices.filter { m in
                    let r = lines[m], across = -(r.v0 + r.v1) / 2, along = (r.u0 + r.u1) / 2
                    return !r.vertical && r.textBox == a.textBox && a.u1 < across && across < b.u0
                        && max(a.v0, b.v0) - w < along && along < min(a.v1, b.v1) + w
                }
                if rows.count >= 2 { out += [Pair(i: i, j: j)] + rows.map { Pair(i: i, j: $0) } }
            }
        }
        return out
    }

    /// Reading order and outline of one paragraph.
    private static func assemble(_ members: [Int], _ inputs: [Input]) -> Group {
        let vertical = inputs[members[0]].vertical
        // Opposed or non-finite axes (overflowing polygon coordinates) can sum to no direction.
        let direction = unit(members.reduce(CGPoint.zero) { let a = axis(inputs[$1]); return .init(x: $0.x+a.x, y: $0.y+a.y) })
            .flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
            ?? (vertical ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0))
        let (a, c, cross) = intervals(members.flatMap { inputs[$0].polygon }, direction, vertical)
        let legacyOrder = members.sorted {
            let x = bounds(inputs[$0].polygon), y = bounds(inputs[$1].polygon)
            let xa = vertical ? -x.midX : x.midY, ya = vertical ? -y.midX : y.midY
            if xa != ya { return xa < ya }
            let xb = vertical ? x.minY : x.minX, yb = vertical ? y.minY : y.minX
            return xb == yb ? $0 < $1 : xb < yb
        }
        let corners = vertical ? [(a[0], c[0]), (a[0], c[1]), (a[1], c[1]), (a[1], c[0])]
            : [(a[0], c[0]), (a[1], c[0]), (a[1], c[1]), (a[0], c[1])]
        let polygon = members.count == 1 ? inputs[members[0]].polygon : corners.map {
            CGPoint(x: $0.0*direction.x+$0.1*cross.x, y: $0.0*direction.y+$0.1*cross.y)
        }
        let projections = members.map { intervals(inputs[$0].polygon, direction, vertical) }
        let crossSpans = projections.map { $0.1 }
        var readingOrder = legacyOrder
        if vertical, members.count > 1 {
            let along = projections.map { $0.0 }
            if commonColumn(Array(members.indices), cross: crossSpans) {
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
    private static func intervals(_ points: [CGPoint], _ along: CGPoint, _ vertical: Bool) -> ([CGFloat], [CGFloat], CGPoint) {
        let cross = vertical ? CGPoint(x: along.y, y: -along.x) : CGPoint(x: -along.y, y: along.x)
        var start = CGFloat.infinity, end = -CGFloat.infinity, low = CGFloat.infinity, high = -CGFloat.infinity
        for p in points {
            let a = p.x*along.x + p.y*along.y, c = p.x*cross.x + p.y*cross.y
            start = min(start, a); end = max(end, a); low = min(low, c); high = max(high, c)
        }
        return ([start, end], [low, high], cross)
    }
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

    /// Intercolumn ruby: a kana-only singleton
    /// column at most 1/1.5 as wide, just right of ONE kanji column and within its extent, is
    /// erased with that host and never translated, unless it continues another column end to end.
    private static func rubyRails(_ inputs: [Input]) -> [Int: Int] {
        func kana(_ s: Unicode.Scalar) -> Bool {
            (0x3041...0x3096).contains(s.value) || (0x30A1...0x30FA).contains(s.value) || [0x3099, 0x309A, 0x30FC].contains(s.value)
        }
        func kanji(_ s: Unicode.Scalar) -> Bool { (0x3400...0x9FFF).contains(s.value) || (0xF900...0xFAFF).contains(s.value) }
        let boxes = inputs.map { bounds($0.polygon) }
        var rails: [Int: Int] = [:]
        for (i, rail) in inputs.enumerated() where rail.vertical {
            let c = boxes[i], text = rail.source.unicodeScalars
            guard c.height > c.width, !text.isEmpty, text.allSatisfy(kana) else { continue }
            let hosts = inputs.indices.filter { j in
                let h = boxes[j], size = h.width, gap = c.minX - h.maxX
                return j != i && inputs[j].vertical && h.height > size && c.width*1.5 <= size
                    && inputs[j].source.unicodeScalars.contains(where: kanji)
                    && gap >= -size/4 && gap <= size/2 && c.midX > h.maxX - size/4
                    && c.minY >= h.minY - size/4 && c.maxY <= h.maxY + size/4
            }
            guard hosts.count == 1, let host = hosts.first else { continue }
            let continues = inputs.indices.contains { j in
                let p = boxes[j], glyph = min(c.width, p.width)
                let gap = max(c.minY, p.minY) - min(c.maxY, p.maxY)
                return j != i && j != host && inputs[j].vertical && max(c.width, p.width) >= boxes[host].width*0.75
                    && max(c.width, p.width) <= glyph*1.8 && abs(c.midX - p.midX) <= glyph/2
                    && gap >= -min(c.height, p.height)/4 && gap <= glyph*0.75
            }
            if !continues { rails[i] = host }
        }
        return rails
    }
}
