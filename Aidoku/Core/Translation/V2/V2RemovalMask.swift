import Accelerate
import CoreGraphics
import Foundation

/// S6: page-size 0/255 source-text removal mask, recall first.
///
/// Per block, inside the line polygons dilated by max(8, 0.3 T) (T = median line
/// thickness), cheap local-background features (black-hat / top-hat at 0.12/0.3/0.6 T
/// and at 1/2.5 estimated stroke widths, colour distance to the ring background, local
/// contrast, signed polygon distance) feed a two-stage auto-context MLP fit on train GT
/// `text_glyph_instance_mask` (the out-of-repo research scripts (scripts-mask)). The stage-2 probability is
/// thresholded low and dilated 2 px so antialiased fringes and outline bands are
/// erased. No RF-DETR evidence or legacy forest is needed.
enum V2RemovalMask {
    static let roiScale = 0.3
    static let roiMinimum = 8
    static let threshold: Float = 0.05
    /// Large lettering (line thickness >= 70 px) gets a lower threshold. Both values were fit on
    /// the train split only (max train recall with train far-FP <= 1.15x legacy).
    static let largeThickness: Double = 70
    static let largeThreshold: Float = 0.01
    static let outputDilation = 2
    static let maximumThickness: Double = 400

    static func build(_ page: V2Page, blocks: [V2Block], layout: [V2LayoutRegion]) -> [UInt8] {
        let width = page.width, height = page.height
        guard width > 0, height > 0 else { return [] }
        guard let rgba = rgbaBytes(page.image) else { return [UInt8](repeating: 0, count: width * height) }
        return build(rgba: rgba, width: width, height: height, blocks: blocks, layout: layout)
    }

    /// Same as `build(_:blocks:layout:)` for callers that already hold the page as
    /// RGBA8 (row-major, 4 bytes per pixel, alpha ignored).
    static func build(rgba: [UInt8], width: Int, height: Int, blocks: [V2Block], layout: [V2LayoutRegion]) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: width * height)
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return mask }
        let targets = blocks.filter { $0.role != .background }
        guard !targets.isEmpty else { return mask }
        var results = [BlockMask?](repeating: nil, count: targets.count)
        rgba.withUnsafeBufferPointer { pixels in
            results.withUnsafeMutableBufferPointer { out in
                let base = out.baseAddress!
                DispatchQueue.concurrentPerform(iterations: targets.count) { index in
                    base[index] = segment(targets[index], pixels: pixels, width: width, height: height)
                }
            }
        }
        for case let result? in results {
            for y in 0..<result.frame.height {
                let row = (result.frame.y + y) * width + result.frame.x
                for x in 0..<result.frame.width where result.mask[y * result.frame.width + x] != 0 {
                    mask[row + x] = 255
                }
            }
        }
        return mask
    }

    // MARK: - Per block

    struct Frame: Equatable {
        var x: Int, y: Int, width: Int, height: Int
    }

    struct BlockMask {
        let frame: Frame
        let mask: [UInt8]
    }

    static func linePolygons(_ block: V2Block) -> [[CGPoint]] {
        var polygons = block.lines.map { line -> [CGPoint] in
            line.polygon.count >= 3 ? line.polygon : corners(line.bounds)
        }.filter { polygon in polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite } && area(polygon) > 0 }
        if polygons.isEmpty {
            let fallback = block.polygon.count >= 3 ? block.polygon : corners(block.bounds)
            if fallback.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), area(fallback) > 0 { polygons = [fallback] }
        }
        return polygons
    }

    static func segment(_ block: V2Block, pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int) -> BlockMask? {
        let polygons = linePolygons(block)
        guard !polygons.isEmpty else { return nil }
        let thickness = min(maximumThickness, max(1, median(polygons.map(minimumRectSide))))
        let roiRadius = max(roiMinimum, roundEven(roiScale * thickness))
        let scales = [max(2, roundEven(0.12 * thickness)), max(3, roundEven(0.3 * thickness)),
                      max(4, roundEven(0.6 * thickness))]
        let blurHalf = max(3, roundEven(0.25 * thickness) | 1)
        let pad = roiRadius + max(scales[2], 2 * blurHalf, outputDilation) + 4
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for point in polygons.joined() {
            minX = min(minX, point.x); minY = min(minY, point.y); maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        let x0 = max(0, Int(floor(minX)) - pad), y0 = max(0, Int(floor(minY)) - pad)
        let x1 = min(width, Int(ceil(maxX)) + pad + 1), y1 = min(height, Int(ceil(maxY)) + pad + 1)
        guard x1 > x0, y1 > y0 else { return nil }
        let frame = Frame(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        let w = frame.width, h = frame.height, n = w * h
        let space = Workspace(width: w, height: h)

        // Rasterise the line polygons and the dilated ROI.
        let poly = space.plane(zero: true)
        for polygon in polygons {
            fill(polygon.map { CGPoint(x: $0.x - CGFloat(x0), y: $0.y - CGFloat(y0)) }, into: poly, width: w, height: h)
        }
        let roi = space.copy(poly)
        morph(roi, width: w, height: h, radius: roiRadius, max: true, space: space)
        var roiIndices = [Int]()
        roiIndices.reserveCapacity(n / 2)
        for i in 0..<n where roi[i] > 0 { roiIndices.append(i) }
        guard !roiIndices.isEmpty else { return nil }
        let rows = roiIndices.count

        // Colour planes.
        let red = space.plane(), green = space.plane(), blue = space.plane()
        let luma = space.plane(), high = space.plane(), low = space.plane()
        for y in 0..<h {
            var source = ((y0 + y) * width + x0) * 4
            for x in 0..<w {
                let i = y * w + x
                let r = Float(pixels[source]) / 255, g = Float(pixels[source + 1]) / 255, b = Float(pixels[source + 2]) / 255
                red[i] = r; green[i] = g; blue[i] = b
                luma[i] = 0.299 * r + 0.587 * g + 0.114 * b
                high[i] = max(r, g, b); low[i] = min(r, g, b)
                source += 4
            }
        }

        // Block background from the 3 px ring around the ROI.
        let ringMask = space.copy(roi)
        morph(ringMask, width: w, height: h, radius: 3, max: true, space: space)
        var ring = [Int]()
        for i in 0..<n where ringMask[i] > 0 && roi[i] == 0 { ring.append(i) }
        space.recycle(ringMask); space.recycle(roi)
        if ring.count < 8 { ring = roiIndices.filter { poly[$0] == 0 } }
        if ring.count < 8 { ring = roiIndices }
        let background = (orderMedian(red, at: ring), orderMedian(green, at: ring), orderMedian(blue, at: ring))
        let distance = space.plane()
        for i in 0..<n {
            distance[i] = max(abs(red[i] - background.0), abs(green[i] - background.1), abs(blue[i] - background.2))
        }
        space.recycle(red); space.recycle(green); space.recycle(blue)
        let backgroundLuma = 0.299 * background.0 + 0.587 * background.1 + 0.114 * background.2
        let ringLuma = sortedValues(luma, at: ring)
        let ringMean = ringLuma.reduce(0, +) / Float(ringLuma.count)
        let ringStd = sqrt(ringLuma.reduce(0) { $0 + ($1 - ringMean) * ($1 - ringMean) } / Float(ringLuma.count))
        let ringLow = percentile(sorted: ringLuma, 10), ringHigh = percentile(sorted: ringLuma, 90)
        var insideIndices = [Int]()
        insideIndices.reserveCapacity(n / 2)
        for i in 0..<n where poly[i] > 0 { insideIndices.append(i) }
        let inkLuma = insideIndices.isEmpty ? backgroundLuma : orderPercentile(luma, at: insideIndices, 10)

        let f1 = stage1.features
        precondition(f1 == 29)
        // Feature-major (one contiguous plane of `rows` values per feature); stage 2 appends to it.
        let features = UnsafeMutablePointer<Float>.allocate(capacity: rows * stage2.features)
        defer { features.deallocate() }
        let index = UnsafeMutablePointer<Int>.allocate(capacity: rows)
        defer { index.deallocate() }
        index.initialize(from: roiIndices, count: rows)
        func column(_ f: Int) -> UnsafeMutablePointer<Float> { features + f * rows }
        func gather(_ plane: UnsafePointer<Float>, into f: Int) {
            let target = column(f)
            for row in 0..<rows { target[row] = plane[index[row]] }
        }
        func constant(_ value: Float, into f: Int) { column(f).update(repeating: value, count: rows) }
        // Black-hat (closing - low) into column f and top-hat (high - opening) into column g;
        // `keep` also leaves both full planes for the 2 px neighbourhood features.
        func hats(_ scale: Int, dark f: Int, light g: Int, space: Workspace,
                  keep: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)? = nil) {
            let closed = space.copy(high), opened = space.copy(low)
            morph2(closed, width: w, height: h, radius: scale, firstMax: true, space: space)
            morph2(opened, width: w, height: h, radius: scale, firstMax: false, space: space)
            if let (dark, light) = keep {
                for i in 0..<n { dark[i] = closed[i] - low[i]; light[i] = high[i] - opened[i] }
                gather(dark, into: f); gather(light, into: g)
            } else {
                let dark = column(f), light = column(g)
                for row in 0..<rows {
                    let i = index[row]
                    dark[row] = closed[i] - low[i]; light[row] = high[i] - opened[i]
                }
            }
            space.recycle(closed); space.recycle(opened)
        }
        let parallel = n >= parallelPixels

        do {
            let a = column(0), b = column(1), c = column(2), d = column(3), e = column(19)
            for row in 0..<rows {
                let i = index[row]
                a[row] = luma[i]; b[row] = high[i] - low[i]; c[row] = distance[i]
                d[row] = luma[i] - backgroundLuma; e[row] = abs(luma[i] - inkLuma)
            }
        }
        let invThickness = 1 / Float(max(thickness, 1))
        constant(backgroundLuma, into: 15); constant(ringStd, into: 16); constant(inkLuma, into: 17)
        constant(Float(log(thickness) / 5), into: 18)
        constant(ringLow, into: 20); constant(ringHigh, into: 21)

        // High-contrast pixels inside the line polygons (stroke-width features below).
        let ink = space.plane(zero: true)
        var inkIndices = [Int]()
        for i in 0..<n where poly[i] > 0 && distance[i] >= 0.25 { ink[i] = 1; inkIndices.append(i) }
        let inkGap = space.plane()
        var stroke: Float = 1

        // Independent feature groups (disjoint feature columns, read-only shared planes).
        let groups = 5
        runGroups(groups, parallel: parallel) { group in
            let local = Workspace(width: w, height: h)
            switch group {
            case 0:
                hats(scales[0], dark: 4, light: 5, space: local)
                hats(scales[2], dark: 8, light: 9, space: local)
            case 1:
                let darkMiddle = local.plane(), lightMiddle = local.plane()
                hats(scales[1], dark: 6, light: 7, space: local, keep: (darkMiddle, lightMiddle))
                morph(darkMiddle, width: w, height: h, radius: 2, max: true, space: local)
                gather(darkMiddle, into: 10)
                morph(lightMiddle, width: w, height: h, radius: 2, max: true, space: local)
                gather(lightMiddle, into: 11)
                let distanceNear = local.copy(distance)
                morph(distanceNear, width: w, height: h, radius: 2, max: true, space: local)
                gather(distanceNear, into: 12)
                let lumaMean = local.copy(luma), lumaSquareMean = local.plane()
                for i in 0..<n { lumaSquareMean[i] = luma[i] * luma[i] }
                boxBlur(lumaMean, width: w, height: h, radius: 2, space: local)
                boxBlur(lumaSquareMean, width: w, height: h, radius: 2, space: local)
                let target = column(13)
                for row in 0..<rows {
                    let i = index[row]
                    target[row] = sqrt(max(lumaSquareMean[i] - lumaMean[i] * lumaMean[i], 0))
                }
            case 2:
                let inside = local.plane(), outside = local.plane()
                chamfer(poly, into: inside, width: w, height: h, inverted: false)
                chamfer(poly, into: outside, width: w, height: h, inverted: true)
                let target = column(14)
                for row in 0..<rows {
                    let i = index[row]
                    target[row] = min(1, max(-1, (outside[i] - inside[i]) * invThickness))
                }
            case 3:
                // Stroke width from the distance transform of the ink pixels, then black-hat /
                // top-hat at 1 and 2.5 stroke widths so very thick lettering is not out of distribution.
                let inkDepth = local.plane(zero: true)
                let width: Float
                if inkIndices.count >= 4 {
                    chamfer(ink, into: inkDepth, width: w, height: h, inverted: false)
                    width = min(Float(thickness), max(1, 2 * orderPercentile(inkDepth, at: inkIndices, 90)))
                } else {
                    width = max(1, Float(0.1 * thickness))
                }
                stroke = width
                let invStroke = 1 / width, depth = column(26)
                for row in 0..<rows { depth[row] = min(2, max(0, inkDepth[index[row]] * invStroke)) }
                constant(log(width / Float(thickness)), into: 28)
                hats(max(1, roundEven(Double(width))), dark: 22, light: 23, space: local)
                hats(max(2, roundEven(2.5 * Double(width))), dark: 24, light: 25, space: local)
            default:
                chamfer(ink, into: inkGap, width: w, height: h, inverted: true)
            }
        }
        do {
            let invStroke = 1 / stroke, gap = column(27)
            for row in 0..<rows { gap[row] = min(3, max(0, inkGap[index[row]] * invStroke)) }
        }
        space.recycle(ink); space.recycle(inkGap); space.recycle(distance)
        space.recycle(luma); space.recycle(high); space.recycle(low)

        let p1 = space.plane(zero: true)
        do {
            let p1Values = column(f1)
            mlp(features, rows: rows, network: stage1, output: p1Values, parallel: parallel)
            for row in 0..<rows { p1[index[row]] = p1Values[row] }
        }

        // Auto-context neighbourhood of the stage-1 probability, one feature column each.
        let f2 = stage2.features
        precondition(f2 == f1 + 1 + 9)
        let closeRadius = max(2, roundEven(0.06 * thickness))
        let spreadRadius = max(4, roundEven(0.15 * thickness))
        let blurRadii = [2, blurHalf, 2 * blurHalf]
        runGroups(3, parallel: parallel) { group in
            let local = Workspace(width: w, height: h)
            func context(_ k: Int, _ transform: (UnsafeMutablePointer<Float>) -> Void) {
                let plane = local.copy(p1)
                transform(plane)
                gather(plane, into: f1 + 1 + k)
                local.recycle(plane)
            }
            switch group {
            case 0:
                for (k, radius) in [1, 2, 4].enumerated() {
                    context(k) { morph($0, width: w, height: h, radius: radius, max: true, space: local) }
                }
                context(3) { morph($0, width: w, height: h, radius: 1, max: false, space: local) }
            case 1:
                for (k, radius) in blurRadii.enumerated() {
                    context(4 + k) { boxBlur($0, width: w, height: h, radius: radius, space: local) }
                }
            default:
                context(7) { morph2($0, width: w, height: h, radius: closeRadius, firstMax: true, space: local) }
                context(8) { morph($0, width: w, height: h, radius: spreadRadius, max: true, space: local) }
            }
        }
        space.recycle(p1)

        let p2 = UnsafeMutablePointer<Float>.allocate(capacity: rows)
        defer { p2.deallocate() }
        mlp(features, rows: rows, network: stage2, output: p2, parallel: parallel)
        let cut = thickness >= largeThickness ? largeThreshold : threshold
        let out = space.plane(zero: true)
        for row in 0..<rows where p2[row] >= cut { out[index[row]] = 1 }
        morph(out, width: w, height: h, radius: outputDilation, max: true, space: space)
        let mask = [UInt8](unsafeUninitializedCapacity: n) { buffer, count in
            for i in 0..<n { buffer[i] = out[i] > 0 ? 1 : 0 }
            count = n
        }
        return BlockMask(frame: frame, mask: mask)
    }

    /// Blocks smaller than this run their feature groups serially.
    static let parallelPixels = 65_536

    /// Runs `body(0..<count)`; concurrently (nested under the per-block loop) for large blocks.
    static func runGroups(_ count: Int, parallel: Bool, _ body: (Int) -> Void) {
        if parallel {
            DispatchQueue.concurrentPerform(iterations: count, execute: body)
        } else {
            for group in 0..<count { body(group) }
        }
    }

    /// Equal-size float planes and morphology/blur scratch for one block, recycled so a block
    /// touches a handful of planes instead of allocating (and page-faulting) dozens.
    final class Workspace {
        let width: Int, height: Int, count: Int
        private var spare: [UnsafeMutablePointer<Float>] = []
        private var owned: [UnsafeMutablePointer<Float>] = []
        private var bands: UnsafeMutablePointer<Float>?
        private var bandCapacity = 0

        init(width: Int, height: Int) {
            self.width = width; self.height = height; count = width * height
        }

        deinit {
            for plane in owned { plane.deallocate() }
            bands?.deallocate()
        }

        func plane(zero: Bool = false) -> UnsafeMutablePointer<Float> {
            let plane: UnsafeMutablePointer<Float>
            if let reused = spare.popLast() {
                plane = reused
            } else {
                plane = .allocate(capacity: count)
                owned.append(plane)
            }
            if zero { plane.update(repeating: 0, count: count) }
            return plane
        }

        func copy(_ source: UnsafePointer<Float>) -> UnsafeMutablePointer<Float> {
            let plane = plane()
            plane.update(from: source, count: count)
            return plane
        }

        func recycle(_ plane: UnsafeMutablePointer<Float>) { spare.append(plane) }

        /// Scratch of at least `capacity` floats (contents undefined).
        func band(_ capacity: Int) -> UnsafeMutablePointer<Float> {
            if capacity > bandCapacity {
                bands?.deallocate()
                bands = .allocate(capacity: capacity)
                bandCapacity = capacity
            }
            return bands!
        }
    }

    /// Value at each index, ascending.
    static func sortedValues(_ plane: UnsafePointer<Float>, at indices: [Int]) -> [Float] {
        guard !indices.isEmpty else { return [] }
        var values = gathered(plane, at: indices)
        values.withUnsafeMutableBufferPointer { vDSP_vsort($0.baseAddress!, vDSP_Length($0.count), 1) }
        return values
    }

    /// Gathered values; `orderMedian` / `orderPercentile` equal `median` / `percentile(sorted:)` of
    /// them (exact order statistics by selection instead of a full sort).
    static func gathered(_ plane: UnsafePointer<Float>, at indices: [Int]) -> [Float] {
        [Float](unsafeUninitializedCapacity: indices.count) { buffer, count in
            for (k, i) in indices.enumerated() { buffer[k] = plane[i] }
            count = indices.count
        }
    }

    static func orderMedian(_ plane: UnsafePointer<Float>, at indices: [Int]) -> Float {
        guard !indices.isEmpty else { return 0 }
        var values = gathered(plane, at: indices)
        return values.withUnsafeMutableBufferPointer { buffer in
            let a = buffer.baseAddress!, c = buffer.count
            select(a, count: c, c / 2)
            guard c % 2 == 0 else { return a[c / 2] }
            var below = a[0]
            for i in 1..<(c / 2) { below = max(below, a[i]) }
            return (below + a[c / 2]) / 2
        }
    }

    static func orderPercentile(_ plane: UnsafePointer<Float>, at indices: [Int], _ q: Float) -> Float {
        guard !indices.isEmpty else { return 0 }
        var values = gathered(plane, at: indices)
        return values.withUnsafeMutableBufferPointer { buffer in
            let a = buffer.baseAddress!, c = buffer.count
            let position = Float(c - 1) * q / 100
            let lower = Int(position), upper = min(c - 1, lower + 1)
            select(a, count: c, lower)
            var next = a[lower]
            if upper > lower {
                next = a[upper]
                for i in upper..<c { next = min(next, a[i]) }
            }
            return a[lower] + (next - a[lower]) * (position - Float(lower))
        }
    }

    /// Quickselect: afterwards a[k] is the k-th smallest, with no larger value before it and
    /// no smaller value after it.
    static func select(_ a: UnsafeMutablePointer<Float>, count: Int, _ k: Int) {
        func swap(_ x: Int, _ y: Int) { let t = a[x]; a[x] = a[y]; a[y] = t }
        var lo = 0, hi = count - 1
        while hi > lo {
            let mid = lo + (hi - lo) / 2
            if a[mid] < a[lo] { swap(mid, lo) }
            if a[hi] < a[lo] { swap(hi, lo) }
            if a[hi] < a[mid] { swap(hi, mid) }
            let pivot = a[mid]
            var i = lo, j = hi
            while i <= j {
                while a[i] < pivot { i += 1 }
                while a[j] > pivot { j -= 1 }
                if i <= j { swap(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { return }
        }
    }

    // MARK: - MLP (two ReLU layers, sigmoid output)

    struct Network {
        let features: Int, hidden: Int
        let w1: [Float], b1: [Float], w2: [Float], b2: [Float], w3: [Float], b3: Float

        /// Unpacks W1[hidden x features], b1, W2[hidden x hidden], b2, w3[hidden], b3 (row-major).
        init(_ weights: [Float], features: Int, hidden: Int) {
            precondition(weights.count == hidden * features + hidden * hidden + 3 * hidden + 1)
            self.features = features; self.hidden = hidden
            var offset = 0
            func take(_ count: Int) -> [Float] {
                defer { offset += count }
                return Array(weights[offset..<(offset + count)])
            }
            w1 = take(hidden * features); b1 = take(hidden)
            w2 = take(hidden * hidden); b2 = take(hidden)
            w3 = take(hidden); b3 = weights[offset]
        }
    }

    static let stage1 = Network(V2RemovalMaskWeights.stage1, features: V2RemovalMaskWeights.stage1Features,
                                hidden: V2RemovalMaskWeights.stage1Hidden)
    static let stage2 = Network(V2RemovalMaskWeights.stage2, features: V2RemovalMaskWeights.stage2Features,
                                hidden: V2RemovalMaskWeights.stage2Hidden)

    /// Two ReLU layers and a sigmoid output. `input` is feature-major: feature f of row r at
    /// f * rows + r (extra trailing planes are ignored).
    static func mlp(_ input: [Float], rows: Int, network net: Network) -> [Float] {
        precondition(input.count >= rows * net.features)
        var output = [Float](repeating: 0, count: rows)
        guard rows > 0 else { return output }
        input.withUnsafeBufferPointer { ip in
            output.withUnsafeMutableBufferPointer { op in
                mlp(ip.baseAddress!, rows: rows, network: net, output: op.baseAddress!)
            }
        }
        return output
    }

    /// Pointer form of `mlp(_:rows:network:)`. Rows are evaluated in fixed chunks of 16 384
    /// (each chunk is one identical BLAS call however they are scheduled); `parallel` runs the
    /// chunks concurrently, and a single chunk reads the input planes in place.
    static func mlp(_ input: UnsafePointer<Float>, rows: Int, network net: Network, output: UnsafeMutablePointer<Float>,
                    parallel: Bool = false) {
        let chunk = min(rows, 16_384)
        guard chunk > 0 else { return }
        let chunks = (rows + chunk - 1) / chunk
        runGroups(chunks, parallel: parallel && chunks > 1) { index in
            let start = index * chunk, count = min(chunk, rows - start)
            mlpChunk(input, rows: rows, start: start, count: count, network: net, output: output + start)
        }
    }

    private static func mlpChunk(_ input: UnsafePointer<Float>, rows: Int, start: Int, count: Int, network net: Network,
                                 output o: UnsafeMutablePointer<Float>) {
        let features = net.features, hidden = net.hidden, n = vDSP_Length(count)
        let x = count < rows ? UnsafeMutablePointer<Float>.allocate(capacity: count * features) : nil
        let layer1 = UnsafeMutablePointer<Float>.allocate(capacity: count * hidden)
        let layer2 = UnsafeMutablePointer<Float>.allocate(capacity: count * hidden)
        defer { x?.deallocate(); layer1.deallocate(); layer2.deallocate() }
        var zero: Float = 0
        let block: UnsafePointer<Float>
        if let x {
            for f in 0..<features { (x + f * count).update(from: input + f * rows + start, count: count) }
            block = UnsafePointer(x)
        } else {
            block = input
        }
        // layer = W[hidden x in] * X[in x count]; bias and ReLU per hidden row.
        vDSP_mmul(net.w1, 1, block, 1, layer1, 1, vDSP_Length(hidden), n, vDSP_Length(features))
        for j in 0..<hidden {
            var bias = net.b1[j]
            let row = layer1 + j * count
            vDSP_vsadd(row, 1, &bias, row, 1, n)
            vDSP_vthres(row, 1, &zero, row, 1, n)
        }
        vDSP_mmul(net.w2, 1, layer1, 1, layer2, 1, vDSP_Length(hidden), n, vDSP_Length(hidden))
        for j in 0..<hidden {
            var bias = net.b2[j]
            let row = layer2 + j * count
            vDSP_vsadd(row, 1, &bias, row, 1, n)
            vDSP_vthres(row, 1, &zero, row, 1, n)
        }
        vDSP_mmul(net.w3, 1, layer2, 1, o, 1, 1, n, vDSP_Length(hidden))
        // sigmoid(z + b3) = 1 / (1 + exp(-(z + b3)))
        var negBias = -net.b3, minusOne: Float = -1, one: Float = 1
        vDSP_vsmsa(o, 1, &minusOne, &negBias, o, 1, n)
        var length = Int32(count)
        vvexpf(o, o, &length)
        vDSP_vsadd(o, 1, &one, o, 1, n)
        vvrecf(o, o, &length)
    }

    // MARK: - Image primitives

    /// Square (2r+1) max/min filter, separable (van Herk / Gil-Werman over whole rows with
    /// vDSP, O(1) per pixel); samples outside the frame are ignored.
    static func morph(_ plane: inout [Float], width w: Int, height h: Int, radius r: Int, max isMax: Bool) {
        guard r > 0, w > 0, h > 0 else { return }
        let space = Workspace(width: w, height: h)
        plane.withUnsafeMutableBufferPointer { morph($0.baseAddress!, width: w, height: h, radius: r, max: isMax, space: space) }
    }

    static func morph(_ p: UnsafeMutablePointer<Float>, width w: Int, height h: Int, radius r: Int, max isMax: Bool,
                      space: Workspace) {
        guard r > 0, w > 0, h > 0 else { return }
        let t = space.plane()
        filterColumns(p, width: w, height: h, radius: r, max: isMax, space: space)
        vDSP_mtrans(p, 1, t, 1, vDSP_Length(w), vDSP_Length(h))
        filterColumns(t, width: h, height: w, radius: r, max: isMax, space: space)
        vDSP_mtrans(t, 1, p, 1, vDSP_Length(h), vDSP_Length(w))
        space.recycle(t)
    }

    /// Closing (`firstMax`) or opening: two square filters of radius r. The square filter is
    /// separable in either order, so the inner pair runs on the transposed plane and the
    /// result is exactly the two `morph` calls with two fewer transposes.
    static func morph2(_ p: UnsafeMutablePointer<Float>, width w: Int, height h: Int, radius r: Int, firstMax: Bool,
                       space: Workspace) {
        guard r > 0, w > 0, h > 0 else { return }
        let t = space.plane()
        filterColumns(p, width: w, height: h, radius: r, max: firstMax, space: space)
        vDSP_mtrans(p, 1, t, 1, vDSP_Length(w), vDSP_Length(h))
        filterColumns(t, width: h, height: w, radius: r, max: firstMax, space: space)
        filterColumns(t, width: h, height: w, radius: r, max: !firstMax, space: space)
        vDSP_mtrans(t, 1, p, 1, vDSP_Length(h), vDSP_Length(w))
        filterColumns(p, width: w, height: h, radius: r, max: !firstMax, space: space)
        space.recycle(t)
    }

    /// Vertical running max/min of window 2r+1 applied in place to every column.
    private static func filterColumns(_ data: UnsafeMutablePointer<Float>, width w: Int, height h: Int, radius r: Int,
                                      max isMax: Bool, space: Workspace) {
        let k = 2 * r + 1, length = (h + 2 * r + k - 1) / k * k, n = vDSP_Length(w)
        let prefix = space.band(2 * length * w)
        let suffix = prefix + length * w
        let neutral: Float = isMax ? -.infinity : .infinity
        func op(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>) {
            if isMax { vDSP_vmax(a, 1, b, 1, out, 1, n) } else { vDSP_vmin(a, 1, b, 1, out, 1, n) }
        }
        func source(_ i: Int) -> UnsafePointer<Float>? {
            let y = i - r
            return y >= 0 && y < h ? UnsafePointer(data + y * w) : nil
        }
        var start = 0
        while start < length {
        let end = start + k
        for i in start..<end {
            let target = prefix + i * w
            if let row = source(i) {
                if i == start { target.update(from: row, count: w) } else { op(target - w, row, target) }
            } else if i == start {
                target.update(repeating: neutral, count: w)
            } else {
                target.update(from: target - w, count: w)
            }
        }
        var i = end - 1
        while i >= start {
            let target = suffix + i * w
            if let row = source(i) {
                if i == end - 1 { target.update(from: row, count: w) } else { op(target + w, row, target) }
            } else if i == end - 1 {
                target.update(repeating: neutral, count: w)
            } else {
                target.update(from: target + w, count: w)
            }
            i -= 1
        }
        start = end
        }
        // Output y covers padded rows [y, y + 2r].
        for y in 0..<h { op(suffix + y * w, prefix + (y + 2 * r) * w, data + y * w) }
    }

    /// Normalised box blur of size 2r+1 with reflect-101 borders (OpenCV `blur` default).
    static func boxBlur(_ plane: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        var output = plane
        let space = Workspace(width: w, height: h)
        output.withUnsafeMutableBufferPointer { boxBlur($0.baseAddress!, width: w, height: h, radius: r, space: space) }
        return output
    }

    static func boxBlur(_ p: UnsafeMutablePointer<Float>, width w: Int, height h: Int, radius r: Int, space: Workspace) {
        let t = space.plane()
        blurColumns(p, width: w, height: h, radius: r, space: space)
        vDSP_mtrans(p, 1, t, 1, vDSP_Length(w), vDSP_Length(h))
        blurColumns(t, width: h, height: w, radius: r, space: space)
        vDSP_mtrans(t, 1, p, 1, vDSP_Length(h), vDSP_Length(w))
        space.recycle(t)
    }

    /// Vertical running mean of window 2r+1 (reflect-101) applied in place to every column.
    private static func blurColumns(_ data: UnsafeMutablePointer<Float>, width w: Int, height h: Int, radius r: Int,
                                    space: Workspace) {
        func reflect(_ i: Int) -> Int {
            guard h > 1 else { return 0 }
            var j = i
            while j < 0 || j >= h { j = j < 0 ? -j : 2 * (h - 1) - j }
            return j
        }
        let n = vDSP_Length(w)
        let copy = space.band(w * h + w)
        let sum = copy + w * h
        copy.update(from: data, count: w * h)
        sum.update(repeating: 0, count: w)
        for k in -r...r { vDSP_vadd(sum, 1, copy + reflect(k) * w, 1, sum, 1, n) }
        var scale = 1 / Float(2 * r + 1)
        for y in 0..<h {
            vDSP_vsmul(sum, 1, &scale, data + y * w, 1, n)
            if y + 1 < h {
                vDSP_vadd(sum, 1, copy + reflect(y + r + 1) * w, 1, sum, 1, n)
                vDSP_vsub(copy + reflect(y - r) * w, 1, sum, 1, sum, 1, n)
            }
        }
    }

    /// 3x3 chamfer distance (OpenCV DIST_L2 mask 3: 0.955 / 1.3693) from each nonzero
    /// pixel to the nearest zero pixel; zero pixels get 0.
    static func chamfer(_ plane: [Float], width w: Int, height h: Int) -> [Float] {
        var d = [Float](repeating: 0, count: w * h)
        plane.withUnsafeBufferPointer { p in
            d.withUnsafeMutableBufferPointer { chamfer(p.baseAddress!, into: $0.baseAddress!, width: w, height: h, inverted: false) }
        }
        return d
    }

    /// Pointer form of `chamfer`; `inverted` measures the zero pixels of `plane` instead.
    /// Each pass takes the minimum over the same candidates as the classic raster scan (min is
    /// exact and order-free; zero pixels stay 0 because every candidate is >= 0), so only the
    /// bounding box of the nonzero pixels is scanned: the previous-row terms vectorise, then one
    /// sequential sweep adds the in-row term.
    static func chamfer(_ plane: UnsafePointer<Float>, into d: UnsafeMutablePointer<Float>, width w: Int, height h: Int,
                        inverted: Bool) {
        let a: Float = 0.955, b: Float = 1.3693, far: Float = 1e6
        var top = h, bottom = -1, left = w, right = -1
        for y in 0..<h {
            let source = plane + y * w, row = d + y * w
            var first = -1, last = -1
            for x in 0..<w {
                let seed = (source[x] > 0) != inverted
                row[x] = seed ? far : 0
                if seed { if first < 0 { first = x }; last = x }
            }
            if first >= 0 {
                top = min(top, y); bottom = y
                left = min(left, first); right = max(right, last)
            }
        }
        guard bottom >= 0 else { return }
        // Columns [left, right] of `row` against the neighbouring row `other` (frame-clipped).
        func vertical(_ row: UnsafeMutablePointer<Float>, _ other: UnsafePointer<Float>) {
            var x = left
            if x == 0 {
                row[0] = min(row[0], other[0] + a)
                if w > 1 { row[0] = min(row[0], other[1] + b) }
                x = 1
            }
            let end = right == w - 1 ? w - 1 : right + 1
            while x < end {
                row[x] = min(min(row[x], other[x] + a), min(other[x - 1] + b, other[x + 1] + b))
                x += 1
            }
            if right == w - 1, w > 1 { row[w - 1] = min(min(row[w - 1], other[w - 1] + a), other[w - 2] + b) }
        }
        for y in top...bottom {
            let row = d + y * w
            if y > 0 { vertical(row, row - w) }
            var x = max(1, left)
            while x <= right { row[x] = min(row[x], row[x - 1] + a); x += 1 }
        }
        for y in stride(from: bottom, through: top, by: -1) {
            let row = d + y * w
            if y + 1 < h { vertical(row, row + w) }
            var x = min(w - 2, right)
            while x >= left { row[x] = min(row[x], row[x + 1] + a); x -= 1 }
        }
    }

    /// Fills pixels whose centre (integer coordinate) lies inside or on the polygon.
    static func fill(_ polygon: [CGPoint], into plane: UnsafeMutablePointer<Float>, width w: Int, height h: Int) {
        let ys = polygon.map(\.y)
        let top = max(0, Int(ceil(ys.min()! - 1e-6))), bottom = min(h - 1, Int(floor(ys.max()! + 1e-6)))
        guard top <= bottom else { return }
        var crossings = [CGFloat]()
        for y in top...bottom {
            let yc = CGFloat(y)
            crossings.removeAll(keepingCapacity: true)
            var lo = CGFloat.infinity, hi = -CGFloat.infinity
            for k in 0..<polygon.count {
                let p = polygon[k], q = polygon[(k + 1) % polygon.count]
                if p.y == q.y {
                    if abs(p.y - yc) < 1e-6 { lo = min(lo, p.x, q.x); hi = max(hi, p.x, q.x) }
                    continue
                }
                let (a, b) = p.y < q.y ? (p, q) : (q, p)
                guard yc >= a.y - 1e-6, yc <= b.y + 1e-6 else { continue }
                let x = a.x + (yc - a.y) * (b.x - a.x) / (b.y - a.y)
                lo = min(lo, x); hi = max(hi, x)
                if yc >= a.y, yc < b.y { crossings.append(x) }
            }
            crossings.sort()
            func span(_ left: CGFloat, _ right: CGFloat) {
                let from = max(0, Int(ceil(left - 1e-6))), to = min(w - 1, Int(floor(right + 1e-6)))
                if from <= to { (plane + y * w + from).update(repeating: 1, count: to - from + 1) }
            }
            var k = 0
            while k + 1 < crossings.count { span(crossings[k], crossings[k + 1]); k += 2 }
            if crossings.count < 2, lo <= hi { span(lo, hi) }
        }
    }

    // MARK: - Geometry and statistics

    static func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    static func area(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for k in 0..<polygon.count {
            let p = polygon[k], q = polygon[(k + 1) % polygon.count]
            sum += p.x * q.y - q.x * p.y
        }
        return abs(sum) / 2
    }

    /// Shorter side of the minimum-area enclosing rectangle (OpenCV `minAreaRect`).
    static func minimumRectSide(_ polygon: [CGPoint]) -> Double {
        let hull = convexHull(polygon)
        guard hull.count >= 3 else { return 0 }
        var best = Double.infinity, side: Double = 0
        for k in 0..<hull.count {
            let p = hull[k], q = hull[(k + 1) % hull.count]
            let length = hypot(Double(q.x - p.x), Double(q.y - p.y))
            guard length > 0 else { continue }
            let ux = Double(q.x - p.x) / length, uy = Double(q.y - p.y) / length
            var minU = Double.infinity, maxU = -Double.infinity, minV = Double.infinity, maxV = -Double.infinity
            for point in hull {
                let dx = Double(point.x - p.x), dy = Double(point.y - p.y)
                let u = dx * ux + dy * uy, v = -dx * uy + dy * ux
                minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
            }
            let a = maxU - minU, b = maxV - minV
            if a * b < best { best = a * b; side = min(a, b) }
        }
        return side
    }

    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower = [CGPoint](), upper = [CGPoint]()
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    static func roundEven(_ value: Double) -> Int { Int(value.rounded(.toNearestOrEven)) }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func median(_ values: [Float]) -> Float {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// NumPy default (linear) percentile of an ascending array.
    static func percentile(sorted s: [Float], _ q: Float) -> Float {
        guard !s.isEmpty else { return 0 }
        let position = Float(s.count - 1) * q / 100
        let lower = Int(position), upper = min(s.count - 1, lower + 1)
        return s[lower] + (s[upper] - s[lower]) * (position - Float(lower))
    }

    static func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}
