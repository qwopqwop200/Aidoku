import CoreGraphics
import Foundation

extension NativeResidualProof {
    /// aidokuForceInpaintSourceComponent: accepted component mask, independent
    /// donors, one sparse residual retry, then exact post-fill core verification.
    static func forceComponent(_ p: NativeRestorationPixels, box: CGRect, auxiliary: [CGRect], excluded: [CGRect],
                               palette: NativeRestorationPixels.Palette, vertical: Bool,
                               polygons: [[CGPoint]] = [], excludedPolygons: [[CGPoint]] = [],
                               glyphSize: Double = 0, trailing: Double = 0,
                               donorExcluded: [CGRect] = [], requireSafeDonors: Bool = false,
                               excludedMask: [UInt8]? = nil, protectedMask: [UInt8]? = nil) -> NativeRestorationPixels? {
        let w = p.width, h = p.height, n = p.count, rgba = p.rgba
        guard w >= 5, h >= 5, n <= 1_000_000, rgba.count == n * 4, box.size.width > 0, box.size.height > 0,
              [box.origin.x, box.origin.y, box.size.width, box.size.height].allSatisfy(\.isFinite) else { return nil }
        let sourceInk = palette.sourceInk
        guard let foreground = sourceInk?["foreground"] as? [Double] ?? palette.verifiedForeground?.channels else { return nil }
        let hintedStroke = sourceInk?["stroke"] as? [Double]
        let stroke = hintedStroke ?? (palette.strokeConfidence >= 0.55 &&
            palette.verifiedForeground.map { colorDistance($0.channels, foreground) <= 24 } == true ? palette.stroke?.channels : nil)
        let background = sourceInk?["background"] as? [Double] ?? palette.verifiedBackground?.channels
        let segmentationPalette = componentSegmentationPalette(palette)
        var segmentationOptions = NativeSourceGlyphSegmentation.Options()
        segmentationOptions.polygons = polygons; segmentationOptions.excludedPolygons = excludedPolygons
        segmentationOptions.glyphSize = glyphSize
        var candidates = NativeSourceGlyphSegmentation.forcedTextMask(rgba: rgba, width: w, height: h,
            box: box, palette: segmentationPalette, options: segmentationOptions)
        if candidates == nil && n > 262_144 {
            let scale = sqrt(245_000 / Double(n)), sw = max(5, Int(floor(Double(w) * scale))), sh = max(5, Int(floor(Double(h) * scale)))
            var small = [UInt8](repeating: 0, count: sw * sh * 4)
            for y in 0..<sh {
                for x in 0..<sw {
                    let sx = min(w - 1, Int(floor((Double(x) + 0.5) * Double(w) / Double(sw))))
                    let sy = min(h - 1, Int(floor((Double(y) + 0.5) * Double(h) / Double(sh))))
                    let source = (sy * w + sx) * 4, target = (y * sw + x) * 4
                    for c in 0..<4 { small[target + c] = rgba[source + c] }
                }
            }
            let kx = CGFloat(sw) / CGFloat(w), ky = CGFloat(sh) / CGFloat(h)
            let sb = CGRect(x: box.minX * kx, y: box.minY * ky, width: box.width * kx, height: box.height * ky)
            var reducedOptions = segmentationOptions
            reducedOptions.polygons = polygons.map { $0.map { CGPoint(x: $0.x * kx, y: $0.y * ky) } }
            reducedOptions.excludedPolygons = excludedPolygons.map { $0.map { CGPoint(x: $0.x * kx, y: $0.y * ky) } }
            reducedOptions.glyphSize = glyphSize * Double(min(kx, ky))
            if let reduced = NativeSourceGlyphSegmentation.forcedTextMask(rgba: small, width: sw, height: sh,
                box: sb, palette: segmentationPalette, options: reducedOptions),
               reduced.mask.count == sw * sh, reduced.sourceCoreCandidateMask.count == sw * sh,
               reduced.sourceOutlineCandidateMask.count == sw * sh {
                var lifted = reduced
                lifted.mask = [UInt8](repeating: 0, count: n)
                lifted.sourceCoreCandidateMask = lifted.mask; lifted.sourceOutlineCandidateMask = lifted.mask
                for y in 0..<h {
                    for x in 0..<w {
                        let j = min(sh - 1, Int(floor(Double(y * sh) / Double(h)))) * sw + min(sw - 1, Int(floor(Double(x * sw) / Double(w))))
                        let i = y * w + x
                        lifted.mask[i] = reduced.mask[j]; lifted.sourceCoreCandidateMask[i] = reduced.sourceCoreCandidateMask[j]
                        lifted.sourceOutlineCandidateMask[i] = reduced.sourceOutlineCandidateMask[j]
                    }
                }
                candidates = lifted
            }
        }
        guard let candidates, candidates.mask.count == n, candidates.sourceCoreCandidateMask.count == n,
              candidates.sourceOutlineCandidateMask.count == n else { return nil }
        var owned = [UInt8](repeating: 0, count: n), main = owned, protected = owned
        let geometry = NativeSourceGlyphSegmentation.geometryMask(width: w, height: h, polygons: polygons, excluded: excludedPolygons, margin: 7)
        let trailing = max(0, min(96, trailing.isNaN ? 0 : trailing))
        let margin = max(8, min(24, floor(Double(min(box.width, box.height)) * 0.1 + 0.5)))
        func rectFill(_ r: CGRect, margin: Double, target: inout [UInt8], withTrailing: Bool,
                      excludedRectangle: Bool = false) {
            guard [r.origin.x, r.origin.y, r.size.width, r.size.height].allSatisfy(\.isFinite),
                  excludedRectangle || r.size.width > 0 && r.size.height > 0 else { return }
            let x0 = max(1, floor(Double(r.origin.x) - margin)), y0 = max(1, floor(Double(r.origin.y) - margin))
            let x1 = min(Double(w - 2), ceil(Double(r.origin.x + r.size.width) + margin + (withTrailing && !vertical ? trailing : 0)))
            let y1 = min(Double(h - 2), ceil(Double(r.origin.y + r.size.height) + margin + (withTrailing && vertical ? trailing : 0)))
            guard y0 <= y1 else { return }
            // TypedArray.fill normalizes absolute linear indices. An off-crop
            // negative end is relative to the whole buffer, not an empty row.
            for y in Int(y0)...Int(y1) {
                NativeTypedArrayFill.fill(&target, value: 1, start: Double(y) * Double(w) + x0,
                                          end: Double(y) * Double(w) + x1 + 1)
            }
        }
        for r in [box] + auxiliary { rectFill(r, margin: margin, target: &owned, withTrailing: true); rectFill(r, margin: 3, target: &main, withTrailing: false) }
        for r in excluded { rectFill(r, margin: 2, target: &protected, withTrailing: false, excludedRectangle: true) }
        if let geometry { for i in 0..<n where geometry.mask[i] == 0 { owned[i] = 0; main[i] = 0 } }
        let core = candidates.sourceCoreCandidateMask, outline = candidates.sourceOutlineCandidateMask
        var mask = candidates.mask
        for i in 0..<n {
            if owned[i] == 0 || protected[i] != 0 && main[i] == 0 { mask[i] = 0; continue }
            if core[i] != 0 || outline[i] != 0 { mask[i] = 1 }
        }
        let seeds = mask
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where seeds[y * w + x] != 0 {
                for yy in max(1, y - 1)...min(h - 2, y + 1) {
                    for xx in max(1, x - 1)...min(w - 2, x + 1) where abs(xx - x) + abs(yy - y) <= 1 {
                        let j = yy * w + xx
                        if owned[j] != 0 && (protected[j] == 0 || main[j] != 0) { mask[j] = 1 }
                    }
                }
            }
        }
        var painted = mask, queue: [Int] = [], coreTotal = 0, coreMasked = 0, outlineTotal = 0, outlineMasked = 0
        for i in 0..<n {
            if mask[i] != 0 { queue.append(i) }
            if owned[i] == 0 || protected[i] != 0 && main[i] == 0 { continue }
            if core[i] != 0 { coreTotal += 1; if mask[i] != 0 { coreMasked += 1 } }
            if outline[i] != 0 { outlineTotal += 1; if mask[i] != 0 { outlineMasked += 1 } }
        }
        if queue.isEmpty || coreTotal < 3 || coreMasked < coreTotal || outlineMasked < outlineTotal { return nil }
        var blocked = [UInt8](repeating: 0, count: n)
        let separateStroke = stroke.flatMap { color in background.map { colorDistance(color, $0) >= 48 } } ?? false
        for i in 0..<n where painted[i] == 0 {
            let isStroke = separateStroke && stroke.map { pixelDistance(rgba, i, $0) <= 45 } == true
            if protected[i] != 0 || excludedMask?.indices.contains(i) == true && excludedMask?[i] != 0 ||
                protectedMask?.indices.contains(i) == true && protectedMask?[i] != 0 || owned[i] != 0 && (pixelDistance(rgba, i, foreground) <= 40 || isStroke) { blocked[i] = 1 }
        }
        for r in donorExcluded {
            guard [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite), r.width > 0, r.height > 0 else { continue }
            let x0 = max(0, Int(floor(r.minX - 2))), y0 = max(0, Int(floor(r.minY - 2)))
            let x1 = min(w - 1, Int(ceil(r.maxX + 2))), y1 = min(h - 1, Int(ceil(r.maxY + 2)))
            if x0 > x1 || y0 > y1 { continue }
            for y in y0...y1 { for x in x0...x1 where painted[y * w + x] == 0 { blocked[y * w + x] = 1 } }
        }
        var options = Options(); options.excludedMask = blocked; options.sourceForeground = foreground
        options.sourceStroke = stroke; options.sourceBackground = background; options.glyphSize = glyphSize
        var filled = componentExemplarFill(rgba: rgba, width: w, height: h, mask: painted, blocked: blocked, options: options)
        if filled == nil { filled = forcedDonorFill(rgba: rgba, width: w, height: h, mask: painted, options: options) }
        if filled?.rgba == nil, let residual = filled?.residualMask, residual.count == n,
           filled?.failure == "residual-source-ink" || filled?.failure == "residual-white-outline" {
            var expanded = 0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    if residual[i] == 0 || owned[i] == 0 || protected[i] != 0 && main[i] == 0 { continue }
                    for yy in max(1, y - 1)...min(h - 2, y + 1) {
                        for xx in max(1, x - 1)...min(w - 2, x + 1) where abs(xx - x) + abs(yy - y) <= 1 {
                            let j = yy * w + xx
                            if owned[j] == 0 || protected[j] != 0 && main[j] == 0 || painted[j] != 0 { continue }
                            painted[j] = 1; mask[j] = 1; blocked[j] = 0; queue.append(j); expanded += 1
                        }
                    }
                }
            }
            if expanded > 0 { options.excludedMask = blocked; filled = forcedDonorFill(rgba: rgba, width: w, height: h, mask: painted, options: options) }
        }
        if requireSafeDonors && (filled?.quality.safe != true || filled?.rgba == nil) { return nil }
        if filled?.rgba == nil { filled = certifiedSurfaceFill(rgba: rgba, width: w, height: h, mask: painted, blocked: blocked, options: options) }
        guard let output = filled?.rgba, output.count == n * 4 else { return nil }
        var result = NativeRestorationPixels(width: w, height: h), safe = [UInt8](repeating: 0, count: n), remainingCore = 0
        for i in queue { for c in 0..<3 { result.rgba[i * 4 + c] = output[i * 4 + c] }; result.rgba[i * 4 + 3] = 255; safe[i] = 1 }
        for i in 0..<n where core[i] != 0 && painted[i] != 0 {
            if pixelDistance(result.rgba, i, foreground) <= 28 { remainingCore += 1 }
        }
        if Double(remainingCore) > max(4, Double(coreTotal) * 0.01) { return nil }
        result.layoutSafe = safe; result.erasureComplete = true; result.glyphsVerified = true
        result.method = filled?.method
        return result
    }

    /// Segmentation receives sourceInk as a whole hypothesis when present.
    /// Its confidence and optional channels cannot inherit display-palette
    /// fallbacks used later by the fill/donor policy.
    static func componentSegmentationPalette(_ palette: NativeRestorationPixels.Palette) -> NativeSourceGlyphSegmentation.Palette {
        NativeSourceGlyphSegmentation.Palette(foreground: palette.verifiedForeground?.channels ?? [],
            background: palette.verifiedBackground?.channels, stroke: palette.stroke?.channels,
            outline: palette.metadata["outline"] as? [Double],
            backgroundConfidence: palette.backgroundConfidence, strokeConfidence: palette.strokeConfidence,
            sourceInk: palette.sourceInk.map { source in
                NativeSourceGlyphSegmentation.Ink(foreground: source["foreground"] as? [Double] ?? [],
                    background: source["background"] as? [Double], stroke: source["stroke"] as? [Double],
                    outline: source["outline"] as? [Double],
                    backgroundConfidence: (source["confidence"] as? [String: Any])?["background"] as? Double ?? 0)
            })
    }

    private static func colorDistance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count >= 3, b.count >= 3 else { return 256 }
        return (0..<3).map { abs(a[$0] - b[$0]) }.max() ?? 256
    }
}
