import Foundation

/// Base126 source-boundary ABI. Raw detector quad + physical RGBA + DB/RF only.
/// No OCR, corrected baselines, page identifiers, model loading or inference.
@available(iOS 18.0, *)
enum NativeOCRRawBoundaryFeatures {
    static let abi = "raw-source-boundary-base126-cv2-linear32-u8-f32-v1"
    struct Run: Codable, Sendable { let x: Int; let y: Int; let count: Int }
    struct Component: Codable, Sendable { let meanProbability: Double; let runs: [Run] }
    /// Numeric projection of the actual raw detectorSeedEvidence, not inferred ownership.
    struct DBEvidence: Codable, Sendable {
        let sourceWidth: Int; let sourceHeight: Int
        let mapFullWidth: Int; let mapFullHeight: Int
        let components: [Component]
        let ownershipVersion: Int?; let completeCCScan: Bool?
        let ambiguousComponents: [Component]?
        // Only the number is used; accept native candidate objects without their owner metadata.
        let candidateComponents: [Candidate]?
        struct Candidate: Codable, Sendable { let component: Component }
    }
    struct Bounds: Codable, Sendable { let x: Double; let y: Double; let width: Double; let height: Double }
    /// Class is the producer's primitive wire class 0...3, never an enum remapping.
    struct RFPrimitive: Codable, Sendable {
        let classID: Int; let confidence: Double; let sourceBounds: Bounds
        enum CodingKeys: String, CodingKey { case classID = "class", confidence, sourceBounds }
    }
    struct Output: Sendable {
        /// np.nan_to_num(np.array(values, float32)) semantics; exactly FEATURE-NAMES order.
        let features: [Float]
        let pixelAvailable: Bool
    }
    static let names: [String] = {
        var result = ["boundaryLogWidth", "boundaryLogHeight", "boundaryLogAspect", "boundaryAxisSin2",
                      "boundaryAxisCos2", "boundaryValidContext", "boundaryBackgroundDispersion", "boundaryInteriorGradient"]
        for threshold in [16, 32, 48] {
            for axis in ["U", "V"] {
                for q in ["0.01", "0.05", "0.1", "0.5", "0.9", "0.95", "0.99"] {
                    result.append("boundaryContrast\(threshold)\(axis)Q\(q)")
                }
            }
            result += ["Inside", "Left", "Right", "Top", "Bottom"].map { "boundaryContrast\(threshold)\($0)" }
        }
        result += ["pixelFeaturesAvailable", "dbAvailable", "dbCompleteV2", "dbOwnedComponentsLog",
                   "dbAmbiguousComponentsLog", "dbCandidateComponentsLog", "dbCellCountLog", "dbMeanProbability",
                   "dbMinProbability", "dbCellNormalScale", "dbCellAlongScale"]
        for axis in ["U", "V"] {
            result += ["0", "0.1", "0.5", "0.9", "1"].map { "db\(axis)Q\($0)" }
        }
        for cl in 0..<4 {
            result += ["Available", "MaxConfidence", "IntersectCountLog", "CandidateCoverage", "ReferenceCoverage",
                       "Left", "Right", "Top", "Bottom", "Confidence"].map { "rf\(cl)\($0)" }
        }
        return result
    }()
    private struct Axes {
        let ux: Double; let uy: Double; let vx: Double; let vy: Double
        let w: Double; let h: Double; let cx: Double; let cy: Double
    }
    private static func axes(_ q: [[Double]]) -> Axes? {
        guard q.count == 4, q.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let ux = q[1][0] - q[0][0], uy = q[1][1] - q[0][1]
        let vx = q[3][0] - q[0][0], vy = q[3][1] - q[0][1]
        let w = max(1e-6, hypot(ux, uy)), h = max(1e-6, hypot(vx, vy))
        guard w.isFinite, h.isFinite else { return nil }
        return Axes(ux: ux / w, uy: uy / w, vx: vx / h, vy: vy / h, w: w, h: h,
                    cx: q.reduce(0) { $0 + $1[0] } / 4, cy: q.reduce(0) { $0 + $1[1] } / 4)
    }
    /// Invalid raw quads abstain; unavailable/oversize pixels zero only the pixel block.
    /// Caller must supply the raw detector quad and original seed, never OCR-selected geometry.
    static func extract(rawPolygon q: [[Double]], frame: NativeOCRRGBAFrame,
                        detectorSeed: DBEvidence? = nil, rfPrimitives: [RFPrimitive] = []) -> Output? {
        guard let a = axes(q) else { return nil }
        let pixel = pixels(q, a, frame)
        guard let db = detectorFeatures(detectorSeed, a) else { return nil }
        let values = (pixel ?? Array(repeating: 0, count: 65)) + [pixel == nil ? 0 : 1] + db + rfFeatures(rfPrimitives, a)
        guard values.count == 126 else { return nil }
        return Output(features: values.map {
            let f = Float($0)
            return f.isNaN ? 0 : f == .infinity ? Float.greatestFiniteMagnitude :
                f == -.infinity ? -Float.greatestFiniteMagnitude : f
        }, pixelAvailable: pixel != nil)
    }
    private static func quantile(_ sorted: [Double], _ p: Double) -> Double {
        let x = p * Double(sorted.count - 1), lo = Int(floor(x)), hi = Int(ceil(x))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (x - Double(lo))
    }
    private static func median(_ values: [Float]) -> Float {
        let s = values.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
    /// OpenCV remap INTER_LINEAR: Float32 map, ties-to-even 1/32 coordinate
    /// quantization, integer bilinear weights, rounded uint8 result, BORDER_REPLICATE.
    private static func sample(_ frame: NativeOCRRGBAFrame, _ mx: Float, _ my: Float) -> [Float] {
        let xx = Double(mx) * 32, yy = Double(my) * 32
        // Far outside the image, both replicated neighbors are the same edge pixel.
        let x = Int(min(Double(frame.width * 32), max(-32, xx)).rounded(.toNearestOrEven))
        let y = Int(min(Double(frame.height * 32), max(-32, yy)).rounded(.toNearestOrEven))
        let ix = Int(floor(Double(x) / 32)), iy = Int(floor(Double(y) / 32))
        let fx = x - ix * 32, fy = y - iy * 32
        let x0 = min(frame.width - 1, max(0, ix)), x1 = min(frame.width - 1, max(0, ix + 1))
        let y0 = min(frame.height - 1, max(0, iy)), y1 = min(frame.height - 1, max(0, iy + 1))
        let weights = [(32 - fx) * (32 - fy), fx * (32 - fy), (32 - fx) * fy, fx * fy]
        let offsets = [y0 * frame.bytesPerRow + x0 * 4, y0 * frame.bytesPerRow + x1 * 4,
                       y1 * frame.bytesPerRow + x0 * 4, y1 * frame.bytesPerRow + x1 * 4]
        return (0..<3).map { channel in
            var sum = 0
            for j in 0..<4 { sum += Int(frame.bytes[offsets[j] + channel]) * weights[j] }
            return Float(min(255, max(0, (sum + 512) >> 10)))
        }
    }
    private static func pixels(_ q: [[Double]], _ a: Axes, _ frame: NativeOCRRGBAFrame) -> [Double]? {
        guard a.w >= 1, a.h >= 1, abs(a.ux * a.vx + a.uy * a.vy) <= 0.05,
              a.w * a.h * 1.3 * 1.3 <= 0.15 * Double(frame.width) * Double(frame.height) else { return nil }
        let nx = 96, ny = 256, count = nx * ny
        let xs = (0..<nx).map { -0.15 + (Double($0) + 0.5) * 1.3 / Double(nx) }
        let ys = (0..<ny).map { -0.15 + (Double($0) + 0.5) * 1.3 / Double(ny) }
        var samples = [[Float]](); samples.reserveCapacity(count)
        var valid = [Bool](), inside = [Bool](), exterior = [Bool](), histogram = Array(repeating: 0, count: 512)
        var ids = [Int](), interiorCount = 0, exteriorCount = 0
        for y in 0..<ny {
            for x in 0..<nx {
                let mx = Float(q[0][0] + xs[x] * (q[1][0] - q[0][0]) + ys[y] * (q[3][0] - q[0][0]))
                let my = Float(q[0][1] + xs[x] * (q[1][1] - q[0][1]) + ys[y] * (q[3][1] - q[0][1]))
                guard mx.isFinite, my.isFinite else { return nil }
                let ok = mx >= 0 && my >= 0 && Double(mx) <= Double(frame.width - 1) && Double(my) <= Double(frame.height - 1)
                let body = xs[x] >= 0 && xs[x] <= 1 && ys[y] >= 0 && ys[y] <= 1
                let s = sample(frame, mx, my)
                let id = Int(s[0]) / 32 * 64 + Int(s[1]) / 32 * 8 + Int(s[2]) / 32
                samples.append(s); valid.append(ok); inside.append(ok && body); exterior.append(ok && !body); ids.append(id)
                if ok && body { interiorCount += 1 }
                if ok && !body { exteriorCount += 1; histogram[id] += 1 }
            }
        }
        guard interiorCount >= 16, exteriorCount >= 16 else { return nil }
        var mode = 0
        for i in 1..<512 where histogram[i] > histogram[mode] { mode = i }
        let borderMode = (0..<count).filter { exterior[$0] && ids[$0] == mode }
        let background = (0..<3).map { channel in median(borderMode.map { samples[$0][channel] }) }
        let contrast: [Float] = samples.map { s in max(abs(s[0] - background[0]), abs(s[1] - background[1]), abs(s[2] - background[2])) }
        let gray: [Float] = samples.map { ($0[0] + $0[1] + $0[2]) / 3 }
        var gradients = [Float](); gradients.reserveCapacity(interiorCount)
        for i in 0..<count where inside[i] {
            let dx = abs(gray[i] - gray[i % nx == 0 ? i : i - 1])
            let dy = abs(gray[i] - gray[i < nx ? i : i - nx])
            gradients.append(min(255, dx + dy))
        }
        // NumPy mean(float32) uses pairwise summation; mirror that reduction order.
        let grad = floatSum(gradients) / Float(gradients.count) / 255
        let dispersion = median((0..<count).filter { exterior[$0] }.map { contrast[$0] }) / 255
        var result = [log(a.w), log(a.h), log(a.w / a.h), 2 * a.ux * a.uy,
                      a.ux * a.ux - a.uy * a.uy, Double(valid.filter { $0 }.count) / Double(count),
                      Double(dispersion), Double(grad)]
        for threshold in [Float(16), 32, 48] {
            var um = Array(repeating: 0, count: nx), vm = Array(repeating: 0, count: ny)
            var stripTotal = Array(repeating: 0, count: 5), stripInk = stripTotal
            for y in 0..<ny {
                for x in 0..<nx {
                    let i = y * nx + x
                    guard valid[i] else { continue }
                    let ix = xs[x] >= 0 && xs[x] <= 1, iy = ys[y] >= 0 && ys[y] <= 1
                    let ink = contrast[i] >= threshold
                    if ink && iy { um[x] += 1 }
                    if ink && ix { vm[y] += 1 }
                    let strips = [inside[i], xs[x] < 0 && iy, xs[x] > 1 && iy, ys[y] < 0 && ix, ys[y] > 1 && ix]
                    for j in 0..<5 where strips[j] { stripTotal[j] += 1; if ink { stripInk[j] += 1 } }
                }
            }
            for (mass, coords) in [(um, xs), (vm, ys)] {
                let total = mass.reduce(0, +)
                for p in [0.01, 0.05, 0.1, 0.5, 0.9, 0.95, 0.99] {
                    if total == 0 { result.append(0.5); continue }
                    var cumulative = 0, selected = mass.count - 1
                    for i in mass.indices {
                        cumulative += mass[i]
                        if Double(cumulative) / Double(total) >= p { selected = i; break }
                    }
                    result.append(coords[selected])
                }
            }
            result += (0..<5).map { stripTotal[$0] == 0 ? 0 : Double(stripInk[$0]) / Double(stripTotal[$0]) }
        }
        return result
    }
    private static func floatSum(_ x: [Float]) -> Float {
        func sum(_ lo: Int, _ n: Int) -> Float {
            if n < 8 { var s: Float = -0.0; for i in lo..<(lo + n) { s += x[i] }; return s }
            if n <= 128 {
                var r = Array(x[lo..<(lo + 8)]), i = 8
                while i < n - n % 8 { for j in 0..<8 { r[j] += x[lo + i + j] }; i += 8 }
                var s = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
                while i < n { s += x[lo + i]; i += 1 }; return s
            }
            var n2 = n / 2; n2 -= n2 % 8
            return sum(lo, n2) + sum(lo + n2, n - n2)
        }
        return sum(0, x.count)
    }
    private static func detectorFeatures(_ seed: DBEvidence?, _ a: Axes) -> [Double]? {
        guard let s = seed else { return Array(repeating: 0, count: 20) }
        guard s.mapFullWidth > 0, s.mapFullHeight > 0, s.sourceWidth > 0, s.sourceHeight > 0 else { return nil }
        let sx = Double(s.sourceWidth) / Double(s.mapFullWidth), sy = Double(s.sourceHeight) / Double(s.mapFullHeight)
        var uu = [Double](), vv = [Double](), probs = [Double]()
        for c in s.components {
            guard c.meanProbability.isFinite else { return nil }; probs.append(c.meanProbability)
            for run in c.runs {
                // Bound malformed external input before expansion. Native complete-CC runs fit the map.
                guard run.count >= 0, run.x >= 0, run.y >= 0, run.y < s.mapFullHeight,
                      run.x <= s.mapFullWidth, run.count <= s.mapFullWidth - run.x,
                      uu.count <= 16_777_216 - run.count else { return nil }
                for x in run.x..<(run.x + run.count) {
                    let dx = (Double(x) + 0.5) * sx - a.cx, dy = (Double(run.y) + 0.5) * sy - a.cy
                    uu.append((dx * a.ux + dy * a.uy) / a.w); vv.append((dx * a.vx + dy * a.vy) / a.h)
                }
            }
        }
        let total = uu.count
        if uu.isEmpty { uu = [0]; vv = [0] }; uu.sort(); vv.sort()
        var result = [1.0, s.ownershipVersion == 2 && s.completeCCScan == true ? 1.0 : 0.0,
                      log1p(Double(s.components.count)), log1p(Double(s.ambiguousComponents?.count ?? 0)),
                      log1p(Double(s.candidateComponents?.count ?? 0)), log1p(Double(total)),
                      probs.isEmpty ? 0 : probs.reduce(0, +) / Double(probs.count), probs.min() ?? 0,
                      (abs(a.ux) * sx + abs(a.uy) * sy) / a.w, (abs(a.vx) * sx + abs(a.vy) * sy) / a.h]
        for sorted in [uu, vv] { result += [0.0, 0.1, 0.5, 0.9, 1.0].map { quantile(sorted, $0) } }
        return result
    }
    private static func rfFeatures(_ rf: [RFPrimitive], _ a: Axes) -> [Double] {
        var result = [Double]()
        for cl in 0..<4 {
            var best: [Double]?, bestScore = -Double.infinity, maximum = -Double.infinity, intersections = 0
            for p in rf where p.classID == cl {
                let b = p.sourceBounds
                guard [b.x, b.y, b.width, b.height, p.confidence].allSatisfy(\.isFinite) else { continue }
                let corners = [[b.x, b.y], [b.x + b.width, b.y], [b.x + b.width, b.y + b.height], [b.x, b.y + b.height]]
                let xx = corners.map { (($0[0] - a.cx) * a.ux + ($0[1] - a.cy) * a.uy) / a.w }
                let yy = corners.map { (($0[0] - a.cx) * a.vx + ($0[1] - a.cy) * a.vy) / a.h }
                let l = xx.min()!, r = xx.max()!, t = yy.min()!, btm = yy.max()!
                let inter = max(0, min(0.5, r) - max(-0.5, l)) * max(0, min(0.5, btm) - max(-0.5, t))
                let area = max(1e-12, (r - l) * (btm - t)), score = p.confidence * inter
                maximum = max(maximum, p.confidence); if inter > 0 { intersections += 1 }
                // Python max retains the FIRST primitive on ties, including zero intersections.
                if best == nil || score > bestScore {
                    bestScore = score
                    best = [inter, inter / area, l + 0.5, r - 0.5, t + 0.5, btm - 0.5, p.confidence]
                }
            }
            if let best { result += [1, maximum, log1p(Double(intersections))] + best }
            else { result += Array(repeating: 0, count: 10) }
        }
        return result
    }
}
