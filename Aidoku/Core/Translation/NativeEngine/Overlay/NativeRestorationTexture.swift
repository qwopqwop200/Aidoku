import CoreGraphics
import Foundation

extension NativeRestorationPixels {
    struct Period {
        let x: Int
        let y: Int
        let error: Double
        let outliers: Double
        let deviation: Double
    }

    static func periodicEvidence(_ p: Self, points: [Int], box: CGRect) -> Bool {
        guard points.count >= 64 else { return false }
        var map = [UInt8](repeating: 0, count: p.count), inside: [Int] = [], outside: [Int] = []
        for index in points {
            let own = box.contains(CGPoint(x: index % p.width, y: index / p.width))
            map[index] = own ? 1 : 2
            if own { inside.append(index) } else { outside.append(index) }
        }
        guard inside.count >= 32, outside.count >= 32, Double(inside.count) >= box.width * box.height * 0.004 else { return false }
        let groups = [inside, outside].map { list in
            list.enumerated().filter { $0.offset % max(1, Int(ceil(Double(list.count) / 256))) == 0 }.map(\.element)
        }
        var vectors: [(Int, Int)] = []
        for dx in 0...8 {
            for dy in -8...8 {
                let length = hypot(Double(dx), Double(dy))
                guard length >= 3, length <= 9, dx != 0 || dy >= 0 else { continue }
                var support: [Double] = []
                for (k, group) in groups.enumerated() {
                    var total = 0, matches = 0
                    for index in group {
                        let x = index % p.width + dx, y = index / p.width + dy
                        guard x >= 1, y >= 1, x < p.width - 1, y < p.height - 1 else { continue }
                        total += 1
                        if p.neighbors(y * p.width + x).contains(where: { map[$0] == UInt8(k + 1) }) { matches += 1 }
                    }
                    support.append(Double(matches) / Double(max(1, total)))
                }
                guard support.min()! >= 0.6 else { continue }
                if vectors.contains(where: { vector in
                    abs(Double(vector.0 * dx + vector.1 * dy)) / (hypot(Double(vector.0), Double(vector.1)) * length) < 0.75
                }) { return true }
                vectors.append((dx, dy))
            }
        }
        return false
    }

    /// Continue two independently witnessed texture periods, using only mutually agreeing
    /// original donor pixels. One unrecoverable pixel rejects the complete proposal.
    static func periodicFill(_ p: Self, mask: [UInt8], blocked: [UInt8], halftone: Bool, texturePoints: [Int]) -> Self? {
        var valid = [UInt8](repeating: 0, count: p.count), supported = valid
        let stride = max(1, Int(ceil(sqrt(Double(p.count) / 768))))
        var samples: [Int] = [], total = 0
        let tone = texturePoints.reduce(0.0) { $0 + Double(p.rgba[$1 * 4 + 1]) } / Double(max(1, texturePoints.count))
        if halftone {
            for index in texturePoints {
                let x = index % p.width, y = index / p.width
                for yy in max(3, y - 3)..<min(p.height - 3, y + 4) {
                    for xx in max(3, x - 3)..<min(p.width - 3, x + 4) { supported[yy * p.width + xx] = 1 }
                }
            }
        }
        guard p.width > 6, p.height > 6 else { return nil }
        for y in 3..<p.height - 3 {
            for x in 3..<p.width - 3 {
                let index = y * p.width + x
                guard mask[index] == 0, blocked[index] == 0, !halftone || supported[index] != 0 else { continue }
                valid[index] = 1; total += 1
                if x % stride == 0, y % stride == 0 { samples.append(index) }
            }
        }
        guard total >= 256, samples.count >= 96 else { return nil }
        let probes = samples.enumerated().filter { $0.offset % max(1, Int(ceil(Double(samples.count) / 192))) == 0 }.map(\.element)
        func evaluate(_ dx: Int, _ dy: Int, _ list: [Int], limit: Double = .infinity) -> Period? {
            var count = 0, error = 0.0, outliers = 0, sum = 0.0, squared = 0.0
            for index in list {
                let x = index % p.width + dx, y = index / p.width + dy
                guard x >= 3, y >= 3, x < p.width - 3, y < p.height - 3 else { continue }
                let next = y * p.width + x
                guard valid[next] != 0 else { continue }
                let distance = p.color(index).distance(p.color(next))
                count += 1; error += min(64, distance)
                if error > Double(list.count) * limit { return nil }
                if distance > 12 { outliers += 1 }
                let value = Double(p.rgba[index * 4 + 1]); sum += value; squared += value * value
            }
            guard Double(count) >= max(32, Double(list.count) * 0.12) else { return nil }
            let deviation = sqrt(max(0, squared / Double(count) - pow(sum / Double(count), 2)))
            return Period(x: dx, y: dy, error: error / Double(count), outliers: Double(outliers) / Double(count), deviation: deviation)
        }
        var coarse: [Period] = []
        for dy in Swift.stride(from: 0, through: min(64, p.height / 2), by: halftone ? 1 : 2) {
            for dx in Swift.stride(from: -min(128, p.width / 2), through: min(128, p.width / 2), by: halftone ? 1 : 2) {
                guard !(dy == 0 && dx <= 0), max(abs(dx), dy) >= 8 else { continue }
                if let period = evaluate(dx, dy, probes, limit: halftone ? 12 : 2.5), period.error <= (halftone ? 12 : 2.5),
                   period.deviation >= 3, period.outliers <= (halftone ? 0.3 : 0.02) { coarse.append(period) }
            }
        }
        func ordered(_ a: Period, _ b: Period) -> Bool {
            a.error != b.error ? a.error < b.error : halftone && hypot(Double(a.x), Double(a.y)) < hypot(Double(b.x), Double(b.y))
        }
        coarse.sort(by: ordered)
        var refined: [Period] = [], visited = Set<String>()
        for candidate in coarse.prefix(halftone ? 96 : 24) {
            for dy in candidate.y - 1...candidate.y + 1 {
                for dx in candidate.x - 1...candidate.x + 1 {
                    guard dy >= 0, !(dy == 0 && dx <= 0), visited.insert("\(dx),\(dy)").inserted,
                          let period = evaluate(dx, dy, samples), period.error <= (halftone ? 9 : 1.5),
                          period.deviation >= 3, period.outliers <= (halftone ? 0.2 : 0.01),
                          let first = evaluate(dx + 4, dy, samples), let second = evaluate(dx, dy + 4, samples),
                          first.error >= period.error * (halftone ? 1.25 : 1.5) + 1,
                          second.error >= period.error * (halftone ? 1.25 : 1.5) + 1 else { continue }
                    refined.append(period)
                }
            }
        }
        refined.sort(by: ordered)
        var vectors: [Period] = []
        func independent(_ a: Period, _ b: Period) -> Bool {
            abs(Double(a.x * b.y - a.y * b.x)) > hypot(Double(a.x), Double(a.y)) * hypot(Double(b.x), Double(b.y)) * 0.2
        }
        if halftone, let first = refined.first, let second = refined.first(where: { independent(first, $0) }) { vectors = [first, second] }
        for period in refined {
            guard !vectors.contains(where: { hypot(Double($0.x - period.x), Double($0.y - period.y)) < 6 }) else { continue }
            vectors.append(period)
            if vectors.count == 6 { break }
        }
        guard vectors.count >= 2, vectors.contains(where: { independent(vectors[0], $0) }) else { return nil }
        var shifts: [Period] = []
        for vector in vectors {
            for scale in [1, -1, 2, -2, 3, -3, 4, -4] {
                shifts.append(Period(x: vector.x * scale, y: vector.y * scale, error: vector.error * Double(abs(scale)),
                                     outliers: 0, deviation: 0))
            }
        }
        for shift in shifts {
            for scale in [-2, -1, 1, 2] {
                let dx = shift.x + vectors[0].x * scale, dy = shift.y + vectors[0].y * scale
                if abs(dx) < p.width - 6, abs(dy) < p.height - 6, !shifts.contains(where: { $0.x == dx && $0.y == dy }) {
                    shifts.append(Period(x: dx, y: dy, error: shift.error + vectors[0].error * Double(abs(scale)), outliers: 0, deviation: 0))
                }
            }
        }
        shifts.sort { $0.error < $1.error }
        var output = Self(width: p.width, height: p.height)
        for index in 0..<p.count where mask[index] != 0 {
            var donors: [Int] = []
            for shift in shifts {
                let x = index % p.width + shift.x, y = index / p.width + shift.y
                guard x >= 3, y >= 3, x < p.width - 3, y < p.height - 3 else { continue }
                let next = y * p.width + x
                guard valid[next] != 0, !donors.contains(next) else { continue }
                donors.append(next)
                if donors.count == (halftone ? 12 : 6) { break }
            }
            var pair: (Int, Int)?, shade = Double.infinity
            for a in donors.indices {
                for b in donors.indices where b > a {
                    guard p.color(donors[a]).distance(p.color(donors[b])) <= (halftone ? 24 : 6) else { continue }
                    let value = abs((Double(p.rgba[donors[a] * 4 + 1]) + Double(p.rgba[donors[b] * 4 + 1])) / 2 - tone)
                    if value < shade { pair = (donors[a], donors[b]); shade = value }
                    if !halftone { break }
                }
                if !halftone, pair != nil { break }
            }
            guard let pair else { return nil }
            // Math.round in the periodic legacy helper rounds half upwards.
            output.paint(index, NativeRestorationRGB((0..<3).map {
                floor((Double(p.rgba[pair.0 * 4 + $0]) + Double(p.rgba[pair.1 * 4 + $0])) / 2 + 0.5)
            }))
        }
        output.surfaceQuality = ["vectors": vectors.map { [$0.x, $0.y] }, "repetitionError": vectors[0].error]
        return output
    }

    /// Stationary grain synthesis: compare 9x9 residual patches after subtracting the
    /// observed RGB gradient, copy original donors, and validate seams and texture energy.
    static func exemplarFill(_ p: Self, mask: [UInt8], blocked: [UInt8], palette: Palette, surface: Surface) -> Self? {
        nativeExemplarFill(p, mask: mask, blocked: blocked, palette: palette, surface: surface)
    }
}
