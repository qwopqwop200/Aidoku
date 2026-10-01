import CoreGraphics
import Foundation

extension NativeRestorationPixels {
    struct Surface {
        let coefficients: [[Double]]
        let safe: Bool
        let locallySmooth: Bool
        let rmse: Double
        let outliers: Double
        let samples: Int
        var localSamples = 0
        var localRMSE = Double.infinity
        var edgeFraction = Double.infinity
        var payload: [String: Any] {
            var value: [String: Any] = ["coefficients": coefficients, "safe": safe, "reason": reason,
                                       "rmse": rmse, "outliers": outliers, "samples": samples]
            if localSamples > 0 {
                value["localSamples"] = localSamples; value["localRMSE"] = localRMSE; value["edgeFraction"] = edgeFraction
            }
            return value
        }
        var reason: String { locallySmooth ? "locally-smooth" : (safe ? "smooth" : "textured") }
    }

    /// Same least-squares plane and local continuity gates as aidokuSourceSurfaceQuality.
    /// Donors must be original pixels within four rings of the actual erase mask.
    static func surface(_ p: Self, mask: [UInt8], blocked: [UInt8], dense: Bool = false) -> Surface? {
        let stride = dense ? 1 : max(1, Int(ceil(sqrt(Double(p.count) / 4096))))
        let tableWidth = p.width + 1
        var integral = [Int](repeating: 0, count: tableWidth * (p.height + 1))
        for y in 0..<p.height {
            var row = 0
            for x in 0..<p.width {
                row += mask[y * p.width + x] == 0 ? 0 : 1
                integral[(y + 1) * tableWidth + x + 1] = integral[y * tableWidth + x + 1] + row
            }
        }
        func donor(_ x: Int, _ y: Int) -> Bool {
            let index = y * p.width + x
            guard mask[index] == 0, blocked[index] == 0 else { return false }
            let left = max(0, x - 4), right = min(p.width - 1, x + 4) + 1
            let top = max(0, y - 4), bottom = min(p.height - 1, y + 4) + 1
            return integral[bottom * tableWidth + right] - integral[top * tableWidth + right]
                - integral[bottom * tableWidth + left] + integral[top * tableWidth + left] > 0
        }
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        var rhs = matrix, count = 0
        for y in Swift.stride(from: 1, to: p.height - 1, by: stride) {
            for x in Swift.stride(from: 1, to: p.width - 1, by: stride) where donor(x, y) {
                let index = y * p.width + x, a = [1, Double(x) / Double(p.width), Double(y) / Double(p.height)]
                count += 1
                for j in 0..<3 {
                    for k in 0..<3 { matrix[j][k] += a[j] * a[k] }
                    for channel in 0..<3 { rhs[channel][j] += a[j] * Double(p.rgba[index * 4 + channel]) }
                }
            }
        }
        guard count >= 24 else { return nil }
        var coefficients: [[Double]] = []
        for values in rhs {
            var augmented = (0..<3).map { matrix[$0] + [values[$0]] }
            for k in 0..<3 {
                var pivot = k
                for j in k..<3 where abs(augmented[j][k]) > abs(augmented[pivot][k]) { pivot = j }
                augmented.swapAt(k, pivot)
                guard abs(augmented[k][k]) >= 0.000_001 else { return nil }
                let divisor = augmented[k][k]
                for channel in k..<4 { augmented[k][channel] /= divisor }
                for j in 0..<3 where j != k {
                    let factor = augmented[j][k]
                    for channel in k..<4 { augmented[j][channel] -= factor * augmented[k][channel] }
                }
            }
            coefficients.append(augmented.map { $0[3] })
        }
        var squared = 0.0, outliers = 0
        for y in Swift.stride(from: 1, to: p.height - 1, by: stride) {
            for x in Swift.stride(from: 1, to: p.width - 1, by: stride) where donor(x, y) {
                let index = y * p.width + x
                var error = 0.0
                for channel in 0..<3 {
                    let a = coefficients[channel]
                    error = max(error, abs(Double(p.rgba[index * 4 + channel]) - (a[0] + a[1] * Double(x) / Double(p.width)
                                           + a[2] * Double(y) / Double(p.height))))
                }
                squared += error * error
                if error > 22 { outliers += 1 }
            }
        }
        let rmse = sqrt(squared / Double(count)), fraction = Double(outliers) / Double(count)
        if dense && (rmse > 3 || fraction > 0) {
            return Surface(coefficients: coefficients, safe: false, locallySmooth: false, rmse: rmse, outliers: fraction, samples: count)
        }
        if rmse <= 14, fraction <= 0.08 {
            return Surface(coefficients: coefficients, safe: true, locallySmooth: false, rmse: rmse, outliers: fraction, samples: count)
        }
        var localCount = 0, localSquared = 0.0, localOutliers = 0, edges = 0
        for y in Swift.stride(from: 2, to: p.height - 2, by: stride) {
            for x in Swift.stride(from: 2, to: p.width - 2, by: stride) where donor(x, y) {
                let index = y * p.width + x
                let neighbors = [index - 1, index + 1, index - p.width, index + p.width]
                guard neighbors.allSatisfy({ mask[$0] == 0 && blocked[$0] == 0 }) else { continue }
                var residual = 0.0, edge = 0.0
                for channel in 0..<3 {
                    let center = Double(p.rgba[index * 4 + channel])
                    let values = neighbors.map { Double(p.rgba[$0 * 4 + channel]) }
                    residual = max(residual, abs(center - values.reduce(0, +) / 4))
                    edge = max(edge, values.map { abs(center - $0) }.max()!)
                }
                localCount += 1; localSquared += residual * residual
                if residual > 12 { localOutliers += 1 }
                if edge > 28 { edges += 1 }
            }
        }
        let localRMSE = sqrt(localSquared / Double(max(1, localCount)))
        let safe = localCount >= 24 && Double(localCount) >= Double(count) * 0.25 && localRMSE <= 5 &&
            Double(localOutliers) / Double(max(1, localCount)) <= 0.04 && Double(edges) / Double(max(1, localCount)) <= 0.04
        return Surface(coefficients: coefficients, safe: safe, locallySmooth: safe, rmse: rmse, outliers: fraction, samples: count,
                       localSamples: localCount, localRMSE: localRMSE, edgeFraction: Double(edges) / Double(max(1, localCount)))
    }

    static func surfaceDonorCount(_ p: Self, mask: [UInt8], blocked: [UInt8]) -> Int {
        let step = max(1, Int(ceil(sqrt(Double(p.count) / 4096))))
        var count = 0
        for y in stride(from: 1, to: p.height - 1, by: step) {
            for x in stride(from: 1, to: p.width - 1, by: step) {
                let i = y * p.width + x
                guard mask[i] == 0, blocked[i] == 0 else { continue }
                var nearby = false
                for yy in max(0, y - 4)...min(p.height - 1, y + 4) {
                    for xx in max(0, x - 4)...min(p.width - 1, x + 4) where mask[yy * p.width + xx] != 0 { nearby = true }
                }
                if nearby { count += 1 }
            }
        }
        return count
    }

    static func planeFill(_ p: Self, mask: [UInt8], surface: Surface) -> Self {
        var output = Self(width: p.width, height: p.height)
        for index in 0..<p.count where mask[index] != 0 {
            let x = Double(index % p.width) / Double(p.width), y = Double(index / p.width) / Double(p.height)
            output.paint(index, NativeRestorationRGB(surface.coefficients.map { $0[0] + $0[1] * x + $0[2] * y }))
        }
        return output
    }

    /// Raster-order Gauss-Seidel/SOR with Float work buffers, preserving the legacy
    /// 32-pass accelerated convergence rule and 48-pass ordinary fallback.
    static func harmonicFill(_ p: Self, mask: [UInt8], blocked: [UInt8], seed: Self, accelerated: Bool = true, orderedQueue: [Int]? = nil) -> Self {
        let queue: [Int] = orderedQueue ?? ((0..<p.count).filter { mask[$0] != 0 })
        if let result = nativeHarmonicFill(p, mask: mask, blocked: blocked, seed: seed, accelerated: accelerated, queue: queue) {
            return result
        }
        var work = [Float](repeating: 0, count: p.count * 3)
        for index in 0..<p.count {
            for channel in 0..<3 {
                work[index * 3 + channel] = Float(mask[index] != 0 ? seed.rgba[index * 4 + channel] : p.rgba[index * 4 + channel])
            }
        }
        var links = [[Int]](repeating: [], count: queue.count)
        for (k, index) in queue.enumerated() {
            links[k] = p.neighbors(index, diagonal: false).filter { blocked[$0] == 0 || mask[$0] != 0 }
        }
        for pass in 0..<(accelerated ? 32 : 48) {
            let check = accelerated && pass & 3 == 3
            var maximumChange = 0.0
            for (k, index) in queue.enumerated() where !links[k].isEmpty {
                for channel in 0..<3 {
                    let at = index * 3 + channel
                    let average = links[k].reduce(0.0) { $0 + Double(work[$1 * 3 + channel]) } / Double(links[k].count)
                    if accelerated {
                        let change = (average - Double(work[at])) * 1.6
                        work[at] = Float(Double(work[at]) + change)
                        if check { maximumChange = max(maximumChange, abs(change)) }
                    } else { work[at] = Float(average) }
                }
            }
            if check && maximumChange < 0.05 { break }
        }
        var output = Self(width: p.width, height: p.height)
        for index in queue { output.paint(index, NativeRestorationRGB((0..<3).map { Double(work[index * 3 + $0]) })) }
        return output
    }
}
