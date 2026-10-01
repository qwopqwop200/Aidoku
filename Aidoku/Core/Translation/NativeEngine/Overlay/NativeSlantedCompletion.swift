import Foundation

extension NativeSlantedRestoration {
    static func completeNativeFringe(_ page: Pixels, output: inout [UInt8], safe: inout [UInt8], fg: [Double], bg: [Double],
                                     coefficients: [[Double]], regions: [[Double]], auxiliary: [[Double]], vertical: Bool, lw: Int, lh: Int,
                                     cx: Double, cy: Double, c: Double, s: Double, ox: Double, oy: Double) -> Int {
        let axis = zip(fg, bg).map(-), norm = max(1, axis.reduce(0) { $0 + $1 * $1 })
        let raw = NativeSlantedPixels.rampPixels(page.rgba, n: page.count, axis: axis, bg: bg, scale: norm)
        let w = page.width, h = page.height
        var erased = 0
        func local(_ i: Int) -> (Double, Double) {
            let dx = Double(i % w) + 0.5 - cx, dy = Double(i / w) + 0.5 - cy
            return (dx * c + dy * s + ox, -dx * s + dy * c + oy)
        }
        for part in page.components(raw) {
            let tail = part.points.count, painted = part.points.filter { output[$0 * 4 + 3] != 0 }.count
            let transformed = part.points.map(local), ul = transformed.map(\.0).min()!, ut = transformed.map(\.1).min()!
            let ur = transformed.map(\.0).max()!, ub = transformed.map(\.1).max()!
            let inside = transformed.filter { u, v in regions.contains { u >= $0[0] - 2 && u <= $0[0] + $0[2] + 2 && v >= $0[1] - 2 && v <= $0[1] + $0[3] + 2 } }.count
            let left = Int(part.rect.minX), top = Int(part.rect.minY), right = Int(part.rect.maxX - 1), bottom = Int(part.rect.maxY - 1)
            var enclosedFringe = false
            if tail <= 16 && Double(painted) < Double(tail) * 0.85 && inside == tail {
                var contacts = 0, covered = 0, soft = true
                for i in part.points {
                    if NativeSlantedPixels.distance(page.rgba, i, fg) < 40 { soft = false }
                    for j in page.neighbors(i) where raw[j] == 0 { contacts += 1; if output[j * 4 + 3] != 0 { covered += 1 } }
                }
                enclosedFringe = soft && contacts >= 6 && Double(covered) >= Double(contacts) * 0.75
            }
            let compact = tail <= 128 && Double(painted) >= Double(tail) * 0.3 && inside == tail &&
                right - left <= 16 && bottom - top <= 16 && Double(tail) < Double((right - left + 1) * (bottom - top + 1)) * 0.8
            // Rectification can reduce a detached, antialiased stroke to one
            // already-owned native pixel. A seed alone is not enough: require
            // existing erasure beyond all four sides of this small component,
            // inside the same bounded donor neighborhood, before completing it.
            var enclosedStroke = false
            if w > 2 && h > 2 && tail <= 32 && painted > 0 && inside == tail && right - left <= 8 && bottom - top <= 8 {
                var sides = 0
                for y in max(1, top - 3)...min(h - 2, bottom + 3) {
                    for x in max(1, left - 3)...min(w - 2, right + 3) where output[(y * w + x) * 4 + 3] != 0 {
                        if x < left { sides |= 1 }; if x > right { sides |= 2 }
                        if y < top { sides |= 4 }; if y > bottom { sides |= 8 }
                    }
                }
                enclosedStroke = sides == 15
            }
            let small = tail <= 32 && (Double(painted) >= Double(tail) * 0.08 || enclosedStroke) &&
                inside == tail && right - left <= 8 && bottom - top <= 8
            var reading = false
            if w > 2 && h > 2 && vertical && tail >= 2 && tail <= 256 && inside == tail && ur - ul <= 14 && ub - ut <= 40 &&
                fg.max()! <= 100 && bg.min()! >= 220 && auxiliary.contains(where: {
                    ul >= $0[0] - 2 && ur <= $0[0] + $0[2] + 2 && ut >= $0[1] && ut <= $0[1] + $0[3] + 96
                }) {
                var support = 0
                for y in max(1, top - 20)...min(h - 2, bottom + 20) { for x in max(1, left - 20)...min(w - 2, right + 20) {
                    let i = y * w + x; guard output[i * 4 + 3] != 0 else { continue }
                    let (u, v) = local(i); if u >= ul - 16 && u < ul - 2 && v >= ut - 6 && v <= ub + 6 { support += 1 }
                } }
                reading = support >= 6
            }
            if !enclosedFringe && !compact && !small && !reading && Double(painted) < Double(tail) * 0.85 || Double(inside) < Double(tail) * 0.98 {
                let long = max(ur - ul, ub - ut) > min(ur - ul + 1, ub - ut + 1) * 12 ||
                    max(ur - ul, ub - ut) >= 40 && Double(tail) < (ur - ul + 1) * (ub - ut + 1) * 0.12
                if painted > 0 && tail >= 12 && Double(painted) < Double(tail) * 0.5 && long {
                    var untouched: [Int] = [], seen = Set<Int>()
                    for i in part.points { for j in page.neighbors(i) where seen.insert(j).inserted { untouched.append(j) } }
                    for i in untouched where output[i * 4 + 3] != 0 {
                        output[i * 4 + 3] = 0; erased -= 1
                        let (u, v) = local(i), xx = Int(floor(u - 0.5 + 0.5)), yy = Int(floor(v - 0.5 + 0.5))
                        if xx >= 0 && xx < lw && yy >= 0 && yy < lh { safe[yy * lw + xx] = 0 }
                    }
                }
                continue
            }
            for i in part.points where output[i * 4 + 3] == 0 {
                let x = i % w, y = i / w
                var donor = -1, distance = Double.infinity
                for yy in max(0, y - 3)...min(h - 1, y + 3) { for xx in max(0, x - 3)...min(w - 1, x + 3) {
                    let j = yy * w + xx, d = Double((x - xx) * (x - xx) + (y - yy) * (y - yy))
                    if output[j * 4 + 3] != 0 && d < distance { distance = d; donor = j }
                } }
                if donor < 0 && (reading || small) {
                    let (u, v) = local(i)
                    for k in 0..<3 { let a = coefficients[k]; output[i * 4 + k] = Pixels.clamp(a[0] + a[1] * (u / Double(lw)) + a[2] * (v / Double(lh))) }
                    output[i * 4 + 3] = 255; erased += 1
                }
                if donor >= 0 { for k in 0..<4 { output[i * 4 + k] = output[donor * 4 + k] }; erased += 1 }
            }
        }
        return erased
    }

    static func partiallyExposed(_ page: Pixels, output: [UInt8], box: [Double], foreground fg: [Double], background bg: [Double],
                                 cx: Double, cy: Double, c: Double, s: Double) -> Bool {
        let remaining = NativeSlantedPixels.exposedInk(page.rgba, output: output, w: page.width, h: page.height, box: box,
            cx: cx, cy: cy, c: c, s: s, foreground: fg, background: bg)
        guard remaining.count >= 3 else { return false }
        let axis = zip(fg, bg).map(-), scale = max(1, axis.reduce(0) { $0 + $1 * $1 })
        func ink(_ i: Int) -> Bool {
            let r0 = Double(page.rgba[i * 4]) - bg[0], r1 = Double(page.rgba[i * 4 + 1]) - bg[1], r2 = Double(page.rgba[i * 4 + 2]) - bg[2]
            let t = (0 + axis[0] * r0 + axis[1] * r1 + axis[2] * r2) / scale
            return t > 0.08 && t < 1.2 && max(abs(r0 - axis[0] * t), abs(r1 - axis[1] * t), abs(r2 - axis[2] * t)) <= 24
        }
        var seen = [UInt8](repeating: 0, count: page.count)
        for start in remaining where seen[start] == 0 {
            var queue = [start], head = 0, cores = 0, painted = 0; seen[start] = 1
            while head < queue.count {
                let i = queue[head]; head += 1
                if NativeSlantedPixels.distance(page.rgba, i, fg) <= 36 { cores += 1; if output[i * 4 + 3] != 0 { painted += 1 } }
                for j in page.neighbors(i) where seen[j] == 0 && ink(j) { seen[j] = 1; queue.append(j) }
            }
            if cores - painted >= 3 && Double(painted) > Double(cores) * 0.5 { return true }
        }
        return false
    }

    static func closeProofSeams(safe: inout [UInt8], luminance: [UInt8], restored: [UInt8], w: Int, h: Int) {
        var visited = [UInt8](repeating: 0, count: w * h)
        for start in 0..<safe.count where safe[start] == 0 && visited[start] == 0 {
            var cells = [start], head = 0, closed = true, low: UInt8 = 255, high: UInt8 = 0; visited[start] = 1
            while head < cells.count {
                let i = cells[head], x = i % w, y = i / w; head += 1
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { closed = false }
                for yy in max(0, y - 1)...min(h - 1, y + 1) { for xx in max(0, x - 1)...min(w - 1, x + 1) {
                    let j = yy * w + xx
                    if safe[j] != 0 { low = min(low, luminance[j]); high = max(high, luminance[j]) }
                    else if visited[j] == 0 { visited[j] = 1; cells.append(j) }
                } }
            }
            let fringe = cells.count == 1 && [-w - 1, -w, -w + 1, -1, 1, w - 1, w, w + 1].filter { d in
                let i = cells[0] + d; return i >= 0 && i < safe.count && restored[i * 4 + 3] == 255
            }.count >= 3
            if closed && cells.count <= 3 && low <= high && (fringe || cells.allSatisfy {
                Int(luminance[$0]) >= Int(low) - 4 && Int(luminance[$0]) <= Int(high) + 4
            }) { for i in cells { safe[i] = 1 } }
        }
    }
}
