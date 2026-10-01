import CoreGraphics
import Foundation

/// The final source-owned repair pass runs after typography decides which
/// readability plates remain. Merely proposing a local repair spends no budget.
final class NativeDeferredForcedRestoration {
    struct Report {
        enum Status: String { case absentPanel, alreadyCertified, invalidCrop, rejected, accepted }
        let itemID: String
        let status: Status
        let pixels: Int
    }
    private let image: CGImage
    private let layout: NativeTranslationLayout
    private let cleanupGeometry: NativeSourceSurfaceGeometry.Geometry?
    private let reader: NativeSourcePixelReader
    private let cropper: NativeSpatialSourceCrop
    private(set) var completed = false
    var remainingPixels: Int { cropper.forcedBudget }

    init(image: CGImage, layout: NativeTranslationLayout, cleanupGeometry: NativeSourceSurfaceGeometry.Geometry? = nil) {
        self.image = image; self.layout = layout; self.cleanupGeometry = cleanupGeometry
        reader = NativeSourcePixelReader(image: image)
        cropper = NativeSpatialSourceCrop(image: image, reader: reader, eligibleCount: 0)
    }

    /// The caller supplies final plate presence, including rotated plates, and
    /// receives the same source-order outcome for panel fallback bookkeeping.
    @discardableResult func apply(to result: inout NativeTranslationRestoration.Result,
        hasReadabilityPanel: (NativeTranslationLayoutItem) -> Bool) throws -> [Report] {
        guard !completed else { return [] }
        completed = true
        defer { reader.release() }
        var reports: [Report] = []
        func report(_ item: NativeTranslationLayoutItem, _ status: Report.Status, _ pixels: Int = 0) {
            reports.append(Report(itemID: item.id, status: status, pixels: pixels))
        }
        let protected = layout.items.filter(\.keptLettering).flatMap { other in
            ([other.sourceBounds] + other.auxiliaryInkRects).compactMap(cropper.pixelRect)
        }
        for item in layout.items where !item.keptLettering {
            try Task.checkCancellation()
            guard hasReadabilityPanel(item) else { report(item, .absentPanel); continue }
            let old = result.appearances[item.id]
            let existing = result.patches.first { $0.itemID == item.id && !$0.independentArtworkCover }
            let complete = existing?.candidate?.erasureComplete ?? old?.erasureComplete ?? false
            let provisional = existing?.candidate?.provisional ?? old?.provisional ?? false
            let glyphsVerified = existing?.candidate?.sourceGlyphsVerified ?? old?.sourceGlyphsVerified ?? false
            if complete && !provisional && (glyphsVerified || existing?.candidate?.sourceErasureVerified == true) {
                report(item, .alreadyCertified); continue
            }
            let excluded = layout.items.filter { $0.id != item.id }.flatMap { other in
                ([other.sourceBounds] + other.auxiliaryInkRects).compactMap(cropper.pixelRect)
            }
            let palette = old?.sourceSample.flatMap(NativeRestorationPixels.palette)
            guard let prepared = cropper.prepare(item: item, palette: palette, excluded: protected,
                forced: true, sample: old?.sourceSample, frame: cleanupGeometry?.frame) else { report(item, .invalidCrop); continue }
            let frame = cleanupGeometry?.frame ?? layout.sourceRect
            let sourceFont = item.sourceFontSize.flatMap { $0 != 0 && !$0.isNaN ? $0 : nil } ?? 8
            let glyph = max(8, Double(sourceFont) * Double(image.width) / Double(frame.width))
            let scale = Double(prepared.nominalScale ?? min(prepared.sx, prepared.sy))
            func polygon(_ target: NativeTranslationLayoutItem) -> [[CGFloat]] {
                if target.sourcePolygon.count >= 3 { return target.sourcePolygon }
                let b = target.sourceBounds
                return [[b[0], b[1]], [b[0] + b[2], b[1]], [b[0] + b[2], b[1] + b[3]], [b[0], b[1] + b[3]]]
            }
            func localPolygon(_ vertices: [[CGFloat]]) -> [CGPoint] {
                vertices.compactMap { point in
                    guard point.count == 2 else { return nil }
                    return CGPoint(x: (point[0] * CGFloat(image.width) - prepared.crop.minX) * prepared.sx,
                                   y: (point[1] * CGFloat(image.height) - prepared.crop.minY) * prepared.sy)
                }
            }
            let auxiliary = item.auxiliaryInkRects.filter { $0.count == 4 && $0.allSatisfy(\.isFinite) && $0[2] > 0 && $0[3] > 0 }
            let own = [polygon(item)] + item.auxiliaryInkPolygons + auxiliary.map { b in
                [[b[0], b[1]], [b[0] + b[2], b[1]], [b[0] + b[2], b[1] + b[3]], [b[0], b[1] + b[3]]]
            }
            let ownedPolygons = own.map(localPolygon)
            let foreignPolygons = layout.items.filter { $0.id != item.id }.map { localPolygon(polygon($0)) }
            let safeDonors = (item.sourceLettering == "display" || item.sourceLettering == "title") && item.balloonInterior?.contourVerified != true
            var repaired = palette.flatMap { NativeResidualProof.forceComponent(prepared.pixels, box: prepared.box,
                auxiliary: prepared.auxiliary, excluded: prepared.excluded, palette: $0, vertical: item.sourceVertical,
                polygons: ownedPolygons, excludedPolygons: foreignPolygons, glyphSize: glyph * scale,
                trailing: min(72, max(24, glyph * 2 * scale)), donorExcluded: excluded.map(prepared.local), requireSafeDonors: safeDonors) }
            if repaired == nil {
                var options = NativeForcedSourceInpainting.Options()
                options.auxiliary = prepared.auxiliary; options.excluded = prepared.excluded
                options.donorExcluded = excluded.map(prepared.local); options.polygons = ownedPolygons
                options.excludedPolygons = foreignPolygons; options.vertical = item.sourceVertical
                options.glyphSize = glyph * scale; options.trailing = min(72, max(24, glyph * 2 * scale))
                options.requireSafeDonors = safeDonors
                if let fallback = NativeForcedSourceInpainting.restore(rgba: prepared.pixels.rgba,
                    width: prepared.pixels.width, height: prepared.pixels.height, box: prepared.box, palette: palette, options: options).result {
                    var pixels = NativeRestorationPixels(width: prepared.pixels.width, height: prepared.pixels.height)
                    pixels.rgba = fallback.rgba; pixels.layoutSafe = fallback.layoutSafe
                    pixels.erasureComplete = fallback.sourceErasureVerified; pixels.glyphsVerified = fallback.sourceGlyphsVerified
                    pixels.method = fallback.method
                    pixels.sourceRemainingInk = fallback.sourceRemainingInk; pixels.preservedCore = fallback.preservedCore
                    pixels.preservedPixels = fallback.preservedPixels; repaired = pixels
                }
            }
            guard let repaired, repaired.erasureComplete, repaired.glyphsVerified, repaired.paintedCount > 0,
                  repaired.preservedCore == 0, repaired.preservedPixels == 0,
                  repaired.layoutSafe?.count == repaired.count, let patchImage = repaired.image() else {
                result.patches.removeAll { $0.itemID == item.id && !$0.independentArtworkCover }
                result.appearances[item.id] = appearance(old ?? .init(foreground: nil, background: nil, restored: false), repaired: nil)
                report(item, .rejected, prepared.pixels.count); continue
            }
            let rect = CGRect(x: frame.minX + prepared.crop.minX / CGFloat(image.width) * frame.width,
                y: frame.minY + prepared.crop.minY / CGFloat(image.height) * frame.height,
                width: prepared.crop.width / CGFloat(image.width) * frame.width, height: prepared.crop.height / CGFloat(image.height) * frame.height)
            result.patches.removeAll { $0.itemID == item.id && !$0.independentArtworkCover }
            result.patches.append(.init(image: patchImage, rect: rect, itemID: item.id, layoutSafe: repaired.layoutSafe,
                surfaceQuality: repaired.surfaceQuality, finalForcedErasure: true,
                rasterGeometry: .init(frame: frame, imageSize: CGSize(width: image.width, height: image.height),
                    origin: prepared.crop.origin, scale: CGSize(width: prepared.sx, height: prepared.sy)),
                cleanupClip: cleanupGeometry?.clip))
            result.appearances[item.id] = appearance(old ?? .init(foreground: nil, background: nil, restored: false), repaired: repaired)
            result.limitations.removeAll { $0 == "unresolved-source-restoration:\(item.id)" }
            report(item, .accepted, repaired.count)
        }
        return reports
    }
    private func appearance(_ old: NativeTranslationRestoration.Appearance, repaired: NativeRestorationPixels?) -> NativeTranslationRestoration.Appearance {
        .init(foreground: old.foreground, background: old.background, restored: repaired != nil,
            stroke: old.stroke, strokeWidth: old.strokeWidth, erasureComplete: repaired != nil,
            letteringStyle: old.letteringStyle, fontName: old.fontName, sourceStrokeWeight: old.sourceStrokeWeight,
            sourceSample: old.sourceSample, restorationMethod: repaired?.method,
            sourceGlyphsVerified: repaired?.glyphsVerified ?? false, finalForcedErasure: repaired != nil, provisional: false)
    }
}
