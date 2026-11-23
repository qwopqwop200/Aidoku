import Accelerate
import CoreGraphics
@preconcurrency import CoreML
import Foundation
import os

/// S6: page-size 0/255 source-text removal mask, recall first. Per block (T = median line thickness), a
/// compact U-Net (`V2MaskNet`, fit on train GT glyph masks) sees the block frame scale-normalized by T;
/// its glyph probability, thresholded low inside the ROI (dilated line polygons plus line ends), is
/// dilated 2 px.
enum V2RemovalMask {
    static let roiScale = 0.3
    static let roiMinimum = 8
    /// Line boxes grown along their axis by this many thicknesses are also searched (detection often
    /// stops short of a column's last glyph).
    static let lineEndExtension = 0.5
    /// Glyph probability cut (fit by 3-fold CV on the train folds).
    static let threshold: Float = 0.15
    static let outputDilation = 2
    static let gateScale = 0.25
    static let maximumThickness: Double = 400

    /// Without `net` (the model failed to load) every block erases its dilated line polygons.
    static func build(_ page: V2Page, blocks: [V2Block], layout: [V2LayoutRegion],
                      net: V2MaskNet? = V2MaskNet.bundled) -> [UInt8] {
        let width = page.width, height = page.height
        guard width > 0, height > 0 else { return [] }
        // Beyond the shared raster limit nothing is erased (a multi-GB RGBA copy).
        guard width * height <= maximumPagePixels, let rgba = rgbaBytes(page.image) else {
            return [UInt8](repeating: 0, count: width * height)
        }
        return build(rgba: rgba, width: width, height: height, blocks: blocks, layout: layout, net: net)
    }

    /// Largest page (pixels) converted to RGBA for the mask (same as `V2PageRaster`'s 16384 x 16384).
    static let maximumPagePixels = 16_384 * 16_384

    /// `build(_:blocks:layout:)` from RGBA8 bytes (alpha ignored).
    static func build(rgba: [UInt8], width: Int, height: Int, blocks: [V2Block], layout: [V2LayoutRegion],
                      net: V2MaskNet? = V2MaskNet.bundled) -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        var mask = [UInt8](repeating: 0, count: width * height)
        guard rgba.count >= width * height * 4 else { return mask }
        let targets = blocks.filter { $0.role != .background }
        guard !targets.isEmpty else { return mask }
        let geometries = targets.map { geometry($0, width: width, height: height) }
        var results = [BlockMask?](repeating: nil, count: targets.count)
        // Peak memory scales with the frame pixels in flight: large blocks run in batches of at most
        // `concurrentBlockPixels` (one at a time when larger).
        let threads = max(1, ProcessInfo.processInfo.activeProcessorCount)
        // Largest first: a page waits for its slowest block, so it should not start last.
        let small = geometries.indices.filter { (geometries[$0]?.frame.pixels ?? 0) <= concurrentBlockPixels / threads }
            .sorted { (geometries[$0]?.frame.pixels ?? 0) > (geometries[$1]?.frame.pixels ?? 0) }
        let large = geometries.indices.filter { (geometries[$0]?.frame.pixels ?? 0) > concurrentBlockPixels / threads }
        rgba.withUnsafeBufferPointer { pixels in
            results.withUnsafeMutableBufferPointer { out in
                let base = out.baseAddress!
                DispatchQueue.concurrentPerform(iterations: small.count) { k in
                    let index = small[k]
                    base[index] = geometries[index].flatMap { segment($0, net: net, pixels: pixels, width: width, height: height) }
                }
                // On iOS a batch never exceeds the largest classifier block.
#if os(iOS)
                let batchPixels = large.compactMap { geometries[$0]?.frame.pixels }.filter { $0 <= maximumBlockPixels }.max() ?? 0
#else
                let batchPixels = concurrentBlockPixels
#endif
                var start = 0
                while start < large.count {
                    let first = start
                    var end = start + 1, total = geometries[large[start]]?.frame.pixels ?? 0
                    while end < large.count, total + (geometries[large[end]]?.frame.pixels ?? 0) <= batchPixels {
                        total += geometries[large[end]]?.frame.pixels ?? 0
                        end += 1
                    }
                    DispatchQueue.concurrentPerform(iterations: end - first) { k in
                        let index = large[first + k]
                        base[index] = geometries[index].flatMap { segment($0, net: net, pixels: pixels, width: width, height: height) }
                    }
                    start = end
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

    /// Frame pixels of all blocks segmented concurrently (about `bytesPerFramePixel` each).
    static let concurrentBlockPixels = 3_000_000
    /// Larger frames erase their dilated line polygons without the classifier.
    static let maximumBlockPixels = 3_000_000
    /// Classifier working memory per frame pixel (ROI planes, background channels, mask), rounded up.
    static let bytesPerFramePixel = 64
    /// Polygon coordinates beyond this magnitude are treated as invalid (no page is that large).
    static let maximumCoordinate: CGFloat = 1_000_000

    // MARK: - Per block

    struct Frame: Equatable {
        var x: Int, y: Int, width: Int, height: Int
        var pixels: Int { width * height }
    }

    /// Per-block sizes derived from the line polygons; `frame` is the padded page crop.
    struct Geometry {
        let polygons: [[CGPoint]]
        let thickness: Double
        let roiRadius: Int
        let frame: Frame
        var lineEnds: [[CGPoint]] = []
    }

    struct BlockMask {
        let frame: Frame
        let mask: [UInt8]
    }

    static func linePolygons(_ block: V2Block) -> [[CGPoint]] {
        var polygons = block.lines.map { line -> [CGPoint] in
            line.polygon.count >= 3 ? line.polygon : corners(line.bounds)
        }.filter { polygon in polygon.allSatisfy(isUsable) && area(polygon) > 0 }
        if polygons.isEmpty {
            let fallback = block.polygon.count >= 3 ? block.polygon : corners(block.bounds)
            if fallback.allSatisfy(isUsable), area(fallback) > 0 { polygons = [fallback] }
        }
        return polygons
    }

    /// Finite and small enough that frame and raster arithmetic cannot overflow `Int`.
    static func isUsable(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && abs(point.x) <= maximumCoordinate && abs(point.y) <= maximumCoordinate
    }

    static func geometry(_ block: V2Block, width: Int, height: Int) -> Geometry? {
        let polygons = linePolygons(block)
        guard !polygons.isEmpty else { return nil }
        let thickness = min(maximumThickness, max(1, median(polygons.map(minimumRectSide))))
        let roiRadius = max(roiMinimum, roundEven(roiScale * thickness))
        // Context beyond the ROI: about 0.6 T (the frame the classifier was fit on).
        let context = max(4, roundEven(0.6 * thickness), 2 * max(3, roundEven(0.25 * thickness) | 1), outputDilation)
        let pad = roiRadius + context + 4
        let along = CGFloat(lineEndExtension * thickness)
        let lineEnds = block.lines.map { line in
            corners(line.vertical ? line.bounds.insetBy(dx: 0, dy: -along) : line.bounds.insetBy(dx: -along, dy: 0))
        }.filter { $0.allSatisfy(isUsable) }
        guard let frame = paddedFrame(polygons + lineEnds, pad: pad, width: width, height: height) else { return nil }
        return Geometry(polygons: polygons, thickness: thickness, roiRadius: roiRadius, frame: frame, lineEnds: lineEnds)
    }

    /// Bounding box of `polygons` grown by `pad` (plus one on the far side), clipped to the page.
    static func paddedFrame(_ polygons: [[CGPoint]], pad: Int, width: Int, height: Int) -> Frame? {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for point in polygons.joined() {
            minX = min(minX, point.x); minY = min(minY, point.y); maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        let x0 = max(0, Int(floor(minX)) - pad), y0 = max(0, Int(floor(minY)) - pad)
        let x1 = min(width, Int(ceil(maxX)) + pad + 1), y1 = min(height, Int(ceil(maxY)) + pad + 1)
        guard x1 > x0, y1 > y0 else { return nil }
        return Frame(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Conv classifier: the frame box-downscaled by `V2MaskNet.factor(T)` (edges replicated to a multiple of the
    /// factor, then of `V2MaskNet.align`), the probability bilinearly upsampled, thresholded inside the ROI, dilated.
    static func segment(_ geometry: Geometry, net: V2MaskNet?, pixels: UnsafeBufferPointer<UInt8>, width: Int,
                        height: Int) -> BlockMask? {
        let frame = geometry.frame
        guard let net, frame.pixels <= maximumBlockPixels else {
            return polygonMask(geometry.polygons, width: width, height: height)
        }
#if os(iOS)
        // The classifier must leave half the remaining app memory free.
        let available = os_proc_available_memory()
        if available > 0, frame.pixels * bytesPerFramePixel > available / 2 {
            return polygonMask(geometry.polygons, width: width, height: height)
        }
#endif
        let regions = regions(geometry)
        guard regions.roi.contains(1) else { return nil }
        let bg = background(regions, frame: frame, pixels: pixels, width: width)
        let w = frame.width, h = frame.height, k = V2MaskNet.factor(geometry.thickness)
        let pw = (w + k - 1) / k, ph = (h + k - 1) / k
        let aw = (pw + V2MaskNet.align - 1) / V2MaskNet.align * V2MaskNet.align
        let ah = (ph + V2MaskNet.align - 1) / V2MaskNet.align * V2MaskNet.align
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: V2MaskNet.channels), NSNumber(value: ah),
                                                    NSNumber(value: aw)], dataType: .float32) else { return nil }
        let planeStride = input.strides[1].intValue, rowStride = input.strides[2].intValue
        do {
            // `dataPointer`: `withUnsafeMutableBufferPointer(ofType:)` needs iOS 15.4.
            let out = input.dataPointer.assumingMemoryBound(to: Float.self)
            var sums = [Float](repeating: 0, count: V2MaskNet.channels)
            let scale = 1 / Float(k * k)
            for py in 0..<ph {
                for px in 0..<pw {
                    for c in 0..<sums.count { sums[c] = 0 }
                    for dy in 0..<k {
                        let y = min(py * k + dy, h - 1)
                        for dx in 0..<k {
                            let x = min(px * k + dx, w - 1)
                            let s = ((frame.y + y) * width + frame.x + x) * 4
                            let r = Float(pixels[s]) / 255, g = Float(pixels[s + 1]) / 255, b = Float(pixels[s + 2]) / 255
                            sums[0] += r; sums[1] += g; sums[2] += b
                            sums[3] += max(abs(r - bg.0), abs(g - bg.1), abs(b - bg.2))
                            sums[4] += Float(regions.poly[y * w + x]); sums[5] += Float(regions.roi[y * w + x])
                        }
                    }
                    for c in 0..<sums.count { out[c * planeStride + py * rowStride + px] = sums[c] * scale }
                }
                // Edge replication to the aligned width.
                for c in 0..<V2MaskNet.channels {
                    let row = out + c * planeStride + py * rowStride
                    for px in pw..<aw { row[px] = row[pw - 1] }
                }
            }
            for c in 0..<V2MaskNet.channels {
                for py in ph..<ah {
                    (out + c * planeStride + py * rowStride).update(from: out + c * planeStride + (ph - 1) * rowStride, count: aw)
                }
            }
        }
        guard let coarse = try? net.predict(input, height: ah, width: aw) else {
            return polygonMask(geometry.polygons, width: width, height: height)
        }
        // Bilinear: fine x samples coarse (x + 0.5) / k - 0.5, clamped to the pooled (unpadded) extent.
        func axis(_ n: Int, _ m: Int) -> [(Int, Int, Float)] {
            (0..<n).map { i in
                let c = min(max((Float(i) + 0.5) / Float(k) - 0.5, 0), Float(m - 1))
                let i0 = Int(c.rounded(.down))
                return (i0, min(i0 + 1, m - 1), c - Float(i0))
            }
        }
        let ys = axis(h, ph), xs = axis(w, pw)
        var mask = [UInt8](repeating: 0, count: frame.pixels)
        for y in 0..<h {
            let (y0, y1, fy) = ys[y]
            for x in 0..<w where regions.gate[y * w + x] != 0 {
                let (x0, x1, fx) = xs[x]
                let top = coarse[y0 * aw + x0] * (1 - fx) + coarse[y0 * aw + x1] * fx
                let bottom = coarse[y1 * aw + x0] * (1 - fx) + coarse[y1 * aw + x1] * fx
                if top * (1 - fy) + bottom * fy >= threshold { mask[y * w + x] = 1 }
            }
        }
        dilate(&mask, width: w, height: h, radius: outputDilation)
        return BlockMask(frame: frame, mask: mask)
    }

    /// Frame-size 0/1 line polygons, classifier ROI (polygons dilated by `roiRadius`, plus the line ends) and
    /// output gate (the ROI dilated by `gateScale` T: the classifier may also erase glyph parts just past the ROI).
    struct Regions {
        let poly: [UInt8]
        let roi: [UInt8]
        let gate: [UInt8]
    }

    static func regions(_ geometry: Geometry) -> Regions {
        let frame = geometry.frame, w = frame.width, h = frame.height
        let space = Workspace(width: w, height: h)
        let poly = space.plane(zero: true)
        for polygon in geometry.polygons {
            fill(polygon.map { CGPoint(x: $0.x - CGFloat(frame.x), y: $0.y - CGFloat(frame.y)) }, into: poly, width: w, height: h)
        }
        let roi = space.copy(poly)
        morph(roi, width: w, height: h, radius: geometry.roiRadius, max: true, space: space)
        for end in geometry.lineEnds {
            fill(end.map { CGPoint(x: $0.x - CGFloat(frame.x), y: $0.y - CGFloat(frame.y)) }, into: roi, width: w, height: h)
        }
        let n = frame.pixels
        let gate = space.copy(roi)
        morph(gate, width: w, height: h, radius: roundEven(gateScale * geometry.thickness), max: true, space: space)
        return Regions(poly: (0..<n).map { poly[$0] > 0 ? 1 : 0 }, roi: (0..<n).map { roi[$0] > 0 ? 1 : 0 },
                       gate: (0..<n).map { gate[$0] > 0 ? 1 : 0 })
    }

    /// Block background (0-1 RGB): per-channel median of the 3 px ring around the ROI (else ROI minus polygons, else ROI).
    static func background(_ regions: Regions, frame: Frame, pixels: UnsafeBufferPointer<UInt8>, width: Int) -> (Float, Float, Float) {
        let w = frame.width, h = frame.height
        var grown = regions.roi
        dilate(&grown, width: w, height: h, radius: 3)
        var ring = [Int]()
        for i in 0..<frame.pixels where grown[i] != 0 && regions.roi[i] == 0 { ring.append(i) }
        if ring.count < 8 { ring = (0..<frame.pixels).filter { regions.roi[$0] != 0 && regions.poly[$0] == 0 } }
        if ring.count < 8 { ring = (0..<frame.pixels).filter { regions.roi[$0] != 0 } }
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frame.pixels), count: 3)
        for y in 0..<h {
            let source = ((frame.y + y) * width + frame.x) * 4
            for x in 0..<w {
                for c in 0..<3 { channels[c][y * w + x] = Float(pixels[source + 4 * x + c]) / 255 }
            }
        }
        let m = channels.map { plane in plane.withUnsafeBufferPointer { orderMedian($0.baseAddress!, at: ring) } }
        return (m[0], m[1], m[2])
    }

    /// Fallback above `maximumBlockPixels` (or without the model): the line polygons dilated by `outputDilation`.
    static func polygonMask(_ polygons: [[CGPoint]], width: Int, height: Int) -> BlockMask? {
        guard let frame = paddedFrame(polygons, pad: outputDilation + 1, width: width, height: height) else { return nil }
        let w = frame.width, h = frame.height, n = frame.pixels
        // Filled straight into the 0/1 byte mask (no float plane for these large frames).
        var mask = [UInt8](repeating: 0, count: n)
        mask.withUnsafeMutableBufferPointer { plane in
            for polygon in polygons {
                fill(polygon.map { CGPoint(x: $0.x - CGFloat(frame.x), y: $0.y - CGFloat(frame.y)) }, into: plane.baseAddress!,
                     width: w, height: h)
            }
        }
        dilate(&mask, width: w, height: h, radius: outputDilation)
        return BlockMask(frame: frame, mask: mask)
    }

    /// Square (2r+1) binary dilation of a 0/1 byte plane (samples outside the frame ignored).
    static func dilate(_ mask: inout [UInt8], width w: Int, height h: Int, radius r: Int) {
        guard r > 0, w > 0, h > 0 else { return }
        var horizontal = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where mask[row + x] != 0 {
                for xx in max(0, x - r)...min(w - 1, x + r) { horizontal[row + xx] = 1 }
            }
        }
        for i in 0..<(w * h) { mask[i] = 0 }
        for y in 0..<h {
            for x in 0..<w where horizontal[y * w + x] != 0 {
                for yy in max(0, y - r)...min(h - 1, y + r) { mask[yy * w + x] = 1 }
            }
        }
    }

    /// Recycled float planes and morphology/blur scratch for one block.
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

    /// Gathered values; `orderMedian` / `orderPercentile` are exact order statistics of them by selection.
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

    // MARK: - Image primitives

    /// Square (2r+1) max/min filter (separable van Herk / Gil-Werman); outside samples are ignored.
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

    /// Fills pixels whose centre (integer coordinate) lies inside or on the polygon.
    static func fill<T: Numeric>(_ polygon: [CGPoint], into plane: UnsafeMutablePointer<T>, width w: Int, height h: Int) {
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
