import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Runs after early margin trials and compacted plates, before packing.
    @discardableResult
    static func applyEarlyPlateContrast(cards: inout [Card], layout: NativeTranslationLayout,
        restoration: NativeTranslationRestoration.Result, settings: IPhoneOverlaySettings) -> [NativeEarlyPlateContrast.Decision] {
        guard settings.preserveSourceBackgroundColor, settings.renderedBackgroundOpacity == 1,
              layout.items.count <= 256 else { return [] }
        let records = cards.map { card -> NativePanelGeometry.Record in
            let item = card.item, ink = rgb(card.style.foreground) ?? [17,18,23]
            let sample = restoration.appearances[item.id]?.sourceSample ?? [:]
            let palette = NativeTranslationSourceStylePostPolish.captionPalette(sample: sample, ink: ink,
                preserveText: settings.preserveSourceTextColor, displayInk: NativeSourceColorSampler.displayedInk(sample))
            var record = NativePanelGeometry.Record(id: item.id, ink: cardInkRect(card), source: nil, sources: [],
                sourceColorEligible: item.sourceColorEligible, sourceTextOnly: item.sourceTextOnly,
                balancedColumn: item.balancedColumn, vertical: item.vertical, rotation: Double(item.rotation),
                font: Double(card.finalFontSize), sourceFont: nil, sourceVertical: item.sourceVertical, inkPadding: 0,
                foreground: ink, fallbackBackground: palette.background, panels: card.sourcePanels)
            record.backings = card.backings
            return record
        }
        let result = NativeEarlyPlateContrast.apply(records, opacity: settings.renderedBackgroundOpacity,
            itemCount: layout.items.count)
        let changed = Set(result.decisions.map(\.id))
        for record in result.records {
            guard let index = cards.firstIndex(where: { $0.item.id == record.id }) else { continue }
            cards[index].backings = record.backings
            if changed.contains(record.id) {
                cards[index].style.foreground = color(record.foreground.map { CGFloat($0) })
                cards[index].typography = remeasureTypography(cards[index])
            }
        }
        return result.decisions
    }
}
