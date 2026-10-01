import CoreGraphics
import Foundation

/// Bounded glyph-shaped artwork repair for a plate no source restorer accepted.
/// Raw buffers use Canvas ImageData's straight RGBA contract throughout.
enum NativeGlyphCover {
    struct Matrix {
        var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0
        var is2D = true
        var inverse: Self {
            let det = a * d - b * c
            return .init(a: d / det, b: -b / det, c: -c / det, d: a / det,
                         e: (c * f - d * e) / det, f: (b * e - a * f) / det, is2D: is2D)
        }
    }
    struct Plate {
        var rect: CGRect
        var size: CGSize
        var origin: CGPoint
        var transformOrigin: CGPoint
        var transform = Matrix()
        var connected = true
        var parentIsRoot = true
        var backgroundRGBA: [Double]
        var hasBackgroundImage = false
        var frameLines = false
        var foreignFills = false
        var displayed = true
        var visible = true
        var hasShadow = false
        var borderTop = 0.0
        var borderLeft = 0.0
        var nodeIsChild = false
        var ownedNodeCount = 0
        var hasOwnBacking = false
        var backgroundSharedWithAnotherPlate = false
        var clipped = false
        var coverage: [[Double]]?
    }
    struct Entry {
        var id: String
        var text: String
        var mode: String
        var record: [String: Any]?
        var sampledInk: [Double]?
        var displayGroup = false
        var sourceBounds: [Double]
        var sourceFrame: [Double]
        var sourceFontSize: Double?
        var fontSize: Double
        var plate: Plate?
        var otherCaptionInks: [CGRect] = []
        var otherSourceRects: [CGRect] = []
    }
    struct Scene {
        var opacity = 1.0
        var inpaintingEnabled = true
        var preserveSourceText = true
        var preserveSourceBackground = true
        var sourceComplete = true
        var imageSize: CGSize
        var itemCount: Int
        var cleanupFrame: [Double]?
    }
    final class Budget {
        var pixels = 65_536
        var analysed = 0
        var covers = 0
    }
    struct Result {
        var width: Int
        var height: Int
        var rgba: [UInt8]
        var cover: [UInt8]
        var letters: [UInt8]
        var art: [UInt8]
        var sourceCrop: CGRect
        var viewportRect: CGRect
        var foreground: [Double]
        var outline: [Double]
        var outlineWidth: Double
        var metadata: [String: Any]
        var image: CGImage? {
            guard let provider = CGDataProvider(data: Data(rgba) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }
    struct Attempt {
        var result: Result?
        var rejection: String?
    }
    private struct Pixels {
        var rgba: [UInt8]
        var full: [UInt8]
        var width: Int
        var height: Int
        var sourceWidth: Int
        var sourceHeight: Int
        var scale: Double
        var glyph: Double
        var inPlate: [UInt8]
        var inBox: [UInt8]
        var inZone: [UInt8]
        var core: [Double]
        var outline: [Double]
        var surface: [Double]?
        var bandWidth: Double
        var frameLines: Bool
    }
    private struct Paint {
        var rgba: [UInt8]
        var cover: [UInt8]
        var letters: [UInt8]
        var art: [UInt8]
        var plateCount: Int
        var coverCount: Int
        var texture: Double
        var surfaces: Int
        var edgeKind: String?
        var edgeResidual: Double?
    }
    private static func rgb(_ value: Any?) -> [Double]? {
        let colors: [Double]?
        if let value = value as? [Double] { colors = value }
        else if let value = value as? [NSNumber] { colors = value.map(\.doubleValue) }
        else { colors = nil }
        guard let colors, colors.count == 3, colors.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }) else { return nil }
        return colors
    }
    private static func gap(_ a: [Double], _ b: [Double]) -> Double { max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2])) }
    private static func luminance(_ rgb: [Double]) -> Double {
        let values = rgb.map { v -> Double in let c = v / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]
    }
    private static func byte(_ value: Double) -> UInt8 { UInt8(min(255, max(0, floor(value + 0.5)))) }
    private static func truthyNumber(_ value: Double?, fallback: Double = 0) -> Double {
        value.flatMap { $0 == 0 || $0.isNaN ? nil : $0 } ?? fallback
    }
    private static func rect(_ values: [Double]) -> Bool { values.count == 4 && values.allSatisfy(\.isFinite) }
    private static func whitespaced(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (9...13).contains(v) || v == 32 || v == 160 || v == 5760 || (8192...8202).contains(v) ||
            v == 8232 || v == 8233 || v == 8239 || v == 8287 || v == 12288 || v == 65279
    }

    static func attempt(entry: Entry, scene: Scene, budget: Budget,
                        readSource: (_ crop: CGRect, _ width: Int, _ height: Int) throws -> [UInt8]) rethrows -> Attempt {
        func reject(_ reason: String) -> Attempt { .init(result: nil, rejection: reason) }
        guard scene.opacity == 1, scene.inpaintingEnabled, scene.preserveSourceText, scene.preserveSourceBackground,
              scene.sourceComplete, scene.imageSize.width > 0, scene.imageSize.height > 0, scene.itemCount <= 256 else { return .init() }
        guard entry.mode == "readability-panel" || entry.mode == "rotated-panel" else { return .init() }
        if entry.displayGroup { return reject("display-group") }
        let count = entry.text.unicodeScalars.filter { !whitespaced($0) }.count
        if count == 0 || count > 16 { return reject("text") }
        guard let record = entry.record, let core = rgb(record["core"]), let outline = rgb(record["outline"]) else { return reject("no-pair") }
        let surface = (record["surface"] as? [NSNumber])?.map(\.doubleValue) ?? record["surface"] as? [Double]
        if let surface, surface.count > 3, surface[3] == 1 { return reject("flat-surface") }
        let cl = luminance(core), ol = luminance(outline)
        if (max(cl, ol) + 0.05) / (min(cl, ol) + 0.05) < 3 { return reject("pair-contrast") }
        if let sampled = rgb(entry.sampledInk), gap(sampled, core) > 60 && gap(sampled, outline) > 60 { return reject("pair-disagrees") }
        guard let plate = entry.plate, plate.connected, plate.parentIsRoot else { return reject("owner") }
        let frameLines = plate.frameLines && !plate.foreignFills
        if plate.backgroundRGBA.count < 3 || (plate.backgroundRGBA.count > 3 && plate.backgroundRGBA[3] < 1) ||
            (plate.hasBackgroundImage && !frameLines) || !plate.displayed || !plate.visible || plate.hasShadow ||
            plate.borderTop > 0 || plate.borderLeft > 0 { return reject("plate-style") }
        if plate.ownedNodeCount > (plate.nodeIsChild ? 1 : 0) || plate.hasOwnBacking || plate.backgroundSharedWithAnotherPlate { return reject("shared") }
        let b = entry.sourceBounds, f = scene.cleanupFrame ?? entry.sourceFrame
        let glyphCSS = (entry.sourceFontSize ?? 0) > 0 ? entry.sourceFontSize! :
            (b.count == 4 && f.count == 4 ? min(b[2] * f[2], b[3] * f[3]) * 0.7 : .nan)
        guard rect(b), rect(f), b[2] > 0, b[3] > 0, f[2] > 0, f[3] > 0, glyphCSS >= 20 else { return reject("glyph") }
        func meets(_ r: CGRect) -> Bool { r.minX < plate.rect.maxX && plate.rect.minX < r.maxX && r.minY < plate.rect.maxY && plate.rect.minY < r.maxY }
        if entry.otherCaptionInks.contains(where: meets) { return reject("other-caption") }
        if entry.otherSourceRects.contains(where: meets) { return reject("other-source") }
        let W = Double(plate.size.width), H = Double(plate.size.height)
        if W < 4 || H < 4 { return reject("size") }
        let X = Double(plate.origin.x), Y = Double(plate.origin.y), ox = Double(plate.transformOrigin.x), oy = Double(plate.transformOrigin.y), M = plate.transform
        guard M.is2D, ox.isFinite, oy.isFinite else { return reject("transform") }
        let Mi = M.inverse, iw = Double(scene.imageSize.width), ih = Double(scene.imageSize.height)
        let coverage: [[Double]]?
        if plate.clipped && entry.mode != "rotated-panel" {
            guard let spans = plate.coverage?.filter(rect), !spans.isEmpty else { return reject("clip") }; coverage = spans
        } else { coverage = nil }
        func toClient(_ u: Double, _ v: Double) -> [Double] { [X + ox + M.a * (u - ox) + M.c * (v - oy) + M.e, Y + oy + M.b * (u - ox) + M.d * (v - oy) + M.f] }
        let corners = [[0.0, 0], [W, 0], [W, H], [0, H]].map { v -> [Double] in let p = toClient(v[0], v[1]); return [(p[0] - f[0]) / f[2] * iw, (p[1] - f[1]) / f[3] * ih] }
        let glyphPx = glyphCSS * iw / f[2], margin = max(6, glyphPx * 0.4)
        let x0 = max(0, floor(corners.map { $0[0] }.min()! - margin)), y0 = max(0, floor(corners.map { $0[1] }.min()! - margin))
        let x1 = min(iw, ceil(corners.map { $0[0] }.max()! + margin)), y1 = min(ih, ceil(corners.map { $0[1] }.max()! + margin))
        let sw = x1 - x0, sh = y1 - y0
        guard [x0, y0, sw, sh].allSatisfy(\.isFinite), sw >= 8, sh >= 8 else { return reject("size") }
        let k = min(1, 40 / glyphPx, sqrt(81_920 / (sw * sh)))
        let w = max(1, Int(floor(sw * k + 0.5))), h = max(1, Int(floor(sh * k + 0.5))), n = w * h, g = glyphPx * k
        if g < 10 { return reject("resolution") }
        if sw * sh > 1_048_576 { return reject("size") }
        if n > budget.pixels { return reject("budget") }
        budget.pixels -= n; budget.analysed += 1
        let crop = CGRect(x: x0, y: y0, width: sw, height: sh), rgba = try readSource(crop, w, h)
        let full = k < 1 ? try readSource(crop, Int(sw), Int(sh)) : rgba
        guard rgba.count == n * 4, full.count == Int(sw * sh) * 4 else { return reject("source") }
        let cA = f[2] / (iw * k), cB = f[0] + (x0 + 0.5 / k) / iw * f[2], dA = f[3] / (ih * k), dB = f[1] + (y0 + 0.5 / k) / ih * f[3]
        let ua = Mi.a * cA, ub = Mi.c * dA, uc = Mi.a * (cB - X - ox) + Mi.c * (dB - Y - oy) + Mi.e + ox
        let va = Mi.b * cA, vb = Mi.d * dA, vc = Mi.b * (cB - X - ox) + Mi.d * (dB - Y - oy) + Mi.f + oy
        let spans = coverage?.map { r in [(r[0] - cB) / cA, (r[0] + r[2] - cB) / cA, (r[1] - dB) / dA, (r[1] + r[3] - dB) / dA] }
        let pad = max(2, g * 0.15), bx0 = (b[0] * iw - x0) * k - pad, by0 = (b[1] * ih - y0) * k - pad
        let bx1 = ((b[0] + b[2]) * iw - x0) * k + pad, by1 = ((b[1] + b[3]) * ih - y0) * k + pad
        let zp = g * 0.35, zx0 = bx0 - zp + pad, zy0 = by0 - zp + pad, zx1 = bx1 + zp - pad, zy1 = by1 + zp - pad
        var inPlate = [UInt8](repeating: 0, count: n), inBox = inPlate, inZone = inPlate
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x, xc = Double(x) + 0.5, yc = Double(y) + 0.5, u = ua * Double(x) + ub * Double(y) + uc, v = va * Double(x) + vb * Double(y) + vc
            if u >= 0 && v >= 0 && u <= W && v <= H && (spans == nil || spans!.contains { Double(x) >= $0[0] && Double(x) <= $0[1] && Double(y) >= $0[2] && Double(y) <= $0[3] }) { inPlate[i] = 1 }
            if yc >= by0 && yc <= by1 && xc >= bx0 && xc <= bx1 { inBox[i] = 1 }
            if yc >= zy0 && yc <= zy1 && xc >= zx0 && xc <= zx1 { inZone[i] = 1 }
        } }
        let input = Pixels(rgba: rgba, full: full, width: w, height: h, sourceWidth: Int(sw), sourceHeight: Int(sh), scale: k, glyph: g,
            inPlate: inPlate, inBox: inBox, inZone: inZone, core: core, outline: outline, surface: surface.flatMap { $0.count >= 3 ? Array($0.prefix(3)) : nil },
            bandWidth: truthyNumber((record["width"] as? NSNumber)?.doubleValue), frameLines: frameLines)
        let outcome = paint(input)
        guard let p = outcome.paint else { return reject(outcome.rejection!) }
        let left = f[0] + x0 / iw * f[2], top = f[1] + y0 / ih * f[3], width = sw / iw * f[2], height = sh / ih * f[3]
        let fontSize = truthyNumber(entry.fontSize, fallback: 10), band = max(1, input.bandWidth * glyphCSS)
        let strokeWidth = max(2, min(fontSize * 0.2, max(fontSize * 0.1, band * 2)))
        let cssPerCrop = (f[2] / iw / k) * (f[3] / ih / k)
        var metadata: [String: Any] = ["area": floor(Double(p.plateCount) * cssPerCrop + 0.5), "cover": floor(Double(p.coverCount) * cssPerCrop + 0.5),
            "plate": Array(plate.backgroundRGBA.prefix(3)), "texture": floor(p.texture * 10 + 0.5) / 10, "surfaces": p.surfaces, "edge": p.edgeKind != nil]
        if let kind = p.edgeKind, kind != "line" { metadata["fit"] = kind; metadata["residual"] = floor(p.edgeResidual! * 10 + 0.5) / 10 }
        budget.covers += 1
        return .init(result: .init(width: w, height: h, rgba: p.rgba, cover: p.cover, letters: p.letters, art: p.art, sourceCrop: crop,
            viewportRect: CGRect(x: left, y: top, width: width, height: height), foreground: core, outline: outline,
            outlineWidth: floor(strokeWidth * 4 + 0.5) / 4, metadata: metadata), rejection: nil)
    }
    private static func distance(_ mask: [UInt8], _ w: Int, _ h: Int) -> [Float] {
        var d = mask.map { $0 != 0 ? Float(0) : Float(1e9) }
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x; var v = Double(d[i]); if v == 0 { continue }
            if x > 0 { v = min(v, Double(d[i-1])+1) }
            if y > 0 { v = min(v, Double(d[i-w])+1); if x > 0 { v = min(v, Double(d[i-w-1])+1.4142) }; if x < w-1 { v = min(v, Double(d[i-w+1])+1.4142) } }
            d[i] = Float(v)
        } }
        for y in stride(from:h-1, through:0, by:-1) { for x in stride(from:w-1, through:0, by:-1) {
            let i = y*w+x; var v = Double(d[i]); if v == 0 { continue }
            if x < w-1 { v = min(v, Double(d[i+1])+1) }
            if y < h-1 { v = min(v, Double(d[i+w])+1); if x < w-1 { v = min(v, Double(d[i+w+1])+1.4142) }; if x > 0 { v = min(v, Double(d[i+w-1])+1.4142) } }
            d[i] = Float(v)
        } }
        return d
    }
    private struct Level { var values:[Float]; var weights:[Float]; var width:Int; var height:Int }
    private static func diffuse(_ values:[Float], _ channels:Int, _ w:Int, _ h:Int, _ weights:[Float], _ need:[UInt8]?) -> [Float] {
        var levels = [Level(values:values,weights:weights,width:w,height:h)]
        while let p = levels.last, p.width > 2 || p.height > 2 {
            let nw = max(1,(p.width+1)/2), nh = max(1,(p.height+1)/2)
            var q = Level(values:[Float](repeating:0,count:nw*nh*channels),weights:[Float](repeating:0,count:nw*nh),width:nw,height:nh)
            for y in 0..<p.height { for x in 0..<p.width {
                let a = y*p.width+x, t = (y/2)*nw+x/2; if p.weights[a] <= 0 { continue }
                q.weights[t] += p.weights[a]
                for c in 0..<channels { q.values[t*channels+c] += p.values[a*channels+c] }
            } }; levels.append(q)
        }
        if levels.count > 1 { for l in stride(from:levels.count-2,through:0,by:-1) {
            let p = levels[l+1]; var q = levels[l]
            for y in 0..<q.height {
                let fy = max(0,min(Double(p.height-1),(Double(y)+0.5)/2-0.5)), iy = Int(floor(fy)), jy = min(p.height-1,iy+1), ty = fy-Double(iy)
                for x in 0..<q.width {
                    let a = y*q.width+x; if q.weights[a] > 0 || (l == 0 && need != nil && need![a] == 0) { continue }
                    let fx = max(0,min(Double(p.width-1),(Double(x)+0.5)/2-0.5)), ix = Int(floor(fx)), jx = min(p.width-1,ix+1), tx = fx-Double(ix)
                    var sum = 0.0, pix = [Float](repeating:0,count:channels)
                    for k in 0..<4 {
                        let px = k&1 != 0 ? jx:ix, py = k&2 != 0 ? jy:iy
                        let weight = (k&1 != 0 ? tx:1-tx)*(k&2 != 0 ? ty:1-ty), t = py*p.width+px, pw = Double(p.weights[t])
                        if pw <= 0 || weight <= 0 { continue }
                        for c in 0..<channels { pix[c] = Float(Double(pix[c])+weight*Double(p.values[t*channels+c])/pw) }; sum += weight
                    }
                    if sum <= 0 { continue }
                    for c in 0..<channels { q.values[a*channels+c] = Float(Double(pix[c])/sum) }; q.weights[a] = 1
                }
            }; levels[l] = q
        } }
        return levels[0].values
    }
    private static func colours(_ rgba:[UInt8], _ known:[UInt8]) -> ([Float],[Float]) {
        var values = [Float](repeating:0,count:known.count*3), weights = [Float](repeating:0,count:known.count)
        for i in known.indices where known[i] != 0 { for c in 0..<3 { values[i*3+c] = Float(rgba[i*4+c]) }; weights[i] = 1 }
        return (values,weights)
    }
    private static func paint(_ input:Pixels) -> (paint:Paint?,rejection:String?) {
        func reject(_ r:String) -> (paint:Paint?,rejection:String?) { (nil,r) }
        let rgba = input.rgba, w = input.width, h = input.height, n = w*h, g = input.glyph, k = input.scale
        let inPlate = input.inPlate, inBox = input.inBox, inZone = input.inZone, outline = input.outline
        var dc = [Int](repeating:0,count:n), dout = dc, bins = dc, exterior = [Double](repeating:0,count:512)
        var exteriorCount = 0, plateCount = 0, artHits = 0
        for i in 0..<n {
            let p = i*4, r = Int(rgba[p]), gg = Int(rgba[p+1]), b = Int(rgba[p+2])
            dc[i] = Int(gap([Double(r),Double(gg),Double(b)],input.core)); dout[i] = Int(gap([Double(r),Double(gg),Double(b)],outline))
            bins[i] = (r>>5)*64+(gg>>5)*8+(b>>5)
            plateCount += Int(inPlate[i])
            if inZone[i] == 0 { exterior[bins[i]] += 1; exteriorCount += 1; if dc[i] <= 48 { artHits += 1 } }
        }
        if plateCount < 64 { return reject("size") }
        if exteriorCount >= 64 && Double(artHits) > Double(exteriorCount)*0.15 { return reject("core-in-art") }
        var rare = [UInt8](repeating:0,count:512)
        if exteriorCount >= 64 { for q in 0..<512 { rare[q] = exterior[q]/Double(exteriorCount) < 0.002 ? 1:0 } }
        var seed = [UInt8](repeating:0,count:n), letters = seed, art = seed, crossed = seed, label = [Int](repeating:0,count:n)
        for i in 0..<n where inPlate[i] != 0 && (dc[i] <= 48 || (inBox[i] != 0 && rare[bins[i]] != 0)) { seed[i] = 1 }
        func neighbours4(_ i:Int) -> [Int] { let x = i%w; return [x > 0 ? i-1:-1,x < w-1 ? i+1:-1,i-w,i+w].filter { $0 >= 0 && $0 < n } }
        func neighbours8(_ i:Int) -> [Int] {
            let x = i%w; var result:[Int] = []
            for dy in -1...1 { for dx in -1...1 { let j = i+dy*w+dx; if (dx != 0 || dy != 0) && x+dx >= 0 && x+dx < w && j >= 0 && j < n { result.append(j) } } }; return result
        }
        var crossedCount = 0, crossing = 0, next = 0
        for s in 0..<n where seed[s] != 0 && label[s] == 0 {
            next += 1; var stack = [s], members:[Int] = [], edge = false; label[s] = next
            while let i = stack.popLast() {
                members.append(i)
                for j in neighbours4(i) {
                    if inPlate[j] == 0 && dc[j] <= 48 { edge = true }
                    if seed[j] != 0 && label[j] == 0 { label[j] = next; stack.append(j) }
                }
            }
            if edge && Double(members.count) > g*g*0.02 { for i in members { crossed[i] = 1 }; crossedCount += members.count }
            else { for i in members { letters[i] = 1 } }
        }
        if crossedCount > 0 { let touch = distance(letters,w,h), reach = max(2,g*0.08)
            for i in 0..<n where crossed[i] != 0 { if inBox[i] != 0 && Double(touch[i]) <= reach { letters[i] = 1; crossing += 1 } else { art[i] = 1 } }
        }
        let coreCount = letters.reduce(0) { $0+($1 != 0 ? 1:0) }
        if coreCount < 24 { return reject("no-core") }
        if Double(crossing) > Double(coreCount)*0.5 { return reject("art-crossing") }
        if input.frameLines && crossing != 0 { return reject("frame-line") }
        if crossedCount > 0 {
            let coreMask = letters.map { UInt8($0 == 1 ? 1:0) }, innerCore = distance(coreMask.map { $0 != 0 ? 0:1 },w,h), innerArt = distance(art.map { $0 != 0 ? 0:1 },w,h)
            let depths = innerCore.indices.filter { coreMask[$0] != 0 }.map { Double(innerCore[$0]) }.sorted()
            let stroke = depths.isEmpty ? 0:depths[Int(floor(Double(depths.count)*0.9))]
            let thick = (0..<n).filter { art[$0] != 0 && inZone[$0] != 0 && Double(innerArt[$0]) >= max(1.5,stroke*0.6) }.count
            if Double(thick) > max(4,Double(coreCount)*0.02) { return reject("thick-crossing") }
        }
        var queue:[Int] = []
        let toCore = distance(letters,w,h), ring = min(g*0.2,max(2,input.bandWidth*g+2))
        for i in 0..<n where toCore[i] <= 1.5 && inPlate[i] != 0 && letters[i] == 0 && art[i] == 0 && dout[i] <= 56 { letters[i] = 2; queue.append(i) }
        var head = 0
        while head < queue.count { let i = queue[head]; head += 1
            for j in neighbours8(i) where inPlate[j] != 0 && letters[j] == 0 && art[j] == 0 && Double(toCore[j]) <= ring && dout[j] <= 56 { letters[j] = 2; queue.append(j) }
        }
        if let surface = input.surface, gap(surface,outline) >= 48 {
            let d = (0..<3).map { outline[$0]-surface[$0] }, n2 = d.reduce(0) { $0+$1*$1 }
            func toward(_ i:Int) -> Double { let r = (0..<3).map { Double(rgba[i*4+$0])-surface[$0] }, t = (r[0]*d[0]+r[1]*d[1]+r[2]*d[2])/n2
                let off = sqrt(max(0,r[0]*r[0]+r[1]*r[1]+r[2]*r[2]-t*t*n2)); return off <= 40 ? t:0 }
            var steps = [Int](repeating:0,count:n); let limit = max(2,Int(floor(g*0.15+0.5)))
            queue = (0..<n).filter { letters[$0] == 2 }; head = 0
            while head < queue.count { let i = queue[head]; head += 1; if steps[i] >= limit { continue }
                for j in neighbours4(i) where letters[j] == 0 && art[j] == 0 && inPlate[j] != 0 && toward(j) >= 0.2 { letters[j] = 2; steps[j] = steps[i]+1; queue.append(j) }
            }
        }
        var palette = [UInt8](repeating:0,count:512), counts = [Int](repeating:0,count:512), total = 0
        for i in 0..<n where letters[i] == 1 { counts[bins[i]] += 1; total += 1 }
        for q in 0..<512 { palette[q] = Double(counts[q]) >= Double(total)*0.01 ? 1:0 }
        func lettering(_ i:Int) -> Bool { dout[i] > 56 && (palette[bins[i]] == 1 || (inBox[i] != 0 && rare[bins[i]] == 1)) }
        let rounds = min(40,max(3,Int(ceil(g*0.5/1.5)))); var depth = [Int](repeating:0,count:n)
        queue = (0..<n).filter { letters[$0] != 0 }; head = 0
        while head < queue.count { let i = queue[head]; head += 1; if depth[i] >= rounds { continue }
            for j in neighbours8(i) where letters[j] == 0 && art[j] == 0 && inPlate[j] != 0 && inZone[j] != 0 && lettering(j) { letters[j] = 3; depth[j] = depth[i]+1; queue.append(j) }
        }
        for i in 0..<n where letters[i] == 0 && art[i] == 0 && inPlate[i] != 0 && inBox[i] != 0 && lettering(i) { letters[i] = 4 }
        let grow = max(1.5,g*0.025), toLetters = distance(letters,w,h)
        var cover = toLetters.map { UInt8(Double($0) <= grow ? 1:0) }
        label = [Int](repeating:0,count:n); next = 0
        for s in 0..<n where cover[s] == 0 && label[s] == 0 {
            next += 1; var stack = [s], members:[Int] = [], edge = false; label[s] = next
            while let i = stack.popLast() { let x = i%w,y = i/w; members.append(i); if x == 0 || y == 0 || x == w-1 || y == h-1 { edge = true }
                for j in neighbours4(i) where cover[j] == 0 && label[j] == 0 { label[j] = next; stack.append(j) }
            }
            if !edge && Double(members.count) <= max(9,g*g*0.12) { for i in members { cover[i] = 1 } }
        }
        if Double((0..<n).filter { cover[$0] != 0 && inPlate[$0] != 0 }.count) > Double(plateCount)*0.8 { return reject("area") }
        let near0 = distance(cover,w,h), halo = g*0.12, before = cover, base = cover.reduce(0) { $0+Int($1) }
        var known = [UInt8](repeating:0,count:n), need = known
        for i in 0..<n {
            if cover[i] == 0 && letters[i] == 0 && art[i] == 0 && Double(near0[i]) > halo { known[i] = 1 }
            else if cover[i] == 0 && inPlate[i] != 0 && art[i] == 0 && Double(near0[i]) <= halo { need[i] = 1 }
        }
        var (values,weights) = colours(rgba,known); let local = diffuse(values,3,w,h,weights,need)
        for i in 0..<n where need[i] != 0 {
            let pixel = (0..<3).map { Double(rgba[i*4+$0]) }, localColor = (0..<3).map { Double(local[i*3+$0]) }
            if gap(pixel,localColor) > 10 && Double(dout[i]) < gap(localColor,outline)-6 { cover[i] = 1 }
        }
        var grown = cover
        for i in 0..<n where cover[i] == 0 && inPlate[i] != 0 && art[i] == 0 { if neighbours4(i).contains(where: { cover[$0] != 0 }) { grown[i] = 1 } }
        cover = grown
        let after = cover.reduce(0) { $0+Int($1) }
        if Double(after) > Double(base)*1.25 || Double(after) > Double(plateCount)*0.8 { cover = before }
        let toCover = distance(cover,w,h)
        var exposed = 0, coverCount = 0
        for i in 0..<n where inPlate[i] != 0 { if cover[i] != 0 { coverCount += 1 } else if art[i] == 0 && (dc[i] <= 48 || (inZone[i] != 0 && lettering(i))) { exposed += 1 } }
        if exposed > 0 { return reject("exposed") }
        var histogram = [Int](repeating:0,count:1024); total = 0
        let reach = max(1.5,3*k), sw = input.sourceWidth, sh = input.sourceHeight
        for i in 0..<n where cover[i] == 0 && Double(toCover[i]) <= reach && inPlate[i] != 0 && art[i] == 0 {
            let x = min(sw-2,max(1,Int(floor((Double(i%w)+0.5)/k)))), y = min(sh-2,max(1,Int(floor((Double(i/w)+0.5)/k)))), c = (y*sw+x)*4
            var sum = 0
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 { let p = c+(dy*sw+dx)*4; sum += Int(input.full[p])+Int(input.full[p+1])+Int(input.full[p+2]) } }
            let detail = abs(Double(Int(input.full[c])+Int(input.full[c+1])+Int(input.full[c+2]))-Double(sum)/8)/3
            histogram[min(1023,Int(floor(detail*4)))] += 1; total += 1
        }
        func quantile(_ t:Double) -> Double { let goal = Int(floor(Double(total)*t)); var seen = 0; for q in 0..<1024 { seen += histogram[q]; if seen > goal { return Double(q)/4 } }; return 256 }
        let texture = total > 0 ? max(quantile(0.75),quantile(0.9)/2):0
        if texture > 6 { return reject("texture") }
        if Double(coverCount) > Double(plateCount)*0.8 { return reject("area") }
        known = [UInt8](repeating:0,count:n); need = known
        for i in 0..<n { if cover[i] != 0 { need[i] = 1 } else if letters[i] == 0 && toCover[i] > 2 && !(art[i] != 0 && Double(toCover[i]) <= g*0.1) { known[i] = 1 } }
        let ringReach = max(3,g*0.15)
        let ringCount = (0..<n).filter { known[$0] != 0 && Double(toCover[$0]) <= ringReach+2 }.count, step = max(1,ringCount/2048)
        var sample:[Int] = [], seen = 0
        for i in 0..<n where known[i] != 0 && Double(toCover[i]) <= ringReach+2 { if seen%step == 0 { sample.append(i*4) }; seen += 1 }
        func far2(_ p:Int,_ c:[Double]) -> Double { let a = Double(rgba[p])-c[0], b = Double(rgba[p+1])-c[1], d = Double(rgba[p+2])-c[2]; return a*a+b*b+d*d }
        var centres:[[Double]] = [], ringSpread = 0.0
        func nearest(_ p:Int) -> Int { var best = 0, bestD = Double.infinity; for c in centres.indices { let d = far2(p,centres[c]); if d < bestD { bestD = d; best = c } }; return best }
        if sample.count >= 32 {
            let mean = (0..<3).map { c in sample.reduce(0.0) { $0+Double(rgba[$1+c]) }/Double(sample.count) }
            func farthest(_ list:[[Double]]) -> [Double] { var best = sample[0], bestD = -1.0; for p in sample { let d = list.map { far2(p,$0) }.min()!; if d > bestD { bestD = d; best = p } }; return (0..<3).map { Double(rgba[best+$0]) } }
            centres = [farthest([mean])]; centres.append(farthest(centres)); centres.append(farthest(centres))
            for round in 0..<8 {
                var sums = centres.map { _ in [Double](repeating:0,count:3) }, counts = centres.map { _ in 0 }
                for p in sample { let c = nearest(p); for channel in 0..<3 { sums[c][channel] += Double(rgba[p+channel]) }; counts[c] += 1 }
                var changed = false, next:[[Double]] = []
                for c in centres.indices { if counts[c] == 0 { changed = true; continue }; next.append(sums[c].map { $0/Double(counts[c]) }) }
                for c in next.indices where !changed { if gap(next[c],centres[c]) > 0.5 { changed = true } }; centres = next
                var merged = false
                for a in centres.indices { if merged { break }; for b in (a+1)..<centres.count { if gap(centres[a],centres[b]) < 40 { centres[a] = (0..<3).map { (centres[a][$0]+centres[b][$0])/2 }; centres.remove(at:b); merged = true; break } } }
                if !merged && round >= 2 { counts = centres.map { _ in 0 }; for p in sample { counts[nearest(p)] += 1 }; if let small = counts.firstIndex(where: { Double($0) < Double(sample.count)*0.06 }), centres.count > 1 { centres.remove(at:small); changed = true } }
                if !changed && !merged && round >= 2 { break }
            }
            let own = sample.map { sqrt(far2($0,centres[nearest($0)])) }.sorted(); ringSpread = own[Int(floor(Double(own.count)*0.75))]
        }
        if ringSpread > 55 { return reject("busy") }
        if !centres.isEmpty {
            var kept = 0, all = 0, keep = [UInt8](repeating:0,count:n)
            for i in 0..<n where known[i] != 0 { all += 1; let rgb = (0..<3).map { Double(rgba[i*4+$0]) }; if centres.contains(where: { gap(rgb,$0) <= 64 }) { keep[i] = 1; kept += 1 } }
            if Double(kept) >= Double(all)*0.5 { known = keep }
        }
        (values,weights) = colours(rgba,known); let diffused = diffuse(values,3,w,h,weights,need)
        let edgeResult = edgeFill(rgba:rgba, known:known, need:need, toCover:toCover, sample:sample, centres:centres, colours:diffused, w:w,h:h,g:g,ringReach:ringReach)
        if edgeResult.rejected { return reject("haze") }
        let finalColours = edgeResult.colours
        var output = [UInt8](repeating:0,count:n*4)
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x; var sum = 0
            for dy in -1...1 { let yy = y+dy; if yy < 0 || yy >= h { continue }; for dx in -1...1 { let xx = x+dx; if xx >= 0 && xx < w { sum += Int(cover[yy*w+xx]) } } }
            if sum == 0 { continue }
            var best = cover[i] != 0 ? i:-1
            if best < 0 { for dy in -1...1 { if best >= 0 { break }; for dx in -1...1 { let yy = y+dy, xx = x+dx; if yy >= 0 && yy < h && xx >= 0 && xx < w && cover[yy*w+xx] != 0 { best = yy*w+xx; break } } } }
            for c in 0..<3 { output[i*4+c] = byte(finalColours[best*3+c]) }; output[i*4+3] = byte(min(1,Double(sum)/9*1.5)*255)
        } }
        return (Paint(rgba:output,cover:cover,letters:letters,art:art,plateCount:plateCount,coverCount:coverCount,texture:texture,surfaces:centres.count,edgeKind:edgeResult.kind,edgeResidual:edgeResult.residual),nil)
    }
    private struct Edge { var a:Int; var b:Int; var distance:(Double,Double)->Double; var flip:Bool; var kind:String; var residual:Double? }
    private struct EdgeOutput { var colours:[Double]; var rejected:Bool; var kind:String?; var residual:Double? }
    private static func edgeFill(rgba:[UInt8],known:[UInt8],need:[UInt8],toCover:[Float],sample:[Int],centres:[[Double]],colours:[Float],w:Int,h:Int,g:Double,ringReach:Double) -> EdgeOutput {
        let n = w*h
        func far2(_ p:Int,_ c:[Double]) -> Double { let r = Double(rgba[p])-c[0], gg = Double(rgba[p+1])-c[1], b = Double(rgba[p+2])-c[2]; return r*r+gg*gg+b*b }
        var edge:Edge?, rejected = false
        for a in centres.indices { if rejected { break }; for b in (a+1)..<centres.count {
            if rejected { break }
            let A = centres[a], B = centres[b], difference = gap(A,B); if difference < 64 { continue }
            let e = (0..<3).map { A[$0]-B[$0] }, e2 = e[0]*e[0]+e[1]*e[1]+e[2]*e[2], off = max(16,difference*0.25)
            func mixed(_ r:Double,_ gg:Double,_ bb:Double) -> Bool {
                let t = ((r-B[0])*e[0]+(gg-B[1])*e[1]+(bb-B[2])*e[2])/e2
                if t <= 0.2 || t >= 0.8 { return false }
                return max(abs(r-B[0]-t*e[0]),abs(gg-B[1]-t*e[1]),abs(bb-B[2]-t*e[2])) <= off
            }
            let ringMixed = sample.filter { mixed(Double(rgba[$0]),Double(rgba[$0+1]),Double(rgba[$0+2])) }.count
            if Double(ringMixed) > Double(sample.count)*0.2 { continue }
            var coverMixed = 0, coverAll = 0
            for i in 0..<n where need[i] != 0 { coverAll += 1; if mixed(Double(colours[i*3]),Double(colours[i*3+1]),Double(colours[i*3+2])) { coverMixed += 1 } }
            if Double(coverMixed) < Double(coverAll)*0.08+Double(ringMixed)/Double(sample.count)*Double(coverAll) { continue }
            if centres.count != 2 { rejected = true; break }
            let span = ringReach*2+2
            var side = [Int](repeating:-1,count:n), points:[[Double]] = [], sideCount = 0
            for i in 0..<n where known[i] != 0 && Double(toCover[i]) <= span { side[i] = far2(i*4,A) <= far2(i*4,B) ? 0:1 }
            for i in 0..<n where side[i] >= 0 {
                sideCount += 1; let x = i%w
                if (x < w-1 && side[i+1] >= 0 && side[i+1] != side[i]) || (i+w < n && side[i+w] >= 0 && side[i+w] != side[i]) { points.append([Double(x)+0.5,Double(i/w)+0.5]) }
            }
            if points.count < 6 { rejected = true; break }
            let mx = points.reduce(0.0) { $0+$1[0] }/Double(points.count), my = points.reduce(0.0) { $0+$1[1] }/Double(points.count)
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for p in points { sxx += (p[0]-mx)*(p[0]-mx); syy += (p[1]-my)*(p[1]-my); sxy += (p[0]-mx)*(p[1]-my) }
            let angle = atan2(2*sxy,sxx-syy)/2, tolerance = max(1.5,g*0.06)
            func agreement(_ distance:(Double,Double)->Double,_ band:Double) -> (flip:Bool,consistent:Double,total:Int) {
                var agree = 0,total = 0
                for i in 0..<n where side[i] >= 0 { let d = distance(Double(i%w)+0.5,Double(i/w)+0.5); if abs(d) < band { continue }; total += 1; if (d > 0) == (side[i] == 0) { agree += 1 } }
                return (Double(agree) < Double(total)/2,Double(max(agree,total-agree))/Double(max(1,total)),total)
            }
            let nx = -sin(angle), ny = cos(angle)
            let lineDistance:(Double,Double)->Double = { ($0-mx)*nx+($1-my)*ny }
            let lineResidual = sqrt(points.reduce(0.0) { $0+pow(lineDistance($1[0],$1[1]),2) }/Double(points.count)), lineFit = agreement(lineDistance,1)
            if lineFit.total >= 32 && lineFit.consistent >= 0.95 && lineResidual <= tolerance { edge = Edge(a:a,b:b,distance:lineDistance,flip:lineFit.flip,kind:"line",residual:nil) }
            if edge == nil { for (theta,degree) in [(angle,1),(angle,2),(0.0,2),(Double.pi/2,2)] {
                let ax = cos(theta), ay = sin(theta), nx = -ay, ny = ax, count = points.count,size = degree+1
                var scale = 1.0
                for p in points { scale = max(scale,abs((p[0]-mx)*ax+(p[1]-my)*ay)) }
                let ts = points.map { (($0[0]-mx)*ax+($0[1]-my)*ay)/scale }, ds = points.map { ($0[0]-mx)*nx+($0[1]-my)*ny }
                var errors = [Double](repeating:0,count:count), inlier = [UInt8](repeating:1,count:count), c = [0.0,0,0], solved = true, residual = Double.infinity, kept = 0
                for round in 0..<3 {
                    if !solved { break }
                    var m = [Double](repeating:0,count:9), r = [Double](repeating:0,count:3)
                    for p in 0..<count where inlier[p] != 0 { let t = ts[p], row = [1,t,t*t]
                        for u in 0..<size { r[u] += row[u]*ds[p]; for v in 0..<size { m[u*3+v] += row[u]*row[v] } }
                    }
                    for col in 0..<size {
                        if !solved { break }; var pivot = col
                        if col+1 < size { for u in (col+1)..<size where abs(m[u*3+col]) > abs(m[pivot*3+col]) { pivot = u } }
                        if abs(m[pivot*3+col]) < 1e-9 { solved = false; break }
                        if pivot != col { for v in 0..<3 { m.swapAt(col*3+v,pivot*3+v) }; r.swapAt(col,pivot) }
                        if col+1 < size { for u in (col+1)..<size { let q = m[u*3+col]/m[col*3+col]; for v in col..<size { m[u*3+v] -= q*m[col*3+v] }; r[u] -= q*r[col] } }
                    }
                    if !solved { break }
                    c[2] = 0
                    for u in stride(from:size-1,through:0,by:-1) { var v = r[u]; if u+1 < size { for z in (u+1)..<size { v -= m[u*3+z]*c[z] } }; c[u] = v/m[u*3+u] }
                    for p in 0..<count { let t = ts[p], slope = (c[1]+2*c[2]*t)/scale; errors[p] = abs(ds[p]-c[0]-c[1]*t-c[2]*t*t)/sqrt(1+slope*slope) }
                    let sorted = errors.sorted(), cut = max(round < 2 ? tolerance:tolerance*2,round < 2 ? sorted[min(count-1,Int(floor(Double(count)*0.7)))]:0)
                    var sum = 0.0; kept = 0
                    for p in 0..<count { inlier[p] = errors[p] <= cut ? 1:0; if inlier[p] != 0 { kept += 1; sum += errors[p]*errors[p] } }
                    residual = kept > 0 ? sqrt(sum/Double(kept)):.infinity
                }
                if !solved || Double(kept) < Double(count)*0.6 || kept < 6 || residual > tolerance { continue }
                let c0 = c[0], c1 = c[1], c2 = c[2], fitScale = scale
                let along:(Double,Double)->Double = { (($0-mx)*ax+($1-my)*ay)/fitScale }
                let distance:(Double,Double)->Double = { x,y in let t = along(x,y), slope = (c1+2*c2*t)/fitScale; return ((x-mx)*nx+(y-my)*ny-c0-c1*t-c2*t*t)/sqrt(1+slope*slope) }
                var tIn = Double.infinity, tOut = -Double.infinity
                for i in 0..<n where need[i] != 0 { let x = Double(i%w)+0.5,y = Double(i/w)+0.5; if abs(distance(x,y)) <= 1 { let t = along(x,y); tIn = min(tIn,t); tOut = max(tOut,t) } }
                if tIn <= tOut {
                    let reach = (span*2+1)/fitScale, slack = 1/fitScale; var before = 0,after = 0
                    for p in 0..<count where inlier[p] != 0 { let t = ts[p]; if t <= tIn+slack && t >= tIn-reach { before += 1 }; if t >= tOut-slack && t <= tOut+reach { after += 1 } }
                    if before < 3 || after < 3 { continue }
                    let sagitta = abs(c2)*pow((tOut-tIn)/2,2), chord = (tOut-tIn)*fitScale
                    if sagitta > max(1,chord/3) { continue }
                }
                let fit = agreement(distance,tolerance)
                if fit.total < 32 || Double(fit.total) < Double(sideCount)*0.8 || fit.consistent < 0.95 { continue }
                edge = Edge(a:a,b:b,distance:distance,flip:fit.flip,kind:degree == 1 ? "robust-line":"curve",residual:residual); break
            } }
            if edge == nil { rejected = true; break }
        } }
        if rejected { return .init(colours:[],rejected:true) }
        var result = colours.map(Double.init)
        if let edge {
            let ownSide = edge.kind != "line", sign = edge.flip ? -1.0:1.0
            var fills:[[Float]] = []
            for c in [edge.a,edge.b] {
                var mask = [UInt8](repeating:0,count:n); let toward = c == edge.a ? sign:-sign, other = c == edge.a ? edge.b:edge.a
                for i in 0..<n where known[i] != 0 {
                    if far2(i*4,centres[c]) > far2(i*4,centres[other]) { continue }
                    if ownSide && edge.distance(Double(i%w)+0.5,Double(i/w)+0.5)*toward < 1 { continue }; mask[i] = 1
                }
                let (values,weights) = self.colours(rgba,mask); fills.append(diffuse(values,3,w,h,weights,need))
            }
            for i in 0..<n { let d = edge.distance(Double(i%w)+0.5,Double(i/w)+0.5)*(edge.flip ? -1:1), t = max(0,min(1,d+0.5))
                for c in 0..<3 { result[i*3+c] = Double(fills[0][i*3+c])*t+Double(fills[1][i*3+c])*(1-t) }
            }
        }
        return .init(colours:result,rejected:false,kind:edge?.kind,residual:edge?.residual)
    }
}
