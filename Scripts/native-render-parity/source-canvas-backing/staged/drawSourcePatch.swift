import CoreGraphics
import UIKit

extension NativeTranslationRenderer {
    static func drawSourcePatch(_ patch: SourcePatch, context: CGContext, appliesCanvasClip: Bool = true,
                                usesLiveTextureSampling: Bool = false, canvasSession: NativeCanvasTextureResampler.Session? = nil,
                                canvasBacking: NativeCanvasBacking? = nil) {
        let canonicalBacking = usesLiveTextureSampling && (canvasBacking?.matchesFreshState(context) ?? false)
        context.saveGState()
        defer { context.restoreGState() }
        if appliesCanvasClip, let rawClip = patch.cleanupClip {
            var clip: CGRect? = rawClip
            if let authored = patch.authoredCanvasRect {
                let matrix = context.ctm
                let xScale = hypot(matrix.a, matrix.b), yScale = hypot(matrix.c, matrix.d)
                // The observed CSS device-scale contract is uniform. Keep the
                // prior global clip for unsupported nonuniform transforms.
                if xScale.isFinite, yScale.isFinite, xScale > 0, Float(xScale) == Float(yScale) {
                    clip = NativeSourceCanvasClip.liveClip(authoredRect: authored, domRect: patch.rect,
                        cleanupClip: rawClip, deviceScale: xScale)
                }
            }
            if let clip {
                guard clip.width > 0, clip.height > 0 else { return }
                context.clip(to: clip)
            }
        }
        // Live canvas painting rounds CSS edges independently of its clip
        // reference box. Saved source masks retain their DOM-used frame.
        let frame: CGRect
        if appliesCanvasClip {
            guard let live = NativeSourceCanvasImageFrame.liveFrame(domRect: patch.rect) else { return }
            frame = live
        } else { frame = patch.rect }
        if usesLiveTextureSampling {
            let matrix = context.ctm
            let scale = matrix.a
            let fullSize = CGSize(width: frame.width * scale, height: frame.height * scale)
            let deviceOrigin = context.convertToDeviceSpace(frame.origin)
            // The experimental live path currently proves axis-aligned,
            // integral device pixels only. Preserve CG sampling elsewhere.
            if scale.isFinite, scale > 0, matrix.b == 0, matrix.c == 0, abs(matrix.d) == scale,
               [fullSize.width, fullSize.height, deviceOrigin.x, deviceOrigin.y].allSatisfy({ $0.isFinite && $0.rounded(.towardZero) == $0 }),
               fullSize.width > 0, fullSize.height > 0 {
                let visible = frame.intersection(context.boundingBoxOfClipPath)
                guard visible.width > 0, visible.height > 0 else { return }
                let left = max(0, floor((visible.minX - frame.minX) * scale))
                let top = max(0, floor((visible.minY - frame.minY) * scale))
                let right = min(fullSize.width, ceil((visible.maxX - frame.minX) * scale))
                let bottom = min(fullSize.height, ceil((visible.maxY - frame.minY) * scale))
                let crop = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                let tileFrame = CGRect(x: frame.minX + left / scale,
                    y: frame.minY + top / scale, width: crop.width / scale, height: crop.height / scale)
                do {
                    // Expansion/identity only: no new minification contract is
                    // inferred from the separate linear-filter primitive.
                    if canonicalBacking, fullSize.width >= CGFloat(patch.image.width),
                       fullSize.height >= CGFloat(patch.image.height),
                       let background = canvasBacking?.backgroundRGBA(context: context, userRect: tileFrame) {
                        let composited = try NativeCanvasTextureResampler.compositeCanvasImage(image: patch.image,
                            destinationPixels: fullSize, cropPixels: crop, backgroundRGBA: background, session: canvasSession)
                        context.interpolationQuality = .none
                        UIImage(cgImage: composited).draw(in: tileFrame, blendMode: .copy, alpha: 1)
                        return
                    }
                    let tile = try NativeCanvasTextureResampler.canvasImage(image: patch.image,
                        destinationPixels: fullSize, cropPixels: crop, session: canvasSession)
                    context.interpolationQuality = .none
                    UIImage(cgImage: tile).draw(in: tileFrame)
                    return
                } catch is CancellationError { return }
                catch { /* Unsupported hardware/bounds retain the existing CG path. */ }
            }
        }
        UIImage(cgImage: patch.image).draw(in: frame)
    }
}
