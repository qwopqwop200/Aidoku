import CoreGraphics
import Foundation

/// Final light-lettering decisions. Source sampling is bounded and supplied by
/// the renderer's native Canvas-compatible reader; geometry is never moved.
enum NativeLightLettering {
    typealias RGB = [Double]
    struct Style {
        var fill: RGB
        var stroke: RGB?
        var strokeWidth: Double
        var background: RGB?
        var glowRadius: Double?
        var record: [String: Any]
    }
    struct Crop {
        let source: CGRect
        let width: Int
        let height: Int
        let scale: Double
        let glyph: Double
        let core: CGRect
        let plate: CGRect
    }
    struct Analysis {
        var style: Style?
        var rejection: String?
        var record: [String: Any] = [:]
    }
    static func saturated(mode: String, font: Double, strokeWidth: Double,
                          ring: [String: Any], currentPlate: RGB?) -> Style? {
        guard ["readability-panel", "rotated-panel"].contains(mode), font >= 12, strokeWidth <= 0,
              ring["kind"] as? String == "outline", ring["action"] as? String == "none",
              let core = rgb(ring["core"]), let outline = rgb(ring["outline"]), let plate = rgb(ring["plate"]),
              let currentPlate, valid(currentPlate), luminance(core) > 0.6, luminance(outline) < 0.45,
              (outline.max() ?? 0) - (outline.min() ?? 0) >= 80, gap(plate, core) <= 24,
              gap(currentPlate, plate) <= 8, contrast(outline, plate) >= 3, contrast(core, outline) >= 3,
              number(ring["hug"]) >= 0.7, number(ring["uniform"]) >= 0.6 else { return nil }
        let glow = number(ring["width"]) >= 0.1
        return Style(fill: core, stroke: outline, strokeWidth: max(1.5, quarter(font * 0.24)),
            background: nil, glowRadius: glow ? quarter(min(3, font * 0.2)) : nil,
            record: ["action": "saturated-outline", "fill": core, "outline": outline, "glow": glow])
    }
    static func hasLightEvidence(sampledFill: RGB?, sampledStroke: RGB?, strokeConfidence: Double,
                                 sampledBackground: RGB?, ring: [String: Any]) -> Bool {
        if let sampledFill, valid(sampledFill), luminance(sampledFill) > 0.5 { return true }
        if let sampledStroke, valid(sampledStroke), strokeConfidence >= 0.55, luminance(sampledStroke) > 0.5 { return true }
        if let sampledBackground, valid(sampledBackground), luminance(sampledBackground) < 0.3 { return true }
        if let core = rgb(ring["core"]), luminance(core) > 0.5 { return true }
        if let values = ring["surface"] as? [Double], values.count >= 3 {
            let surface = Array(values.prefix(3)); if valid(surface), luminance(surface) < 0.2 { return true }
        }
        return false
    }
    static func hasLightEvidence(sample: [String: Any], ring: [String: Any]) -> Bool {
        hasLightEvidence(sampledFill: sample["foreground"] as? RGB, sampledStroke: sample["stroke"] as? RGB,
            strokeConfidence: (sample["confidence"] as? [String: Any])?["stroke"] as? Double ?? 0,
            sampledBackground: sample["background"] as? RGB, ring: ring)
    }
    static func darkInkEligible(_ ink: RGB, plate: RGB, font: Double) -> Bool {
        valid(ink) && valid(plate) && font >= 6 && luminance(ink) < 0.2 &&
            luminance(ink) < luminance(plate) && contrast(ink, plate) >= 3
    }
    /// Called in source order only after owner, style, and cheap evidence gates.
    /// The budget is charged before the source read, just like the frozen pass.
    static func crop(bounds b: [Double], frame: CGRect, imageSize: CGSize, sourceFont: Double?,
                     plate: CGRect, remainingPixels: inout Int) -> (crop: Crop?, rejection: String?) {
        guard b.count == 4, b.allSatisfy(\.isFinite), b[2] > 0, b[3] > 0,
              finite(frame), frame.size.width > 0, frame.size.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0 else { return (nil, nil) }
        let glyphCSS = sourceFont.flatMap { $0 > 0 ? $0 : nil } ?? min(b[2] * frame.width, b[3] * frame.height) * 0.7
        guard glyphCSS.isFinite, glyphCSS >= 8 else { return (nil, nil) }
        let iw = Double(imageSize.width), ih = Double(imageSize.height), glyphPx = glyphCSS * iw / frame.width
        let pad = max(3, glyphPx * 0.5)
        let x0 = max(0, floor(b[0] * iw - pad)), y0 = max(0, floor(b[1] * ih - pad))
        let x1 = min(iw, ceil((b[0] + b[2]) * iw + pad)), y1 = min(ih, ceil((b[1] + b[3]) * ih + pad))
        let sw = x1 - x0, sh = y1 - y0
        guard sw.isFinite, sh.isFinite, sw >= 8, sh >= 8 else { return (nil, nil) }
        let k = min(1, 24 / glyphPx, sqrt(16_384 / (sw * sh)))
        let wd = max(1, floor(sw * k + 0.5)), hd = max(1, floor(sh * k + 0.5)), g = glyphPx * k
        guard g.isFinite, g >= 8 else { return (nil, "resolution") }
        guard wd.isFinite, hd.isFinite, wd <= 49_152, hd <= 49_152,
              wd * hd <= Double(remainingPixels) else { return (nil, "budget") }
        let w = Int(wd), h = Int(hd); remainingPixels -= w * h
        let bx0 = max(0, floor((b[0] * iw - x0) * k)), by0 = max(0, floor((b[1] * ih - y0) * k))
        let bx1 = min(wd, ceil(((b[0] + b[2]) * iw - x0) * k)), by1 = min(hd, ceil(((b[1] + b[3]) * ih - y0) * k))
        let px0 = ((plate.minX - frame.minX) / frame.width * iw - x0) * k
        let py0 = ((plate.minY - frame.minY) / frame.height * ih - y0) * k
        let px1 = ((plate.maxX - frame.minX) / frame.width * iw - x0) * k
        let py1 = ((plate.maxY - frame.minY) / frame.height * ih - y0) * k
        return (Crop(source: CGRect(x: x0, y: y0, width: sw, height: sh), width: w, height: h, scale: k, glyph: g,
            core: CGRect(x: bx0, y: by0, width: bx1 - bx0, height: by1 - by0),
            plate: CGRect(x: px0, y: py0, width: px1 - px0, height: py1 - py0)), nil)
    }
    static func analyze(rgba: [UInt8], crop: Crop, font: Double, ink: RGB, plate: RGB,
                        neighborOverlapsPlate: Bool) -> Analysis {
        let w = crop.width, h = crop.height, g = crop.glyph
        guard w > 0, h > 0, w <= 49_152 / h, rgba.count == w * h * 4, g.isFinite, g > 0, g <= 24,
              finite(crop.core), finite(crop.plate), valid(ink), valid(plate) else { return Analysis() }
        let n = w * h
        func inBox(_ i: Int) -> Bool { let x = Double(i % w), y = Double(i / w)
            return x >= crop.core.origin.x && x < crop.core.origin.x + crop.core.size.width &&
                y >= crop.core.origin.y && y < crop.core.origin.y + crop.core.size.height }
        var lum = [Int](repeating: 0, count: n), hist = [Int](repeating: 0, count: 256), boxN = 0
        for i in 0..<n { let p = i * 4
            lum[i] = (54 * Int(rgba[p]) + 183 * Int(rgba[p + 1]) + 19 * Int(rgba[p + 2])) >> 8
            if inBox(i) { hist[lum[i]] += 1; boxN += 1 }
        }
        guard boxN >= 64 else { return Analysis() }
        let total = (0..<256).reduce(0) { $0 + $1 * hist[$1] }
        var best = -1.0, cut = 128, sumB = 0, countB = 0
        for v in 0..<255 {
            countB += hist[v]; if countB == 0 { continue }; let countF = boxN - countB; if countF == 0 { break }
            sumB += v * hist[v]
            let delta = Double(sumB) / Double(countB) - Double(total - sumB) / Double(countF)
            let between = Double(countB) * Double(countF) * delta * delta
            if between > best { best = between; cut = v }
        }
        var darkSum = 0, darkN = 0, lightSum = 0, lightN = 0
        for v in 0..<256 { if v <= cut { darkSum += v * hist[v]; darkN += hist[v] }
            else { lightSum += v * hist[v]; lightN += hist[v] } }
        guard darkN > 0, lightN > 0, Double(lightSum) / Double(lightN) - Double(darkSum) / Double(darkN) >= 80
        else { return Analysis(rejection: "separation") }
        var seen = 0, top90 = 255
        for v in stride(from: 255, through: cut + 1, by: -1) { seen += hist[v]; if Double(seen) >= Double(lightN) * 0.1 { top90 = v; break } }
        let lightCut = max(cut, top90 - 40)
        lightN = ((lightCut + 1)..<256).reduce(0) { $0 + hist[$1] }
        guard lightN >= 24 else { return Analysis(rejection: "separation") }
        let light = lum.map { $0 > lightCut }
        func components(_ target: Bool) -> (labels: [Int], open: [Bool]) {
            var labels = [Int](repeating: 0, count: n), open = [false]
            for start in 0..<n where light[start] == target && labels[start] == 0 {
                let label = open.count; var stack = [start], edge = false; labels[start] = label
                while let i = stack.popLast() { let x = i % w
                    if x == 0 || x == w - 1 || i < w || i >= n - w { edge = true }
                    for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, i >= w ? i - w : -1, i + w < n ? i + w : -1]
                    where j >= 0 && light[j] == target && labels[j] == 0 { labels[j] = label; stack.append(j) }
                }
                open.append(edge)
            }
            return (labels, open)
        }
        let enclosedLight = components(true), enclosedDark = components(false)
        func distances(_ seed: Bool) -> [Int] {
            var d = light.map { $0 == seed ? 0 : w + h + 2 }
            for y in 0..<h { for x in 0..<w { let i = y * w + x
                if x > 0 { d[i] = min(d[i], d[i - 1] + 1) }; if y > 0 { d[i] = min(d[i], d[i - w] + 1) }
            } }
            for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) { let i = y * w + x
                if x < w - 1 { d[i] = min(d[i], d[i + 1] + 1) }; if y < h - 1 { d[i] = min(d[i], d[i + w] + 1) }
            } }
            return d
        }
        let depth = distances(false), toLight = distances(true)
        var darkIn = 0, darkEnclosed = 0, sealedList: [Int] = [], enclosedN = 0, depths: [Int] = [], fillList: [Int] = []
        for i in 0..<n where inBox(i) {
            if !light[i], lum[i] <= cut { darkIn += 1
                if !enclosedDark.open[enclosedDark.labels[i]] { darkEnclosed += 1; sealedList.append(i) }
            }
            if light[i] {
                if !enclosedLight.open[enclosedLight.labels[i]] { enclosedN += 1 }
                depths.append(depth[i]); if depth[i] >= 2 { fillList.append(i) }
            }
        }
        depths.sort()
        let lightShare = Double(lightN) / Double(boxN), enclosed = Double(enclosedN) / Double(lightN)
        let stroke = depths.isEmpty ? Double.nan : 2 * Double(depths[Int(floor(Double(depths.count) * 0.9))]) / g
        let sealedDark = darkIn > 0 ? Double(darkEnclosed) / Double(darkIn) : 0
        var stats: [String: Any] = ["light": hundredth(lightShare), "enclosed": hundredth(enclosed),
            "stroke": hundredth(stroke), "sealedDark": hundredth(sealedDark)]
        guard enclosed >= 0.7, lightShare >= 0.08, lightShare <= 0.55, stroke >= 0.05, stroke <= 0.4, fillList.count >= 12
        else { return Analysis(rejection: "topology", record: stats) }
        let p = crop.plate, band = max(2, Int(floor(g * 0.18 + 0.5)))
        var farList: [Int] = [], farDark = 0
        for i in 0..<n { let x = Double(i % w) + 0.5, y = Double(i / w) + 0.5
            if light[i] || toLight[i] <= band || x < p.minX || x >= p.maxX || y < p.minY || y >= p.maxY { continue }
            farList.append(i); if lum[i] <= cut { farDark += 1 }
        }
        guard farList.count >= 24 else { return Analysis(rejection: "surface", record: stats) }
        func median(_ list: [Int]) -> RGB { var hist = [Int](repeating: 0, count: 768), output = [Double](repeating: 0, count: 3)
            for i in list { for c in 0..<3 { hist[c * 256 + Int(rgba[i * 4 + c])] += 1 } }
            for c in 0..<3 { var count = 0; for v in 0..<256 { count += hist[c * 256 + v]
                if count > list.count / 2 { output[c] = Double(v); break }
            } }
            return output
        }
        let fill = median(fillList), surface = median(farList), surfaceDark = Double(farDark) / Double(farList.count)
        if sealedList.count >= 8 { let sealed = median(sealedList)
            if gap(sealed, surface) > 48 && !(luminance(sealed) < 0.05 && luminance(surface) < 0.05) {
                stats["sealed"] = sealed; stats["surface"] = surface
                return Analysis(rejection: "halo", record: stats)
            }
        }
        stats["surfaceDark"] = hundredth(surfaceDark)
        func pixel(_ i: Int) -> RGB { [Double(rgba[i * 4]), Double(rgba[i * 4 + 1]), Double(rgba[i * 4 + 2])] }
        let like = farList.filter { gap(pixel($0), surface) <= 48 }.count
        let margin = max(2, g * 0.2)
        let l = max(0, floor(p.minX - margin)), t = max(0, floor(p.minY - margin))
        let r = min(Double(w), ceil(p.maxX + margin)), b = min(Double(h), ceil(p.maxY + margin))
        var around = 0, aroundLike = 0
        if l < r && t < b { for y in Int(t)..<Int(b) { for x in Int(l)..<Int(r) {
            if Double(x) + 0.5 >= p.minX && Double(x) + 0.5 < p.maxX && Double(y) + 0.5 >= p.minY && Double(y) + 0.5 < p.maxY { continue }
            around += 1; if gap(pixel(y * w + x), surface) <= 48 { aroundLike += 1 }
        } } }
        stats["like"] = hundredth(Double(like) / Double(farList.count))
        stats["around"] = around > 0 ? hundredth(Double(aroundLike) / Double(around)) as Any : NSNull()
        let required = font >= 18 ? 3.0 : 4.5
        guard surfaceDark >= 0.75, luminance(surface) < luminance(plate), contrast(fill, surface) >= required,
              Double(like) >= Double(farList.count) * 0.7, around >= 16, Double(aroundLike) >= Double(around) * 0.45,
              !neighborOverlapsPlate else { return Analysis(rejection: "surface", record: stats) }
        stats["action"] = "dark-surface"; stats["fill"] = fill; stats["plate"] = surface; stats["before"] = [ink, plate]
        return Analysis(style: Style(fill: fill, stroke: nil, strokeWidth: 0, background: surface, glowRadius: 0, record: stats), record: stats)
    }
    private static func number(_ x: Any?) -> Double { x as? Double ?? .nan }
    private static func rgb(_ x: Any?) -> RGB? { guard let a = x as? [Double], valid(a) else { return nil }; return a }
    private static func valid(_ a: RGB) -> Bool { a.count == 3 && a.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 255 } }
    private static func finite(_ r: CGRect) -> Bool { [r.origin.x, r.origin.y, r.size.width, r.size.height].allSatisfy(\.isFinite) }
    private static func luminance(_ a: RGB) -> Double { NativeTranslationSourceStylePostPolish.luminance(a) }
    private static func contrast(_ a: RGB, _ b: RGB) -> Double { let x = luminance(a), y = luminance(b); return (max(x,y) + 0.05) / (min(x,y) + 0.05) }
    private static func gap(_ a: RGB, _ b: RGB) -> Double { zip(a,b).map { abs($0 - $1) }.max() ?? 0 }
    private static func quarter(_ x: Double) -> Double { floor(x * 4 + 0.5) / 4 }
    private static func hundredth(_ x: Double) -> Double { floor(x * 100 + 0.5) / 100 }
}
