import CoreGraphics
import Foundation

/// Repaints only thin source rules that continue beyond both sides of a plate
/// and its source lettering. The scan and Float32 luminance match the frozen
/// frameSource pass; all panels share the same three-million-pixel budget.
enum NativeSourceFrameLines {
    struct Crop {
        let rect: CGRect
        let source: CGRect
        let width: Int
        let height: Int
        let scale: Double
    }
    struct Result {
        let width: Int
        let height: Int
        let rgba: [UInt8]
        let painted: Int
    }

    static func crop(panel: CGRect, source: CGRect, frame: CGRect, imageSize: CGSize,
                     budget: inout Int) -> Crop? {
        guard valid(panel), valid(source), valid(frame), imageSize.width.isFinite,
              imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0,
              panel.width >= 4, panel.height >= 4 else { return nil }
        let scale = max(1, min(3, Double(imageSize.width / frame.width)))
        let left = max(frame.minX, min(panel.minX, source.minX) - 8)
        let top = max(frame.minY, min(panel.minY, source.minY) - 8)
        let right = min(frame.maxX, max(panel.maxX, source.maxX) + 8)
        let bottom = min(frame.maxY, max(panel.maxY, source.maxY) + 8)
        let w = ceil(Double(right - left) * scale), h = ceil(Double(bottom - top) * scale)
        guard w >= 4, h >= 4, w * h <= Double(max(0, budget)) else { return nil }
        let width = Int(w), height = Int(h)
        budget -= width * height
        return Crop(rect: CGRect(x: left, y: top, width: right - left, height: bottom - top),
            source: CGRect(x: (left - frame.minX) / frame.width * imageSize.width,
                y: (top - frame.minY) / frame.height * imageSize.height,
                width: (right - left) / frame.width * imageSize.width,
                height: (bottom - top) / frame.height * imageSize.height),
            width: width, height: height, scale: scale)
    }

    static func restore(crop: Crop, rgba: [UInt8], panel: CGRect, source: CGRect, textBoxes: [CGRect]) -> Result? {
        let w = crop.width, h = crop.height, k = crop.scale
        guard w >= 4, h >= 4, w <= 3_000_000 / h, rgba.count == w * h * 4,
              valid(panel), valid(source), k.isFinite, k >= 1, k <= 3 else { return nil }
        var lum = [Float](repeating: 0, count: w * h)
        for i in lum.indices {
            lum[i] = Float(0.2126 * Double(rgba[i * 4]) + 0.7152 * Double(rgba[i * 4 + 1]) + 0.0722 * Double(rgba[i * 4 + 2]))
        }
        func x(_ value: CGFloat) -> Double { Double(value - crop.rect.minX) * k }
        func y(_ value: CGFloat) -> Double { Double(value - crop.rect.minY) * k }
        let thick = Int(ceil(4.5 * k)), minimumRun = max(12 * k, Double(min(panel.width, panel.height)) * 0.5 * k)
        var line = [UInt8](repeating: 0, count: w * h), found = 0
        for horizontal in [true, false] {
            let outer = horizontal ? h : w, inner = horizontal ? w : h
            guard thick < outer - thick else { continue }
            let lo = min(horizontal ? x(panel.minX) : y(panel.minY), horizontal ? x(source.minX) : y(source.minY)) - 4 * k
            let hi = max(horizontal ? x(panel.maxX) : y(panel.maxY), horizontal ? x(source.maxX) : y(source.maxY)) + 4 * k
            let plateLo = horizontal ? x(panel.minX) : y(panel.minY), plateHi = horizontal ? x(panel.maxX) : y(panel.maxY)
            for o in thick..<(outer - thick) {
                var start = -1
                for q in 0...inner {
                    let dark = q < inner && lum[horizontal ? o * w + q : q * w + o] < 110
                    if dark && start < 0 { start = q }
                    if dark || start < 0 { continue }
                    let end = q
                    if Double(end - start) >= minimumRun, Double(start) <= lo, Double(end) >= hi,
                       Double(start) < plateHi, Double(end) > plateLo {
                        var sides = 0
                        for s in start..<end {
                            let before = horizontal ? (o - thick) * w + s : s * w + o - thick
                            let after = horizontal ? (o + thick) * w + s : s * w + o + thick
                            if lum[before] > 150 && lum[after] > 150 { sides += 1 }
                        }
                        if Double(sides) >= Double(end - start) * 0.6 {
                            for s in start..<end { line[horizontal ? o * w + s : s * w + o] = 1 }
                            found += end - start
                        }
                    }
                    start = -1
                }
            }
        }
        guard Double(found) >= minimumRun else { return nil }
        let pwValue = max(1, floor(Double(panel.width) * k + 0.5))
        let phValue = max(1, floor(Double(panel.height) * k + 0.5))
        guard pwValue * phValue <= 3_000_000 else { return nil }
        let pw = Int(pwValue), ph = Int(phValue), ox = Int(floor(x(panel.minX) + 0.5)), oy = Int(floor(y(panel.minY) + 0.5))
        var keep = [UInt8](repeating: 0, count: pw * ph)
        for r in textBoxes where valid(r) {
            let x0 = Int(max(0, min(Double(pw), floor(Double(r.minX - 2 - panel.minX) * k))))
            let x1 = Int(max(0, min(Double(pw), ceil(Double(r.maxX + 2 - panel.minX) * k))))
            let y0 = Int(max(0, min(Double(ph), floor(Double(r.minY - 1 - panel.minY) * k))))
            let y1 = Int(max(0, min(Double(ph), ceil(Double(r.maxY + 1 - panel.minY) * k))))
            guard x0 < x1, y0 < y1 else { continue }
            for row in y0..<y1 { keep.replaceSubrange((row * pw + x0)..<(row * pw + x1), with: repeatElement(1, count: x1 - x0)) }
        }
        var out = [UInt8](repeating: 0, count: pw * ph * 4), painted = 0
        for yy in 0..<ph { for xx in 0..<pw {
            let sx = xx + ox, sy = yy + oy
            guard keep[yy * pw + xx] == 0, sx >= 0, sy >= 0, sx < w, sy < h else { continue }
            let at = sy * w + sx
            var near = line[at] == 1
            if !near && lum[at] < 200 {
                for dy in -1...1 where !near { for dx in -1...1 where !near {
                    let nx = sx + dx, ny = sy + dy
                    if nx >= 0, ny >= 0, nx < w, ny < h, line[ny * w + nx] == 1 { near = true }
                } }
            }
            guard near else { continue }
            let target = (yy * pw + xx) * 4
            for channel in 0..<3 { out[target + channel] = rgba[at * 4 + channel] }
            out[target + 3] = 255
            painted += 1
        } }
        return painted == 0 ? nil : Result(width: pw, height: ph, rgba: out, painted: painted)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite) && rect.size.width > 0 && rect.size.height > 0
    }
}
