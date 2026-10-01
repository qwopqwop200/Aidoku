import CoreGraphics
import Foundation

extension NativeRestorationPixels {
    /// Compatibility entry for the single observed-palette policy. The source wrapper
    /// sequences evidence, compact-mask and connected-glyph retries separately.
    static func observed(_ p: Self, box: CGRect, auxiliary: [CGRect], excluded: [CGRect], palette: Palette,
                         vertical: Bool, polygon: [CGPoint], slanted: Bool) -> Self? {
        var options = NativeObservedRestoreOptions()
        options.auxiliary = auxiliary; options.excluded = excluded; options.inferredRubyExclusions = excluded
        options.vertical = vertical; options.slantedOwnership = slanted
        return exactObserved(p, box: box, palette: palette, options: options)
    }
}
