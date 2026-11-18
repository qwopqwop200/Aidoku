import CoreGraphics

/// Validates derived sampling geometry before allocation or integer conversion.
/// Normal requests retain their original coordinates, including subpixel rounding.
enum NativeTextBoxSourceProjection {
    static func project(_ roi: CGRect, frame: CGRect, sourceSize: CGSize) -> CGRect? {
        guard [roi, frame].allSatisfy({
            !$0.isNull && !$0.isInfinite && $0.size.width > 0 && $0.size.height > 0
                && [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite)
        }), sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let sx = sourceSize.width / frame.width, sy = sourceSize.height / frame.height
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return nil }
        let result = CGRect(x: (roi.minX - frame.minX) * sx, y: (roi.minY - frame.minY) * sy,
                            width: roi.width * sx, height: roi.height * sy)
        guard result.size.width > 0, result.size.height > 0,
              [result.minX, result.minY, result.maxX, result.maxY].allSatisfy(\.isFinite) else { return nil }
        // Permit floating-point edge noise, not a reconstructed span extending
        // materially past the source (e.g. width 3 becoming 4 at origin 2^53).
        let toleranceX = sourceSize.width * CGFloat.ulpOfOne * 16
        let toleranceY = sourceSize.height * CGFloat.ulpOfOne * 16
        guard result.minX >= -toleranceX, result.minY >= -toleranceY,
              result.maxX <= sourceSize.width + toleranceX,
              result.maxY <= sourceSize.height + toleranceY else { return nil }
        return result
    }
}
