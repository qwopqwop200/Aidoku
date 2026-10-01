import CoreGraphics
import Foundation

/// Frozen shared-row and source-column axes. Snapshots belong to the caller:
/// failed targets restore each text node, including its style and child state.
enum NativeTypographyHarmonyAxis {
    struct Member {
        let source: NativeTypographyPostPolish.SourceBox
        let font: CGFloat
        let pitch: CGFloat
    }
    struct Move { let index: Int; let dx: CGFloat; let dy: CGFloat; let columnEdge: CGFloat? }
    struct Result { var moves: [Move] = []; var flushed: [Int: CGFloat] = [:] }

    static func align<Snapshot>(members: [Member?], groups: [NativeTypographyPostPolish.AlignedGroup],
        columnLinks: [NativeTypographyPostPolish.Link], ink: (Int) -> CGRect,
        snapshot: (Int) -> Snapshot, restore: (Int, Snapshot) -> Void,
        flush: (Int, CGFloat) -> Bool, move: (Int, CGFloat, CGFloat) -> Bool) -> Result {
        var result = Result()
        func components(_ links: [NativeTypographyPostPolish.Link]) -> [[Int]] {
            var parents: [Int: Int] = [:], order: [Int] = []
            func find(_ i: Int) -> Int {
                var root = i
                while let parent = parents[root], parent != root { root = parent }
                return root
            }
            for link in links {
                for i in [link.a, link.b] where parents[i] == nil { parents[i] = i; order.append(i) }
                let a = find(link.a), b = find(link.b)
                if a != b { parents[b] = a }
            }
            var roots: [Int] = [], groups: [[Int]] = []
            for i in order {
                let root = find(i)
                if let n = roots.firstIndex(of: root) { groups[n].append(i) }
                else { roots.append(root); groups.append([i]) }
            }
            return groups
        }
        func alignComponent(_ indices: [Int], axis: String, edge: CGFloat, column: Bool) {
            guard indices.count >= 2, indices.allSatisfy({ members.indices.contains($0) && members[$0] != nil }) else { return }
            let boxes = indices.map { members[$0]!.source }
            let font = indices.map { members[$0]!.font }.max() ?? 0
            if !column, axis == "x", edge != 0.5, !boxes.contains(where: \.vertical) {
                let tolerance = max(2, 0.25 * (boxes.map(\.glyph).min() ?? 0))
                let centres = boxes.map { $0.x + $0.w / 2 }
                if (centres.max() ?? 0) - (centres.min() ?? 0) > tolerance {
                    let saved = indices.map { ($0, snapshot($0)) }
                    var accepted = true
                    for i in indices {
                        if !flush(i, edge) { accepted = false; break }
                    }
                    if accepted { for i in indices { result.flushed[i] = edge } }
                    else { for (i, old) in saved { restore(i, old) } }
                }
            }
            let offsets = indices.map { i -> CGFloat in
                let r = ink(i), s = members[i]!.source
                return axis == "y" ? r.minY + edge * r.height - (s.y + edge * s.h)
                    : r.minX + edge * r.width - (s.x + edge * s.w)
            }
            guard (offsets.max() ?? 0) - (offsets.min() ?? 0) > max(2, 0.25 * font) else { return }
            let sorted = offsets.sorted(), median = sorted[(sorted.count - 1) / 2]
            var targets: [CGFloat] = []
            for value in [median] + offsets where !targets.contains(where: { abs($0 - value) < 0.5 }) { targets.append(value) }
            func cost(_ target: CGFloat) -> CGFloat { offsets.reduce(0) { $0 + abs($1 - target) } }
            targets = targets.enumerated().sorted { a, b in
                let ca = cost(a.element), cb = cost(b.element)
                return ca == cb ? a.offset < b.offset : ca < cb
            }.prefix(3).map(\.element)
            for target in targets {
                var saved: [(Int, Snapshot)] = [], acceptedMoves: [Move] = [], accepted = true
                for (k, i) in indices.enumerated() {
                    let delta = target - offsets[k]
                    if abs(delta) <= 0.5 { continue }
                    let member = members[i]!, old = snapshot(i), r = ink(i)
                    let reach = max(1.2 * member.font, 0.5 * (axis == "x" ? member.source.w : member.source.h))
                    let slack = max(2, 0.25 * member.font)
                    let remains = !column || (r.minY + delta >= min(r.minY, member.source.y - slack) &&
                        r.maxY + delta <= max(r.maxY, member.source.y + member.source.h + slack))
                    let dx = axis == "x" ? delta : 0, dy = axis == "y" ? delta : 0
                    accepted = abs(delta) <= reach && remains && move(i, dx, dy)
                    if !accepted { break }
                    saved.append((i, old)); acceptedMoves.append(.init(index: i, dx: dx, dy: dy, columnEdge: column ? edge : nil))
                }
                if accepted { result.moves.append(contentsOf: acceptedMoves); break }
                for (i, old) in saved.reversed() { restore(i, old) }
            }
        }
        for group in groups {
            for axis in ["y", "x"] {
                var edges: [CGFloat] = [], grouped: [[NativeTypographyPostPolish.Link]] = []
                for link in group.links {
                    guard link.axis == axis, let edge = link.edge,
                          members.indices.contains(link.a), members.indices.contains(link.b),
                          let a = members[link.a], let b = members[link.b],
                          link.gap <= 3 * max(a.source.glyph, b.source.glyph) else { continue }
                    if axis == "y", edge != 0.5,
                       !(ink(link.a).height < 1.6 * a.pitch && ink(link.b).height < 1.6 * b.pitch) { continue }
                    if let n = edges.firstIndex(of: edge) { grouped[n].append(link) }
                    else { edges.append(edge); grouped.append([link]) }
                }
                for (n, links) in grouped.enumerated() {
                    for indices in components(links) { alignComponent(indices, axis: axis, edge: edges[n], column: false) }
                }
            }
        }
        for edge: CGFloat in [0, 0.5, 1] {
            for indices in components(columnLinks.filter { $0.edge == edge }) {
                alignComponent(indices, axis: "y", edge: edge, column: true)
            }
        }
        return result
    }
}
