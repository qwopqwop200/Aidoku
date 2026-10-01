import CoreGraphics
import Foundation

extension NativeSpatialSourceCrop {
    struct SlantedPrepared {
        let prepared: Prepared
        var result: NativeSlantedRestoration.Result
        let scale: CGFloat
    }
    func prepareSlanted(item: NativeTranslationLayoutItem, palette: NativeRestorationPixels.Palette?,
                        excluded: [CGRect], frame: CGRect, upright: CGRect? = nil,
                        uprightBudget: inout Int, failures: NativeSlantedGeometry.Failures? = nil) -> SlantedPrepared? {
        guard let bounds = pixelRect(item.sourceBounds), frame.width > 0, frame.height > 0,
              item.sourceFrame.count == 4, item.sourceFrame.allSatisfy(\.isFinite), item.sourceFrame[2] > 0,
              item.sourceFrame[3] > 0 else { return nil }
        let iw = Double(image.width), ih = Double(image.height), sx = iw / Double(frame.width), sy = ih / Double(frame.height)
        guard abs(sx - sy) <= 0.01 * max(sx, sy) else { return nil }
        let auxiliary = item.auxiliaryInkRects.compactMap(pixelRect).prefix(32)
        let ratio = item.sourceVertical ? item.rect.height / item.rect.width : item.rect.width / item.rect.height
        let inferRuby = item.sourceRubyEligible && ratio >= 2.5 && palette?.verifiedForeground.map { $0.maximum <= 80 } == true &&
            palette?.verifiedBackground.map { $0.minimum >= 220 } == true
        let ruby = inferRuby ? min(96, Double(item.sourceVertical ? item.rect.width : item.rect.height) * sx * 0.8) : 0
        let margin = 40 + ceil(ruby)
        let card = upright.map { r in CGRect(x: (Double(r.minX) - Double(frame.minX)) * sx,
            y: (Double(r.minY) - Double(frame.minY)) * sy, width: Double(r.width) * sx, height: Double(r.height) * sy) }
        let extent = Array(auxiliary) + (card.map { [$0] } ?? [])
        let x = max(0, floor(min(Double(bounds.minX), extent.map { Double($0.minX) }.min() ?? .infinity)) - margin)
        let y = max(0, floor(min(Double(bounds.minY), extent.map { Double($0.minY) }.min() ?? .infinity)) - margin)
        let sourceWidth = min(iw, ceil(max(Double(bounds.maxX), extent.map { Double($0.maxX) }.max() ?? -.infinity)) + margin) - x
        let sourceHeight = min(ih, ceil(max(Double(bounds.maxY), extent.map { Double($0.maxY) }.max() ?? -.infinity)) + margin) - y
        let allowance: Int
        if upright != nil { allowance = 524_288 }
        else { allowance = min(524_288, restorationBudget / max(1, remaining)); remaining -= 1 }
        let scale = min(1, sqrt(min(262_144, Double(allowance) / 2) / ((sourceWidth + 48) * (sourceHeight + 48))))
        guard scale >= 0.5 else { return nil }
        let w = max(1, Int(floor(sourceWidth * scale))), h = max(1, Int(floor(sourceHeight * scale)))
        let rasterScale = min(Double(w) / sourceWidth, Double(h) / sourceHeight)
        let sourceSX = iw / Double(item.sourceFrame[2]), sourceSY = ih / Double(item.sourceFrame[3])
        let box = [(Double(item.rect.minX) - Double(item.sourceFrame[0])) * sourceSX - x,
                   (Double(item.rect.minY) - Double(item.sourceFrame[1])) * sourceSY - y,
                   Double(item.rect.width) * sourceSX, Double(item.rect.height) * sourceSY].map { $0 * rasterScale }
        func local(_ r: CGRect) -> CGRect {
            CGRect(x: (Double(r.minX) - x) * rasterScale, y: (Double(r.minY) - y) * rasterScale,
                   width: Double(r.width) * rasterScale, height: Double(r.height) * rasterScale)
        }
        var options = NativeSlantedGeometry.Options()
        options.auxiliary = auxiliary.map { NativeSlantedGeometry.array(local($0)) }
        options.inferredRubyExclusions = excluded.prefix(256).map { NativeSlantedGeometry.array(local($0)) }
        options.failures = failures
        options.inferRuby = inferRuby; options.cover = card.map { NativeSlantedGeometry.array(local($0)) }
        options.auxiliaryPolygons = item.auxiliaryInkPolygons.prefix(32).filter { q in
            q.count == 4 && q.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) }
        }.map { q in q.map { [(Double($0[0]) * iw - x) * rasterScale, (Double($0[1]) * ih - y) * rasterScale] } }
        let geometry = NativeSlantedGeometry.localGeometry(box: box, angle: Double(item.rotation), vertical: item.sourceVertical, options: options)
        guard w >= 8, h >= 8, w <= 262_144 / h,
              geometry.width > 0, geometry.height > 0, geometry.width <= 262_144 / geometry.height else { return nil }
        let pixels = w * h + geometry.width * geometry.height
        if upright != nil { guard pixels <= uprightBudget else { return nil }; uprightBudget -= pixels }
        else { guard pixels <= allowance else { failures?.reasons.append("budget"); return nil }; restorationBudget -= pixels }
        guard let rgba = try? reader.read(x: x, y: y, sourceWidth: sourceWidth, sourceHeight: sourceHeight, width: w, height: h) else { return nil }
        var original = NativeRestorationPixels(width: w, height: h); original.rgba = rgba
        guard let result = NativeSlantedRestoration.restore(original, box: box, angle: Double(item.rotation),
            palette: palette, vertical: item.sourceVertical, options: options) else { return nil }
        let crop = CGRect(x: x, y: y, width: sourceWidth, height: sourceHeight)
        let prepared = Prepared(pixels: original, crop: crop, source: bounds, box: NativeSlantedGeometry.rect(box),
            auxiliary: options.auxiliary.map(NativeSlantedGeometry.rect), excluded: options.inferredRubyExclusions.map(NativeSlantedGeometry.rect),
            marks: [], leadingRule: false, sx: rasterScale, sy: rasterScale, synthetic: [UInt8](repeating: 0, count: w * h))
        return SlantedPrepared(prepared: prepared, result: result, scale: sx * rasterScale)
    }
}
