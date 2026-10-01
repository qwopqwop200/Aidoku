import CoreGraphics
import Foundation

extension NativeRestorationPixels {
    static func flatInpaintingPalette(_ p: Self, box: CGRect) -> Palette? {
        guard p.width >= 8, p.height >= 8, p.count <= 262_144, box.minX >= 2, box.minY >= 2,
              box.width > 0, box.height > 0, box.maxX <= CGFloat(p.width - 2), box.maxY <= CGFloat(p.height - 2) else { return nil }
        struct Bin { let order: Int; var count = 0; var sum = [Double](repeating: 0, count: 3); var mean: NativeRestorationRGB { .init(sum.map { $0 / Double(count) }) } }
        var bins: [Int: Bin] = [:], order = 0
        let samples = p.indices(box)
        for i in samples {
            let key = Int(p.rgba[i * 4] >> 4) * 256 + Int(p.rgba[i * 4 + 1] >> 4) * 16 + Int(p.rgba[i * 4 + 2] >> 4)
            if bins[key] == nil { bins[key] = Bin(order: order); order += 1 }
            var bin = bins[key]!; bin.count += 1
            for c in 0..<3 { bin.sum[c] += Double(p.rgba[i * 4 + c]) }
            bins[key] = bin
        }
        let peaks = bins.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order }
        guard let seed = peaks.first?.mean else { return nil }
        let surface = peaks.filter { $0.mean.distance(seed) <= 20 }, support = surface.reduce(0) { $0 + $1.count }
        guard Double(support) >= Double(samples.count) * 0.4 else { return nil }
        let background = NativeRestorationRGB((0..<3).map { c in surface.reduce(0.0) { $0 + $1.sum[c] } / Double(support) })
        let x0 = Int(floor(box.minX)), y0 = Int(floor(box.minY)), x1 = Int(ceil(box.maxX)), y1 = Int(ceil(box.maxY))
        var sides: [Double] = []
        for side in 0..<4 {
            var support = 0, count = 0
            for t in 0..<(side < 2 ? y1 - y0 : x1 - x0) { for step in 1...3 {
                let x = side == 0 ? x0 - step : (side == 1 ? x1 - 1 + step : x0 + t)
                let y = side == 2 ? y0 - step : (side == 3 ? y1 - 1 + step : y0 + t)
                if x < 0 || x >= p.width || y < 0 || y >= p.height { continue }
                count += 1; if p.color(y * p.width + x).distance(background) <= 20 { support += 1 }
            } }
            sides.append(Double(support) / Double(max(1, count)))
        }
        guard sides[0] >= 0.65 && sides[1] >= 0.65 || sides[2] >= 0.65 && sides[3] >= 0.65,
              let ink = peaks.first(where: { Double($0.count) >= max(4, Double(samples.count) * 0.015) && $0.mean.distance(background) >= 40 }) else { return nil }
        return Palette(foreground: ink.mean, background: background, stroke: nil,
                       metadata: ["foreground": ink.mean.channels, "background": background.channels, "confidence": ["foreground": 0.75, "background": 0.8], "inpaintingOnly": true])
    }

    static func secondarySourceInk(_ p: Self, box: CGRect, palette: Palette, usedPalette: Palette) -> [String: Any]? {
        guard let ink = rgb(palette.sourceInk?["stroke"]), ink.maximum - ink.minimum >= 40,
              ((palette.sourceInk?["confidence"] as? [String: Any])?["stroke"] as? Double ?? 0) >= 0.6,
              ink.distance(usedPalette.foreground) >= 48, ink.distance(usedPalette.background) >= 48 else { return nil }
        let match = (0..<p.count).map { i -> UInt8 in p.rgba[i * 4 + 3] >= 250 && p.color(i).distance(ink) <= 28 ? 1 : 0 }
        var interior = 0, exterior = 0, owned = 0, components = 0, bands = Set<Int>()
        let vertical = box.height >= box.width
        for part in p.components(match) {
            let local = part.points.filter { i in
                let x = CGFloat(i % p.width), y = CGFloat(i / p.width)
                return x >= box.minX && x < box.maxX && y >= box.minY && y < box.maxY
            }.count
            interior += local; exterior += part.points.count - local
            guard part.points.count >= 4, Double(local) >= Double(part.points.count) * 0.97,
                  part.rect.minX >= 1, part.rect.minY >= 1, part.rect.maxX - 1 < CGFloat(p.width - 1), part.rect.maxY - 1 < CGFloat(p.height - 1),
                  (vertical ? part.rect.height : part.rect.width) <= max(box.width, box.height) * 0.3,
                  (vertical ? part.rect.width : part.rect.height) <= min(box.width, box.height) * 0.8 else { continue }
            owned += local; components += 1
            let center = vertical ? part.rect.midY - 0.5 : part.rect.midX - 0.5
            let start = vertical ? box.minY : box.minX, length = vertical ? box.height : box.width
            bands.insert(min(7, max(0, Int(floor((center - start) * 8 / length)))))
        }
        let support = Double(interior) / Double(box.width * box.height)
        let outside = Double(exterior) / max(1, Double(p.count) - Double(box.width * box.height))
        guard components >= 3, bands.count >= 3, support >= 0.015, support <= 0.4, outside <= 0.02, Double(owned) >= Double(interior) * 0.8 else { return nil }
        return ["color": ink.channels, "components": components, "bands": bands.count, "support": support, "exterior": outside]
    }

    static func exactObservedAttempts(_ p: Self, box: CGRect, palette: Palette?, options: NativeObservedRestoreOptions,
                                      context: ObservedContext) -> Self? {
        func finish(_ candidate: Self, usedPalette: Palette, method: String) -> Self {
            var result = candidate
            var evidence = palette?.metadata["lettering"] as? [String: Any]
            if options.readabilityGate && (rgb(evidence?["color"]) == nil || rgb(evidence?["color"])!.distance(usedPalette.foreground) < 48), let palette {
                evidence = secondarySourceInk(p, box: box, palette: palette, usedPalette: usedPalette)
            }
            if options.readabilityGate, let ink = rgb(evidence?["color"]),
                (evidence?["bands"] as? Int ?? 0) >= 3, (evidence?["components"] as? Int ?? 0) >= 3,
                (evidence?["support"] as? Double ?? 0) >= 0.015, (evidence?["exterior"] as? Double ?? 1) <= 0.02,
                ink.distance(usedPalette.foreground) >= 48, ink.distance(usedPalette.background) >= 48 {
                var jointOptions = options; jointOptions.secondaryInk = ink
                if let joint = exactObserved(p, box: box, palette: usedPalette, options: jointOptions, context: context) {
                    let preserves = (0..<p.count).allSatisfy { i in
                        result.rgba[i * 4 + 3] == 0 || joint.rgba[i * 4 + 3] != 0 ||
                            p.color(i).distance(usedPalette.foreground) > 48 || p.color(i).distance(usedPalette.background) < 32
                    }
                    if preserves { result = joint }
                }
            }
            let chromatic = usedPalette.foreground.maximum - usedPalette.foreground.minimum >= 40
            if options.readabilityGate && (chromatic || usedPalette.stroke.map { $0.distance(usedPalette.background) >= 32 } == true) {
                var guardRing = [UInt8](repeating: 0, count: p.count)
                for pass in 0..<2 {
                    var pending: [Int] = []
                    for y in 1..<(p.height - 1) { for x in 1..<(p.width - 1) {
                        let i = y * p.width + x
                        guard result.rgba[i * 4 + 3] == 0, result.layoutSafe?[i] != 0 else { continue }
                        if p.neighbors(i).contains(where: { j in
                            result.rgba[j * 4 + 3] != 0 && Int(guardRing[j]) <= pass && p.color(i).distance(result.color(j)) <= 16
                        }) { pending.append(i) }
                    } }
                    for i in pending { for c in 0..<4 { result.rgba[i * 4 + c] = p.rgba[i * 4 + c] }; guardRing[i] = UInt8(pass + 1) }
                }
            }
            result.method = method
            if options.slantedOwnership { result.observedFill = usedPalette.foreground; result.observedBacking = usedPalette.background }
            return result
        }
        if let palette {
            let observedInk = palette.sourceInk.flatMap(Self.palette)
            let observedStroke = observedInk?.stroke
            let chromaticStroke = options.vertical && !options.slantedOwnership && observedStroke.map {
                $0.maximum - $0.minimum >= 40 && $0.distance(observedInk!.foreground) < 48 && observedInk!.strokeConfidence >= 0.6
            } == true
            let neutralStroke = options.vertical && !options.slantedOwnership && observedStroke.map {
                $0.minimum >= 230 && (observedInk!.widthEvidence?["method"] as? String ?? "").hasPrefix("outer stroke boundary") &&
                    observedInk!.strokeConfidence >= 0.6 && observedInk!.foreground.maximum <= 80 &&
                    (observedInk!.metadata["confidence"] as? [String: Any])?["reason"] as? String == "repeated dark glyph interiors enclosed by white source outlines"
            } == true
            if (options.connectedGlyphRecovery || chromaticStroke || neutralStroke) && options.readabilityGate && palette.stroke == nil,
               observedStroke != nil, let observedInk,
               let candidate = exactObserved(p, box: box, palette: observedInk, options: options, context: context) {
                return finish(candidate, usedPalette: observedInk, method: "observed-ink-evidence")
            }
            let surface = palette.metadata["surface"] as? [String: Any], stroke = palette.stroke ?? observedStroke
            if options.readabilityGate && options.vertical && !options.slantedOwnership, palette.verifiedForeground != nil, palette.verifiedBackground != nil,
               let stroke, let color = rgb(surface?["color"]), let stops = surface?["stops"] as? [[Double]], stops.count >= 4,
               palette.foreground.maximum <= 80, stroke.minimum >= 230, palette.strokeConfidence >= 0.6,
               palette.backgroundConfidence < 0.4, stroke.distance(palette.background) < 8, stroke.distance(color) >= 24,
               stops.allSatisfy({ NativeRestorationRGB($0).distance(color) <= 8 }) {
                var exposed = palette; exposed.background = color; exposed.metadata["background"] = color.channels
                if let candidate = exactObserved(p, box: box, palette: exposed, options: options, context: context), candidate.erasureComplete {
                    return finish(candidate, usedPalette: exposed, method: "observed-surface-outline")
                }
            }
            if let candidate = exactObserved(p, box: box, palette: palette, options: options, context: context) {
                let method = candidate.surfaceQuality?["reason"] as? String == "locally-smooth" ? "local-diffusion" : "observed-palette"
                return finish(candidate, usedPalette: palette, method: method)
            }
            guard options.readabilityGate else { return nil }
            if let observedInk, let candidate = exactObserved(p, box: box, palette: observedInk, options: options, context: context) {
                return finish(candidate, usedPalette: observedInk, method: "observed-ink-evidence")
            }
            var ink = observedInk ?? palette
            if options.vertical, let stroke = ink.stroke, ink.foreground.minimum > 230,
                stroke.maximum - stroke.minimum >= 40, ink.strokeConfidence >= 0.6 {
                ink.stroke = ink.foreground; ink.foreground = stroke
                if let candidate = exactObserved(p, box: box, palette: ink, options: options, context: context) { return finish(candidate, usedPalette: ink, method: "observed-outline-ink") }
            }
            // An unmeasured white band may be exposed paper rather than a distinct
            // outline. Retry its independent dark fill without that band hypothesis,
            // retaining the original component, artwork, donor and ownership checks.
            // A frame-connected drawing still prevents complete erasure certification.
            if !options.slantedOwnership, let stroke = ink.stroke, ink.widthEvidence == nil,
               ink.foreground.maximum <= 80, stroke.minimum >= 230,
               ink.foregroundConfidence >= 0.75, ink.strokeConfidence >= 0.6,
               ink.metadata["observedBackground"] as? Bool == true || palette.metadata["observedBackground"] as? Bool == true {
                var exposed = ink
                exposed.stroke = nil
                exposed.metadata["stroke"] = NSNull()
                exposed.metadata["outline"] = NSNull()
                if let candidate = exactObserved(p, box: box, palette: exposed, options: options, context: context),
                   candidate.glyphsVerified, candidate.preservedCore == 0, candidate.preservedPixels == 0,
                   let quality = candidate.surfaceQuality, quality["safe"] as? Bool == true,
                   quality["reason"] as? String == "smooth", (quality["rmse"] as? Double ?? .infinity) <= 3,
                   (quality["outliers"] as? Double ?? .infinity) == 0, (quality["samples"] as? Int ?? 0) >= 64,
                   let coefficients = quality["coefficients"] as? [[Double]], coefficients.count == 3,
                   coefficients.allSatisfy({ $0.count == 3 }) {
                    let center = NativeRestorationRGB(coefficients.map {
                        $0[0] + $0[1] * Double(box.midX) / Double(p.width) + $0[2] * Double(box.midY) / Double(p.height)
                    })
                    if center.distance(stroke) <= 12, center.distance(ink.background) >= 20 {
                        return finish(candidate, usedPalette: exposed, method: "observed-exposed-paper")
                    }
                }
            }
        } else if !options.readabilityGate { return nil }
        if let flat = flatInpaintingPalette(p, box: box) {
            var next = options; next.compactMask = true; next.flatPalette = true
            if let candidate = exactObserved(p, box: box, palette: flat, options: next, context: context) { return finish(candidate, usedPalette: flat, method: "flat-surface-palette") }
        }
        if !options.connectedGlyphRecovery && options.vertical && !options.slantedOwnership {
            var next = options; next.connectedGlyphRecovery = true
            return exactObservedAttempts(p, box: box, palette: palette, options: next, context: context)
        }
        return nil
    }

    static func exactObservedRestore(_ p: Self, box: CGRect, palette: Palette?, options: NativeObservedRestoreOptions) -> Self? {
        let context = ObservedContext()
        func outlineRecovery() -> Self? {
            return Self.outlineRecovery(p, box: box, auxiliary: options.auxiliary, excluded: options.excluded,
                                        palette: palette, vertical: options.vertical, allowDiscovery: !options.slantedOwnership,
                                        slantedOwnership: options.slantedOwnership)
        }
        func refine(_ candidate: Self) -> Self {
            let completed = finishClearPaperCaption(p, box: box, palette: palette, options: options, repaired: candidate)
            var refined = completed
            if !options.slantedOwnership, completed.glyphsVerified {
                let sourceFill = rgb(palette?.sourceInk?["foreground"]) ?? palette?.verifiedForeground
                let outlined = (completed.observedFill?.minimum ?? 0) >= 220
                refined = refineFringe(p, repaired: completed, outlined: outlined,
                                       foreground: outlined ? completed.observedStroke : sourceFill)
            }
            return NativeDottedPaperFrame.protecting(p, box: box, vertical: options.vertical, repaired: refined)
        }
        func preferred(_ candidate: Self) -> Self { candidate.erasureComplete ? candidate : (outlineRecovery() ?? candidate) }
        let candidate = exactObservedAttempts(p, box: box, palette: palette, options: options, context: context)
        if candidate?.erasureComplete != true, let narrow = narrowPaperGlyphs(p, box: box, palette: palette, options: options) { return narrow }
        if let candidate { return refine(preferred(candidate)) }
        if context.shortGlyphCandidate {
            var next = options; next.shortGlyphRecovery = true
            if let candidate = exactObservedAttempts(p, box: box, palette: palette, options: next, context: context) {
                return refine(options.slantedOwnership ? candidate : preferred(candidate))
            }
        }
        if options.slantedOwnership {
            return sampledChromatic(p, box: box, auxiliary: options.auxiliary, excluded: options.excluded,
                                    palette: palette, vertical: options.vertical, slantedOwnership: options.slantedOwnership)
        }
        if context.denseDonorCandidate {
            var next = options; next.denseDonorSampling = true
            if let candidate = exactObservedAttempts(p, box: box, palette: palette, options: next, context: context) { return refine(preferred(candidate)) }
        }
        let outline = palette?.stroke ?? rgb(palette?.sourceInk?["stroke"])
        let distinct = outline != nil && palette?.verifiedBackground != nil && outline!.distance(palette!.verifiedBackground!) > 24
        var next = options; next.enclosedWordRecovery = true; next.shortGlyphRecovery = true; next.segmentedSurfaceRecovery = !distinct
        if let candidate = exactObservedAttempts(p, box: box, palette: palette, options: next, context: context) { return refine(preferred(candidate)) }
        return outlineRecovery().map(refine)
    }
}
