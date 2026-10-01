import Foundation

extension NativeObservedRestorationHelpers {
    /// Simultaneous Float32 frontier updates, then Uint8ClampedArray rounding. Unreachable pixels retain their mask.
    static func fillFromDonorFront(p: inout [UInt8], w: Int, n: Int, queue: [Int], tail: Int,
                                  mask: inout [UInt8], donorBlocked: [UInt8], paintMask: [UInt8]) {
        guard w > 0, n > 0, n <= p.count / 4, mask.count >= n, donorBlocked.count >= n,
              paintMask.count >= n, tail >= 0, tail <= queue.count else { return }
        func neighbor(_ i: Int, _ direction: Int) -> Int {
            direction == 0 ? i - 1 : direction == 1 ? i + 1 : direction == 2 ? i - w : i + w
        }
        func donorAt(_ i: Int) -> Bool {
            // The source routine only paints interior queues. Preserve its out-of-range undefined semantics safely.
            if i < 0 || i >= n { return true }
            return mask[i] == 0 && (donorBlocked[i] == 0 || paintMask[i] != 0)
        }
        func byte(_ value: Float) -> UInt8 {
            if value.isNaN || value <= 0 { return 0 }
            if value >= 255 { return 255 }
            return UInt8(Double(value).rounded(.toNearestOrEven))
        }
        var queued = [UInt8](repeating: 0, count: n), frontier: [Int] = []
        for i in queue.prefix(tail) where i >= 0 && i < n {
            if (0..<4).contains(where: { donorAt(neighbor(i, $0)) }) { frontier.append(i); queued[i] = 1 }
        }
        while !frontier.isEmpty {
            var rgb = [Float](repeating: 0, count: frontier.count * 3)
            for (offset, i) in frontier.enumerated() {
                var count = 0, sums = [Double](repeating: 0, count: 3)
                for direction in 0..<4 {
                    let j = neighbor(i, direction)
                    if !donorAt(j) { continue }
                    count += 1
                    for channel in 0..<3 { sums[channel] += j >= 0 && j < n ? Double(p[j * 4 + channel]) : .nan }
                }
                for channel in 0..<3 { rgb[offset * 3 + channel] = Float(sums[channel] / Double(count)) }
            }
            for (offset, i) in frontier.enumerated() {
                for channel in 0..<3 { p[i * 4 + channel] = byte(rgb[offset * 3 + channel]) }
                mask[i] = 0
            }
            var next: [Int] = []
            for i in frontier { for direction in 0..<4 {
                let j = neighbor(i, direction)
                if j >= 0 && j < n && mask[j] != 0 && queued[j] == 0 { queued[j] = 1; next.append(j) }
            } }
            frontier = next
        }
    }

    /// Donors off the verified surface plane must continue through the erased region before lending their tint.
    static func contaminatedFrontDonors(p: [UInt8], w: Int, h: Int, queue: [Int], tail: Int,
                                        donorBlocked: [UInt8], paintMask: [UInt8], coefficients: [[Double]],
                                        strokes: [[Double]] = [], inks: [[Double]] = []) -> (indices: [Int], specks: [Int]) {
        guard w > 0, h > 0, w <= p.count / 4 / h, donorBlocked.count >= w * h, paintMask.count >= w * h,
              tail >= 0, tail <= queue.count, coefficients.count == 3,
              coefficients.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else { return ([], []) }
        let n = w * h
        func residual(_ i: Int, _ channel: Int) -> Double {
            let x = Double(i % w) / Double(w), y = Double(i / w) / Double(h), row = coefficients[channel]
            return Double(p[i * 4 + channel]) - (row[0] + row[1] * x + row[2] * y)
        }
        func size(_ i: Int) -> Double { max(abs(residual(i, 0)), abs(residual(i, 1)), abs(residual(i, 2))) }
        var seen = [UInt8](repeating: 0, count: n), front: [Int] = [], errors: [Double] = [], inward: [Int] = []
        for i in queue.prefix(tail) where i >= 0 && i < n {
            let x = i % w
            for direction in 0..<4 {
                if direction == 0 && x == 0 || direction == 1 && x == w - 1 { continue }
                let j = direction == 0 ? i - 1 : direction == 1 ? i + 1 : direction == 2 ? i - w : i + w
                if j < 0 || j >= n || seen[j] != 0 || paintMask[j] != 0 || donorBlocked[j] != 0 { continue }
                seen[j] = 1; front.append(j); errors.append(size(j))
                inward.append(direction == 0 ? 1 : direction == 1 ? -1 : direction == 2 ? w : -w)
            }
        }
        guard !front.isEmpty else { return ([], []) }
        let sorted = errors.sorted(), tolerance = max(16, sorted[sorted.count / 2] * 3)
        var result: [Int] = [], specks: [Int] = []
        for offset in front.indices {
            if errors[offset] <= tolerance { continue }
            let j = front[offset], step = inward[offset], horizontal = abs(step) == 1
            if strokes.contains(where: { distance(color(p, j), $0) <= 24 }) { continue }
            var at = j + step, continued = false
            while at >= 0 && at < n && paintMask[at] != 0 && (!horizontal || (at - step) % w != (step > 0 ? w - 1 : 0)) { at += step }
            if at >= 0 && at < n && paintMask[at] == 0 && donorBlocked[at] == 0 &&
                (!horizontal || abs(at % w - (at - step) % w) == 1) {
                continued = true
                for channel in 0..<3 {
                    let r = residual(j, channel), other = residual(at, channel)
                    if abs(r - other) > max(12, abs(r) * 0.4) { continued = false; break }
                }
            }
            if continued { continue }
            let r = (0..<3).map { residual(j, $0) }
            let x = j % w, y = j / w
            let inkward = inks.contains { ink in
                guard ink.count == 3 else { return false }
                let xx = Double(x) / Double(w), yy = Double(y) / Double(h)
                let d = (0..<3).map { ink[$0] - (coefficients[$0][0] + coefficients[$0][1] * xx + coefficients[$0][2] * yy) }
                let length = d[0] * d[0] + d[1] * d[1] + d[2] * d[2]
                if length < 1_600 { return false }
                let factor = (r[0] * d[0] + r[1] * d[1] + r[2] * d[2]) / length
                return factor >= 0.12 && max(abs(r[0] - factor * d[0]), abs(r[1] - factor * d[1]), abs(r[2] - factor * d[2])) <=
                    max(12, errors[offset] * 0.5)
            }
            if !inkward {
                var low = [Double](repeating: 255, count: 3), high = [Double](repeating: 0, count: 3)
                for yy in max(0, y - 1)...min(h - 1, y + 1) { for xx in max(0, x - 1)...min(w - 1, x + 1) {
                    let index = yy * w + xx
                    if paintMask[index] != 0 { continue }
                    for channel in 0..<3 {
                        low[channel] = min(low[channel], Double(p[index * 4 + channel]))
                        high[channel] = max(high[channel], Double(p[index * 4 + channel]))
                    }
                } }
                if max(high[0] - low[0], high[1] - low[1], high[2] - low[2]) < 24 { continue }
            }
            result.append(j)
            var structure = 0
            for yy in max(0, y - 1)...min(h - 1, y + 1) { for xx in max(0, x - 1)...min(w - 1, x + 1) {
                let index = yy * w + xx
                if index == j || paintMask[index] != 0 { continue }
                if donorBlocked[index] != 0 || size(index) > tolerance { structure += 1 }
            } }
            if structure <= 1 && x > 0 && y > 0 && x < w - 1 && y < h - 1 { specks.append(j) }
        }
        return (result, specks)
    }
}
