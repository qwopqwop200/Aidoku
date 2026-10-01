import CoreGraphics

extension NativeTranslationRenderer {
    /// Apply the current CSS declaration using its local reference box. The
    /// reference origin and size snap independently; border paint snapping is
    /// a different operation. Unsupported contexts retain the prior clip.
    static func applyCoverageClip(_ declaration: NativeCSSCoveragePath.Declaration?,
        coverage: [CGRect], owner: CGRect, context: CGContext, pixelSnapScale: CGFloat? = nil,
        legacyOrigin: CGPoint? = nil) {
        let scale: CGFloat? = {
            if let pixelSnapScale { return pixelSnapScale }
            let m = context.ctm
            guard m.a.isFinite, m.a > 0, m.b == 0, m.c == 0,
                  Float(m.a).isFinite, Float(abs(m.d)) == Float(m.a) else { return nil }
            return m.a
        }()
        if let declaration, let scale, scale > 0 {
            let reference = NativeSourceCanvasClip.referenceRect(domRect: owner, deviceScale: scale)
            if let path = NativeCSSCoveragePath.path(declaration, referenceBox: reference) {
                // GraphicsContext replaces, rather than unions with, a pending path.
                // A degenerate inset path deliberately clips to the empty shape.
                context.beginPath(); context.addPath(path); context.clip(); return
            }
        }
        let origin = legacyOrigin ?? owner.origin
        let path = CGMutablePath()
        for rect in coverage {
            path.addRect(rect.offsetBy(dx: origin.x-owner.minX, dy: origin.y-owner.minY))
        }
        context.beginPath(); context.addPath(path); context.clip()
    }
}
