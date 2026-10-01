import CoreGraphics
import UIKit

extension NativeTranslationRenderer {
    /// The caller attests alpha one and normal blending in a fresh bitmap
    /// scope. The image's opacity is checked from its actual canonical samples.
    /// This path never reads or overwrites destination bytes and preserves the
    /// real CGContext clip. Minification and translucent sources still use CG.
    static func drawOpaqueAffineSourcePatch(_ patch: SourcePatch, context: CGContext,
                                           session: NativeCanvasTextureResampler.Session) throws -> Bool {
        try Task.checkCancellation()
        guard patch.cleanupClip == nil, context.data != nil,
              context.bitsPerComponent == 8, context.bitsPerPixel == 32,
              context.colorSpace?.name == CGColorSpace.sRGB,
              context.width > 0, context.height > 0,
              context.width <= NativeCanvasTextureResampler.maximumDimension,
              context.height <= NativeCanvasTextureResampler.maximumDimension else { return false }
        let origin = context.convertToDeviceSpace(CGPoint.zero)
        let x = context.convertToDeviceSpace(CGPoint(x: 1, y: 0))
        let y = context.convertToDeviceSpace(CGPoint(x: 0, y: 1))
        // These conversions remove the bitmap's base Y flip. The raw CTM
        // would mirror the source a second time when used as a Metal basis.
        let basis = CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
            c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y)
        let geometry = try NativeCanvasTextureResampler.affineCanvasGeometry(domRect: patch.rect,
            userToPixelTransform: basis)
        let inverse = basis.inverted()
        guard [inverse.a, inverse.b, inverse.c, inverse.d, inverse.tx, inverse.ty].allSatisfy(\.isFinite) else { return false }
        let quad = geometry.pixelQuad
        let imageWidth = hypot(quad[1].x - quad[0].x, quad[1].y - quad[0].y)
        let imageHeight = hypot(quad[3].x - quad[0].x, quad[3].y - quad[0].y)
        guard imageWidth >= CGFloat(patch.image.width), imageHeight >= CGFloat(patch.image.height) else { return false }
        let viewport = CGSize(width: context.width, height: context.height)
        guard let crop = geometry.samplingCrop(viewportPixelSize: viewport) else { return true }
        guard Double(crop.width) * Double(crop.height) <= Double(NativeCanvasTextureResampler.maximumPixels) else { return false }
        guard try NativeCanvasTextureResampler.isOpaqueSource(image: patch.image, session: session) else { return false }
        let tile = try NativeCanvasTextureResampler.affineCanvasImage(image: patch.image,
            domRect: patch.rect, userToPixelTransform: basis, viewportPixelSize: viewport,
            cropPixels: crop, session: session)
        try Task.checkCancellation()
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(inverse)
        context.interpolationQuality = .none
        // Transparent samples outside the quad preserve destination paint.
        // The affine transform has already been applied by the GPU.
        UIImage(cgImage: tile).draw(in: crop, blendMode: .normal, alpha: 1)
        return true
    }
}
