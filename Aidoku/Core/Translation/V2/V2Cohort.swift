import CoreGraphics
import Foundation

// S9 size cohorts: translated text whose source lettering shared a size and style is
// painted at a common size, so a page keeps the source's typographic consistency
// (ported from the legacy page font clusters, source-size snap and inconsistency
// guard). Pure arithmetic over S8 styles and S9 fits; one bounded pass.
//
// 1. Key: orientation, bold, outline, fill and outline colour class.
// 2. Source snap: within a key, sources within 1.08x of a band's first value take the
//    band median (S8 per-block estimates are noisy).
// 3. Cohorts: same key, sorted by source, chained while max/min <= 1.22; size >= 2.
//    Each member's fit cap is capRatio x max(own source, cohort median source), so a
//    small member may grow to the cohort size when its box allows.
// 4. After the per-block fits, a cohort whose sizes spread > 1.1 takes the common size
//    x that minimises its spread when each member becomes min(fit, max(0.8 fit, x)).
//    Members only shrink, so frames only get smaller and stay collision-free. The
//    change is kept when the spread drops by >= 0.03 and the page inconsistency count
//    (similar sources, sizes > 1.25x apart) does not rise.
enum V2Cohort {
    static let snapRatio: CGFloat = 1.08
    static let cohortRatio: CGFloat = 1.22
    static let spreadTrigger: CGFloat = 1.1
    static let minimumGain: CGFloat = 0.03
    static let shrinkFloor: CGFloat = 0.8
    static let similarSource: CGFloat = 1.15
    static let inconsistentSize: CGFloat = 1.25

    struct Key: Hashable {
        var vertical: Bool
        var bold: Bool
        var outlined: Bool
        var fill: Int
        var outline: Int
    }

    /// Hue sextant (0-5) when chroma > 60/255, else dark (6), light (7) or mid (8).
    static func colorClass(_ color: V2RGB?) -> Int {
        guard let color else { return -1 }
        let r = CGFloat(color.r) / 255, g = CGFloat(color.g) / 255, b = CGFloat(color.b) / 255
        let high = max(r, g, b), low = min(r, g, b), chroma = high - low
        if chroma > 60 / 255 {
            var hue: CGFloat
            if high == r { hue = (g - b) / chroma } else if high == g { hue = (b - r) / chroma + 2 } else { hue = (r - g) / chroma + 4 }
            hue = (hue < 0 ? hue + 6 : hue)
            return min(5, Int(hue))
        }
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        return luma < 0.3 ? 6 : luma > 0.72 ? 7 : 8
    }

    static func key(_ block: V2Block) -> Key {
        let style = block.style
        let outlined = style.map { $0.strokeColor != nil && $0.strokeWidth > 0 } ?? false
        return Key(vertical: block.vertical, bold: style?.bold ?? false, outlined: outlined,
                   fill: colorClass(style?.textColor), outline: outlined ? colorClass(style?.strokeColor) : -1)
    }

    struct Plan {
        /// Snapped source px per block.
        var sources: [CGFloat]
        /// Fit cap per block.
        var caps: [CGFloat]
        /// Member indices of each cohort (>= 2 members).
        var cohorts: [[Int]]
        var keys: [Key]
    }

    static func plan(_ blocks: [V2Block], sources raw: [CGFloat], capRatio: CGFloat, floor: CGFloat) -> Plan {
        var sources = raw
        let keys = blocks.map(key)
        var cohorts: [[Int]] = []
        let byKey = Dictionary(grouping: blocks.indices, by: { keys[$0] })
        for key in byKey.keys.sorted(by: { "\($0)" < "\($1)" }) {
            let members = byKey[key]!.sorted { (raw[$0], $0) < (raw[$1], $1) }
            for band in chains(members, values: raw, ratio: snapRatio) where band.count >= 2 {
                let median = median(band.map { raw[$0] })
                for index in band { sources[index] = median }
            }
            cohorts += chains(members, values: sources, ratio: cohortRatio).filter { $0.count >= 2 }
        }
        var caps = sources.map { max(floor, $0 * capRatio) }
        for cohort in cohorts {
            let shared = median(cohort.map { sources[$0] })
            for index in cohort { caps[index] = max(floor, max(sources[index], shared) * capRatio) }
        }
        return Plan(sources: sources, caps: caps, cohorts: cohorts, keys: keys)
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

    static func spread(_ values: [CGFloat]) -> CGFloat {
        guard let low = values.min(), let high = values.max(), low > 0 else { return 1 }
        return high / low
    }

    /// Target sizes for one cohort, or nil when it is already consistent or cannot improve enough.
    static func targets(fits: [CGFloat], floor: CGFloat) -> [CGFloat]? {
        let initial = spread(fits)
        guard fits.count >= 2, initial > spreadTrigger else { return nil }
        let floors = fits.map { max(min(floor, $0), $0 * shrinkFloor) }
        func sizes(_ common: CGFloat) -> [CGFloat] {
            zip(fits, floors).map { fit, low in min(fit, max(low, common)) }
        }
        var best: (sizes: [CGFloat], spread: CGFloat, sum: CGFloat)?
        for common in Set(fits + floors).sorted() {
            let candidate = sizes(common)
            let value = spread(candidate), sum = candidate.reduce(0, +)
            if best.map({ value < $0.spread - 0.0001 || (abs(value - $0.spread) <= 0.0001 && sum > $0.sum) }) ?? true {
                best = (candidate, value, sum)
            }
        }
        guard let best, best.spread <= initial - minimumGain else { return nil }
        return best.sizes.map { ($0 * 4).rounded(.down) / 4 }
    }

    /// Pairs with the same key and similar sources whose painted sizes are > 1.25x apart.
    static func inconsistency(sizes: [CGFloat], plan: Plan) -> Int {
        var count = 0
        for i in sizes.indices {
            for j in sizes.indices where j > i && plan.keys[i] == plan.keys[j] {
                let a = plan.sources[i], b = plan.sources[j]
                guard a > 0, b > 0, max(a, b) / min(a, b) <= similarSource else { continue }
                if spread([sizes[i], sizes[j]]) > inconsistentSize { count += 1 }
            }
        }
        return count
    }
}
