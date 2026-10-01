import CoreGraphics
import Foundation

/// The shared finish of the browser's enclosed-paper kernel and scalar path.
enum NativeEnclosedPaperFinish {
    struct Result {
        var rgba: [UInt8]
        var safe: [UInt8]
        var erased: Int
    }

    static func finish(source: [UInt8], width: Int, height: Int, core: CGRect,
                       auxiliary: [CGRect], rgba: [UInt8], safe: [UInt8]) -> Result? {
        guard width > 0, height > 0, width <= 262_144 / height else { return nil }
        let count = width * height
        guard source.count == count * 4, rgba.count == count * 4, safe.count == count else { return nil }
        var out = rgba, layoutSafe = safe, seen = [UInt8](repeating: 0, count: count)
        let owned = [core] + auxiliary, reach = max(3, min(core.width, core.height) * 0.25)
        func inside(_ index: Int, margin: CGFloat) -> Bool {
            let x = CGFloat(index % width), y = CGFloat(index / width)
            return owned.contains { x >= $0.minX - margin && x < $0.maxX + margin &&
                y >= $0.minY - margin && y < $0.maxY + margin }
        }
        func neighbors(_ index: Int) -> [Int] {
            let x = index % width, y = index / width
            return (max(0, y - 1)...min(height - 1, y + 1)).flatMap { yy in
                (max(0, x - 1)...min(width - 1, x + 1)).map { yy * width + $0 }
            }
        }
        func component(_ start: Int, opaque: Bool) -> [Int] {
            var queue = [start], head = 0
            seen[start] = 1
            while head < queue.count {
                let index = queue[head]; head += 1
                for next in neighbors(index) where seen[next] == 0 &&
                    (opaque ? out[next * 4 + 3] == 255 : out[next * 4 + 3] != 0) {
                    seen[next] = 1; queue.append(next)
                }
            }
            return queue
        }
        var erased = 0
        for start in 0..<count where out[start * 4 + 3] != 0 && seen[start] == 0 {
            let part = component(start, opaque: false)
            if part.allSatisfy({ inside($0, margin: reach) }) { erased += part.count; continue }
            var failed = false
            for index in part {
                out[index * 4 + 3] = 0; layoutSafe[index] = 0
                if inside(index, margin: 0) { failed = true }
            }
            if failed { return nil }
        }
        guard erased >= 8 else { return nil }
        func paper(_ index: Int) -> Bool {
            let k = index * 4
            return source[k + 3] >= 254 && min(source[k], source[k + 1], source[k + 2]) >= 232 &&
                Int(max(source[k], source[k + 1], source[k + 2])) - Int(min(source[k], source[k + 1], source[k + 2])) <= 12
        }
        seen = [UInt8](repeating: 0, count: count)
        for start in 0..<count where out[start * 4 + 3] == 255 && seen[start] == 0 {
            let part = component(start, opaque: true)
            var donors = Set<Int>(), samples = [[UInt8]](repeating: [], count: 3)
            for index in part {
                let x = index % width, y = index / width
                for yy in max(0, y - 4)...min(height - 1, y + 4) {
                    for xx in max(0, x - 4)...min(width - 1, x + 4) {
                        let next = yy * width + xx
                        guard max(abs(xx - x), abs(yy - y)) >= 2, !donors.contains(next),
                              out[next * 4 + 3] == 0, paper(next),
                              !neighbors(next).contains(where: { out[$0 * 4 + 3] == 255 }) else { continue }
                        donors.insert(next)
                        for channel in 0..<3 { samples[channel].append(source[next * 4 + channel]) }
                    }
                }
            }
            guard samples[0].count >= 4 else { continue }
            let color = samples.map { $0.sorted()[$0.count / 2] }
            for index in part { for channel in 0..<3 { out[index * 4 + channel] = color[channel] } }
        }
        for _ in 0..<2 {
            var ring: [(Int, [Double])] = []
            for index in 0..<count where out[index * 4 + 3] == 0 && paper(index) {
                let adjacent = neighbors(index).filter { out[$0 * 4 + 3] == 255 }
                guard !adjacent.isEmpty else { continue }
                ring.append((index, (0..<3).map { channel in
                    adjacent.reduce(0) { $0 + Double(out[$1 * 4 + channel]) } / Double(adjacent.count)
                }))
            }
            for (index, color) in ring {
                for channel in 0..<3 {
                    out[index * 4 + channel] = UInt8(min(255, max(0, color[channel].rounded(.toNearestOrEven))))
                }
                out[index * 4 + 3] = 254
            }
            for (index, _) in ring { out[index * 4 + 3] = 255 }
        }
        return Result(rgba: out, safe: layoutSafe, erased: erased)
    }
}
