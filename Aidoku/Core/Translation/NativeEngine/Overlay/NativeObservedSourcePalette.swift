import Foundation
import CoreGraphics

/// Native source-ink policy corresponding to BrowserSourceTextColor's bounded
/// observed palettes. These decisions are display evidence; erasure roles are
/// deliberately kept separate. Every returned RGB endpoint was observed in the
/// original crop rather than invented for translated-text contrast.
enum NativeObservedSourcePalette {
    typealias RGB = [Double]
    typealias Payload = [String: Any]

    private struct Pixels {
        let rgba: [UInt8]
        let width: Int
        let height: Int
        let inner: CGRect
        var count: Int { width * height }
        init?(rgba: [UInt8], width: Int, height: Int, inner: CGRect, opaque: Bool = false) {
            guard width >= 8, height >= 8, width <= 24576 / height,
                  rgba.count == width * height * 4,
                  [inner.minX, inner.minY, inner.width, inner.height].allSatisfy(\.isFinite),
                  inner.width > 0, inner.height > 0 else { return nil }
            if !opaque {
                for index in stride(from: 3, to: rgba.count, by: 4) where rgba[index] < 250 { return nil }
            }
            self.rgba = rgba
            self.width = width
            self.height = height
            self.inner = inner
        }
        func rgb(_ index: Int) -> RGB {
            let offset = index * 4
            return [Double(rgba[offset]), Double(rgba[offset + 1]), Double(rgba[offset + 2])]
        }
        func inside(_ x: Int, _ y: Int) -> Bool {
            Double(x) >= inner.minX && Double(x) < inner.maxX && Double(y) >= inner.minY && Double(y) < inner.maxY
        }
        func near(_ index: Int, _ color: RGB, _ tolerance: Double) -> Bool { distance(rgb(index), color) <= tolerance }
    }

    private struct Bin {
        var count = 0
        var sum: RGB = [0, 0, 0]
        var color: RGB { sum.map { jsRound($0 / Double(count)) } }
        mutating func add(_ color: RGB) {
            count += 1
            for channel in 0..<3 { sum[channel] += color[channel] }
        }
    }

    private final class Glyph {
        let color: RGB
        let pixels: Double
        let components: Int
        let bands: Int
        let energy: Double
        let coverage: Double
        let score: Double
        var core: [Int]
        var enclosure: [(color: RGB, ratio: Double)] = []
        var enclosureObserved = false
        var endpoint: RGB?
        var darkEndpoint: RGB?

        init(color: RGB, pixels: Int, components: Int, bands: Int, energy: Double, coverage: Double, core: [Int], score: Double) {
            self.color = color
            self.pixels = Double(pixels)
            self.components = components
            self.bands = bands
            self.energy = energy
            self.coverage = coverage
            self.core = core
            self.score = score
        }

        convenience init?(_ payload: Payload) {
            guard let color = rgb(payload["color"]) else { return nil }
            self.init(color: color, pixels: Int(number(payload["pixels"])), components: Int(number(payload["components"])),
                      bands: Int(number(payload["bands"])), energy: number(payload["energy"]), coverage: number(payload["coverage"]),
                      core: [], score: number(payload["score"]))
            enclosure = (payload["enclosure"] as? [Payload] ?? []).compactMap {
                guard let color = rgb($0["color"]) else { return nil }
                return (color: color, ratio: number($0["ratio"]))
            }
            enclosureObserved = payload["enclosure"] != nil
            endpoint = rgb(payload["endpoint"])
            darkEndpoint = rgb(payload["darkEndpoint"])
        }

        var payload: Payload {
            var result: Payload = ["color": color, "pixels": pixels, "components": components, "bands": bands,
                                   "energy": energy, "coverage": coverage, "score": score]
            if enclosureObserved { result["enclosure"] = enclosure.map { ["color": $0.color, "ratio": $0.ratio] as Payload } }
            if let endpoint { result["endpoint"] = endpoint }
            if let darkEndpoint { result["darkEndpoint"] = darkEndpoint }
            return result
        }
        func enclosed(by other: Glyph) -> Double { enclosure.first { distance($0.color, other.color) <= 24 }?.ratio ?? 0 }
        func enclosed(by color: RGB, atLeast ratio: Double, tolerance: Double = 24) -> Bool {
            enclosure.contains { distance($0.color, color) <= tolerance && $0.ratio >= ratio }
        }
    }

    private struct Result {
        let payload: Payload
        let foreground: RGB?
        let displayForeground: RGB?
        let background: RGB?
        let surface: RGB?
        let stroke: RGB?
        let captionBackground: RGB?
        let lettering: Payload
        let letteringColor: RGB?
        let evidence: Payload
        let confidence: Payload
        var foregroundConfidence: Double { number(confidence["foreground"]) }
        var backgroundConfidence: Double { number(confidence["background"]) }
        var reason: String { confidence["reason"] as? String ?? "" }
        var samplePixels: Double { number(evidence["samplePixels"]) }
        var relativeToGlyph: Double { number(evidence["relativeToGlyph"]) }
        var hasEvidence: Bool { payload["widthEvidence"] != nil && !(payload["widthEvidence"] is NSNull) }
        init(_ payload: Payload?) {
            self.payload = payload ?? [:]
            foreground = rgb(payload?["foreground"])
            displayForeground = rgb(payload?["displayForeground"])
            background = rgb(payload?["background"])
            surface = rgb((payload?["surface"] as? Payload)?["color"])
            stroke = rgb(payload?["stroke"])
            captionBackground = rgb(payload?["captionBackground"])
            lettering = payload?["lettering"] as? Payload ?? [:]
            letteringColor = rgb(lettering["color"])
            evidence = payload?["widthEvidence"] as? Payload ?? [:]
            confidence = payload?["confidence"] as? Payload ?? [:]
        }
        var preservedStroke: Payload? {
            guard let foreground, let stroke else { return nil }
            var result: Payload = ["foreground": foreground, "stroke": stroke]
            if let evidence = payload["widthEvidence"] { result["widthEvidence"] = evidence }
            return result
        }
    }

    private static let directions = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)]

    private static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    private static func rgb(_ value: Any?) -> RGB? {
        guard let values = value as? [Any], values.count == 3 else { return nil }
        let result = values.compactMap { ($0 as? NSNumber)?.doubleValue }
        return result.count == 3 && result.allSatisfy(\.isFinite) ? result : nil
    }
    private static func low(_ color: RGB) -> Double { color.min() ?? .infinity }
    private static func high(_ color: RGB) -> Double { color.max() ?? -.infinity }
    private static func span(_ color: RGB) -> Double { high(color) - low(color) }
    private static func hue(_ color: RGB) -> RGB { color.map { ($0 - low(color)) / max(1, span(color)) } }
    private static func distance(_ lhs: RGB, _ rhs: RGB) -> Double { zip(lhs, rhs).map { abs($0 - $1) }.max() ?? .infinity }
    private static func delta(_ lhs: RGB, _ rhs: RGB) -> RGB { zip(lhs, rhs).map(-) }
    private static func dot(_ lhs: RGB, _ rhs: RGB) -> Double { zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 } }
    private static func onAxis(_ value: RGB, _ axis: RGB, _ projection: Double, _ tolerance: Double) -> Bool {
        zip(value, axis).allSatisfy { abs($0 - projection * $1) <= tolerance }
    }
    private static func jsRound(_ value: Double) -> Double { floor(value + 0.5) }
    private static func key(_ color: RGB, bits: Int = 4) -> Int {
        let shift = 8 - bits, base = 1 << bits
        return (Int(color[0]) >> shift) * base * base + (Int(color[1]) >> shift) * base + (Int(color[2]) >> shift)
    }
    private static func stableSort<T>(_ values: [T], by precedes: (T, T) -> Bool) -> [T] {
        values.enumerated().sorted {
            if precedes($0.element, $1.element) { return true }
            if precedes($1.element, $0.element) { return false }
            return $0.offset < $1.offset
        }.map(\.element)
    }
    private static func contrast(_ foreground: RGB, _ background: RGB) -> Double {
        guard foreground.count == 3, foreground.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }) else { return 0 }
        func luminance(_ color: RGB) -> Double {
            let channels = color.map { value -> Double in
                let component = value / 255
                return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let foreground = luminance(foreground), background = luminance(background)
        return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
    }

    private static func bins(_ pixels: Pixels) -> [(key: Int, bin: Bin)] {
        var values: [Int: Bin] = [:]
        var order: [Int] = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.inside(x, y) {
                let color = pixels.rgb(y * pixels.width + x), index = key(color)
                if values[index] == nil { values[index] = Bin(); order.append(index) }
                values[index]?.add(color)
            }
        }
        return order.compactMap { index in values[index].map { (key: index, bin: $0) } }
    }

    private static func rect(_ box: [Double]) -> CGRect? {
        guard box.count == 4, box.allSatisfy(\.isFinite), box[2] > 0, box[3] > 0 else { return nil }
        return CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
    }

    static func observedGlyphPalette(
        rgba: [UInt8], width: Int, height: Int, box: [Double], hint: Payload? = nil
    ) -> [Payload]? {
        guard let inner = rect(box), let pixels = Pixels(rgba: rgba, width: width, height: height, inner: inner) else { return nil }
        do {
            let source = try NativeKernelBuffer(values: rgba)
            let starts = try NativeKernelBuffer<Int32>(count: 4097)
            let order = try NativeKernelBuffer<Int32>(count: pixels.count)
            let cursor = try NativeKernelBuffer<Int32>(count: 4096)
            let mask = try NativeKernelBuffer<UInt8>(count: pixels.count)
            let seen = try NativeKernelBuffer<UInt8>(count: pixels.count)
            let queue = try NativeKernelBuffer<Int32>(count: pixels.count)
            let core = try NativeKernelBuffer<Int32>(count: pixels.count)
            let stats = try NativeKernelBuffer<Int32>(count: 5)
            let bins = stableSort(bins(pixels).map(\.bin)) { $0.count > $1.count }
            let area = Double(bins.reduce(0) { $0 + $1.count })
            var seeds: [RGB] = []
            for bin in bins where Double(bin.count) >= max(4, area * 0.002) {
                let color = bin.color
                if seeds.contains(where: { distance($0, color) < 32 }) { continue }
                seeds.append(color)
                if seeds.count >= 12 { break }
            }
            try NativeTranslationPixelKernels.glyph_index(rgba: source, n: Int32(pixels.count), start: starts, order: order, cursor: cursor)
            let vertical = inner.height >= inner.width
            var candidates: [Glyph] = []
            for color in seeds {
                let length = try NativeTranslationPixelKernels.glyph_seed(
                    rgba: source, w: Int32(width), h: Int32(height), cr: Int32(color[0]), cg: Int32(color[1]), cb: Int32(color[2]),
                    left: inner.minX, right: inner.maxX, top: inner.minY, bottom: inner.maxY, min_total: max(8, area * 0.004),
                    vertical: vertical ? 1 : 0, origin: vertical ? inner.minY : inner.minX, span: vertical ? inner.height : inner.width,
                    start: starts, order: order, mask: mask, seen: seen, queue: queue, core: core, stats: stats
                )
                if length < 0 { continue }
                let total = Double(stats[0]), retained = Int(stats[1]), components = Int(stats[2]), bands = Int(stats[4])
                guard components >= 3, bands >= 3, Double(retained) >= max(8, area * 0.004), Double(retained) <= area * 0.6 else { continue }
                let average = Double(stats[3]) / Double(retained)
                guard average >= 12 else { continue }
                candidates.append(Glyph(
                    color: color, pixels: retained, components: components, bands: bands, energy: average,
                    coverage: Double(retained) / max(1, total), core: (0..<Int(length)).map { Int(core[$0]) },
                    score: Double(retained) * (0.5 + min(1, average / 80))
                ))
            }
            candidates = stableSort(candidates) { $0.score > $1.score }
            for candidate in candidates.prefix(6) {
                candidate.enclosureObserved = true
                for other in candidates.prefix(6) where other !== candidate && distance(candidate.color, other.color) >= 48 {
                    for (index, pixel) in candidate.core.enumerated() { core[index] = Int32(pixel) }
                    try NativeTranslationPixelKernels.glyph_enclosure(
                        rgba: source, w: Int32(width), h: Int32(height), core: core, len: Int32(candidate.core.count),
                        stride: Int32(max(1, Int(ceil(Double(candidate.core.count) / 128)))),
                        or: Int32(other.color[0]), og: Int32(other.color[1]), ob: Int32(other.color[2]), out: stats
                    )
                    candidate.enclosure.append((color: other.color, ratio: Double(stats[0]) / max(1, Double(stats[1]))))
                }
            }
            let hint = Result(hint)
            if let foreground = hint.foreground, let background = hint.background,
               low(delta(foreground, background)) >= 32 {
                let direction = delta(foreground, background), squared = dot(direction, direction)
                for candidate in candidates where distance(candidate.color, foreground) <= 32 {
                    var peaks: [RGB] = []
                    let stride = max(1, Int(ceil(Double(candidate.core.count) / 128)))
                    for index in Swift.stride(from: 0, to: candidate.core.count, by: stride) {
                        let pixel = candidate.core[index], x = pixel % width, y = pixel / width
                        var best: RGB?, bestProjection = 0.8
                        for dy in -1...1 {
                            for dx in -1...1 {
                                let xx = x + dx, yy = y + dy
                                guard xx >= 0, xx < width, yy >= 0, yy < height, pixels.inside(xx, yy) else { continue }
                                let color = pixels.rgb(yy * width + xx), difference = delta(color, background)
                                let projection = dot(difference, direction) / squared
                                if projection > bestProjection && onAxis(difference, direction, projection, 16) {
                                    best = color; bestProjection = projection
                                }
                            }
                        }
                        if let best { peaks.append(best) }
                    }
                    if peaks.count >= 8 {
                        candidate.endpoint = (0..<3).map { channel in peaks.map { $0[channel] }.sorted()[peaks.count / 2] }
                    }
                }
            }
            if let foreground = hint.foreground, let background = hint.background, high(foreground) < 80, low(background) >= 225 {
                let direction = delta(foreground, background), squared = dot(direction, direction)
                for candidate in candidates where candidate.pixels <= 64 && candidate.coverage < 0.5 {
                    let difference = delta(candidate.color, background), projection = dot(difference, direction) / max(1, squared)
                    if projection < 0.1 || projection > 0.8 || !onAxis(difference, direction, projection, 12) { continue }
                    var supported = 0
                    for pixel in candidate.core {
                        let x = pixel % width, y = pixel / width
                        var found = false
                        for yy in max(0, y - 2)...min(height - 1, y + 2) {
                            for xx in max(0, x - 2)...min(width - 1, x + 2) {
                                if pixels.inside(xx, yy) && pixels.near(yy * width + xx, foreground, 64) { found = true }
                            }
                        }
                        if found { supported += 1 }
                    }
                    if supported >= 8 && Double(supported) >= Double(candidate.core.count) * 0.4 { candidate.darkEndpoint = foreground }
                }
            }
            return candidates.map(\.payload)
        } catch { return nil }
    }

    static func observedLetteringInk(
        rgba: [UInt8], width: Int, height: Int, box: [Double], opaque: Bool = false
    ) -> Payload? {
        guard let inner = rect(box), let pixels = Pixels(rgba: rgba, width: width, height: height, inner: inner, opaque: opaque) else { return nil }
        struct Mode {
            var colors: [RGB] = []
            var bands: Set<Int> = []
            var points: [Int] = []
        }
        do {
            let source = try NativeKernelBuffer(values: rgba)
            let dark = try NativeKernelBuffer<UInt8>(count: pixels.count)
            let events = try NativeKernelBuffer<Int32>(count: pixels.count * 4)
            let vertical = inner.height >= inner.width
            let alongStart = max(0, vertical ? inner.minY : inner.minX)
            let alongEnd = min(Double(vertical ? height : width), vertical ? inner.maxY : inner.maxX)
            let x0 = Int(max(1, min(Double(width), ceil(inner.minX)))), x1 = Int(max(0, min(Double(width - 1), ceil(inner.maxX))))
            let y0 = Int(max(1, min(Double(height), ceil(inner.minY)))), y1 = Int(max(0, min(Double(height - 1), ceil(inner.maxY))))
            guard x1 >= x0, y1 >= y0 else { return nil }
            let count = try NativeTranslationPixelKernels.lettering_rays(
                rgba: source, dark: dark, w: Int32(width), h: Int32(height), x0: Int32(x0), x1: Int32(x1),
                y0: Int32(y0), y1: Int32(y1), out: events
            )
            var modes: [Int: Mode] = [:], order: [Int] = []
            for index in 0..<Int(count) {
                let pixel = Int(events[index * 4]), x = pixel % width, y = pixel / width
                let color = (1...3).map { Double(events[index * 4 + $0]) }, index = key(color, bits: 3)
                if modes[index] == nil { modes[index] = Mode(); order.append(index) }
                modes[index]?.colors.append(color)
                modes[index]?.points.append(pixel)
                modes[index]?.bands.insert(min(7, Int(floor((Double(vertical ? y : x) - alongStart) * 8 / max(1, alongEnd - alongStart)))))
            }
            var candidates: [Payload] = []
            let rankedModes = stableSort(order.compactMap { modes[$0] }) { $0.points.count > $1.points.count }
            for mode in rankedModes.prefix(4) {
                guard mode.points.count >= 8, mode.bands.count >= 3 else { continue }
                var remaining = Array(repeating: UInt8(0), count: pixels.count)
                for point in mode.points { remaining[point] = 1 }
                var components = 0
                for start in mode.points where remaining[start] != 0 {
                    remaining[start] = 0; components += 1
                    var queue = [start], head = 0
                    while head < queue.count {
                        let pixel = queue[head], x = pixel % width, y = pixel / width
                        head += 1
                        for (dx, dy) in directions {
                            let xx = x + dx, yy = y + dy
                            if xx >= 0 && xx < width && yy >= 0 && yy < height && remaining[yy * width + xx] != 0 {
                                remaining[yy * width + xx] = 0; queue.append(yy * width + xx)
                            }
                        }
                    }
                }
                if components < 3 { continue }
                let color = (0..<3).map { channel in mode.colors.map { $0[channel] }.sorted()[mode.colors.count / 2] }
                let counts = try NativeKernelBuffer<Int32>(count: 4)
                try NativeTranslationPixelKernels.lettering_support(
                    rgba: source, w: Int32(width), h: Int32(height), l: inner.minX, r: inner.maxX, t: inner.minY, b: inner.maxY,
                    ir: Int32(color[0]), ig: Int32(color[1]), ib: Int32(color[2]), out: counts
                )
                let cx0 = max(0, ceil(inner.minX)), cx1 = min(Double(width), ceil(inner.maxX))
                let cy0 = max(0, ceil(inner.minY)), cy1 = min(Double(height), ceil(inner.maxY))
                let insideCount = max(0, cx1 - cx0) * max(0, cy1 - cy0), outsideCount = Double(pixels.count) - insideCount
                let inkInside = Double(counts[2]), inkOutside = Double(counts[3])
                let support = inkInside / max(1, insideCount), exterior = inkOutside / max(1, outsideCount)
                if outsideCount < 8 || support < 0.025 || support > 0.55 || exterior > support * 0.6 || exterior > 0.16 { continue }
                var endpointBins: [Int: Bin] = [:], endpointOrder: [Int] = []
                let chromatic = span(color) >= 40, seedHue = hue(color), inkMaximum = high(color)
                for y in 0..<height {
                    for x in 0..<width where pixels.inside(x, y) {
                        let color = pixels.rgb(y * width + x)
                        if chromatic {
                            if span(color) < 40 || distance(hue(color), seedHue) > 0.18 { continue }
                        } else if span(color) > 24 || high(color) > inkMaximum { continue }
                        let index = key(color)
                        if endpointBins[index] == nil { endpointBins[index] = Bin(); endpointOrder.append(index) }
                        endpointBins[index]?.add(color)
                    }
                }
                let endpoints = endpointOrder.compactMap { endpointBins[$0] }.filter { Double($0.count) >= max(4, inkInside * 0.025) }.map(\.color)
                let ranked = stableSort(endpoints) { chromatic ? span($0) > span($1) : high($0) < high($1) }
                candidates.append(["color": ranked.first ?? color, "pixels": mode.points.count, "bands": mode.bands.count,
                                   "components": components, "support": support, "exterior": exterior])
            }
            return stableSort(candidates) { number($0["pixels"]) > number($1["pixels"]) }.first
        } catch { return nil }
    }

    private struct StrokePair {
        let foreground: RGB
        let stroke: RGB
        let band: Double
        let glyphPixels: Double
        let hitRatio: Double
        let exitRatio: Double
        let coverage: Double
        let backgroundExits: Double
        let exits: Double
        let score: Double
        var payload: Payload {
            ["foreground": foreground, "stroke": stroke, "band": band, "glyphPixels": glyphPixels,
             "hitRatio": hitRatio, "exitRatio": exitRatio, "coverage": coverage, "backgroundExits": backgroundExits,
             "exits": exits, "score": score]
        }
    }

    static func observedStrokePalette(
        rgba: [UInt8], width: Int, height: Int, box: [Double], glyphs glyphPayloads: [Payload]?,
        display: RGB?, result resultPayload: Payload?, opaque: Bool = false
    ) -> Payload? {
        guard let inner = rect(box), let pixels = Pixels(rgba: rgba, width: width, height: height, inner: inner, opaque: opaque) else { return nil }
        let result = Result(resultPayload), glyphs = (glyphPayloads ?? []).compactMap(Glyph.init)
        let fore = result.foreground, stroke = result.stroke, background = result.background
        let reason = result.reason, lettering = result.letteringColor
        if let fore, let stroke, distance(fore, stroke) >= 48,
           reason == "matching colored glyph interiors inside observed white outlines in independent strips" { return result.preservedStroke }
        if let fore, let stroke, result.hasEvidence, result.foregroundConfidence >= 0.8,
           low(fore) >= 175, high(stroke) < 130,
           reason.contains("agreeing native detail") || reason.contains("enclosed glyph fill") { return result.preservedStroke }
        if let fore, let stroke, let background, let lettering, let display,
           reason == "enclosed glyph fill and distinct enclosing source stroke", low(fore) >= 225, low(background) >= 225,
           span(stroke) >= 40, result.samplePixels >= 1, result.relativeToGlyph <= 0.3,
           number(result.lettering["components"]) >= 3, number(result.lettering["bands"]) >= 3,
           number(result.lettering["exterior"]) < 0.02, distance(lettering, stroke) <= 24, distance(display, stroke) <= 24 {
            return result.preservedStroke
        }
        if let fore, let stroke, let background, let lettering,
           result.samplePixels >= 1, result.relativeToGlyph <= 0.3, result.foregroundConfidence >= 0.8,
           number(result.lettering["components"]) >= 3, number(result.lettering["bands"]) >= 3,
           distance(lettering, stroke) <= 24, distance(fore, stroke) >= 48 {
            let nativeAgreement = reason == "agreeing native detail palettes preserve fill and outline roles" &&
                low(fore) >= 225 && result.backgroundConfidence >= 0.5
            let enclosed = reason == "enclosed glyph fill and distinct enclosing source stroke" &&
                high(stroke) < 130 && number(result.lettering["exterior"]) < 0.02 && distance(fore, background) >= 48
            let following = reason.contains("observed glyph fill and following halo") && low(fore) >= 225 && distance(stroke, background) >= 48 &&
                glyphs.contains { $0.coverage >= 0.6 && distance($0.color, fore) <= 24 && $0.enclosed(by: stroke, atLeast: 0.7) }
            if nativeAgreement || enclosed || following { return result.preservedStroke }
        }
        guard !glyphs.isEmpty else { return nil }
        do {
            let source = try NativeKernelBuffer(values: rgba)
            var seeds: [RGB] = []
            for bin in stableSort(bins(pixels).map(\.bin), by: { $0.count > $1.count }) where bin.count >= 4 {
                let color = bin.color
                if seeds.contains(where: { distance($0, color) < 32 }) { continue }
                seeds.append(color)
                if seeds.count >= 12 { break }
            }
            var pairs: [StrokePair] = []
            for glyph in glyphs.prefix(6) {
                let surroundedPale = low(glyph.color) >= 225 && glyph.coverage >= 0.5 && glyph.enclosure.contains { enclosure in
                    enclosure.ratio >= 0.6 && glyphs.contains { other in
                        distance(other.color, enclosure.color) <= 24 && other.coverage >= 0.5 &&
                            !other.enclosure.contains { distance($0.color, glyph.color) <= 24 && $0.ratio > enclosure.ratio - 0.3 }
                    }
                }
                let enclosedByOwnedEdge = glyph.enclosure.contains { enclosure in
                    enclosure.ratio >= 0.65 && glyphs.contains { distance($0.color, enclosure.color) <= 24 && $0.coverage >= 0.65 }
                }
                if glyph.coverage < 0.15 { continue }
                if glyph.coverage < 0.5, let display, distance(glyph.color, display) > 24,
                   fore == nil || distance(glyph.color, fore!) > 24, !enclosedByOwnedEdge { continue }
                let supportedFill = surroundedPale || enclosedByOwnedEdge || glyph.coverage >= 0.5 ||
                    fore.map { distance(glyph.color, $0) <= 40 } == true
                if let display, distance(glyph.color, display) > 40, !supportedFill { continue }
                let fill = glyph.color
                let mask = try NativeKernelBuffer<UInt8>(count: pixels.count)
                let seen = try NativeKernelBuffer<UInt8>(count: pixels.count)
                let exterior = try NativeKernelBuffer<UInt8>(count: pixels.count)
                let queue = try NativeKernelBuffer<Int32>(count: pixels.count)
                let core = try NativeKernelBuffer<Int32>(count: pixels.count)
                let heightsBuffer = try NativeKernelBuffer<Int32>(count: pixels.count)
                let stats = try NativeKernelBuffer<Int32>(count: 15)
                try NativeTranslationPixelKernels.stroke_glyph(
                    rgba: source, w: Int32(width), h: Int32(height), fr: Int32(fill[0]), fg: Int32(fill[1]), fb: Int32(fill[2]),
                    left: inner.minX, right: inner.maxX, top: inner.minY, bottom: inner.maxY,
                    mask: mask, seen: seen, exterior: exterior, queue: queue, core: core, heights: heightsBuffer, out: stats
                )
                let coreLength = Int(stats[0]), heightLength = Int(stats[1])
                if heightLength < 3 || coreLength < 8 { continue }
                let heights = (0..<heightLength).map { Double(heightsBuffer[$0]) }.sorted()
                let size = heights[Int(floor(Double(heights.count) * 0.75))]
                let reach = min(16, max(4, Int(ceil(size * 0.6))))
                let stride = max(1, Int(ceil(Double(coreLength) / 128)))
                var adjacent: [Int: Bin] = [:], adjacentOrder: [Int] = []
                for index in Swift.stride(from: 0, to: coreLength, by: stride) {
                    let pixel = Int(core[index]), x = pixel % width, y = pixel / width
                    for (dx, dy) in directions {
                        for step in 1...2 {
                            let xx = x + dx * step, yy = y + dy * step
                            if xx < 0 || xx >= width || yy < 0 || yy >= height { continue }
                            let color = pixels.rgb(yy * width + xx)
                            if distance(color, fill) < 48 { continue }
                            let index = key(color)
                            if adjacent[index] == nil { adjacent[index] = Bin(); adjacentOrder.append(index) }
                            adjacent[index]?.add(color)
                        }
                    }
                }
                var localSeeds = seeds, added = 0
                for bin in stableSort(adjacentOrder.compactMap { adjacent[$0] }, by: { $0.count > $1.count }) where bin.count >= 4 {
                    let color = bin.color
                    if localSeeds.contains(where: { distance($0, color) < 24 }) { continue }
                    localSeeds.append(color); added += 1
                    if added >= 4 { break }
                }
                // The generated bridge reserves by input core count rather
                // than sample count; only ceil(core/stride) records are used.
                let sampleX = try NativeKernelBuffer<Int32>(count: coreLength)
                let sampleY = try NativeKernelBuffer<Int32>(count: coreLength)
                let first = try NativeKernelBuffer<Int32>(count: coreLength * 8)
                let bandsBuffer = try NativeKernelBuffer<Int32>(count: coreLength * 8)
                let samples = try NativeTranslationPixelKernels.stroke_first(
                    rgba: source, w: Int32(width), h: Int32(height), core: core, len: Int32(coreLength), stride: Int32(stride), reach: Int32(reach),
                    fr: Int32(fill[0]), fg: Int32(fill[1]), fb: Int32(fill[2]), sx: sampleX, sy: sampleY, first: first
                )
                for stroke in localSeeds {
                    if distance(fill, stroke) < 48 { continue }
                    let rejoinsExterior = low(fill) < 160 && glyph.coverage >= 0.15 &&
                        glyphs.contains { distance($0.color, stroke) <= 24 && $0.coverage >= 0.7 }
                    let rejected = try NativeTranslationPixelKernels.stroke_seed(
                        rgba: source, w: Int32(width), h: Int32(height), samples: samples, sx: sampleX, sy: sampleY, first: first, reach: Int32(reach),
                        fr: Int32(fill[0]), fg: Int32(fill[1]), fb: Int32(fill[2]), sr: Int32(stroke[0]), sg: Int32(stroke[1]), sb: Int32(stroke[2]),
                        rejoins: rejoinsExterior ? 1 : 0, exterior: exterior, bands: bandsBuffer, stats: stats
                    )
                    if rejected == 1 { continue }
                    let rays = Double(stats[0]), hits = Double(stats[1]), exits = Double(stats[2]), points = Double(stats[3])
                    let enclosed = Double(stats[4]), backgroundExits = Double(stats[5]), bandCount = Int(stats[6])
                    let hitRatio = hits / max(1, rays), exitRatio = exits / max(1, hits), coverage = enclosed / max(1, points)
                    if hitRatio < 0.8 || exitRatio < 0.15 || coverage < 0.3 || bandCount < 12 { continue }
                    let bands = (0..<bandCount).map { Double(bandsBuffer[$0]) }.sorted()
                    let band = bands[bands.count / 2], p90 = bands[Int(floor(Double(bands.count) * 0.9))]
                    if (band < 2 && (hitRatio < 0.97 || (glyph.coverage < 0.8 && backgroundExits / max(1, exits) < 0.6))) ||
                        band > size * 0.3 || p90 > size * 0.5 { continue }
                    if stats[7] + stats[8] < 4 || stats[9] + stats[10] < 4 { continue }
                    pairs.append(StrokePair(foreground: fill, stroke: stroke, band: band, glyphPixels: size,
                                            hitRatio: hitRatio, exitRatio: exitRatio, coverage: coverage,
                                            backgroundExits: backgroundExits, exits: exits, score: glyph.score * hitRatio * coverage))
                }
            }
            let filtered = pairs.filter { pair in
                guard let surface = result.captionBackground, pair.backgroundExits / max(1, pair.exits) < 0.6 else { return true }
                let closedDark = high(pair.stroke) <= 32 && pair.hitRatio >= 0.97 && pair.band >= 2 && pair.coverage >= 0.3 && pair.exitRatio >= 0.18
                if closedDark { return true }
                let closedWhite = low(pair.stroke) >= 225 && pair.hitRatio >= 0.97 && pair.band >= 2 && pair.coverage >= 0.3 &&
                    low(pair.foreground) < 160 && (fore == nil || (stroke != nil && distance(stroke!, pair.stroke) <= 24 && distance(fore!, pair.foreground) <= 24))
                if distance(pair.stroke, surface) <= 40 && low(pair.stroke) < 245 && !closedWhite &&
                    !glyphs.contains(where: { distance($0.color, pair.foreground) <= 24 && $0.enclosed(by: pair.stroke, atLeast: 0.5) }) { return false }
                if !(result.foregroundConfidence > 0) && distance(pair.stroke, surface) <= 40 && !closedWhite { return false }
                let vector = delta(surface, pair.foreground), difference = delta(pair.stroke, pair.foreground)
                let projection = dot(difference, vector) / max(1, dot(vector, vector))
                if projection > 0.12 && projection < 1.08 && onAxis(difference, vector, projection, 24) && !closedWhite { return false }
                return low(pair.foreground) < 160 || distance(pair.stroke, surface) > 24
            }
            if let best = stableSort(filtered, by: { $0.score > $1.score }).first { return best.payload }
            for fill in glyphs where low(fill.color) >= 225 && fill.coverage >= 0.75 {
                for edge in glyphs where span(edge.color) >= 40 && edge.coverage >= 0.8 && fill.pixels >= edge.pixels * 0.4 {
                    let enclosed = fill.enclosed(by: edge), reverse = edge.enclosed(by: fill)
                    if enclosed >= 0.6 && enclosed - reverse >= 0.3 {
                        return ["foreground": fill.color, "stroke": edge.color, "widthEvidence": NSNull()]
                    }
                }
            }
            if let fore, let stroke, distance(fore, stroke) >= 48, result.foregroundConfidence >= 0.6 {
                let colored = reason == "repeated colored interiors enclosed by source white outlines"
                let dark = reason == "repeated dark glyph interiors enclosed by white source outlines" && background != nil &&
                    distance(stroke, background!) > 12 && result.backgroundConfidence >= 0.5 &&
                    (result.samplePixels >= 1 || (distance(stroke, background!) >= 24 &&
                        glyphs.contains { $0.coverage >= 0.6 && distance($0.color, fore) <= 24 && $0.enclosed(by: stroke, atLeast: 0.65) }))
                let enclosed = reason == "enclosed glyph fill and distinct enclosing source stroke" && display != nil && distance(display!, fore) <= 32
                if colored || dark || enclosed { return result.preservedStroke }
            }
            if let fore, let stroke, result.samplePixels >= 0.5, result.relativeToGlyph <= 0.3, distance(fore, stroke) >= 48 {
                let ownedEdge = glyphs.contains { $0.coverage >= 0.65 && distance($0.color, stroke) <= 24 }
                let fill = glyphs.first { ($0.coverage >= 0.25 || ($0.coverage >= 0.15 && ownedEdge)) &&
                    distance($0.color, fore) <= 32 && $0.enclosed(by: stroke, atLeast: 0.65) }
                let distinctExterior = background.map { distance($0, stroke) >= 24 } == true
                let paleEndpoint = fill.map { $0.coverage >= 0.8 } == true && span(fore) >= 40 && low(stroke) >= 245
                let corroboratedNative = reason == "agreeing native detail palettes preserve fill and outline roles" && low(fore) >= 225 && high(stroke) < 80 &&
                    ((number(result.lettering["components"]) >= 3 && number(result.lettering["bands"]) >= 3 &&
                        lettering.map { distance($0, stroke) <= 40 } == true) || (distinctExterior && result.relativeToGlyph <= 0.2))
                let method = result.evidence["method"] as? String ?? ""
                if (result.foregroundConfidence >= 0.6 || (fill != nil && ownedEdge)) &&
                    ((fill != nil && (distinctExterior || paleEndpoint)) || corroboratedNative) &&
                    (method == "outer stroke boundary distance to validated ink; external Manhattan band" ||
                        method == "alternative observed ink with glyph-following halo; exterior surface unverified") {
                    return ["foreground": fore, "stroke": stroke, "band": result.samplePixels,
                            "glyphPixels": number(result.evidence["glyphPixels"]), "method": "validated full outer boundary"]
                }
            }
            return nil
        } catch { return nil }
    }

    static func resolveDisplayGlyphs(result resultPayload: Payload?, glyphs glyphPayloads: [Payload]?) -> RGB? {
        let result = Result(resultPayload), glyphs = (glyphPayloads ?? []).compactMap(Glyph.init)
        let foreground = result.foreground ?? result.displayForeground
        let background = result.surface ?? result.background, lettering = result.letteringColor
        guard let dominant = glyphs.first else { return foreground }
        let current = foreground.flatMap { color in glyphs.first { distance($0.color, color) <= 32 } }
        let outlined = lettering.flatMap { color in glyphs.first { distance($0.color, color) <= 40 } }
        let light = stableSort(glyphs.filter { low($0.color) >= 175 && high($0.color) >= 225 }, by: { $0.pixels > $1.pixels }).first
        if let foreground, let background, result.stroke == nil,
           (result.foreground != nil ? result.foregroundConfidence >= 0.7 : result.displayForeground != nil),
           low(delta(foreground, background)) >= 32, contrast(foreground, background) >= 3, contrast(dominant.color, background) < 2 {
            let direction = delta(foreground, background), squared = dot(direction, direction)
            if squared >= 3600 && glyphs.contains(where: { glyph in
                if glyph.coverage < 0.08 || glyph.bands < 3 || glyph.components < 3 { return false }
                let difference = delta(glyph.color, background), projection = dot(difference, direction) / squared
                return projection >= 0.5 && projection <= 1.2 && onAxis(difference, direction, projection, 16)
            }) {
                if result.foreground == nil, let endpoint = current?.endpoint,
                   zip(endpoint, foreground).allSatisfy({ $0 >= $1 }) { return endpoint }
                return foreground
            }
        }
        if result.foreground == nil, result.displayForeground != nil, let current, current.coverage >= 0.2, let background,
           distance(dominant.color, background) <= 24, contrast(current.color, background) >= 3,
           current.enclosed(by: dominant.color, atLeast: 0.85),
           dominant.enclosure.contains(where: { distance($0.color, current.color) <= 24 && $0.ratio < 0.2 }) { return current.color }
        if let current, let foreground, current.coverage >= 0.4, current.bands >= 5, current.energy >= 120,
           span(foreground) >= 100, result.foregroundConfidence < 0.7, distance(current.color, foreground) > 16 { return current.color }
        if result.foreground != nil, let current, let foreground, let background, current.coverage >= 0.25, current.bands >= 3,
           (outlined == nil || outlined === current || outlined!.coverage < 0.5 || outlined!.pixels < current.pixels),
           result.foregroundConfidence >= 0.85, result.stroke == nil, low(foreground) >= 175, span(foreground) < 40,
           contrast(foreground, background) >= contrast(dominant.color, background) * 2.5 { return foreground }
        if result.foreground != nil || (current?.coverage ?? 0) >= 0.5,
           let foreground, let lettering, distance(foreground, lettering) <= 24 {
            if (current?.coverage ?? 0) >= 0.5 ||
                ((current?.coverage ?? 0) >= 0.2 && (current?.bands ?? 0) >= 3 && distance(foreground, lettering) <= 16) ||
                span(foreground) >= 100 || (low(lettering) >= 40 && background.map { low($0) >= 225 } == true) { return foreground }
        }
        if result.foreground != nil, result.foregroundConfidence >= 0.5, let endpoint = dominant.darkEndpoint, dominant.bands >= 3 { return endpoint }
        if result.foreground == nil, let current, dominant !== current, current.coverage >= 0.65,
           dominant.coverage >= 0.65, dominant.bands >= 4, low(dominant.color) >= 175,
           dominant.energy >= current.energy * 1.8, distance(dominant.color, current.color) >= 48 {
            let bright = glyphs.first { $0 !== dominant && $0.coverage >= 0.25 && $0.bands >= 3 && $0.pixels >= dominant.pixels * 0.25 &&
                $0.energy >= dominant.energy * 1.2 && zip($0.color, dominant.color).allSatisfy({ $0 >= $1 }) && distance($0.color, dominant.color) <= 48 }
            return bright.map { other in zip(dominant.color, other.color).map { jsRound(($0 + $1) / 2) } } ?? dominant.color
        }
        if let current, let foreground, dominant !== current, dominant.coverage >= 0.75,
           dominant.score > current.score * 2.5, distance(dominant.color, foreground) <= 96 { return dominant.color }
        if let current, let light, current !== light, let stroke = result.stroke,
           current.coverage >= 0.15, current.pixels >= 24, current.bands >= 3, result.foregroundConfidence >= 0.7,
           distance(stroke, light.color) <= 24, current.enclosed(by: light) >= 0.85, light.enclosed(by: current) <= 0.15 { return foreground }
        if let light {
            let coloredCore = glyphs.first { $0.coverage >= 0.65 && $0.bands >= 3 && $0.components >= 3 && span($0.color) >= 60 &&
                $0.pixels >= light.pixels * 0.2 && $0.enclosed(by: light) >= 0.7 && light.enclosed(by: $0) <= 0.15 }
            if let coloredCore, let foreground, distance(coloredCore.color, foreground) <= 48, result.foregroundConfidence >= 0.6 { return coloredCore.color }
        }
        if result.foreground == nil, let outlined, let lettering, let light, high(lettering) < 80,
           outlined.coverage >= 0.6, outlined.enclosed(by: light) >= 0.6, light.enclosed(by: outlined) < 0.15,
           outlined.energy >= 100 { return lettering }
        let core = glyphs.first { glyph in
            glyph.coverage >= 0.2 && glyph.pixels >= dominant.pixels * 0.5 && glyphs.contains { other in
                other !== glyph && other.coverage >= 0.25 && glyph.enclosed(by: other) >= 0.85 &&
                    glyph.enclosed(by: other) - other.enclosed(by: glyph) >= 0.3
            }
        }
        if let core, low(core.color) < 175 || background.map({ contrast(core.color, $0) >= 3 }) == true,
           (light == nil || low(core.color) < 175 || distance(core.color, light!.color) <= 24),
           (outlined == nil || lettering.map { span($0) < 40 } == true || low(core.color) < 175) { return core.color }
        if let outlined, let lettering, let light, span(lettering) >= 100, outlined.coverage >= 0.6,
           (background == nil || contrast(lettering, background!) >= 1.75), outlined.pixels >= light.pixels,
           light.enclosed(by: outlined) >= 0.6, outlined.enclosed(by: light) < 0.3 { return lettering }
        if let outlined, let lettering, outlined.coverage >= 0.5 || span(lettering) >= 100,
           (light == nil || outlined.pixels >= light!.pixels * 1.8 ||
            (span(lettering) >= 100 && current != nil && foreground.map { low($0) < 175 } == true && outlined.score > current!.score * 1.8)),
           (background == nil || contrast(lettering, background!) >= 1.75) {
            if span(lettering) < 100, let current, let foreground, current.coverage >= 0.25, high(foreground) < 100,
               distance(foreground, lettering) > 25, outlined.score < current.score { return foreground }
            return lettering
        }
        if let current, let lettering, let foreground, let background, current.coverage < 0.25,
           number(result.lettering["pixels"]) >= 32, high(lettering) < 100, high(foreground) < 100, low(background) >= 225 { return lettering }
        if let current, let foreground, current.coverage >= 0.4, span(foreground) >= 100, low(foreground) < 150 { return foreground }
        if let foreground, let background {
            let plain = result.stroke == nil && result.foregroundConfidence >= 0.8 && result.backgroundConfidence >= 0.75
            let outlined = result.stroke.map { span(foreground) >= 40 && distance($0, background) <= 40 &&
                result.foregroundConfidence >= 0.75 && result.backgroundConfidence >= 0.5 } == true
            if plain || outlined {
                let direction = delta(foreground, background), squared = dot(direction, direction)
                if let best = glyphs.first(where: { $0.coverage >= 0.25 }), squared >= 3600 {
                    let difference = delta(best.color, background), projection = dot(difference, direction) / squared
                    if projection >= 0.25 && projection < 0.9 && onAxis(difference, direction, projection, 12) { return foreground }
                }
            }
        }
        if let current, let foreground, current.coverage >= 0.5 {
            if low(foreground) >= 175 {
                let interior = glyphs.first { glyph in glyph.coverage >= 0.5 && glyph.pixels >= current.pixels * 0.2 &&
                    glyph.enclosed(by: current.color, atLeast: 0.6) &&
                    current.enclosure.contains { distance($0.color, glyph.color) <= 24 && $0.ratio < 0.3 } }
                if let interior { return interior.color }
            }
            return foreground
        }
        let reliableSurface = background != nil && result.backgroundConfidence >= 0.75
        func backdropCounter(_ glyph: Glyph) -> Bool {
            guard let background, distance(glyph.color, background) <= 24, glyph.coverage < 0.5 else { return false }
            return glyphs.contains { $0 !== glyph && $0.coverage >= 0.6 && distance($0.color, background) >= 80 }
        }
        let best = glyphs.first { glyph in
            glyph.coverage >= (foreground == nil ? 0.2 : 0.25) && !backdropCounter(glyph) &&
                (!reliableSurface || distance(glyph.color, background!) >= 80)
        }
        guard let best else { return foreground }
        if let current, let foreground, let background, current.coverage >= 0.35, current.bands >= 3,
           distance(best.color, background) <= 48, distance(foreground, background) >= 80, contrast(foreground, background) >= 3 { return foreground }
        if let current, let foreground, let background, current.pixels >= 24, current.bands >= 3, current.energy >= 100,
           best.energy < current.energy * 0.6 {
            let axis = delta(foreground, background), difference = delta(best.color, background)
            let projection = dot(difference, axis) / max(1, dot(axis, axis))
            if projection >= 0.25 && projection <= 0.85 && onAxis(difference, axis, projection, 12) { return foreground }
        }
        if current != nil, let foreground, distance(foreground, best.color) <= 32 { return foreground }
        let enclosed = glyphs.first { glyph in glyph.pixels >= best.pixels * 0.25 && low(glyph.color) >= 175 &&
            glyph.enclosed(by: best.color, atLeast: 0.6) && best.enclosure.contains { distance($0.color, glyph.color) <= 24 && $0.ratio < 0.3 } }
        return enclosed?.color ?? best.color
    }

    static func sourceObservedDisplayInk(sample payload: Payload?) -> RGB? {
        func valid(_ color: RGB?) -> RGB? { color.flatMap { $0.allSatisfy { $0 >= 0 && $0 <= 255 } ? $0 : nil } }
        let result = Result(payload)
        if let display = valid(rgb((payload?["displayEvidence"] as? Payload)?["color"])) { return display }
        if let lettering = valid(result.letteringColor) { return lettering }
        guard let foreground = valid(result.foreground) else { return valid(result.displayForeground) }
        let background = valid(result.surface) ?? valid(result.background)
        if low(foreground) >= 225, let stroke = valid(result.stroke), number(result.confidence["stroke"]) >= 0.55,
           span(stroke) >= 40, let background, contrast(stroke, background) > contrast(foreground, background) { return stroke }
        return foreground
    }

    static func sourceDisplayInk(sample payload: Payload?) -> RGB? {
        let display = sourceObservedDisplayInk(sample: payload), result = Result(payload)
        func valid(_ color: RGB?) -> RGB? { color.flatMap { $0.allSatisfy { $0 >= 0 && $0 <= 255 } ? $0 : nil } }
        guard let display, let ink = valid(result.foreground) ?? valid(result.displayForeground),
              let backing = valid(result.captionBackground) ?? valid(result.surface) ?? valid(result.background),
              valid(result.stroke) == nil || number(result.confidence["stroke"]) < 0.55 else { return display }
        if result.foregroundConfidence >= 0.6, valid(result.foreground) != nil, span(display) < 24,
           span(ink) >= 40 || high(ink) < 48, contrast(ink, backing) >= 3, contrast(display, backing) * 1.5 < contrast(ink, backing) { return ink }
        let axis = delta(backing, ink), length = dot(axis, axis)
        if (axis.map(abs).max() ?? 0) < 96 || (high(ink) >= 48 && low(ink) <= 207) { return display }
        let projection = dot(delta(display, ink), axis) / length
        if projection < 0.15 || projection > 1.05 || !onAxis(delta(display, ink), axis, projection, 20) { return display }
        return contrast(display, backing) < 4.5 && contrast(ink, backing) >= 4.5 ? ink : display
    }
}
