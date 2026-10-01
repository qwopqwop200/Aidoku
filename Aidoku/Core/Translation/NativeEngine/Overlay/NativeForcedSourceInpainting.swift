import CoreGraphics
import Foundation

/// Final source-readability erasure, with independent core/outline and donor proofs.
enum NativeForcedSourceInpainting {
    struct Options {
        var auxiliary: [CGRect] = []
        var excluded: [CGRect] = []
        var donorExcluded: [CGRect] = []
        var polygons: [[CGPoint]] = []
        var excludedPolygons: [[CGPoint]] = []
        var trailing: Double = 0
        var vertical = false
        var requireSafeDonors = false
        var glyphSize: Double = 0
        var excludedMask: [UInt8]? = nil
        var protected: [UInt8]? = nil
    }
    struct Result {
        let rgba: [UInt8]
        let layoutSafe: [UInt8]
        let erased: Int
        let method: String
        let quality: NativeResidualProof.Quality?
        let sourceTouchesCropEdge: Int
        let postFillPaletteInkPixels: Int
        let sourceRemainingInk: Int
        let sourceCorePixels: Int
        let sourceOutlinePixels: Int
        let sourceRemainingOutline: Int
        let forcedCoverage: Double
        let forcedOutlineCoverage: Double
        let forcedMaskMode: String
        var sourceGlyphsVerified: Bool { true }
        var sourceErasureVerified: Bool { true }
        var preservedPixels: Int { 0 }
        var preservedCore: Int { 0 }
    }
    struct Outcome {
        var result: Result?
        var failure: String
    }
    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite) && rect.size.width > 0 && rect.size.height > 0
    }
    static func restore(rgba: [UInt8], width w: Int, height h: Int, box: CGRect,
                        palette: NativeRestorationPixels.Palette?, options suppliedOptions: Options = Options()) -> Outcome {
        func fail(_ reason: String) -> Outcome { Outcome(result: nil, failure: reason) }
        guard w >= 5, h >= 5, w <= 1_000_000 / h, rgba.count == w * h * 4, valid(box) else { return fail("invalid-crop") }
        let n = w * h
        var options = suppliedOptions
        func normalizedMask(_ input: [UInt8]?) -> [UInt8]? {
            guard var mask = input else { return nil }
            if mask.count < n { mask.append(contentsOf: repeatElement(0, count: n - mask.count)) }
            else if mask.count > n { mask.removeLast(mask.count - n) }
            return mask
        }
        // Missing typed-array cells are undefined (false) in the browser.
        options.excludedMask = normalizedMask(options.excludedMask)
        options.protected = normalizedMask(options.protected)
        let geometry = NativeSourceGlyphSegmentation.geometryMask(width: w, height: h,
            polygons: options.polygons, excluded: options.excludedPolygons, margin: 7)?.mask
        let boxes = ([box] + options.auxiliary).filter(valid)
        var bounds = [UInt8](repeating: 0, count: n), ownedCore = bounds, protectedPixels = bounds
        let margin = max(8, min(24, floor(min(Double(box.width), Double(box.height)) * 0.1 + 0.5)))
        let trailing = options.trailing.isNaN ? 0 : max(0, min(96, options.trailing))
        func fill(_ buffer: inout [UInt8], rect: CGRect, margin: Double, trailing: Double = 0, inset: Int = 1, typedRange: Bool = true) {
            let x0 = max(Double(inset), floor(Double(rect.origin.x) - margin))
            let y0 = max(Double(inset), floor(Double(rect.origin.y) - margin))
            let x1 = min(Double(w - 1 - inset), ceil(Double(rect.origin.x + rect.size.width) + margin + (options.vertical ? 0 : trailing)))
            let y1 = min(Double(h - 1 - inset), ceil(Double(rect.origin.y + rect.size.height) + margin + (options.vertical ? trailing : 0)))
            guard y0 <= y1 else { return }
            for y in Int(y0)...Int(y1) {
                if typedRange {
                    NativeTypedArrayFill.fill(&buffer, value: 1, start: Double(y * w) + x0, end: Double(y * w) + x1 + 1)
                } else if x0 <= x1 {
                    for x in Int(x0)...Int(x1) { buffer[y * w + x] = 1 }
                }
            }
        }
        for rect in boxes { fill(&bounds, rect: rect, margin: margin, trailing: trailing); fill(&ownedCore, rect: rect, margin: 3) }
        if let geometry { for i in 0..<n where geometry[i] == 0 { bounds[i] = 0; ownedCore[i] = 0 } }
        for rect in options.excluded where [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite) {
            fill(&protectedPixels, rect: rect, margin: 2)
        }
        var mask = [UInt8](repeating: 0, count: n), segmented = false
        // JavaScript selects the entire sourceInk descriptor when present; a
        // missing foreground there must not invent a base-palette segmentation.
        if let palette,
           palette.sourceInk == nil || NativeRestorationPixels.rgb(palette.sourceInk?["foreground"]) != nil,
           let glyphForeground = palette.verifiedForeground ?? NativeRestorationPixels.rgb(palette.sourceInk?["foreground"]) {
            let sourceInk = palette.sourceInk.flatMap { metadata -> NativeSourceGlyphSegmentation.Ink? in
                guard let fg = NativeRestorationPixels.rgb(metadata["foreground"]) else { return nil }
                return .init(foreground: fg.channels, background: NativeRestorationPixels.rgb(metadata["background"])?.channels,
                    stroke: NativeRestorationPixels.rgb(metadata["stroke"])?.channels,
                    outline: NativeRestorationPixels.rgb(metadata["outline"])?.channels,
                    backgroundConfidence: (metadata["confidence"] as? [String: Any])?["background"] as? Double ?? 0)
            }
            let ink = NativeSourceGlyphSegmentation.Palette(foreground: glyphForeground.channels, background: palette.verifiedBackground?.channels,
                stroke: palette.stroke?.channels, outline: NativeRestorationPixels.rgb(palette.metadata["outline"])?.channels,
                backgroundConfidence: (palette.metadata["confidence"] as? [String: Any])?["background"] as? Double ?? 0,
                strokeConfidence: palette.verifiedForeground != nil ? ((palette.metadata["confidence"] as? [String: Any])?["stroke"] as? Double ?? 0) : 0, sourceInk: sourceInk)
            if let candidate = NativeSourceGlyphSegmentation.forcedTextMask(rgba: rgba, width: w, height: h, box: box, palette: ink,
                options: .init(polygons: options.polygons, excludedPolygons: options.excludedPolygons, glyphSize: options.glyphSize)) {
                mask = candidate.mask; segmented = true
            }
        }
        for i in 0..<n where bounds[i] == 0 || protectedPixels[i] != 0 && ownedCore[i] == 0 { mask[i] = 0 }
        let foreground = NativeRestorationPixels.rgb(palette?.sourceInk?["foreground"])?.channels ?? palette?.verifiedForeground?.channels
        let stroke: [Double]?
        if let sourceStroke = NativeRestorationPixels.rgb(palette?.sourceInk?["stroke"]) { stroke = sourceStroke.channels }
        else if let palette, let foreground, let observedForeground = palette.verifiedForeground,
                ((palette.metadata["confidence"] as? [String: Any])?["stroke"] as? Double ?? 0) >= 0.55,
                NativeObservedRestorationHelpers.distance(observedForeground.channels, foreground) <= 24 { stroke = palette.stroke?.channels }
        else { stroke = nil }
        func colorAt(_ i: Int, _ color: [Double]?) -> Double {
            guard let color, color.count >= 3 else { return 256 }
            return NativeResidualProof.pixelDistance(rgba, i, color)
        }
        var coreTotal = 0, coreMasked = 0
        for i in 0..<n where ownedCore[i] != 0 && colorAt(i, foreground) <= 28 { coreTotal += 1; if mask[i] != 0 { coreMasked += 1 } }
        var coverage = coreTotal > 0 ? Double(coreMasked) / Double(coreTotal) : 0
        var nearCore = [UInt8](repeating: 0, count: n)
        if stroke != nil && foreground != nil {
            for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                let i = y * w + x
                if ownedCore[i] == 0 || colorAt(i, foreground) > 28 { continue }
                for yy in max(1, y - 7)...min(h - 2, y + 7) {
                    for xx in max(1, x - 7)...min(w - 2, x + 7) { nearCore[yy * w + xx] = 1 }
                }
            } }
        }
        var outlineTotal = 0, outlineMasked = 0
        for i in 0..<n where ownedCore[i] != 0 && nearCore[i] != 0 && colorAt(i, stroke) <= 32 {
            outlineTotal += 1; if mask[i] != 0 { outlineMasked += 1 }
        }
        var outlineCoverage = outlineTotal > 0 ? Double(outlineMasked) / Double(outlineTotal) : 1
        let narrowMask = segmented && coreTotal >= 3 && coverage >= 0.995 && outlineCoverage >= 0.995
        if options.requireSafeDonors && !narrowMask { return fail("display-mask-unverified") }
        if !narrowMask {
            var rectMask = [UInt8](repeating: 0, count: n)
            for rect in boxes { fill(&rectMask, rect: rect, margin: 3) }
            for i in 0..<n where rectMask[i] != 0 && (geometry?[i] ?? 1) != 0 { mask[i] = 1 }
        }
        let painted = mask, queue = (0..<n).filter { mask[$0] != 0 }
        guard !queue.isEmpty else { return fail("empty-erasure-mask") }
        var p = rgba, blocked = [UInt8](repeating: 0, count: n)
        for i in 0..<n where painted[i] == 0 && (protectedPixels[i] != 0 || (options.excludedMask?[i] ?? 0) != 0 || (options.protected?[i] ?? 0) != 0) { blocked[i] = 1 }
        for rect in options.donorExcluded where valid(rect) {
            var excluded = [UInt8](repeating: 0, count: n)
            fill(&excluded, rect: rect, margin: 2, inset: 0, typedRange: false)
            for i in 0..<n where excluded[i] != 0 && painted[i] == 0 { blocked[i] = 1 }
        }
        var method = "forced-donor-front", quality: NativeResidualProof.Quality?
        var fillOptions = NativeResidualProof.Options(excludedMask: blocked, protected: options.protected, sourceForeground: foreground,
            sourceStroke: stroke, sourceBackground: NativeRestorationPixels.rgb(palette?.sourceInk?["background"])?.channels ?? palette?.verifiedBackground?.channels,
            glyphSize: options.glyphSize)
        if narrowMask, let filled = NativeResidualProof.forcedDonorFill(rgba: p, width: w, height: h, mask: painted, options: fillOptions), let data = filled.rgba, data.count == n * 4 {
            p = data; method = filled.method; quality = filled.quality
        }
        if options.requireSafeDonors && (quality?.safe != true || method == "forced-donor-front") { return fail("display-donors-unverified") }
        if method == "forced-donor-front" {
            fillOptions.sourceForeground = foreground
            guard let filled = NativeResidualProof.certifiedSurfaceFill(rgba: rgba, width: w, height: h, mask: painted, blocked: blocked, options: fillOptions), let data = filled.rgba else { return fail("uncertified-background-surface") }
            p = data; method = filled.method; quality = filled.quality
        }
        var output = [UInt8](repeating: 0, count: n * 4), layoutSafe = [UInt8](repeating: 0, count: n)
        for i in queue { for c in 0..<3 { output[i * 4 + c] = p[i * 4 + c] }; output[i * 4 + 3] = 255; layoutSafe[i] = 1 }
        coreMasked = (0..<n).filter { ownedCore[$0] != 0 && colorAt($0, foreground) <= 28 && painted[$0] != 0 }.count
        coverage = coreTotal > 0 ? Double(coreMasked) / Double(coreTotal) : 1
        outlineMasked = (0..<n).filter { ownedCore[$0] != 0 && nearCore[$0] != 0 && colorAt($0, stroke) <= 32 && painted[$0] != 0 }.count
        outlineCoverage = outlineTotal > 0 ? Double(outlineMasked) / Double(outlineTotal) : 1
        if coverage < 0.995 || outlineCoverage < 0.995 { return fail("source-ink-outside-mask") }
        var edge = 0, postInk = 0
        for i in queue {
            let x = i % w, y = i / w
            if (x <= 3 || x >= w - 4 || y <= 3 || y >= h - 4) && colorAt(i, foreground) <= 40 { edge += 1 }
            if let foreground, NativeResidualProof.pixelDistance(output, i, foreground) <= 28 { postInk += 1 }
        }
        let remaining = (0..<n).filter { i in
            ownedCore[i] != 0 && painted[i] != 0 && colorAt(i, foreground) <= 28 && foreground.map { NativeResidualProof.pixelDistance(output, i, $0) <= 28 } == true
        }.count
        if Double(remaining) > max(4, Double(coreTotal) * 0.01) { return fail("source-ink-in-reconstruction") }
        return Outcome(result: Result(rgba: output, layoutSafe: layoutSafe, erased: queue.count, method: method, quality: quality,
            sourceTouchesCropEdge: edge, postFillPaletteInkPixels: postInk, sourceRemainingInk: remaining, sourceCorePixels: coreTotal,
            sourceOutlinePixels: outlineTotal, sourceRemainingOutline: outlineTotal - outlineMasked, forcedCoverage: coverage,
            forcedOutlineCoverage: outlineCoverage, forcedMaskMode: narrowMask ? "glyph" : "rect"), failure: "")
    }
}
