import UIKit

/// Coordinate neighboring vertical captions before fitting horizontal Korean.
/// Columns share the whitespace within a tightly bounded source row. This
/// keeps reading order and prevents one short utterance consuming the room a
/// longer one needs. Isolated balloons retain the ordinary layout planner.
enum BrowserOverlayColumnLayout {
    static func plan(
        sources: [CGRect], variants: [BrowserOverlayDisplayVariant], eligible: [Bool],
        bounds: CGRect, measurementCache: BrowserOverlayTextMeasurementCache?,
        sourceSizes: [CGFloat?] = []
    ) -> [Int: BrowserOverlayCardLayout] {
        guard sources.count == variants.count, sources.count == eligible.count,
              sources.count <= 128, bounds.width > 0 else { return [:] }
        let scale = min(2, max(0.5, bounds.width / 430))
        let candidates = sources.indices.filter {
            let r = sources[$0]
            return eligible[$0] && !variants[$0].vertical && r.width > 0 &&
                r.height >= max(30 * scale, r.width * 3) && r.width <= 40 * scale &&
                variants[$0].displayText.count <= 180 &&
                BrowserOverlayTextFlow.wrappingScript(for: variants[$0].displayText) == .korean
        }.sorted { sources[$0].minX < sources[$1].minX }
        var visited = Set<Int>()
        var result: [Int: BrowserOverlayCardLayout] = [:]
        for seed in candidates where !visited.contains(seed) {
            if Task.isCancelled { return [:] }
            var row = [seed]
            for next in candidates where !visited.contains(next) && next != seed {
                let previous = sources[row.last!], source = sources[next]
                guard source.minX >= previous.maxX,
                      source.minX - previous.maxX <= 44 * scale,
                      abs(source.minY - sources[seed].minY) <= 8 * scale else { continue }
                row.append(next)
            }
            visited.formUnion(row)
            guard row.count >= 2 else { continue }
            let rowSet = Set(row)
            let gap = 4 * scale
            var frames: [CGRect] = []
            for (offset, index) in row.enumerated() {
                let source = sources[index]
                // End columns get a small symmetric allowance, never an
                // unbounded extension into the adjacent drawing or gutter.
                let edge = min(8 * scale, source.width * 0.4)
                let left = offset == 0 ? source.minX - edge :
                    (sources[row[offset - 1]].maxX + source.minX) / 2 + gap / 2
                let right = offset == row.count - 1 ? source.maxX + edge :
                    (source.maxX + sources[row[offset + 1]].minX) / 2 - gap / 2
                frames.append(CGRect(x: max(bounds.minX, left), y: source.minY,
                    width: min(bounds.maxX, right) - max(bounds.minX, left), height: source.height))
            }
            guard frames.allSatisfy({ $0.width > 0 && bounds.contains($0) }),
                  !frames.contains(where: { frame in sources.indices.contains { other in
                      guard !rowSet.contains(other) else { return false }
                      let overlap = frame.intersection(sources[other])
                      return !overlap.isNull && overlap.width > 0.25 && overlap.height > 0.25
                  } }) else { continue }
            let insets = UIEdgeInsets(top: 2 * scale, left: 2 * scale, bottom: 2 * scale, right: 2 * scale)
            // A bounded common ceiling avoids shrinking one caption to 5 pt
            // while its neighbor grows to 12 pt. WebKit still verifies actual
            // glyph wrapping and may reduce the ceiling for a difficult word.
            var chosen: CGFloat?
            var chosenFrames: [CGRect] = []
            for step in 0...6 {
                let font = (9 - CGFloat(step) * 0.25) * scale
                guard font >= BrowserOverlayLayoutPlanner.minimumRenderedFontSize else { break }
                let left = frames[0].minX, right = frames[frames.count - 1].maxX
                let available = right - left - CGFloat(row.count - 1) * gap
                let minimum = row.map { index in
                    CGFloat(min(3, variants[index].displayText.filter { !$0.isWhitespace }.count)) * font + 4 * scale
                }
                let remaining = available - minimum.reduce(0, +)
                guard remaining >= 0 else { continue }
                let weights = row.map { sqrt(CGFloat(max(1, variants[$0].displayText.count))) }
                let totalWeight = weights.reduce(0, +)
                var cursor = left
                let trial = row.enumerated().map { offset, index -> CGRect in
                    let width = minimum[offset] + remaining * weights[offset] / totalWeight
                    defer { cursor += width + gap }
                    return CGRect(x: cursor, y: sources[index].minY, width: width, height: sources[index].height)
                }
                let fits = zip(row, trial).allSatisfy { index, frame in
                    let usable = CGSize(width: frame.width - 4 * scale, height: frame.height - 4 * scale)
                    return abs(frame.midX - sources[index].midX) <= 24 * scale &&
                        variants[index].fits(available: usable, fontSize: font, measurementCache: measurementCache)
                }
                if fits { chosen = font; chosenFrames = trial; break }
            }
            guard let chosen else { continue }
            guard !chosenFrames.contains(where: { frame in sources.indices.contains { other in
                guard !rowSet.contains(other) else { return false }
                let overlap = frame.intersection(sources[other])
                return !overlap.isNull && overlap.width > 0.25 && overlap.height > 0.25
            } }) else { continue }
            let evidence = row.compactMap { sourceSizes.indices.contains($0) ? sourceSizes[$0] : nil }.sorted()
            let typical = evidence.isEmpty ? nil : evidence[evidence.count / 2]
            for (index, frame) in zip(row, chosenFrames) {
                var font = chosen
                // Keep the approved column positions. A clearly larger source
                // heading may use its spare room; ordinary captions keep the
                // shared ceiling and are clustered after WebKit fitting.
                if let typical, sourceSizes.indices.contains(index), let size = sourceSizes[index],
                   size > typical * 1.3 {
                    let emphasis = floor(chosen * min(1.4, size / typical) * 4) / 4
                    if variants[index].fits(available: CGSize(width: frame.width - 4 * scale,
                        height: frame.height - 4 * scale), fontSize: emphasis, measurementCache: measurementCache) {
                        font = emphasis
                    }
                }
                result[index] = .init(rect: frame, maximumFontSize: font, contentInsets: insets)
            }
        }
        return result
    }
}
