import CoreGraphics
import Foundation

/// A broad OCR title can surround a separate, measured speech balloon.
/// Resolve only the smaller balloon's independently enclosed glyph rectangle;
/// all foreign protection outside that rectangle remains byte-for-byte intact.
enum NativeClosedBalloonExclusion {
    struct Proof {
        let excluded: [CGRect]
        fileprivate let width: Int
        fileprivate let height: Int
        fileprivate let readablePaper: [UInt8]

        /// Readable original paper does not grant source-paint ownership. Only
        /// fully certified repairs may expose this independently observed room.
        /// The alpha, RGB, exclusions, and source-ink certificates stay intact.
        @discardableResult
        func certifyLayout(of repaired: inout NativeRestorationPixels, pixelBudget: Int = 262_144) -> Int {
            guard !Task.isCancelled, repaired.width == width, repaired.height == height,
                  repaired.rgba.count == readablePaper.count * 4, pixelBudget >= readablePaper.count,
                  repaired.erasureComplete, repaired.glyphsVerified, repaired.sourceErasureVerified == true,
                  var safe = repaired.layoutSafe, safe.count == readablePaper.count else { return 0 }
            var added = 0
            for y in 0..<height {
                if Task.isCancelled { return 0 }
                for x in 0..<width {
                    let index = y * width + x
                    if readablePaper[index] != 0, safe[index] == 0, repaired.rgba[index * 4 + 3] == 0 {
                        safe[index] = 1; added += 1
                    }
                }
            }
            if added > 0 { repaired.layoutSafe = safe }
            return added
        }
    }

    static func resolve(prepared p: NativeSpatialSourceCrop.Prepared, item: NativeTranslationLayoutItem,
                        palette: NativeRestorationPixels.Palette?, imageSize: CGSize,
                        pixelBudget: Int = 262_144) -> [CGRect] {
        prove(prepared: p, item: item, palette: palette, imageSize: imageSize, pixelBudget: pixelBudget)?.excluded ?? p.excluded
    }

    static func prove(prepared p: NativeSpatialSourceCrop.Prepared, item: NativeTranslationLayoutItem,
                      palette: NativeRestorationPixels.Palette?, imageSize: CGSize,
                      pixelBudget: Int = 262_144) -> Proof? {
        let original = p.excluded, pixels = p.pixels, w = pixels.width, h = pixels.height
        guard !Task.isCancelled, !original.isEmpty, original.count <= 256,
              w > 0, h > 0, w <= 262_144 / h, pixels.rgba.count == w * h * 4,
              pixelBudget >= w * h, p.auxiliary.isEmpty, p.marks.isEmpty,
              item.rotation == 0, item.unitMemberRects.isEmpty,
              p.sx.isFinite, p.sy.isFinite, p.sx > 0, p.sy > 0,
              imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0,
              let balloon = item.balloonInterior, balloon.contourVerified,
              balloon.rect.count == 4, balloon.rect.allSatisfy(\.isFinite),
              balloon.rect[0] >= 0, balloon.rect[1] >= 0, balloon.rect[2] > 0, balloon.rect[3] > 0,
              balloon.rect[0] + balloon.rect[2] <= 1, balloon.rect[1] + balloon.rect[3] <= 1,
              !balloon.spans.isEmpty, balloon.spans.count <= 1_024, balloon.spans.count.isMultiple(of: 2),
              balloon.spans.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              let background = palette?.verifiedBackground, let foreground = palette?.verifiedForeground,
              background.minimum >= 248, background.maximum - background.minimum <= 6,
              background.distance(foreground) >= 40 else { return nil }
        let box = p.box, bounds = CGRect(x: 0, y: 0, width: w, height: h)
        guard valid(box), valid(p.crop), bounds.contains(box.insetBy(dx: -1, dy: -1)),
              p.synthetic.count == w * h, p.synthetic.allSatisfy({ $0 == 0 }), original.allSatisfy(valid), item.sourcePolygon.count == 4,
              item.sourcePolygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let polygon = item.sourcePolygon.map { point -> CGPoint in
            CGPoint(x: (point[0] * imageSize.width - p.crop.minX) * p.sx,
                    y: (point[1] * imageSize.height - p.crop.minY) * p.sy)
        }
        guard let ownership = NativeObservedGlyphOwnership.make(width: w, height: h, box: box,
            polygon: polygon, auxiliary: []) else { return nil }
        let r = balloon.rect
        let balloonBox = p.local(CGRect(x: r[0] * imageSize.width, y: r[1] * imageSize.height,
            width: r[2] * imageSize.width, height: r[3] * imageSize.height))
        func inBalloon(_ point: CGPoint) -> Bool {
            let y = (point.y / p.sy + p.crop.minY) / imageSize.height
            guard y >= r[1], y < r[1] + r[3] else { return false }
            let band = min(balloon.spans.count / 2 - 1,
                Int(floor((y - r[1]) / r[3] * CGFloat(balloon.spans.count / 2))))
            let left = balloon.spans[band * 2], right = balloon.spans[band * 2 + 1]
            let x = Double((point.x / p.sx + p.crop.minX) / imageSize.width)
            return left < right && x >= left && x <= right
        }
        let containers = original.map { rect in
            rect.contains(balloonBox) && !inBalloon(CGPoint(x: rect.midX, y: rect.midY))
        }
        guard containers.contains(true) else { return nil }
        // A distinct caption in the same balloon remains authoritative, even
        // when its foreground happens to match the current caption exactly.
        guard zip(original, containers).allSatisfy({ rect, container in
            container || !rect.intersects(box.insetBy(dx: -1, dy: -1))
        }) else { return nil }
        let x0 = Int(floor(box.minX)), y0 = Int(floor(box.minY))
        let x1 = Int(ceil(box.maxX)), y1 = Int(ceil(box.maxY))
        guard x0 >= 1, y0 >= 1, x1 < w, y1 < h else { return nil }
        func paper(_ index: Int) -> Bool {
            let color = pixels.color(index)
            return pixels.rgba[index * 4 + 3] == 255 && color.maximum - color.minimum <= 6 &&
                color.distance(background) <= 8
        }
        // The full one-pixel moat is actual source paper, not an inferred
        // bounding box or a transparent pixel in a proposed repair.
        for y in (y0 - 1)...y1 {
            for x in (x0 - 1)...x1 {
                let index = y * w + x
                guard inBalloon(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)),
                      pixels.rgba[index * 4 + 3] == 255 else { return nil }
                if x < x0 || x >= x1 || y < y0 || y >= y1 {
                    guard paper(index) else { return nil }
                } else {
                    let color = pixels.color(index)
                    guard paper(index) || color.distance(foreground) <= 36 ||
                        NativeRestorationPixels.blend(color, from: foreground, to: background) else {
                        return nil
                    }
                }
            }
        }
        // Every significant dark component must have observed source-ink
        // support and remain separated from the rectangle boundary by paper.
        var seen = [UInt8](repeating: 0, count: w * h), components = 0
        var queue: [Int] = []
        for y in y0..<y1 {
            if Task.isCancelled { return nil }
            for x in x0..<x1 {
                let start = y * w + x
                guard seen[start] == 0, pixels.color(start).distance(background) >= 40 else { continue }
                queue.removeAll(keepingCapacity: true); queue.append(start); seen[start] = 1
                var cursor = 0, core = false
                while cursor < queue.count {
                    let index = queue[cursor], xx = index % w, yy = index / w
                    cursor += 1
                    guard xx > x0, yy > y0, xx < x1 - 1, yy < y1 - 1,
                          ownership.body[index] != 0 else { return nil }
                    core = core || pixels.color(index).distance(foreground) <= 36
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let next = (yy + dy) * w + xx + dx
                            if seen[next] == 0, pixels.color(next).distance(background) >= 40 {
                                seen[next] = 1; queue.append(next)
                            }
                        }
                    }
                }
                guard core else { return nil }
                components += 1
            }
        }
        guard components > 0 else { return nil }
        let resolved = zip(original, containers).flatMap { rect, container -> [CGRect] in
            guard container else { return [rect] }
            // The carve-out is strictly the existing OCR rectangle. No donor,
            // mask, safe surface, or source-ink certificate is manufactured.
            return [
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: box.minY - rect.minY),
                CGRect(x: rect.minX, y: box.maxY, width: rect.width, height: rect.maxY - box.maxY),
                CGRect(x: rect.minX, y: box.minY, width: box.minX - rect.minX, height: box.height),
                CGRect(x: box.maxX, y: box.minY, width: rect.maxX - box.maxX, height: box.height)
            ].filter { $0.width > 0 && $0.height > 0 }
        }
        // A separate read-only certificate covers untouched neutral paper in
        // the measured balloon. It cannot mark original glyphs, art, or pixels
        // belonging to a distinct foreign caption as a clean layout surface.
        var readablePaper = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            if Task.isCancelled { return nil }
            for x in 0..<w {
                let index = y * w + x
                if paper(index), inBalloon(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                    readablePaper[index] = 1
                }
            }
        }
        for (rect, container) in zip(original, containers) where !container {
            let left = Int(max(0, min(CGFloat(w), floor(rect.minX))))
            let right = Int(max(0, min(CGFloat(w), ceil(rect.maxX))))
            let top = Int(max(0, min(CGFloat(h), floor(rect.minY))))
            let bottom = Int(max(0, min(CGFloat(h), ceil(rect.maxY))))
            guard left < right, top < bottom else { continue }
            for y in top..<bottom { for x in left..<right { readablePaper[y * w + x] = 0 } }
        }
        return Proof(excluded: resolved, width: w, height: h, readablePaper: readablePaper)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
}
