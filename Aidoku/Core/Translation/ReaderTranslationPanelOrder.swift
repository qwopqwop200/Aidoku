import CoreGraphics
import Foundation

/// Partial RTL reading order from clearly separated panels and disjoint vertical-text
/// bands. Callers must use the reader's explicit direction, never the source language.
enum ReaderTranslationPanelOrder {
    struct Input: Sendable {
        let rect: CGRect // Normalized top-left image coordinates.
        let isVertical: Bool
    }

    static func rightToLeftRanks(pixels: [UInt8], width: Int, height: Int, inputs: [Input]) -> [Int] {
        let unchanged = Array(inputs.indices)
        guard width > 0, height > 0, width <= 768, height <= 768,
              pixels.count == width * height, inputs.count >= 2, inputs.count <= 512,
              inputs.allSatisfy({ !$0.rect.isEmpty && !$0.rect.isNull &&
                  [$0.rect.minX, $0.rect.minY, $0.rect.maxX, $0.rect.maxY].allSatisfy(\.isFinite) &&
                  $0.rect.minX >= 0 && $0.rect.minY >= 0 && $0.rect.maxX <= 1 && $0.rect.maxY <= 1 })
        else { return unchanged }
        let boxes = inputs.map { CGRect(x: $0.rect.minX * CGFloat(width), y: $0.rect.minY * CGFloat(height),
                                        width: $0.rect.width * CGFloat(width), height: $0.rect.height * CGFloat(height)) }
        struct Area { let x0: Int; let y0: Int; let x1: Int; let y1: Int }
        var leaves: [[Int]] = []

        func split(_ area: Area, _ ids: [Int], _ depth: Int) {
            guard ids.count >= 2, depth < 5, !Task.isCancelled else { leaves.append(ids); return }
            for horizontal in [true, false] {
                let count = horizontal ? area.y1 - area.y0 : area.x1 - area.x0
                let span = horizontal ? area.x1 - area.x0 : area.y1 - area.y0
                guard count > 0, span > 0 else { continue }
                var bright = [Bool](repeating: false, count: count)
                var dark = [Double](repeating: 0, count: count)
                var whiteFraction = [Double](repeating: 0, count: count)
                // Row-major counts of white/black cells per row or per column (no strided reads).
                let (whiteCounts, blackCounts) = counts(pixels, width: width, x0: area.x0, y0: area.y0, x1: area.x1,
                                                        y1: area.y1, rows: horizontal)
                for position in 0..<count {
                    whiteFraction[position] = Double(whiteCounts[position]) / Double(span)
                    bright[position] = whiteFraction[position] >= 0.997
                    dark[position] = Double(blackCounts[position]) / Double(span)
                }
                var bands: [(Int, Int)] = []
                var start: Int?
                for position in 0...count {
                    if position < count && bright[position] {
                        if start == nil { start = position }
                    } else if let first = start {
                        if position - first >= 2 { bands.append((first, position)) }
                        start = nil
                    }
                }
                bands.sort { a, b in
                    let da = a.1 - a.0, db = b.1 - b.0
                    return da == db ? a.0 < b.0 : da > db
                }
                // Antialiased 1-3 px gutters require a frame on both sides.
                var narrowStart: Int?
                for position in 0...count {
                    if position < count && whiteFraction[position] >= 0.99 {
                        if narrowStart == nil { narrowStart = position }
                    } else if let first = narrowStart {
                        if (1...3).contains(position - first) {
                            let before = dark[max(0, first - 5)..<first].max() ?? 0
                            let after = dark[position..<min(count, position + 5)].max() ?? 0
                            if min(before, after) >= 0.8 { bands.append((first, position)) }
                        }
                        narrowStart = nil
                    }
                }
                for (lo, hi) in bands {
                    let beforeBoundary = dark[max(0, lo - 5)..<lo].max() ?? 0
                    let afterBoundary = dark[hi..<min(count, hi + 5)].max() ?? 0
                    guard max(beforeBoundary, afterBoundary) >= 0.8 else { continue }
                    let cut = (lo + hi) / 2 + (horizontal ? area.y0 : area.x0)
                    let before = ids.filter { (horizontal ? boxes[$0].maxY : boxes[$0].maxX) < CGFloat(cut) }
                    let after = ids.filter { (horizontal ? boxes[$0].minY : boxes[$0].minX) > CGFloat(cut) }
                    guard !before.isEmpty, !after.isEmpty, before.count + after.count == ids.count else { continue }
                    if horizontal {
                        split(Area(x0: area.x0, y0: area.y0, x1: area.x1, y1: cut), before, depth + 1)
                        split(Area(x0: area.x0, y0: cut, x1: area.x1, y1: area.y1), after, depth + 1)
                    } else {
                        // Traverse the right panel completely before the left.
                        split(Area(x0: cut, y0: area.y0, x1: area.x1, y1: area.y1), after, depth + 1)
                        split(Area(x0: area.x0, y0: area.y0, x1: cut, y1: area.y1), before, depth + 1)
                    }
                    return
                }
            }
            leaves.append(ids)
        }
        split(Area(x0: 0, y0: 0, x1: width, y1: height), unchanged, 0)
        guard leaves.count >= 2, !Task.isCancelled else { return unchanged }
        // Leaves are already in traversal order; build the permutation directly.
        let order = leaves.flatMap { ids -> [Int] in
            guard ids.count >= 2 else { return ids }
            // Partition at vertical whitespace between text blocks.
            let topToBottom = ids.sorted { boxes[$0].minY < boxes[$1].minY }
            var bands: [[Int]] = []
            var bottom: CGFloat = -.infinity
            for id in topToBottom {
                if bands.isEmpty || boxes[id].minY > bottom {
                    bands.append([id])
                    bottom = boxes[id].maxY
                } else {
                    bands[bands.count - 1].append(id)
                    bottom = max(bottom, boxes[id].maxY)
                }
            }
            var ordered = ids
            for band in bands where band.count >= 2 {
                // Bands with any horizontal lettering keep the detector's order.
                guard band.allSatisfy({ inputs[$0].isVertical }) else { continue }
                let slots = ids.indices.filter { band.contains(ids[$0]) }
                let commonTop = band.map { boxes[$0].minY }.max() ?? 0
                let commonBottom = band.map { boxes[$0].maxY }.min() ?? 0
                let maximumHeight = band.map { boxes[$0].height }.max() ?? 0
                guard commonBottom - commonTop >= maximumHeight * 0.25 else { continue }
                let leftToRight = band.sorted { boxes[$0].minX < boxes[$1].minX }
                guard zip(leftToRight, leftToRight.dropFirst()).allSatisfy({ boxes[$0.0].maxX <= boxes[$0.1].minX }) else { continue }
                for (slot, id) in zip(slots, leftToRight.reversed()) { ordered[slot] = id }
            }
            return ordered
        }
        var ranks = unchanged
        for (rank, id) in order.enumerated() { ranks[id] = rank }
        return Task.isCancelled ? unchanged : ranks
    }

    /// White (>= 245) and black (<= 100) cell counts of each row (`rows`) or column of the area.
    private static func counts(_ pixels: [UInt8], width: Int, x0: Int, y0: Int, x1: Int, y1: Int,
                               rows: Bool) -> ([Int32], [Int32]) {
        var white = [Int32](repeating: 0, count: rows ? y1 - y0 : x1 - x0)
        var black = white
        pixels.withUnsafeBufferPointer { pixels in
            white.withUnsafeMutableBufferPointer { white in
                black.withUnsafeMutableBufferPointer { black in
                    guard let base = pixels.baseAddress, let white = white.baseAddress, let black = black.baseAddress else { return }
                    for y in y0..<y1 {
                        let row = base + y * width + x0
                        if rows {
                            var whiteCount: Int32 = 0, blackCount: Int32 = 0
                            for x in 0..<(x1 - x0) {
                                whiteCount &+= row[x] >= 245 ? 1 : 0
                                blackCount &+= row[x] <= 100 ? 1 : 0
                            }
                            white[y - y0] = whiteCount
                            black[y - y0] = blackCount
                        } else {
                            for x in 0..<(x1 - x0) {
                                white[x] &+= row[x] >= 245 ? 1 : 0
                                black[x] &+= row[x] <= 100 ? 1 : 0
                            }
                        }
                    }
                }
            }
        }
        return (white, black)
    }
}
