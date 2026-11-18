import Foundation
import CoreGraphics

/// Source-observation relations from the live OCR pipeline. Page IDs and GT
/// fixtures are never inputs; physical ownership and reading stay separate.
enum NativeParagraphFragmentGrouping {
    static var policyVersion: String {
        simpleGroupingEnabled ? NativeSimpleParagraphGrouping.policyVersion :
            "source-observed-paragraph-closure-v2196-evidence-priority-gap125-ulp4" + (columnRubyRecoveryEnabled ? "" : "-no-column-ruby")
    }
    struct Atom {
        let index: Int
        let source: String
        let box: CGRect // Coordinates stay in the caller's source frame.
        let orientation: BrowserOCRSourceOrientation
        let owner: Int?
        var sourceColumnWidth: CGFloat? = nil
        var glyph: CGFloat { sourceColumnWidth ?? (orientation == .vertical ? box.width : box.height) }
    }
    struct Ink {
        let rgb: [Double]
        let samples: Int
    }
    struct Edge: Hashable {
        let first: Int
        let second: Int
        let reason: String
    }
    struct Result {
        let edges: [Edge]
    }
    /// Independently detected, widely spaced labels on the same baseline may
    /// use different writing systems. This is a boundary, not a word dictionary.
    static func independentInlineLabels(_ a: Atom, _ b: Atom) -> Bool {
        guard a.orientation == .horizontal, b.orientation == .horizontal else { return false }
        func script(_ text: String) -> Int? {
            var latin = false, cjk = false
            for scalar in text.unicodeScalars {
                latin = latin || (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
                cjk = cjk || (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value)
            }
            return latin == cjk ? nil : (latin ? 0 : 1)
        }
        guard let first = script(a.source), let second = script(b.source), first != second else { return false }
        let glyph = min(a.box.height, b.box.height)
        let gap = max(a.box.minX, b.box.minX) - min(a.box.maxX, b.box.maxX)
        let overlap = min(a.box.maxY, b.box.maxY) - max(a.box.minY, b.box.minY)
        return glyph > 0 && gap > glyph && overlap >= glyph * 0.75
    }
    struct TextScope {
        let owner: Int
        let box: CGRect
        let confidence: Double
    }

    /// Original-column ruby recovery is enabled in the live and saved-source routes.
    /// An explicit zero retains the previous policy for controlled comparisons.
    static var columnRubyRecoveryEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_COLUMN_RUBY_RECOVERY"] != "0"
    }


    /// A narrow full-size kana can start its own body column beside kanji.
    /// A compatible end-to-end body continuation is stronger evidence than
    /// apparent ruby placement beside that OTHER column. Use intrinsic axes,
    /// not screen-axis envelopes, and never join the sources in this predicate.
    static func hasInlineBodyContinuation(candidate:[CGPoint],continuation:[CGPoint],host:[CGPoint])->Bool {
        func frame(_ p:[CGPoint])->(u:CGPoint,v:CGPoint,width:CGFloat)? {
            guard p.count==4,p.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {return nil}
            let a=CGPoint(x:(p[1].x-p[0].x+p[2].x-p[3].x)/2,y:(p[1].y-p[0].y+p[2].y-p[3].y)/2)
            let b=CGPoint(x:(p[2].x-p[1].x+p[3].x-p[0].x)/2,y:(p[2].y-p[1].y+p[3].y-p[0].y)/2)
            let la=hypot(a.x,a.y),lb=hypot(b.x,b.y),along=la>=lb ? a:b,length=max(la,lb)
            guard min(la,lb)>0,length>0 else {return nil}
            let v=CGPoint(x:along.x/length,y:along.y/length)
            return (.init(x:v.y,y:-v.x),v,min(la,lb))
        }
        guard let c=frame(candidate),let p=frame(continuation),let h=frame(host),
              abs(c.v.x*p.v.x+c.v.y*p.v.y)>=0.9,
              max(c.width,p.width)>=h.width*0.75,c.width>=h.width*0.4,
              max(c.width,p.width)<=min(c.width,p.width)*1.8 else {return false}
        func box(_ points:[CGPoint])->CGRect {
            points.reduce(CGRect.null) { result,q in
                result.union(CGRect(x:q.x*c.u.x+q.y*c.u.y,y:q.x*c.v.x+q.y*c.v.y,width:0,height:0))
            }
        }
        let a=box(candidate),b=box(continuation),glyph=min(c.width,p.width)
        let shared=min(a.maxX,b.maxX)-max(a.minX,b.minX)
        let gap=max(a.minY,b.minY)-min(a.maxY,b.maxY)
        return shared>=min(a.width,b.width)*0.75 && abs(a.midX-b.midX)<=glyph*0.5 &&
            gap>=(-min(a.height,b.height)*0.25) && gap<=glyph*0.75
    }

    /// Locate a small kana rail beside ONE original vertical column, never beside
    /// the midpoint of a multi-column paragraph envelope. Ambiguous hosts abstain.
    /// Geometry is scale invariant; IDs, page numbers and literal words are not rules.
    static func intercolumnRubyHost(_ candidate: Atom, columns: [Atom]) -> Int? {
        let c = candidate.box
        guard candidate.orientation == .vertical, !c.isEmpty, !c.isNull,
              [c.minX, c.minY, c.maxX, c.maxY].allSatisfy(\.isFinite),
              c.height > c.width, !candidate.source.isEmpty,
              candidate.source.unicodeScalars.allSatisfy({ scalar in
                  (0x3041...0x3096).contains(scalar.value) || (0x30A1...0x30FA).contains(scalar.value) ||
                      [0x3099, 0x309A, 0x309D, 0x309E, 0x30FC, 0x30FD, 0x30FE].contains(scalar.value)
              }) else { return nil }
        let hosts = columns.filter { column in
            let h = column.box, size = h.width
            guard column.index != candidate.index, column.orientation == .vertical,
                  !h.isEmpty, !h.isNull, [h.minX, h.minY, h.maxX, h.maxY].allSatisfy(\.isFinite),
                  h.height > size, c.width * 1.5 <= size,
                  column.source.unicodeScalars.contains(where: {
                      (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
                  }) else { return false }
            let gap = c.minX - h.maxX
            return gap >= -size * 0.25 && gap <= size * 0.5 && c.midX > h.maxX - size * 0.25 &&
                c.minY >= h.minY - size * 0.25 && c.maxY <= h.maxY + size * 0.25
        }
        if hosts.count == 1 { return hosts[0].index }
        guard hosts.isEmpty else { return nil }
        // A recovered rail can span two independently detected pieces of the
        // SAME body column. Test its complete physical continuation, not each
        // shorter host in isolation. Never bridge neighboring body columns.
        let body = columns.filter { $0.index != candidate.index && $0.orientation == .vertical &&
            $0.box.width >= c.width * 1.5 }
        var graph = ObservationGraph(body.map(\.index))
        graph.join(columnRelations(atoms: body))
        let joined = graph.groups.values.compactMap { ids -> Atom? in
            guard ids.count > 1 else { return nil }
            let members = body.filter { ids.contains($0.index) }
            return Atom(index: ids.min()!, source: members.map(\.source).joined(),
                box: members.map(\.box).reduce(CGRect.null) { $0.union($1) }, orientation:.vertical,owner:nil)
        }
        // A singleton aggregate cannot recursively form another chain.
        let matches = joined.filter { intercolumnRubyHost(candidate,columns:[$0]) != nil }
        return matches.count == 1 ? matches[0].index : nil
    }

    /// Connectivity is independent of reading direction and source ordering.
    /// Callers supply unique observation IDs, never positions in another table.
    struct ObservationGraph {
        private var parents: [Int: Int]
        init(_ ids: [Int]) { parents = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) }) }
        func root(_ id: Int) -> Int {
            var value = id
            while parents[value]! != value { value = parents[value]! }
            return value
        }
        mutating func join(_ first: Int, _ second: Int) { parents[root(second)] = root(first) }
        mutating func join(_ edges: [Edge]) { for edge in edges { join(edge.first, edge.second) } }
        var groups: [Int: [Int]] { Dictionary(grouping: parents.keys.sorted(), by: root) }
    }

    /// Physical continuation geometry; fitted widths share the same frame and packet inventory.
    static func columnRelations(atoms: [Atom], measuredWidths: [Int: CGFloat] = [:],
                                frame: CGAffineTransform = .identity, reason: String = "same-column-continuation",
                                maximumFitRatio: CGFloat = 1.6,
                                spansGap: (Atom, Atom, CGFloat) -> Bool = { upper, lower, glyph in
                                    lower.box.minY - upper.box.maxY <= glyph * 2
                                }) -> [Edge] {
        let observed = validObservations(atoms).map { atom in
            let raw = atom.box.width
            return (atom: atom, span: atom.box.applying(frame), glyph: max(raw, atom.sourceColumnWidth ?? raw),
                    fit: measuredWidths[atom.index] ?? atom.box.width)
        }
        return pairEdges(observed, index: { $0.atom.index }, reason: reason) { first, second in
            let a = first.span, b = second.span, glyph = min(first.glyph, second.glyph)
            let advance = min(b.minY - a.minY, b.maxY - a.maxY)
            let shared = min(a.maxX, b.maxX, a.minX + glyph * 3, b.minX + glyph * 3) - max(a.minX, b.minX)
            let aligned = min(abs(a.minX - b.minX), abs(a.maxX - b.maxX)) <= glyph * 0.5
            let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
            let fitScale = first.atom.owner != nil && first.atom.owner == second.atom.owner ?
                max(first.glyph, second.glyph) : glyph
            let fitEpsilon = max(a.minX.ulp, a.maxX.ulp, a.minY.ulp, a.maxY.ulp,
                b.minX.ulp, b.maxX.ulp, b.minY.ulp, b.maxY.ulp) * 4
            guard glyph > 0, advance >= min(first.atom.glyph, second.atom.glyph, a.height, b.height) * 0.8,
                  (shared >= min(a.width, b.width, glyph * 3) * 0.75 ||
                   aligned && overlap >= min(a.width, b.width, glyph * 3) * 0.75),
                  max(first.fit, second.fit) <= fitScale * maximumFitRatio + fitEpsilon else { return false }
            return spansGap(first.atom, second.atom, glyph)
        }
    }

    private static func validObservations(_ atoms: [Atom]) -> [Atom] {
        // Duplicate IDs invalidate the complete inventory, including degenerate entries.
        guard Set(atoms.map(\.index)).count == atoms.count else { return [] }
        return atoms.filter { !$0.box.isEmpty && !$0.box.isNull }
    }



    /// Enumerate observation relations once; callers own their evidence gates.
    static func pairEdges<Element>(_ observed: [Element], index: (Element) -> Int,
                                            reason: String, follows: (Element, Element) -> Bool) -> [Edge] {
        var edges: [Edge] = []
        for first in observed { for second in observed where index(first) != index(second) && follows(first, second) {
            edges.append(.init(first: index(first), second: index(second), reason: reason))
        } }
        return edges
    }


    /// A unique best RF proposal; exact score ties remain unowned.
    static func owningScope(_ box: CGRect, scopes: [TextScope], minimumConfidence: Double) -> TextScope? {
        let area = box.width * box.height
        guard area > 0 else { return nil }
        let candidates = scopes.compactMap { scope -> (TextScope, CGFloat)? in
            guard scope.confidence.isFinite, (minimumConfidence...1).contains(scope.confidence),
                  !scope.box.isEmpty, !scope.box.isNull,
                  [scope.box.minX, scope.box.minY, scope.box.maxX, scope.box.maxY].allSatisfy(\.isFinite) else { return nil }
            let intersection = scope.box.intersection(box)
            guard !intersection.isNull else { return nil }
            let coverage = intersection.width * intersection.height / area
            return coverage >= 0.8 ? (scope, coverage * scope.confidence) : nil
        }
        guard let winner = uniqueBest(candidates, score: { $0.1 }) else { return nil }
        // FP16 RF queries can exchange a small score lead between a complete
        // paragraph and a nested partial query. Prefer the complete enclosing
        // context only within that small support margin; disjoint or materially
        // weaker proposals cannot change ownership. Physical merge tests still
        // run independently of this RF association.
        let winnerArea = winner.0.box.width * winner.0.box.height
        let enclosing = candidates.filter { candidate in
            let shared = candidate.0.box.intersection(winner.0.box)
            let candidateArea = candidate.0.box.width * candidate.0.box.height
            return candidateArea >= winnerArea && candidate.1 >= winner.1 - 0.05 &&
                !shared.isNull && shared.width * shared.height >= winnerArea * 0.98
        }
        return uniqueBest(enclosing, score: { $0.0.box.width * $0.0.box.height })?.0 ?? winner.0
    }

    /// Exact ties supply no independent ownership, regardless of the score's meaning.
    static func uniqueBest<Value>(_ values: [Value], score: (Value) -> CGFloat) -> Value? {
        guard let best = values.max(by: { score($0) < score($1) }),
              values.reduce(0, { $0 + (score($1) == score(best) ? 1 : 0) }) == 1 else { return nil }
        return best
    }

    /// Physical adjacency within a caller-proven source context.
    /// RF/native ownership stays outside this geometry relation.
    // Every measurement uses the same local gap or caller-certified wider spacing.
    static func measuredColumnEdges(atoms: [Atom], alternatives: [[Atom]] = [], allowing: (Int) -> Bool = { _ in true },
                                    spansGap: (Atom, Atom, CGFloat) -> Bool = { right, left, glyph in
                                        NativeParagraphFragmentGrouping.withinColumnGap(left.box.maxX, right.box.minX, glyph: glyph)
                                    }) -> [Edge] {
        Array(Set(([atoms] + alternatives).flatMap { view in
            columnRelations(atoms: view.filter { $0.orientation == .vertical },
                frame: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0), reason: "measured-adjacent-columns") { right, left, glyph in
                allowing(right.index) && allowing(left.index) &&
                    (withinColumnGap(left.box.maxX, right.box.minX, glyph: glyph) || spansGap(right, left, glyph))
            }
        }))
    }

    static func compatibleGlyphScale(_ first: CGFloat, _ second: CGFloat,
                                     measured: (CGFloat, CGFloat)? = nil) -> Bool {
        max(measured?.0 ?? first, measured?.1 ?? second) <= min(first, second) * 1.6
    }

    /// A detector cell bounds quantization error only when a shared view proves it.
    static func withinColumnGap(_ leftMaxX: CGFloat, _ rightMinX: CGFloat, glyph: CGFloat, cell: CGFloat = 0) -> Bool {
        // Arithmetic roundoff exists even without certified physical cell uncertainty.
        let epsilon = max(rightMinX.ulp, leftMaxX.ulp, glyph.ulp, cell.ulp) * 4
        return rightMinX - leftMaxX <= glyph * 1.25 + cell + epsilon
    }


    /// Combine transverse extent and longitudinal advance without a language rule.
    static func lineMeasure(_ atom: Atom) -> CGFloat {
        let along = atom.orientation == .horizontal ? atom.box.width : atom.box.height
        return max(atom.glyph, along / CGFloat(atom.source.count))
    }

    static func infer(atoms: [Atom], groups input: [[Int]],
                      separates: (Atom, Atom) -> Bool = { _, _ in false },
                      ink: (Atom) -> Ink? = { _ in nil }) -> Result {
        let ids = atoms.map(\.index), members = input.flatMap { $0 }
        guard Set(ids).count == ids.count, Set(members) == Set(ids), members.count == ids.count,
              input.allSatisfy({ !$0.isEmpty }), atoms.allSatisfy({
                  $0.box.width > 0 && $0.box.height > 0 &&
                  [$0.box.minX, $0.box.minY, $0.box.maxX, $0.box.maxY].allSatisfy(\.isFinite)
              }) else { return .init(edges: []) }
        let byID = Dictionary(uniqueKeysWithValues: atoms.map { ($0.index, $0) })
        var groups = input.map { $0.sorted() }.sorted { $0[0] < $1[0] }, edges: [Edge] = []
        // Attach only a short singleton to the outside end of an existing
        // vertical paragraph. This never rebuilds or bridges two full blocks.
        for j in groups.indices {
            guard groups[j].count == 1, let short = byID[groups[j][0]], short.orientation == .vertical,
                  (1.5...3).contains(short.box.height / short.glyph) else { continue }
            var options: [(index: Int, endpoint: Atom, overlap: CGFloat)] = []
            for k in groups.indices where k != j && groups[k].count >= 2 {
                let units = groups[k].compactMap { byID[$0] }
                guard units.allSatisfy({ $0.orientation == .vertical }),
                      let longest = units.map({ $0.box.height }).max(), short.box.height <= longest * 0.5,
                      units.contains(where: { $0.box.height / $0.glyph >= 4 }) else { continue }
                let ordered = units.sorted { $0.box.midX < $1.box.midX }
                let end = short.box.midX < ordered[0].box.midX ? ordered[0] :
                    short.box.midX > ordered.last!.box.midX ? ordered.last! : nil
                guard let end, !separates(short, end),
                      ratio(short.glyph, end.glyph) <= 1.65,
                      overlapX(short.box, end.box) >= 0.4, overlapY(short.box, end.box) >= 0.95,
                      abs(short.box.minY - end.box.minY) / meanGlyph(short, end) <= 0.15,
                      units.allSatisfy({ abs($0.box.minY - short.box.minY) / max($0.glyph, short.glyph) <= 0.15 }),
                      !intervening(short, end, atoms: atoms) else { continue }
                options.append((k, end, overlapX(short.box, end.box)))
            }
            options.sort { $0.overlap != $1.overlap ? $0.overlap > $1.overlap : $0.index < $1.index }
            if let target = options.first {
                groups[target.index].append(short.index); groups[j] = []
                edges.append(.init(first: short.index, second: target.endpoint.index, reason: "short-vertical-endpoint"))
            }
        }
        groups = groups.filter { !$0.isEmpty }
        var graph = ObservationGraph(ids)
        for group in groups { for id in group { graph.join(group[0], id) } }
        let ordered = atoms.sorted { $0.index < $1.index }
        for (i, a) in ordered.enumerated() {
            for b in ordered.dropFirst(i + 1) {
                guard graph.root(a.index) != graph.root(b.index),
                      (a.orientation == .horizontal && b.orientation == .vertical) ||
                      (b.orientation == .horizontal && a.orientation == .vertical) else { continue }
                let h = a.orientation == .horizontal ? a : b, v = a.orientation == .vertical ? a : b
                guard h.source.trimmingCharacters(in: .whitespacesAndNewlines).count == 1,
                      let owner = h.owner, owner == v.owner, !separates(h, v),
                      overlapX(h.box, v.box) >= 0.8, overlapY(h.box, v.box) > 0,
                      ratio(h.glyph, v.glyph) <= 1.1, v.box.height / v.box.width >= 1.5,
                      ratio(h.box.width, h.box.height) <= 1.3,
                      !intervening(h, v, atoms: atoms),
                      let hc = ink(h), let vc = ink(v), hc.samples >= 32, vc.samples >= 32,
                      hc.rgb.count == 3, vc.rgb.count == 3,
                      (hc.rgb + vc.rgb).allSatisfy({ $0.isFinite && (0...255).contains($0) }),
                      sqrt(zip(hc.rgb, vc.rgb).reduce(0) { $0 + pow($1.0 - $1.1, 2) }) <= 4 else { continue }
                graph.join(a.index, b.index)
                edges.append(.init(first: a.index, second: b.index, reason: "overlapping-single-glyph"))
            }
        }
        return .init(edges: edges)
    }

    private static func ratio(_ a: CGFloat, _ b: CGFloat) -> CGFloat { max(a, b) / min(a, b) }
    private static func meanGlyph(_ a: Atom, _ b: Atom) -> CGFloat { (a.glyph + b.glyph) / 2 }
    private static func overlapX(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) / min(a.width, b.width)
    }
    private static func overlapY(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY)) / min(a.height, b.height)
    }
    private static func intervening(_ a: Atom, _ b: Atom, atoms: [Atom]) -> Bool {
        let vx = b.box.midX - a.box.midX, vy = b.box.midY - a.box.midY, length = vx * vx + vy * vy
        guard length > 0 else { return false }
        return atoms.contains { c in
            guard c.index != a.index, c.index != b.index else { return false }
            let dx = c.box.midX - a.box.midX, dy = c.box.midY - a.box.midY, t = (dx * vx + dy * vy) / length
            return t > 0 && t < 1 && hypot(dx - t * vx, dy - t * vy) < meanGlyph(a, b) * 0.75
        }
    }
}
