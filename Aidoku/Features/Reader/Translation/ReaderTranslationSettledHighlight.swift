import Gifu
import UIKit

/// Tentative live static presentation lease. It owns only the selected visual
/// alternate, never the underlying source UIImage or the interaction hierarchy.
@MainActor
final class ReaderTranslationSettledHighlight {
    private weak var view: UIImageView?
    private var ownedAlternate: UIImage?

    func isActive(in view: UIImageView) -> Bool {
        self.view === view && view.isHighlighted && ownedAlternate != nil &&
            view.highlightedImage === ownedAlternate
    }

    static func matches(_ geometry: ReaderTranslationImageGeometry, in view: UIImageView) -> Bool {
        geometry.isValid && view.bounds.size == geometry.viewport &&
            view.traitCollection.displayScale == geometry.scale &&
            (view.traitCollection.userInterfaceStyle == .dark) == geometry.dark &&
            view.contentMode == (geometry.aspectFit ? .scaleAspectFit : .scaleToFill)
    }

    @discardableResult
    func acquire(
        view: UIImageView, source: UIImage, settled: UIImage,
        geometry: ReaderTranslationImageGeometry, isKnownStatic: Bool,
        cancelled: Bool = Task.isCancelled
    ) -> Bool {
        guard !cancelled, isKnownStatic,
              view.image === source, source.imageOrientation == .up, settled.imageOrientation == .up,
              source.images == nil, settled.images == nil, source.capInsets == .zero, settled.capInsets == .zero,
              source.renderingMode != .alwaysTemplate, view.animationImages?.isEmpty != false,
              view.highlightedAnimationImages?.isEmpty != false, !view.isAnimating,
              Self.matches(geometry, in: view),
              self.view == nil, !view.isHighlighted, view.highlightedImage == nil,
              let pixels = settled.cgImage, source.size.width > 0, source.size.height > 0 else { return false }
        if let gif = view as? GIFImageView, gif.frameCount != 0 || gif.isAnimatingGIF { return false }
        let scale = CGFloat(pixels.width) / source.size.width
        guard scale.isFinite, scale > 0, CGFloat(pixels.height) / scale == source.size.height else { return false }
        let alternate = UIImage(cgImage: pixels, scale: scale, orientation: .up).withRenderingMode(.alwaysOriginal)
        guard alternate.size == source.size else { return false } // Odd rounded raster: keep existing child view.
        self.view = view
        ownedAlternate = alternate
        UIView.performWithoutAnimation {
            view.highlightedImage = alternate
            view.isHighlighted = true
        }
        return true
    }

    func release() {
        defer { view = nil; ownedAlternate = nil }
        guard let view, let ownedAlternate, view.highlightedImage === ownedAlternate else { return }
        UIView.performWithoutAnimation {
            view.isHighlighted = false
            view.highlightedImage = nil
        }
    }
}
