import Foundation

/// The page crop is rectified once. Only owned repaired pixels are projected
/// back; untouched page artwork never passes through a second resampler.
enum NativeSlantedRestoration {
    typealias Pixels = NativeRestorationPixels
    typealias Options = NativeSlantedGeometry.Options
    struct ProofRaster {
        var width: Int
        var height: Int
        var box: [Double]
        var safe: [UInt8]
        var luminance: [UInt8]
        var auxiliary: [[Double]]
        var method: String? = nil
        var preparation: NativeSlantedPreparation? = nil
    }
    struct Result {
        var pixels: Pixels
        var proof: ProofRaster
    }
    static func restore(_ page: Pixels, box: [Double], angle: Double, palette: Pixels.Palette?,
                        vertical: Bool = false, options: Options = Options()) -> Result? {
        guard page.count <= 262_144, page.rgba.count == page.count * 4, NativeSlantedGeometry.valid(box),
              angle.isFinite, box[2] >= 3, box[3] >= 3 else { return nil }
        let geometry = NativeSlantedGeometry.localGeometry(box: box, angle: angle, vertical: vertical, options: options)
        let lw = geometry.width, lh = geometry.height, b = geometry.box
        guard lw > 0, lh > 0, lw <= 262_144 / lh else { return nil }
        let n = lw * lh
        let cx = box[0] + box[2] / 2, cy = box[1] + box[3] / 2, c = cos(angle), s = sin(angle)
        let ox = b[0] + box[2] / 2, oy = b[1] + box[3] / 2
        var local = Pixels(width: lw, height: lh)
        local.rgba = NativeSlantedPixels.resample(page.rgba, w: page.width, h: page.height, lw: lw, lh: lh,
            cx: cx, cy: cy, c: c, s: s, ox: ox, oy: oy)
        var auxiliary = geometry.auxiliary
        if options.inferRuby && auxiliary.isEmpty, let background = palette?.verifiedBackground {
            let raw = (0..<n).map { i -> UInt8 in local.color(i).maximum < 110 ? 1 : 0 }
            var inferred: [[Double]]
            if vertical {
                inferred = NativeSourceGlyphSegmentation.inferVerticalRuby(raw: raw, rgba: local.rgba, width: lw, height: lh,
                    box: NativeSlantedGeometry.rect(b), background: background.channels).map(NativeSlantedGeometry.array)
            } else {
                var turned = [UInt8](repeating: 0, count: n * 4), ink = raw
                for y in 0..<lh { for x in 0..<lw {
                    let i = y * lw + x, j = x * lh + lh - 1 - y
                    for k in 0..<4 { turned[j * 4 + k] = local.rgba[i * 4 + k] }; ink[j] = raw[i]
                } }
                inferred = NativeSourceGlyphSegmentation.inferVerticalRuby(raw: ink, rgba: turned, width: lh, height: lw,
                    box: NativeSlantedGeometry.rect([Double(lh) - b[1] - b[3], b[0], b[3], b[2]]), background: background.channels)
                    .map { r in [Double(r.minY), Double(lh) - Double(r.minX) - Double(r.width), Double(r.height), Double(r.width)] }
            }
            auxiliary += inferred.filter { r in !geometry.exclusions.contains { q in
                r[0] < q[0] + q[2] && r[0] + r[2] > q[0] && r[1] < q[1] + q[3] && r[1] + r[3] > q[1]
            } }
        }
        func attempt(_ colors: Pixels.Palette?) -> Pixels? {
            var settings = NativeObservedRestoreOptions()
            settings.readabilityGate = true; settings.compactMask = true; settings.protectArtMargin = true; settings.slantedOwnership = true
            settings.vertical = vertical; settings.sampleScale = 1; settings.chromaticBalloon = options.chromaticBalloon
            settings.auxiliary = auxiliary.map(NativeSlantedGeometry.rect)
            settings.inferredRubyExclusions = geometry.exclusions.map(NativeSlantedGeometry.rect)
            settings.rowEndMarks = vertical ? auxiliary.filter { $0[1] + $0[3] / 2 > b[1] + b[3] * 0.7 && $0[3] <= b[2] * 0.65 }
                .map(NativeSlantedGeometry.rect) : []
            let result = Pixels.exactObservedRestore(local, box: NativeSlantedGeometry.rect(b), palette: colors, options: settings)
            let reason: String?
            if result == nil { reason = "panel" }
            else if result!.paintedCount == 0 { reason = "nothing-erased" }
            else if Double(result!.preservedCore) > max(8, min(32, Double(result!.paintedCount) * 0.0005)) {
                reason = "preserved-core:" + String(result!.preservedCore)
            } else if result!.layoutSafe == nil { reason = "layout" }
            else if result!.method != "chromatic-balloon-glyphs" && !NativeSlantedProof.surfaceFits(result!, palette: colors) {
                reason = "surface:" + (result!.surfaceQuality?["reason"] as? String ?? "none")
            } else if NativeSlantedProof.residualInk(local, box: b, result: result!) { reason = "residual" }
            else { reason = nil }
            if let reason { options.failures?.reasons.append(reason); return nil }
            return result
        }
        let observed = palette?.sourceInk.flatMap(Pixels.palette)
        let outlined = observed?.stroke.map { $0.minimum >= 230 } == true &&
            (observed?.strokeConfidence ?? 0) >= 0.8 && (observed?.foregroundConfidence ?? 0) >= 0.6
        var accepted = attempt(palette)
        if accepted == nil && outlined { accepted = attempt(observed) }
        let scale = min(1, sqrt(24_576 / (b[2] * b[3]))), sw = Int(floor(b[2] * scale)), sh = Int(floor(b[3] * scale))
        if sw >= 8 && sh >= 8 {
            var sample = [UInt8](repeating: 0, count: sw * sh * 4)
            for y in 0..<sh { for x in 0..<sw {
                let j = (Int(floor(b[1] + (Double(y) + 0.5) * b[3] / Double(sh))) * lw +
                    Int(floor(b[0] + (Double(x) + 0.5) * b[2] / Double(sw)))) * 4
                for k in 0..<4 { sample[(y * sw + x) * 4 + k] = local.rgba[j + k] }
            } }
            let evidence = palette?.metadata["lettering"] as? [String: Any]
            let seed = (evidence?["bands"] as? NSNumber)?.doubleValue ?? 0 >= 3 &&
                ((evidence?["components"] as? NSNumber)?.doubleValue ?? 0) >= 3 &&
                ((evidence?["support"] as? NSNumber)?.doubleValue ?? 0) >= 0.02 &&
                ((evidence?["exterior"] as? NSNumber)?.doubleValue ?? .infinity) <= 0.03
                ? Pixels.rgb(evidence?["color"])?.channels : nil
            if var descriptor = NativeSourceColorSampler.estimate(rgba: sample, width: sw, height: sh, inkSeed: seed),
               let fg = Pixels.rgb(descriptor["foreground"]), let bg = Pixels.rgb(descriptor["background"]) {
                let paper = palette?.verifiedBackground ?? Pixels.rgb(palette?.metadata["captionBackground"])
                if let stroke = Pixels.rgb(descriptor["stroke"]), let paper, bg.minimum >= 245,
                   fg.maximum - fg.minimum >= 100, stroke.distance(paper) <= 24, bg.distance(paper) > stroke.distance(paper) + 6 {
                    descriptor["stroke"] = bg.channels; descriptor["background"] = paper.channels
                }
                if var width = descriptor["widthEvidence"] as? [String: Any] { width["sampleScale"] = scale; descriptor["widthEvidence"] = width }
                let colors = Pixels.palette(descriptor)
                let detailed = attempt(colors) ?? (accepted == nil ? NativeSlantedProof.flatGlyphs(local, box: b, palette: colors) : nil)
                if let detailed, !NativeSlantedProof.residualInk(local, box: b, result: detailed) { accepted = detailed }
            }
        }
        guard var result = accepted, var safe = result.layoutSafe else { return nil }
        let quality = result.surfaceQuality, coefficients = quality?["coefficients"] as? [[Double]]
        let rmse = (quality?["rmse"] as? NSNumber)?.doubleValue ?? .nan
        let outliers = (quality?["outliers"] as? NSNumber)?.doubleValue ?? .nan
        if quality?["reason"] as? String == "smooth", rmse > 3, rmse <= 8, outliers <= 0.025, let coefficients {
            for i in 0..<n where result.rgba[i * 4 + 3] != 0 {
                let x = Double(i % lw) / Double(lw), y = Double(i / lw) / Double(lh)
                for k in 0..<3 { let a = coefficients[k]; result.rgba[i * 4 + k] = Pixels.clamp(a[0] + a[1] * x + a[2] * y) }
            }
        }
        var output = [UInt8](repeating: 0, count: page.count * 4)
        var luminance = NativeSlantedPixels.compositeLuminance(result.rgba, local: local.rgba, n: n)
        var erased = NativeSlantedPixels.projectOwned(result.rgba, safe: safe, output: &output, w: page.width, h: page.height, lw: lw, lh: lh,
            cx: cx, cy: cy, c: c, s: s, ox: ox, oy: oy)
        if quality?["reason"] as? String == "smooth", let fg = result.observedFill, let bg = result.observedBacking, let coefficients {
            erased += completeNativeFringe(page, output: &output, safe: &safe, fg: fg.channels, bg: bg.channels, coefficients: coefficients,
                regions: [b] + auxiliary, auxiliary: auxiliary, vertical: vertical, lw: lw, lh: lh, cx: cx, cy: cy, c: c, s: s, ox: ox, oy: oy)
            let axis = zip(fg.channels, bg.channels).map(-), norm = max(1, axis.reduce(0) { $0 + $1 * $1 })
            for _ in 0..<2 { erased += NativeSlantedPixels.fillHoles(page.rgba, output: &output, w: page.width, h: page.height,
                axis: axis, bg: bg.channels, scale: norm, regions: [b] + auxiliary, cx: cx, cy: cy, c: c, s: s, ox: ox, oy: oy) }
        }
        guard let fg = result.observedFill, let bg = result.observedBacking,
              !partiallyExposed(page, output: output, box: box, foreground: fg.channels, background: bg.channels, cx: cx, cy: cy, c: c, s: s) else { return nil }
        NativeSlantedPixels.layoutProof(page.rgba, output: output, w: page.width, h: page.height, safe: &safe, luminance: &luminance,
            lw: lw, lh: lh, cx: cx, cy: cy, c: c, s: s, ox: ox, oy: oy)
        closeProofSeams(safe: &safe, luminance: luminance, restored: result.rgba, w: lw, h: lh)
        var pixels = Pixels(width: page.width, height: page.height); pixels.rgba = output
        pixels.method = "rectified-" + (result.method ?? "undefined"); pixels.surfaceQuality = quality
        return Result(pixels: pixels, proof: ProofRaster(width: lw, height: lh, box: b, safe: safe, luminance: luminance, auxiliary: auxiliary))
    }
}
