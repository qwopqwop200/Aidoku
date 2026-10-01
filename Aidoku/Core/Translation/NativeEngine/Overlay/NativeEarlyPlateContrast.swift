import CoreGraphics
import Foundation

/// The first source-plate contrast pass, before opaque caption packing.
/// It consumes the exact paint order and adds a backing only after its ink proof.
enum NativeEarlyPlateContrast {
    struct Decision {
        let id: String
        let before: [Double]
        let after: [Double]
        let surfaces: [[Double]]
        let minimumBefore: Double
        let minimumAfter: Double
        let target: Double
    }
    struct Result {
        var records: [NativePanelGeometry.Record]
        var decisions: [Decision]
    }
    static func apply(_ input: [NativePanelGeometry.Record], opacity: Double, itemCount: Int) -> Result {
        guard opacity == 1, itemCount <= 256 else { return Result(records: input, decisions: []) }
        var records = input
        var layers = input.flatMap { record in record.panels.map { panel in
            NativePanelGeometry.Layer(rect: panel.rect, color: panel.background,
                coverage: panel.coverage.isEmpty ? [panel.rect] : panel.coverage)
        } } + input.flatMap { record in record.backings.map {
            NativePanelGeometry.Layer(rect: $0.frame, color: $0.color, coverage: $0.coverage)
        } }
        var decisions: [Decision] = []
        for index in records.indices {
            let record = records[index]
            guard record.sourceColorEligible, !record.sourceTextOnly, NativePanelGeometry.valid(record.ink),
                  record.foreground.count == 3, record.foreground.allSatisfy(\.isFinite),
                  let owner = record.panels.lastIndex(where: { !$0.sourceErasure }) else { continue }
            var surfaces = NativePanelGeometry.visiblePanelColors(record.ink, layers: layers, fallback: record.fallbackBackground)
            guard !surfaces.isEmpty else { continue }
            func contrast(_ rgb: [Double]) -> Double {
                surfaces.map { NativeTranslationSourceStylePostPolish.sourceColorContrast(rgb, panel: $0) }.min() ?? 0
            }
            let before = contrast(record.foreground)
            let target = record.font >= 18 && record.foreground.max()! - record.foreground.min()! >= 40 &&
                surfaces.allSatisfy { NativeTranslationSourceStylePostPolish.luminance(record.foreground) <
                    NativeTranslationSourceStylePostPolish.luminance($0) } ? 3.0 : 4.5
            if before >= target { continue }
            if surfaces.contains(where: { $0 != record.fallbackBackground }) {
                let neighbors = records.indices.filter { $0 != index }.map { records[$0].ink }.filter(NativePanelGeometry.valid)
                if let backing = NativePanelGeometry.textBackingRect(record.ink, panel: record.panels[owner].rect, neighbors: neighbors) {
                    let layer = NativePanelGeometry.Backing(frame: record.panels[owner].rect,
                        coverage: [backing], color: record.panels[owner].background)
                    records[index].backings.append(layer)
                    layers.append(.init(rect: layer.frame, color: record.fallbackBackground, coverage: layer.coverage))
                    surfaces = [record.fallbackBackground]
                }
            }
            let adjusted = NativeTranslationSourceStylePostPolish.adjustInkForContrast(record.foreground, contrast: contrast, target: target)
            guard contrast(adjusted) >= contrast(record.foreground) else { continue }
            records[index].foreground = adjusted
            decisions.append(Decision(id: record.id, before: record.foreground, after: adjusted,
                surfaces: surfaces, minimumBefore: before, minimumAfter: contrast(adjusted), target: target))
        }
        return Result(records: records, decisions: decisions)
    }
}
