import CoreGraphics
import Foundation

/// Frozen skipped-caption bridge7849–7892. All intersections are retained
/// before the original solid-panel helper forms their bounded envelope.
enum NativeSkippedCaptionBridge {
    struct Source {
        var bounds: [CGRect]
        var font: Double
        var sourceFont: Double?
        var priorPadding: Double = 0
        var vertical = false
        var oversizedUnrestored = false
    }

    static func required(_ sources: [Source], inks: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for source in sources where !source.oversizedUnrestored {
            let font = source.font.isFinite && source.font != 0 ? source.font : 10
            let padding = max(source.priorPadding, max(3, min(6, font * 0.3)))
            let sourceFont = source.sourceFont.flatMap { $0.isFinite ? $0 : nil } ?? padding
            let cross = max(padding, min(16, sourceFont))
            let px = (source.vertical ? cross : padding) + 0.04
            let py = (source.vertical ? padding : cross) + 0.04
            for bounds in source.bounds where valid(bounds) {
                result.append(CGRect(x: bounds.minX - px, y: bounds.minY - py,
                    width: bounds.width + 2 * px, height: bounds.height + 2 * py))
            }
        }
        result += inks.filter(valid).map { CGRect(x: $0.minX - 3, y: $0.minY - 3,
            width: $0.width + 6, height: $0.height + 6) }
        return result
    }

    /// Nil preserves the layer when there are no intersections or the frozen
    /// pre-merge 512-piece cap is exceeded. Existing clipping stays effective.
    static func coverage(layer: CGRect, original: [CGRect], required: [CGRect]) -> [CGRect]? {
        guard valid(layer) else { return nil }
        var pieces: [CGRect] = []
        for requirement in required {
            for old in original {
                let left = max(requirement.minX, old.minX, layer.minX)
                let top = max(requirement.minY, old.minY, layer.minY)
                let right = min(requirement.maxX, old.maxX, layer.maxX)
                let bottom = min(requirement.maxY, old.maxY, layer.maxY)
                if right > left, bottom > top {
                    pieces.append(CGRect(x: left, y: top, width: right-left, height: bottom-top))
                }
            }
        }
        guard !pieces.isEmpty, pieces.count <= 512 else { return nil }
        return NativePanelGeometry.solidPanelCoverage(pieces)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
}
