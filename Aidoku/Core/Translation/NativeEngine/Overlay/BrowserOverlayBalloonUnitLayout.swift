import UIKit

/// Captions that share one balloon (OCR split one utterance, or a balloon holds two), proposed as
/// one lettering unit: one stack of blocks in source reading order, centred in the balloon's paper,
/// at one size. Every caption keeps its own card and erasure; the overlay commits the stack only
/// after verifying each member's erasure and the final sizes (payload `balloonUnit`).
struct BrowserOverlayBalloonUnit: Equatable {
    /// Segment indices in source reading order.
    let members: [Int]
}

extension BrowserOverlayLayoutPlanner {
    /// Balloon paper in viewport coordinates, from a normalized `ReaderTranslationBalloonInterior`.
    struct BalloonPaper {
        let rect: CGRect
        let center: CGPoint
        /// Per band (top to bottom): the paper run, or nil where the outline or other ink cuts it.
        let runs: [ClosedRange<CGFloat>?]

        init?(_ interior: ReaderTranslationBalloonInterior, frame: CGRect) {
            let bands = interior.spans.count / 2
            guard bands > 0, frame.width > 0, frame.height > 0, interior.rect.width > 0, interior.rect.height > 0 else { return nil }
            rect = CGRect(x: frame.minX + interior.rect.minX * frame.width, y: frame.minY + interior.rect.minY * frame.height,
                          width: interior.rect.width * frame.width, height: interior.rect.height * frame.height)
            center = CGPoint(x: frame.minX + interior.center.x * frame.width, y: frame.minY + interior.center.y * frame.height)
            runs = (0..<bands).map { band in
                let left = interior.spans[band * 2], right = interior.spans[band * 2 + 1]
                guard left >= 0, right > left else { return nil }
                return (frame.minX + CGFloat(left) * frame.width)...(frame.minX + CGFloat(right) * frame.width)
            }
        }

        /// The block [x0, x1] x [y0, y1] lies on paper in every band it touches.
        func holds(_ block: CGRect) -> Bool {
            guard block.minY >= rect.minY, block.maxY <= rect.maxY else { return false }
            let step = rect.height / CGFloat(runs.count)
            let first = max(0, Int(((block.minY - rect.minY) / step).rounded(.down)))
            let last = min(runs.count - 1, Int(((block.maxY - rect.minY) / step).rounded(.up)) - 1)
            guard first <= last else { return false }
            for band in first...last {
                guard let run = runs[band], run.lowerBound <= block.minX, run.upperBound >= block.maxX else { return false }
            }
            return true
        }
    }

    /// Proposes a unit for every complete group of eligible captions that share a native balloon
    /// interior and whose stack fits the balloon paper at the automatic floor size, in source
    /// reading order. Text and an aside in clearly different source sizes stay separate captions.
    static func balloonUnits(
        items: [BrowserOverlayItem],
        sources: [CGRect],
        sourceVerticals: [Bool],
        variants: [BrowserOverlayDisplayVariant],
        eligible: [Bool],
        planned: [BrowserOverlayCardLayout?],
        frame: CGRect,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> [BrowserOverlayBalloonUnit] {
        var groups: [[Double]: [Int]] = [:]
        for index in items.indices {
            guard let interior = items[index].balloonInterior, let members = interior.members, members >= 2 else { continue }
            let r = interior.rect
            groups[[Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)], default: []].append(index)
        }
        var units: [BrowserOverlayBalloonUnit] = []
        var orderKeys: [UInt64?]?
        for (_, indices) in groups.sorted(by: { ($0.value.first ?? 0) < ($1.value.first ?? 0) }) {
            guard !Task.isCancelled else { break }
            guard let interior = items[indices[0]].balloonInterior, indices.count == interior.members,
                  indices.allSatisfy({ eligible[$0] && planned[$0] != nil }),
                  let paper = BalloonPaper(interior, frame: frame) else { continue }
            if orderKeys == nil { orderKeys = items.map(\.stableRegionID) }
            let ordered = readingOrder(indices, sources: sources, sourceVerticals: sourceVerticals,
                                       orderKeys: orderKeys)
            let glyphs = ordered.compactMap { index in
                BrowserOverlayTypography.sourceSize(text: items[index].sourceText, rect: sources[index])
            }
            if let small = glyphs.min(), let large = glyphs.max(), glyphs.count == ordered.count, large > small * 1.4 { continue }
            guard stackFits(ordered.map { variants[$0] }, paper: paper, fontSize: minimumAutoFontSize,
                            measurementCache: measurementCache) else { continue }
            units.append(BrowserOverlayBalloonUnit(members: ordered))
        }
        return units
    }

    /// Source reading order: vertical columns right to left, then top down; horizontal lines top
    /// down. Horizontal blocks side by side keep the OCR reading order (`stableRegionID`, which
    /// follows the page's panel direction), else left to right. The majority of boxes sets the
    /// direction; a tie (a column and a lone kana, a line and a short word) follows the largest box.
    static func readingOrder(_ indices: [Int], sources: [CGRect], sourceVerticals: [Bool],
                             orderKeys: [UInt64?]? = nil) -> [Int] {
        let columns = indices.filter { sourceVerticals[$0] }.count
        let largest = indices.max { sources[$0].width * sources[$0].height < sources[$1].width * sources[$1].height }
        let vertical = columns * 2 > indices.count || columns * 2 == indices.count && largest.map { sourceVerticals[$0] } == true
        // Group boxes into bands first (columns, or lines), each joined by half the smaller box's extent
        // with the band's first box, then order inside each band: a pairwise rule mixing the two
        // orders would not be transitive.
        func shares(_ a: CGRect, _ b: CGRect) -> Bool {
            vertical
                ? min(a.maxX, b.maxX) - max(a.minX, b.minX) >= min(a.width, b.width) * 0.5
                : min(a.maxY, b.maxY) - max(a.minY, b.minY) >= min(a.height, b.height) * 0.5
        }
        let across = indices.sorted { vertical ? sources[$0].midX > sources[$1].midX : sources[$0].minY < sources[$1].minY }
        var bands: [[Int]] = []
        for index in across {
            if let first = bands.last?.first, shares(sources[first], sources[index]) {
                bands[bands.count - 1].append(index)
            } else {
                bands.append([index])
            }
        }
        return bands.flatMap { band in
            if vertical { return band.sorted { sources[$0].minY < sources[$1].minY } }
            let keyed = band.compactMap { index in orderKeys?[index].map { (index, $0) } }
            if keyed.count == band.count, Set(keyed.map(\.1)).count == band.count {
                return keyed.sorted { $0.1 < $1.1 }.map(\.0)
            }
            return band.sorted { sources[$0].minX < sources[$1].minX }
        }
    }

    /// The blocks, each wrapped at whole words to one common width and stacked with a small gap,
    /// fit the balloon paper with a 0.2 em clearance at `fontSize`, centred on the balloon's visual
    /// centre or shifted by up to a third of the balloon.
    static func stackFits(
        _ texts: [BrowserOverlayDisplayVariant],
        paper: BalloonPaper,
        fontSize: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> Bool {
        guard !texts.isEmpty, fontSize > 0 else { return false }
        let clearance = fontSize * 0.2, pad = min(3, max(1, fontSize * 0.15)), gap = fontSize * 0.3
        let widest = texts.map { $0.minimumUnbrokenWidth(fontSize: fontSize, measurementCache: measurementCache) }.max() ?? 0
        let available = paper.rect.width - clearance * 2 - pad * 2
        guard widest > 0, widest <= available else { return false }
        let steps = 8
        let shifts: [CGFloat] = [0, 0.08, -0.08, 0.16, -0.16, 0.25, -0.25, 0.35, -0.35]
        for step in 0...steps {
            let width = (widest + (available - widest) * CGFloat(steps - step) / CGFloat(steps)).rounded(.up)
            let sizes = texts.map { $0.measuredSize(width: width, fontSize: fontSize, measurementCache: measurementCache) }
            guard sizes.allSatisfy({ $0.width > 0 && $0.width <= width + 0.5 && $0.height > 0 }) else { continue }
            let height = sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(sizes.count - 1)
            guard height + (clearance + pad) * 2 <= paper.rect.height else { continue }
            for dy in shifts {
                for dx in shifts.prefix(5) {
                    let centre = paper.center.x + dx * paper.rect.width
                    var top = paper.center.y - height / 2 + dy * paper.rect.height
                    let fits = sizes.allSatisfy { size in
                        defer { top += size.height + gap }
                        return paper.holds(CGRect(x: centre - size.width / 2 - pad - clearance, y: top - pad - clearance,
                                                  width: size.width + (pad + clearance) * 2,
                                                  height: size.height + (pad + clearance) * 2))
                    }
                    if fits { return true }
                }
            }
        }
        return false
    }
}
