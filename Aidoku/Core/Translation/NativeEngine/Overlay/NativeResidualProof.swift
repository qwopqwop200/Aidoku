import CoreGraphics
import Foundation

/// Native ports of the forced donor quality policies. Byte writes use ECMAScript
/// ToUint8Clamp (ties to even); relaxation scratch writes retain Float32 rounding.
enum NativeResidualProof {
    struct Options {
        var excludedMask: [UInt8]? = nil
        var protected: [UInt8]? = nil
        var sourceForeground: [Double]? = nil
        var sourceStroke: [Double]? = nil
        var sourceBackground: [Double]? = nil
        var glyphSize: Double = 0
    }
    struct Quality {
        var safe = false
        var erased = 0
        var noDonor = 0
        var continuous = 0
        var seams = 0
        var wide = 0
        var wideDiscordant = 0
        var maxSpan = 0
        var residualSourceInk = 0
        var whiteHaloFractionInner: Double = 0
        var whiteHaloFractionOuter: Double = 0
        var whiteHaloPixels = 0
        var whiteHaloRadius = 0
        var edgeRelaxationIterations = 0
        var components = 0
        var patches: Double = 0
        var maxError: Double = 0
        var patchedPixels = 0
        var rayPixels = 0
        var donorQuality: [Quality]? = nil
        var surface: Surface? = nil
        var supportSides: [Int]? = nil
        var continuityRatio: Double { Double(continuous) / Double(max(1, erased)) }
    }
    struct Fill {
        var rgba: [UInt8]?
        var method: String
        var quality: Quality
        var failure = ""
        var residualMask: [UInt8]? = nil
    }
    struct Surface {
        var safe = false
        var reason: String
        var samples: Int
        var coefficients: [[Double]]? = nil
        var rmse: Double = .nan
        var outliers: Double = .nan
        var localSamples = 0
        var localRMSE: Double = .nan
        var edgeFraction: Double = .nan
    }
    struct Exemplar {
        let rgba: [UInt8]
        let patches: Double
        let maxError: Double
        let textureRatio: Double
    }

    static func clamp(_ value: Double) -> UInt8 {
        if value.isNaN || value <= 0 { return 0 }
        if value >= 255 { return 255 }
        return UInt8(value.rounded(.toNearestOrEven))
    }

    /// aidokuForcedDonorFill, including sparse missing-core and white-halo proofs.
    static func forcedDonorFill(rgba original: [UInt8], width w: Int, height h: Int,
                                mask: [UInt8], options: Options = Options()) -> Fill? {
        guard w >= 8, h >= 8, w <= 1_000_000 / h, original.count == w * h * 4,
              mask.count == w * h, options.excludedMask == nil || options.excludedMask?.count == w * h,
              options.protected == nil || options.protected?.count == w * h else { return nil }
        let n = w * h
        var out = original
        func donor(_ i: Int) -> Bool {
            mask[i] == 0 && (options.excludedMask?[i] ?? 0) == 0 &&
                (options.protected?[i] ?? 0) == 0 && original[i * 4 + 3] >= 250
        }
        var left = [Int](repeating: -1, count: n), right = left, up = left, down = left
        for y in 0..<h {
            var last = -1
            for x in 0..<w { let i = y * w + x; if donor(i) { last = i }; left[i] = last }
            last = -1
            for x in stride(from: w - 1, through: 0, by: -1) { let i = y * w + x; if donor(i) { last = i }; right[i] = last }
        }
        for x in 0..<w {
            var last = -1
            for y in 0..<h { let i = y * w + x; if donor(i) { last = i }; up[i] = last }
            last = -1
            for y in stride(from: h - 1, through: 0, by: -1) { let i = y * w + x; if donor(i) { last = i }; down[i] = last }
        }
        let maxReach = max(36, min(64, (options.glyphSize.isFinite ? options.glyphSize : 0) * 0.45))
        func difference(_ a: Int, _ b: Int) -> Int {
            (0..<3).map { abs(Int(original[a * 4 + $0]) - Int(original[b * 4 + $0])) }.max() ?? 0
        }
        struct Pair { let a: Int; let b: Int; let da: Int; let db: Int; let gap: Int; var span: Int { da + db } }
        var quality = Quality()
        for i in 0..<n where mask[i] != 0 {
            quality.erased += 1
            let x = i % w, y = i / w
            var candidates: [Pair] = []
            if left[i] >= 0 && right[i] >= 0 {
                let a = left[i], b = right[i]
                candidates.append(Pair(a: a, b: b, da: x - a % w, db: b % w - x, gap: difference(a, b)))
            }
            if up[i] >= 0 && down[i] >= 0 {
                let a = up[i], b = down[i]
                candidates.append(Pair(a: a, b: b, da: y - a / w, db: b / w - y, gap: difference(a, b)))
            }
            let local = candidates.enumerated().filter { Double($0.element.da) <= maxReach && Double($0.element.db) <= maxReach }
                .sorted { a, b in
                    let x = Double(a.element.gap) + min(48, Double(a.element.span) * 0.45)
                    let y = Double(b.element.gap) + min(48, Double(b.element.span) * 0.45)
                    return x == y ? a.offset < b.offset : x < y
                }.map(\.element)
            let color: [Double]
            if let best = local.first, best.gap <= 36 {
                quality.maxSpan = max(quality.maxSpan, best.span)
                let blend = Double(best.da) / Double(max(1, best.span))
                color = (0..<3).map { Double(original[best.a * 4 + $0]) * (1 - blend) + Double(original[best.b * 4 + $0]) * blend }
                quality.continuous += 1
            } else {
                let singles = [left[i], right[i], up[i], down[i]].filter { $0 >= 0 }
                guard var closest = singles.first else { quality.noDonor += 1; continue }
                var distance = Int.max
                for j in singles {
                    let d = abs(j % w - x) + abs(j / w - y)
                    if d < distance { distance = d; closest = j }
                }
                quality.maxSpan = max(quality.maxSpan, distance)
                if Double(distance) > maxReach { quality.wide += 1; quality.wideDiscordant += 1 }
                color = (0..<3).map { Double(original[closest * 4 + $0]) }
                quality.seams += 1
            }
            for c in 0..<3 { out[i * 4 + c] = clamp(color[c]) }
            out[i * 4 + 3] = 255
        }
        quality.safe = quality.erased > 0 && quality.noDonor == 0 &&
            Double(quality.wide) <= Double(quality.erased) * 0.05 && Double(quality.erased) <= Double(n) * 0.45
        if quality.safe, let foreground = options.sourceForeground, foreground.count == 3, foreground.allSatisfy(\.isFinite) {
            var distance = [UInt8](repeating: 255, count: n), queue: [Int] = []
            for i in 0..<n where mask[i] != 0 { distance[i] = 0; queue.append(i) }
            var head = 0
            while head < queue.count {
                let i = queue[head], d = distance[i]; head += 1
                if d >= 16 { continue }
                for j in cardinal(i, width: w, height: h) where distance[j] > d + 1 {
                    distance[j] = d + 1; queue.append(j)
                }
            }
            var residual = [UInt8](repeating: 0, count: n), residue = 0
            for i in 0..<n where distance[i] > 0 && distance[i] <= 16 &&
                (options.excludedMask?[i] ?? 0) == 0 && (options.protected?[i] ?? 0) == 0 {
                if pixelDistance(original, i, foreground) <= 24 { residual[i] = 1; residue += 1 }
            }
            quality.residualSourceInk = residue
            let darkDetected = residue >= max(8, Int(ceil(Double(quality.erased) * 0.0025)))
            let darkSparse = Double(residue) <= max(64, Double(quality.erased) * 0.15)
            var rings = [Int](repeating: 0, count: 13), whiteRings = rings
            for i in 0..<n {
                let d = Int(distance[i])
                if d < 1 || d > 12 || (options.excludedMask?[i] ?? 0) != 0 || (options.protected?[i] ?? 0) != 0 { continue }
                rings[d] += 1
                if min(original[i * 4], original[i * 4 + 1], original[i * 4 + 2]) >= 246 { whiteRings[d] += 1 }
            }
            func fraction(_ a: Int, _ b: Int) -> Double {
                let total = (a...b).reduce(0) { $0 + rings[$1] }
                return total == 0 ? 0 : Double((a...b).reduce(0) { $0 + whiteRings[$1] }) / Double(total)
            }
            let inner = fraction(1, 3), outer = fraction(9, 12)
            quality.whiteHaloFractionInner = inner; quality.whiteHaloFractionOuter = outer
            if inner >= 0.82 && inner - outer >= 0.28 &&
                Double(whiteRings[1] + whiteRings[2] + whiteRings[3]) >= max(12, Double(quality.erased) * 0.05) {
                let midpoint = (inner + outer) / 2
                var radius = 8
                for d in 4...8 where rings[d] > 0 && Double(whiteRings[d]) / Double(rings[d]) < midpoint { radius = max(3, d - 1); break }
                var outline = [UInt8](repeating: 0, count: n), count = 0
                for i in 0..<n where distance[i] > 0 && Int(distance[i]) <= radius &&
                    (options.excludedMask?[i] ?? 0) == 0 && (options.protected?[i] ?? 0) == 0 {
                    if min(original[i * 4], original[i * 4 + 1], original[i * 4 + 2]) >= 246 { outline[i] = 1; count += 1 }
                }
                if Double(count) >= max(12, Double(quality.erased) * 0.05) {
                    if darkDetected && darkSparse { for i in 0..<n where residual[i] != 0 && outline[i] == 0 { outline[i] = 1; count += 1 } }
                    quality.whiteHaloPixels = count; quality.whiteHaloRadius = radius; quality.safe = false
                    return Fill(rgba: nil, method: "rejected-edge-aware-donors", quality: quality,
                                failure: "residual-white-outline", residualMask: outline)
                }
            }
            if darkDetected {
                quality.safe = false
                return Fill(rgba: nil, method: "rejected-edge-aware-donors", quality: quality,
                    failure: darkSparse ? "residual-source-ink" : "ambiguous-residual-source-ink", residualMask: darkSparse ? residual : nil)
            }
        }
        guard quality.safe else {
            return Fill(rgba: nil, method: "rejected-edge-aware-donors", quality: quality,
                failure: quality.noDonor != 0 ? "no-clean-donor" : Double(quality.wide) > Double(quality.erased) * 0.05 ? "distant-donors" : "oversized-mask")
        }
        let points = (0..<n).filter { mask[$0] != 0 }
        var index = [Int](repeating: -1, count: n)
        for (k, i) in points.enumerated() { index[i] = k }
        var values = [Float](repeating: 0, count: quality.erased * 3), next = values
        var weights = [Float](repeating: 0, count: quality.erased * 4), adjacent = [Int](repeating: -1, count: quality.erased * 4)
        for (k, i) in points.enumerated() {
            for c in 0..<3 { values[k * 3 + c] = Float(out[i * 4 + c]) }
            let x = i % w, y = i / w
            let neighbors = [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]
            for (d, j) in neighbors.enumerated() where j >= 0 {
                if mask[j] == 0 && !donor(j) { continue }
                var delta = 0
                for c in 0..<3 { delta = max(delta, abs(Int(out[i * 4 + c]) - Int(out[j * 4 + c]))) }
                adjacent[k * 4 + d] = j
                weights[k * 4 + d] = delta > 32 ? 0 : Float(1 / (1 + pow(Double(delta) / 12, 4)))
            }
        }
        for _ in 0..<24 {
            for k in points.indices {
                var total = 0.0, rgb = [Double](repeating: 0, count: 3)
                for d in 0..<4 {
                    let weight = Double(weights[k * 4 + d]); if weight == 0 { continue }
                    let j = adjacent[k * 4 + d], at = index[j]; total += weight
                    for c in 0..<3 { rgb[c] += weight * (at >= 0 ? Double(values[at * 3 + c]) : Double(out[j * 4 + c])) }
                }
                for c in 0..<3 { next[k * 3 + c] = total > 0 ? Float(rgb[c] / total) : values[k * 3 + c] }
            }
            swap(&values, &next)
        }
        for (k, i) in points.enumerated() { for c in 0..<3 { out[i * 4 + c] = clamp(Double(values[k * 3 + c])) } }
        quality.edgeRelaxationIterations = 24
        return Fill(rgba: out, method: "edge-aware-donors", quality: quality)
    }

    /// aidokuSourceSurfaceQuality. Dense is a separate conservative recovery
    /// gate; it may never reclassify textured donors as a safe smooth surface.
    static func sourceSurfaceQuality(rgba: [UInt8], width w: Int, height h: Int, mask: [UInt8],
                                     blocked: [UInt8], dense: Bool = false) -> Surface? {
        guard w > 4, h > 4, w <= 1_000_000 / h, rgba.count == w * h * 4,
              mask.count == w * h, blocked.count == w * h else { return nil }
        let step = dense ? 1 : max(1, Int(ceil(sqrt(Double(w * h) / 4096))))
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0
            for x in 0..<w { row += mask[y * w + x] == 0 ? 0 : 1; integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row }
        }
        func donor(_ x: Int, _ y: Int) -> Bool {
            let i = y * w + x
            if mask[i] != 0 || blocked[i] != 0 { return false }
            let x0 = max(0, x - 4), x1 = min(w - 1, x + 4) + 1, y0 = max(0, y - 4), y1 = min(h - 1, y + 4) + 1
            return integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] -
                integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0] > 0
        }
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3), rhs = matrix, count = 0
        for y in stride(from: 1, to: h - 1, by: step) {
            for x in stride(from: 1, to: w - 1, by: step) where donor(x, y) {
                let i = y * w + x, a = [1, Double(x) / Double(w), Double(y) / Double(h)]; count += 1
                for j in 0..<3 {
                    for k in 0..<3 { matrix[j][k] += a[j] * a[k] }
                    for c in 0..<3 { rhs[c][j] += a[j] * Double(rgba[i * 4 + c]) }
                }
            }
        }
        if count < 24 { return Surface(reason: "insufficient-donors", samples: count) }
        var coefficients: [[Double]] = []
        for values in rhs {
            var m = (0..<3).map { matrix[$0] + [values[$0]] }
            for k in 0..<3 {
                var pivot = k
                if k + 1 < 3 { for j in (k + 1)..<3 where abs(m[j][k]) > abs(m[pivot][k]) { pivot = j } }
                m.swapAt(k, pivot)
                if abs(m[k][k]) < 0.000_001 { return Surface(reason: "insufficient-geometry", samples: count) }
                let d = m[k][k]
                for c in k..<4 { m[k][c] /= d }
                for j in 0..<3 where j != k { let f = m[j][k]; for c in k..<4 { m[j][c] -= f * m[k][c] } }
            }
            coefficients.append(m.map { $0[3] })
        }
        var squared = 0.0, outliers = 0
        for y in stride(from: 1, to: h - 1, by: step) {
            for x in stride(from: 1, to: w - 1, by: step) where donor(x, y) {
                let i = y * w + x
                var error = 0.0
                for c in 0..<3 {
                    let a = coefficients[c]
                    error = max(error, abs(Double(rgba[i * 4 + c]) - (a[0] + a[1] * Double(x) / Double(w) + a[2] * Double(y) / Double(h))))
                }
                squared += error * error
                if error > 22 { outliers += 1 }
            }
        }
        let rmse = sqrt(squared / Double(count)), fraction = Double(outliers) / Double(count)
        var result = Surface(reason: "textured", samples: count, coefficients: coefficients, rmse: rmse, outliers: fraction)
        if dense && (rmse > 3 || fraction > 0) { return result }
        if rmse <= 14 && fraction <= 0.08 { result.safe = true; result.reason = "smooth"; return result }
        var localCount = 0, localSquared = 0.0, localOutliers = 0, edges = 0
        for y in stride(from: 2, to: h - 2, by: step) {
            for x in stride(from: 2, to: w - 2, by: step) where donor(x, y) {
                let i = y * w + x, neighbors = [i - 1, i + 1, i - w, i + w]
                if neighbors.contains(where: { mask[$0] != 0 || blocked[$0] != 0 }) { continue }
                var residual = 0.0, edge = 0.0
                for c in 0..<3 {
                    let center = Double(rgba[i * 4 + c]), values = neighbors.map { Double(rgba[$0 * 4 + c]) }
                    let average = values.reduce(0, +) / 4
                    residual = max(residual, abs(center - average))
                    for value in values { edge = max(edge, abs(center - value)) }
                }
                localCount += 1; localSquared += residual * residual
                if residual > 12 { localOutliers += 1 }; if edge > 28 { edges += 1 }
            }
        }
        let localRMSE = sqrt(localSquared / Double(max(1, localCount)))
        result.safe = localCount >= 24 && Double(localCount) >= Double(count) * 0.25 && localRMSE <= 5 &&
            Double(localOutliers) / Double(max(1, localCount)) <= 0.04 && Double(edges) / Double(max(1, localCount)) <= 0.04
        result.reason = result.safe ? "locally-smooth" : "textured"
        result.localSamples = localCount; result.localRMSE = localRMSE; result.edgeFraction = Double(edges) / Double(max(1, localCount))
        return result
    }

    /// aidokuCertifiedSurfaceFill, including four independent donor-side support
    /// witnesses and rejection if source-colored original ink survives the fill.
    static func certifiedSurfaceFill(rgba: [UInt8], width w: Int, height h: Int, mask: [UInt8],
                                     blocked: [UInt8], options: Options = Options()) -> Fill? {
        guard let surface = sourceSurfaceQuality(rgba: rgba, width: w, height: h, mask: mask, blocked: blocked, dense: true),
              surface.safe, surface.reason == "smooth", surface.rmse <= 3, surface.outliers == 0,
              surface.samples >= 64, let coefficients = surface.coefficients else { return nil }
        var l = w, t = h, r = -1, b = -1, erased = 0
        for i in 0..<(w * h) where mask[i] != 0 {
            let x = i % w, y = i / w; l = min(l, x); r = max(r, x); t = min(t, y); b = max(b, y); erased += 1
        }
        if erased == 0 { return nil }
        var sides = [Int](repeating: 0, count: 4)
        for y in max(0, t - 4)...min(h - 1, b + 4) {
            for x in max(0, l - 4)...min(w - 1, r + 4) {
                let i = y * w + x
                if mask[i] != 0 || blocked[i] != 0 || rgba[i * 4 + 3] < 250 { continue }
                if x < l { sides[0] += 1 }; if x > r { sides[1] += 1 }; if y < t { sides[2] += 1 }; if y > b { sides[3] += 1 }
            }
        }
        if sides.contains(where: { $0 < 8 }) { return nil }
        var output = rgba, residual = 0
        for i in 0..<(w * h) where mask[i] != 0 {
            let x = i % w, y = i / w
            for c in 0..<3 {
                let a = coefficients[c], value = a[0] + a[1] * Double(x) / Double(w) + a[2] * Double(y) / Double(h)
                if !value.isFinite || value < 0 || value > 255 { return nil }
                output[i * 4 + c] = clamp(value)
            }
            output[i * 4 + 3] = 255
            if let fg = options.sourceForeground, fg.count >= 3,
               pixelDistance(rgba, i, fg) <= 28 && pixelDistance(output, i, fg) <= 28 { residual += 1 }
        }
        if residual != 0 { return nil }
        var quality = Quality(); quality.safe = true; quality.erased = erased; quality.residualSourceInk = residual
        quality.surface = surface; quality.supportSides = sides
        return Fill(rgba: output, method: "certified-surface-plane", quality: quality)
    }

    private static func cardinal(_ i: Int, width w: Int, height h: Int) -> [Int] {
        let x = i % w, y = i / w
        return [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1].filter { $0 >= 0 }
    }
    static func pixelDistance(_ rgba: [UInt8], _ i: Int, _ color: [Double]) -> Double {
        guard color.count >= 3 else { return 256 }
        return (0..<3).map { abs(Double(rgba[i * 4 + $0]) - color[$0]) }.max() ?? 256
    }
}
