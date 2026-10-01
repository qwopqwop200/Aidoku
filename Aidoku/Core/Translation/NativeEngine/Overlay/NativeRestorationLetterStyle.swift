import CoreGraphics
import Foundation

extension NativeRestorationPixels {
    struct LetterStyle {
        let serif: Bool
        let weight: Double
        let horizontalCount: Int
        let verticalCount: Int
    }

    /// Measured source stroke flares, with the same run-thickness thresholds as the
    /// legacy mincho/Latin-serif classifier. Typography roles are never used as evidence.
    static func letterStyle(_ p: Self, glyph: CGFloat) -> LetterStyle? {
        guard glyph >= 24, glyph <= 240, p.width >= 12, p.height >= 12, p.count <= 65_536 else { return nil }
        var luminance = [Float](repeating: 0, count: p.count), histogram = [Int](repeating: 0, count: 256)
        for index in 0..<p.count {
            let offset = index * 4
            let value = (Double(p.rgba[offset]) * 299 + Double(p.rgba[offset + 1]) * 587 + Double(p.rgba[offset + 2]) * 114) / 1000
            luminance[index] = Float(value); histogram[min(255, Int(floor(value + 0.5)))] += 1
        }
        func percentile(_ q: Double) -> Double {
            var cumulative = 0
            for value in 0..<256 { cumulative += histogram[value]; if Double(cumulative) >= q * Double(p.count) { return Double(value) } }
            return 255
        }
        let low = percentile(0.03), high = percentile(0.97)
        guard high - low >= 60 else { return LetterStyle(serif: false, weight: 0, horizontalCount: 0, verticalCount: 0) }
        var inkCount = 0
        var alpha = luminance.map { value -> Float in
            let fraction = min(1, max(0, (high - Double(value)) / (high - low)))
            if fraction > 0.5 { inkCount += 1 }
            return Float(fraction)
        }
        if Double(inkCount) > Double(p.count) / 2 {
            inkCount = 0
            alpha = alpha.map { value -> Float in
                let inverted = Float(1 - Double(value))
                if inverted > 0.5 { inkCount += 1 }
                return inverted
            }
        }
        let ink = alpha.map { $0 > 0.5 }
        let fraction = Double(inkCount) / Double(p.count)
        guard fraction >= 0.03, fraction <= 0.6 else { return LetterStyle(serif: false, weight: 0, horizontalCount: 0, verticalCount: 0) }
        var horizontalThickness = [Float](repeating: 0, count: p.count), verticalThickness = horizontalThickness
        var horizontalRuns: [(Int, Int, Int)] = [], verticalRuns: [(Int, Int, Int)] = []
        for y in 0..<p.height {
            var x = 0
            while x < p.width {
                guard ink[y * p.width + x] else { x += 1; continue }
                let start = x
                while x < p.width && ink[y * p.width + x] { x += 1 }
                let sum = (max(0, start - 1)..<min(p.width, x + 1)).reduce(0.0) { $0 + Double(alpha[y * p.width + $1]) }
                for at in start..<x { horizontalThickness[y * p.width + at] = Float(sum) }
                horizontalRuns.append((y, start, x))
            }
        }
        for x in 0..<p.width {
            var y = 0
            while y < p.height {
                guard ink[y * p.width + x] else { y += 1; continue }
                let start = y
                while y < p.height && ink[y * p.width + x] { y += 1 }
                let sum = (max(0, start - 1)..<min(p.height, y + 1)).reduce(0.0) { $0 + Double(alpha[$1 * p.width + x]) }
                for at in start..<y { verticalThickness[at * p.width + x] = Float(sum) }
                verticalRuns.append((x, start, y))
            }
        }
        func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
        func strokes(_ runs: [(Int, Int, Int)], horizontal: Bool) -> (Int, Double, Double) {
            var flares: [Double] = [], mids: [Double] = []
            for (line, start, end) in runs {
                let length = end - start
                guard CGFloat(length) >= max(6, glyph * 0.28) else { continue }
                let edge = max(2, Int(floor(Double(length) * 0.15)))
                var core: [Double] = [], head = 0.0, tail = 0.0
                for at in start..<end {
                    let value = Double(horizontal ? verticalThickness[line * p.width + at] : horizontalThickness[at * p.width + line])
                    guard value < Double(glyph * 0.22) else { continue }
                    core.append(value)
                    if at - start < edge { head = max(head, value) }
                    if end - 1 - at < edge { tail = max(tail, value) }
                }
                guard Double(core.count) >= Double(length) / 2 else { continue }
                let mid = median(core)
                guard mid <= Double(length) / 4 else { continue }
                let far = max(head, tail)
                if far > 0 { flares.append(far / max(mid, 0.5)); mids.append(mid) }
            }
            return (flares.count, median(flares), median(mids))
        }
        let across = strokes(horizontalRuns, horizontal: true), stems = strokes(verticalRuns, horizontal: false)
        let thin = max(across.2, 0.3)
        let mincho = across.0 >= 7 && across.1 >= 1.9 && stems.2 >= 2.4 * thin && across.2 <= 0.035 * Double(glyph)
        let latinSerif = stems.0 >= 30 && stems.1 >= 1.35 && across.1 >= 1.8 && stems.2 >= 1.6 * thin
        let weight = stems.0 >= 6 ? floor(stems.2 / Double(glyph) * 1000 + 0.5) / 1000 : 0
        return LetterStyle(serif: mincho || latinSerif, weight: weight, horizontalCount: across.0, verticalCount: stems.0)
    }
}
