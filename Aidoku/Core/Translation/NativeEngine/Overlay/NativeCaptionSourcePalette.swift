import CoreGraphics
import Foundation

/// Caption and panel observation policy ported from the frozen browser renderer.
/// Descriptors retain display-only evidence separately from permission to erase ink.
enum NativeCaptionSourcePalette {
    typealias Payload = [String: Any]
    typealias RGB = [Double]

    private static func rgb(_ value: Any?) -> RGB? {
        guard let values = value as? [NSNumber], values.count == 3 else { return nil }
        let result = values.map(\.doubleValue)
        return result.allSatisfy(\.isFinite) ? result : nil
    }
    private static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    private static func distance(_ first: RGB, _ second: RGB) -> Double {
        zip(first, second).map { abs($0 - $1) }.max() ?? .infinity
    }
    private static func low(_ color: RGB) -> Double { color.min() ?? .infinity }
    private static func high(_ color: RGB) -> Double { color.max() ?? -.infinity }
    private static func rounded(_ color: RGB) -> RGB { color.map { floor($0 + 0.5) } }
    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    private static func stableSort<T>(_ values: [T], by precedes: (T, T) -> Bool) -> [T] {
        values.enumerated().sorted {
            if precedes($0.element, $1.element) { return true }
            if precedes($1.element, $0.element) { return false }
            return $0.offset < $1.offset
        }.map(\.element)
    }
    private static func valid(_ rgba: [UInt8], _ width: Int, _ height: Int, _ box: CGRect? = nil) -> Bool {
        guard width > 0, height > 0, height <= 24_576, width <= 24_576 / height,
              rgba.count == width * height * 4 else { return false }
        if let box {
            return [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) && box.width > 0 && box.height > 0
        }
        return true
    }
    private static func color(_ rgba: [UInt8], _ pixel: Int) -> RGB {
        (0..<3).map { Double(rgba[pixel * 4 + $0]) }
    }
    private static func confidence(_ result: Payload?) -> Payload { result?["confidence"] as? Payload ?? [:] }

    static func recoverSourcePanel(rgba: [UInt8], width: Int, height: Int, box: CGRect, result: Payload?) -> Payload? {
        guard let result, valid(rgba, width, height, box) else { return result }
        let vertical = box.height >= box.width
        let start = vertical ? box.minY : box.minX, end = vertical ? box.maxY : box.maxX
        let near = vertical ? box.minX : box.minY, far = vertical ? box.maxX : box.maxY
        func sideOf(_ x: Int, _ y: Int) -> Int? {
            let along = Double(vertical ? y : x), across = Double(vertical ? x : y)
            guard along >= start, along < end else { return nil }
            if across >= 1, across < near - 2 { return 0 }
            if across > far + 2, across < Double(vertical ? width : height) - 1 { return 1 }
            return nil
        }
        var sides = [[Int](), [Int]()]
        for y in 0..<height {
            for x in 0..<width {
                guard let side = sideOf(x, y) else { continue }
                let offset = (y * width + x) * 4
                guard rgba[offset + 3] >= 250 else { return result }
                sides[side].append(offset)
            }
        }
        guard sides.allSatisfy({ $0.count >= 8 }) else { return result }
        var candidate = (0..<3).map { channel in median(sides.flatMap { $0.map { Double(rgba[$0 + channel]) } }) }
        let support = sides.map { side in
            Double(side.filter { offset in distance((0..<3).map { Double(rgba[offset + $0]) }, candidate) <= 18 }.count) / Double(side.count)
        }
        var panelConfidence = support.min()!
        if panelConfidence < 0.6 || (support[0] + support[1]) / 2 < 0.75 {
            var rows: [Int: [[RGB]]] = [:], rowOrder: [Int] = []
            for y in 0..<height {
                for x in 0..<width {
                    guard let side = sideOf(x, y) else { continue }
                    let along = vertical ? y : x
                    if rows[along] == nil { rows[along] = [[], []]; rowOrder.append(along) }
                    rows[along]![side].append(color(rgba, y * width + x))
                }
            }
            var paired: [RGB] = []
            for key in rowOrder {
                let row = rows[key]!
                guard row.allSatisfy({ $0.count >= 2 }) else { continue }
                let colors = row.map { side in (0..<3).map { channel in median(side.map { $0[channel] }) } }
                if distance(colors[0], colors[1]) <= 18 { paired.append(contentsOf: colors) }
            }
            panelConfidence = Double(paired.count) / Double(rowOrder.count * 2)
            guard panelConfidence >= 0.5 else { return result }
            candidate = rounded((0..<3).map { channel in paired.reduce(0) { $0 + $1[channel] } / Double(paired.count) })
        }
        if let background = rgb(result["background"]) {
            if distance(background, candidate) <= 8 || low(background) < 235 { return result }
        }
        var updated = result, evidence = confidence(result)
        evidence["background"] = panelConfidence
        evidence["panelReason"] = "matching observed surfaces on opposite sides of OCR"
        updated["background"] = candidate; updated["confidence"] = evidence
        return updated
    }

    private struct OutlinedGroup { let rgb: RGB; let count: Double; let stroke: RGB }
    static func recoverOutlinedColor(rgba: [UInt8], width: Int, height: Int, result: Payload?,
                                     allowDark: Bool = false, opaque: Bool = false) -> Payload? {
        if !allowDark, rgb(result?["foreground"]) != nil, number(confidence(result)["foreground"]) >= 0.6 { return nil }
        guard width >= 8, height >= 8, valid(rgba, width, height) else { return nil }
        if !opaque, stride(from: 3, to: rgba.count, by: 4).contains(where: { rgba[$0] < 250 }) { return nil }
        do {
            let n = width * height
            var source = try NativeKernelBuffer(values: rgba), w = width, h = height
            if allowDark, w > h {
                let transposed = try NativeKernelBuffer<UInt8>(count: rgba.count)
                try NativeTranslationPixelKernels.transpose_rgba(src: source, dst: transposed, w: Int32(w), h: Int32(h))
                source = transposed; swap(&w, &h)
            }
            let output = try NativeKernelBuffer<Int32>(count: n * 9)
            let groupsCount = try NativeTranslationPixelKernels.outlined_components(rgba: source, w: Int32(w), h: Int32(h),
                allow_dark: allowDark ? 1 : 0, white: NativeKernelBuffer(count: n), seen: NativeKernelBuffer(count: n),
                queue: NativeKernelBuffer(count: n), counts: NativeKernelBuffer(count: 4096), sums: NativeKernelBuffer(count: 12288),
                keys: NativeKernelBuffer(count: 4096), out: output)
            var groups: [OutlinedGroup] = []
            for group in 0..<Int(groupsCount) {
                let at = group * 9, tail = Double(output[at]), topCount = Double(output[at + 1])
                guard topCount >= 2, topCount >= tail * 0.15 else { continue }
                let observed = (2...4).map { Double(output[at + $0]) / topCount }
                if let background = rgb(result?["background"]), distance(observed, background) < 48 { continue }
                let edgeCount = Double(output[at + 5])
                if edgeCount >= 4 {
                    groups.append(.init(rgb: observed, count: topCount, stroke: (6...8).map { Double(output[at + $0]) / edgeCount }))
                }
                if groups.count >= 128 { return nil }
            }
            var best: [OutlinedGroup] = []
            for group in groups {
                let same = groups.filter { distance($0.rgb, group.rgb) <= 28 }
                if same.count > best.count { best = same }
            }
            guard best.count >= 3 else { return nil }
            if allowDark {
                guard best.reduce(0, { $0 + $1.count }) >= groups.reduce(0, { $0 + $1.count }) * 0.6 else { return nil }
            } else if Double(best.count) < Double(groups.count) * 0.8 { return nil }
            let count = best.reduce(0) { $0 + $1.count }
            let foreground = rounded((0..<3).map { channel in best.reduce(0) { $0 + $1.rgb[channel] * $1.count } / count })
            let stroke = rounded((0..<3).map { channel in best.reduce(0) { $0 + $1.stroke[channel] * $1.count } / count })
            return ["foreground": foreground, "stroke": stroke, "confidence": 0.75, "components": best.count, "fillPixels": count]
        } catch { return nil }
    }

    static func observedSourceSurface(rgba: [UInt8], width: Int, height: Int, box: CGRect, result: Payload?) -> Payload? {
        guard valid(rgba, width, height, box) else { return nil }
        let vertical = box.height >= box.width
        let start = vertical ? box.minY : box.minX, length = vertical ? box.height : box.width
        let near = vertical ? box.minX : box.minY, far = vertical ? box.maxX : box.maxY
        let foreground = rgb(result?["foreground"]), stroke = rgb(result?["stroke"])
        var bands = Array(repeating: [[RGB](), [RGB]()], count: 6)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard rgba[index * 4 + 3] >= 250 else { return nil }
                let along = Double(vertical ? y : x), across = Double(vertical ? x : y)
                guard along >= start, along < start + length, !(across >= near - 1 && across <= far + 1) else { continue }
                let observed = color(rgba, index)
                if let foreground, distance(observed, foreground) < 28 { continue }
                if let stroke, distance(observed, stroke) < 28 { continue }
                bands[min(5, Int(floor((along - start) * 6 / length)))][across < near - 1 ? 0 : 1].append(observed)
            }
        }
        var stops: [RGB?] = bands.map { sides in
            guard sides.allSatisfy({ $0.count >= 4 }) else { return nil }
            let colors = sides.map { values in (0..<3).map { channel in median(values.map { $0[channel] }) } }
            guard distance(colors[0], colors[1]) <= 18 else { return nil }
            for side in 0..<2 {
                guard Double(sides[side].filter({ distance($0, colors[side]) <= 18 }).count) >= Double(sides[side].count) * 0.6 else { return nil }
            }
            return rounded(zip(colors[0], colors[1]).map { ($0 + $1) / 2 })
        }
        let observed = stops.compactMap { $0 }
        guard observed.count >= 3 else { return nil }
        let estimate = (0..<3).map { channel in median(observed.map { $0[channel] }) }
        for index in stops.indices where stops[index] == nil {
            var nearest = 0
            for other in stops.indices where stops[other] != nil {
                if stops[nearest] == nil || abs(other - index) < abs(nearest - index) { nearest = other }
            }
            stops[index] = stops[nearest]
        }
        return ["color": estimate, "stops": stops.compactMap { $0 }, "vertical": vertical]
    }

    private final class Bin {
        var count = 0, inside = 0, outside = 0, kept = 0
        var sum: RGB = [0, 0, 0]
        var core: [RGB] = []
        var bands: Set<Int> = []
        var mean: RGB { sum.map { $0 / Double(count) } }
        var roundedMean: RGB { rounded(mean) }
        func add(_ value: RGB) { count += 1; for channel in 0..<3 { sum[channel] += value[channel] } }
    }

    static func observedCaptionPalette(rgba: [UInt8], width: Int, height: Int, box: CGRect, result: Payload?) -> Payload? {
        guard valid(rgba, width, height, box) else { return result }
        var bins: [Bin] = [], indices: [Int: Int] = [:], insideCount = 0, outsideCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if rgba[offset + 3] < 128 { continue }
                let key = Int(rgba[offset] >> 5) * 64 + Int(rgba[offset + 1] >> 5) * 8 + Int(rgba[offset + 2] >> 5)
                if indices[key] == nil { indices[key] = bins.count; bins.append(Bin()) }
                let bin = bins[indices[key]!]
                bin.add(color(rgba, y * width + x))
                if Double(x) >= box.minX, Double(x) < box.maxX, Double(y) >= box.minY, Double(y) < box.maxY {
                    bin.inside += 1; insideCount += 1
                } else { bin.outside += 1; outsideCount += 1 }
            }
        }
        guard !bins.isEmpty else { return result }
        let ink = rgb(result?["foreground"]) ?? rgb(result?["displayForeground"]), stroke = rgb(result?["stroke"])
        let surface = rgb((result?["surface"] as? Payload)?["color"]) ?? rgb(result?["background"])
        func bright(_ color: RGB?) -> Bool { color.map { low($0) >= 230 } ?? false }
        func exteriorSupport(_ color: RGB) -> Double {
            Double(bins.reduce(0) { $0 + (distance($1.roundedMean, color) <= 32 ? $1.outside : 0) }) / Double(max(1, outsideCount))
        }
        let haloSurface = bright(surface) && number(confidence(result)["background"]) < 0.5 && exteriorSupport(surface!) < 0.25
        if !haloSurface, let surface,
           Double(bins.reduce(0, { $0 + (distance($1.roundedMean, surface) <= 32 ? $1.inside : 0) })) >= max(1, Double(insideCount) * 0.08) {
            return result
        }
        let candidates = bins.filter { bin in
            (!haloSurface || !bright(bin.roundedMean) || exteriorSupport(bin.roundedMean) >= 0.25) &&
                (ink == nil || distance(bin.roundedMean, ink!) > 32) && (stroke == nil || distance(bin.roundedMean, stroke!) > 32)
        }
        func score(_ bin: Bin) -> Double { ink != nil ? Double(bin.outside) + Double(bin.inside) * 0.25 : Double(bin.inside) }
        let ranked = stableSort(candidates.isEmpty ? bins : candidates) {
            score($0) == score($1) ? $0.count > $1.count : score($0) > score($1)
        }
        let background = ranked[0].roundedMean
        var updated = result ?? [:]
        if ink == nil {
            let foreground = stableSort(bins.filter { Double($0.inside) >= max(2, Double(insideCount) * 0.02) &&
                distance($0.roundedMean, background) >= 48 }) { $0.inside > $1.inside }.first
            if let foreground { updated["displayForeground"] = foreground.roundedMean }
        }
        var evidence = confidence(result)
        evidence["background"] = 0
        evidence["panelReason"] = "best available observed pixels; display only, no erasure"
        updated["background"] = background; updated["surface"] = NSNull(); updated["observedBackground"] = true; updated["confidence"] = evidence
        return updated
    }

    static func recoverHaloInk(rgba: [UInt8], width: Int, height: Int, box: CGRect) -> Payload? {
        guard valid(rgba, width, height, box) else { return nil }
        let vertical = box.height >= box.width
        let directions = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
        let reach = max(2, min(6, Int(ceil(min(6, min(box.width, box.height) * 0.2)))))
        var bins: [Bin] = [], indices: [Int: Int] = [:]
        func white(_ index: Int) -> Bool { min(rgba[index * 4], rgba[index * 4 + 1], rgba[index * 4 + 2]) >= 220 }
        let x0 = max(0, min(width, Int(floor(max(0, min(CGFloat(width), box.minX)))))), x1 = max(0, min(width, Int(ceil(max(0, min(CGFloat(width), box.maxX))))))
        let y0 = max(0, min(height, Int(floor(max(0, min(CGFloat(height), box.minY)))))), y1 = max(0, min(height, Int(ceil(max(0, min(CGFloat(height), box.maxY))))))
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) {
                let index = y * width + x, offset = index * 4, observed = color(rgba, index)
                guard rgba[offset + 3] >= 250, high(observed) - low(observed) >= 40, !white(index) else { continue }
                let key = Int(rgba[offset] >> 5) * 64 + Int(rgba[offset + 1] >> 5) * 8 + Int(rgba[offset + 2] >> 5)
                if indices[key] == nil { indices[key] = bins.count; bins.append(Bin()) }
                let bin = bins[indices[key]!]; bin.add(observed)
                var enclosed = 0
                for (dx, dy) in directions {
                    for step in 1...reach {
                        let xx = x + dx * step, yy = y + dy * step
                        guard xx >= 0, yy >= 0, xx < width, yy < height else { break }
                        if white(yy * width + xx) { enclosed += 1; break }
                    }
                }
                if enclosed >= 5 {
                    bin.kept += 1; bin.core.append(observed)
                    let along = Double(vertical ? y : x), start = vertical ? box.minY : box.minX, length = vertical ? box.height : box.width
                    bin.bands.insert(min(5, max(0, Int(floor((along - start) / length * 6)))))
                }
            }
        }
        func hue(_ color: RGB) -> RGB { color.map { ($0 - low(color)) / max(1, high(color) - low(color)) } }
        var winner: Payload?, winnerKept = 0
        for seed in bins {
            let same = bins.filter { distance(hue($0.mean), hue(seed.mean)) <= 0.18 }
            let count = same.reduce(0) { $0 + $1.count }, kept = same.reduce(0) { $0 + $1.kept }
            let bands = Set(same.flatMap { $0.bands })
            guard kept >= 6, Double(kept) >= Double(count) * 0.65, bands.count >= 3 else { continue }
            if winner == nil || kept > winnerKept {
                let core = stableSort(same.flatMap { $0.core }) { high($0) - low($0) > high($1) - low($1) }
                let selected = Array(core.prefix(max(3, Int(ceil(Double(core.count) / 3)))))
                winnerKept = kept
                winner = ["kept": kept, "foreground": rounded((0..<3).map { channel in
                    selected.reduce(0) { $0 + $1[channel] } / Double(selected.count)
                })]
            }
        }
        return winner
    }

    static func interiorCaptionSurface(rgba: [UInt8], width: Int, height: Int, box: CGRect, result: Payload?) -> Payload? {
        guard valid(rgba, width, height, box), let backing = rgb((result?["surface"] as? Payload)?["color"]) ?? rgb(result?["background"]),
              let ink = rgb(result?["foreground"]) ?? rgb(result?["displayForeground"]), low(backing) >= 225, low(ink) < 220 else { return result }
        let n = width * height
        var mask = [UInt8](repeating: 0, count: n)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard rgba[index * 4 + 3] >= 250, distance(color(rgba, index), ink) <= 40 else { continue }
                for yy in max(0, y - 2)...min(height - 1, y + 2) {
                    for xx in max(0, x - 2)...min(width - 1, x + 2) { mask[yy * width + xx] = 1 }
                }
            }
        }
        var pixels: [RGB] = [], total = 0
        let x0 = max(0, min(width, Int(ceil(max(0, min(CGFloat(width), box.minX)))))), x1 = max(0, min(width, Int(ceil(max(0, min(CGFloat(width), box.maxX))))))
        let y0 = max(0, min(height, Int(ceil(max(0, min(CGFloat(height), box.minY)))))), y1 = max(0, min(height, Int(ceil(max(0, min(CGFloat(height), box.maxY))))))
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) {
                total += 1
                let index = y * width + x
                if mask[index] == 0, rgba[index * 4 + 3] >= 250 { pixels.append(color(rgba, index)) }
            }
        }
        guard pixels.count >= 32, Double(pixels.count) >= Double(total) * 0.35 else { return result }
        do {
            let count = pixels.count
            let r = try NativeKernelBuffer(values: pixels.map { UInt8($0[0]) })
            let g = try NativeKernelBuffer(values: pixels.map { UInt8($0[1]) })
            let b = try NativeKernelBuffer(values: pixels.map { UInt8($0[2]) })
            let band = try NativeKernelBuffer<UInt8>(count: count)
            let sortedR = try NativeKernelBuffer<UInt8>(count: count), sortedG = try NativeKernelBuffer<UInt8>(count: count)
            let sortedB = try NativeKernelBuffer<UInt8>(count: count)
            try NativeTranslationPixelKernels.columns_sort(r: r, g: g, b: b, band: band, count: Int32(count), ro: sortedR, go: sortedG,
                bo: sortedB, bando: NativeKernelBuffer(count: count), offsets: NativeKernelBuffer(count: 767))
            let trim = Int(floor(Double(count) * 0.1)), sum = try NativeKernelBuffer<Int32>(count: 3)
            try NativeTranslationPixelKernels.columns_sum(r: sortedR, g: sortedG, b: sortedB, from: Int32(trim), to: Int32(count - trim), out: sum)
            let estimate = rounded(sum.values.map { Double($0) / Double(count - trim * 2) })
            let disagreement = Double(pixels.filter { distance($0, backing) > 18 }.count) / Double(count)
            guard disagreement >= 0.3, distance(estimate, backing) >= 5 else { return result }
            var updated = result ?? [:], evidence = confidence(result)
            evidence["panelReason"] = "trimmed exposed interior excluding local ink and halo; display only"
            updated["background"] = estimate; updated["surface"] = NSNull(); updated["observedBackground"] = true
            updated["captionInterior"] = ["color": estimate, "coverage": Double(count) / Double(max(1, total)), "disagreement": disagreement]
            updated["confidence"] = evidence
            return updated
        } catch { return result }
    }

    private struct Samples {
        let r: [UInt8]; let g: [UInt8]; let b: [UInt8]; let band: [UInt8]
        let bands: Set<Int>; let total: Int; let textured: Bool
        var count: Int { r.count }
        var enough: Bool { count >= 24 && Double(count) >= Double(total) * 0.15 && bands.count >= 4 }
    }

    private static func captionSamples(rgba: [UInt8], width: Int, height: Int, box: CGRect,
                                       ink: RGB, tolerance: Int, radius: Int) throws -> Samples? {
        let n = width * height, vertical = box.height >= box.width
        let start = vertical ? box.minY : box.minX, length = vertical ? box.height : box.width
        let input = try NativeKernelBuffer(values: rgba)
        let mask = try NativeKernelBuffer<UInt8>(count: n), halo = try NativeKernelBuffer<UInt8>(count: n)
        let dots = try NativeKernelBuffer<UInt8>(count: n), stats = try NativeKernelBuffer<Int32>(count: 4)
        var nearCount = 0, dotCount = 0, dotInside = 0, dotOutside = 0
        if ink.allSatisfy({ floor($0) == $0 && (0...255).contains($0) }) {
            let value = try NativeTranslationPixelKernels.caption_mask(rgba: input, w: Int32(width), h: Int32(height),
                ir: Int32(ink[0]), ig: Int32(ink[1]), ib: Int32(ink[2]), tolerance: Int32(tolerance), radius: Int32(radius),
                il: box.minX, it: box.minY, iright: box.maxX, ibottom: box.maxY, dark_ink: high(ink) < 128 ? 1 : 0,
                interior_min: max(48, box.width * box.height * 0.1), near: NativeKernelBuffer(count: n), mask: mask, dots: dots, halo: halo,
                seen: NativeKernelBuffer(count: n), queue: NativeKernelBuffer(count: n), stats: stats)
            if value < 0 { return nil }
            dotCount = Int(stats[0]); dotInside = Int(stats[1]); dotOutside = Int(stats[2]); nearCount = Int(stats[3])
        } else {
            // Fractional inferred ink has the browser's Double comparisons. The
            // integer kernel cannot safely truncate those palette endpoints.
            var near = [UInt8](repeating: 0, count: n), seen = [UInt8](repeating: 0, count: n)
            for index in 0..<n {
                if rgba[index * 4 + 3] < 250 { return nil }
                if distance(color(rgba, index), ink) <= Double(tolerance) { near[index] = 1; nearCount += 1 }
            }
            for seed in 0..<n where near[seed] != 0 && seen[seed] == 0 {
                var queue = [seed], read = 0, edges = 0, interior = 0
                var x0 = width, y0 = height, x1 = 0, y1 = 0
                seen[seed] = 1
                while read < queue.count {
                    let index = queue[read], x = index % width, y = index / width; read += 1
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                    if x == 0 { edges |= 1 }; if x == width - 1 { edges |= 2 }
                    if y == 0 { edges |= 4 }; if y == height - 1 { edges |= 8 }
                    if Double(x) >= box.minX, Double(x) < box.maxX, Double(y) >= box.minY, Double(y) < box.maxY { interior += 1 }
                    let neighbors = [(x > 0, index - 1), (x + 1 < width, index + 1), (y > 0, index - width), (y + 1 < height, index + width)]
                    for (valid, other) in neighbors where valid && near[other] != 0 && seen[other] == 0 {
                        seen[other] = 1; queue.append(other)
                    }
                }
                let surface = high(ink) < 128 && Double(interior) >= max(48, box.width * box.height * 0.1) && (edges & (edges - 1)) != 0
                let dot = queue.count <= 4 && x1 - x0 <= 2 && y1 - y0 <= 2
                if dot { dotCount += 1; dotInside += interior; dotOutside += queue.count - interior }
                let target = dot ? halo : mask
                for index in queue {
                    if dot { dots[index] = 1 }
                    if surface, distance(color(rgba, index), ink) > 12 { continue }
                    let reach = surface ? min(radius, 1) : radius, x = index % width, y = index / width
                    for yy in max(0, y - reach)...min(height - 1, y + reach) {
                        for xx in max(0, x - reach)...min(width - 1, x + reach) { target[yy * width + xx] = 1 }
                    }
                }
            }
        }
        let area = box.width * box.height, outside = max(1, Double(n) - area)
        var textured = high(ink) < 96 && dotCount >= 80 && dotInside >= 32 && dotOutside >= 40 &&
            Double(dotInside + dotOutside) >= Double(nearCount) * 0.8 && Double(dotInside) / max(1, area) >= 0.03 &&
            Double(dotInside) / max(1, area) <= 0.25 && Double(dotOutside) / outside >= Double(dotInside) / area * 0.5 &&
            Double(dotOutside) / outside <= Double(dotInside) / area * 2.5
        if textured {
            textured = try NativeTranslationPixelKernels.caption_periodic(dots: dots, w: Int32(width), h: Int32(height), axis: 0) == 1 &&
                NativeTranslationPixelKernels.caption_periodic(dots: dots, w: Int32(width), h: Int32(height), axis: 1) == 1
        }
        let r = try NativeKernelBuffer<UInt8>(count: n), g = try NativeKernelBuffer<UInt8>(count: n)
        let b = try NativeKernelBuffer<UInt8>(count: n), band = try NativeKernelBuffer<UInt8>(count: n)
        let x0 = max(0, min(width, Int(ceil(max(0, min(CGFloat(width), box.minX)))))), x1 = max(0, min(width, Int(ceil(max(0, min(CGFloat(width), box.maxX))))))
        let y0 = max(0, min(height, Int(ceil(max(0, min(CGFloat(height), box.minY)))))), y1 = max(0, min(height, Int(ceil(max(0, min(CGFloat(height), box.maxY))))))
        try NativeTranslationPixelKernels.caption_exposed(rgba: input, w: Int32(width), mask: mask, halo: halo,
            textured: textured ? 1 : 0, x0: Int32(x0), x1: Int32(max(x0, x1)), y0: Int32(y0), y1: Int32(max(y0, y1)),
            vertical: vertical ? 1 : 0, start: start, length: length, r: r, g: g, b: b, band: band, stats: stats)
        let count = Int(stats[0]), bands = Set((0..<8).filter { stats[2] & (1 << $0) != 0 })
        return Samples(r: Array(r.values.prefix(count)), g: Array(g.values.prefix(count)), b: Array(b.values.prefix(count)),
                       band: Array(band.values.prefix(count)), bands: bands, total: Int(stats[1]), textured: textured)
    }

    private static func captionColor(_ samples: Samples, ink: RGB) throws -> RGB {
        let count = samples.count
        let r = try NativeKernelBuffer(values: samples.r), g = try NativeKernelBuffer(values: samples.g)
        let b = try NativeKernelBuffer(values: samples.b), band = try NativeKernelBuffer(values: samples.band)
        let sortedR = try NativeKernelBuffer<UInt8>(count: count), sortedG = try NativeKernelBuffer<UInt8>(count: count)
        let sortedB = try NativeKernelBuffer<UInt8>(count: count), sortedBand = try NativeKernelBuffer<UInt8>(count: count)
        try NativeTranslationPixelKernels.columns_sort(r: r, g: g, b: b, band: band, count: Int32(count), ro: sortedR,
            go: sortedG, bo: sortedB, bando: sortedBand, offsets: NativeKernelBuffer(count: 767))
        let counts = try NativeKernelBuffer<Int32>(count: 4096), sums = try NativeKernelBuffer<Int32>(count: 12288)
        let keys = try NativeKernelBuffer<Int32>(count: 4096), output = try NativeKernelBuffer<Int32>(count: 4)
        let bins = Int(try NativeTranslationPixelKernels.columns_bins(r: sortedR, g: sortedG, b: sortedB, count: Int32(count),
                                                                   counts: counts, sums: sums, order: keys))
        let ranked = stableSort((0..<bins).map { Int(keys[$0]) }) { counts[$0] > counts[$1] }
        var supportedCount = 0, supportedSum: RGB = [0, 0, 0]
        for key in ranked.prefix(8) {
            let mode = (0..<3).map { Double(sums[key * 3 + $0]) / Double(counts[key]) }
            try NativeTranslationPixelKernels.columns_support(r: sortedR, g: sortedG, b: sortedB, count: Int32(count),
                m0: mode[0], m1: mode[1], m2: mode[2], out: output)
            if Int(output[0]) > supportedCount {
                supportedCount = Int(output[0]); supportedSum = (1...3).map { Double(output[$0]) }
            }
        }
        let range = try NativeTranslationPixelKernels.columns_range(r: sortedR, g: sortedG, b: sortedB, count: Int32(count),
                                                                   hist: NativeKernelBuffer(count: 256))
        let mode = supportedCount > 0 ? supportedSum.map { $0 / Double(supportedCount) } : ink
        try NativeTranslationPixelKernels.columns_brighter(r: sortedR, g: sortedG, b: sortedB, band: sortedBand, count: Int32(count),
            m0: mode[0], m1: mode[1], m2: mode[2], out: output)
        let brighter = Int(output[0]), brighterBands = (0..<8).filter { output[1] & (1 << $0) != 0 }.count
        let lightGradient = high(mode) - low(mode) >= 30 && Double(brighter) >= Double(count) * 0.15 && brighterBands >= 2
        if !samples.textured, range > 64, Double(supportedCount) >= Double(count) * 0.45, !lightGradient {
            return rounded(supportedSum.map { $0 / Double(supportedCount) })
        }
        let trim = Int(floor(Double(count) * 0.1)), from = samples.textured ? 0 : trim, to = samples.textured ? count : count - trim
        try NativeTranslationPixelKernels.columns_sum(r: sortedR, g: sortedG, b: sortedB, from: Int32(from), to: Int32(to), out: output)
        return rounded((0..<3).map { Double(output[$0]) / Double(to - from) })
    }

    static func observedCaptionBackground(rgba: [UInt8], width: Int, height: Int, box: CGRect, result: Payload?, haloReach: Int = 2) -> Payload? {
        guard let result, valid(rgba, width, height, box), var ink = NativeSourceColorSampler.observedDisplayInk(result),
              haloReach >= 0, haloReach <= 128 else { return result }
        let evidence = confidence(result)
        if let foreground = rgb(result["foreground"]), let stroke = rgb(result["stroke"]), number(evidence["foreground"]) >= 0.8,
           evidence["reason"] as? String == "agreeing native detail palettes preserve fill and outline roles",
           distance(ink, stroke) <= 24, distance(foreground, stroke) >= 48 { ink = foreground }
        do {
            var samples = try captionSamples(rgba: rgba, width: width, height: height, box: box, ink: ink, tolerance: 40, radius: haloReach)
            guard samples != nil else { return result }
            var narrowed = false
            if !samples!.enough {
                samples = try captionSamples(rgba: rgba, width: width, height: height, box: box, ink: ink, tolerance: 12, radius: 1)
                narrowed = true
            }
            guard let samples, samples.enough else { return result }
            let estimate = try captionColor(samples, ink: ink)
            let measuredBand = number((result["widthEvidence"] as? Payload)?["samplePixels"])
            if haloReach == 2, low(estimate) >= 235, let background = rgb(result["background"]), let foreground = rgb(result["foreground"]),
               distance(estimate, background) >= 32, number(evidence["background"]) < 0.5, number(evidence["stroke"]) >= 0.7,
               measuredBand.isFinite, measuredBand > 1, distance(ink, foreground) <= 24 {
                let reach = max(3, min(8, Int(ceil(min(8, measuredBand + 1)))))
                if var retry = observedCaptionBackground(rgba: rgba, width: width, height: height, box: box, result: result, haloReach: reach),
                   var retryEvidence = retry["captionBackgroundEvidence"] as? Payload,
                   let retryColor = rgb(retry["captionBackground"]), low(retryColor) < 230 {
                    retryEvidence["reason"] = "measured halo exclusion rejected a white-outline background; display only"
                    retry["captionBackgroundEvidence"] = retryEvidence
                    return retry
                }
            }
            guard distance(estimate, ink) >= 12,
                  !(narrowed && (zip(estimate, ink).map(-).min()! < 12 || distance(estimate, ink) > 80)) else { return result }
            var updated = result
            updated["captionBackground"] = estimate
            updated["captionBackgroundEvidence"] = ["color": estimate, "coverage": Double(samples.count) / Double(max(1, samples.total)),
                "reason": samples.textured ? "periodic halftone retained across OCR and surrounding pixels; display only" :
                    "trimmed exposed OCR interior excluding displayed ink and local halo; display only"]
            return updated
        } catch { return result }
    }
}

extension NativeCaptionSourcePalette {
    private static func boxRect(_ values: [Double]) -> CGRect? {
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
    static func recoverSourcePanel(rgba: [UInt8], width: Int, height: Int, box: [Double], result: Payload? = nil) -> Payload? {
        guard let box = boxRect(box) else { return result }
        return recoverSourcePanel(rgba: rgba, width: width, height: height, box: box, result: result)
    }
    static func observedSourceSurface(rgba: [UInt8], width: Int, height: Int, box: [Double], result: Payload? = nil) -> Payload? {
        guard let box = boxRect(box) else { return nil }
        return observedSourceSurface(rgba: rgba, width: width, height: height, box: box, result: result)
    }
    static func observedCaptionPalette(rgba: [UInt8], width: Int, height: Int, box: [Double], result: Payload? = nil) -> Payload? {
        guard let box = boxRect(box) else { return result }
        return observedCaptionPalette(rgba: rgba, width: width, height: height, box: box, result: result)
    }
    static func recoverHaloInk(rgba: [UInt8], width: Int, height: Int, box: [Double]) -> Payload? {
        guard let box = boxRect(box) else { return nil }
        return recoverHaloInk(rgba: rgba, width: width, height: height, box: box)
    }
    static func interiorCaptionSurface(rgba: [UInt8], width: Int, height: Int, box: [Double], result: Payload? = nil) -> Payload? {
        guard let box = boxRect(box) else { return result }
        return interiorCaptionSurface(rgba: rgba, width: width, height: height, box: box, result: result)
    }
    static func observedCaptionBackground(rgba: [UInt8], width: Int, height: Int, box: [Double], result: Payload? = nil, haloReach: Int = 2) -> Payload? {
        guard let box = boxRect(box) else { return result }
        return observedCaptionBackground(rgba: rgba, width: width, height: height, box: box, result: result, haloReach: haloReach)
    }
}
