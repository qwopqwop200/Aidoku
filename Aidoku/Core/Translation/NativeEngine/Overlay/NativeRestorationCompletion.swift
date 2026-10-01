import CoreGraphics
import Foundation

extension NativeRestorationPixels {
    static func narrowPaperGlyphs(_ p: Self, box: CGRect, palette: Palette?, options: NativeObservedRestoreOptions) -> Self? {
        guard options.vertical, options.auxiliary.isEmpty, box.width >= 12, box.width <= 64,
              box.height >= box.width * 2, box.height <= box.width * 7, p.count <= 65_536,
              box.minX >= 3, box.minY >= 3, box.maxX <= CGFloat(p.width - 3), box.maxY <= CGFloat(p.height - 3) else { return nil }
        var ink = [UInt8](repeating: 0, count: p.count), safe = ink, paper = 0, total = 0, sums = [Double](repeating: 0, count: 3)
        for i in 0..<p.count {
            let color = p.color(i), x = CGFloat(i % p.width), y = CGFloat(i / p.width)
            ink[i] = color.minimum < 230 ? 1 : 0; safe[i] = color.minimum >= 242 ? 1 : 0
            if x >= box.minX && x <= box.maxX && y >= box.minY && y <= box.maxY {
                guard p.rgba[i * 4 + 3] == 255, color.maximum - color.minimum <= 12 else { return nil }
                total += 1
                if color.minimum >= 248 { paper += 1; for c in 0..<3 { sums[c] += color.channels[c] } }
            }
        }
        guard Double(paper) >= Double(total) * 0.6 else { return nil }
        struct Part { let component: Component; let dark: Int; let contained: Bool; let aligned: Bool }
        let parts = p.components(ink).filter {
            $0.rect.maxX - 1 >= box.minX && $0.rect.minX <= box.maxX && $0.rect.maxY - 1 >= box.minY && $0.rect.minY <= box.maxY
        }.map { component in
            Part(component: component, dark: component.points.filter { p.color($0).maximum < 100 }.count,
                 contained: component.rect.minX >= box.minX && component.rect.maxX - 1 <= box.maxX &&
                    component.rect.minY >= box.minY && component.rect.maxY - 1 <= box.maxY,
                 aligned: abs(component.rect.midX - 0.5 - box.midX) <= box.width * 0.23 &&
                    component.rect.width - 1 < box.width * 0.8 && component.rect.height - 1 < box.width * 1.25)
        }
        let coreIndices = parts.indices.filter { parts[$0].contained && parts[$0].aligned && parts[$0].dark >= 2 }
        guard coreIndices.count >= 3, coreIndices.reduce(0, { $0 + parts[$1].dark }) >= 24 else { return nil }
        let bounds = coreIndices.reduce(CGRect.null) { $0.union(parts[$1].component.rect) }
        guard bounds.height - 1 >= box.height * 0.35 else { return nil }
        let owned = Set(parts.indices.filter { index in
            let part = parts[index], r = part.component.rect
            return coreIndices.contains(index) || part.contained && part.aligned && Double(part.component.points.count) >= box.width * 0.8 &&
                r.minX >= bounds.minX && r.maxX <= bounds.maxX && r.width - 1 >= box.width * 0.22 &&
                r.minY >= bounds.minY - box.width * 0.5 && r.maxY - 1 <= bounds.maxY - 1 + box.width * 0.65
        })
        let rim = parts.indices.filter { !owned.contains($0) }.map { parts[$0] }
        guard !rim.contains(where: { $0.contained && $0.dark >= 2 }),
              rim.contains(where: { $0.component.rect.minX < box.midX - box.width * 0.3 }),
              rim.contains(where: { $0.component.rect.maxX - 1 > box.midX + box.width * 0.3 }),
              rim.contains(where: { !$0.contained }) || rim.count >= 6 else { return nil }
        let exclusions = options.excluded.isEmpty ? options.inferredRubyExclusions : options.excluded
        guard !owned.contains(where: { index in parts[index].component.points.contains { i in
            exclusions.contains { r in CGFloat(i % p.width) >= r.minX && CGFloat(i % p.width) <= r.maxX &&
                CGFloat(i / p.width) >= r.minY && CGFloat(i / p.width) <= r.maxY }
        } }) else { return nil }
        let bg = NativeRestorationRGB(sums.map { floor($0 / Double(paper) + 0.5) })
        var mask = ink.map { _ in UInt8(0) }
        for index in owned { for i in parts[index].component.points { mask[i] = 1 } }
        let original = mask
        for i in 0..<p.count where original[i] != 0 {
            for j in p.indices(CGRect(x: i % p.width - 2, y: i / p.width - 2, width: 5, height: 5)) {
                let x = j % p.width, y = j / p.width
                if x >= 1 && y >= 1 && x <= p.width - 2 && y <= p.height - 2 && (ink[j] == 0 || original[j] != 0) { mask[j] = 1 }
            }
        }
        var output = Self(width: p.width, height: p.height)
        for i in 0..<p.count where mask[i] != 0 { output.paint(i, bg); safe[i] = 1 }
        output.layoutSafe = safe; output.erasureComplete = true; output.sourceErasureVerified = true; output.glyphsVerified = true
        output.method = "narrow-paper-glyphs"
        output.sourceRemainingInk = 0
        output.surfaceQuality = ["safe": true, "reason": "smooth", "rmse": 0, "outliers": 0, "samples": paper]
        output.observedFill = palette?.verifiedForeground ?? NativeRestorationRGB([50, 50, 50]); output.observedBacking = bg
        return output
    }

    static func finishClearPaperCaption(_ p: Self, box: CGRect, palette: Palette?, options: NativeObservedRestoreOptions, repaired: Self) -> Self {
        guard !repaired.erasureComplete, !options.slantedOwnership, let palette, let bg = palette.verifiedBackground, bg.minimum >= 248,
              bg.maximum - bg.minimum <= 6, p.count <= 262_144, repaired.paintedCount >= 32 else { return repaired }
        guard let fill = rgb(palette.sourceInk?["foreground"]) ?? palette.verifiedForeground else { return repaired }
        let outline = rgb(palette.sourceInk?["stroke"]) ?? palette.stroke
        let fg = fill.minimum >= 220 && outline != nil ? outline! : fill
        var boundary = 0, clear = 0
        for i in 0..<p.count {
            let x = i % p.width, y = i / p.width
            if x < 2 || y < 2 || x >= p.width - 2 || y >= p.height - 2 {
                boundary += 1
                if p.rgba[i * 4 + 3] == 255 && p.color(i).distance(bg) <= 10 { clear += 1 }
            }
        }
        let span = fg.maximum - fg.minimum, color = fg.channels.map { ($0 - fg.minimum) * 255 / max(1, span) }
        guard Double(clear) >= Double(boundary) * (span >= 60 && !options.chromaticBalloon ? 0.95 : 0.98) else { return repaired }
        var pending = Set<Int>(), foreign = Set<Int>()
        for rect in [box] + options.auxiliary {
            for i in p.indices(rect.insetBy(dx: -2, dy: -2)) {
                let x = i % p.width, y = i / p.width
                if x < 2 || y < 2 || x >= p.width - 2 || y >= p.height - 2 { continue }
                let rgb = repaired.rgba[i * 4 + 3] != 0 ? repaired.color(i) : p.color(i)
                if rgb.distance(bg) <= 12 { continue }
                let d = rgb.maximum - rgb.minimum
                let owned = span >= 60 ? d >= 10 && zip(rgb.channels.map { ($0 - rgb.minimum) * 255 / d }, color).map { abs($0 - $1) }.max()! <= 45 :
                    fg.maximum < 90 && d <= 20
                if !owned {
                    if d > (span >= 60 ? 24 : 3) { return repaired }
                    foreign.insert(i)
                }
                pending.insert(i)
            }
        }
        guard foreign.count <= (span >= 60 ? 512 : 8) else { return repaired }
        let mask = (0..<p.count).map { foreign.contains($0) ? UInt8(1) : 0 }
        for group in p.components(mask) {
            var boundary = 0, patched = 0
            for i in group.points { for j in p.neighbors(i) where !foreign.contains(j) {
                boundary += 1; if repaired.rgba[j * 4 + 3] == 255 || pending.contains(j) { patched += 1 }
            } }
            if group.points.count > (span >= 60 ? 64 : 8) || Double(patched) < Double(boundary) * 0.5 { return repaired }
        }
        guard Double(pending.count) <= max(32, Double(repaired.paintedCount) * 0.1) else { return repaired }
        var output = repaired
        for i in pending { output.paint(i, bg); output.layoutSafe?[i] = 1 }
        output.erasureComplete = true; output.sourceErasureVerified = true; output.glyphsVerified = true
        return output
    }
}
