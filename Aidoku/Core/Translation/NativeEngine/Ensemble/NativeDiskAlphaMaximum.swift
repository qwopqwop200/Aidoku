import Accelerate
import Foundation

/// Maximum alpha under a flat or coverage-weighted disk.
enum NativeDiskAlphaMaximum {
    // vImage maximizes source minus kernel. Entries outside the disk subtract
    // 255, which reduces every possible alpha byte to zero after clipping.
    private static let flatKernels: [[UInt8]] = (0...8).map { radius in
        let side = radius * 2 + 1
        var kernel = [UInt8](repeating: 255, count: side * side)
        for y in -radius...radius {
            for x in -radius...radius where x * x + y * y <= radius * radius {
                kernel[(y + radius) * side + x + radius] = 0
            }
        }
        return kernel
    }

    static func flatSmallDisk(_ alpha: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8]? {
        guard (1...8).contains(radius), width >= 32, height >= 8 else { return nil }
        let side = radius * 2 + 1
        var result = [UInt8](repeating: 0, count: alpha.count)
        return flat(alpha, width: width, height: height, kernel: flatKernels[radius], side: side, into: &result) ? result : nil
    }

    private static func flat(_ alpha: [UInt8], width: Int, height: Int, kernel: [UInt8], side: Int,
                             into result: inout [UInt8]) -> Bool {
        guard height > 0, width == alpha.count / height, alpha.count % height == 0 else { return false }
        let status = alpha.withUnsafeBytes { input in
            result.withUnsafeMutableBytes { output in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: input.baseAddress!),
                    height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var dst = vImage_Buffer(data: output.baseAddress!, height: src.height, width: src.width, rowBytes: width)
                return vImageDilate_Planar8(&src, &dst, 0, 0, kernel, vImagePixelCount(side), vImagePixelCount(side),
                                            vImage_Flags(kvImageDoNotTile))
            }
        }
        return status == kvImageNoError
    }

    // For each nonzero coverage, take the maximum over its disk, then apply
    // coverage once. Rounding is monotone, so the largest weighted byte across
    // these disks equals the largest separately weighted neighbor.
    private static func smallAntialiasedDisk(_ alpha: [UInt8], width: Int, height: Int, radius: CGFloat) -> [UInt8]? {
        let size = Int(ceil(radius))
        guard radius >= 0.5, size <= 8, width >= 32, height >= 8 else { return nil }
        let side = size * 2 + 1
        var weights: [Double] = []
        for dy in -size...size {
            for dx in -size...size {
                weights.append(min(1, max(0, Double(radius) + 0.5 - hypot(Double(dx), Double(dy)))))
            }
        }
        var result = [UInt8](repeating: 0, count: alpha.count)
        var layer = result
        for weight in Set(weights).sorted(by: >) where weight > 0 {
            let kernel = weights.map { $0 >= weight ? UInt8(0) : 255 }
            guard flat(alpha, width: width, height: height, kernel: kernel, side: side, into: &layer) else { return nil }
            if weight == 1 {
                swap(&result, &layer)
            } else {
                let table = (0...255).map { UInt8((Double($0) * weight).rounded()) }
                for i in layer.indices { result[i] = max(result[i], table[Int(layer[i])]) }
            }
        }
        return result
    }

    static func antialiased(_ alpha: [UInt8], width: Int, height: Int, radius: CGFloat) -> [UInt8] {
        if let result = smallAntialiasedDisk(alpha, width: width, height: height, radius: radius) { return result }
        let size = Int(ceil(radius))
        var result = [UInt8](repeating: 0, count: alpha.count)
        var deque = [Int](repeating: 0, count: width)
        for dy in 0...min(size, height - 1) {
            var inner = -1
            var fringe: [(Int, Double)] = []
            for dx in -size...size {
                let weight = min(1, max(0, Double(radius) + 0.5 - hypot(Double(dx), Double(dy))))
                if weight == 1 { inner = max(inner, abs(dx)) }
                else if weight > 0 { fringe.append((dx, weight)) }
            }
            if inner < 0 && fringe.isEmpty { continue }
            for row in 0..<height {
                let upper = row >= dy ? (row - dy) * width : -1
                let lower = dy > 0 && row + dy < height ? (row + dy) * width : -1
                guard upper >= 0 || lower >= 0 else { continue }
                let source = row * width
                var head = 0, tail = 0, next = 0
                for x in 0..<width {
                    while inner >= 0 && next <= min(width - 1, x + inner) {
                        while tail > head && alpha[source + deque[tail - 1]] <= alpha[source + next] { tail -= 1 }
                        deque[tail] = next
                        tail += 1
                        next += 1
                    }
                    while head < tail && deque[head] < x - inner { head += 1 }
                    var value: UInt8 = head < tail ? alpha[source + deque[head]] : 0
                    for (dx, weight) in fringe {
                        let sx = x + dx
                        if sx >= 0 && sx < width {
                            value = max(value, UInt8((Double(alpha[source + sx]) * weight).rounded()))
                        }
                    }
                    if upper >= 0 { result[upper + x] = max(result[upper + x], value) }
                    if lower >= 0 { result[lower + x] = max(result[lower + x], value) }
                }
            }
        }
        return result
    }
}
