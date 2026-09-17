import CoreGraphics
import Foundation

/// Joins close, similarly sized vertical columns only when their surrounding
/// white background belongs to the same bounded connected image component.
enum ReaderTranslationBalloonMerger {
    struct SourceLine {
        let polygon: [CGPoint]
        let text: String
        let orientation: BrowserOCRSourceOrientation
    }

    static func apply(_ regions: [ReaderTranslationRegion], image: CGImage, sourceLines: [SourceLine] = []) -> [ReaderTranslationRegion] {
        let regions = joinStackedCaptionFragments(regions, image: image, sourceLines: sourceLines)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let candidates = regions.filter { $0.sourceOrientation == .vertical && $0.source.count >= 2 &&
            $0.rect.height * height >= $0.rect.width * width * 1.5 }
        guard candidates.count >= 2 else { return regions }
        var groups = ReaderTranslationEnclosedBackground.enclosedRegionGroups(in: image,
            candidateInputs: candidates.map { .init(id: $0.id, text: $0.source,
                rect: CGRect(x: $0.rect.minX * width, y: $0.rect.minY * height,
                             width: $0.rect.width * width, height: $0.rect.height * height)) },
            coordinateSize: CGSize(width: width, height: height))
        // Closed-component evidence is strongest. Translucent balloons can
        // expose artwork behind one column and break that white component.
        // A clear gutter can still connect aligned, similarly sized columns.
        let enclosedCandidates = Set(groups.flatMap { $0 })
        // A connected component may span multiple balloon lobes and fail the
        // geometry checks below. Do not reserve its columns before validation:
        // doing so prevents a valid neighbouring pair from using the bridge.
        let ordered = candidates.sorted { $0.rect.midX > $1.rect.midX }
        var bridgeClaimed = Set<String>()
        for (right, left) in zip(ordered, ordered.dropFirst()) {
            guard !bridgeClaimed.contains(right.id), !bridgeClaimed.contains(left.id),
                  min(right.source.count, left.source.count) >= 3 else { continue }
            let small = min(right.rect.width, left.rect.width), large = max(right.rect.width, left.rect.width)
            let gap = right.rect.minX - left.rect.maxX
            let overlap = min(right.rect.maxY, left.rect.maxY) - max(right.rect.minY, left.rect.minY)
            let box = right.rect.union(left.rect)
            let mixedBlock = ((right.sourceSingleVerticalColumn == false && left.sourceSingleVerticalColumn == true) ||
                (right.sourceSingleVerticalColumn == true && left.sourceSingleVerticalColumn == false)) &&
                large >= small * 1.8 && large <= small * 3.5 && gap <= small * 0.65 &&
                overlap >= min(right.rect.height, left.rect.height) * 0.5
            let alignedColumns = right.sourceSingleVerticalColumn != false && left.sourceSingleVerticalColumn != false &&
                (enclosedCandidates.contains(right.id) || enclosedCandidates.contains(left.id)) &&
                large <= small * 1.6 && gap <= small * 1.2 &&
                // Leading vertical ellipses can be omitted by recognition,
                // leaving the first lexical column one or two glyphs lower.
                abs(right.rect.minY - left.rect.minY) * height <= small * width * 1.75 &&
                overlap >= min(right.rect.height, left.rect.height) * 0.75
            guard gap >= -small * 0.2, mixedBlock || alignedColumns,
                  !regions.contains(where: { $0.id != right.id && $0.id != left.id && $0.rect.intersects(box) }) else { continue }
            func pixels(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height) }
            if ReaderTranslationEnclosedBackground.hasClearVerticalBridge(in: image, left: pixels(left.rect), right: pixels(right.rect)) {
                groups.append([right.id, left.id]); bridgeClaimed.formUnion([right.id, left.id])
            }
        }
        var replacements: [String: ReaderTranslationRegion] = [:], removed = Set<String>()
        var consumed = Set<String>()
        for ids in groups where (2...4).contains(ids.count) {
            guard consumed.isDisjoint(with: ids) else { continue }
            let members = candidates.filter { ids.contains($0.id) }.sorted { $0.rect.midX > $1.rect.midX }
            guard let first = members.first, let smallest = members.map({ $0.rect.width }).min(), smallest > 0,
                  members.allSatisfy({ $0.rect.width <= smallest * ($0.sourceSingleVerticalColumn == false ? 3.5 : 1.6) }) else { continue }
            var valid = true
            for (right, left) in zip(members, members.dropFirst()) {
                func pixels(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height) }
                if separatesVerticalUtterances(right.source, box: pixels(right.rect), left.source, box: pixels(left.rect)) ||
                    differentOutlinedInk(in: image, first: pixels(right.rect), second: pixels(left.rect)) { valid = false; break }
                let gap = right.rect.minX - left.rect.maxX
                let overlap = min(right.rect.maxY, left.rect.maxY) - max(right.rect.minY, left.rect.minY)
                if gap < -smallest * 0.2 || gap > smallest * 1.8 || overlap < min(right.rect.height, left.rect.height) * 0.5 { valid = false; break }
                // A connected white component can contain several balloon lobes.
                // Across a wide column gutter, require a clear bridge over the
                // shared text height; a narrow neck is not one text block.
                if gap > smallest * 0.6 && !ReaderTranslationEnclosedBackground.hasClearVerticalBridge(
                    in: image, left: pixels(left.rect), right: pixels(right.rect)
                ) { valid = false; break }
            }
            guard valid else { continue }
            let box = members.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            guard box.width <= smallest * 7 else { continue }
            // Never jump over a column that the connected-background evidence
            // did not include. Lettering or an overlapping balloon can split
            // the white component even though the outer rectangle looks close.
            guard !regions.contains(where: { !ids.contains($0.id) && $0.rect.intersects(box) }) else { continue }
            consumed.formUnion(ids)
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

    /// A wrapped caption can end with a centered/edge-aligned single column
    /// below its multi-column head. This is not an adjacent-column merge.
    private static func joinStackedCaptionFragments(_ input: [ReaderTranslationRegion], image: CGImage, sourceLines: [SourceLine]) -> [ReaderTranslationRegion] {
        var result = input
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ r: CGRect) -> CGRect { CGRect(x: r.minX * width, y: r.minY * height, width: r.width * width, height: r.height * height) }
        for head in input where head.sourceOrientation == .vertical && head.sourceSingleVerticalColumn == false {
            guard let index = result.firstIndex(where: { $0.id == head.id }) else { continue }
            let tails = result.filter { $0.id != head.id && $0.sourceOrientation == .vertical && $0.sourceSingleVerticalColumn == true }
                .sorted { $0.rect.minY < $1.rect.minY }
            for tail in tails {
                let top = pixels(result[index].rect), bottom = pixels(tail.rect), font = bottom.width
                let gap = bottom.minY - top.maxY
                let next = tail.source.trimmingCharacters(in: .whitespacesAndNewlines)
                guard font > 0, next.count >= 2, !next.hasPrefix("「"), !next.hasPrefix("『"),
                      top.width >= font * 1.4, top.width <= font * 3.5,
                      bottom.minY > top.minY, bottom.maxY > top.maxY,
                      (gap >= -font * 0.5 || continuesLastSourceColumn(head: result[index], tail: tail,
                          top: top, bottom: bottom, sourceLines: sourceLines)), gap <= font * 1.1,
                      bottom.minX >= top.minX - font * 0.2, bottom.maxX <= top.maxX + font * 0.2,
                      matchingOutlinedInk(in: image, first: top, second: bottom) else { continue }
                let union = result[index].rect.union(tail.rect)
                guard !result.contains(where: { $0.id != head.id && $0.id != tail.id && $0.rect.intersects(union) }) else { continue }
                var joined = ReaderTranslationRegion(id: head.id, rect: union, source: result[index].source + tail.source,
                    confidence: min(result[index].confidence, tail.confidence), sourceImageAspectRatio: Double(width / height),
                    sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
                joined.polygon = [CGPoint(x: union.minX, y: union.minY), CGPoint(x: union.maxX, y: union.minY),
                                  CGPoint(x: union.maxX, y: union.maxY), CGPoint(x: union.minX, y: union.maxY)]
                result[index] = joined
                // Rebuild indices after removal by id; a head may follow its tail in detector order.
                return joinStackedCaptionFragments(result.filter { $0.id != tail.id }, image: image, sourceLines: sourceLines)
            }
        }
        return result
    }

    // A short final column can end above the other columns in the same block.
    // Its continuation then overlaps the block's bounding box. Use the original
    // last text line, not that enclosing rectangle, to establish adjacency/order.
    private static func continuesLastSourceColumn(
        head: ReaderTranslationRegion, tail: ReaderTranslationRegion,
        top: CGRect, bottom: CGRect, sourceLines: [SourceLine]
    ) -> Bool {
        let font = bottom.width
        guard font > 0, abs(bottom.minX - top.minX) <= font * 0.2,
              bottom.maxY > top.maxY, !head.source.hasSuffix("」"), !head.source.hasSuffix("』") else { return false }
        let matches = sourceLines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.orientation == .vertical, text.count >= 2, head.source.hasSuffix(text),
                  !text.hasSuffix("」"), !text.hasSuffix("』"), !line.polygon.isEmpty else { return false }
            let xs = line.polygon.map(\.x), ys = line.polygon.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            let small = min(font, box.width)
            guard small > 0, max(font, box.width) <= small * 1.6,
                  abs(box.midX - bottom.midX) <= small * 0.25,
                  min(box.maxX, bottom.maxX) - max(box.minX, bottom.minX) >= small * 0.8,
                  box.minY >= top.minY - small * 0.2,
                  box.maxY <= bottom.minY + small * 0.15,
                  bottom.minY - box.maxY <= small * 1.1 else { return false }
            return true
        }
        return matches.count == 1
    }

    /// A fresh opening quote across a visible column gutter marks a new
    /// utterance, even when OCR missed the previous utterance's closing quote.
    /// Tight/nested quotations and an ordinary wrapped continuation are unaffected.
    static func separatesVerticalUtterances(_ a: String, box aBox: CGRect, _ b: String, box bBox: CGRect) -> Bool {
        let rightFirst = aBox.midX > bBox.midX
        let right = rightFirst ? aBox : bBox, left = rightFirst ? bBox : aBox
        let previous = (rightFirst ? a : b).trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (rightFirst ? b : a).trimmingCharacters(in: .whitespacesAndNewlines)
        let quoteBoundary = next.first.map { "「『“".contains($0) } == true ||
            previous.last.map { "」』”".contains($0) } == true
        let font = min(right.width, left.width)
        guard font > 0, next.count >= 3, quoteBoundary,
              right.minX - left.maxX >= font * 0.35,
              abs(right.minY - left.minY) <= font * 0.75,
              min(right.maxY, left.maxY) - max(right.minY, left.minY) >= font * 2 else { return false }
        return true
    }

    // Coloured CG captions may sit directly on artwork. Sample saturated strokes
    // next to near-white outline/fill pixels, not the dominant background colour.
    static func matchingOutlinedInk(in image: CGImage, first: CGRect, second: CGRect) -> Bool {
        guard let a = outlinedInk(in: image, rect: first), let b = outlinedInk(in: image, rect: second) else { return false }
        return abs(a.0 - b.0) <= 35 && abs(a.1 - b.1) <= 35 && abs(a.2 - b.2) <= 35
    }

    static func differentOutlinedInk(in image: CGImage, first: CGRect, second: CGRect) -> Bool {
        guard let a = outlinedInk(in: image, rect: first), let b = outlinedInk(in: image, rect: second) else { return false }
        return max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) >= 70
    }

    static func outlinedInk(in image: CGImage, rect: CGRect) -> (Double, Double, Double)? {
            guard let crop = image.cropping(to: rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) else { return nil }
            let w = min(96, crop.width), h = min(384, crop.height)
            guard w >= 4, h >= 16 else { return nil }
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            var bins: [Int: (count: Int, r: Int, g: Int, b: Int, rows: Set<Int>)] = [:]
            let offsets: [Int] = [-4, 4, -w * 4, w * 4]
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = (y * w + x) * 4
                    let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                    guard max(r, g, b) >= 110, max(r, g, b) - min(r, g, b) >= 65 else { continue }
                    var whiteNeighbour = false
                    for offset in offsets {
                        let neighbour = i + offset
                        if rgba[neighbour] >= 200 && rgba[neighbour + 1] >= 200 && rgba[neighbour + 2] >= 200 {
                            whiteNeighbour = true
                            break
                        }
                    }
                    guard whiteNeighbour else { continue }
                    let key = (r / 64) * 16 + (g / 64) * 4 + b / 64
                    var bin = bins[key] ?? (0, 0, 0, 0, [])
                    bin.count += 1; bin.r += r; bin.g += g; bin.b += b; bin.rows.insert(y * 12 / h)
                    bins[key] = bin
                }
            }
            guard let best = bins.values.max(by: { $0.count < $1.count }), best.count >= 24, best.rows.count >= 6 else { return nil }
            // White outline antialiasing changes brightness/saturation, not the caption hue.
            let r = Double(best.r) / Double(best.count), g = Double(best.g) / Double(best.count), b = Double(best.b) / Double(best.count)
            let low = min(r, g, b), chroma = max(r, g, b) - low
            guard chroma >= 65 else { return nil }
            return ((r - low) * 255 / chroma, (g - low) * 255 / chroma, (b - low) * 255 / chroma)
    }

}
