import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    static func adjustInitialJoinedUnits(layout: NativeTranslationLayout,
        restoration: NativeTranslationRestoration.Result) -> NativeTranslationLayout {
        let entries = layout.items.map { item in
            NativeInitialJoinedUnit.Entry(rect: item.keptLettering && !valid(item.rect) ? .null : item.rect, font: Double(item.fontSize),
                frame: item.sourceFrame.map(Double.init), source: item.sourceBounds.map(Double.init),
                interior: item.balloonInterior?.rect.map(Double.init) ?? [], spans: item.balloonInterior?.spans ?? [],
                joined: joinedUnitMembers(item) != nil, residue: restoration.unitResidueRiskIDs.contains(item.id),
                rotated: item.rotation != 0, vertical: item.vertical, kept: item.keptLettering)
        }
        let result = NativeInitialJoinedUnit.fit(entries)
        var items = layout.items
        for i in items.indices {
            guard let planned = result[i].planned else { continue }
            items[i].unitPlannedCard = [planned.origin.x, planned.origin.y, planned.size.width, planned.size.height]
            items[i].x = result[i].rect.origin.x; items[i].y = result[i].rect.origin.y
            items[i].width = result[i].rect.size.width; items[i].height = result[i].rect.size.height
        }
        return .init(imageSize: layout.imageSize, sourceRect: layout.sourceRect, viewport: layout.viewport, items: items,
            readableRecoveryRemaining: layout.readableRecoveryRemaining, sourceObjectFit: layout.sourceObjectFit)
    }
}
