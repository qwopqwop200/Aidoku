import CoreGraphics
import Foundation

/// Source-image crop admission and punctuation probes. Coordinates remain in the
/// source page until the final raster transform, including synthetic page-edge margins.
final class NativeSpatialSourceCrop {
    struct Prepared {
        let pixels: NativeRestorationPixels
        let crop: CGRect
        let source: CGRect
        let box: CGRect
        let auxiliary: [CGRect]
        let excluded: [CGRect]
        let marks: [CGRect]
        let leadingRule: Bool
        let sx: CGFloat
        let sy: CGFloat
        let synthetic: [UInt8]
        var nominalScale: CGFloat? = nil
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - crop.minX) * sx, y: (rect.minY - crop.minY) * sy, width: rect.width * sx, height: rect.height * sy)
        }
    }
    let image: CGImage
    let reader: NativeSourcePixelReader
    var restorationBudget = 1_572_864
    var slantedPageFallbackBudget = 1_048_576
    var forcedBudget = 6_000_000
    var rubyBudget = 262_144
    var markBudget = 262_144
    var adjacentDotBudget = 262_144
    var remaining: Int
    var remainingMarks: Int

    init(image: CGImage, reader: NativeSourcePixelReader, eligibleCount: Int) {
        self.image = image; self.reader = reader; remaining = eligibleCount; remainingMarks = eligibleCount
    }
    func pixelRect(_ r: [CGFloat]) -> CGRect? {
        guard r.count == 4, r.allSatisfy(\.isFinite), r[2] > 0, r[3] > 0 else { return nil }
        return CGRect(x: r[0] * CGFloat(image.width), y: r[1] * CGFloat(image.height),
                      width: r[2] * CGFloat(image.width), height: r[3] * CGFloat(image.height))
    }
    func normalized(_ r: CGRect) -> [CGFloat] {
        [r.minX / CGFloat(image.width), r.minY / CGFloat(image.height), r.width / CGFloat(image.width), r.height / CGFloat(image.height)]
    }
    func probeMarks(item: NativeTranslationLayoutItem, source: CGRect, palette: NativeRestorationPixels.Palette?, excluded: [CGRect], sample: [String: Any]? = nil, frame: CGRect? = nil) -> [CGRect] {
        let sourceFrame = frame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? item.sourceFrame
        guard sourceFrame.count == 4, sourceFrame[2] > 0, let size = item.sourceFontSize,
              let paper = sample.flatMap({ NativeRestorationPixels.rgb($0["background"]) }) ?? palette?.verifiedBackground else { return [] }
        let glyph = Double(size) * Double(image.width) / Double(sourceFrame[2])
        guard glyph.isFinite, glyph >= 6 else { return [] }
        let vertical = item.sourceVertical || item.sourceSingleColumn && source.height > source.width * 1.2
        let leadingDots = vertical && item.sourceSingleColumn && item.text.range(of: #"^[.⋯…‥・･]{2,}"#, options: .regularExpression) != nil
        let foreground = sample.flatMap { NativeRestorationPixels.rgb($0["foreground"]) } ?? palette?.verifiedForeground ??
            (paper.minimum >= 200 ? NativeRestorationRGB([0, 0, 0]) : paper.maximum <= 55 ? NativeRestorationRGB([255, 255, 255]) : nil)
        guard let foreground else { return [] }
        var allowance = min(65_536, markBudget / max(1, remainingMarks)); remainingMarks -= 1
        let sourceInk = sample?["sourceInk"] as? [String: Any] ?? palette?.sourceInk
        let stroke = sample.flatMap { NativeRestorationPixels.rgb($0["stroke"]) } ?? palette?.stroke ?? NativeRestorationPixels.rgb(sourceInk?["stroke"])
        let segmentationPalette = NativeSourceGlyphSegmentation.Palette(foreground: foreground.channels,
            background: paper.channels, stroke: stroke?.channels)
        func probe(_ side: NativeSourceGlyphSegmentation.Side, reach: Double, pair: [Double]?) -> (rects: [CGRect], open: Bool, last: [Double]?) {
            let end = side == .end
            let lo = end ? Double(vertical ? source.maxY : source.maxX) - glyph * 0.9 : Double(vertical ? source.minY : source.minX) - glyph * reach
            let x0 = max(0, floor(vertical ? Double(source.minX) - glyph * 0.5 : lo))
            let y0 = max(0, floor(vertical ? lo : Double(source.minY) - glyph * 0.5))
            let x1 = min(Double(image.width), ceil(vertical ? Double(source.maxX) + glyph * 0.5 : lo + glyph * (reach + 0.9)))
            let y1 = min(Double(image.height), ceil(vertical ? lo + glyph * (reach + 0.9) : Double(source.maxY) + glyph * 0.5))
            let sourceW = x1 - x0, sourceH = y1 - y0
            guard sourceW > 0, sourceH > 0, allowance > 0 else { return ([], false, nil) }
            let scale = min(1, sqrt(min(32_768, Double(allowance) / 2) / max(1, sourceW * sourceH)))
            let w = Int(floor(sourceW * scale)), h = Int(floor(sourceH * scale))
            guard w >= 4, h >= 4, glyph * scale >= 6, w * h <= markBudget else { return ([], false, nil) }
            markBudget -= w * h; allowance -= w * h
            guard let rgba = try? reader.read(x: x0, y: y0, sourceWidth: sourceW, sourceHeight: sourceH, width: w, height: h) else { return ([], false, nil) }
            let sx = Double(w) / sourceW, sy = Double(h) / sourceH
            func rect(_ r: CGRect) -> CGRect { CGRect(x: (Double(r.minX) - x0) * sx, y: (Double(r.minY) - y0) * sy, width: Double(r.width) * sx, height: Double(r.height) * sy) }
            let found = NativeSourceGlyphSegmentation.rowEndMarks(rgba: rgba, width: w, height: h, box: rect(source),
                glyph: glyph * min(sx, sy), palette: segmentationPalette, vertical: vertical, side: side, excluded: excluded.map(rect),
                pair: pair?.map { $0 * min(sx, sy) }, allowDotRun: leadingDots)
            let rects = found.rects.map { CGRect(x: Double($0.minX) / sx + x0, y: Double($0.minY) / sy + y0,
                                                width: Double($0.width) / sx, height: Double($0.height) / sy) }
            let last = found.rects.last.map { [Double($0.minX) / sx, Double($0.minY) / sy, Double($0.width) / sx, Double($0.height) / sy] }
            return (rects, found.open, last)
        }
        var end = probe(.end, reach: 2, pair: nil)
        if end.open { end = probe(.end, reach: 4, pair: nil) }
        if end.open { end = ([], false, nil) }
        let pair = end.last.map { vertical ? [$0[3], $0[2]] : [$0[2], $0[3]] }
        let start = probe(.start, reach: leadingDots ? 6 : 1.4, pair: pair)
        var marks = end.rects + start.rects
        if leadingDots, let interior = item.balloonInterior, interior.contourVerified, interior.rect.count == 4, interior.rect[3] > 0 {
            let x0 = max(0, floor(Double(source.minX) - glyph * 1.4)), y0 = max(0, floor(Double(source.minY) - glyph * 4))
            let x1 = min(Double(image.width), ceil(Double(source.maxX) + glyph * 1.4)), y1 = min(Double(image.height), ceil(Double(source.maxY) + glyph * 4))
            let w = Int(x1 - x0), h = Int(y1 - y0)
            if w > 4 && h > 4 && w * h <= adjacentDotBudget {
                adjacentDotBudget -= w * h
                if let rgba = try? reader.read(x: x0, y: y0, sourceWidth: Double(w), sourceHeight: Double(h), width: w, height: h) {
                    let dots = NativeSourceGlyphSegmentation.adjacentDotRun(rgba: rgba, width: w, height: h,
                        box: CGRect(x: Double(source.minX) - x0, y: Double(source.minY) - y0, width: source.width, height: source.height),
                        glyph: glyph, palette: segmentationPalette, excluded: excluded.map {
                            CGRect(x: Double($0.minX) - x0, y: Double($0.minY) - y0, width: $0.width, height: $0.height)
                        })
                    for dot in dots {
                        let nx = (Double(dot.midX) + x0) / Double(image.width), ny = (Double(dot.midY) + y0) / Double(image.height)
                        let row = Int(floor((ny - Double(interior.rect[1])) / Double(interior.rect[3]) * Double(interior.spans.count / 2)))
                        if row >= 0 && row < interior.spans.count / 2 && nx >= interior.spans[row * 2] && nx <= interior.spans[row * 2 + 1] {
                            marks.append(CGRect(x: Double(dot.minX) + x0, y: Double(dot.minY) + y0, width: dot.width, height: dot.height))
                        }
                    }
                }
            }
        }
        return marks
    }

    func prepare(item: NativeTranslationLayoutItem, palette: NativeRestorationPixels.Palette?, excluded: [CGRect], forced: Bool = false, detached: Bool = false, sample: [String: Any]? = nil, frame: CGRect? = nil) -> Prepared? {
        let allowance: Int
        if forced { allowance = min(750_000, forcedBudget) }
        else if detached { allowance = min(262_144, slantedPageFallbackBudget) }
        else { allowance = min(262_144, restorationBudget / max(1, remaining)); remaining -= 1 }
        let sourceFrame = frame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? item.sourceFrame
        guard sourceFrame.count == 4, sourceFrame.allSatisfy(\.isFinite),
              sourceFrame[2] > 0, sourceFrame[3] > 0,
              let source = pixelRect(item.sourceBounds), source.width > 0, source.height > 0 else { return nil }
        let auxiliaryBounds = (forced ? item.auxiliaryInkRects : Array(item.auxiliaryInkRects.prefix(32))).filter {
            $0.count == 4 && $0.allSatisfy(\.isFinite) && $0[2] > 0 && $0[3] > 0
        }
        let auxiliary = auxiliaryBounds.compactMap(pixelRect)
        let sourceFont = Double(item.sourceFontSize ?? 8)
        let cropFont = forced && (sourceFont == 0 || sourceFont.isNaN) ? 8 : sourceFont
        let glyph = max(8, cropFont * Double(image.width) / Double(sourceFrame[2]))
        let pad: CGFloat = forced ? CGFloat(max(32, min(160, glyph * 2.5))) : 24
        let leadingRule = !forced && item.sourceVertical && item.sourceSingleColumn && palette?.stroke != nil
        let topPad = leadingRule ? pad + min(120, source.width * 3) : pad
        let bottomPad = !forced && item.sourceVertical && item.balloonInterior?.contourVerified != true && source.height <= source.width * 6 ?
            max(pad, min(64, source.width * 0.75)) : pad
        let marks = forced || detached ? [] : probeMarks(item: item, source: source, palette: palette, excluded: excluded, sample: sample, frame: frame)
        // Keep the descriptor's normalized union before converting back to pixels.
        // Adding pixel-space endpoints first can change ceil by one pixel at a
        // floating-point boundary (including an observed row-end punctuation box).
        let owned = [item.sourceBounds] + Array(auxiliaryBounds) + marks.map(normalized)
        let left = owned.map { $0[0] }.min()! * CGFloat(image.width)
        let top = owned.map { $0[1] }.min()! * CGFloat(image.height)
        let rightBound = owned.map { $0[0] + $0[2] }.max()! * CGFloat(image.width)
        let bottomBound = owned.map { $0[1] + $0[3] }.max()! * CGFloat(image.height)
        let x = forced ? max(0, floor(left - pad)) : left < 3 ? floor(left) - pad : max(0, floor(left) - pad)
        let y = forced ? max(0, floor(top - pad)) : top < 3 ? floor(top) - topPad : max(0, floor(top) - topPad)
        var right = forced ? min(CGFloat(image.width), ceil(rightBound + pad)) : CGFloat(image.width) - rightBound < 3 ? ceil(rightBound) + pad : min(CGFloat(image.width), ceil(rightBound) + pad)
        let bottom = forced ? min(CGFloat(image.height), ceil(bottomBound + pad)) : CGFloat(image.height) - bottomBound < 3 ? ceil(bottomBound) + bottomPad : min(CGFloat(image.height), ceil(bottomBound) + bottomPad)
        let edge = x < 0 || y < 0 || right > CGFloat(image.width) || bottom > CGFloat(image.height)
        let rubyPadding = !forced && item.sourceVertical && item.sourceCleanupLexical && source.height >= source.width * 2.5 ? min(96, source.width * 0.8) : 0
        if rubyPadding > 0 && !edge && auxiliary.isEmpty && rubyBudget >= 1024, let palette, let foreground = palette.verifiedForeground, let background = palette.verifiedBackground,
           foreground.maximum <= 80 && background.minimum >= 220 {
            let expanded = min(CGFloat(image.width), ceil(right + rubyPadding)), pw = expanded - x, ph = bottom - y
            let scale = min(1, sqrt(Double(min(32_768, rubyBudget)) / Double(pw * ph)))
            let w = max(1, Int(floor(Double(pw) * scale))), h = max(1, Int(floor(Double(ph) * scale)))
            rubyBudget -= w * h
            if let rgba = try? reader.read(x: Double(x), y: Double(y), sourceWidth: Double(pw), sourceHeight: Double(ph), width: w, height: h) {
                let raw = (0..<(w * h)).map { i -> UInt8 in max(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]) < 110 ? 1 : 0 }
                let sx = CGFloat(w) / pw, sy = CGFloat(h) / ph
                func local(_ r: CGRect) -> CGRect { CGRect(x: (r.minX - x) * sx, y: (r.minY - y) * sy, width: r.width * sx, height: r.height * sy) }
                let inferred = NativeSourceGlyphSegmentation.inferVerticalRuby(raw: raw, rgba: rgba, width: w, height: h, box: local(source), background: background.channels)
                if inferred.contains(where: { r in !excluded.map(local).contains { $0.intersects(r) } }) && sqrt(Double(allowance) / Double(pw * ph)) >= 0.75 { right = expanded }
            }
        }
        let crop = CGRect(x: x, y: y, width: right - x, height: bottom - y)
        guard crop.width >= 8, crop.height >= 8 else { return nil }
        let scale = min(1, sqrt(Double(allowance) / Double(crop.width * crop.height)))
        guard scale >= (forced ? 0.55 : 0.75) else { return nil }
        let w = max(forced ? 8 : 1, Int(floor(Double(crop.width) * scale))), h = max(forced ? 8 : 1, Int(floor(Double(crop.height) * scale)))
        guard w >= 8, h >= 8, w * h <= (forced ? forcedBudget : detached ? slantedPageFallbackBudget : restorationBudget) else { return nil }
        if forced { forcedBudget -= w * h }
        else if detached { slantedPageFallbackBudget -= w * h }
        else { restorationBudget -= w * h }
        let sx = CGFloat(w) / crop.width, sy = CGFloat(h) / crop.height
        let dl = edge ? Int(floor(Double((max(0, x) - x) * sx) + 0.5)) : 0
        let dt = edge ? Int(floor(Double((max(0, y) - y) * sy) + 0.5)) : 0
        let dr = edge ? Int(floor(Double((min(CGFloat(image.width), right) - x) * sx) + 0.5)) : w
        let db = edge ? Int(floor(Double((min(CGFloat(image.height), bottom) - y) * sy) + 0.5)) : h
        let original: [UInt8]?
        if edge {
            let clipped = CGRect(x: max(0, x), y: max(0, y), width: min(CGFloat(image.width), right) - max(0, x),
                height: min(CGFloat(image.height), bottom) - max(0, y))
            original = Self.edgePixels(image: image, source: clipped,
                destination: CGRect(x: dl, y: dt, width: dr - dl, height: db - dt), width: w, height: h)
        } else {
            original = try? reader.read(x: Double(x), y: Double(y), sourceWidth: Double(crop.width), sourceHeight: Double(crop.height), width: w, height: h)
        }
        guard var rgba = original else { return nil }
        var synthetic = [UInt8](repeating: 0, count: w * h)
        if edge { for yy in 0..<h { for xx in 0..<w {
            guard xx < dl || yy < dt || xx >= dr || yy >= db else { continue }
            let i = yy * w + xx; synthetic[i] = 1
            if let background = sample.flatMap({ NativeRestorationPixels.rgb($0["background"]) }) ?? palette?.verifiedBackground {
                for c in 0..<3 { rgba[i * 4 + c] = NativeRestorationPixels.clamp(background.channels[c]) }; rgba[i * 4 + 3] = 255
            } else {
                let from = min(db - 1, max(dt, yy)) * w + min(dr - 1, max(dl, xx))
                for c in 0..<4 { rgba[i * 4 + c] = rgba[from * 4 + c] }
            }
        } } }
        var pixels = NativeRestorationPixels(width: w, height: h); pixels.rgba = rgba
        func local(_ r: CGRect) -> CGRect { CGRect(x: (r.minX - x) * sx, y: (r.minY - y) * sy, width: r.width * sx, height: r.height * sy) }
        return Prepared(pixels: pixels, crop: crop, source: source, box: local(source), auxiliary: auxiliary.map(local),
                        excluded: excluded.map(local), marks: marks.map(local), leadingRule: leadingRule, sx: sx, sy: sy, synthetic: synthetic, nominalScale: CGFloat(scale))
    }

    /// Canvas page-edge draws round the clamped destination before sampling.
    /// Preserve that affine transform independently of the virtual donor margin.
    static func edgePixels(image: CGImage, source: CGRect, destination: CGRect, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, width <= 4_194_304 / height,
              [destination.minX, destination.minY, destination.width, destination.height].allSatisfy({ $0.isFinite && $0 == floor($0) }),
              source.width > 0, source.height > 0, destination.width > 0, destination.height > 0,
              destination.minX >= 0, destination.minY >= 0, destination.maxX <= CGFloat(width), destination.maxY <= CGFloat(height),
              let crop = try? NativeSourcePixelReader.draw(image: image, x: Double(source.minX), y: Double(source.minY),
                sourceWidth: Double(source.width), sourceHeight: Double(source.height),
                width: Int(destination.width), height: Int(destination.height)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let x = Int(destination.minX), y = Int(destination.minY), cropWidth = Int(destination.width), cropHeight = Int(destination.height)
        for row in 0..<cropHeight {
            let from = row * cropWidth * 4, to = ((y + row) * width + x) * 4
            rgba.replaceSubrange(to..<(to + cropWidth * 4), with: crop[from..<(from + cropWidth * 4)])
        }
        return rgba
    }

}
