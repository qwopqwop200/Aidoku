import CoreGraphics
import Foundation

// S9 size cohorts (legacy page font clusters): text whose source lettering shared a size
// and style is painted at a common size.
// 1. No key: vertical and horizontal text of one source size share a family (colour, S8 outline and
//    S8 bold are too noisy; bold text keeps its peers' size and changes only the weight).
// 2. Snap: sources within 1.08x of a band's first value take the band median.
// 3. Families: chained while max/min <= 1.22, >= 2 members; a lone block joins the nearest family
//    within 1.08x. Members share the cap median source x largest cap ratio.
// 4. After the fits, a family takes the largest cap step (1 ... 0.65, >= 12 px) every member
//    reached (members below the last step keep their fit); the page takes the smallest family
//    step, and a lower re-fit pulls its family down. Members only shrink; a horizontal fit pulls
//    vertical members down to no less than 0.95x their smallest fit.
enum PipelineCohort {
    static let snapRatio: CGFloat = 1.08
    static let cohortRatio: CGFloat = 1.22
    static let steps: [CGFloat] = [1, 0.95, 0.9, 0.85, 0.8, 0.75, 0.7, 0.65]
    static let minimumPixels: CGFloat = 12
    /// Vertical members shrink for a horizontal member's fit to no less than this share of their smallest fit.
    static let verticalGuard: CGFloat = 0.95

    struct Plan {
        /// Snapped source px per block.
        var sources: [CGFloat]
        /// Fit cap per block.
        var caps: [CGFloat]
        /// Member indices of each family (>= 2 members).
        var cohorts: [[Int]]
    }

    static func plan(_ blocks: [PipelineBlock], sources raw: [CGFloat], capRatio: (PipelineBlock) -> CGFloat, floor: CGFloat) -> Plan {
        var sources = raw
        let members = blocks.indices.sorted { (raw[$0], $0) < (raw[$1], $1) }
        for band in chains(members, values: raw, ratio: snapRatio) where band.count >= 2 {
            let median = median(band.map { raw[$0] })
            for index in band { sources[index] = median }
        }
        var cohorts = chains(members, values: sources, ratio: cohortRatio).filter { $0.count >= 2 }
        // A block left out of every family joins the nearest family within the snap ratio.
        let grouped = Set(cohorts.joined())
        for index in blocks.indices where !grouped.contains(index) {
            let near = cohorts.indices.map { ($0, median(cohorts[$0].map { sources[$0] })) }.filter { _, mid in
                max(mid, sources[index]) <= min(mid, sources[index]) * snapRatio
            }.min { abs($0.1 - sources[index]) < abs($1.1 - sources[index]) }
            if let near { cohorts[near.0].append(index) }
        }
        var caps = blocks.indices.map { max(floor, sources[$0] * capRatio(blocks[$0])) }
        for cohort in cohorts {
            let cap = max(floor, median(cohort.map { sources[$0] }) * (cohort.map { capRatio(blocks[$0]) }.max() ?? 1))
            for index in cohort { caps[index] = cap }
        }
        return Plan(sources: sources, caps: caps, cohorts: cohorts)
    }

    /// Consecutive runs of `members` (sorted by value) whose values stay within `ratio`
    /// of the run's first value.
    static func chains(_ members: [Int], values: [CGFloat], ratio: CGFloat) -> [[Int]] {
        var result: [[Int]] = []
        for index in members {
            if let first = result.last?.first, values[index] <= values[first] * ratio {
                result[result.count - 1].append(index)
            } else {
                result.append([index])
            }
        }
        return result
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// The smallest fit; horizontal fits pull it to no less than `verticalGuard` x the smallest vertical
    /// first fit (`firstFits`, default `fits`).
    static func lowestFit(_ fits: [CGFloat], vertical: [Bool], firstFits: [CGFloat]? = nil) -> CGFloat? {
        guard let low = fits.min() else { return nil }
        guard let lowVertical = zip(firstFits ?? fits, vertical).filter(\.1).map(\.0).min() else { return low }
        return max(low, min(lowVertical * verticalGuard, zip(fits, vertical).filter(\.1).map(\.0).min() ?? .infinity))
    }

    /// The family's common size (quarter pixels): the largest cap step every member's fit
    /// reaches, ignoring members below the last step; nil when none reaches it.
    static func familySize(cap: CGFloat, fits: [CGFloat], vertical: [Bool] = []) -> CGFloat? {
        let sizes = steps.map { ((cap * $0) * 4).rounded(.down) / 4 }.filter { $0 >= min(cap, minimumPixels) }
        let vertical = vertical.count == fits.count ? vertical : fits.map { _ in false }
        let reached = fits.indices.filter { fits[$0] >= (sizes.last ?? .infinity) - 0.01 }
        guard let lowest = sizes.last, let need = lowestFit(reached.map { fits[$0] }, vertical: reached.map { vertical[$0] }) else { return nil }
        return sizes.first { $0 <= need + 0.01 } ?? lowest
    }
}
