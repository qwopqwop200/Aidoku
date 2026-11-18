import Foundation

/// Geometry only. Does not admit/reject OCR content and never consumes a read,
/// confidence, page identity, GT, or recognizer result. Parent owns integration.
/// Frozen rule: gradient24, blank-edge density<=.025, trim>=2px, growth>=1.15.
/// Keep recognition sampling separate from the selected emitted quad.
enum NativeOCRBlankGrowthTrim {
    struct Point: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        static func + (a: Self, b: Self) -> Self { .init(x: a.x + b.x, y: a.y + b.y) }
        static func - (a: Self, b: Self) -> Self { .init(x: a.x - b.x, y: a.y - b.y) }
        static func * (a: Self, b: Double) -> Self { .init(x: a.x * b, y: a.y * b) }
        func dot(_ p: Self) -> Double { x * p.x + y * p.y }
        var length: Double { hypot(x, y) }
    }
    /// Original pixels, top-left origin. BGR/RGB order is interchangeable because
    /// the algorithm takes the maximum gradient over channels; alpha is ignored.
    struct Frame: Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let channels: Int
        let pixels: [UInt8]
    }
    struct Run: Codable, Sendable { let x: Int; let y: Int; let count: Int }
    struct OwnedEvidence: Codable, Sendable {
        let sourceWidth: Int
        let sourceHeight: Int
        let mapFullWidth: Int
        let mapFullHeight: Int
        let completeCCScan: Bool
        let ambiguousCount: Int
        let candidateCount: Int
        /// Exclusive components only. RLE positions already use full-grid
        /// coordinates; NEVER add the detector ROI origin a second time.
        let components: [[Run]]
    }
    struct Measurement: Codable, Sendable {
        let normalGrowth: Double
        let alongGrowth: Double
        let blankDensities: [Double?]
        let coreEdgeDensity: Double
        let trimPixels: [Double]
        let supportNormalBounds: [Double]
        let newNormalBounds: [Double]
        let activeRows: Int
        let scale: Double
    }
    struct Result: Codable, Sendable {
        let polygon: [Point]
        let changed: Bool
        let measurement: Measurement?
    }
    private static func extent(_ a: [Double]) -> Double { (a.max() ?? 0) - (a.min() ?? 0) }
    private static func basis(_ q: [Point]) -> (Point, Point)? {
        guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let a = q[1] - q[0], b = q[3] - q[0]
        guard min(a.length, b.length) >= 3, abs(a.dot(b) / (a.length * b.length)) <= 0.05 else { return nil }
        let v = b.length >= a.length ? b : a, l = v * (1 / v.length)
        return (Point(x: l.y, y: -l.x), l)
    }

    /// Association values come from geometry of ALL raw boxes: best overlap and
    /// second-best overlap. raw must be that best box, not an inferred ancestor.
    /// Returns current unchanged on missing/contested evidence or empty growth
    /// not independently supported by measured source pixels.
    static func trim(frame: Frame, owned: OwnedEvidence, raw: [Point], current: [Point],
                     associationIoU: Double, runnerUpIoU: Double) -> Result {
        let unchanged = Result(polygon: current, changed: false, measurement: nil)
        guard associationIoU.isFinite, runnerUpIoU.isFinite,
              associationIoU >= 0.35, associationIoU - runnerUpIoU >= 0.08,
              let (n, l) = basis(raw), let (_, cl) = basis(current), abs(cl.dot(l)) >= 0.985,
              owned.completeCCScan, owned.ambiguousCount == 0, owned.candidateCount == 0,
              !owned.components.isEmpty, owned.mapFullWidth > 0, owned.mapFullHeight > 0,
              owned.sourceWidth == frame.width, owned.sourceHeight == frame.height,
              frame.width > 0, frame.height > 0, frame.channels >= 3,
              frame.width <= Int.max / frame.channels,
              frame.bytesPerRow >= frame.width * frame.channels,
              frame.height <= Int.max / frame.bytesPerRow,
              frame.pixels.count >= frame.height * frame.bytesPerRow else { return unchanged }
        let rn = raw.map { $0.dot(n) }, rl = raw.map { $0.dot(l) }
        let qn = current.map { $0.dot(n) }, ql = current.map { $0.dot(l) }
        let rw = extent(rn), rh = extent(rl), normal = extent(qn) / rw, along = extent(ql) / rh
        guard rw >= 4, rh >= rw, normal >= 1.15, abs(along - 1) <= 0.20 else { return unchanged }
        let oldMin = qn.min()!, oldMax = qn.max()!, rawMin = rn.min()!, rawMax = rn.max()!
        let lo = min(rawMin, oldMin) - 2, hi = max(rawMax, oldMax) + 2
        let top = min(rl.min()!, ql.min()!) - 2, bottom = max(rl.max()!, ql.max()!) + 2
        let scale = min(1, 320 / max(hi - lo, 1), 4000 / max(bottom - top, 1))
        let w = max(3, Int(ceil((hi - lo) * scale))), h = max(3, Int(ceil((bottom - top) * scale)))
        guard w <= 322, h <= 4002 else { return unchanged }
        let patch = warp(frame, n: n, l: l, lo: lo, top: top, scale: scale, width: w, height: h)
        var owner = [UInt8](repeating: 0, count: w * h)
        let sx = Double(owned.sourceWidth) / Double(owned.mapFullWidth)
        let sy = Double(owned.sourceHeight) / Double(owned.mapFullHeight)
        var runCount = 0
        for component in owned.components {
            for run in component {
                runCount += 1
                guard runCount <= 4096, run.x >= 0, run.y >= 0, run.y < owned.mapFullHeight,
                      run.count > 0, run.x < owned.mapFullWidth,
                      run.count <= owned.mapFullWidth - run.x else { return unchanged }
                let x = Double(run.x) * sx, y = Double(run.y) * sy
                let xx = x + Double(run.count) * sx, yy = y + sy
                let xy = [Point(x: x, y: y), Point(x: xx, y: y), Point(x: xx, y: yy), Point(x: x, y: yy)]
                let uv = xy.map { Point(x: (($0.dot(n) - lo) * scale).rounded(.toNearestOrEven),
                                       y: (($0.dot(l) - top) * scale).rounded(.toNearestOrEven)) }
                fill(uv, mask: &owner, width: w, height: h)
            }
        }
        guard owner.contains(1) else { return unchanged }
        let radius = max(2, Int(ceil(0.08 * rw * scale)))
        let anchor = dilate(owner, width: w, height: h, radius: radius)
        let active = (0..<h).map { y in anchor[(y * w)..<((y + 1) * w)].contains(1) }
        let activeCount = active.filter { $0 }.count
        guard activeCount >= 4 else { return unchanged }
        let edge = edges(patch, width: w, height: h)
        // Flood every edge component touching owned support. Include its entire
        // contour; a connected outline is not lost because its rim is white.
        var supported = [UInt8](repeating: 0, count: w * h), queue = [Int]()
        for i in edge.indices where edge[i] == 1 && anchor[i] == 1 { supported[i] = 1; queue.append(i) }
        guard !queue.isEmpty else { return unchanged }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % w, y = i / w
            for dy in -1...1 {
                let yy = y + dy
                if yy < 0 || yy >= h { continue }
                for dx in -1...1 {
                    let xx = x + dx
                    if xx < 0 || xx >= w { continue }
                    let j = yy * w + xx
                    if edge[j] == 1 && supported[j] == 0 { supported[j] = 1; queue.append(j) }
                }
            }
        }
        var first = w, last = -1
        for y in 0..<h where active[y] {
            for x in 0..<w where supported[y * w + x] == 1 { first = min(first, x); last = max(last, x) }
        }
        guard last >= first else { return unchanged }
        let supportMin = Double(first) / scale + lo, supportMax = Double(last) / scale + lo
        let newMin = max(oldMin, min(rawMin, supportMin - 1 / scale))
        let newMax = min(oldMax, max(rawMax, supportMax + 1 / scale))
        var leftCount = 0, rightCount = 0, coreCount = 0, leftEdge = 0, rightEdge = 0, coreEdge = 0
        for x in 0..<w {
            let c = Double(x) / scale + lo
            let left = c >= oldMin && c < newMin, right = c > newMax && c <= oldMax
            let core = c >= rawMin && c <= rawMax
            if left { leftCount += activeCount }
            if right { rightCount += activeCount }
            if core { coreCount += activeCount }
            if left || right || core {
                for y in 0..<h where active[y] {
                    let value = Int(edge[y * w + x])
                    if left { leftEdge += value }
                    if right { rightEdge += value }
                    if core { coreEdge += value }
                }
            }
        }
        let density: [Double?] = [leftCount == 0 ? nil : Double(leftEdge) / Double(leftCount),
                                 rightCount == 0 ? nil : Double(rightEdge) / Double(rightCount)]
        let coreDensity = coreCount == 0 ? 0 : Double(coreEdge) / Double(coreCount)
        let trimPixels = [newMin - oldMin, oldMax - newMax]
        let measurement = Measurement(normalGrowth: normal, alongGrowth: along, blankDensities: density,
            coreEdgeDensity: coreDensity, trimPixels: trimPixels, supportNormalBounds: [supportMin, supportMax],
            newNormalBounds: [newMin, newMax], activeRows: activeCount, scale: scale)
        guard coreDensity >= 0.015, max(trimPixels[0], trimPixels[1]) >= 2,
              let worst = density.compactMap({ $0 }).max(), worst <= 0.025 else {
            return Result(polygon: current, changed: false, measurement: measurement)
        }
        let polygon = zip(current, qn).map { p, v in p + n * (min(newMax, max(newMin, v)) - v) }
        return Result(polygon: polygon, changed: true, measurement: measurement)
    }

    /// OpenCV INTER_LINEAR's 1/32-pixel interpolation and replicate border.
    private static func warp(_ frame: Frame, n: Point, l: Point, lo: Double, top: Double,
                             scale: Double, width: Int, height: Int) -> [UInt8] {
        let a = Double(Float(n.x * scale)), b = Double(Float(n.y * scale)), c = Double(Float(-lo * scale))
        let d = Double(Float(l.x * scale)), e = Double(Float(l.y * scale)), f = Double(Float(-top * scale))
        let inv = 1 / (a * e - b * d)
        let aa = e * inv, ab = -b * inv, ac = (b * f - e * c) * inv
        let ba = -d * inv, bb = a * inv, bc = (d * c - a * f) * inv
        let adelta = (0..<width).map { Int((aa * Double($0) * 1024).rounded(.toNearestOrEven)) }
        let bdelta = (0..<width).map { Int((ba * Double($0) * 1024).rounded(.toNearestOrEven)) }
        var result = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            let x0 = Int(((ab * Double(y) + ac) * 1024).rounded(.toNearestOrEven)) + 16
            let y0 = Int(((bb * Double(y) + bc) * 1024).rounded(.toNearestOrEven)) + 16
            for x in 0..<width {
                let ix = (x0 + adelta[x]) >> 5, iy = (y0 + bdelta[x]) >> 5
                let sx = ix >> 5, sy = iy >> 5, fx = ix & 31, fy = iy & 31
                let xa = min(frame.width - 1, max(0, sx)), xb = min(frame.width - 1, max(0, sx + 1))
                let ya = min(frame.height - 1, max(0, sy)), yb = min(frame.height - 1, max(0, sy + 1))
                let i00 = ya * frame.bytesPerRow + xa * frame.channels, i10 = ya * frame.bytesPerRow + xb * frame.channels
                let i01 = yb * frame.bytesPerRow + xa * frame.channels, i11 = yb * frame.bytesPerRow + xb * frame.channels
                for ch in 0..<3 {
                    let v = Int(frame.pixels[i00 + ch]) * (32 - fx) * (32 - fy)
                        + Int(frame.pixels[i10 + ch]) * fx * (32 - fy)
                        + Int(frame.pixels[i01 + ch]) * (32 - fx) * fy + Int(frame.pixels[i11 + ch]) * fx * fy
                    result[(y * width + x) * 3 + ch] = UInt8((v + 512) >> 10)
                }
            }
        }
        return result
    }
    private static func fill(_ q: [Point], mask: inout [UInt8], width: Int, height: Int) {
        // Rasterize closed integer polygon edges, then nearest-pixel scanlines.
        for i in 0..<q.count {
            var x = Int(q[i].x), y = Int(q[i].y)
            let end = q[(i + 1) % q.count], xx = Int(end.x), yy = Int(end.y)
            let dx = abs(xx - x), dy = -abs(yy - y), sx = x < xx ? 1 : -1, sy = y < yy ? 1 : -1
            var error = dx + dy
            while true {
                if x >= 0 && x < width && y >= 0 && y < height { mask[y * width + x] = 1 }
                if x == xx && y == yy { break }
                let twice = 2 * error
                if twice >= dy { error += dy; x += sx }
                if twice <= dx { error += dx; y += sy }
            }
        }
        let low = max(0, Int(q.map(\.y).min()!)), high = min(height - 1, Int(q.map(\.y).max()!))
        if high < low { return }
        for y in low...high {
            var intersections = [Double]()
            for i in 0..<q.count {
                let a = q[i], b = q[(i + 1) % q.count]
                if a.y == b.y { continue }
                if Double(y) >= min(a.y, b.y) && Double(y) <= max(a.y, b.y) {
                    intersections.append(a.x + (Double(y) - a.y) * (b.x - a.x) / (b.y - a.y))
                }
            }
            guard let left = intersections.min(), let right = intersections.max() else { continue }
            let x0 = max(0, Int(floor(left + 0.5))), x1 = min(width - 1, Int(floor(right + 0.5)))
            if x1 >= x0 { for x in x0...x1 { mask[y * width + x] = 1 } }
        }
    }
    private static func dilate(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        var horizontal = [UInt8](repeating: 0, count: mask.count), result = horizontal
        for y in 0..<height {
            var count = 0
            for x in 0..<min(width, radius) { count += Int(mask[y * width + x]) }
            for x in 0..<width {
                if x + radius < width { count += Int(mask[y * width + x + radius]) }
                if x - radius - 1 >= 0 { count -= Int(mask[y * width + x - radius - 1]) }
                horizontal[y * width + x] = count > 0 ? 1 : 0
            }
        }
        for x in 0..<width {
            var count = 0
            for y in 0..<min(height, radius) { count += Int(horizontal[y * width + x]) }
            for y in 0..<height {
                if y + radius < height { count += Int(horizontal[(y + radius) * width + x]) }
                if y - radius - 1 >= 0 { count -= Int(horizontal[(y - radius - 1) * width + x]) }
                result[y * width + x] = count > 0 ? 1 : 0
            }
        }
        return result
    }
    private static func edges(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        func reflect(_ v: Int, _ limit: Int) -> Int { v < 0 ? -v : (v >= limit ? 2 * limit - v - 2 : v) }
        var result = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var magnitude: Float = 0
                for ch in 0..<3 {
                    var dx: Float = 0, dy: Float = 0
                    for j in -1...1 {
                        for i in -1...1 {
                            let value = Float(pixels[(reflect(y + j, height) * width + reflect(x + i, width)) * 3 + ch])
                            let weightX = Float(i * (j == 0 ? 2 : 1)), weightY = Float(j * (i == 0 ? 2 : 1))
                            dx += value * weightX; dy += value * weightY
                        }
                    }
                    dx /= 8; dy /= 8
                    magnitude = max(magnitude, (dx * dx + dy * dy).squareRoot())
                }
                result[y * width + x] = magnitude >= 24 ? 1 : 0
            }
        }
        return result
    }
}
