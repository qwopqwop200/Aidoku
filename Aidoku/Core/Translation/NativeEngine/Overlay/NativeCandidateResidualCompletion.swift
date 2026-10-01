import CoreGraphics
import Foundation

extension NativeRestorationCandidate {
    func restorationFitEligible(item: NativeTranslationLayoutItem, fontSize: Double,
        inner: Bool = false, alreadyRestored: Bool = false) -> Bool {
        guard erasureComplete, !partialErasureCertified, !alreadyRestored, item.rotation == 0,
              !item.balancedColumn, !item.sourceTextOnly else { return false }
        let core = coreRects, w = surface.width, h = surface.height
        func clear(_ band: Double) -> Bool {
            var area = 0, unsafe = 0
            for r in core {
                guard r.allSatisfy(\.isFinite), band.isFinite else { return false }
                let l = Int(max(0, min(Double(w), floor(r[0] + band))))
                let t = Int(max(0, min(Double(h), floor(r[1] + band))))
                let right = Int(max(0, min(Double(w), ceil(r[0] + r[2] - band))))
                let bottom = Int(max(0, min(Double(h), ceil(r[1] + r[3] - band))))
                if l >= right || t >= bottom { continue }
                for y in t..<bottom { for x in l..<right { area += 1; if safe[y * w + x] == 0 { unsafe += 1 } } }
            }
            return area > 0 && Double(unsafe) <= Double(area) * 0.05
        }
        if surface.coreClear == nil { cacheProof(coreClear: clear(0)) }
        let font = sourceFontSize.flatMap { $0 == 0 || $0.isNaN ? nil : $0 } ?? fontSize
        let glyph = max(4, font * Double(imageSize.width / frame.width * descriptor.sx))
        if inner && surface.coreClear == false && surface.innerCoreClear == nil {
            cacheProof(innerCoreClear: clear(max(2, glyph * 0.25)))
        }
        guard surface.coreClear == true || inner && surface.innerCoreClear == true else { return false }
        if item.sourceVertical && !item.sourceSingleColumn &&
            NativeResidualTopology.hasAttachedLeadingInk(safe: safe, width: w, height: h, core: core, glyph: glyph) { return false }
        if surface.residualLettering == nil {
            cacheProof(residualLettering: NativeResidualTopology.hasResidualLettering(safe: safe, width: w, height: h, regions: core, glyphSize: glyph))
        }
        return surface.residualLettering == false
    }

    /// Fill only small flat leftovers under the current plate; the caller must
    /// invoke the undo when the subsequent measured glyph placement fails.
    func completeResidualErasure(item: NativeTranslationLayoutItem, fontSize: Double, plate: CGRect,
        sourceImage: CGImage, otherSourceRects: [CGRect], sampledForeground: [Double]?, sampledBackground: [Double]?,
        canvasConnected: Bool = true) -> (() -> Void)? {
        let w = surface.width, h = surface.height, n = w * h
        guard erasureComplete, surface.residualLettering == true, !partialErasureCertified,
              item.rotation == 0, !item.balancedColumn, canvasConnected, n <= 262_144,
              safe.count == n, luminance.count == n else { return nil }
        let original = originalRGBA, baseline = beginTrial()
        let card = viewportRegions([plate])[0], regions = coreRects
        let expandedCard = [card[0] - 1, card[1] - 1, card[2] + 2, card[3] + 2]
        let others = viewportRegions(otherSourceRects).map { [$0[0] - 2, $0[1] - 2, $0[2] + 4, $0[3] + 4] }
        let font = sourceFontSize.flatMap { $0 == 0 || $0.isNaN ? nil : $0 } ?? fontSize
        let glyph = max(4, font * Double(imageSize.width / frame.width * descriptor.sx))
        let reader = NativeSourcePixelReader(image: sourceImage)
        defer { reader.release() }
        var continuationBudget = 262_144
        func continues(_ points: [Int]) -> Bool {
            let pageGlyph = glyph / Double(descriptor.sx)
            let xs = points.map { Double(descriptor.crop.minX) + (Double($0 % w) + 0.5) / Double(descriptor.sx) }
            let ys = points.map { Double(descriptor.crop.minY) + (Double($0 / w) + 0.5) / Double(descriptor.sy) }
            let l = max(0, floor(xs.min()! - pageGlyph * 2.5)), t = max(0, floor(ys.min()! - pageGlyph * 2.5))
            let r = min(Double(imageSize.width), ceil(xs.max()! + pageGlyph * 2.5))
            let bottom = min(Double(imageSize.height), ceil(ys.max()! + pageGlyph * 2.5))
            let sw = r - l, sh = bottom - t
            guard sw >= 1, sh >= 1, continuationBudget >= 0 else { return false }
            let scale = min(1, sqrt(Double(continuationBudget) / max(1, sw * sh)))
            guard scale >= 0.5 else { return false }
            let ww = Int(floor(sw * scale)), hh = Int(floor(sh * scale))
            guard ww >= 2, hh >= 2 else { return false }
            continuationBudget -= ww * hh
            guard let page = try? reader.read(x: l, y: t, sourceWidth: sw, sourceHeight: sh, width: ww, height: hh) else { return false }
            let mean = (0..<3).map { k in points.reduce(0.0) { $0 + Double(original[$1 * 4 + k]) } / Double(points.count) }
            let tolerance = mean.max()! - mean.min()! >= 50 ? 80.0 : 48.0
            func near(_ i: Int) -> Bool { page[i * 4 + 3] >= 254 && (0..<3).map { abs(mean[$0] - Double(page[i * 4 + $0])) }.max()! <= tolerance }
            var seen = [UInt8](repeating: 0, count: ww * hh), queue: [Int] = []
            for k in xs.indices {
                let x = min(ww - 1, Int(floor((xs[k] - l) * Double(ww) / sw)))
                let y = min(hh - 1, Int(floor((ys[k] - t) * Double(hh) / sh))), i = y * ww + x
                if i >= 0 && i < ww * hh && seen[i] == 0 && near(i) { seen[i] = 1; queue.append(i) }
            }
            var x0 = ww, x1 = 0, y0 = hh, y1 = 0, head = 0
            while head < queue.count {
                let i = queue[head], x = i % ww, y = i / ww; head += 1
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for yy in max(0, y - 1)...min(hh - 1, y + 1) { for xx in max(0, x - 1)...min(ww - 1, x + 1) {
                    let j = yy * ww + xx
                    if seen[j] == 0 && near(j) { seen[j] = 1; queue.append(j) }
                } }
            }
            return max(Double(x1 - x0 + 1) * sw / Double(ww), Double(y1 - y0 + 1) * sh / Double(hh)) >= pageGlyph * 2.5
        }
        var seen = [UInt8](repeating: 0, count: n), fills: [(pixels: [Int], mean: [Double])] = [], filled = 0
        func color(_ i: Int, _ k: Int) -> Double { Double(baseline.rgba[i * 4 + 3] != 0 ? baseline.rgba[i * 4 + k] : original[i * 4 + k]) }
        for start in 0..<n where baseline.safe[start] == 0 && seen[start] == 0 {
            var queue = [start], head = 0, l = w, t = h, r = 0, bottom = 0; seen[start] = 1
            while head < queue.count {
                let i = queue[head], x = i % w, y = i / w; head += 1
                l = min(l, x); r = max(r, x); t = min(t, y); bottom = max(bottom, y)
                for yy in max(0, y - 1)...min(h - 1, y + 1) { for xx in max(0, x - 1)...min(w - 1, x + 1) {
                    let j = yy * w + xx
                    if baseline.safe[j] == 0 && seen[j] == 0 { seen[j] = 1; queue.append(j) }
                } }
            }
            let span = Double(max(r - l + 1, bottom - t + 1))
            guard queue.count >= 2, span <= max(12, glyph * 2), regions.contains(where: {
                Double(r) >= $0[0] - glyph && Double(l) <= $0[0] + $0[2] + glyph && Double(bottom) >= $0[1] - glyph && Double(t) <= $0[1] + $0[3] + glyph
            }) else { continue }
            if Double(r) < expandedCard[0] || Double(l) > expandedCard[0] + expandedCard[2] ||
                Double(bottom) < expandedCard[1] || Double(t) > expandedCard[1] + expandedCard[3] { continue }
            let owned = queue.filter { i in others.contains { Double(i % w) >= $0[0] && Double(i % w) < $0[0] + $0[2] && Double(i / w) >= $0[1] && Double(i / w) < $0[1] + $0[3] } }
            if Double(owned.count) >= Double(queue.count) * 0.6 { continue }
            if let fg = sampledForeground, let bg = sampledBackground, fg.count == 3, bg.count == 3,
               fg.allSatisfy(\.isFinite), bg.allSatisfy(\.isFinite), fg.max()! - fg.min()! >= 60 {
                let axis = (0..<3).map { fg[$0] - bg[$0] }, norm = axis.reduce(0) { $0 + $1 * $1 }
                let ink = queue.contains { i in
                    let c = (0..<3).map { Double(original[i * 4 + $0]) }
                    if (0..<3).map({ abs(c[$0] - fg[$0]) }).max()! <= 32 { return true }
                    let f = (0..<3).reduce(0.0) { $0 + (c[$1] - bg[$1]) * axis[$1] } / max(1, norm)
                    return f >= 0.25 && f <= 1.15 && (0..<3).map { abs(c[$0] - bg[$0] - axis[$0] * f) }.max()! <= 18
                }
                if !ink { continue }
            }
            if l < 3 || t < 3 || r > w - 4 || bottom > h - 4 {
                guard continues(queue) else { return nil }; continue
            }
            guard span <= glyph * 1.5 else { return nil }
            let member = Set(queue)
            var halo: [Int] = [], haloSet = Set<Int>()
            for i in queue {
                let x = i % w, y = i / w
                for yy in (y - 3)...(y + 3) { for xx in (x - 3)...(x + 3) {
                    let j = yy * w + xx
                    if !member.contains(j) && max(abs(xx - x), abs(yy - y)) <= 1 && haloSet.insert(j).inserted { halo.append(j) }
                } }
            }
            let near = queue + halo, nearSet = Set(near)
            var ring: [Int] = [], ringSet = Set<Int>()
            for i in near {
                let x = i % w, y = i / w
                for yy in (y - 2)...(y + 2) { for xx in (x - 2)...(x + 2) {
                    let j = yy * w + xx
                    if nearSet.contains(j) || ringSet.contains(j) { continue }
                    guard baseline.safe[j] != 0, original[j * 4 + 3] >= 254 else { return nil }
                    ringSet.insert(j); ring.append(j)
                } }
            }
            guard ring.count >= 8 else { return nil }
            let mean = (0..<3).map { k in ring.reduce(0.0) { $0 + color($1, k) } / Double(ring.count) }
            let deviation = (0..<3).map { k in sqrt(ring.reduce(0.0) { $0 + pow(color($1, k) - mean[k], 2) } / Double(ring.count)) }.max()!
            guard deviation <= 6 else { return nil }
            filled += near.count
            guard Double(filled) <= Double(n) * 0.08 else { return nil }
            fills.append((near, mean))
        }
        var proposed = baseline
        for fill in fills {
            let rgb = fill.mean.map { floor($0 + 0.5) }
            let linear = rgb.map { v -> Double in let c = v / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let light = UInt8(floor(255 * (0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]) + 0.5))
            for i in fill.pixels {
                for k in 0..<3 { proposed.rgba[i * 4 + k] = UInt8(rgb[k]) }
                proposed.rgba[i * 4 + 3] = 255; proposed.safe[i] = 1; proposed.luminance[i] = light
            }
        }
        proposed.residualLettering = false; proposed.surfaceRevision = revision + 1
        guard commit(proposed) else { return nil }
        sourceResidualFilled = filled
        return { [weak self] in
            guard let self else { return }
            var previous = baseline; previous.residualLettering = true
            self.undo(previous); self.sourceResidualFilled = nil
        }
    }
}
