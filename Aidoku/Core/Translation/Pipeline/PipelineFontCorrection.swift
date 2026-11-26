import CoreGraphics
import Foundation

/// S8 font px as layout reads it: each `PipelineSimpleFont` size group's geometric size A (train median bias
/// removed) moved toward the group's character pitch P, then times exp(level).
/// Pitch of a line: its ink extent along the reading axis (Otsu ink of the line box padded by 15% of its short
/// side) over a cell count, a linear table over character classes fit on TRAIN lines (`cellWeights`).
/// P is the cell-weighted median over the group's lines, N their cells, S the weighted median |log pitch - P|;
/// log size = log A + N / (N + n0) (P - log A) when S <= maxSpread, else log A. Mostly-Latin horizontal groups
/// take log A + latin. One size per group keeps grouped blocks equal. `level` keeps the global level the S9
/// sizing constants were fit to. Held-out (fit on TRAIN): share of blocks off by more than 10% 4.2% -> 3.9% (dev),
/// 5.8% -> 2.2% (test) against the forest this replaces.
/// The fitted table and constants are in Resources/Translation/PipelineFontSize.json
/// (Scripts/pipeline/tools/retrain/fontsize/train.py); without the file layout keeps the geometric sizes.
enum PipelineFontCorrection {
    struct Model: Decodable, Sendable {
        let bias: Double
        let n0: Double
        let maxSpread: Double
        let latin: Double
        /// Cells per character class (`CellClass` order), then per ellipsis run and per !? run.
        let cellWeights: [Double]
        let cellOffset: Double
    }

    static let model: Model? = {
        var urls = [Bundle.main.url(forResource: "PipelineFontSize", withExtension: "json")].compactMap { $0 }
        if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] {
            urls.append(URL(fileURLWithPath: root).appendingPathComponent("Aidoku/Resources/Translation/PipelineFontSize.json"))
        }
        return urls.lazy.compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(Model.self, from: $0) }
            .first { $0.cellWeights.count == 12 }
    }()

    static var level: Double { PipelineTuning.current.fontLevel }
    static var bias: Double { model?.bias ?? 0 }
    static var cellWeights: [Double] { model?.cellWeights ?? [] }
    static var cellOffset: Double { model?.cellOffset ?? 0 }

    static func corrected(_ blocks: [PipelineBlock], fonts: [CGFloat], groups: [Int], image: CGImage?,
                          raster: PipelinePageRaster? = nil) -> [CGFloat] {
        guard !blocks.isEmpty, let model else { return fonts }
        let bias = model.bias, n0 = model.n0, maxSpread = model.maxSpread, latin = model.latin
        // Lines are independent; measure them concurrently, then pool in block / line order.
        let jobs = blocks.indices.flatMap { index in blocks[index].lines.indices.map { (index, $0) } }
        let extents = UnsafeMutableBufferPointer<Int>.allocate(capacity: max(1, jobs.count))
        extents.initialize(repeating: 0)
        defer { extents.deallocate() }
        DispatchQueue.concurrentPerform(iterations: jobs.count) { k in
            let block = blocks[jobs[k].0], line = block.lines[jobs[k].1]
            guard !line.text.isEmpty else { return }
            extents[k] = inkExtent(line.polygon, vertical: block.vertical, image: image, raster: raster) ?? 0
        }
        var pitches: [Int: [(value: Double, weight: Double)]] = [:]
        for (k, (index, line)) in jobs.enumerated() where extents[k] > 0 {
            let cells = cellCount(blocks[index].lines[line].text)
            guard cells >= 0.5 else { continue }
            pitches[groups[index], default: []].append((log(Double(extents[k]) / cells), cells))
        }
        var members: [Int: [Int]] = [:]
        for index in blocks.indices { members[groups[index], default: []].append(index) }
        var result = fonts
        for (group, indices) in members {
            let a0 = log(Double(fonts[indices[0]])) - bias
            var size = a0
            if isLatin(indices.map { blocks[$0] }) {
                size = a0 + latin
            } else if let lines = pitches[group], !lines.isEmpty {
                let p = weightedMedian(lines)
                let spread = weightedMedian(lines.map { (abs($0.value - p), $0.weight) })
                let n = lines.reduce(0) { $0 + $1.weight }
                if spread <= maxSpread { size = a0 + n / (n + n0) * (p - a0) }
            }
            for index in indices { result[index] = CGFloat(exp(size + level)) }
        }
        return result
    }

    /// The first value (ascending) whose cumulative weight reaches half the total.
    static func weightedMedian(_ items: [(value: Double, weight: Double)]) -> Double {
        let sorted = items.enumerated().sorted { $0.element.value != $1.element.value ? $0.element.value < $1.element.value : $0.offset < $1.offset }
        let half = 0.5 * sorted.reduce(0) { $0 + $1.element.weight }
        var cumulative = 0.0
        for item in sorted {
            cumulative += item.element.weight
            if cumulative >= half { return item.element.value }
        }
        return sorted.last?.element.value ?? 0
    }

    /// Horizontal (most blocks) and more than half ASCII letters or digits.
    static func isLatin(_ blocks: [PipelineBlock]) -> Bool {
        guard blocks.filter({ !$0.vertical }).count * 2 > blocks.count else { return false }
        var ascii = 0, total = 0
        for scalar in blocks.map(\.sourceText).joined().unicodeScalars where !scalar.properties.isWhitespace {
            total += 1
            if cellClass(scalar) == .ascii { ascii += 1 }
        }
        return Double(ascii) / Double(max(1, total)) > 0.5
    }

    // MARK: - Cells

    enum CellClass: Int { case cjk, small, long, halfPunct, ellipsis, dot, bang, tilde, ascii, other }

    private static let small = Set("ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ".unicodeScalars)
    private static let long = Set("ーｰ一—―－-".unicodeScalars)
    private static let halfPunct = Set("、。，．,「」『』（）()【】〈〉《》“”\"'［］[]".unicodeScalars)
    private static let ellipsis = Set("…‥".unicodeScalars), dot = Set(".・･·".unicodeScalars)
    private static let bang = Set("!?！？".unicodeScalars), tilde = Set("~～〜∼".unicodeScalars)

    static func cellClass(_ s: Unicode.Scalar) -> CellClass {
        if small.contains(s) { return .small }
        if long.contains(s) { return .long }
        if halfPunct.contains(s) { return .halfPunct }
        if ellipsis.contains(s) { return .ellipsis }
        if dot.contains(s) { return .dot }
        if bang.contains(s) { return .bang }
        if tilde.contains(s) { return .tilde }
        let v = s.value
        if v < 128, s.properties.isAlphabetic || ("0"..."9").contains(s) { return .ascii }
        switch v {
        case 0x3040...0x30FF, 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0xFF10...0xFF5A, 0xAC00...0xD7AF: return .cjk
        default: return .other
        }
    }

    /// Cells a line occupies: class weights plus one weight per run of ellipses and per run of !? marks.
    static func cellCount(_ text: String) -> Double {
        var counts = [Double](repeating: 0, count: 12)
        var previous: CellClass?
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace { previous = nil; continue }
            let c = cellClass(scalar)
            counts[c.rawValue] += 1
            if c != previous {
                if c == .ellipsis { counts[10] += 1 } else if c == .bang { counts[11] += 1 }
            }
            previous = c
        }
        guard let model else { return 0 }
        return zip(counts, model.cellWeights).reduce(model.cellOffset) { $0 + $1.0 * $1.1 }
    }

    // MARK: - Ink extent

    /// Rows (vertical) or columns of the padded line box from the first to the last whose ink count reaches a
    /// quarter of the mean; ink is the Otsu class rarer on the crop border. nil when the box is too small.
    static func inkExtent(_ polygon: [CGPoint], vertical: Bool, image: CGImage?, raster: PipelinePageRaster?) -> Int? {
        guard !polygon.isEmpty, let width = raster?.width ?? image?.width, let height = raster?.height ?? image?.height
        else { return nil }
        let xs = polygon.map { Double($0.x) }, ys = polygon.map { Double($0.y) }
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let pad = 0.15 * (vertical ? maxX - minX : maxY - minY)
        guard pad.isFinite else { return nil }
        func clamp(_ value: Double, _ limit: Int) -> Int { Int(min(Double(limit), max(0, value))) }
        let x0 = clamp((minX - pad).rounded(.down), width), x1 = clamp((maxX + pad).rounded(.up), width)
        let y0 = clamp((minY - pad).rounded(.down), height), y1 = clamp((maxY + pad).rounded(.up), height)
        let w = x1 - x0, h = y1 - y0
        guard w >= 4, h >= 4, let gray = grayPlane(x0: x0, y0: y0, w: w, h: h, image: image, raster: raster) else { return nil }
        return inkExtent(gray: gray, width: w, height: h, vertical: vertical)
    }

    static func inkExtent(gray: [UInt8], width w: Int, height h: Int, vertical: Bool) -> Int {
        var histogram = [Double](repeating: 0, count: 256)
        for g in gray { histogram[Int(g)] += 1 }
        let threshold = otsu(histogram)
        let dark = gray.map { Int($0) <= threshold }
        var border = 0
        for x in 0..<w { border += (dark[x] ? 1 : 0) + (dark[(h - 1) * w + x] ? 1 : 0) }
        for y in 0..<h { border += (dark[y * w] ? 1 : 0) + (dark[y * w + w - 1] ? 1 : 0) }
        let inkIsDark = Double(border) / Double(2 * (w + h)) < 0.5
        var along = [Int](repeating: 0, count: vertical ? h : w)
        for y in 0..<h {
            for x in 0..<w where dark[y * w + x] == inkIsDark { along[vertical ? y : x] += 1 }
        }
        let mean = Double(along.reduce(0, +)) / Double(along.count)
        guard mean > 0, let first = along.firstIndex(where: { Double($0) >= 0.25 * mean }),
              let last = along.lastIndex(where: { Double($0) >= 0.25 * mean }) else { return 0 }
        return last - first + 1
    }

    /// Otsu threshold (between-class variance argmax, first on ties) of a 256-bin histogram.
    static func otsu(_ histogram: [Double]) -> Int {
        let total = histogram.reduce(0, +)
        var w = 0.0, mu = 0.0
        var cumW = [Double](repeating: 0, count: 256), cumMu = [Double](repeating: 0, count: 256)
        for i in 0..<256 {
            let p = histogram[i] / total
            w += p; mu += p * Double(i); cumW[i] = w; cumMu[i] = mu
        }
        var best = 0, bestScore = -Double.infinity
        for i in 0..<256 {
            let d = mu * cumW[i] - cumMu[i]
            var score = d * d / (cumW[i] * (1 - cumW[i]))
            if !score.isFinite { score = 0 }
            if score > bestScore { best = i; bestScore = score }
        }
        return best
    }

    /// Luminance (ITU-R 601, integer rounding) of a page region, from the raster bytes or a 1:1 draw of the image.
    static func grayPlane(x0: Int, y0: Int, w: Int, h: Int, image: CGImage?, raster: PipelinePageRaster?) -> [UInt8]? {
        func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Int(r) * 19595 + Int(g) * 38470 + Int(b) * 7471 + 0x8000) >> 16)
        }
        var gray = [UInt8](repeating: 0, count: w * h)
        if let raster {
            raster.rgba.withUnsafeBufferPointer { page in
                for y in 0..<h {
                    var source = ((y0 + y) * raster.width + x0) * 4
                    for x in 0..<w {
                        gray[y * w + x] = luma(page[source], page[source + 1], page[source + 2]); source += 4
                    }
                }
            }
            return gray
        }
        guard let image, let crop = image.cropping(to: CGRect(x: x0, y: y0, width: w, height: h)) else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        for i in 0..<(w * h) { gray[i] = luma(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]) }
        return gray
    }
}
