import CoreGraphics
import Foundation

/// Frozen final display lettering restoration. Its output is a transparent
/// owned repaint; acceptance of actual translated ink remains the caller's trial.
enum NativeDisplayLetteringPixels {
    struct Result {
        var reject: String?
        var output: [UInt8] = []
        var fill: [Double]? = nil
        var outline: [Double]? = nil
        var width: Double = 0
        var masked: Double = 0
        var polarity: String? = nil
        var ends: Bool? = nil
        var halo: [String: Double]? = nil
        var stats: [String: Any]? = nil
        init(reject: String? = nil) { self.reject = reject }
    }
    static func valid(_ rgba: [UInt8], _ w: Int, _ h: Int, _ glyph: Double) -> Bool {
        w > 0 && h > 0 && w <= 393216 / h && rgba.count == w * h * 4 && glyph.isFinite && glyph > 0
    }
    static func fixed(_ value: Double, _ digits: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }
    static func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded(.toNearestOrEven)))) }
    static func neighbours(_ i: Int, _ w: Int, _ n: Int) -> [Int] {
        let x = i % w
        return [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, i - w, i + w].filter { $0 >= 0 && $0 < n }
    }
    static func inside(_ w: Int, _ h: Int, _ box: CGRect) -> ([UInt8], Int) {
        let x0 = max(0, floor(Double(box.minX) + 0.5)), y0 = max(0, floor(Double(box.minY) + 0.5))
        let x1 = min(Double(w), floor(Double(box.maxX) + 0.5)), y1 = min(Double(h), floor(Double(box.maxY) + 0.5))
        var mask = [UInt8](repeating: 0, count: w * h), count = 0
        for y in 0..<h { for x in 0..<w where Double(x) >= x0 && Double(x) < x1 && Double(y) >= y0 && Double(y) < y1 {
            mask[y*w+x] = 1; count += 1
        } }
        return (mask, count)
    }
    static func distance(_ source: [UInt8], _ w: Int, _ h: Int) -> [Float] {
        let n = w*h; var d = source.map { Float($0 != 0 ? 0 : 1e9) }
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x; var v = Double(d[i])
            if x > 0 { v = min(v,Double(d[i-1])+3) }
            if y > 0 { v = min(v,Double(d[i-w])+3); if x > 0 { v = min(v,Double(d[i-w-1])+4) }; if x < w-1 { v = min(v,Double(d[i-w+1])+4) } }
            d[i] = Float(v)
        } }
        for y in (0..<h).reversed() { for x in (0..<w).reversed() {
            let i = y*w+x; var v = Double(d[i])
            if x < w-1 { v = min(v,Double(d[i+1])+3) }
            if y < h-1 { v = min(v,Double(d[i+w])+3); if x < w-1 { v = min(v,Double(d[i+w+1])+4) }; if x > 0 { v = min(v,Double(d[i+w-1])+4) } }
            d[i] = Float(v)
        } }
        for i in 0..<n { d[i] = Float(Double(d[i])/3) }
        return d
    }
    static func median(_ rgba: [UInt8], _ select: (Int)->Bool) -> [Double]? {
        var counts = Array(repeating: [Int](repeating: 0, count: 256), count: 3), total = 0
        for i in 0..<rgba.count/4 where select(i) { total += 1; for c in 0..<3 { counts[c][Int(rgba[i*4+c])] += 1 } }
        guard total > 0 else { return nil }
        return counts.map { list in var sum = 0; for v in 0..<256 { sum += list[v]; if sum*2 >= total { return Double(v) } }; return 255 }
    }
    static func near(_ p: [UInt8], _ i: Int, _ rgb: [Double], _ threshold: Double) -> Bool {
        rgb.count == 3 && (0..<3).allSatisfy { abs(Double(p[i*4+$0])-rgb[$0]) <= threshold }
    }
    static func floodOutside(_ barrier: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        let n = w*h; var open = [UInt8](repeating: 0,count: n), queue: [Int] = []
        for i in 0..<n where (i%w == 0 || i < w || i%w == w-1 || i >= n-w) && barrier[i] == 0 { open[i] = 1; queue.append(i) }
        var head = 0
        while head < queue.count { let i = queue[head]; head += 1
            for j in neighbours(i,w,n) where open[j] == 0 && barrier[j] == 0 { open[j] = 1; queue.append(j) }
        }
        return open
    }
    static func colour(rgba p: [UInt8], width w: Int, height h: Int, box: CGRect, glyph: Double,
                       surface: [Double]? = nil, text: [Double]? = nil) -> Result {
        guard valid(p,w,h,glyph) else { return .init(reject: "size") }
        let n = w*h, (inside,boxCount) = inside(w,h,box), ringCount = n-boxCount
        guard boxCount >= 64 && ringCount >= 64 else { return .init(reject: "size") }
        var bins = [Int](repeating: 0,count: n), bh = [Double](repeating: 0,count: 512), rh = bh
        for i in 0..<n { let q = Int(p[i*4]>>5)*64+Int(p[i*4+1]>>5)*8+Int(p[i*4+2]>>5); bins[i] = q
            if inside[i] != 0 { bh[q] += 1 } else { rh[q] += 1 }
        }
        var candidate = [UInt8](repeating: 0,count: 512), share = 0.0
        for q in 0..<512 { let pb = bh[q]/Double(boxCount), pr = rh[q]/Double(ringCount)
            let r = (q>>6)*32+16, g = ((q>>3)&7)*32+16, b = (q&7)*32+16
            if pb >= 0.01 && pb/(pr+0.001) >= 4 && max(r,g,b)-min(r,g,b) >= 64 { candidate[q] = 1; share += pb }
        }
        if share < 0.03 || share > 0.45 { return .init(reject: "share \(fixed(share,3))") }
        var fill = (0..<n).map { UInt8(inside[$0] != 0 && candidate[bins[$0]] != 0 ? 1 : 0) }
        guard let fillRGB = median(p,{ fill[$0] != 0 }), fillRGB.max()!-fillRGB.min()! >= 60 else { return .init(reject: "chroma") }
        if let surface, nearRGB(surface,fillRGB,48) { return .init(reject: "surface") }
        var dist = distance(fill,w,h)
        fill = (0..<n).map { UInt8(fill[$0] != 0 || (dist[$0] <= 3 && near(p,$0,fillRGB,70)) ? 1 : 0) }
        dist = distance(fill,w,h)
        guard let outlineRGB = median(p,{ dist[$0] > 1 && dist[$0] <= 3 }) else { return .init(reject: "outline") }
        let colour = (0..<n).map { UInt8(fill[$0] != 0 || near(p,$0,fillRGB,48) ? 1 : 0) }, open = floodOutside(colour,w,h)
        var band = 0, enclosed = 0
        for i in 0..<n where dist[i] > 1 && dist[i] <= 3 { band += 1; if open[i] == 0 { enclosed += 1 } }
        if band > 0 && Double(enclosed) > Double(band)*0.5 { return .init(reject: "enclosed") }
        if let text, let surface, nearRGB(text,outlineRGB,48) && nearRGB(surface,fillRGB,80) { return .init(reject: "ink-is-band") }
        func ringShare(_ from: Double,_ to: Double,_ rgb: [Double]) -> Double {
            var all = 0, close = 0
            for i in 0..<n where Double(dist[i]) > from && Double(dist[i]) <= to { all += 1; if near(p,i,rgb,60) { close += 1 } }
            return all > 0 ? Double(close)/Double(all) : 0
        }
        var width = 1.0, d = 2.0
        while d <= max(3,glyph*0.25) { if ringShare(d-1,d,outlineRGB) < 0.5 { break }; width = d; d += 1 }
        if width < 2 || width >= glyph*0.25 || ringShare(width+3,width+5,outlineRGB) >= 0.5 { return .init(reject: "band \(Int(width))") }
        var mask = [UInt8](repeating: 0,count: n), masked = 0, residual = 0
        for i in 0..<n { if Double(dist[i]) <= width+3 { mask[i] = 1; if inside[i] != 0 { masked += 1 } }
            else if inside[i] != 0 && near(p,i,fillRGB,40) { residual += 1 }
        }
        if Double(masked) > Double(boxCount)*0.85 || Double(residual) > Double(boxCount)*0.001 {
            return .init(reject: "residual \(fixed(Double(masked)/Double(boxCount),2)) \(fixed(Double(residual)/Double(boxCount),4))")
        }
        var leftover = [Double](repeating: 0,count: 512)
        for i in 0..<n where inside[i] != 0 && mask[i] == 0 && Double(dist[i]) <= width+3+max(2,glyph*0.1) { leftover[bins[i]] += 1 }
        for q in 0..<512 { let pb = leftover[q]/Double(boxCount), pr = rh[q]/Double(ringCount)
            if pb >= 0.004 && pb/(pr+0.001) >= 4 { return .init(reject: "leftover \(q) \(fixed(pb,3))") }
        }
        let halo = width+3+max(2,floor(glyph*0.1+0.5)), outer = halo+2+max(4,floor(glyph*0.3+0.5))
        let ring = (0..<n).filter { Double(dist[$0]) > halo+2 && Double(dist[$0]) <= outer }
        guard !ring.isEmpty else { return .init(reject: "ring") }
        let surfaceRGB = (0..<3).map { c in Double(ring.map { p[$0*4+c] }.sorted()[ring.count>>1]) }
        let surfaceL = surfaceRGB[0]*0.299+surfaceRGB[1]*0.587+surfaceRGB[2]*0.114
        let flatShare = Double(ring.filter { near(p,$0,surfaceRGB,24) }.count)/Double(ring.count), flat = flatShare >= 0.65
        var values = [Float](repeating: 0,count: n*3), known = [UInt8](repeating: 0,count: n)
        for i in 0..<n {
            let l = Double(p[i*4])*0.299+Double(p[i*4+1])*0.587+Double(p[i*4+2])*0.114
            known[i] = dist[i] > Float(halo+2) && !(flat && l < surfaceL-48) ? 1 : 0
            for c in 0..<3 { values[i*3+c] = Float(p[i*4+c]) }
        }
        guard NativeSlantedInkSafety.pushPull(values: &values,known: known,width: w,height: h) else { return .init(reject: "diffusion") }
        var result = Result(); result.output = [UInt8](repeating: 0,count: n*4)
        for i in 0..<n where Double(dist[i]) <= halo { for c in 0..<3 { result.output[i*4+c] = byte(Double(values[i*3+c])) }; result.output[i*4+3] = 255 }
        result.fill = fillRGB; result.outline = outlineRGB; result.width = width; result.masked = Double(masked)/Double(boxCount)
        result.halo = ["flat": floor(flatShare*100+0.5)/100]
        return result
    }
    static func nearRGB(_ a: [Double],_ b: [Double],_ threshold: Double) -> Bool {
        a.count == 3 && b.count == 3 && (0..<3).allSatisfy { abs(a[$0]-b[$0]) <= threshold }
    }
}
