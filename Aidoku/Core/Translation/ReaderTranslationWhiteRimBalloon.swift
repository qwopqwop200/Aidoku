import CoreGraphics
import Foundation

/// Geometric fallback: a connected white rim enclosing the owned OCR boxes.
/// Colour/transparency of the hole is deliberately not inferred as clean paper.
enum ReaderTranslationWhiteRimBalloon {
    struct Result {
        let bounds: CGRect
        let center: CGPoint
        let spans: [Double]
        let holeCount: Int
    }
    static func inspect(image: CGImage, owned: [CGRect], padding: CGFloat, searchBounds: CGRect? = nil, pixelBudget: inout Int)
        -> Result?
    {
        guard !Task.isCancelled, owned.count <= 32, let first = owned.first, padding.isFinite,
            padding > 0,
            owned.allSatisfy({
                $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite
                    && $0.width > 0 && $0.height > 0
            })
        else { return nil }
        let union = owned.dropFirst().reduce(first) { $0.union($1) }
        // Search context only extends observation. Every owned box must still
        // independently fit the enclosed hole; a neighbour never grants ownership.
        if let searchBounds {
            guard [searchBounds.minX, searchBounds.minY, searchBounds.width, searchBounds.height].allSatisfy(\.isFinite),
                searchBounds.width > 0, searchBounds.height > 0 else { return nil }
        }
        let search = searchBounds.map { union.union($0) } ?? union
        let roi = search.insetBy(dx: -padding, dy: -padding).integral.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard roi.width > 0, roi.height > 0, roi.width <= 1200, roi.height <= 1200 else { return nil }
        let w = Int(roi.width)
        let h = Int(roi.height)
        let n = w * h
        guard n <= pixelBudget,
            owned.reduce(CGFloat(0), { $0 + $1.width * $1.height }) <= CGFloat(n) * 2
        else { return nil }
        pixelBudget -= n
        guard let crop = image.cropping(to: roi) else { return nil }
        var holeBudget = n * 2
        var rgba = [UInt8](repeating: 0, count: n * 4)
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard
                let c = CGContext(
                    data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            c.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var seen = [UInt8](repeating: 0, count: n)
        func white(_ i: Int) -> Bool { min(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]) >= 235 }
        var best: Result?
        for seed in 0..<n where seen[seed] == 0 && white(seed) {
            guard !Task.isCancelled else { return nil }
            var q = [seed]
            var head = 0
            seen[seed] = 1
            var lx = w
            var rx = 0
            var ty = h
            var by = 0
            while head < q.count {
                let z = q[head]
                head += 1
                let x = z % w
                let y = z / w
                lx = min(lx, x)
                rx = max(rx, x)
                ty = min(ty, y)
                by = max(by, y)
                for (xx, yy) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where xx >= 0 && xx < w && yy >= 0 && yy < h {
                    let j = yy * w + xx
                    if seen[j] == 0 && white(j) {
                        seen[j] = 1
                        q.append(j)
                    }
                }
            }
            guard q.count >= 80, lx > 0, rx < w - 1, ty > 0, by < h - 1 else { continue }
            let box = CGRect(
                x: CGFloat(lx) + roi.minX, y: CGFloat(ty) + roi.minY, width: CGFloat(rx - lx + 1),
                height: CGFloat(by - ty + 1))
            guard owned.allSatisfy({ box.contains($0) }),
                box.width * box.height >= union.width * union.height * 1.12
            else { continue }
            let cw = rx - lx + 3
            let ch = by - ty + 3
            guard cw * ch <= holeBudget else { continue }
            holeBudget -= cw * ch
            var mask = [UInt8](repeating: 0, count: cw * ch)
            for z in q { mask[(z / w - ty + 1) * cw + z % w - lx + 1] = 1 }
            var exterior = [0]
            mask[0] = 2
            head = 0
            while head < exterior.count {
                let z = exterior[head]
                head += 1
                let x = z % cw
                let y = z / cw
                for (xx, yy) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where xx >= 0 && xx < cw && yy >= 0 && yy < ch {
                    let j = yy * cw + xx
                    if mask[j] == 0 {
                        mask[j] = 2
                        exterior.append(j)
                    }
                }
            }
            var total = 0
            var inside = 0
            var everyOwnerEnclosed = true
            for r in owned {
                var ownerTotal = 0
                var ownerInside = 0
                for y in Int(r.minY)...Int(r.maxY) {
                    for x in Int(r.minX)...Int(r.maxX) {
                        let xx = x - Int(roi.minX) - lx + 1
                        let yy = y - Int(roi.minY) - ty + 1
                        if xx >= 0 && xx < cw && yy >= 0 && yy < ch {
                            ownerTotal += 1
                            if mask[yy * cw + xx] == 0 { ownerInside += 1 }
                        }
                    }
                }
                total += ownerTotal
                inside += ownerInside
                if ownerTotal == 0 || Double(ownerInside) / Double(ownerTotal) < 0.97 {
                    everyOwnerEnclosed = false
                    break
                }
            }
            guard everyOwnerEnclosed, total > 0 else { continue }
            var lefts = [Int](repeating: cw, count: ch)
            var rights = [Int](repeating: -1, count: ch)
            var holes = 0
            var sx = 0.0
            var sy = 0.0
            for y in 0..<ch {
                var x = 0
                while x < cw {
                    guard mask[y * cw + x] == 0 else {
                        x += 1
                        continue
                    }
                    let start = x
                    while x < cw && mask[y * cw + x] == 0 {
                        holes += 1
                        sx += Double(x)
                        sy += Double(y)
                        x += 1
                    }
                    if x - start > rights[y] - lefts[y] + 1 {
                        lefts[y] = start
                        rights[y] = x - 1
                    }
                }
            }
            guard holes > inside else { continue }
            let bands = min(96, ch)
            var spans: [Double] = []
            for b in 0..<bands {
                var l = 0
                var r = cw - 1
                for y in b * ch / bands..<max(b * ch / bands + 1, (b + 1) * ch / bands) {
                    l = max(l, lefts[y])
                    r = min(r, rights[y])
                }
                if l <= r {
                    spans += [
                        (Double(l + lx - 1) + Double(roi.minX)) / Double(image.width),
                        (Double(r + lx) + Double(roi.minX)) / Double(image.width),
                    ]
                } else {
                    spans += [-1, -1]
                }
            }
            let candidate = Result(
                bounds: CGRect(
                    x: roi.minX + CGFloat(lx - 1), y: roi.minY + CGFloat(ty - 1), width: CGFloat(cw),
                    height: CGFloat(ch)),
                center: CGPoint(
                    x: roi.minX + CGFloat(lx - 1) + CGFloat(sx / Double(holes)),
                    y: roi.minY + CGFloat(ty - 1) + CGFloat(sy / Double(holes))), spans: spans,
                holeCount: holes)
            if best == nil || holes < best!.holeCount { best = candidate }
        }
        return best
    }

    /// Only unresolved contours enter this bounded fallback. Source-slot witnesses remain authoritative.
    static func fillMissing(
        _ existing: [ReaderTranslationBalloonInterior?], regions: [ReaderTranslationRegion],
        image: CGImage, preservingSourceSlots: Set<String>
    ) -> [ReaderTranslationBalloonInterior?] {
        var result = existing
        var budget = 4_000_000
        var attempts = 0
        let iw = CGFloat(image.width)
        let ih = CGFloat(image.height)
        guard iw > 0, ih > 0, result.count == regions.count else { return result }
        let boxes = regions.map {
            CGRect(
                x: $0.rect.minX * iw, y: $0.rect.minY * ih, width: $0.rect.width * iw,
                height: $0.rect.height * ih)
        }
        for index in regions.indices
        where result[index] == nil && !preservingSourceSlots.contains(regions[index].id) {
            guard !Task.isCancelled, attempts < 8, budget > 0 else { break }
            let source = boxes[index]
            guard regions[index].source.contains(where: \.isLetter), source.width >= 8,
                source.height >= 8,
                source.width * source.height < iw * ih / 8
            else { continue }
            let padding = max(32, min(320, max(source.width, source.height) * 0.65))
            attempts += 1
            var observed = inspect(image: image, owned: [source], padding: padding, pixelBudget: &budget)
            if observed == nil {
                // A connected outline can leave the crop around one lobe. Nearby
                // OCR supplies search context, not an utterance or source union.
                let context = source.insetBy(dx: -padding * 2, dy: -padding * 2)
                let peers = boxes.indices.filter {
                    $0 != index && !source.intersects(boxes[$0]) && context.intersects(boxes[$0])
                }.sorted {
                    hypot(boxes[$0].midX - source.midX, boxes[$0].midY - source.midY)
                        < hypot(boxes[$1].midX - source.midX, boxes[$1].midY - source.midY)
                }
                for peer in peers.prefix(2) {
                    guard attempts < 8, budget > 0 else { break }
                    attempts += 1
                    let peerBox = boxes[peer]
                    let contextPadding = max(32, min(320,
                        max(source.width, source.height, peerBox.width, peerBox.height) * 1.25))
                    observed = inspect(image: image, owned: [source], padding: contextPadding,
                        searchBounds: peerBox, pixelBudget: &budget)
                    if observed != nil { break }
                }
            }
            guard let proof = observed else { continue }
            var spans = proof.spans
            let rows = spans.count / 2
            let band = proof.bounds.height / CGFloat(rows)
            var rejected = false
            for peer in boxes.indices where peer != index && proof.bounds.intersects(boxes[peer]) {
                let other = boxes[peer]
                // Independently owned OCR must not become permission to move into its slot.
                if source.intersects(other) {
                    rejected = true
                    break
                }
                for row in 0..<rows where spans[row * 2] >= 0 {
                    let y = proof.bounds.minY + CGFloat(row) * band
                    guard y + band > other.minY, y < other.maxY else { continue }
                    if source.maxX <= other.minX {
                        spans[row * 2 + 1] = min(
                            spans[row * 2 + 1], Double((source.maxX + other.minX) / 2 / iw))
                    } else if other.maxX <= source.minX {
                        spans[row * 2] = max(spans[row * 2], Double((other.maxX + source.minX) / 2 / iw))
                    } else if source.maxY <= other.minY && y + band > (source.maxY + other.minY) / 2 {
                        spans[row * 2] = -1
                        spans[row * 2 + 1] = -1
                    } else if other.maxY <= source.minY && y < (other.maxY + source.minY) / 2 {
                        spans[row * 2] = -1
                        spans[row * 2 + 1] = -1
                    }
                    if spans[row * 2] >= spans[row * 2 + 1] {
                        spans[row * 2] = -1
                        spans[row * 2 + 1] = -1
                    }
                }
            }
            guard !rejected else { continue }
            let center = CGPoint(x: source.midX / iw, y: source.midY / ih)
            let row = min(rows - 1, max(0, Int((source.midY - proof.bounds.minY) / band)))
            guard spans[row * 2] >= 0, Double(center.x) >= spans[row * 2],
                Double(center.x) <= spans[row * 2 + 1]
            else { continue }
            result[index] = ReaderTranslationBalloonInterior(
                rect: CGRect(
                    x: proof.bounds.minX / iw, y: proof.bounds.minY / ih, width: proof.bounds.width / iw,
                    height: proof.bounds.height / ih), center: center, spans: spans, contourVerified: true)
        }
        return result
    }
}
