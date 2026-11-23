import CoreGraphics
import Foundation

// S4 balloon-unit join (legacy joinBalloonUnits): a fragment (< 3 letters) on the same enclosed
// paper component as another line, within 1.6 glyphs, joins that line's paragraph even when
// the column/row geometry does not link them.
final class PipelineBalloonUnits {
    private let boxes: [CGRect]
    private let letters: [Int]
    private let paper: PipelinePaperComponents?
    private var surfaces: [Int: Int?] = [:]

    init(lines: [PipelineLine], raster: PipelineGrayRaster?, pageSize: CGSize) {
        boxes = lines.map(\.bounds)
        letters = lines.map { $0.text.filter { !$0.isWhitespace }.count }
        paper = raster.map { PipelinePaperComponents(raster: $0, pageSize: pageSize) }
    }

    /// The gap between lines `i` and `j` in glyphs when they form one balloon unit, else nil.
    func gap(_ i: Int, _ j: Int) -> CGFloat? {
        guard min(letters[i], letters[j]) < 3, let x = surface(i), x == surface(j) else { return nil }
        let a = boxes[i], b = boxes[j]
        func glyph(_ r: CGRect, _ n: Int) -> CGFloat { min(min(r.width, r.height), (r.width * r.height / CGFloat(max(1, n))).squareRoot()) }
        let large = max(glyph(a, letters[i]), glyph(b, letters[j]))
        let gap = max(max(a.minX, b.minX) - min(a.maxX, b.maxX), max(a.minY, b.minY) - min(a.maxY, b.maxY))
        return large > 0 && gap <= large * 1.6 ? max(0, gap) / large : nil
    }

    private func surface(_ index: Int) -> Int? {
        if let cached = surfaces[index] { return cached }
        let value = paper?.enclosing(boxes[index])
        surfaces[index] = value
        return value
    }
}

/// Light (>= 225) 4-connected paper components of the gray page, labelled on demand.
/// A line's surface is the component holding >= 60% of the light cells in its box; it
/// encloses the line when it is centred on the box, does not touch the page edge, spans
/// under 3/4 of the page each way and is at least 1.5 times the box (legacy ComponentMap).
final class PipelinePaperComponents {
    private struct Stats {
        var count = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var edge = false
    }
    private let raster: PipelineGrayRaster
    private let sx: CGFloat, sy: CGFloat
    private var labels: [Int32]
    private var stats: [Stats] = []
    static let light: UInt8 = 225

    init(raster: PipelineGrayRaster, pageSize: CGSize) {
        self.raster = raster
        sx = CGFloat(raster.width) / max(1, pageSize.width)
        sy = CGFloat(raster.height) / max(1, pageSize.height)
        labels = [Int32](repeating: -1, count: raster.pixels.count)
    }

    func enclosing(_ rect: CGRect) -> Int? {
        let width = raster.width, height = raster.height
        guard raster.pixels.count == width * height,
              [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite && abs($0) < 1e9 }) else { return nil }
        let x0 = Int((rect.minX * sx).rounded()), y0 = Int((rect.minY * sy).rounded())
        let x1 = Int((rect.maxX * sx).rounded()) - 1, y1 = Int((rect.maxY * sy).rounded()) - 1
        guard x0 > 0, y0 > 0, x1 < width - 1, y1 < height - 1, x1 - x0 >= 3, y1 - y0 >= 3 else { return nil }
        var tally: [Int: Int] = [:], light = 0
        for y in y0...y1 {
            for x in x0...x1 where raster.pixels[y * width + x] >= Self.light {
                light += 1
                tally[label(y * width + x), default: 0] += 1
            }
        }
        let area = (x1 - x0 + 1) * (y1 - y0 + 1)
        guard light * 10 >= area * 3,
              let (id, count) = tally.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
              count * 10 >= light * 6 else { return nil }
        let c = stats[id], cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        guard !c.edge, c.minX < cx, c.maxX > cx, c.minY < cy, c.maxY > cy,
              (c.maxX - c.minX) * 4 < width * 3, (c.maxY - c.minY) * 4 < height * 3, c.count >= area * 3 / 2 else { return nil }
        return id
    }

    private func label(_ seed: Int) -> Int {
        if labels[seed] >= 0 { return Int(labels[seed]) }
        let width = raster.width, height = raster.height, id = Int32(stats.count)
        var value = Stats(), queue = [seed], cursor = 0
        labels[seed] = id
        while cursor < queue.count {
            let point = queue[cursor]
            cursor += 1
            let x = point % width, y = point / width
            value.count += 1
            value.minX = min(value.minX, x); value.maxX = max(value.maxX, x)
            value.minY = min(value.minY, y); value.maxY = max(value.maxY, y)
            if x == 0 || y == 0 || x == width - 1 || y == height - 1 { value.edge = true }
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < width && ny >= 0 && ny < height {
                let next = ny * width + nx
                if labels[next] < 0, raster.pixels[next] >= Self.light { labels[next] = id; queue.append(next) }
            }
        }
        stats.append(value)
        return Int(id)
    }
}
