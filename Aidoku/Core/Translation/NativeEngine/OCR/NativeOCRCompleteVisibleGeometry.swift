import Foundation
import CoreGraphics

/// Read-only geometry support; never ownership, status or erasure evidence.
/// Parent supplies the actual SOURCE-ONLY old preferred polygon, not GT/cache.
/// Use to admit NEW normal-changing proposals; keep old/inherited selectable.
@available(iOS 18.0, *)
enum NativeOCRCompleteVisibleGeometry {
    static func support(
        _ m: NativeOCRSourceComponentMeasurements.Measurement,
        inherited: [CGPoint]
    ) -> [CGPoint] {
        guard m.status == "measured", inherited.count == 4 else { return [] }
        let primary = m.components.filter { c in
            let overlap = max(0, min(c.bounds.maxX, m.rect.maxX) - max(c.bounds.minX, m.rect.minX))
            return Double(c.ownedPixels) >= max(2, min(8, Double(c.pixels) * 0.04)) &&
                overlap >= min(c.bounds.width, m.rect.width) * 0.4 && c.insidePixels >= 2
        }
        guard !primary.isEmpty else { return [] }
        var result: [CGPoint] = []
        for c in m.components where c.foreignPixels == 0 && c.insidePixels >= 2 {
            let overlap = max(0, min(c.bounds.maxX, m.rect.maxX) - max(c.bounds.minX, m.rect.minX))
            guard overlap >= min(c.bounds.width, m.rect.width) * 0.4,
                  primary.contains(where: {
                      NativeOCRSourceComponentMeasurements.colourDistance(c.colour, $0.colour) <= 40
                  }) else { continue }
            // ONLY change relative to legacy visibleForeground: clip an already
            // accepted full component to the old preferred crop, not incoming.
            // Preserve 1/2-point hulls (thin marks) as well as polygon hulls.
            result += NativeOCRSourceComponentBounds.clip(c.hull.map(m.restore), to: inherited)
        }
        return result
    }
}
