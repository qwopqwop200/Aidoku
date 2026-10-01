import CoreGraphics
import Foundation

/// Source-position release uses the retained repair's pixel coordinates and
/// ownership proof, followed by the same final outline/geometry admission.
enum NativeRendererSourcePosition {
    /// `otherCandidates` contains only restoration surfaces that are still
    /// attached to this render. `otherSources` includes auxiliary source boxes.
    static func decide(item: NativeTranslationLayoutItem, ink: CGRect, font: Double,
        foreground: [Double], sampledStroke: [Double]?, oldPlate: CGRect?,
        candidate: NativeRestorationCandidate, otherCandidates: [String: NativeRestorationCandidate],
        otherSources: [(id: String, rect: CGRect)], neighbors: [CGRect], contentFits: Bool
    ) -> NativeTranslationSourceStylePostPolish.Outline? {
        guard let oldPlate, item.rotation == 0, !item.sourceTextOnly, candidate.erasureComplete,
              font.isFinite, font >= 7, contentFits else { return nil }
        let frame = candidate.frame, image = candidate.imageSize, crop = candidate.descriptor
        guard frame.size.width > 0, frame.size.height > 0,
              [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
               image.width, image.height, crop.sx, crop.sy].allSatisfy(\.isFinite) else { return nil }
        let rectangles = [item.sourceBounds] + item.auxiliaryInkRects
        guard rectangles.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let core = rectangles.map { b in
            CGRect(x: (b[0] * image.width - crop.crop.origin.x) * crop.sx,
                   y: (b[1] * image.height - crop.crop.origin.y) * crop.sy,
                   width: b[2] * image.width * crop.sx, height: b[3] * image.height * crop.sy)
        }
        // All real retained surfaces are bounded pixel crops. Reject corrupt
        // cached coordinates before the mask helpers convert them to integers.
        let integerLimit = sqrt(Double(Int.max)) / 4
        guard core.allSatisfy({ r in
            [r.origin.x, r.origin.y, r.size.width, r.size.height].allSatisfy { $0.isFinite && abs($0) < integerLimit }
        }) else { return nil }
        let ratio = Double(image.width / frame.width * crop.sx)
        let sourceFont = item.sourceFontSize.flatMap { $0.isFinite && $0 != 0 ? Double($0) : nil } ?? font
        let glyph = max(4, sourceFont * ratio)
        guard glyph.isFinite, glyph < integerLimit else { return nil }
        let safe = candidate.safe, w = candidate.surface.width, h = candidate.surface.height
        let resolved = NativePartialSourceProof.outlineSourceResolved(safe: safe, width: w, height: h, core: core,
            erasureVerified: candidate.sourceErasureVerified, glyphsVerified: candidate.sourceGlyphsVerified, pixelRatio: ratio)
        guard resolved else { return nil }
        let attached = item.sourceVertical && !item.sourceSingleColumn &&
            NativePartialSourceProof.hasAttachedLeadingInk(safe: safe, width: w, height: h, core: core, glyph: glyph)
        let residual = NativePartialSourceProof.hasLargePartialResidual(safe: safe, width: w, height: h,
            core: core, glyph: glyph, vertical: item.sourceVertical)
        let owners = Dictionary(grouping: otherSources.filter { $0.id != item.id }, by: \.id).map { id, sources in
            let other = otherCandidates[id]
            return NativePartialSourceProof.SourceOwner(sources: sources.map(\.rect),
                erasureVerified: other?.sourceErasureVerified == true, provisional: other?.provisional == true,
                partialCertified: other?.partialErasureCertified == true, connected: other != nil)
        }
        let b = item.sourceBounds
        let source = CGRect(x: frame.minX + b[0] * frame.width, y: frame.minY + b[1] * frame.height,
            width: b[2] * frame.width, height: b[3] * frame.height)
        return NativePartialSourceProof.outlinedSourcePosition(source: source, ink: ink, font: font,
            foreground: foreground, sampledStroke: sampledStroke, neighbors: neighbors, oldPlate: oldPlate,
            otherSources: owners, sourceVertical: item.sourceVertical, sourceSingleColumn: item.sourceSingleColumn,
            contentFits: contentFits, erasureComplete: candidate.erasureComplete, outlineResolved: resolved,
            attachedLeadingInk: attached, largePartialResidual: residual)
    }
}
