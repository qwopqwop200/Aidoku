import CoreGraphics
import Foundation

/// Independent colour contours for tinted/translucent balloons. The light-paper map cannot
/// distinguish the artwork showing through them from an opening in the balloon itself.
enum ReaderTranslationChromaticBalloon {
    static func applying(_ regions: [ReaderTranslationRegion], image: CGImage) -> [ReaderTranslationRegion] {
        let regions = attachingThinEndMarks(attachingRepeatedReactionLeadIn(attachingReactionPunctuation(regions, image: image), image: image), image: image)
        let contours = interiors(regions, image: image)
        var values = regions
        for i in values.indices {
            if let contour = contours[i] { values[i].balloonInterior = contour }
        }
        var removed = Set<Int>()
        let width = CGFloat(image.width), height = CGFloat(image.height)
        for i in values.indices where !removed.contains(i) {
            guard let contour = contours[i] else { continue }
            var members = [i]
            var changed = true
            while changed && members.count < 6 {
                changed = false
                for j in values.indices where j != i && !members.contains(j) && !removed.contains(j) {
                    // A short fragment of a vertical paragraph may be labelled
                    // horizontal. Shared contour and strict adjacency still
                    // establish ownership; distant replies remain separate.
                    guard contours[j] == contour,
                          members.contains(where: { values[$0].sourceOrientation == .vertical }) ||
                            values[j].sourceOrientation == .vertical else { continue }
                    let b = values[j].rect
                    let adjacent = members.contains { k in
                        let a = values[k].rect
                        // A paragraph box spans several columns; its entire width is not a glyph.
                        func glyphWidth(_ region: ReaderTranslationRegion) -> CGFloat {
                            let box = region.rect
                            return region.sourceSingleVerticalColumn == true ? box.width * width
                                : min(box.width * width, box.height * height / CGFloat(min(6, max(1, region.source.count))))
                        }
                        let glyph = min(glyphWidth(values[k]), glyphWidth(values[j]))
                        let gapX = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                        let gapY = max(a.minY, b.minY) - min(a.maxY, b.maxY)
                        let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                        let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                        // Adjacent vertical columns or an immediately continued column. Distant
                        // replies and the next lobe cannot join merely because their outlines touch.
                        return gapX * width <= glyph * 1.1 && overlapY >= min(a.height, b.height) * 0.7
                            || overlapX >= min(a.width, b.width) * 0.6 && gapY * height <= glyph * 0.65
                    }
                    guard adjacent else { continue }
                    members.append(j); changed = true
                }
            }
            guard members.count >= 2 else { continue }
            // Form column bands first; avoid a non-transitive top/right pairwise sort.
            var bands: [[Int]] = []
            for j in members.sorted(by: { values[$0].rect.midX > values[$1].rect.midX }) {
                if let first = bands.last?.first,
                   min(values[j].rect.maxX, values[first].rect.maxX) - max(values[j].rect.minX, values[first].rect.minX)
                    >= min(values[j].rect.width, values[first].rect.width) * 0.6 {
                    bands[bands.count - 1].append(j)
                } else { bands.append([j]) }
            }
            let ordered = bands.flatMap { $0.sorted { values[$0].rect.minY < values[$1].rect.minY } }
            let rect = members.dropFirst().reduce(values[i].rect) { $0.union(values[$1].rect) }
            var joined = ReaderTranslationRegion(id: values[i].id, rect: rect,
                source: ordered.map { values[$0].source }.joined(), confidence: members.map { values[$0].confidence }.min() ?? 0,
                sourceImageAspectRatio: Double(width / height), sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
            joined.unitMemberRects = ordered.flatMap { values[$0].unitMemberRects.isEmpty ? [values[$0].rect] : values[$0].unitMemberRects }
            joined.auxiliaryInkRects = members.flatMap { values[$0].auxiliaryInkRects }
            joined.auxiliaryInkPolygons = members.flatMap { values[$0].auxiliaryInkPolygons }
            joined.balloonInterior = contour
            joined.polygon = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                              CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            values[i] = joined
            removed.formUnion(members.filter { $0 != i })
        }
        return values.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element }
    }

    /// Large handwritten kana may be decoded as a lone Latin glyph in an overlapping
    /// detector box. It belongs to the same repeated cry only with shared colour and
    /// substantial overlap at that cry's beginning; retain its ink without inventing text.
    private static func attachingRepeatedReactionLeadIn(_ input: [ReaderTranslationRegion], image: CGImage) -> [ReaderTranslationRegion] {
        var result = input, removed = Set<Int>()
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ r: CGRect) -> CGRect { .init(x: r.minX * width, y: r.minY * height, width: r.width * width, height: r.height * height) }
        for j in input.indices {
            let text = input[j].source
            guard (1...2).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isUppercase }) else { continue }
            let head = pixels(input[j].rect)
            let parents = input.indices.filter { i in
                let source = input[i].source.filter { $0.isLetter }
                guard i != j, (3...12).contains(source.count), Set(source).count == 1,
                      source.unicodeScalars.allSatisfy({ (0x3040...0x30FF).contains($0.value) }) else { return false }
                let body = pixels(input[i].rect), overlap = body.intersection(head)
                return !overlap.isNull && overlap.width * overlap.height >= head.width * head.height * 0.4 &&
                    head.midY < body.minY + body.height * 0.25 && head.height < body.height * 0.6 &&
                    ReaderTranslationBalloonMerger.matchingOutlinedInk(in: image, first: head, second: body)
            }
            guard parents.count == 1, let i = parents.first else { continue }
            result[i].auxiliaryInkRects.append(input[j].rect)
            result[i].auxiliaryInkPolygons.append(input[j].polygon)
            removed.insert(j)
        }
        return result.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element }
    }

    /// A vertical long-vowel mark can be OCR'd as “1”. Keep only independently
    /// measured, same-colour thin strokes at the end of a Japanese paragraph.
    private static func attachingThinEndMarks(_ input: [ReaderTranslationRegion], image: CGImage) -> [ReaderTranslationRegion] {
        var result = input, removed = Set<Int>()
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ r: CGRect) -> CGRect { .init(x: r.minX * width, y: r.minY * height, width: r.width * width, height: r.height * height) }
        for j in input.indices where ["1", "I", "l", "|", "ー"].contains(input[j].source) {
            let tail = pixels(input[j].rect)
            let parents = input.indices.filter { i in
                guard i != j, input[i].sourceOrientation == .vertical, input[i].source.count >= 5,
                      input[i].source.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) else { return false }
                let body = pixels(input[i].rect)
                return tail.midY > body.midY && tail.minY < body.maxY && tail.maxY < body.maxY + body.height * 0.3 &&
                    tail.midX > body.minX && tail.midX < body.minX + body.width * 0.4
            }
            guard parents.count == 1, let i = parents.first,
                  let color = ReaderTranslationBalloonMerger.outlinedInk(in: image, rect: pixels(input[i].rect)),
                  let ink = punctuationInkBounds(image: image, rect: tail.insetBy(dx: -tail.width * 0.35, dy: -tail.height * 0.35), color: color, verticalRule: true),
                  ink.height >= ink.width * 4, ink.height <= pixels(input[i].rect).height * 0.9 else { continue }
            let rect = CGRect(x: ink.minX / width, y: ink.minY / height, width: ink.width / width, height: ink.height / height)
            result[i].auxiliaryInkRects.append(rect)
            result[i].auxiliaryInkPolygons.append([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)])
            removed.insert(j)
        }
        return result.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element }
    }

    /// A sideways punctuation row can include one hallucinated Latin glyph from a nearby heart.
    /// Require a Japanese reaction, overlapping end geometry and independently matching ink.
    static func attachingReactionPunctuation(_ input: [ReaderTranslationRegion], image: CGImage) -> [ReaderTranslationRegion] {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ b: CGRect) -> CGRect { CGRect(x: b.minX * width, y: b.minY * height, width: b.width * width, height: b.height * height) }
        var result = input, removed = Set<Int>()
        for j in input.indices {
            let text = input[j].source.trimmingCharacters(in: .whitespacesAndNewlines)
            let marks = text.prefix { "!?！？".contains($0) }
            let suffix = text.dropFirst(marks.count)
            guard (2...3).contains(marks.count), suffix.count <= 1,
                  suffix.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            let tail = pixels(input[j].rect)
            let parents = input.indices.filter { i in
                guard i != j, !removed.contains(i), input[i].sourceOrientation == .vertical,
                      (2...8).contains(input[i].source.count),
                      input[i].source.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) else { return false }
                let body = pixels(input[i].rect)
                return tail.midY >= body.minY + body.height * 0.7 && tail.midY <= body.maxY + body.width * 0.5 &&
                    tail.height <= body.height * 0.5 && tail.width <= body.width * 1.2 &&
                    min(tail.maxX, body.maxX) - max(tail.minX, body.minX) >= min(tail.width, body.width) * 0.6 &&
                    ReaderTranslationBalloonMerger.matchingOutlinedInk(in: image, first: body, second: tail)
            }
            guard parents.count == 1, let i = parents.first else { continue }
            let original = result[i]
            let body = pixels(original.rect)
            guard let color = ReaderTranslationBalloonMerger.outlinedInk(in: image, rect: body),
                  let owned = punctuationInkBounds(image: image, rect: tail, color: color) else { continue }
            let inkRect = CGRect(x: owned.minX / width, y: owned.minY / height, width: owned.width / width, height: owned.height / height)
            let inkPolygon = [CGPoint(x: inkRect.minX, y: inkRect.minY), CGPoint(x: inkRect.maxX, y: inkRect.minY),
                              CGPoint(x: inkRect.maxX, y: inkRect.maxY), CGPoint(x: inkRect.minX, y: inkRect.maxY)]
            result[i] = ReaderTranslationRegion(id: original.id, rect: original.rect, source: original.source + String(marks),
                translation: original.translation, polygon: original.polygon, confidence: original.confidence,
                sourceImageAspectRatio: original.sourceImageAspectRatio, translationOrder: original.translationOrder,
                translationOrderVersion: original.translationOrderVersion, sourceOrientation: original.sourceOrientation,
                sourceSingleVerticalColumn: original.sourceSingleVerticalColumn, translationReuseIdentity: original.translationReuseIdentity,
                auxiliaryInkRects: original.auxiliaryInkRects + [inkRect],
                auxiliaryInkPolygons: original.auxiliaryInkPolygons + [inkPolygon], balloonInterior: original.balloonInterior,
                unitMemberRects: original.unitMemberRects, isOccludedFinePrint: original.isOccludedFinePrint,
                isRecoveredLine: original.isRecoveredLine)
            removed.insert(j)
        }
        return result.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element }
    }

    private static func punctuationInkBounds(image: CGImage, rect: CGRect, color: (Double, Double, Double), verticalRule: Bool = false) -> CGRect? {
        let cropRect = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let crop = image.cropping(to: cropRect) else { return nil }
        let scale = min(1, 128 / max(cropRect.width, cropRect.height))
        let w = max(1, Int(cropRect.width * scale)), h = max(1, Int(cropRect.height * scale))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard drawn else { return nil }
        var mask = [Bool](repeating: false, count: w * h)
        for i in mask.indices {
            let k = i * 4, rgb = [Double(bytes[k]), Double(bytes[k + 1]), Double(bytes[k + 2])]
            let low = rgb.min()!, span = rgb.max()! - low
            if span >= 65 {
                mask[i] = max(abs((rgb[0] - low) * 255 / span - color.0),
                    abs((rgb[1] - low) * 255 / span - color.1), abs((rgb[2] - low) * 255 / span - color.2)) <= 32
            }
        }
        var l = w, r = -1, t = h, b = -1, count = 0
        for start in mask.indices where mask[start] {
            var queue = [start], head = 0, left = w, right = -1, top = h, bottom = -1
            mask[start] = false
            while head < queue.count {
                let i = queue[head], x = i % w, y = i / w; head += 1
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                for yy in max(0, y - 1)...min(h - 1, y + 1) { for xx in max(0, x - 1)...min(w - 1, x + 1) {
                    let j = yy * w + xx
                    if mask[j] { mask[j] = false; queue.append(j) }
                } }
            }
            // A same-colour balloon edge runs out of the punctuation crop.
            guard queue.count >= 3, left > 0, right < w - 1, top > 0, bottom < h - 1 else { continue }
            if verticalRule && (bottom - top + 1 < (right - left + 1) * 4 ||
                queue.count * 10 < (right - left + 1) * (bottom - top + 1) * 6) { continue }
            l = min(l, left); r = max(r, right); t = min(t, top); b = max(b, bottom); count += queue.count
        }
        guard count >= 12, r > l, b > t else { return nil }
        return CGRect(x: cropRect.minX + CGFloat(l) / scale, y: cropRect.minY + CGFloat(t) / scale,
                      width: CGFloat(r - l + 1) / scale, height: CGFloat(b - t + 1) / scale)
    }

    static func interiors(_ regions: [ReaderTranslationRegion], image: CGImage) -> [ReaderTranslationBalloonInterior?] {
        guard !regions.isEmpty, regions.count <= 256 else { return regions.map { _ in nil } }
        let scale = min(1, 1024 / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale)), n = w * h
        // Dilation needs an interior pixel and its surrounding border. A very
        // narrow source (including one reduced to a single pixel) has neither.
        guard w >= 3, h >= 3 else { return regions.map { _ in nil } }
        var rgba = [UInt8](repeating: 0, count: n * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered else { return regions.map { _ in nil } }
        // Bits 0...12 retain the exact colour/dark memberships; bit 15 records
        // the unchanged strong-colour threshold, so dilation needs no third plane.
        let darkBit: UInt16 = 1 << 12
        let hueBits: [UInt16] = (0..<180).map { hue in
            var bits: UInt16 = 0
            for band in 0..<12 {
                let distance = abs(hue - band * 15)
                if min(distance, 180 - distance) <= 12 { bits |= UInt16(1) << band }
            }
            return bits
        }
        var membership = [UInt16](repeating: 0, count: n)
        var dilatedBits = [UInt16](repeating: 0, count: n)
        var populatedBits: UInt16 = 0
        for i in 0..<n {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            let high = max(r, g, b), low = min(r, g, b), delta = high - low
            if high <= 110 && delta <= 40 { membership[i] = darkBit; dilatedBits[i] = darkBit }
            guard delta >= 28, delta * 255 >= high * 45 else { continue }
            let value: Int
            if high == r { value = 30 * (g - b) / delta }
            else if high == g { value = 60 + 30 * (b - r) / delta }
            else { value = 120 + 30 * (r - g) / delta }
            let bits = hueBits[(value + 180) % 180]
            membership[i] |= bits
            populatedBits |= bits
            if delta >= 80 { membership[i] |= 0x8000; dilatedBits[i] |= bits }
        }
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let value = membership[y * w + x]
            let bits = (value & darkBit) | (value & 0x8000 == 0 ? 0 : value & 0x0fff)
            if bits == 0 { continue }
            for yy in (y - 1)...(y + 1) { for xx in (x - 1)...(x + 1) { dilatedBits[yy * w + xx] |= bits } }
        } }
        let boxes = regions.map { CGRect(x: $0.rect.minX * CGFloat(w), y: $0.rect.minY * CGFloat(h),
                                         width: $0.rect.width * CGFloat(w), height: $0.rect.height * CGFloat(h)) }
        var result = [ReaderTranslationBalloonInterior?](repeating: nil, count: regions.count)
        var areas = [Int](repeating: Int.max, count: regions.count)
        struct Component { var count = 0; var l = Int.max; var t = Int.max; var r = 0; var b = 0; var edge = false }
        for band in 0..<13 {
            guard !Task.isCancelled else { break }
            let hue = band * 15, bit = UInt16(1) << band
            guard band == 12 || populatedBits & bit != 0 else { continue }
            for solid in (hue == 180 ? [false] : [false, true]) {
                let mask = solid ? membership : dilatedBits
                var labels = [Int32](repeating: -1, count: n), components: [Component] = [], queue: [Int] = []
                for start in 0..<n where labels[start] < 0 && (mask[start] & bit != 0) == solid {
                    var component = Component(), head = 0
                    queue.removeAll(keepingCapacity: true); queue.append(start)
                    // -2 marks a queued seed; nonnegative labels mark completed runs.
                    // Row-major seeds preserve component IDs and all downstream votes.
                    let id = Int32(components.count); labels[start] = -2
                    while head < queue.count {
                        let seed = queue[head]; head += 1
                        if labels[seed] >= 0 { continue }
                        let y = seed / w, rowStart = y * w
                        var left = seed, right = seed
                        while left > rowStart && labels[left - 1] < 0 && (mask[left - 1] & bit != 0) == solid { left -= 1 }
                        while right < rowStart + w - 1 && labels[right + 1] < 0 && (mask[right + 1] & bit != 0) == solid { right += 1 }
                        for i in left...right { labels[i] = id }
                        component.count += right - left + 1
                        component.l = min(component.l, left - rowStart); component.r = max(component.r, right - rowStart)
                        component.t = min(component.t, y); component.b = max(component.b, y)
                        if left == rowStart || right == rowStart + w - 1 || y == 0 || y == h - 1 { component.edge = true }
                        for offset in [-w, w] where y + offset / w >= 0 && y + offset / w < h {
                            var next = left + offset
                            let end = right + offset
                            while next <= end {
                                if labels[next] < 0 && (mask[next] & bit != 0) == solid {
                                    if labels[next] == -1 { labels[next] = -2; queue.append(next) }
                                    repeat { next += 1 } while next <= end && labels[next] < 0 && (mask[next] & bit != 0) == solid
                                } else { next += 1 }
                            }
                        }
                    }
                    components.append(component)
                }
                var candidates: [Int: [Int]] = [:]
                var partialSourceCandidates = Set<Int>()
                for (index, box) in boxes.enumerated() where regions[index].source.contains(where: \.isLetter) {
                    var votes: [Int: Int] = [:]
                    for fy in [0.08, 0.29, 0.5, 0.71, 0.92] { for fx in [0.08, 0.29, 0.5, 0.71, 0.92] {
                        let x = max(0, min(w - 1, Int(box.minX + box.width * fx)))
                        let y = max(0, min(h - 1, Int(box.minY + box.height * fy)))
                        let id = Int(labels[y * w + x]); if id >= 0 { votes[id, default: 0] += 1 }
                    } }
                    guard let (id, count) = votes.max(by: { $0.value < $1.value }), count >= 2 else { continue }
                    let c = components[id], area = (c.r - c.l + 1) * (c.b - c.t + 1)
                    let rect = CGRect(x: c.l, y: c.t, width: c.r - c.l + 1, height: c.b - c.t + 1)
                    // A balloon cropped by one page edge is still closed by that edge.
                    // Reject exterior components spanning two edges and near-rectangular panels.
                    let edgeCount = (c.l == 0 ? 1 : 0) + (c.t == 0 ? 1 : 0) + (c.r == w - 1 ? 1 : 0) + (c.b == h - 1 ? 1 : 0)
                    let boundedAtEdge = !solid && edgeCount == 1 && c.count * 100 < area * 90
                    // A tall caption can begin just outside the coloured lobe
                    // while its centre and most of its ink remain inside it.
                    // Only a strong, compact solid-colour vote may use the
                    // smaller source-coverage threshold; free art and broad
                    // page colour are not evidence of a speech balloon.
                    let partialSource = solid && count >= 12 &&
                        CGFloat(area) <= box.width * box.height * 8 &&
                        c.count * 10 < area * 9 &&
                        CGFloat(c.count) >= box.width * box.height * 1.1
                    // A dark outer stroke can bound a nearly full-page-height
                    // dialogue column whose source box already occupies most
                    // of the interior. Its dark letters lower the counted
                    // light area; require a closed, compact non-dark component
                    // and all nine interior samples before accepting it below.
                    let tightOutlined = band == 12 && !solid && result[index] == nil && count >= 10 &&
                        CGFloat(area) >= box.width * box.height * 1.3 &&
                        CGFloat(area) <= box.width * box.height * 3 &&
                        c.count * 10 < area * 9 &&
                        CGFloat(c.count) >= box.width * box.height * 0.85
                    guard (!c.edge || boundedAtEdge), c.count > 100, c.count * 100 >= area * 38, area < n / 3,
                          !(solid && c.count * 100 >= area * 95),
                          CGFloat(c.count) >= box.width * box.height * (tightOutlined ? 0.85 : partialSource ? 1.1 : 1.2),
                          CGFloat(area) <= box.width * box.height * 100,
                          rect.contains(box.insetBy(dx: box.width * 0.12, dy: box.height * 0.12)) else { continue }
                    candidates[id, default: []].append(index)
                    if partialSource { partialSourceCandidates.insert(index) }
                }
                for (id, indices) in candidates {
                    let c = components[id], cw = c.r - c.l + 1, ch = c.b - c.t + 1
                    // Fill internal holes, but preserve the exterior and every concavity of the contour.
                    var exterior = [UInt8](repeating: 0, count: cw * ch), head = 0
                    queue.removeAll(keepingCapacity: true)
                    for y in 0..<ch { for x in 0..<cw where x == 0 || y == 0 || x == cw - 1 || y == ch - 1 {
                        let i = y * cw + x
                        if labels[(y + c.t) * w + x + c.l] != id { exterior[i] = 1; queue.append(i) }
                    } }
                    while head < queue.count {
                        let i = queue[head]; head += 1; let x = i % cw, y = i / cw
                        for next in [x > 0 ? i - 1 : -1, x < cw - 1 ? i + 1 : -1, y > 0 ? i - cw : -1, y < ch - 1 ? i + cw : -1]
                        where next >= 0 && exterior[next] == 0 && labels[(next / cw + c.t) * w + next % cw + c.l] != id {
                            exterior[next] = 1; queue.append(next)
                        }
                    }
                    for partition in lobePartitions(exterior: exterior, width: cw, height: ch,
                        boxes: indices.map { boxes[$0].offsetBy(dx: -CGFloat(c.l), dy: -CGFloat(c.t)) }) {
                        let originX = c.l + partition.x, originY = c.t + partition.y
                        let sourceWidth = cw, sourceExterior = exterior
                        let cw = partition.width, ch = partition.height
                        var localExterior = [UInt8](repeating: 0, count: cw * ch)
                        for y in 0..<ch {
                            let start = (y + partition.y) * sourceWidth + partition.x
                            for x in 0..<cw { localExterior[y * cw + x] = sourceExterior[start + x] }
                        }
                        let exterior: [UInt8] = localExterior
                    let area = exterior.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
                    var spans: [Double] = [], sumX = 0.0, sumY = 0.0, count = 0.0
                    for band in 0..<48 {
                        let y0 = band * ch / 48, y1 = max(y0 + 1, (band + 1) * ch / 48)
                        var left = 0, right = cw - 1
                        for y in y0..<min(ch, y1) {
                            var best = (l: 0, r: -1), start = -1
                            for x in 0...cw {
                                if x < cw && exterior[y * cw + x] == 0 { if start < 0 { start = x } }
                                else if start >= 0 {
                                    if x - start > best.r - best.l + 1 { best = (start, x - 1) }; start = -1
                                }
                            }
                            left = max(left, best.l); right = min(right, best.r)
                        }
                        if right <= left { spans += [-1, -1] }
                        else {
                            spans += [Double(left + originX + 1) / Double(w), Double(right + originX) / Double(w)]
                            let weight = Double(right - left)
                            sumX += Double(left + right + 2 * originX) / 2 * weight
                            sumY += Double(y0 + y1 + 2 * originY) / 2 * weight; count += weight
                        }
                    }
                    guard count > 0 else { continue }
                    let bodyCenters = lobeCenters(exterior: exterior, width: cw, height: ch)
                    let contourRect = CGRect(x: Double(originX) / Double(w), y: Double(originY) / Double(h),
                                             width: Double(cw) / Double(w), height: Double(ch) / Double(h))
                    let interior = ReaderTranslationBalloonInterior(
                        rect: contourRect,
                        center: centerInsideVerifiedSpans(
                            CGPoint(x: sumX / count / Double(w), y: sumY / count / Double(h)),
                            rect: contourRect, spans: spans,
                            imageSize: CGSize(width: CGFloat(w), height: CGFloat(h))),
                        spans: spans, contourVerified: true)
                    for index in indices where area < areas[index] {
                        let box = boxes[index]
                        let covered = [0.12, 0.5, 0.88].flatMap { fy in
                            [0.12, 0.5, 0.88].map { fx in
                                let x = Int(box.minX + box.width * fx) - originX
                                let y = Int(box.minY + box.height * fy) - originY
                                return x >= 0 && x < cw && y >= 0 && y < ch && exterior[y * cw + x] == 0
                            }
                        }
                        guard covered.allSatisfy({ $0 }) || partialSourceCandidates.contains(index) &&
                            covered[4] && covered.filter({ $0 }).count >= 5 else { continue }
                        // A tiny fragment requires another caption to establish the containing balloon.
                        guard CGFloat(area) < boxes[index].width * boxes[index].height * 22 || indices.count >= 2 else { continue }
                        if bodyCenters.count > 1 {
                            let local = CGPoint(x: box.midX - CGFloat(originX), y: box.midY - CGFloat(originY))
                            let center = bodyCenters.min { hypot($0.x - local.x, $0.y - local.y) < hypot($1.x - local.x, $1.y - local.y) }!
                            result[index] = ReaderTranslationBalloonInterior(rect: interior.rect,
                                center: centerInsideVerifiedSpans(
                                    CGPoint(x: (center.x + CGFloat(originX)) / CGFloat(w),
                                            y: (center.y + CGFloat(originY)) / CGFloat(h)),
                                    rect: contourRect, spans: spans,
                                    imageSize: CGSize(width: CGFloat(w), height: CGFloat(h))),
                                spans: interior.spans, contourVerified: true)
                        } else { result[index] = interior }
                        areas[index] = area
                    }
                    }
                }
            }
        }
        return result
    }
    /// An area centroid can land in the neck between connected lobes. Keep the
    /// anchor inside the measured horizontal slice, without inventing a wider
    /// contour or moving a valid centre.
    static func centerInsideVerifiedSpans(_ center: CGPoint, rect: CGRect,
                                          spans: [Double], imageSize: CGSize) -> CGPoint {
        let bands = spans.count / 2
        guard bands > 0, rect.height > 0, imageSize.width > 0, imageSize.height > 0 else { return center }
        let current = max(0, min(bands - 1, Int((center.y - rect.minY) / rect.height * CGFloat(bands))))
        func horizontalRange(_ band: Int) -> ClosedRange<CGFloat>? {
            let left = CGFloat(spans[2 * band]), right = CGFloat(spans[2 * band + 1])
            guard left >= 0, right > left else { return nil }
            let inset = min((right - left) / 4, 1 / imageSize.width)
            return (left + inset)...(right - inset)
        }
        if let range = horizontalRange(current), range.contains(center.x) { return center }
        var nearest = center, distance = CGFloat.infinity
        for band in 0..<bands {
            guard let range = horizontalRange(band) else { continue }
            let lower = rect.minY + rect.height * CGFloat(band) / CGFloat(bands)
            let upper = rect.minY + rect.height * CGFloat(band + 1) / CGFloat(bands)
            let inset = min((upper - lower) / 4, 1 / imageSize.height)
            let point = CGPoint(x: min(range.upperBound, max(range.lowerBound, center.x)),
                                y: min(upper - inset, max(lower + inset, center.y)))
            let dx = (point.x - center.x) * imageSize.width
            let dy = (point.y - center.y) * imageSize.height
            let candidateDistance = dx * dx + dy * dy
            if candidateDistance < distance { nearest = point; distance = candidateDistance }
        }
        return nearest
    }
    /// Distance peaks identify diagonal lobes too. Peaks in one uninterrupted body
    /// coalesce; only a narrower connecting neck can give a caption a different centre.
    private static func lobeCenters(exterior: [UInt8], width: Int, height: Int) -> [CGPoint] {
        guard width >= 5, height >= 5 else { return [] }
        var distance = exterior.map { $0 == 0 ? 1_000_000 : 0 }
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x
            if x == 0 || y == 0 || x == width - 1 || y == height - 1 { distance[i] = min(distance[i], 10) }
            if x > 0 { distance[i] = min(distance[i], distance[i - 1] + 10) }
            if y > 0 { distance[i] = min(distance[i], distance[i - width] + 10) }
            if x > 0 && y > 0 { distance[i] = min(distance[i], distance[i - width - 1] + 14) }
            if x + 1 < width && y > 0 { distance[i] = min(distance[i], distance[i - width + 1] + 14) }
        } }
        for y in stride(from: height - 1, through: 0, by: -1) { for x in stride(from: width - 1, through: 0, by: -1) {
            let i = y * width + x
            if x + 1 < width { distance[i] = min(distance[i], distance[i + 1] + 10) }
            if y + 1 < height { distance[i] = min(distance[i], distance[i + width] + 10) }
            if x + 1 < width && y + 1 < height { distance[i] = min(distance[i], distance[i + width + 1] + 14) }
            if x > 0 && y + 1 < height { distance[i] = min(distance[i], distance[i + width - 1] + 14) }
        } }
        let maximum = distance.max() ?? 0
        guard maximum >= 80 else { return [] }
        var peaks: [(point: CGPoint, radius: Int)] = []
        for y in 1..<(height - 1) { for x in 1..<(width - 1) {
            let i = y * width + x, value = distance[i]
            guard value >= maximum * 35 / 100 else { continue }
            let neighbors = [i - 1, i + 1, i - width, i + width, i - width - 1, i - width + 1, i + width - 1, i + width + 1]
            if neighbors.allSatisfy({ distance[$0] <= value }) { peaks.append((CGPoint(x: x, y: y), value)) }
        } }
        peaks.sort { $0.radius > $1.radius }
        var chosen: [(point: CGPoint, radius: Int)] = []
        for peak in peaks {
            if chosen.contains(where: { hypot($0.point.x - peak.point.x, $0.point.y - peak.point.y) < CGFloat(min($0.radius, peak.radius)) / 12 }) { continue }
            chosen.append(peak)
            if chosen.count >= 16 { break }
        }
        var groups: [[Int]] = []
        func connected(_ a: Int, _ b: Int) -> Bool {
            let first = chosen[a], second = chosen[b]
            let steps = max(1, Int(hypot(first.point.x - second.point.x, first.point.y - second.point.y)))
            for step in 0...steps {
                let fraction = CGFloat(step) / CGFloat(steps)
                let x = Int(first.point.x + (second.point.x - first.point.x) * fraction)
                let y = Int(first.point.y + (second.point.y - first.point.y) * fraction)
                if distance[y * width + x] < max(first.radius, second.radius) * 78 / 100 { return false }
            }
            return true
        }
        for index in chosen.indices {
            let linked = groups.indices.filter { groups[$0].contains { connected($0, index) } }
            let members = linked.flatMap { groups[$0] } + [index]
            for group in linked.reversed() { groups.remove(at: group) }
            groups.append(members)
        }
        guard groups.count > 1, groups.count <= 4 else { return [] }
        let centers = groups.map { group in
            let total = group.reduce(0.0) { $0 + Double(chosen[$1].radius * chosen[$1].radius) }
            let x = group.reduce(0.0) { $0 + Double(chosen[$1].point.x) * Double(chosen[$1].radius * chosen[$1].radius) }
            let y = group.reduce(0.0) { $0 + Double(chosen[$1].point.y) * Double(chosen[$1].radius * chosen[$1].radius) }
            return CGPoint(x: x / total, y: y / total)
        }
        // A distance peak identifies the body, but is not its visual centre:
        // a broad lower half or asymmetric shoulder can move its area centroid.
        // Assign interior cells to their nearest body and omit thin tails/rims.
        var sums = [(x: Double, y: Double, count: Double)](repeating: (0, 0, 0), count: centers.count)
        for y in 0..<height { for x in 0..<width where distance[y * width + x] >= 40 {
            let index = centers.indices.min {
                hypot(centers[$0].x - CGFloat(x), centers[$0].y - CGFloat(y)) <
                    hypot(centers[$1].x - CGFloat(x), centers[$1].y - CGFloat(y))
            }!
            sums[index].x += Double(x); sums[index].y += Double(y); sums[index].count += 1
        } }
        return centers.indices.map { index in
            let sum = sums[index]
            guard sum.count > 0 else { return centers[index] }
            let point = CGPoint(x: sum.x / sum.count, y: sum.y / sum.count)
            return exterior[Int(point.y) * width + Int(point.x)] == 0 ? point : centers[index]
        }
    }

    private struct LobePartition { let x: Int; let y: Int; let width: Int; let height: Int }

    /// A contour may enclose two utterances connected by a narrow neck. Split only when
    /// independent source boxes lie on both sides, neither is cut, and both bodies widen.
    private static func lobePartitions(exterior: [UInt8], width: Int, height: Int,
                                       boxes: [CGRect]) -> [LobePartition] {
        var pending = [LobePartition(x: 0, y: 0, width: width, height: height)]
        var output: [LobePartition] = []
        while let part = pending.popLast() {
            let local = boxes.filter { box in
                CGRect(x: part.x, y: part.y, width: part.width, height: part.height).contains(CGPoint(x: box.midX, y: box.midY))
            }
            var best: (vertical: Bool, cut: Int, ratio: Double)?
            if local.count >= 2 && output.count + pending.count < 3 {
                for vertical in [true, false] {
                    let length = vertical ? part.height : part.width
                    guard length >= 24 else { continue }
                    let projection = (0..<length).map { position -> Int in
                        var count = 0
                        for cross in 0..<(vertical ? part.width : part.height) {
                            let x = part.x + (vertical ? cross : position)
                            let y = part.y + (vertical ? position : cross)
                            if exterior[y * width + x] == 0 { count += 1 }
                        }
                        return count
                    }
                    // Every candidate cut queries the same two ranges. Build
                    // their maxima once instead of rescanning them per cut.
                    var prefixMaximum = projection, suffixMaximum = projection
                    for index in 1..<length {
                        prefixMaximum[index] = max(prefixMaximum[index - 1], projection[index])
                    }
                    for index in stride(from: length - 2, through: 0, by: -1) {
                        suffixMaximum[index] = max(suffixMaximum[index + 1], projection[index])
                    }
                    let start = max(3, length / 5), end = min(length - 3, length * 4 / 5)
                    for cut in start..<end {
                        let absolute = CGFloat((vertical ? part.y : part.x) + cut)
                        let lower = local.filter { (vertical ? $0.maxY : $0.maxX) <= absolute - 1 }
                        let upper = local.filter { (vertical ? $0.minY : $0.minX) >= absolute + 1 }
                        guard !lower.isEmpty, !upper.isEmpty, lower.count + upper.count == local.count else { continue }
                        let before = prefixMaximum[max(1, cut - 2) - 1]
                        let after = suffixMaximum[min(length - 1, cut + 2)]
                        let neck = (projection[cut - 1] + projection[cut] + projection[cut + 1]) / 3
                        let ratio = Double(neck) / Double(max(1, min(before, after)))
                        if ratio < 0.90 && (best == nil || ratio < best!.ratio) { best = (vertical, cut, ratio) }
                    }
                }
            }
            guard let best else { output.append(part); continue }
            if best.vertical {
                pending.append(.init(x: part.x, y: part.y, width: part.width, height: best.cut))
                pending.append(.init(x: part.x, y: part.y + best.cut, width: part.width, height: part.height - best.cut))
            } else {
                pending.append(.init(x: part.x, y: part.y, width: best.cut, height: part.height))
                pending.append(.init(x: part.x + best.cut, y: part.y, width: part.width - best.cut, height: part.height))
            }
        }
        return output
    }

}
