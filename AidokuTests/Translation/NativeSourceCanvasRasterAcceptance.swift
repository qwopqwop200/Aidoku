/// A raster-only allowance for one quantization level on at most 0.01% of
/// canvas pixels. Source pixels, geometry and output dimensions stay exact.
/// This policy does not apply to restoration, artwork, glyphs or final16 gates.
enum NativeSourceCanvasRasterAcceptance {
    static func accepts(referenceWidth: Int, referenceHeight: Int, actualWidth: Int, actualHeight: Int,
                        changedPixels: Int, maximumChannelDelta: Int) -> Bool {
        guard referenceWidth > 0, referenceHeight > 0,
              actualWidth == referenceWidth, actualHeight == referenceHeight,
              changedPixels >= 0, maximumChannelDelta >= 0, maximumChannelDelta <= 1 else { return false }
        let (pixels, overflow) = referenceWidth.multipliedReportingOverflow(by: referenceHeight)
        guard !overflow else { return false }
        // Integer division enforces the inclusive fraction without rounding up
        // the permitted count or risking multiplication overflow.
        return changedPixels <= pixels / 10_000
    }
}
