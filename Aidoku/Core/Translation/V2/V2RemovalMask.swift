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

        // Rasterise the line polygons and the dilated ROI.
        var poly = [Float](repeating: 0, count: n)
        for polygon in polygons {
            fill(polygon.map { CGPoint(x: $0.x - CGFloat(x0), y: $0.y - CGFloat(y0)) }, into: &poly, width: w, height: h)
        }
        var roi = poly
        morph(&roi, width: w, height: h, radius: roiRadius, max: true)
        var roiIndices = [Int]()
        roiIndices.reserveCapacity(n / 2)
        for i in 0..<n where roi[i] > 0 { roiIndices.append(i) }
        guard !roiIndices.isEmpty else { return nil }

        // Colour planes.
        var red = [Float](repeating: 0, count: n), green = red, blue = red
        var luma = red, high = red, low = red
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
        var ringMask = roi
        morph(&ringMask, width: w, height: h, radius: 3, max: true)
        var ring = [Int]()
        for i in 0..<n where ringMask[i] > 0 && roi[i] == 0 { ring.append(i) }
        if ring.count < 8 { ring = roiIndices.filter { poly[$0] == 0 } }
        if ring.count < 8 { ring = roiIndices }
        let background = (median(ring.map { red[$0] }), median(ring.map { green[$0] }), median(ring.map { blue[$0] }))
        let backgroundLuma = 0.299 * background.0 + 0.587 * background.1 + 0.114 * background.2
        let ringLuma = ring.map { luma[$0] }.sorted()
        let ringMean = ringLuma.reduce(0, +) / Float(ringLuma.count)
        let ringStd = sqrt(ringLuma.reduce(0) { $0 + ($1 - ringMean) * ($1 - ringMean) } / Float(ringLuma.count))
        let ringLow = percentile(sorted: ringLuma, 10), ringHigh = percentile(sorted: ringLuma, 90)
        let insideLuma = (0..<n).filter { poly[$0] > 0 }.map { luma[$0] }.sorted()
        let inkLuma = insideLuma.isEmpty ? backgroundLuma : percentile(sorted: insideLuma, 10)

        var distance = [Float](repeating: 0, count: n)
        for i in 0..<n {
            distance[i] = max(abs(red[i] - background.0), abs(green[i] - background.1), abs(blue[i] - background.2))
        }
        var dark = [[Float]](), light = [[Float]]()
        for scale in scales {
            var closed = high, opened = low
            morph(&closed, width: w, height: h, radius: scale, max: true)
            morph(&closed, width: w, height: h, radius: scale, max: false)
            morph(&opened, width: w, height: h, radius: scale, max: false)
            morph(&opened, width: w, height: h, radius: scale, max: true)
            for i in 0..<n { closed[i] -= low[i]; opened[i] = high[i] - opened[i] }
            dark.append(closed); light.append(opened)
        }
        var darkNear = dark[1], lightNear = light[1], distanceNear = distance
        morph(&darkNear, width: w, height: h, radius: 2, max: true)
        morph(&lightNear, width: w, height: h, radius: 2, max: true)
        morph(&distanceNear, width: w, height: h, radius: 2, max: true)
        var lumaSquare = luma
        for i in 0..<n { lumaSquare[i] *= luma[i] }
        let lumaMean = boxBlur(luma, width: w, height: h, radius: 2)
        let lumaSquareMean = boxBlur(lumaSquare, width: w, height: h, radius: 2)
        var inverse = poly
        for i in 0..<n { inverse[i] = poly[i] > 0 ? 0 : 1 }
        let inside = chamfer(poly, width: w, height: h), outside = chamfer(inverse, width: w, height: h)
        let logThickness = Float(log(thickness) / 5)

        // Stroke-width-normalised features: stroke width from the distance transform of
        // high-contrast pixels inside the line polygons, then black-hat / top-hat at 1 and
        // 2.5 stroke widths so very thick lettering is not out of distribution.
        var ink = [Float](repeating: 0, count: n)
        var inkCount = 0
        for i in 0..<n where poly[i] > 0 && distance[i] >= 0.25 { ink[i] = 1; inkCount += 1 }
        let inkDepth: [Float]
        let stroke: Float
        if inkCount >= 4 {
            inkDepth = chamfer(ink, width: w, height: h)
            let depths = (0..<n).filter { ink[$0] > 0 }.map { inkDepth[$0] }.sorted()
            stroke = min(Float(thickness), max(1, 2 * percentile(sorted: depths, 90)))
        } else {
            inkDepth = [Float](repeating: 0, count: n)
            stroke = max(1, Float(0.1 * thickness))
        }
        var notInk = ink
        for i in 0..<n { notInk[i] = 1 - ink[i] }
        let inkGap = chamfer(notInk, width: w, height: h)
        var strokeDark = [[Float]](), strokeLight = [[Float]]()
        for scale in [max(1, roundEven(Double(stroke))), max(2, roundEven(2.5 * Double(stroke)))] {
            var closed = high, opened = low
            morph(&closed, width: w, height: h, radius: scale, max: true)
            morph(&closed, width: w, height: h, radius: scale, max: false)
            morph(&opened, width: w, height: h, radius: scale, max: false)
            morph(&opened, width: w, height: h, radius: scale, max: true)
            for i in 0..<n { closed[i] -= low[i]; opened[i] = high[i] - opened[i] }
            strokeDark.append(closed); strokeLight.append(opened)
        }
        let invStroke = 1 / stroke, logStroke = log(stroke / Float(thickness))

        let f1 = stage1.features
        precondition(f1 == 29)
        let rows = roiIndices.count
        // Feature-major (one contiguous plane of `rows` values per feature); stage 2 appends to it.
        var features = [Float](repeating: 0, count: rows * stage2.features)
        let invThickness = 1 / Float(max(thickness, 1))
        features.withUnsafeMutableBufferPointer { fp in
            let x = fp.baseAddress!
            for (row, i) in roiIndices.enumerated() {
                x[row] = luma[i]; x[rows + row] = high[i] - low[i]; x[2 * rows + row] = distance[i]
                x[3 * rows + row] = luma[i] - backgroundLuma
                x[4 * rows + row] = dark[0][i]; x[5 * rows + row] = light[0][i]
                x[6 * rows + row] = dark[1][i]; x[7 * rows + row] = light[1][i]
                x[8 * rows + row] = dark[2][i]; x[9 * rows + row] = light[2][i]
                x[10 * rows + row] = darkNear[i]; x[11 * rows + row] = lightNear[i]; x[12 * rows + row] = distanceNear[i]
                x[13 * rows + row] = sqrt(max(lumaSquareMean[i] - lumaMean[i] * lumaMean[i], 0))
                x[14 * rows + row] = min(1, max(-1, (outside[i] - inside[i]) * invThickness))
                x[15 * rows + row] = backgroundLuma; x[16 * rows + row] = ringStd; x[17 * rows + row] = inkLuma
                x[18 * rows + row] = logThickness; x[19 * rows + row] = abs(luma[i] - inkLuma)
                x[20 * rows + row] = ringLow; x[21 * rows + row] = ringHigh
                x[22 * rows + row] = strokeDark[0][i]; x[23 * rows + row] = strokeLight[0][i]
                x[24 * rows + row] = strokeDark[1][i]; x[25 * rows + row] = strokeLight[1][i]
                x[26 * rows + row] = min(2, max(0, inkDepth[i] * invStroke))
                x[27 * rows + row] = min(3, max(0, inkGap[i] * invStroke))
                x[28 * rows + row] = logStroke
            }
        }
        let p1Values = mlp(features, rows: rows, network: stage1)
        var p1 = [Float](repeating: 0, count: n)
        for (row, i) in roiIndices.enumerated() { p1[i] = p1Values[row] }

        // Auto-context neighbourhood of the stage-1 probability.
        var context = [[Float]]()
        for radius in [1, 2, 4] {
            var plane = p1
            morph(&plane, width: w, height: h, radius: radius, max: true)
            context.append(plane)
        }
        var eroded = p1
        morph(&eroded, width: w, height: h, radius: 1, max: false)
        context.append(eroded)
        context.append(boxBlur(p1, width: w, height: h, radius: 2))
        context.append(boxBlur(p1, width: w, height: h, radius: blurHalf))
        context.append(boxBlur(p1, width: w, height: h, radius: 2 * blurHalf))
        var closedP = p1
        let closeRadius = max(2, roundEven(0.06 * thickness))
        morph(&closedP, width: w, height: h, radius: closeRadius, max: true)
        morph(&closedP, width: w, height: h, radius: closeRadius, max: false)
        context.append(closedP)
        var spread = p1
        morph(&spread, width: w, height: h, radius: max(4, roundEven(0.15 * thickness)), max: true)
        context.append(spread)

        let f2 = stage2.features
        precondition(f2 == f1 + 1 + context.count)
        features.withUnsafeMutableBufferPointer { fp in
            let x = fp.baseAddress! + f1 * rows
            for (row, i) in roiIndices.enumerated() { x[row] = p1[i] }
            for (k, plane) in context.enumerated() {
                let target = x + (k + 1) * rows
                for (row, i) in roiIndices.enumerated() { target[row] = plane[i] }
            }
        }
        let p2 = mlp(features, rows: rows, network: stage2)
        let cut = thickness >= largeThickness ? largeThreshold : threshold
        var out = [Float](repeating: 0, count: n)
        for (row, i) in roiIndices.enumerated() where p2[row] >= cut { out[i] = 1 }
        morph(&out, width: w, height: h, radius: outputDilation, max: true)
        return BlockMask(frame: frame, mask: out.map { $0 > 0 ? 1 : 0 })
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
        let features = net.features, hidden = net.hidden
        precondition(input.count >= rows * features)
        var output = [Float](repeating: 0, count: rows)
        let chunk = min(rows, 16_384)
        guard chunk > 0 else { return output }
        var x = [Float](repeating: 0, count: chunk * features)
        var layer1 = [Float](repeating: 0, count: chunk * hidden), layer2 = layer1
        var zero: Float = 0
        var start = 0
        while start < rows {
            let count = min(chunk, rows - start), n = vDSP_Length(count)
            input.withUnsafeBufferPointer { ip in
                x.withUnsafeMutableBufferPointer { xp in
                    for f in 0..<features {
                        (xp.baseAddress! + f * count).update(from: ip.baseAddress! + f * rows + start, count: count)
                    }
                }
            }
            // layer = W[hidden x in] * X[in x count]; bias and ReLU per hidden row.
            vDSP_mmul(net.w1, 1, x, 1, &layer1, 1, vDSP_Length(hidden), n, vDSP_Length(features))
            layer1.withUnsafeMutableBufferPointer { lp in
                for j in 0..<hidden {
                    var bias = net.b1[j]
                    let row = lp.baseAddress! + j * count
                    vDSP_vsadd(row, 1, &bias, row, 1, n)
                    vDSP_vthres(row, 1, &zero, row, 1, n)
                }
            }
            vDSP_mmul(net.w2, 1, layer1, 1, &layer2, 1, vDSP_Length(hidden), n, vDSP_Length(hidden))
            layer2.withUnsafeMutableBufferPointer { lp in
                for j in 0..<hidden {
                    var bias = net.b2[j]
                    let row = lp.baseAddress! + j * count
                    vDSP_vsadd(row, 1, &bias, row, 1, n)
                    vDSP_vthres(row, 1, &zero, row, 1, n)
                }
            }
            output.withUnsafeMutableBufferPointer { op in
                let o = op.baseAddress! + start
                vDSP_mmul(net.w3, 1, layer2, 1, o, 1, 1, n, vDSP_Length(hidden))
                // sigmoid(z + b3) = 1 / (1 + exp(-(z + b3)))
                var negBias = -net.b3, minusOne: Float = -1, one: Float = 1
                vDSP_vsmsa(o, 1, &minusOne, &negBias, o, 1, n)
                var length = Int32(count)
                vvexpf(o, o, &length)
                vDSP_vsadd(o, 1, &one, o, 1, n)
                vvrecf(o, o, &length)
            }
            start += count
        }
        return output
    }

    // MARK: - Image primitives

    /// Square (2r+1) max/min filter, separable (van Herk / Gil-Werman over whole rows with
    /// vDSP, O(1) per pixel); samples outside the frame are ignored.
    static func morph(_ plane: inout [Float], width w: Int, height h: Int, radius r: Int, max isMax: Bool) {
        guard r > 0, w > 0, h > 0 else { return }
        var scratch = [Float](repeating: 0, count: w * h)
        plane.withUnsafeMutableBufferPointer { p in
            scratch.withUnsafeMutableBufferPointer { t in
                filterColumns(p.baseAddress!, width: w, height: h, radius: r, max: isMax)
                vDSP_mtrans(p.baseAddress!, 1, t.baseAddress!, 1, vDSP_Length(w), vDSP_Length(h))
                filterColumns(t.baseAddress!, width: h, height: w, radius: r, max: isMax)
                vDSP_mtrans(t.baseAddress!, 1, p.baseAddress!, 1, vDSP_Length(h), vDSP_Length(w))
            }
        }
    }

    /// Vertical running max/min of window 2r+1 applied in place to every column.
    private static func filterColumns(_ data: UnsafeMutablePointer<Float>, width w: Int, height h: Int, radius r: Int,
                                      max isMax: Bool) {
        let k = 2 * r + 1, length = (h + 2 * r + k - 1) / k * k, n = vDSP_Length(w)
        let prefix = UnsafeMutablePointer<Float>.allocate(capacity: length * w)
        let suffix = UnsafeMutablePointer<Float>.allocate(capacity: length * w)
        defer { prefix.deallocate(); suffix.deallocate() }
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
        var scratch = [Float](repeating: 0, count: w * h)
        output.withUnsafeMutableBufferPointer { p in
            scratch.withUnsafeMutableBufferPointer { t in
                blurColumns(p.baseAddress!, width: w, height: h, radius: r)
                vDSP_mtrans(p.baseAddress!, 1, t.baseAddress!, 1, vDSP_Length(w), vDSP_Length(h))
                blurColumns(t.baseAddress!, width: h, height: w, radius: r)
                vDSP_mtrans(t.baseAddress!, 1, p.baseAddress!, 1, vDSP_Length(h), vDSP_Length(w))
            }
        }
        return output
    }

    /// Vertical running mean of window 2r+1 (reflect-101) applied in place to every column.
    private static func blurColumns(_ data: UnsafeMutablePointer<Float>, width w: Int, height h: Int, radius r: Int) {
        func reflect(_ i: Int) -> Int {
            guard h > 1 else { return 0 }
            var j = i
            while j < 0 || j >= h { j = j < 0 ? -j : 2 * (h - 1) - j }
            return j
        }
        let n = vDSP_Length(w)
        let copy = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        let sum = UnsafeMutablePointer<Float>.allocate(capacity: w)
        defer { copy.deallocate(); sum.deallocate() }
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
        let a: Float = 0.955, b: Float = 1.3693, far: Float = 1e6
        var d = plane.map { $0 > 0 ? far : 0 }
        for y in 0..<h {
            for x in 0..<w where d[y * w + x] > 0 {
                var v = d[y * w + x]
                if x > 0 { v = min(v, d[y * w + x - 1] + a) }
                if y > 0 {
                    v = min(v, d[(y - 1) * w + x] + a)
                    if x > 0 { v = min(v, d[(y - 1) * w + x - 1] + b) }
                    if x + 1 < w { v = min(v, d[(y - 1) * w + x + 1] + b) }
                }
                d[y * w + x] = v
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) where d[y * w + x] > 0 {
                var v = d[y * w + x]
                if x + 1 < w { v = min(v, d[y * w + x + 1] + a) }
                if y + 1 < h {
                    v = min(v, d[(y + 1) * w + x] + a)
                    if x + 1 < w { v = min(v, d[(y + 1) * w + x + 1] + b) }
                    if x > 0 { v = min(v, d[(y + 1) * w + x - 1] + b) }
                }
                d[y * w + x] = v
            }
        }
        return d
    }

    /// Fills pixels whose centre (integer coordinate) lies inside or on the polygon.
    static func fill(_ polygon: [CGPoint], into plane: inout [Float], width w: Int, height h: Int) {
        let ys = polygon.map(\.y)
        let top = max(0, Int(ceil(ys.min()! - 1e-6))), bottom = min(h - 1, Int(floor(ys.max()! + 1e-6)))
        guard top <= bottom else { return }
        for y in top...bottom {
            let yc = CGFloat(y)
            var crossings = [CGFloat]()
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
            var spans = [(CGFloat, CGFloat)]()
            var k = 0
            while k + 1 < crossings.count { spans.append((crossings[k], crossings[k + 1])); k += 2 }
            if spans.isEmpty, lo <= hi { spans.append((lo, hi)) }
            for (left, right) in spans {
                let from = max(0, Int(ceil(left - 1e-6))), to = min(w - 1, Int(floor(right + 1e-6)))
                if from <= to { for x in from...to { plane[y * w + x] = 1 } }
            }
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
