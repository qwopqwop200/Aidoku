import CoreGraphics
import Foundation

/// Source-seeded colour/connectivity evidence, not a physical-interior proof.
/// Never replaces an incumbent: callers must require `available` before using
/// the candidate mask, and retain their independent ownership/admission checks.
enum NativeSourcePixelInterior {
    struct Mask {
        /// Tight integral top-left rectangle in the supplied pixel coordinate space.
        let rect: CGRect
        /// Row-major binary bytes (0/1), rect.width * rect.height samples.
        let bytes: [UInt8]
    }

    struct Report {
        let available: Bool
        let status: String
        /// Diagnostic candidate may exist when available is false. Not admission.
        let mask: Mask?
        let background: [Double]?
        let sampleCount: Int
        let modeCount: Int
        let sourceCoreBackgroundPixels: Int
        let sourceErasedPixels: Int
        let sourceErasedCoverage: Double
        let predictedBoundaryContact: Double
        let predictedBoundaryPixels: Int
        let domainPixels: Int
        let predictedPixels: Int
        let rawBackgroundPixels: Int
        let enclosedErasedPixels: Int
    }

    /// Geometric contour candidate only, after the caller has accepted source
    /// evidence. Fill every complementary 4-connected enclosed hole, including
    /// non-erased ink holes. Never changes make()/Report or grants permission to
    /// cover source ink: original domains and retained-source risk still apply.
    static func outerEnvelope(_ mask: Mask) -> Mask? {
        let rect = mask.rect
        guard [rect.origin.x,rect.origin.y,rect.width,rect.height].allSatisfy(\.isFinite),
              rect == rect.integral, rect.width > 0, rect.height > 0,
              rect.width <= 16_384, rect.height <= 16_384 else { return nil }
        let w = Int(rect.width), h = Int(rect.height)
        guard w <= 16_777_216 / h, mask.bytes.count == w*h,
              mask.bytes.contains(where: { $0 != 0 }) else { return nil }
        var outside = [UInt8](repeating:0,count:w*h), queue: [Int] = []
        func seed(_ p: Int) {
            if mask.bytes[p] == 0 && outside[p] == 0 { outside[p] = 1; queue.append(p) }
        }
        // Boundary zero samples are connected through the implicit padded
        // outside. Cardinal steps preserve foreground8/background4 topology.
        for x in 0..<w { seed(x); seed((h-1)*w+x) }
        for y in 0..<h { seed(y*w); seed(y*w+w-1) }
        var head = 0
        while head < queue.count {
            let p = queue[head]; head += 1
            let x = p % w, y = p / w
            if x > 0 { seed(p-1) }
            if x < w-1 { seed(p+1) }
            if y > 0 { seed(p-w) }
            if y < h-1 { seed(p+w) }
        }
        return Mask(rect:rect,bytes:outside.map { $0 == 0 ? 1 : 0 })
    }

    /// RGB is interleaved, exactly three bytes per pixel. Masks use nonzero as
    /// true. No source RGB, labels, thresholds or geometry are mutated.
    /// Components are 8-connected; the complementary padded-outside flood is
    /// 4-connected, matching cv2.floodFill's default. Erosion is 3x3
    /// with outside-image zero. Bounded to 16M pixels / 16384 per dimension.
    static func make(rgb: [UInt8], width: Int, height: Int, predicted: [UInt8],
                     erased: [UInt8], source: CGRect) -> Report {
        func unknown(_ status: String, samples: Int = 0, mode: Int = 0,
                     background: [Double]? = nil) -> Report {
            Report(available: false, status: status, mask: nil, background: background,
                sampleCount: samples, modeCount: mode, sourceCoreBackgroundPixels: 0,
                sourceErasedPixels: 0, sourceErasedCoverage: 0, predictedBoundaryContact: 0,
                predictedBoundaryPixels: 0, domainPixels: 0, predictedPixels: 0,
                rawBackgroundPixels: 0, enclosedErasedPixels: 0)
        }
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= 16_777_216 / height else { return unknown("invalid-input") }
        let count = width * height
        guard rgb.count == count * 3, predicted.count == count, erased.count == count,
              [source.origin.x, source.origin.y, source.size.width, source.size.height,
               source.origin.x + source.size.width, source.origin.y + source.size.height].allSatisfy(\.isFinite),
              source.size.width > 0, source.size.height > 0 else { return unknown("invalid-input") }
        // Clip in floating point before Int conversion, including finite but
        // enormous source rectangles. No negative Python-slice wrapping.
        func lower(_ x: CGFloat, _ limit: Int) -> Int { Int(min(CGFloat(limit), max(0, ceil(x)))) }
        func upper(_ x: CGFloat, _ limit: Int) -> Int { Int(min(CGFloat(limit), max(0, floor(x)))) }
        let x0 = lower(source.minX, width), y0 = lower(source.minY, height)
        let x1 = upper(source.maxX, width), y1 = upper(source.maxY, height)
        guard x1 > x0, y1 > y0 else { return unknown("insufficient-source-background") }
        func key(_ p: Int) -> Int {
            Int(rgb[p*3] / 16) * 256 + Int(rgb[p*3+1] / 16) * 16 + Int(rgb[p*3+2] / 16)
        }
        var histogram = [Int](repeating: 0, count: 4096), samples = 0
        for y in y0..<y1 { for x in x0..<x1 {
            let p = y * width + x
            if predicted[p] != 0 && erased[p] == 0 { histogram[key(p)] += 1; samples += 1 }
        }}
        guard samples >= 8 else { return unknown("insufficient-source-background", samples: samples) }
        // np.unique + argmax: lowest quantized key wins equal histogram counts.
        var mode = 0
        for k in 1..<histogram.count where histogram[k] > histogram[mode] { mode = k }
        var channels = [[UInt8]](repeating: [], count: 3)
        for c in 0..<3 { channels[c].reserveCapacity(histogram[mode]) }
        for y in y0..<y1 { for x in x0..<x1 {
            let p = y * width + x
            if predicted[p] != 0 && erased[p] == 0 && key(p) == mode {
                for c in 0..<3 { channels[c].append(rgb[p*3+c]) }
            }
        }}
        let color = channels.map { values -> Double in
            let s = values.sorted(), n = s.count
            return n % 2 == 1 ? Double(s[n/2]) : (Double(s[n/2-1]) + Double(s[n/2])) / 2
        }
        var plausible = [UInt8](repeating: 0, count: count)
        for p in 0..<count where predicted[p] != 0 {
            if (0..<3).allSatisfy({ abs(Double(rgb[p*3+$0]) - color[$0]) <= 32 }) { plausible[p] = 1 }
        }
        let cx0 = lower(source.minX + source.width * 0.2, width)
        let cy0 = lower(source.minY + source.height * 0.2, height)
        let cx1 = upper(source.minX + source.width * 0.8, width)
        let cy1 = upper(source.minY + source.height * 0.8, height)
        var labels = [Int32](repeating: 0, count: count), label: Int32 = 0
        var queue: [Int] = [], chosen: Int32 = 0, bestOverlap = 0, bestBlock = Int.max
        // OpenCV's default 8-connected block labeling orders tied components
        // by first occupied 2x2 block, not necessarily first occupied pixel.
        let blockWidth = (width + 1) / 2
        for start in 0..<count where plausible[start] != 0 && labels[start] == 0 {
            label += 1; labels[start] = label; queue.removeAll(keepingCapacity: true); queue.append(start)
            var head = 0, overlap = 0, firstBlock = Int.max
            while head < queue.count {
                let p = queue[head]; head += 1
                let x = p % width, y = p / width
                firstBlock = min(firstBlock, (y / 2) * blockWidth + x / 2)
                if x >= cx0 && x < cx1 && y >= cy0 && y < cy1 { overlap += 1 }
                for yy in max(0,y-1)...min(height-1,y+1) {
                    for xx in max(0,x-1)...min(width-1,x+1) {
                        let q = yy * width + xx
                        if plausible[q] != 0 && labels[q] == 0 { labels[q] = label; queue.append(q) }
                    }
                }
            }
            if overlap > bestOverlap || (overlap > 0 && overlap == bestOverlap && firstBlock < bestBlock) {
                chosen = label; bestOverlap = overlap; bestBlock = firstBlock
            }
        }
        guard chosen != 0 else {
            return unknown("no-background-component-in-source-core", samples: samples,
                mode: histogram[mode], background: color)
        }
        // Equivalent to a 4-connected zero flood from the padded outside.
        var outside = [UInt8](repeating: 0, count: count)
        queue.removeAll(keepingCapacity: true)
        func seedOutside(_ p: Int) {
            if labels[p] != chosen && outside[p] == 0 { outside[p] = 1; queue.append(p) }
        }
        for x in 0..<width { seedOutside(x); seedOutside((height-1)*width+x) }
        for y in 0..<height { seedOutside(y*width); seedOutside(y*width+width-1) }
        var head = 0
        while head < queue.count {
            let p = queue[head]; head += 1
            let x = p % width, y = p / width
            if x > 0 { seedOutside(p-1) }
            if x < width-1 { seedOutside(p+1) }
            if y > 0 { seedOutside(p-width) }
            if y < height-1 { seedOutside(p+width) }
        }
        var result = [UInt8](repeating: 0, count: count)
        var owned = 0, covered = 0, boundary = 0, contact = 0, predictedCount = 0
        var rawCount = 0, holeCount = 0, domain = 0
        var left = width, top = height, right = -1, bottom = -1
        for p in 0..<count {
            let x = p % width, y = p / width
            let component = labels[p] == chosen
            let hole = !component && outside[p] == 0 && erased[p] != 0
            if component { rawCount += 1 }
            if hole { holeCount += 1 }
            let selected = predicted[p] != 0 && (component || hole)
            if selected {
                result[p] = 1; domain += 1
                left = min(left,x); right = max(right,x); top = min(top,y); bottom = max(bottom,y)
            }
            if predicted[p] != 0 {
                predictedCount += 1
                var inner = x > 0 && y > 0 && x < width-1 && y < height-1
                if inner {
                    for yy in y-1...y+1 { for xx in x-1...x+1 where predicted[yy*width+xx] == 0 { inner = false }}
                }
                if !inner { boundary += 1; if selected { contact += 1 } }
                if x >= x0 && x < x1 && y >= y0 && y < y1 && erased[p] != 0 {
                    owned += 1; if selected { covered += 1 }
                }
            }
        }
        let coverage = Double(covered) / Double(max(1,owned))
        let contactRatio = Double(contact) / Double(max(1,boundary))
        let available = coverage >= 0.98 && contactRatio <= 0.05
        var local: [UInt8] = []
        if right >= left {
            local.reserveCapacity((right-left+1)*(bottom-top+1))
            for y in top...bottom { local.append(contentsOf: result[(y*width+left)...(y*width+right)]) }
        }
        let mask: Mask? = right >= left ? Mask(rect: CGRect(x:left,y:top,width:right-left+1,height:bottom-top+1), bytes:local) : nil
        return Report(available: available,
            status: available ? "available" : (owned == 0 ? "empty-source-erased" :
                (coverage < 0.98 ? "insufficient-source-erased-coverage" : "predicted-boundary-contact")),
            mask: mask, background: color, sampleCount: samples, modeCount: histogram[mode],
            sourceCoreBackgroundPixels: bestOverlap, sourceErasedPixels: owned,
            sourceErasedCoverage: coverage, predictedBoundaryContact: contactRatio,
            predictedBoundaryPixels: boundary, domainPixels: domain, predictedPixels: predictedCount,
            rawBackgroundPixels: rawCount, enclosedErasedPixels: holeCount)
    }
}
