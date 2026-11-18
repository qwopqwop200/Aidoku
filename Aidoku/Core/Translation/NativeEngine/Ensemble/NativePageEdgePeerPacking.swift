import CoreGraphics
import Foundation

/// Proposal only, after an isolated page-edge shift failed. Never admits paint.
/// The caller must retain all owners, merge these changed alpha origins into a
/// complete fixed-origin map, then run NativeFinalTextPaintAdmission.place and
/// its full alpha/domain/peer and unchanged-raster/font/start-axis checks.
enum NativePageEdgePeerPacking {
    enum Eligibility { case fixed, exterior }
    struct Owner {
        let id: String
        let alpha: CGRect
        let readable: CGRect
        let capacity: CGRect
        let font: CGFloat
        let cohort: String?
        let axis: NativeSourceClusterAlignment.Axis?
        // Body members and inside-balloon owners MUST be .fixed, even when
        // they also carry a source cohort. No mask approximation belongs here.
        let eligibility: Eligibility
    }

    /// One deterministic greedy proposal on the whole-pixel peer lattice.
    /// Seed delta is supplied unchanged by the existing page-edge policy.
    /// .top locks Y (free X); .left locks X (free Y). Process outward in the
    /// seed's direction, choosing the smallest feasible nonnegative peer shift
    /// against every already processed cohort member. Zero always wins when
    /// sufficient. This is lexicographically minimal in that directional order,
    /// not a global continuous optimizer. Conservative rejection is permitted.
    /// At most 256 owners, 257 candidates/peer, one sweep and one final audit;
    /// shifts beyond the 256px search budget return nil, never a weaker guard.
    /// nil also covers invalid input, seed-only/no-op, or infeasible geometry.
    static func origins(_ owners: [Owner], page: CGRect, seed: String, delta: CGFloat) -> [String: CGPoint]? {
        guard !owners.isEmpty, owners.count <= 256, valid(page), delta.isFinite, delta != 0,
              Set(owners.map(\.id)).count == owners.count,
              owners.allSatisfy({ !$0.id.isEmpty && valid($0.alpha) && valid($0.readable) && valid($0.capacity) &&
                  $0.font.isFinite && $0.font > 0 && ($0.font * 0.25).isFinite &&
                  contains(page, $0.alpha) && contains(page, $0.readable) }),
              let seedIndex = owners.firstIndex(where: { $0.id == seed }) else { return nil }
        let anchor = owners[seedIndex]
        guard anchor.eligibility == .exterior, let cohort = anchor.cohort, !cohort.isEmpty,
              let axis = anchor.axis, abs(delta) <= ceil(anchor.font * 0.25), abs(delta) <= 256 else { return nil }
        // A cohort cannot have contradictory locked axes, even for fixed peers.
        guard owners.filter({ $0.cohort == cohort }).allSatisfy({ $0.axis == axis }) else { return nil }
        let horizontal = axis == .top, sign: CGFloat = delta > 0 ? 1 : -1
        func start(_ r: CGRect) -> CGFloat { horizontal ? r.minX : r.minY }
        func translated(_ r: CGRect, _ amount: CGFloat) -> CGRect {
            r.offsetBy(dx: horizontal ? amount : 0, dy: horizontal ? 0 : amount)
        }
        let ordered = owners.indices.filter { owners[$0].cohort == cohort }.sorted {
            let a = start(owners[$0].alpha), b = start(owners[$1].alpha)
            if a == b { return sign > 0 ? owners[$0].id < owners[$1].id : owners[$0].id > owners[$1].id }
            return sign > 0 ? a < b : a > b
        }
        var shifts = Array(repeating: CGFloat(0), count: owners.count)
        shifts[seedIndex] = delta
        func fits(_ i: Int, _ amount: CGFloat) -> Bool {
            let alpha = translated(owners[i].alpha, amount), readable = translated(owners[i].readable, amount)
            return contains(page, alpha) && contains(page, readable) && contains(owners[i].capacity, alpha)
        }
        func pairSafe(_ i: Int, _ a: CGFloat, _ j: Int, _ b: CGFloat) -> Bool {
            let first = owners[i], second = owners[j]
            if first.cohort == cohort && second.cohort == cohort {
                let old = start(first.alpha) - start(second.alpha)
                let new = old + a - b
                if (old < 0 && new >= 0) || (old > 0 && new <= 0) || (old == 0 && new != 0) { return false }
            }
            let desired = min(first.font, second.font) * 0.35
            let prior = NativeAdaptiveTextGutter.clearance(first.readable, second.readable) ?? desired
            if let next = NativeAdaptiveTextGutter.clearance(translated(first.readable, a), translated(second.readable, b)) {
                // Exact threshold, deliberately no extra 0.01px relaxation.
                return next >= min(prior, desired)
            }
            return true
        }
        guard fits(seedIndex, delta) else { return nil }
        var processed: [Int] = []
        var passedSeed = false
        for i in ordered {
            if i == seedIndex {
                guard processed.allSatisfy({ pairSafe(i, delta, $0, shifts[$0]) }) else { return nil }
                passedSeed = true
            } else if passedSeed {
                let limit = owners[i].eligibility == .exterior ? Int(min(256, ceil(owners[i].font * 0.25))) : 0
                var selected: CGFloat?
                for pixels in 0...limit {
                    let amount = sign * CGFloat(pixels)
                    // Untouched owners retain their admitted capacity state.
                    if amount != 0 && !fits(i, amount) { continue }
                    if processed.allSatisfy({ pairSafe(i, amount, $0, shifts[$0]) }) { selected = amount; break }
                }
                guard let selected else { return nil }
                shifts[i] = selected
            }
            processed.append(i)
        }
        // All unrelated owners remain fixed, but every changed pair is checked
        // against them too. Never move unrelated owners to rescue a proposal.
        for i in owners.indices {
            for j in owners.indices where j > i && (shifts[i] != 0 || shifts[j] != 0) {
                guard pairSafe(i, shifts[i], j, shifts[j]) else { return nil }
            }
        }
        guard owners.indices.contains(where: { $0 != seedIndex && shifts[$0] != 0 }) else { return nil }
        return Dictionary(uniqueKeysWithValues: owners.indices.compactMap { i in
            shifts[i] == 0 ? nil : (owners[i].id, translated(owners[i].alpha, shifts[i]).origin)
        })
    }

    private static func valid(_ r: CGRect) -> Bool {
        [r.origin.x, r.origin.y, r.size.width, r.size.height, r.maxX, r.maxY].allSatisfy(\.isFinite) &&
            r.size.width > 0 && r.size.height > 0
    }
    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX && inner.minY >= outer.minY && inner.maxX <= outer.maxX && inner.maxY <= outer.maxY
    }
}
