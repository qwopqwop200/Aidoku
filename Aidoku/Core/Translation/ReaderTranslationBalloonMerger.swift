import CoreGraphics
import Foundation

/// Joins close, similarly sized vertical columns only when their surrounding
/// white background belongs to the same bounded connected image component.
enum ReaderTranslationBalloonMerger {
    static func apply(_ regions: [ReaderTranslationRegion], image: CGImage) -> [ReaderTranslationRegion] {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let candidates = regions.filter { $0.sourceOrientation == .vertical && $0.source.count >= 2 &&
            $0.rect.height * height >= $0.rect.width * width * 1.5 }
        guard candidates.count >= 2 else { return regions }
        var groups = ReaderTranslationEnclosedBackground.enclosedRegionGroups(in: image,
            candidateInputs: candidates.map { .init(id: $0.id, text: $0.source,
                rect: CGRect(x: $0.rect.minX * width, y: $0.rect.minY * height,
                             width: $0.rect.width * width, height: $0.rect.height * height)) },
            coordinateSize: CGSize(width: width, height: height))
        // Closed-component evidence is strongest. Only use the bridge fallback
        // for a remaining single column immediately beside an existing block.
        let claimed = Set(groups.filter { $0.count >= 2 }.flatMap { $0 })
        let ordered = candidates.filter { !claimed.contains($0.id) }.sorted { $0.rect.midX > $1.rect.midX }
        var bridgeClaimed = Set<String>()
        for (right, left) in zip(ordered, ordered.dropFirst()) {
            guard !bridgeClaimed.contains(right.id), !bridgeClaimed.contains(left.id),
                  (right.sourceSingleVerticalColumn == false && left.sourceSingleVerticalColumn == true) ||
                    (right.sourceSingleVerticalColumn == true && left.sourceSingleVerticalColumn == false),
                  min(right.source.count, left.source.count) >= 3 else { continue }
            let small = min(right.rect.width, left.rect.width), large = max(right.rect.width, left.rect.width)
            let gap = right.rect.minX - left.rect.maxX
            let overlap = min(right.rect.maxY, left.rect.maxY) - max(right.rect.minY, left.rect.minY)
            let box = right.rect.union(left.rect)
            guard large >= small * 1.8, large <= small * 3.5, gap >= -small * 0.2, gap <= small * 0.65,
                  overlap >= min(right.rect.height, left.rect.height) * 0.5,
                  !regions.contains(where: { $0.id != right.id && $0.id != left.id && $0.rect.intersects(box) }) else { continue }
            func pixels(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height) }
            if ReaderTranslationEnclosedBackground.hasClearVerticalBridge(in: image, left: pixels(left.rect), right: pixels(right.rect)) {
                groups.append([right.id, left.id]); bridgeClaimed.formUnion([right.id, left.id])
            }
        }
        var replacements: [String: ReaderTranslationRegion] = [:], removed = Set<String>()
        for ids in groups where (2...4).contains(ids.count) {
            let members = candidates.filter { ids.contains($0.id) }.sorted { $0.rect.midX > $1.rect.midX }
            guard let first = members.first, let smallest = members.map({ $0.rect.width }).min(), smallest > 0,
                  members.allSatisfy({ $0.rect.width <= smallest * ($0.sourceSingleVerticalColumn == false ? 3.5 : 1.6) }) else { continue }
            var valid = true
            for (right, left) in zip(members, members.dropFirst()) {
                let gap = right.rect.minX - left.rect.maxX
                let overlap = min(right.rect.maxY, left.rect.maxY) - max(right.rect.minY, left.rect.minY)
                if gap < -smallest * 0.2 || gap > smallest * 1.8 || overlap < min(right.rect.height, left.rect.height) * 0.5 { valid = false; break }
            }
            guard valid else { continue }
            let box = members.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            guard box.width <= smallest * 7 else { continue }
            // Never jump over a column that the connected-background evidence
            // did not include. Lettering or an overlapping balloon can split
            // the white component even though the outer rectangle looks close.
            guard !regions.contains(where: { !ids.contains($0.id) && $0.rect.intersects(box) }) else { continue }
            let anchor = regions.first { ids.contains($0.id) }!
            var joined = ReaderTranslationRegion(id: anchor.id, rect: box,
                source: members.map(\.source).joined(), confidence: members.map(\.confidence).min() ?? 1,
                sourceImageAspectRatio: Double(width / height), sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false)
            joined.polygon = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                              CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            replacements[anchor.id] = joined
            removed.formUnion(ids.filter { $0 != anchor.id })
        }
        return regions.compactMap { removed.contains($0.id) ? nil : replacements[$0.id] ?? $0 }
    }

}
