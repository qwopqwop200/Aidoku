import CoreGraphics
import Foundation
import UIKit

extension NativeTranslationRenderer {
    /// The live kept-lettering IMG is a clone of the normalized cleanup source.
    /// Export hides that clone and restores original pixels at composite time.
    static func drawKeptSourceCopy(source: CGImage, geometry: NativeSourceSurfaceGeometry.Geometry,
                                   pieces: [CGRect], context: CGContext) {
        guard !pieces.isEmpty, valid(geometry.frame), valid(geometry.clip) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: geometry.clip)
        context.addRects(pieces)
        context.clip()
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        UIImage(cgImage: source).draw(in: geometry.frame)
    }
}
