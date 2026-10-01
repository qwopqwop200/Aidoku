import CoreGraphics
import Foundation

/// aidokuCompleteConnectedLettering. Only source-colored parts connected to
/// already erased lettering can join a repair; long rules and non-flat donor
/// rings remain original pixels. The output is the caller's transparent patch.
enum NativeConnectedLettering {
    static func complete(original p: NativeRestorationPixels, box: CGRect, restored: inout NativeRestorationPixels,
                         exclusions: [CGRect] = [], vertical: Bool? = nil) -> Int {
        let w = p.width, h = p.height, n = p.count, original = p.rgba
        guard w > 0, h > 0, n <= 1_000_000, restored.rgba.count == n * 4, original.count == n * 4,
              [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) else { return 0 }
        let l = max(1, Int(floor(box.minX))), t = max(1, Int(floor(box.minY)))
        let r = min(w - 1, Int(ceil(box.maxX))), bottom = min(h - 1, Int(ceil(box.maxY)))
        if r - l < 6 || bottom - t < 6 { return 0 }
        var out = restored.rgba
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3), fillHist = hist
        var erasedInk = [UInt8](repeating: 0, count: n), inkCount = 0
        for i in 0..<n where out[i * 4 + 3] != 0 {
            var difference = 0
            for c in 0..<3 { difference = max(difference, abs(Int(original[i * 4 + c]) - Int(out[i * 4 + c]))) }
            if difference < 48 { continue }
            erasedInk[i] = 1; inkCount += 1
            for c in 0..<3 { hist[c][Int(original[i * 4 + c])] += 1; fillHist[c][Int(out[i * 4 + c])] += 1 }
        }
        if inkCount < 16 { return 0 }
        func median(_ values: [Int]) -> Double {
            let half = Double(inkCount) / 2; var accumulated = 0
            for v in 0..<256 { accumulated += values[v]; if Double(accumulated) >= half { return Double(v) } }
            return 255
        }
        let ink = hist.map(median), fill = fillHist.map(median)
        let separation = (0..<3).map { abs(ink[$0] - fill[$0]) }.max() ?? 0
        if separation < 48 { return 0 }
        let tolerance = max(24, separation * 0.45)
        var candidate = [UInt8](repeating: 0, count: n), inside = 0
        for i in 0..<n where out[i * 4 + 3] == 0 {
            let di = NativeResidualProof.pixelDistance(original, i, ink), df = NativeResidualProof.pixelDistance(original, i, fill)
            if di <= tolerance && df >= separation * 0.5 {
                candidate[i] = 1
                let x = i % w, y = i / w
                if x >= l && x < r && y >= t && y < bottom { inside += 1 }
            }
        }
        func inkish(_ j: Int) -> Bool {
            out[j * 4 + 3] == 0 && NativeResidualProof.pixelDistance(original, j, ink) <= separation * 0.85
        }
        if Double(inside) < max(12, Double(inkCount) * 0.03) { return 0 }
        func chamfer(_ member: [UInt8]) -> [Int] {
            var distance = member.map { $0 == 0 ? 0 : 65_535 }
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x; if distance[i] == 0 { continue }; var v = distance[i]
                    if x > 0 { v = min(v, distance[i - 1] + 3) } else { v = min(v, 3) }
                    if y > 0 {
                        v = min(v, distance[i - w] + 3)
                        if x > 0 { v = min(v, distance[i - w - 1] + 4) }; if x < w - 1 { v = min(v, distance[i - w + 1] + 4) }
                    } else { v = min(v, 3) }; distance[i] = v
                }
            }
            for y in stride(from: h - 1, through: 0, by: -1) {
                for x in stride(from: w - 1, through: 0, by: -1) {
                    let i = y * w + x; if distance[i] == 0 { continue }; var v = distance[i]
                    if x < w - 1 { v = min(v, distance[i + 1] + 3) } else { v = min(v, 3) }
                    if y < h - 1 {
                        v = min(v, distance[i + w] + 3)
                        if x < w - 1 { v = min(v, distance[i + w + 1] + 4) }; if x > 0 { v = min(v, distance[i + w - 1] + 4) }
                    } else { v = min(v, 3) }; distance[i] = v
                }
            }; return distance
        }
        let erasedDistance = chamfer(erasedInk)
        let sum = (0..<n).reduce(0) { $0 + (erasedInk[$1] != 0 ? erasedDistance[$1] : 0) }
        let stroke = max(2, 4 * Double(sum) / Double(inkCount) / 3)
        let radius = max(1, min(3, Int(floor(stroke * 0.2 + 0.5))))
        let distance = chamfer(candidate), core = distance.map { $0 > radius * 3 ? UInt8(1) : 0 }
        let reach = chamfer(core.map { $0 != 0 ? UInt8(0) : 1 })
        let opened = (0..<n).map { candidate[$0] != 0 && reach[$0] <= radius * 3 + 2 ? UInt8(1) : 0 }
        var label = [Int](repeating: 0, count: n), ringMark = [UInt8](repeating: 0, count: n)
        var accepted = 0, acceptedInk = 0, fillSet = [UInt8](repeating: 0, count: n)
        let thickness = min(box.width, box.height), horizontal = vertical.map { !$0 } ?? (box.width >= box.height)
        var profile = [Int](repeating: 0, count: horizontal ? h : w), peak = 0
        for i in 0..<n where erasedInk[i] != 0 {
            let x = i % w, y = i / w
            if x < l || x >= r || y < t || y >= bottom { continue }
            let k = horizontal ? y : x; profile[k] += 1; peak = max(peak, profile[k])
        }
        let onLine = profile.map { Double($0) >= max(2, Double(peak) * 0.05) }
        var excluded = [UInt8](repeating: 0, count: n)
        for a in exclusions where [a.minX, a.minY, a.width, a.height].allSatisfy(\.isFinite) {
            let y0 = max(0, Int(floor(a.minY))), y1 = min(h, Int(ceil(a.maxY)))
            let x0 = max(0, Int(floor(a.minX))), x1 = min(w, Int(ceil(a.maxX)))
            if y0 >= y1 || x0 >= x1 { continue }
            for y in y0..<y1 { for x in x0..<x1 { excluded[y * w + x] = 1 } }
        }
        func neighbors(_ i: Int, radius: Int = 1, bounds: CGRect? = nil) -> [Int] {
            let x = i % w, y = i / w
            let x0 = max(bounds.map { Int($0.minX) } ?? 0, x - radius), x1 = min(bounds.map { Int($0.maxX) } ?? (w - 1), x + radius)
            let y0 = max(bounds.map { Int($0.minY) } ?? 0, y - radius), y1 = min(bounds.map { Int($0.maxY) } ?? (h - 1), y + radius)
            if x0 > x1 || y0 > y1 { return [] }
            return (y0...y1).flatMap { yy in (x0...x1).map { yy * w + $0 } }
        }
        struct Part { let points: [Int]; let small: Bool }
        var nextLabel = 0, parts: [Part] = []
        for start in 0..<n where opened[start] != 0 && label[start] == 0 {
            nextLabel += 1; var queue = [start], head = 0, x0 = w, x1 = -1, y0 = h, y1 = -1, inBody = 0, thick = 0, touchesExclusion = false
            label[start] = nextLabel
            while head < queue.count {
                let i = queue[head], x = i % w, y = i / w; head += 1
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                if x >= l && x < r && y >= t && y < bottom { inBody += 1 }; thick = max(thick, distance[i])
                touchesExclusion = touchesExclusion || excluded[i] != 0
                for j in neighbors(i) where opened[j] != 0 && label[j] == 0 { label[j] = nextLabel; queue.append(j) }
            }
            let slack = max(2, stroke * 0.25), lined = queue.filter { onLine[horizontal ? $0 / w : $0 % w] }.count
            if queue.count < 8 || Double(inBody) < Double(queue.count) * 0.9 || touchesExclusion ||
                Double(x0) < Double(l) - slack || Double(x1) >= Double(r) + slack || Double(y0) < Double(t) - slack ||
                Double(y1) >= Double(bottom) + slack || Double(thick) > (stroke * 0.75 + 1.5) * 3 ||
                Double(thick) < stroke || CGFloat(max(x1 - x0 + 1, y1 - y0 + 1)) > thickness * 1.4 ||
                Double(lined) < Double(queue.count) * 0.7 { continue }
            parts.append(Part(points: queue, small: Double(queue.count) < stroke * stroke * 0.5))
        }
        if parts.isEmpty { return 0 }
        var runLeft = [Int](repeating: 0, count: n), runRight = runLeft, runTop = runLeft, runBottom = runLeft
        for y in 0..<h {
            var start = -1
            for x in 0...w {
                let on = x < w && candidate[y * w + x] != 0
                if on && start < 0 { start = x }
                if !on && start >= 0 { for k in start..<x { runLeft[y * w + k] = start; runRight[y * w + k] = x - 1 }; start = -1 }
            }
        }
        for x in 0..<w {
            var start = -1
            for y in 0...h {
                let on = y < h && candidate[y * w + x] != 0
                if on && start < 0 { start = y }
                if !on && start >= 0 { for k in start..<y { runTop[k * w + x] = start; runBottom[k * w + x] = y - 1 }; start = -1 }
            }
        }
        func runAlong(_ x: Int, _ y: Int, _ horizontalRun: Bool) -> Int {
            var count = 1
            if horizontalRun {
                var xx = x - 1; while xx >= 0 && candidate[y * w + xx] != 0 { count += 1; xx -= 1 }
                xx = x + 1; while xx < w && candidate[y * w + xx] != 0 { count += 1; xx += 1 }
            } else {
                var yy = y - 1; while yy >= 0 && candidate[yy * w + x] != 0 { count += 1; yy -= 1 }
                yy = y + 1; while yy < h && candidate[yy * w + x] != 0 { count += 1; yy += 1 }
            }; return count
        }
        func consider(_ part: Part) {
            let points = part.points.filter { fillSet[$0] != 1 }; if points.isEmpty { return }
            var region = points
            for i in points { fillSet[i] = 2 }
            let armSteps = max(radius + 3, Int(floor(stroke * 3 + 0.5))), armThickness = max(3, stroke * 0.5)
            let inner = CGRect(x: l + 2, y: t + 2, width: max(0, r - 3 - (l + 2)), height: max(0, bottom - 3 - (t + 2)))
            var head = 0, end = region.count
            for step in 0..<armSteps {
                if head >= region.count { break }
                while head < end {
                    let i = region[head]; head += 1
                    for j in neighbors(i, bounds: inner) {
                        if fillSet[j] != 0 || candidate[j] == 0 || step >= radius + 3 && Double(distance[j]) < armThickness { continue }
                        fillSet[j] = 2; region.append(j)
                    }
                }; end = region.count
            }
            var from = 0
            for _ in 0..<3 {
                let end = region.count
                for m in from..<end { for j in neighbors(region[m], bounds: inner) where fillSet[j] == 0 && candidate[j] != 0 { fillSet[j] = 2; region.append(j) } }
                from = end
            }
            from = 0
            for _ in 0..<3 {
                let end = region.count
                for m in from..<end {
                    let i = region[m], x = i % w, y = i / w
                    for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                        let xx = x + dx, yy = y + dy
                        if xx < l || xx >= r || yy < t || yy >= bottom { continue }
                        let j = yy * w + xx
                        if fillSet[j] != 0 || candidate[j] == 0 { continue }
                        let topBottom = yy < t + 2 || yy >= bottom - 2, sideways = xx < l + 2 || xx >= r - 2
                        if !topBottom && !sideways || topBottom && dx != 0 || sideways && dy != 0 || Double(runAlong(xx, yy, topBottom)) > stroke * 2 { continue }
                        fillSet[j] = 2; region.append(j)
                    }
                }; from = end
            }
            for i in Array(region) {
                for j in neighbors(i, radius: 2) where fillSet[j] == 0 && out[j * 4 + 3] == 0 && candidate[j] == 0 && inkish(j) { fillSet[j] = 2; region.append(j) }
            }
            for i in Array(region) {
                for j in neighbors(i, radius: 2) where fillSet[j] == 0 && out[j * 4 + 3] == 0 && !inkish(j) { fillSet[j] = 2; region.append(j) }
            }
            let actualInk = region.filter { candidate[$0] != 0 }
            let px0 = actualInk.map { $0 % w }.min() ?? w, px1 = actualInk.map { $0 % w }.max() ?? -1
            let py0 = actualInk.map { $0 / w }.min() ?? h, py1 = actualInk.map { $0 / w }.max() ?? -1
            let reachOut = max(3, stroke)
            region = region.filter { i in
                if candidate[i] != 0 && (Double(runLeft[i]) < Double(px0) - reachOut || Double(runRight[i]) > Double(px1) + reachOut ||
                    Double(runTop[i]) < Double(py0) - reachOut || Double(runBottom[i]) > Double(py1) + reachOut) { fillSet[i] = 0; return false }
                return true
            }
            var ring: [Int] = []
            for i in region { for j in neighbors(i) where fillSet[j] == 0 && ringMark[j] == 0 { ringMark[j] = 1; ring.append(j) } }
            for j in ring { ringMark[j] = 0 }
            var ringInk = 0, colors: [[Double]] = []
            for j in ring {
                if inkish(j) { ringInk += 1; continue }
                let source = out[j * 4 + 3] != 0 ? out : original
                colors.append((0..<3).map { Double(source[j * 4 + $0]) })
            }
            var flat = colors.count >= 12 && Double(ringInk) <= Double(ring.count) * 0.25
            if flat {
                func gap(_ a: [Double], _ b: [Double]) -> Double { (0..<3).map { abs(a[$0] - b[$0]) }.max() ?? 0 }
                var mean = [Double](repeating: 0, count: 3)
                for rgb in colors { for c in 0..<3 { mean[c] += rgb[c] / Double(colors.count) } }
                func far(_ source: [Double]) -> [Double] {
                    var best = -1.0, at = 0
                    for k in colors.indices { let d = gap(colors[k], source); if d > best { best = d; at = k } }; return colors[at]
                }
                var centers = [far(mean)]; centers.append(far(centers[0]))
                for _ in 0..<4 {
                    var sums = [Double](repeating: 0, count: 8)
                    for rgb in colors { let o = gap(rgb, centers[0]) <= gap(rgb, centers[1]) ? 0 : 4; for c in 0..<3 { sums[o + c] += rgb[c] }; sums[o + 3] += 1 }
                    for c in 0..<2 where sums[c * 4 + 3] != 0 { centers[c] = (0..<3).map { sums[c * 4 + $0] / sums[c * 4 + 3] } }
                }
                let near = colors.filter { min(gap($0, centers[0]), gap($0, centers[1])) <= 24 }.count
                if Double(near) < Double(colors.count) * 0.85 { flat = false }
            }
            if !flat { for i in region { fillSet[i] = 0 }; return }
            for i in region { fillSet[i] = 1; if candidate[i] != 0 { acceptedInk += 1 } }; accepted += region.count
        }
        let reachLimit = max(6, stroke * 2) * 3
        var done = [Bool](repeating: false, count: parts.count)
        for _ in 0..<4 {
            let near = chamfer((0..<n).map { erasedInk[$0] != 0 || fillSet[$0] == 1 ? UInt8(0) : 1 })
            var changed = false
            for (k, part) in parts.enumerated() where !done[k] {
                let closest = part.points.map { near[$0] }.min() ?? 65_535
                if Double(closest) > reachLimit || part.small && closest > 6 { continue }
                done[k] = true; let before = accepted; consider(part); if accepted > before { changed = true }
            }; if !changed { break }
        }
        if accepted == 0 || Double(acceptedInk) > Double(inkCount) * 1.5 { return 0 }
        var pending = (0..<n).filter { fillSet[$0] == 1 }
        for _ in 0..<64 {
            if pending.isEmpty { break }
            var ready: [(Int, [Double])] = [], waiting: [Int] = []
            for i in pending {
                var count = 0, sums = [Double](repeating: 0, count: 3)
                for j in neighbors(i) {
                    if fillSet[j] == 1 || fillSet[j] == 0 && inkish(j) { continue }
                    count += 1; let source = fillSet[j] == 3 || out[j * 4 + 3] != 0 ? out : original
                    for c in 0..<3 { sums[c] += Double(source[j * 4 + c]) }
                }
                if count >= 2 { ready.append((i, sums.map { $0 / Double(count) })) } else { waiting.append(i) }
            }
            if ready.isEmpty { break }
            for (i, rgb) in ready { for c in 0..<3 { out[i * 4 + c] = NativeResidualProof.clamp(rgb[c]) }; fillSet[i] = 3 }
            pending = waiting
        }
        var painted = 0
        for i in 0..<n where fillSet[i] == 3 { out[i * 4 + 3] = 255; if restored.layoutSafe != nil { restored.layoutSafe?[i] = 1 }; painted += 1 }
        restored.rgba = out
        return painted
    }
}
