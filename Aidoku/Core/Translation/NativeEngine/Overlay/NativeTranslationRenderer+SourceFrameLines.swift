import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    static func restoreSourceFrameLines(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
        layout: NativeTranslationLayout, source: CGImage?, settings: IPhoneOverlaySettings) throws {
        guard settings.renderedBackgroundOpacity == 1, layout.items.count <= 256, let source,
              valid(layout.sourceRect) else { return }
        let reader = NativeSourcePixelReader(image: source)
        defer { reader.release() }
        var budget = 3_000_000
        let textBoxes = cards.filter { !gloss.hiddenIDs.contains($0.item.id) && !gloss.removedLayerIDs.contains($0.item.id) }
            .flatMap { cardPageLineRects($0) }
        func layer(panel: CGRect, item: NativeTranslationLayoutItem, frame: CGRect) throws -> (CGImage, Int)? {
            try Task.checkCancellation()
            let sourceBox = pageRect(item.sourceBounds, frame: frame) ?? panel
            guard let crop = NativeSourceFrameLines.crop(panel: panel, source: sourceBox, frame: frame,
                imageSize: CGSize(width: source.width, height: source.height), budget: &budget) else { return nil }
            let rgba = try reader.read(x: Double(crop.source.minX), y: Double(crop.source.minY),
                    sourceWidth: Double(crop.source.width), sourceHeight: Double(crop.source.height),
                    width: crop.width, height: crop.height)
            guard let restored = NativeSourceFrameLines.restore(crop: crop, rgba: rgba, panel: panel, source: sourceBox, textBoxes: textBoxes)
            else { return nil }
            var pixels = NativeRestorationPixels(width: restored.width, height: restored.height)
            pixels.rgba = restored.rgba
            return pixels.image().map { ($0, restored.painted) }
        }
        for index in cards.indices where !gloss.removedLayerIDs.contains(cards[index].item.id) {
            let item = cards[index].item
            let frame = cards[index].cleanupSourceFrame ?? layout.sourceRect
            for rect in columnSourceErasureRects(cards[index], settings: settings) {
                if let (image, _) = try layer(panel: rect, item: item, frame: frame) {
                    cards[index].columnFrameImages.append(.init(image: image, rect: rect))
                }
            }
            guard !cards[index].rotatesSourcePanels else { continue }
            for p in cards[index].sourcePanels.indices {
                let panel = cards[index].sourcePanels[p]
                guard !panel.rotated else { continue }
                if let (image, count) = try layer(panel: panel.rect, item: item, frame: frame) {
                    cards[index].sourcePanels[p].sourceFrameImage = image
                    cards[index].sourcePanels[p].sourceFrameLineCount = count
                }
            }
        }
    }
}
