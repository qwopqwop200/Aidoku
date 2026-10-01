import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// The source <img> occupied the viewport; its decoded, normalized bitmap
    /// determined object-fit geometry independently of the OCR planner frame.
    static func normalizedCleanupGeometry(layout: NativeTranslationLayout, naturalSize: CGSize,
                                          objectFit: String? = nil) -> NativeSourceSurfaceGeometry.Geometry? {
        func cssLength(_ value: CGFloat) -> CGFloat {
            CGFloat((Float(value) * 64).rounded(.towardZero)) / 64
        }
        let element = CGRect(x: 0, y: 0, width: cssLength(layout.viewport.width), height: cssLength(layout.viewport.height))
        let originalElement = CGRect(origin: .zero, size: layout.viewport)
        // Older layouts did not retain the fit flag. A full viewport source
        // frame uses the historical fill fallback; new renders store the flag
        // so equal-aspect contain/fill layouts remain distinguishable.
        let fit = objectFit ?? layout.sourceObjectFit ?? (layout.sourceRect == originalElement ? "fill" : "contain")
        return NativeSourceSurfaceGeometry.contentGeometry(rect: element, naturalSize: naturalSize,
            style: ["transform": "none", "objectFit": fit, "objectPosition": "50% 50%"])
    }
}
