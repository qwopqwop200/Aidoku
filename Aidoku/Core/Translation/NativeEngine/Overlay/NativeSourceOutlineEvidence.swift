import CoreGraphics
import Foundation

/// Pixel-exact source core/ring/surface evidence used by the final outline pass.
/// Box coordinates are pixel endpoints [left, top, right, bottom], not sizes.
enum NativeSourceOutlineEvidence {
    struct Structure { let band: Double; let deep: Double; let fillN: Int; let ringN: Int }
    struct Surface {
        let rgb: [Double]
        let flat: Bool
        let close: Double
        let luminances: [Double]
        func reads(_ colour: [Double], ratio: Double) -> Double {
            let y = NativeSourceOutlineEvidence.luminance(colour)
            return Double(luminances.filter { (max($0, y) + 0.05) / (min($0, y) + 0.05) >= ratio }.count) / Double(luminances.count)
        }
    }
    struct Ring {
        let core: [Double]
        let outline: [Double]
        let uniform: Double
        let hug: Double
        let width: Double
        let structure: Structure
        let boxRing: Double?
        let reached: Double
        let exterior: Double?
        let kind: String
        let surface: Surface?
        /// The frozen DOM diagnostic rounds these fields to two decimals before
        /// the late final style helper reads them back; keep this same boundary.
        var dictionary: [String: Any] {
            func r(_ x: Double) -> Double { floor(x * 100 + 0.5) / 100 }
            var d: [String: Any] = ["kind": kind, "core": core, "outline": outline,
                "uniform": r(uniform), "hug": r(hug), "width": r(width), "reached": r(reached),
                "boxRing": boxRing.map(r) as Any? ?? NSNull(), "exterior": exterior.map(r) as Any? ?? NSNull()]
            d["surface"] = surface.map { $0.rgb + [$0.flat ? 1 : 0] } as Any? ?? NSNull()
            return d
        }
    }
    struct Result { let ring: Ring?; let rejection: String? }

    static func ringPair(rgba p: [UInt8], width w: Int, height h: Int, box: [Int], glyph: Double,
                         candidates: [[Double]?]) -> Result {
        let n = w * h
        guard w > 0, h > 0, n <= 262_144, p.count == n * 4, box.count == 4,
              glyph.isFinite, glyph > 0 else { return Result(ring: nil, rejection: "invalid") }
        let bx0 = box[0], by0 = box[1], bx1 = box[2], by1 = box[3], boxN = Double(max(1, (bx1 - bx0) * (by1 - by0)))
        var lum = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let red = 0.2126 * Double(p[i * 4]), green = 0.7152 * Double(p[i * 4 + 1]), blue = 0.0722 * Double(p[i * 4 + 2])
            lum[i] = Float(red + green + blue)
        }
        let ix0 = max(0, bx0), ix1 = min(w, bx1), iy0 = max(0, by0), iy1 = min(h, by1)
        var inside: [Int] = []
        if ix0 < ix1 && iy0 < iy1 { for y in iy0..<iy1 { for x in ix0..<ix1 { inside.append(y * w + x) } } }
        let insideN = inside.count
        if insideN < 30 { return Result(ring: nil, rejection: "small") }
        // Stable luminance ranking yields the same low first ties/high last ties
        // as the browser's partial-bin ranking, without changing pixel membership.
        let ranked = inside.sorted { a, b in lum[a] == lum[b] ? a < b : lum[a] < lum[b] }
        let extremes = [median(p, Array(ranked.prefix(max(3, Int(floor(Double(insideN) * 0.06)))))),
                        median(p, Array(ranked.suffix(insideN - Int(floor(Double(insideN) * 0.94)))))]
        var bins: [Int: [Double]] = [:], keys: [Int] = []
        for i in inside {
            let at = i * 4, key = Int(p[at] >> 5) * 64 + Int(p[at + 1] >> 5) * 8 + Int(p[at + 2] >> 5)
            if bins[key] == nil { keys.append(key); bins[key] = [0, 0, 0, 0] }
            bins[key]![0] += 1
            for c in 0..<3 { bins[key]![c + 1] += Double(p[at + c]) }
        }
        let modes = keys.enumerated().filter { bins[$0.element]![0] >= Double(insideN) * 0.04 }
            .sorted { a, b in bins[a.element]![0] == bins[b.element]![0] ? a.offset < b.offset : bins[a.element]![0] > bins[b.element]![0] }
            .prefix(4).map { item -> [Double] in let b = bins[item.element]!; return b.dropFirst().map { $0 / b[0] } }
        var colours: [[Double]] = []
        for colour in candidates.compactMap({ $0 }) + extremes where validRGB(colour) && !colours.contains(where: { gap($0, colour) < 24 }) { colours.append(colour.map { floor($0 + 0.5) }) }
        let primary = colours.count
        for colour in modes where validRGB(colour) && !colours.contains(where: { gap($0, colour) < 24 }) && colours.count < primary + 3 { colours.append(colour.map { floor($0 + 0.5) }) }
        func near(_ colour: [Double]) -> [UInt8] { (0..<n).map { gap(pixel(p, $0), colour) <= 40 ? 1 : 0 } }
        let thin = max(1, Int(floor(glyph * 0.1 + 0.5))), shell = max(2, Int(floor(glyph * 0.12 + 0.5)))
        struct Passed {
            let core: [Double]; let outline: [Double]; let uniform: Double; let hug: Double
            let out: [Int]; let ringMask: [UInt8]; let reached: Double
            var score: Double { uniform * hug }
        }
        var passed: [Passed] = []
        var cache: [Int: (mask: [UInt8], count: Int, depth: [Int])] = [:]
        func reachable(_ barrier: [UInt8], _ ring: [Int], _ ringMask: [UInt8]) -> Double {
            var seen = [UInt8](repeating: 0, count: n), queue: [Int] = [], head = 0
            for y in 0..<h { for x in 0..<w {
                let i = y * w + x
                if (x == 0 || y == 0 || x == w - 1 || y == h - 1) && barrier[i] == 0 { seen[i] = 1; queue.append(i) }
            } }
            while head < queue.count {
                let i = queue[head]; head += 1
                for j in neighbors(i, w, h) where seen[j] == 0 && barrier[j] == 0 { seen[j] = 1; queue.append(j) }
            }
            let members = ring.filter { ringMask[$0] != 0 }
            return Double(members.filter { seen[$0] != 0 }.count) / Double(max(1, members.count))
        }
        let plan = Array(0..<primary).map { ($0, false) } + colours.indices.map { ($0, true) }
        for (k, proposed) in plan.enumerated() {
            if k == primary && !passed.isEmpty { break }
            let (colourIndex, split) = proposed, core = colours[colourIndex]
            if cache[colourIndex] == nil {
                let mask = near(core), count = inside.reduce(0) { $0 + Int(mask[$1]) }
                cache[colourIndex] = (mask, count, distance(mask, w, h, unset: true))
            }
            let entry = cache[colourIndex]!
            if Double(entry.count) < boxN * 0.03 || !split && Double(entry.count) > boxN * 0.65 { continue }
            let whole = entry.mask, depth = entry.depth
            var mask = whole, boxCore = entry.count
            if split {
                var seen = [UInt8](repeating: 0, count: n), removed = 0
                for seed in 0..<n where mask[seed] != 0 && seen[seed] == 0 {
                    var stack = [seed], members: [Int] = [], deep = 0, deepest = 0; seen[seed] = 1
                    while let i = stack.popLast() {
                        members.append(i); if depth[i] > thin { deep += 1 }; deepest = max(deepest, depth[i])
                        for j in neighbors(i, w, h) where mask[j] != 0 && seen[j] == 0 { seen[j] = 1; stack.append(j) }
                    }
                    if Double(deepest) > glyph * 0.3 && Double(deep) > Double(members.count) * 0.25 { for i in members { mask[i] = 0 }; removed += 1 }
                }
                if removed == 0 && k < 2 * primary { continue }
                boxCore = inside.reduce(0) { $0 + Int(mask[$1]) }
            }
            if Double(boxCore) < boxN * 0.03 || Double(boxCore) > boxN * 0.65 { continue }
            let thick = inside.filter { mask[$0] != 0 && depth[$0] > thin }.count
            if Double(thick) > Double(boxCore) * 0.4 { continue }
            let out = distance(mask, w, h), band = min(shell, 3)
            var ring: [Int] = [], apart: [Int] = []
            for y in 0..<h { for x in 0..<w {
                let i = y * w + x
                if out[i] >= 2 && out[i] <= band && x >= bx0 - band && x < bx1 + band && y >= by0 - band && y < by1 + band {
                    ring.append(i); if gap(pixel(p, i), core) >= 80 { apart.append(i) }
                }
            } }
            if ring.count < 12 || Double(apart.count) < Double(ring.count) * 0.4 { continue }
            let outline = median(p, apart)
            if contrast(core, outline) < 3 { continue }
            let uniform = Double(ring.filter { gap(pixel(p, $0), outline) <= 40 }.count) / Double(ring.count)
            if uniform < 0.45 { continue }
            let mr = near(outline), toRing = distance(mr, w, h)
            var edges = 0, hugged = 0
            for i in inside where mask[i] != 0 {
                if neighbors(i, w, h).contains(where: { mask[$0] == 0 }) { edges += 1; if toRing[i] <= 3 { hugged += 1 } }
            }
            let hug = Double(hugged) / Double(max(1, edges))
            if edges < 12 || hug < 0.6 { continue }
            let reached = reachable(mask, ring, mr)
            if reached < 0.5 { continue }
            passed.append(Passed(core: core, outline: outline, uniform: uniform, hug: hug,
                out: out, ringMask: mr, reached: split ? reachable(whole, ring, mr) : reached))
        }
        guard !passed.isEmpty else { return Result(ring: nil, rejection: "no-pair") }
        var best = 0
        for i in passed.indices where passed[i].score > passed[best].score { best = i }
        for _ in 0..<2 {
            let inner = passed.indices.filter { $0 != best && gap(passed[$0].outline, passed[best].core) <= 40 && gap(passed[best].outline, passed[$0].core) > 40 }
                .sorted { a, b in passed[a].score == passed[b].score ? a < b : passed[a].score > passed[b].score }
            guard let first = inner.first else { break }; best = first
        }
        let chosen = passed[best], reach = max(shell + 2, Int(floor(glyph * 0.3 + 0.5)))
        let exteriorPixels = (0..<n).filter { chosen.out[$0] > reach }
        let exterior = exteriorPixels.count >= 16 ? Double(exteriorPixels.filter { chosen.ringMask[$0] != 0 }.count) / Double(exteriorPixels.count) : nil
        var atD = [Int](repeating: 0, count: reach + 2), ringAtD = atD
        for i in 0..<n { let d = chosen.out[i]; if d >= 1 && d <= reach + 1 { atD[d] += 1; ringAtD[d] += Int(chosen.ringMask[i]) } }
        var width = 1
        if reach + 1 >= 2 { for d in 2...reach + 1 { if atD[d] < 8 || Double(ringAtD[d]) < Double(atD[d]) * 0.5 { break }; width = d } }
        let boxRest = inside.filter { chosen.out[$0] > 1 }
        let boxRing = boxRest.count >= 16 ? Double(boxRest.filter { chosen.ringMask[$0] != 0 }.count) / Double(boxRest.count) : nil
        let edge = min(reach, width + 1), surfacePixels = (0..<n).filter { chosen.out[$0] > edge }
        var surface: Surface?
        if surfacePixels.count >= 48 {
            let step = max(1, surfacePixels.count / 1500), picked = surfacePixels.enumerated().filter { $0.offset % step == 0 }.map(\.element)
            func quant(_ a: [Double], _ q: Double) -> Double { a[min(a.count - 1, Int(floor(Double(a.count) * q)))] }
            let channels = (0..<3).map { c in picked.map { Double(p[$0 * 4 + c]) }.sorted() }
            let lums = picked.map { Double(lum[$0]) }.sorted(), rgb = channels.map { quant($0, 0.5) }
            let spread = channels.map { quant($0, 0.75) - quant($0, 0.25) }.max()!
            let close = Double(picked.filter { gap(pixel(p, $0), rgb) <= 32 }.count) / Double(picked.count)
            surface = Surface(rgb: rgb, flat: quant(lums, 0.75) - quant(lums, 0.25) <= 16 && spread <= 20 && close >= 0.7,
                close: close, luminances: picked.map { luminance(pixel(p, $0)) })
        }
        var core = chosen.core
        for extreme in extremes {
            if spread(core) >= 24 || spread(extreme) >= 24 { continue }
            let d: [Double] = zip(chosen.outline, extreme).map { $0 - $1 }
            var norm = 0.0
            for value in d { norm += value * value }
            if norm <= 0 { continue }
            var projection = 0.0
            for c in 0..<3 { projection += (core[c] - extreme[c]) * d[c] }
            let t = projection / norm
            var off = 0.0
            for c in 0..<3 { off = max(off, abs(core[c] - (extreme[c] + t * d[c]))) }
            if t > 0.1 && t < 0.7 && off <= 20 && contrast(extreme, chosen.outline) > contrast(core, chosen.outline) { core = extreme.map { floor($0 + 0.5) }; break }
        }
        let structure = structure(p, w, h, box, glyph, core, chosen.outline, near(core), chosen.ringMask)
        return Result(ring: Ring(core: core, outline: chosen.outline, uniform: chosen.uniform, hug: chosen.hug,
            width: Double(width) / max(1, glyph), structure: structure, boxRing: boxRing, reached: chosen.reached,
            exterior: exterior, kind: exterior == nil || exterior! < 0.5 ? "outline" : "paper", surface: surface), rejection: nil)
    }

    static func enclosedCaptionOutline(rgba p: [UInt8], width w: Int, height h: Int, box b: [Double],
                                       glyph: Double, ink: [Double], allowNeutral: Bool = false) -> [String: Any]? {
        let n = w * h
        guard w >= 8, h >= 8, n <= 262_144, p.count == n * 4, ink.count == 3, ink.allSatisfy(\.isFinite),
              b.count == 4, b.allSatisfy(\.isFinite), glyph >= 8, ink.min()! <= 170,
              !(spread(ink) < 40 && ink.max()! > 48), spread(ink) >= 40 || allowNeutral else { return nil }
        let axis = ink.map { 255 - $0 }, norm = axis.reduce(0) { $0 + $1 * $1 }
        var pale = [UInt8](repeating: 0, count: n), seen = pale
        for i in 0..<n {
            if p[i * 4 + 3] < 250 { return nil }; let rgb = pixel(p, i)
            pale[i] = rgb.min()! >= 225 && spread(rgb) <= 24 ? 1 : 0
        }
        var islands = 0, filaments = 0, total = 0, sums = [Double](repeating: 0, count: 3)
        for seed in 0..<n where pale[seed] != 0 && seen[seed] == 0 {
            var queue = [seed], head = 0, left = w, top = h, right = 0, bottom = 0, edge = false, ring = 0, boundary = 0; seen[seed] = 1
            while head < queue.count {
                let i = queue[head], x = i % w, y = i / w; head += 1
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { edge = true }
                for j in neighbors(i, w, h) {
                    if pale[j] != 0 { if seen[j] == 0 { seen[j] = 1; queue.append(j) } }
                    else {
                        boundary += 1; let rgb = pixel(p, j)
                        let t = (0..<3).reduce(0.0) { $0 + (255 - rgb[$1]) * axis[$1] } / norm
                        if t > 0.06 && t <= 1.2 && (0..<3).allSatisfy({ abs(rgb[$0] - (255 - axis[$0] * t)) <= 25 }) { ring += 1 }
                    }
                }
            }
            let width = right - left + 1, height = bottom - top + 1
            if edge || queue.count < 8 || Double(left) < b[0] - 2 || Double(right) > b[2] + 2 || Double(top) < b[1] - 2 || Double(bottom) > b[3] + 2 ||
                Double(width) > glyph * 1.5 || Double(height) > glyph * 1.5 || Double(ring) < Double(boundary) * 0.8 { continue }
            islands += 1; total += queue.count
            if Double(max(width, height)) >= glyph * 0.25 && (Double(max(width, height)) / Double(min(width, height)) >= 2.4 || Double(queue.count) / Double(width * height) < 0.42) { filaments += 1 }
            for i in queue { for c in 0..<3 { sums[c] += Double(p[i * 4 + c]) } }
        }
        if islands < 4 || filaments < 2 || Double(filaments) < Double(islands) * 0.25 || total < 24 { return nil }
        return ["foreground": sums.map { floor($0 / Double(total) + 0.5) }, "stroke": ink,
            "confidence": ["foreground": 0.85, "stroke": 0.85], "components": Double(islands), "filaments": Double(filaments),
            "proof": "closed thin interiors bounded by observed ink"]
    }

    private static func structure(_ p: [UInt8], _ w: Int, _ h: Int, _ box: [Int], _ glyph: Double,
                                  _ core: [Double], _ outline: [Double], _ mc: [UInt8], _ mo: [UInt8]) -> Structure {
        let n = w * h
        var classes = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            if mc[i] != 0 && mo[i] != 0 {
                let rgb = pixel(p, i), dc = zip(rgb, core).reduce(0.0) { $0 + abs($1.0 - $1.1) }, dd = zip(rgb, outline).reduce(0.0) { $0 + abs($1.0 - $1.1) }
                classes[i] = dc <= dd ? 1 : 2
            } else { classes[i] = mc[i] != 0 ? 1 : mo[i] != 0 ? 2 : 0 }
        }
        var fill = [Int](repeating: 0, count: 3), ring = fill
        func scan(_ length: Int, _ at: (Int) -> Int) {
            var sequence: [UInt8] = [], k = 0
            while k < length {
                let a = classes[at(k)]; var end = k
                while end + 1 < length && classes[at(end + 1)] == a { end += 1 }
                let count = end - k + 1
                if !(a == 0 && count <= 2 && k > 0 && end < length - 1) && sequence.last != a { sequence.append(a) }
                k = end + 1
            }
            if sequence.count >= 3 { for q in 1..<sequence.count - 1 {
                let a = sequence[q]; if a == 0 { continue }; let other: UInt8 = a == 1 ? 2 : 1
                let index = 2 - (sequence[q - 1] == other ? 1 : 0) - (sequence[q + 1] == other ? 1 : 0)
                if a == 1 { fill[index] += 1 } else { ring[index] += 1 }
            } }
        }
        let x0 = max(0, box[0]), x1 = min(w, box[2]), y0 = max(0, box[1]), y1 = min(h, box[3])
        if x0 < x1 && y0 < y1 {
            for y in y0..<y1 { scan(x1 - x0) { y * w + x0 + $0 } }
            for x in x0..<x1 { scan(y1 - y0) { (y0 + $0) * w + x } }
        }
        let depth = distance(mc, w, h, unset: true)
        var hist = [Int](repeating: 0, count: w + h + 3), count = 0
        for i in stride(from: 0, to: n, by: 2) where classes[i] == 1 { hist[min(w + h + 2, depth[i])] += 1; count += 1 }
        var deep = 0, seen = 0
        while deep < hist.count { seen += hist[deep]; if Double(seen) >= Double(count) * 0.95 { break }; deep += 1 }
        let fillN = fill.reduce(0, +), ringN = ring.reduce(0, +)
        let band = fillN > 0 && ringN > 0 ? Double(ring[1]) / Double(ringN) + Double(fill[0]) / Double(fillN) - Double(ring[0]) / Double(ringN) : 0
        return Structure(band: band, deep: Double(deep) / max(1, glyph), fillN: fillN, ringN: ringN)
    }
    private static func distance(_ mask: [UInt8], _ w: Int, _ h: Int, unset: Bool = false) -> [Int] {
        var d = mask.map { (unset ? $0 != 0 : $0 == 0) ? w + h + 2 : 0 }
        for y in 0..<h { for x in 0..<w { let i = y * w + x; if x > 0 { d[i] = min(d[i], d[i - 1] + 1) }; if y > 0 { d[i] = min(d[i], d[i - w] + 1) } } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) { let i = y * w + x; if x < w - 1 { d[i] = min(d[i], d[i + 1] + 1) }; if y < h - 1 { d[i] = min(d[i], d[i + w] + 1) } } }
        return d
    }
    private static func median(_ p: [UInt8], _ list: [Int]) -> [Double] {
        (0..<3).map { c in let sorted = list.map { p[$0 * 4 + c] }.sorted(); return sorted.isEmpty ? 0 : Double(sorted[sorted.count / 2]) }
    }
    private static func neighbors(_ i: Int, _ w: Int, _ h: Int) -> [Int] {
        let x = i % w; return [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, i >= w ? i - w : -1, i + w < w * h ? i + w : -1].filter { $0 >= 0 }
    }
    private static func pixel(_ p: [UInt8], _ i: Int) -> [Double] { (0..<3).map { Double(p[i * 4 + $0]) } }
    private static func validRGB(_ a: [Double]) -> Bool { a.count == 3 && a.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 255 } }
    private static func gap(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map { abs($0 - $1) }.max()! }
    private static func spread(_ a: [Double]) -> Double { a.max()! - a.min()! }
    private static func luminance(_ a: [Double]) -> Double {
        let v = a.map { x -> Double in let s = x / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return v[0] * 0.2126 + v[1] * 0.7152 + v[2] * 0.0722
    }
    private static func contrast(_ a: [Double], _ b: [Double]) -> Double { let x = luminance(a), y = luminance(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
}
