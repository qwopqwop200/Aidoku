import Foundation
import CoreGraphics
import CoreText

/// Raw-source proposal stage. No prepared cards, panels, pixel globals or IDs as rules.
enum NativeRawParagraphGroups {
    struct Item {
        let key: String
        let text: String
        let source: CGRect
        let obstacle: CGRect?
        let sourceFont: CGFloat
        let eligible: Bool
    }
    struct Proposal {
        let index: Int
        let font: CGFloat
        let frame: CGRect
        let lines: [String]
        let group: Int
    }
    struct Result {
        let proposals: [Proposal]
        let rejected: [[String: Any]]
    }
    static func measure(_ text: String, font: CGFloat) -> CGFloat {
        let f = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, font, nil)
        let a = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(a), nil, nil, nil))
    }
    /// Retain words (including Hangul), punctuation and authored paragraph breaks.
    /// Exact whitespace-normalized ownership is checked separately by the caller.
    static func wrap(_ text: String, font: CGFloat, width: CGFloat) -> [String]? {
        var output: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            let words = paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var row = ""
            for word in words {
                guard measure(word, font: font) <= width + 0.001 else { return nil }
                let next = row.isEmpty ? word : row + " " + word
                if measure(next, font: font) > width, !row.isEmpty { output.append(row); row = word }
                else { row = next }
            }
            output.append(row)
        }
        return output
    }
    static func propose(items: [Item], page: CGRect, readableFloor: CGFloat = 8) -> Result {
        let eligible = items.indices.filter { items[$0].eligible && items[$0].sourceFont > 0 }
            .sorted { items[$0].source.minX < items[$1].source.minX }
        var groups: [[Int]] = []
        // round2 source-hierarchy cohort principle, now operating on raw evidence.
        for i in eligible {
            if let g = groups.indices.first(where: { g in
                let all = groups[g] + [i]
                let fonts = all.map { items[$0].sourceFont }
                let tops = all.map { items[$0].source.minY }
                let right = groups[g].map { items[$0].source.maxX }.max()!
                return fonts.max()! / fonts.min()! <= 1.5
                    && tops.max()! - tops.min()! <= fonts.max()! * 0.65
                    && items[i].source.minX - right <= fonts.max()! * 4
            }) { groups[g].append(i) } else { groups.append([i]) }
        }
        var accepted: [Proposal] = [], rejected: [[String: Any]] = []
        for (g, group) in groups.enumerated() {
            let union = group.map { items[$0].source }.reduce(CGRect.null) { $0.union($1) }
            let fonts = group.map { items[$0].sourceFont }.sorted()
            let median = fonts[fonts.count / 2]
            if group.count == 1, union.width < median * 1.6, union.height > union.width * 1.8 {
                rejected.append(["members": group.map { items[$0].key }, "reason": "narrow-source-strip-needs-direction-aware-solver"])
                continue
            }
            let topValues = group.map { items[$0].source.minY }.sorted()
            let top = topValues[topValues.count / 2]
            let floorScale = group.map { readableFloor / items[$0].sourceFont }.max()!
            var best: (CGFloat, [Proposal])?
            // Choose source-relative sizes BEFORE capacity, never shrink-to-fit.
            // The source model proxy can differ from an inherited legacy font;
            // that calibration is explicitly distinct from capacity fitting.
            for multiplier in [CGFloat(1)] {
                let scale = max(floorScale, multiplier)
                let sizes = group.map { items[$0].sourceFont * scale }
                let gap = max(2, median * scale * 0.42)
                let haloMargin = max(2, sizes.max()! * 0.16)
                // Source envelope expansion is bounded; no balloon/panel constraints.
                let expansion = group.count == 1 ? median * 1.2 : median * 2.5
                let left = max(page.minX + haloMargin, union.minX - expansion)
                let right = min(page.maxX - haloMargin, union.maxX + expansion)
                let width = right - left - gap * CGFloat(group.count - 1)
                guard width > 0 else { continue }
                let minimums = zip(group, sizes).map { i, font in
                    max(font * 1.1, items[i].text.split(whereSeparator: { $0.isWhitespace })
                        .map { measure(String($0), font: font) }.max() ?? font)
                }
                guard minimums.reduce(0, +) <= width else { continue }
                let extra = width - minimums.reduce(0, +)
                let weights = group.map { sqrt(CGFloat(max(1, items[$0].text.count))) }
                let totalWeight = weights.reduce(0, +)
                var proposals: [Proposal] = [], x = left
                for (position, i) in group.enumerated() {
                    let font = sizes[position]
                    let w = minimums[position] + extra * weights[position] / totalWeight
                    guard let lines = wrap(items[i].text, font: font, width: w) else { break }
                    let h = CGFloat(lines.count) * font * 1.24
                    let frame = CGRect(x: x, y: top, width: w, height: h)
                    let nextTop = items.indices.filter { !group.contains($0) && items[$0].source.minY > top + median
                        && items[$0].source.minX < frame.maxX && items[$0].source.maxX > frame.minX }
                        .map { items[$0].source.minY }.min() ?? page.maxY
                    guard frame.maxY + gap <= min(page.maxY - haloMargin, nextTop),
                          h <= max(union.height * 1.5, median * 5) else { break }
                    proposals.append(Proposal(index: i, font: font, frame: frame, lines: lines, group: g))
                    x += w + gap
                }
                guard proposals.count == group.count else { continue }
                let score = scale * 100 - proposals.reduce(CGFloat(0)) { total, p in
                    total + abs(p.frame.midX - items[p.index].source.midX) / median
                }
                if best == nil || score > best!.0 { best = (score, proposals) }
            }
            if let best {
                let collision = best.1.contains { p in
                    accepted.contains { $0.frame.insetBy(dx: -1, dy: -1).intersects(p.frame) }
                    || items.indices.contains { i in
                        guard !group.contains(i) else { return false }
                        let support = p.frame.insetBy(dx:-max(1,p.font*0.35),dy:-max(1,p.font*0.35))
                        return items[i].source.intersects(support) || (items[i].obstacle?.intersects(support) ?? false)
                    }
                }
                if !collision { accepted += best.1; continue }
            }
            rejected.append(["members": group.map { items[$0].key }, "reason": "bounded-source-space-or-peer-gap",
                             "floor": Double(readableFloor), "notSilentlyShrunk": true])
        }
        return Result(proposals: accepted, rejected: rejected)
    }
}
