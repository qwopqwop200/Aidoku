import CoreGraphics
import Foundation

/// A synchronous slanted glyph trial can request its original upright source
/// crop without spending a separate budget or painting a rejected proposal.
final class NativeSlantedPreparation {
    final class Budget { var remaining = 1_048_576 }
    private let cropper: NativeSpatialSourceCrop
    private let item: NativeTranslationLayoutItem
    private let palette: NativeRestorationPixels.Palette?
    private let excluded: [CGRect]
    private let frame: CGRect
    private let clip: CGRect?
    private let budget: Budget

    init(cropper: NativeSpatialSourceCrop, item: NativeTranslationLayoutItem, palette: NativeRestorationPixels.Palette?,
         excluded: [CGRect], frame: CGRect, budget: Budget, clip: CGRect? = nil) {
        self.cropper = cropper; self.item = item; self.palette = palette
        self.excluded = excluded; self.frame = frame; self.budget = budget; self.clip = clip
    }
    func prepareUpright(_ rect: CGRect) -> NativeSpatialSourceCrop.SlantedPrepared? {
        cropper.prepareSlanted(item: item, palette: palette, excluded: excluded, frame: frame,
            upright: rect, uprightBudget: &budget.remaining)
    }
    func patch(_ proposal: NativeSpatialSourceCrop.SlantedPrepared) -> NativeTranslationRestoration.Patch? {
        guard proposal.result.pixels.paintedCount > 0, let image = proposal.result.pixels.image() else { return nil }
        let crop = proposal.prepared.crop, source = cropper.image
        let rect = CGRect(x: frame.minX + crop.minX / CGFloat(source.width) * frame.width,
            y: frame.minY + crop.minY / CGFloat(source.height) * frame.height,
            width: crop.width / CGFloat(source.width) * frame.width, height: crop.height / CGFloat(source.height) * frame.height)
        var proof = proposal.result.proof
        proof.method = proposal.result.pixels.method; proof.preparation = self
        return .init(image: image, rect: rect, itemID: item.id, slantedProof: proof, slantedScale: proposal.scale,
            rasterGeometry: .init(frame: frame, imageSize: CGSize(width: source.width, height: source.height),
                origin: crop.origin, scale: CGSize(width: proposal.prepared.sx, height: proposal.prepared.sy)), cleanupClip: clip)
    }
}
