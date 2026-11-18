import CoreGraphics
import Foundation

/// Original closed-colour barrier evidence only, never a physical certificate or
/// permission to move/erase an owner. Does not invoke constant-background evidence.
enum NativeSourceClosedBarrierInterior {
    struct Limits {
        var maxPixelsPerPolarity: Int = 4_000_000
        /// Charged pixel operations, including the fixed neighbour fan-out.
        var maxWorkUnits: Int = 128_000_000
    }

    struct Report {
        let available: Bool
        let status: String
        /// Tight binary mask in ROI-local coordinates; nil on every rejection.
        let mask: NativeSourcePixelInterior.Mask?
        let evidenceKind: String
        /// Counts and ratios only. Availability is not independent admission.
        let metrics: [String: Double]
    }

    private enum Stop: Error {
        case cancelled, budget
    }

    private final class Work {
        let limit: Int
        let isCancelled: () -> Bool
        var used = 0
        private var nextPoll = 0

        init(limit: Int, isCancelled: @escaping () -> Bool) {
            self.limit = limit
            self.isCancelled = isCancelled
        }

        func spend(_ amount: Int = 1) throws {
            if used >= nextPoll {
                if isCancelled() { throw Stop.cancelled }
                nextPoll = used + 1_024
            }
            guard amount <= limit - used else { throw Stop.budget }
            used += amount
        }

        func poll() throws {
            if isCancelled() { throw Stop.cancelled }
        }
    }

    private struct Domain {
        let mask: NativeSourcePixelInterior.Mask
        let pixels: Int
        let sourceCoverage: Double
        let predictedAgreement: Double
        let predictedCoverage: Double

        var associated: Bool {
            sourceCoverage >= 0.9 && predictedAgreement >= 0.6 && predictedCoverage >= 0.3
        }
    }

    /// Association arbitration is kept separate from topology so independent
    /// synthetic association records can exercise ambiguity rejection as well
    /// as the raster smoke. Neither bbox potential nor filled area is a seed.
    struct AssociationSelection {
        private(set) var eligibleComponents = 0
        var ambiguous: Bool { eligibleComponents > 1 }

        static func hasSourceSupport(componentSourceHits: Int, sourcePixels: Int) -> Bool {
            sourcePixels > 0 && componentSourceHits >= 0 && componentSourceHits <= sourcePixels &&
                Double(componentSourceHits) >= 0.25 * Double(sourcePixels)
        }

        mutating func consider(componentSourceHits: Int, sourcePixels: Int, sourceCoverage: Double,
                               predictedAgreement: Double, predictedCoverage: Double) -> Bool {
            guard Self.hasSourceSupport(componentSourceHits: componentSourceHits, sourcePixels: sourcePixels),
                  [sourceCoverage, predictedAgreement, predictedCoverage].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                  sourceCoverage >= 0.9, predictedAgreement >= 0.6, predictedCoverage >= 0.3 else { return false }
            eligibleComponents += 1
            return true
        }
    }

    /// RGB is interleaved original RGB, exactly 3*w*h bytes. Predicted uses
    /// nonzero=true, exactly w*h bytes, and is an association hint, not a clip.
    /// Source is ROI-local and must be wholly contained, before rasterization.
    /// Source samples match the numerical probe: ceil(min)..<floor(max).
    /// The caller must independently prove the decoded source ROI fully opaque;
    /// RGB itself carries no opacity evidence. No inputs or runtime state mutate.
    ///
    /// Complement components use 8-connectivity, then fill complementary holes
    /// using 4-connectivity. Any component touching the ROI edge is excluded.
    /// Original component overlap with the source samples must be >= .25 BEFORE
    /// envelope filling. Surrounding rings cannot manufacture seed support by
    /// filling their holes. Every eligible supported component is considered.
    /// Multiple eligible components in either polarity reject the whole result.
    /// Dual-polarity domains require IoU >= .8 and use only their intersection,
    /// which must independently pass all three association thresholds again.
    static func make(rgb: [UInt8], width: Int, height: Int, predicted: [UInt8],
                     source: CGRect, sourceOpaque: Bool, limits: Limits = Limits(),
                     isCancelled: () -> Bool = { false }) -> Report {
        var metrics: [String: Double] = [:]
        let kind = "source-closed-colour-barrier"
        func report(_ status: String, domain: Domain? = nil) -> Report {
            if let domain {
                metrics["domainPixels"] = Double(domain.pixels)
                metrics["sourceCoverage"] = domain.sourceCoverage
                metrics["predictedAgreement"] = domain.predictedAgreement
                metrics["predictedCoverage"] = domain.predictedCoverage
            }
            return Report(available: domain != nil, status: status, mask: domain?.mask,
                          evidenceKind: kind, metrics: metrics)
        }
        guard limits.maxPixelsPerPolarity > 0, limits.maxPixelsPerPolarity <= 4_000_000,
              limits.maxWorkUnits > 0, limits.maxWorkUnits <= 128_000_000 else {
            return report("invalid-limits")
        }
        guard width > 0, height > 0 else { return report("invalid-input") }
        guard height <= limits.maxPixelsPerPolarity,
              width <= limits.maxPixelsPerPolarity / height else { return report("pixel-budget-exceeded") }
        let count = width * height
        guard rgb.count == count * 3, predicted.count == count else { return report("invalid-input") }
        let sx = source.origin.x, sy = source.origin.y
        let sw = source.size.width, sh = source.size.height
        let ex = sx + sw, ey = sy + sh
        guard [sx, sy, sw, sh, ex, ey].allSatisfy(\.isFinite), sw > 0, sh > 0 else {
            return report("invalid-source")
        }
        guard sx >= 0, sy >= 0, ex <= CGFloat(width), ey <= CGFloat(height) else {
            return report("source-roi-truncated")
        }
        guard sourceOpaque else { return report("opacity-unknown") }
        let x0 = Int(ceil(sx)), y0 = Int(ceil(sy)), x1 = Int(floor(ex)), y1 = Int(floor(ey))
        guard x1 > x0, y1 > y0 else { return report("empty-source-samples") }
        let sourcePixels = (x1 - x0) * (y1 - y0)
        metrics["sourcePixels"] = Double(sourcePixels)
        metrics["roiPixelsPerPolarity"] = Double(count)
        // withoutActuallyEscaping keeps the public cancellation closure nonescaping.
        return withoutActuallyEscaping(isCancelled) { cancellation in
            let work = Work(limit: limits.maxWorkUnits, isCancelled: cancellation)
            func finish(_ status: String, domain: Domain? = nil) -> Report {
                metrics["workUnits"] = Double(work.used)
                return report(status, domain: domain)
            }
            do {
                var predictedPixels = 0
                for value in predicted {
                    try work.spend()
                    if value != 0 { predictedPixels += 1 }
                }
                metrics["predictedPixels"] = Double(predictedPixels)
                guard predictedPixels > 0 else { return finish("empty-predicted") }

                func measure(_ bytes: [UInt8], left: Int, top: Int, w: Int, h: Int) throws -> Domain {
                    var area = 0, sourceHits = 0, predictedHits = 0
                    var minX = w, minY = h, maxX = 0, maxY = 0
                    for y in 0..<h { for x in 0..<w {
                        try work.spend()
                        if bytes[y*w+x] == 0 { continue }
                        let gx = left+x, gy = top+y
                        area += 1
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                        if gx >= x0 && gx < x1 && gy >= y0 && gy < y1 { sourceHits += 1 }
                        if predicted[gy*width+gx] != 0 { predictedHits += 1 }
                    }}
                    var mask = NativeSourcePixelInterior.Mask(rect: CGRect(x: left, y: top, width: w, height: h), bytes: bytes)
                    if area > 0 && (minX != 0 || minY != 0 || maxX != w-1 || maxY != h-1) {
                        let tw = maxX-minX+1, th = maxY-minY+1
                        var tight = [UInt8](repeating: 0, count: tw*th)
                        for y in 0..<th { for x in 0..<tw {
                            try work.spend()
                            tight[y*tw+x] = bytes[(minY+y)*w+minX+x]
                        }}
                        mask = .init(rect: CGRect(x: left+minX, y: top+minY, width: tw, height: th), bytes: tight)
                    }
                    return Domain(mask: mask,
                                  pixels: area, sourceCoverage: Double(sourceHits)/Double(sourcePixels),
                                  predictedAgreement: area > 0 ? Double(predictedHits)/Double(area) : 0,
                                  predictedCoverage: Double(predictedHits)/Double(predictedPixels))
                }

                func polarity(white: Bool) throws -> (Domain?, Bool) {
                    let prefix = white ? "white224" : "black48"
                    var barrier = [UInt8](repeating: 0, count: count)
                    for p in 0..<count {
                        try work.spend()
                        let r = rgb[3*p], g = rgb[3*p+1], b = rgb[3*p+2]
                        if white ? (r >= 224 && g >= 224 && b >= 224) : (r <= 48 && g <= 48 && b <= 48) {
                            barrier[p] = 1
                        }
                    }
                    var labels = [Int32](repeating: 0, count: count), label: Int32 = 0
                    var queue: [Int] = [], chosen: Domain?
                    var edges = 0, envelopes = 0, unsupported = 0, chosenSourceHits = 0
                    var selection = AssociationSelection()
                    defer {
                        metrics[prefix + "Components"] = Double(label)
                        metrics[prefix + "ROIEdgeComponents"] = Double(edges)
                        metrics[prefix + "EnvelopesChecked"] = Double(envelopes)
                        metrics[prefix + "EligibleComponents"] = Double(selection.eligibleComponents)
                        metrics[prefix + "UnsupportedComponents"] = Double(unsupported)
                    }
                    for start in 0..<count {
                        try work.spend()
                        if barrier[start] != 0 || labels[start] != 0 { continue }
                        label += 1
                        labels[start] = label
                        queue.removeAll(keepingCapacity: true)
                        queue.append(start)
                        var head = 0, left = width, right = 0, top = height, bottom = 0, edge = false
                        var componentSourceHits = 0
                        while head < queue.count {
                            try work.spend(9)
                            let p = queue[head]; head += 1
                            let x = p % width, y = p / width
                            if x >= x0 && x < x1 && y >= y0 && y < y1 { componentSourceHits += 1 }
                            left = min(left, x); right = max(right, x)
                            top = min(top, y); bottom = max(bottom, y)
                            if x == 0 || x == width-1 || y == 0 || y == height-1 { edge = true }
                            for yy in max(0, y-1)...min(height-1, y+1) {
                                for xx in max(0, x-1)...min(width-1, x+1) {
                                    let q = yy*width+xx
                                    if barrier[q] == 0 && labels[q] == 0 {
                                        labels[q] = label
                                        queue.append(q)
                                    }
                                }
                            }
                        }
                        if edge { edges += 1; continue }
                        guard AssociationSelection.hasSourceSupport(componentSourceHits: componentSourceHits,
                                                                   sourcePixels: sourcePixels) else {
                            unsupported += 1
                            continue
                        }
                        let potential = max(0, min(right+1, x1)-max(left, x0)) * max(0, min(bottom+1, y1)-max(top, y0))
                        if Double(potential)/Double(sourcePixels) < 0.9 { continue }
                        envelopes += 1
                        let w = right-left+1, h = bottom-top+1
                        var domain = [UInt8](repeating: 0, count: w*h)
                        for y in 0..<h { for x in 0..<w {
                            try work.spend()
                            if labels[(top+y)*width+left+x] == label { domain[y*w+x] = 1 }
                        }}
                        // Flood the complementary four-connected outside. The
                        // implicit padded border connects all zero edge samples.
                        var outside = [UInt8](repeating: 0, count: w*h)
                        queue.removeAll(keepingCapacity: true)
                        func seed(_ p: Int) {
                            if domain[p] == 0 && outside[p] == 0 { outside[p] = 1; queue.append(p) }
                        }
                        for x in 0..<w {
                            try work.spend(2)
                            seed(x); seed((h-1)*w+x)
                        }
                        for y in 0..<h {
                            try work.spend(2)
                            seed(y*w); seed(y*w+w-1)
                        }
                        head = 0
                        while head < queue.count {
                            try work.spend(5)
                            let p = queue[head]; head += 1
                            let x = p % w, y = p / w
                            if x > 0 { seed(p-1) }
                            if x < w-1 { seed(p+1) }
                            if y > 0 { seed(p-w) }
                            if y < h-1 { seed(p+w) }
                        }
                        for p in 0..<domain.count {
                            try work.spend()
                            domain[p] = outside[p] == 0 ? 1 : 0
                        }
                        let candidate = try measure(domain, left: left, top: top, w: w, h: h)
                        if selection.consider(componentSourceHits: componentSourceHits, sourcePixels: sourcePixels,
                                              sourceCoverage: candidate.sourceCoverage,
                                              predictedAgreement: candidate.predictedAgreement,
                                              predictedCoverage: candidate.predictedCoverage) {
                            if selection.ambiguous { return (nil, true) }
                            chosen = candidate
                            chosenSourceHits = componentSourceHits
                        }
                    }
                    if let chosen {
                        metrics[prefix + "DomainPixels"] = Double(chosen.pixels)
                        metrics[prefix + "SourceCoverage"] = chosen.sourceCoverage
                        metrics[prefix + "PredictedAgreement"] = chosen.predictedAgreement
                        metrics[prefix + "PredictedCoverage"] = chosen.predictedCoverage
                        metrics[prefix + "ComponentSourceHits"] = Double(chosenSourceHits)
                        metrics[prefix + "ComponentSourceSupport"] = Double(chosenSourceHits)/Double(sourcePixels)
                    }
                    return (chosen, false)
                }

                let (white, whiteAmbiguous) = try polarity(white: true)
                guard !whiteAmbiguous else { return finish("ambiguous-white224") }
                let (black, blackAmbiguous) = try polarity(white: false)
                guard !blackAmbiguous else { return finish("ambiguous-black48") }
                var selected: Domain
                var status: String
                if let white, let black {
                    let a = white.mask, b = black.mask
                    let rect = a.rect.intersection(b.rect)
                    guard !rect.isNull, rect.width > 0, rect.height > 0 else {
                        return finish("polarity-conflict")
                    }
                    let left = Int(rect.minX), top = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
                    let aw = Int(a.rect.width), bw = Int(b.rect.width)
                    var bytes = [UInt8](repeating: 0, count: w*h), hits = 0
                    for y in 0..<h { for x in 0..<w {
                        try work.spend()
                        let ai = (top+y-Int(a.rect.minY))*aw+left+x-Int(a.rect.minX)
                        let bi = (top+y-Int(b.rect.minY))*bw+left+x-Int(b.rect.minX)
                        if a.bytes[ai] != 0 && b.bytes[bi] != 0 { bytes[y*w+x] = 1; hits += 1 }
                    }}
                    let iou = Double(hits)/Double(white.pixels+black.pixels-hits)
                    metrics["polarityIoU"] = iou
                    guard iou >= 0.8 else { return finish("polarity-conflict") }
                    selected = try measure(bytes, left: left, top: top, w: w, h: h)
                    metrics["intersectionSourceCoverage"] = selected.sourceCoverage
                    metrics["intersectionPredictedAgreement"] = selected.predictedAgreement
                    metrics["intersectionPredictedCoverage"] = selected.predictedCoverage
                    guard selected.associated else { return finish("intersection-association-failed") }
                    status = "available-conservative-intersection"
                } else if let white {
                    selected = white
                    status = "available-white224"
                } else if let black {
                    selected = black
                    status = "available-black48"
                } else {
                    return finish("no-closed-associated-component")
                }
                try work.poll()
                return finish(status, domain: selected)
            } catch {
                return finish((error as? Stop) == .cancelled ? "cancelled" : "work-budget-exceeded")
            }
        }
    }
}
