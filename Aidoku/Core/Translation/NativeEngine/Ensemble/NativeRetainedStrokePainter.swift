import CoreGraphics
import Foundation

/// A retained AA endpoint is premultiplied (a,a,a,a) for white or (0,0,0,a)
/// for black. Requiring a==255 confuses raster coverage with endpoint purity.
enum NativeRetainedStrokePainter {
    enum Failure: Error { case missingOutline(Int), changedGlyphCore(Int), invalidCrop(Int) }

    static func inspect(layer: NativeMandatoryDisplayStroke.Prepared, final: CGImage,
                        haloPage: CGImage, index: Int) throws -> [String: Any] {
        guard let crop = final.cropping(to: layer.frame),
              let under = haloPage.cropping(to: layer.frame) else { throw Failure.invalidCrop(index) }
        let fill = try NativeMandatoryDisplayStroke.rgba(layer.fill)
        let halo = try NativeMandatoryDisplayStroke.rgba(layer.halo)
        let retained = try NativeMandatoryDisplayStroke.rgba(crop)
        let base = try NativeMandatoryDisplayStroke.rgba(under)
        guard fill.count == retained.count, fill.count == halo.count,
              fill.count == base.count else { throw Failure.invalidCrop(index) }
        var opaque = 0, supported = 0, core = 0, opaqueCore = 0
        var mass = 0.0, expectedMass = 0.0, maximumFillAlpha = 0, maximumHaloAlpha = 0
        var maximumOutsideHaloAlpha = 0, outsideHistogram: [String: Int] = [:]
        for p in stride(from: 0, to: fill.count, by: 4) {
            let f = Int(fill[p+3]), h = Int(halo[p+3]), a = Int(retained[p+3])
            maximumFillAlpha = max(maximumFillAlpha, f)
            maximumHaloAlpha = max(maximumHaloAlpha, h)
            if f == 0, h > 0 {
                maximumOutsideHaloAlpha = max(maximumOutsideHaloAlpha, h)
                outsideHistogram[String(h), default: 0] += 1
            }
            if f == 0, h >= 128 {
                expectedMass += Double(h)/255
                let pure = (0..<3).allSatisfy { retained[p+$0] == (layer.endpoint == 255 ? UInt8(a) : 0) }
                if pure, a >= h {
                    supported += 1; mass += Double(h)/255
                    if h == 255, a == 255 { opaque += 1 }
                }
            }
            // Verify substantial AA cores too: own fill OVER the actual union
            // of halos, before peer fills. This rejects later destructive fill
            // occlusion without rejecting normal halo under AA edge coverage.
            if f >= 128 {
                let changed = (0..<4).contains { c in
                    let expected = Int(fill[p+c]) + (Int(base[p+c])*(255-f)+127)/255
                    return abs(expected-Int(retained[p+c])) > 2
                }
                if changed { core += 1; if f == 255 { opaqueCore += 1 } }
            }
        }
        // >=2 output-pixel equivalents, >=2 substantial samples, >=half the
        // eligible own halo support. A nonzero invisible fringe cannot pass.
        let visible = supported >= 2 && mass >= 2 && mass >= expectedMass*0.5 && layer.addedAlphaPixels > 0
        return ["index": index, "endpoint": Int(layer.endpoint), "radiusOutputPixels": layer.outwardPixels,
            "retainedOpaqueBWOutsideOwnFill": opaque, "retainedAAEndpointPixels": supported,
            "retainedAAAlphaMass": mass, "eligibleHaloAlphaMass": expectedMass,
            "maximumFillAlpha": maximumFillAlpha, "maximumHaloAlpha": maximumHaloAlpha,
            "maximumOutsideFillHaloAlpha": maximumOutsideHaloAlpha, "outsideFillHaloAlphaHistogram": outsideHistogram,
            "opaqueCoreChangedPixels": opaqueCore, "substantialCoreChangedPixels": core,
            "visibleOutlineCertified": visible, "minimumSupportAlpha": 128,
            "minimumAlphaMass": 2, "minimumRetainedSupportFraction": 0.5]
    }

    static func haloImage(_ layers: [NativeMandatoryDisplayStroke.Prepared], restored: CGImage) throws -> CGImage {
        guard let c = CGContext(data: nil, width: restored.width, height: restored.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw NativeAOTTranslationPageComposer.Failure.allocation }
        for l in layers {
            c.draw(l.halo, in: CGRect(x: l.frame.minX, y: CGFloat(l.pageHeight)-l.frame.maxY,
                                     width: l.frame.width, height: l.frame.height))
        }
        guard let image = c.makeImage() else { throw NativeAOTTranslationPageComposer.Failure.allocation }
        return image
    }

    static func paint(restored: CGImage, fills: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive],
                      expectedItems: Int, textComplete: Bool) throws -> NativeAOTTranslationPageComposer.TextLayer {
        guard textComplete, expectedItems == fills.count else { throw NativeAOTTranslationPageComposer.Failure.incompleteTranslation }
        let start = Date()
        let layers = try fills.map { try NativeMandatoryDisplayStroke.prepare(fill: $0.image, restored: restored,
            fontOutputPixels: $0.fontOutputPixels, fillFrame: $0.frame) }
        let halos = try haloImage(layers, restored: restored)
        guard let c = CGContext(data: nil, width: restored.width, height: restored.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw NativeAOTTranslationPageComposer.Failure.allocation }
        NativeMandatoryDisplayStroke.paint(layers, in: c)
        guard let image = c.makeImage() else { throw NativeAOTTranslationPageComposer.Failure.allocation }
        var records: [[String: Any]] = []
        for (i, l) in layers.enumerated() {
            let r = try inspect(layer: l, final: image, haloPage: halos, index: i)
            guard r["visibleOutlineCertified"] as! Bool else { throw Failure.missingOutline(i) }
            guard r["substantialCoreChangedPixels"] as! Int == 0 else { throw Failure.changedGlyphCore(i) }
            records.append(r)
        }
        return .init(image: image, expectedItems: expectedItems, paintedItems: fills.count, complete: true,
            audit: ["policy": "mandatory-pureBW-outward-max2px-014em", "paintOrder": "all-strokes-then-all-fills",
                "fontRefitForHalo": false, "restoredImageExplicit": true, "retainedStrokeItems": records,
                "strokePreparePaintAuditSeconds": Date().timeIntervalSince(start),
                "auditAuthority": "final premultiplied endpoint coverage and AA core; no source-color or page quality truth"])
    }
}
