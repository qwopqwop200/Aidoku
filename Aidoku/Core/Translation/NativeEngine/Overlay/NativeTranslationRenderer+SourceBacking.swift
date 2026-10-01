import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// A clipped caption clone retains its DOM box and local clip declaration.
    /// Vector border painting snaps the box first; the local clip moves with
    /// that painted origin without changing its declared dimensions.
    static func drawSourceBacking(_ backing: NativePanelGeometry.Backing, context: CGContext,
                                  pixelSnapScale: CGFloat? = nil) {
        context.saveGState()
        defer { context.restoreGState() }
        if let pixelSnapScale {
            let frame = NativeTranslationPDFCapture.snappedRect(backing.frame, deviceScale: pixelSnapScale)
            if backing.clipped {
                applyCoverageClip(backing.coverageClip, coverage: backing.coverage, owner: backing.frame,
                    context: context, pixelSnapScale: pixelSnapScale, legacyOrigin: frame.origin)
            }
            context.setFillColor(color(backing.color.map { CGFloat($0) }))
            context.addPath(NativeTranslationPDFCapture.roundedPath(backing.frame, radius: 3,
                deviceScale: pixelSnapScale))
            context.fillPath()
        } else {
            context.addPath(CGPath(roundedRect: backing.frame, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.clip()
            if backing.clipped {
                applyCoverageClip(backing.coverageClip, coverage: backing.coverage, owner: backing.frame, context: context)
            }
            context.setFillColor(color(backing.color.map { CGFloat($0) }))
            context.fill(backing.frame)
        }
    }
}
