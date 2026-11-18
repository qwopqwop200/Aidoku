import CoreGraphics
import Foundation

/// Recovers a missing OCR corner only when both ends of one staggered quote
/// are measured in the source pixels. Style and proximity alone are insufficient.
enum ReaderTranslationStaggeredQuoteMerger {
    static func apply(_ input: [ReaderTranslationRegion], image: CGImage,
                      enclosure: ReaderTranslationEnclosedBackground.ComponentMap) -> [ReaderTranslationRegion] {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * width, y: r.minY * height, width: r.width * width, height: r.height * height)
        }
        func normalized(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX / width, y: r.minY / height, width: r.width / width, height: r.height / height)
        }
        let columns = input.filter { $0.sourceOrientation == .vertical && $0.sourceSingleVerticalColumn == true }
            .sorted { $0.rect.midX > $1.rect.midX }
        var replacements: [String: ReaderTranslationRegion] = [:], consumed = Set<String>()
        for (right, left) in zip(columns, columns.dropFirst()) {
            guard !consumed.contains(right.id), !consumed.contains(left.id), right.translation == nil, left.translation == nil else { continue }
            let first = right.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let last = left.source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard first.first == "「", !first.dropFirst().contains(where: { "「」『』“”".contains($0) }),
                  !last.contains(where: { "「」『』“”".contains($0) }),
                  first.filter({ $0.isLetter }).count >= 3, last.filter({ $0.isLetter }).count >= 3 else { continue }
            let a = pixels(right.rect), b = pixels(left.rect), font = min(a.width, b.width)
            let gap = a.minX - b.maxX, overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            let union = right.rect.union(left.rect)
            guard font >= 12, max(a.width, b.width) <= font * 1.35,
                  min(a.height, b.height) >= font * 3,
                  gap >= 0, gap <= font * 0.8,
                  b.minY > a.minY + font * 0.75, b.minY - a.minY <= font * 2.1,
                  abs(a.maxY - b.maxY) <= font * 1.1,
                  overlap >= min(a.height, b.height) * 0.7,
                  !input.contains(where: { $0.id != right.id && $0.id != left.id && $0.rect.intersects(union) }),
                  !enclosure.separates(a, b),
                  let inkA = ReaderTranslationBalloonMerger.outlinedInk(in: image, rect: a),
                  let inkB = ReaderTranslationBalloonMerger.outlinedInk(in: image, rect: b),
                  max(abs(inkA.0 - inkB.0), abs(inkA.1 - inkB.1), abs(inkA.2 - inkB.2)) <= 25,
                  max(inkA.0, inkA.1, inkA.2) - min(inkA.0, inkA.1, inkA.2) >= 45,
                  let opening = corner(in: image, column: a, ink: inkA, opening: true),
                  let closing = corner(in: image, column: b, ink: inkB, opening: false),
                  corner(in: image, column: a, ink: inkA, opening: false) == nil,
                  corner(in: image, column: b, ink: inkB, opening: true) == nil else { continue }
            let anchor = input.first { $0.id == right.id || $0.id == left.id }!
            let box = union.union(normalized(opening)).union(normalized(closing))
            var joined = ReaderTranslationRegion(id: anchor.id, rect: box, source: right.source + left.source + "」",
                confidence: min(right.confidence, left.confidence), sourceImageAspectRatio: Double(width / height),
                sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
            joined.unitMemberRects = [right.rect, left.rect]
            joined.auxiliaryInkRects = right.auxiliaryInkRects + left.auxiliaryInkRects + [normalized(opening), normalized(closing)]
            joined.auxiliaryInkPolygons = right.auxiliaryInkPolygons + left.auxiliaryInkPolygons
            joined.detectorSeedEvidence = NativeOCRDetectorSeedEvidence.preservingUnion([right.detectorSeedEvidence, left.detectorSeedEvidence])
            joined.acceptedSource = .union([right.acceptedSource, left.acceptedSource])
            joined.isRecoveredLine = right.isRecoveredLine || left.isRecoveredLine
            joined.polygon = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                              CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            replacements[anchor.id] = joined
            consumed.formUnion([right.id, left.id])
        }
        return input.compactMap { replacements[$0.id] ?? (consumed.contains($0.id) ? nil : $0) }
    }

    /// Scans only one end band, at native resolution; no page-wide CC search.
    static func corner(in image: CGImage, column: CGRect, ink: (Double, Double, Double), opening: Bool) -> CGRect? {
        let font = column.width
        let band = CGRect(x: column.minX - font * 0.08,
            y: opening ? column.minY - font * 0.15 : column.maxY - font * 0.45,
            width: font * 1.16, height: font * 0.95).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard band.width >= 12, band.height >= 8, band.width * band.height <= 65536,
              let crop = image.cropping(to: band) else { return nil }
        let w = crop.width, h = crop.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        func inkPixel(_ x: Int, _ y: Int) -> Bool {
            let p = (y * w + x) * 4
            let r = Double(rgba[p]), g = Double(rgba[p + 1]), b = Double(rgba[p + 2])
            let low = min(r, g, b), high = max(r, g, b), chroma = high - low
            guard chroma >= 65, high >= 85 else { return false }
            return max(abs((r - low) * 255 / chroma - ink.0), abs((g - low) * 255 / chroma - ink.1),
                       abs((b - low) * 255 / chroma - ink.2)) <= 32
        }
        var seen = [Bool](repeating: false, count: w * h), matches: [CGRect] = []
        for y in 0..<h { for x in 0..<w {
            guard !seen[y * w + x], inkPixel(x, y) else { continue }
            var stack = [y * w + x], points: [(Int, Int)] = []
            var x0 = x, x1 = x, y0 = y, y1 = y
            seen[y * w + x] = true
            while let p = stack.popLast() {
                let px = p % w, py = p / w
                points.append((px, py)); x0 = min(x0, px); x1 = max(x1, px); y0 = min(y0, py); y1 = max(y1, py)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = px + dx, ny = py + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h, !seen[ny * w + nx], inkPixel(nx, ny) else { continue }
                    seen[ny * w + nx] = true; stack.append(ny * w + nx)
                }
            }
            let cw = x1 - x0 + 1, ch = y1 - y0 + 1
            let density = Double(points.count) / Double(cw * ch)
            guard x0 > 0, y0 > 0, x1 < w - 1, y1 < h - 1,
                  CGFloat(cw) >= font * 0.3, CGFloat(cw) <= font * 0.85,
                  CGFloat(ch) >= font * 0.08, CGFloat(ch) <= font * 0.4,
                  cw >= ch * 2, density >= 0.2, density <= 0.72 else { continue }
            // An L has a full horizontal rail plus one short vertical leg.
            let rail = max(1, ch / 3), leg = max(1, cw / 5)
            let horizontal = points.filter { opening ? $0.1 < y0 + rail : $0.1 > y1 - rail }.count
            let vertical = points.filter { opening ? $0.0 > x1 - leg : $0.0 < x0 + leg }.count
            let emptyCorner = points.filter {
                (opening ? $0.0 < x0 + cw / 2 : $0.0 > x0 + cw / 2) &&
                (opening ? $0.1 > y0 + ch / 2 : $0.1 < y0 + ch / 2)
            }.count
            guard horizontal >= cw * rail / 2, vertical >= ch * leg / 3,
                  emptyCorner <= max(1, points.count / 12) else { continue }
            matches.append(CGRect(x: band.minX + CGFloat(x0), y: band.minY + CGFloat(y0), width: CGFloat(cw), height: CGFloat(ch)))
        } }
        return matches.count == 1 ? matches[0] : nil
    }
}
