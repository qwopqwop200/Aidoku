import CoreGraphics
import Foundation

// S8: style per block on a bounded crop. Font px: a geometric rule with grouping times a learned per-group
// correction (PipelineFontCorrection). Fill: the k-means colour candidate picked by TRAIN-fit trees
// (PipelineStyleParameters), then kept or moved to a density peak of the line pixels (thin ink).
// Outline: colour rings around the fill mask.

extension PipelineStyle {
    /// Fills `style` on every block; blocks keep order and all other fields.
    /// `raster`, the page's decoded RGBA bytes when at hand, spares each crop a draw of `page.image`.
    static func estimate(_ page: PipelinePage, blocks: [PipelineBlock], raster: PipelinePageRaster? = nil) -> [PipelineBlock] {
        var groups: [Int] = []
        let fonts = PipelineSimpleFont.estimate(blocks, groups: &groups)
        // Same bytes as drawing the image only for an sRGB page (no colour conversion either way).
        let raster = raster.flatMap {
            $0.width == page.width && $0.height == page.height && page.image.colorSpace?.name == CGColorSpace.sRGB ? $0 : nil
        }
        // Blocks are independent; measure them concurrently.
        let results = UnsafeMutableBufferPointer<PipelineStyleEstimator.BlockAnalysis?>.allocate(capacity: blocks.count)
        results.initialize(repeating: nil)
        // Deinitialize first: deallocate alone would leak every analysis (crop planes) per call.
        defer { results.deinitialize(); results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: blocks.count) { index in
            results[index] = PipelineStyleEstimator.analyze(page.image, block: blocks[index], font: fonts[index], raster: raster)
        }
        var analyses = Array(results)
        let styles = PipelineStyleConsistency.unify(PipelineStyleEstimator.decide(&analyses, fonts: fonts),
                                              characters: blocks.map { $0.sourceText.unicodeScalars.count })
        // Layout reads the corrected size; the colour measurement above keeps the geometric one.
        let layoutFonts = PipelineFontCorrection.corrected(blocks, fonts: fonts, groups: groups)
        // Bold: ridge width of the fill body / layout font and its line cover (`boldMeasure`).
        let measured = analyses.map { $0 != nil }
        let bold = UnsafeMutableBufferPointer<Bool>.allocate(capacity: blocks.count)
        bold.initialize(repeating: false)
        defer { bold.deallocate() }
        DispatchQueue.concurrentPerform(iterations: blocks.count) { index in
            guard measured[index] else { return }
            let m = PipelineStyleEstimator.boldMeasure(page.image, block: blocks[index], font: Double(layoutFonts[index]),
                                                 fill: styles[index].textColor, raster: raster)
            bold[index] = m.map(PipelineStyleParameters.isBold) ?? false
        }
        return blocks.indices.map { index in
            var block = blocks[index]
            block.style = styles[index]
            block.style?.fontPixels = layoutFonts[index]
            block.style?.bold = bold[index]
            return block
        }
    }
}

// MARK: - Font size (port of NativeSimpleSourceFont)

enum PipelineSimpleFont {
    // NativeSourceInferencePolicy minimal-m1-p9-body64-presence95 calibration.
    static let scale = 0.43853239073260936
    static let bias = 4.094089327930639
    static let memberShortScale = 0.4140206805546956
    static let bodyRatioWeight = 0.8212525806130213
    static let maximumLogDistance = 0.9705176286667344
    static let groupedSizeScale = 1.0252379527066393

    static func estimate(_ blocks: [PipelineBlock]) -> [CGFloat] {
        var groups: [Int] = []
        return estimate(blocks, groups: &groups)
    }

    /// `groups[i]`: index of block i's size group (blocks of one group share the size).
    static func estimate(_ blocks: [PipelineBlock], groups groupOf: inout [Int]) -> [CGFloat] {
        groupOf = Array(blocks.indices)
        guard !blocks.isEmpty else { return [] }
        var values: [Double] = [], members: [Double] = [], weights: [Double] = []
        for block in blocks {
            let width = Double(block.bounds.width), height = Double(block.bounds.height)
            let count = max(1, block.sourceText.unicodeScalars.count)
            weights.append(Double(count))
            let prior: Double
            if width.isFinite, height.isFinite, width > 0, height > 0 {
                prior = max(8, min(min(width, height), (width * height / Double(count)).squareRoot()))
            } else {
                prior = 8
            }
            let member = memberShortMedian(block.lines.map(\.polygon)) ?? prior
            members.append(member)
            values.append(max(1, scale * prior + memberShortScale * member + bias))
        }
        guard values.count > 1 else { return values.map { CGFloat($0 * groupedSizeScale) } }
        // Longer texts (more reliable estimates) seed the groups; a group takes the median weighted by text length.
        let order = values.indices.sorted {
            if weights[$0] != weights[$1] { return weights[$0] > weights[$1] }
            if values[$0] != values[$1] { return values[$0] < values[$1] }
            if members[$0] != members[$1] { return members[$0] < members[$1] }
            return $0 < $1
        }
        var groups: [[Int]] = []
        for index in order {
            if let group = groups.firstIndex(where: { group in
                group.allSatisfy { other in
                    abs(log(values[index] / values[other])) +
                        bodyRatioWeight * abs(log(members[index] / members[other])) <= maximumLogDistance
                }
            }) {
                groups[group].append(index)
            } else {
                groups.append([index])
            }
        }
        var result = values
        for (id, group) in groups.enumerated() {
            let median = weightedMedian(group.map { (values[$0], weights[$0]) })
            for index in group { result[index] = median; groupOf[index] = id }
        }
        return result.map { CGFloat($0 * groupedSizeScale) }
    }

    /// Median of the values weighted by `weight` (the mean of the two middle values on an exact tie).
    static func weightedMedian(_ items: [(value: Double, weight: Double)]) -> Double {
        let sorted = items.sorted { $0.value < $1.value }
        let half = sorted.reduce(0) { $0 + $1.weight } * 0.5
        var cumulative: Double = 0
        for (index, item) in sorted.enumerated() {
            cumulative += item.weight
            if cumulative == half, index + 1 < sorted.count { return (item.value + sorted[index + 1].value) * 0.5 }
            if cumulative > half { return item.value }
        }
        return sorted.last?.value ?? 0
    }

    /// Area-weighted median short side of the members' minimum-area boxes.
    static func memberShortMedian(_ polygons: [[CGPoint]]) -> Double? {
        let boxes = polygons.filter { (3...256).contains($0.count) }.compactMap(minimumAreaBox)
        guard !boxes.isEmpty else { return nil }
        let sorted = boxes.sorted { $0.short != $1.short ? $0.short < $1.short : $0.area < $1.area }
        let half = sorted.reduce(0) { $0 + $1.area } * 0.5
        var cumulative: Double = 0
        for box in sorted {
            cumulative += box.area
            if cumulative >= half { return box.short }
        }
        return sorted.last?.short
    }

    private static func minimumAreaBox(_ polygon: [CGPoint]) -> (short: Double, area: Double)? {
        let hull = convexHull(polygon.map { (Double($0.x), Double($0.y)) })
        guard hull.count >= 3 else { return nil }
        var best: (short: Double, area: Double)?
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let dx = b.0 - a.0, dy = b.1 - a.1, length = (dx * dx + dy * dy).squareRoot()
            guard length > 1e-9 else { continue }
            let ux = dx / length, uy = dy / length
            var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
            for p in hull {
                let x = p.0 - a.0, y = p.1 - a.1
                let u = x * ux + y * uy, v = -x * uy + y * ux
                minX = min(minX, u); maxX = max(maxX, u); minY = min(minY, v); maxY = max(maxY, v)
            }
            let w = maxX - minX, h = maxY - minY
            guard w > 1e-9, h > 1e-9 else { continue }
            if best == nil || w * h < best!.area - 1e-9 { best = (min(w, h), w * h) }
        }
        return best
    }

    /// The polygon itself when already convex (legacy vertex order), else the monotone chain hull.
    private static func convexHull(_ poly: [(Double, Double)]) -> [(Double, Double)] {
        func cross(_ a: (Double, Double), _ b: (Double, Double), _ p: (Double, Double)) -> Double {
            (b.0 - a.0) * (p.1 - a.1) - (b.1 - a.1) * (p.0 - a.0)
        }
        let n = poly.count
        var signed: Double = 0
        for i in 0..<n { signed += poly[i].0 * poly[(i + 1) % n].1 - poly[(i + 1) % n].0 * poly[i].1 }
        let sign: Double = signed > 0 ? 1 : -1
        if signed != 0, (0..<n).allSatisfy({ i in
            poly.allSatisfy { sign * cross(poly[i], poly[(i + 1) % n], $0) >= -1e-9 }
        }) { return poly }
        var unique: [(Double, Double)] = []
        for p in poly.sorted(by: { $0 != $1 ? $0 < $1 : $0.1 < $1.1 })
        where unique.last.map({ $0 != p }) ?? true { unique.append(p) }
        guard unique.count > 2 else { return unique }
        var lower: [(Double, Double)] = [], upper: [(Double, Double)] = []
        for p in unique {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in unique.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }
}

// MARK: - Per-block pixel measurement

/// Colour/structure features of one block crop (lengths in page px).
struct PipelineStyleFeatures: Sendable {
    struct Cluster: Sendable {
        var count = 0
        var inLines: Double = 0
        var inRing: Double = 0
        var exterior: Double = 0
        var core: [Double] = [0, 0, 0]
        var coreCount = 0
        var strokeWidth: Double = 0
        var exteriorDistance: Double = 0
        var neighbourPurity: Double = 0
        var shellExterior: Double = 0
        var enclosed = false
        var interior = false
        /// Shell composition by plain colour cluster.
        var neighbours: [Double] = []
        var valid: Bool { count >= 4 }
    }
    struct Ring: Sendable {
        var distance: Double
        var median: [Double]
        var mad: Double
    }
    var font: Double
    var scale: Double = 1
    var ringBackground: [Double] = [255, 255, 255]
    var clusters: [Cluster] = []
    /// Ring profiles outside each cluster mask (only filled for requested clusters).
    var profiles: [Int: [Ring?]] = [:]
    /// Density peaks of the line pixels' colours (CIE Lab histogram), most populous first.
    struct Mode: Sendable {
        var rgb: [Double]
        var share: Double
    }
    var modes: [Mode] = []
}

enum PipelineStyleEstimator {
    static let clusterCount = 5
    static let interiorClusterCount = 3
    static let maximumPixels = 90_000
    static let maximumSamples = 4_000

    /// Working crop: RGB bytes, line mask, cluster assignment and distance maps.
    struct Crop {
        let width: Int, height: Int
        var rgb: [UInt8]
        var lines: [Bool]
        var lineDistance2: [Int32] = []
        var ring: [Bool] = []
        var assignment: [UInt8] = []
        /// Second-level clusters of interior (not exterior-connected) line pixels; 255 elsewhere.
        var interiorAssignment: [UInt8] = []
        /// Ring plus the same-cluster regions 4-connected to it.
        var exteriorOwn: [Bool] = []
        var exteriorDistance2: [Int32] = []
    }

    /// A measured block: features plus the working crop kept for ring profiles.
    struct BlockAnalysis {
        var features: PipelineStyleFeatures
        let crop: Crop
        mutating func profile(_ cluster: Int) -> [PipelineStyleFeatures.Ring?] {
            if let cached = features.profiles[cluster] { return cached }
            let rings = PipelineStyleEstimator.ringProfile(crop, cluster: cluster, scale: features.scale, font: features.font)
            features.profiles[cluster] = rings
            return rings
        }
    }

    static func analyze(_ image: CGImage, block: PipelineBlock, font: CGFloat, raster: PipelinePageRaster? = nil) -> BlockAnalysis? {
        let font = Double(font)
        guard var crop = makeCrop(image, block: block, font: font, raster: raster) else { return nil }
        var result = PipelineStyleFeatures(font: font, scale: crop.scale)
        let n = crop.crop.width * crop.crop.height
        let lineCount = count(crop.crop.lines)
        guard lineCount >= 16 else { return nil }
        let s = crop.scale
        crop.crop.lineDistance2 = squaredDistance(to: crop.crop.lines, width: crop.crop.width, height: crop.crop.height)
        let ringRadius = max(2, 0.2 * font * s)
        let ringRadius2 = ringRadius * ringRadius
        crop.crop.ring = crop.crop.lineDistance2.map { Double($0) > ringRadius2 }
        if count(crop.crop.ring) < 16 { crop.crop.ring = crop.crop.lines.map { !$0 } }
        let centres = kMeans(crop.crop, k: clusterCount, include: crop.crop.lines)
        crop.crop.assignment = assign(crop.crop, centres: centres)
        let k = clusterCount
        var inLines = [Int](repeating: 0, count: k), inRing = [Int](repeating: 0, count: k)
        var ringCount = 0
        // Ring colour histograms (as `channelMedian` over the ring pixels).
        var ringHistogram = [Int](repeating: 0, count: 768)
        crop.crop.assignment.withUnsafeBufferPointer { assignment in
            crop.crop.lines.withUnsafeBufferPointer { lines in
                crop.crop.ring.withUnsafeBufferPointer { ring in
                    crop.crop.rgb.withUnsafeBufferPointer { rgb in
                        inLines.withUnsafeMutableBufferPointer { inLines in
                            inRing.withUnsafeMutableBufferPointer { inRing in
                                ringHistogram.withUnsafeMutableBufferPointer { hist in
                                    for i in 0..<n {
                                        let a = Int(assignment[i])
                                        if lines[i] { inLines[a] += 1 }
                                        if ring[i] {
                                            inRing[a] += 1; ringCount += 1
                                            hist[Int(rgb[i * 3])] += 1; hist[256 + Int(rgb[i * 3 + 1])] += 1
                                            hist[512 + Int(rgb[i * 3 + 2])] += 1
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        result.ringBackground = ringCount == 0 ? [255, 255, 255] : (0..<3).map {
            histogramMedian(Array(ringHistogram[(256 * $0)..<(256 * $0 + 256)]), count: ringCount)
        }
        floodExterior(&crop.crop)
        // No exterior: every exterior distance would be Int32.max (a 2^31-entry histogram).
        guard crop.crop.exteriorOwn.contains(true) else { return nil }
        let labels = Labels(width: crop.crop.width, height: crop.crop.height)
        crop.crop.exteriorDistance2 = squaredDistance(to: crop.crop.exteriorOwn, width: crop.crop.width, height: crop.crop.height)
        // Members of candidates j < k (`candidateMask`) in raster order, in one pass.
        var plain = [[Int]](repeating: [], count: k)
        crop.crop.assignment.withUnsafeBufferPointer { a in
            crop.crop.lineDistance2.withUnsafeBufferPointer { d in
                for i in 0..<n where d[i] <= 4 { plain[Int(a[i])].append(i) }
            }
        }
        result.clusters = (0..<k).map { j in
            var cluster = PipelineStyleFeatures.Cluster()
            cluster.inLines = Double(inLines[j]) / Double(lineCount)
            cluster.inRing = Double(inRing[j]) / Double(max(1, ringCount))
            measureCluster(crop.crop, members: plain[j], labels: labels, scale: s, into: &cluster)
            return cluster
        }
        // Enclosed variants (k + j): the part of a mostly-exterior cluster cut off from the surroundings.
        func measureExtra(_ members: [Int], into cluster: inout PipelineStyleFeatures.Cluster) {
            let inside = crop.crop.lines.withUnsafeBufferPointer { lines in members.reduce(0) { $0 + (lines[$1] ? 1 : 0) } }
            cluster.inLines = Double(inside) / Double(lineCount)
            measureCluster(crop.crop, members: members, labels: labels, scale: s, into: &cluster)
            if cluster.count < 16 { cluster.count = 0 }
        }
        for j in 0..<k {
            var cluster = PipelineStyleFeatures.Cluster()
            cluster.enclosed = true
            if result.clusters[j].valid, result.clusters[j].exterior >= enclosedExteriorMinimum {
                // Candidate k + j: the members of j off the exterior.
                let enclosed = crop.crop.exteriorOwn.withUnsafeBufferPointer { own in plain[j].filter { !own[$0] } }
                measureExtra(enclosed, into: &cluster)
            }
            plain[j] = []
            result.clusters.append(cluster)
        }
        // Interior re-clustering (2k + j): separates a thin fill from merged art colours.
        var interiorCount = 0
        let interior = [Bool](unsafeUninitializedCapacity: n) { out, initialized in
            crop.crop.lines.withUnsafeBufferPointer { lines in
                crop.crop.exteriorOwn.withUnsafeBufferPointer { own in
                    for i in 0..<n {
                        let inside = lines[i] && !own[i]
                        out[i] = inside
                        interiorCount &+= inside ? 1 : 0
                    }
                }
            }
            initialized = n
        }
        var interiorAssignment = [UInt8](repeating: 255, count: n)
        var interiorMembers = [[Int]](repeating: [], count: interiorClusterCount)
        if interiorCount >= 16 {
            let centres = kMeans(crop.crop, k: interiorClusterCount, include: interior)
            let flat = centres.flatMap { $0 }
            interiorAssignment.withUnsafeMutableBufferPointer { out in
                crop.crop.rgb.withUnsafeBufferPointer { rgb in
                    crop.crop.lineDistance2.withUnsafeBufferPointer { d in
                        crop.crop.exteriorOwn.withUnsafeBufferPointer { own in
                            // A pixel of the previous one's colour takes its cluster (as in `assign`).
                            var last = UInt32.max, j = 0
                            for i in 0..<n where d[i] <= 4 && !own[i] {
                                let r = rgb[i * 3], g = rgb[i * 3 + 1], b = rgb[i * 3 + 2]
                                let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
                                if key != last {
                                    j = nearestCentre(Float(r), Float(g), Float(b), flat, k: interiorClusterCount)
                                    last = key
                                }
                                out[i] = UInt8(j)
                                interiorMembers[j].append(i) // candidate 2k + j
                            }
                        }
                    }
                }
            }
        }
        crop.crop.interiorAssignment = interiorAssignment
        for j in 0..<interiorClusterCount {
            var cluster = PipelineStyleFeatures.Cluster()
            cluster.interior = true
            if interiorCount >= 16 { measureExtra(interiorMembers[j], into: &cluster) }
            result.clusters.append(cluster)
        }
        // Ring profiles read only the colour, cluster and line-distance planes.
        result.modes = densityPeaks(crop.crop)
        crop.crop.lines = []; crop.crop.ring = []; crop.crop.exteriorDistance2 = []
        return BlockAnalysis(features: result, crop: crop.crop)
    }

    /// Number of `true` entries.
    private static func count(_ mask: [Bool]) -> Int {
        mask.withUnsafeBufferPointer { m in
            UnsafeRawBufferPointer(m).reduce(0) { $0 &+ Int($1) }
        }
    }

    private static func makeCrop(_ image: CGImage, block: PipelineBlock, font: Double,
                                 raster: PipelinePageRaster?, limit: Int = maximumPixels) -> (crop: Crop, scale: Double)? {
        let W = image.width, H = image.height
        let m = max(6, 0.5 * font)
        let box = block.bounds
        guard !box.isNull, box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite, m.isFinite
        else { return nil }
        // Clamp in floating point first: Int(_:) traps on values outside Int's range.
        func pixel(_ value: Double, _ limit: Int) -> Int { Int(min(Double(limit), max(0, value))) }
        let x0 = pixel(Double(box.minX) - m, W), y0 = pixel(Double(box.minY) - m, H)
        let x1 = pixel((Double(box.maxX) + m).rounded(.up), W), y1 = pixel((Double(box.maxY) + m).rounded(.up), H)
        guard x1 - x0 >= 4, y1 - y0 >= 4 else { return nil }
        var s = min(1, (Double(limit) / Double((x1 - x0) * (y1 - y0))).squareRoot())
        var w = x1 - x0, h = y1 - y0
        if s < 1 {
            w = max(4, Int(Double(x1 - x0) * s)); h = max(4, Int(Double(y1 - y0) * s))
            s = Double(w) / Double(x1 - x0)
        }
        let rgb: [UInt8]
        if s == 1, let raster, let plane = opaqueRGB(raster, x0: x0, y0: y0, x1: x1, y1: y1) {
            // Unscaled: the drawn crop is the raster's bytes.
            rgb = plane
        } else {
            let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
            func draw(_ source: CGImage) -> [UInt8]? {
                var rgba = [UInt8](repeating: 255, count: w * h * 4)
                let drawn: Bool = rgba.withUnsafeMutableBytes { raw in
                    guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                    context.interpolationQuality = s < 1 ? .medium : .none
                    context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
                    return true
                }
                return drawn ? rgba.withUnsafeBytes { rgbPlane($0, count: w * h) } : nil
            }
            // An opaque raster region is drawn in place (an image over the raster rows, no copy).
            var plane: [UInt8]?, drewRaster = false
            if let raster, isOpaque(raster, x0: x0, y0: y0, x1: x1, y1: y1) {
                raster.rgba.withUnsafeBufferPointer { page in
                    guard let source = regionImage(page, rowPixels: raster.width, x0: x0, y0: y0, x1: x1, y1: y1) else { return }
                    drewRaster = true
                    plane = draw(source)
                }
            }
            if !drewRaster {
                guard let source = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else { return nil }
                plane = draw(source)
            }
            guard let plane else { return nil }
            rgb = plane
        }
        var mask = [UInt8](repeating: 0, count: w * h)
        mask.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setShouldAntialias(false)
            context.setFillColor(gray: 1, alpha: 1)
            for line in block.lines where line.polygon.count >= 3 {
                let points = line.polygon.map {
                    CGPoint(x: (Double($0.x) - Double(x0)) * s, y: Double(h) - (Double($0.y) - Double(y0)) * s)
                }
                context.beginPath()
                context.addLines(between: points)
                context.closePath()
                context.fillPath()
            }
        }
        return (Crop(width: w, height: h, rgb: rgb, lines: mask.map { $0 > 0 }), s)
    }

    /// Whether every raster pixel of [x0, x1) x [y0, y1) is opaque
    /// (drawing composites the others over the white context, unlike the raster).
    private static func isOpaque(_ raster: PipelinePageRaster, x0: Int, y0: Int, x1: Int, y1: Int) -> Bool {
        raster.rgba.withUnsafeBufferPointer { page in
            var alpha: UInt8 = 255
            for y in y0..<y1 {
                let source = page.baseAddress! + (y * raster.width + x0) * 4
                for i in stride(from: 3, to: (x1 - x0) * 4, by: 4) { alpha &= source[i] }
            }
            return alpha == 255
        }
    }

    /// The RGB bytes of the raster's [x0, x1) x [y0, y1), or nil when one of them is not opaque.
    private static func opaqueRGB(_ raster: PipelinePageRaster, x0: Int, y0: Int, x1: Int, y1: Int) -> [UInt8]? {
        let w = x1 - x0, h = y1 - y0
        var alpha: UInt8 = 255
        let rgb = raster.rgba.withUnsafeBufferPointer { page in
            [UInt8](unsafeUninitializedCapacity: w * h * 3) { out, initialized in
                let out = out.baseAddress!
                for y in 0..<h {
                    let source = page.baseAddress! + ((y + y0) * raster.width + x0) * 4, row = out + y * w * 3
                    for x in 0..<w {
                        row[3 * x] = source[4 * x]; row[3 * x + 1] = source[4 * x + 1]; row[3 * x + 2] = source[4 * x + 2]
                        alpha &= source[4 * x + 3]
                    }
                }
                initialized = w * h * 3
            }
        }
        return alpha == 255 ? rgb : nil
    }

    /// The RGB bytes of `count` four-byte RGBX pixels.
    private static func rgbPlane(_ rgba: UnsafeRawBufferPointer, count: Int) -> [UInt8] {
        let source = rgba.bindMemory(to: UInt8.self)
        return [UInt8](unsafeUninitializedCapacity: count * 3) { out, initialized in
            for i in 0..<count { out[i * 3] = source[i * 4]; out[i * 3 + 1] = source[i * 4 + 1]; out[i * 3 + 2] = source[i * 4 + 2] }
            initialized = count * 3
        }
    }

    /// An opaque sRGB image over the [x0, x1) x [y0, y1) rows of an RGBA page of `rowPixels` columns,
    /// reading `page` in place: valid only while `page` is.
    private static func regionImage(_ page: UnsafeBufferPointer<UInt8>, rowPixels: Int, x0: Int, y0: Int, x1: Int, y1: Int) -> CGImage? {
        let start = UnsafeRawPointer(page.baseAddress! + (y0 * rowPixels + x0) * 4)
        let size = ((y1 - y0 - 1) * rowPixels + (x1 - x0)) * 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(dataInfo: nil, data: start, size: size, releaseData: { _, _, _ in })
        else { return nil }
        return CGImage(width: x1 - x0, height: y1 - y0, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowPixels * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: clustering

    private static func kMeans(_ crop: Crop, k: Int, include: [Bool]) -> [[Float]] {
        let total = include.withUnsafeBufferPointer { UnsafeRawBufferPointer($0).reduce(0) { $0 &+ Int($1) } }
        let step = max(1, total / maximumSamples)
        // Samples as flat RGB triples: every step-th included pixel (seen % step == 0).
        let samples = [Float](unsafeUninitializedCapacity: 3 * ((total + step - 1) / step)) { out, initialized in
            var taken = 0, skip = 0
            crop.rgb.withUnsafeBufferPointer { rgb in
                include.withUnsafeBufferPointer { m in
                    for i in 0..<(crop.width * crop.height) where m[i] {
                        if skip == 0 {
                            out[taken] = Float(rgb[i * 3]); out[taken + 1] = Float(rgb[i * 3 + 1]); out[taken + 2] = Float(rgb[i * 3 + 2])
                            taken += 3
                            skip = step
                        }
                        skip -= 1
                    }
                }
            }
            initialized = taken
        }
        let count = samples.count / 3
        var centres = [Float](repeating: 0, count: 3 * k)
        samples.withUnsafeBufferPointer { sp in
            let x = sp.baseAddress!
            @inline(__always) func d2(_ i: Int, _ c: UnsafePointer<Float>) -> Float {
                let a = x[3 * i] - c[0], b = x[3 * i + 1] - c[1], z = x[3 * i + 2] - c[2]
                return a * a + b * b + z * z
            }
            let lum = (0..<count).map { 0.299 * x[3 * $0] + 0.587 * x[3 * $0 + 1] + 0.114 * x[3 * $0 + 2] }
            // element at this rank of a stable sort by luminance, via selection
            let rank = Int(0.05 * Double(count - 1))
            let value = select(lum, rank)
            var skip = rank - lum.reduce(0) { $0 + ($1 < value ? 1 : 0) }
            var first = 0
            for (i, l) in lum.enumerated() where l == value {
                if skip == 0 { first = i; break }
                skip -= 1
            }
            centres.withUnsafeMutableBufferPointer { cp in
                let c = cp.baseAddress!
                func take(_ j: Int, _ i: Int) { c[3 * j] = x[3 * i]; c[3 * j + 1] = x[3 * i + 1]; c[3 * j + 2] = x[3 * i + 2] }
                take(0, first)
                var dmin = (0..<count).map { d2($0, c) }
                var chosen = 1
                while chosen < k {
                    let threshold = percentile(dmin, 98)
                    var best = 0, bestGap = Float.infinity
                    for (i, d) in dmin.enumerated() where abs(d - threshold) < bestGap { best = i; bestGap = abs(d - threshold) }
                    take(chosen, best)
                    let centre = UnsafePointer(c + 3 * chosen)
                    for i in 0..<count { dmin[i] = min(dmin[i], d2(i, centre)) }
                    chosen += 1
                }
                var sums = [Double](repeating: 0, count: 3 * k), counts = [Int](repeating: 0, count: k)
                // Lloyd steps; once a step leaves every centre unchanged the rest repeat it exactly.
                for _ in 0..<8 {
                    for j in 0..<(3 * k) { sums[j] = 0 }
                    for j in 0..<k { counts[j] = 0 }
                    for i in 0..<count {
                        var best = 0, bestD = Float.infinity
                        for j in 0..<k { let d = d2(i, c + 3 * j); if d < bestD { bestD = d; best = j } }
                        sums[3 * best] += Double(x[3 * i]); sums[3 * best + 1] += Double(x[3 * i + 1])
                        sums[3 * best + 2] += Double(x[3 * i + 2]); counts[best] += 1
                    }
                    var moved = false
                    for j in 0..<k where counts[j] > 0 {
                        for ch in 0..<3 {
                            let value = Float(sums[3 * j + ch] / Double(counts[j]))
                            if value != c[3 * j + ch] { moved = true }
                            c[3 * j + ch] = value
                        }
                    }
                    if !moved { break }
                }
            }
        }
        return (0..<k).map { Array(centres[(3 * $0)..<(3 * $0 + 3)]) }
    }

    /// numpy.percentile (linear) via selection.
    private static func percentile(_ values: [Float], _ q: Double) -> Float {
        let position = q / 100 * Double(values.count - 1)
        let lower = Int(position), upper = min(values.count - 1, lower + 1)
        var a = values
        return a.withUnsafeMutableBufferPointer { buffer in
            let p = buffer.baseAddress!
            PipelineRemovalMask.select(p, count: buffer.count, lower)
            let low = p[lower]
            // After selection everything past `lower` is >= it: the next order statistic is their minimum.
            var high = low
            if upper != lower {
                high = p[upper]
                for i in (upper + 1)..<buffer.count where p[i] < high { high = p[i] }
            }
            return low + Float(position - Double(lower)) * (high - low)
        }
    }

    /// k-th smallest value (0-based).
    static func select(_ values: [Float], _ k: Int) -> Float {
        var a = values
        return a.withUnsafeMutableBufferPointer { buffer in
            PipelineRemovalMask.select(buffer.baseAddress!, count: buffer.count, k)
            return buffer[k]
        }
    }

    private static func assign(_ crop: Crop, centres: [[Float]]) -> [UInt8] {
        let n = crop.width * crop.height
        let flat = centres.flatMap { $0 }
        let k = centres.count
        return [UInt8](unsafeUninitializedCapacity: n) { out, count in
            crop.rgb.withUnsafeBufferPointer { rgb in
                flat.withUnsafeBufferPointer { c in
                    // Runs of one colour (flat paper, ink) reuse the previous pixel's label.
                    var last = UInt32.max, label: UInt8 = 0
                    for i in 0..<n {
                        let r = rgb[i * 3], g = rgb[i * 3 + 1], b = rgb[i * 3 + 2]
                        let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
                        if key != last {
                            label = UInt8(nearestCentre(Float(r), Float(g), Float(b), c.baseAddress!, k: k))
                            last = key
                        }
                        out[i] = label
                    }
                }
            }
            count = n
        }
    }

    /// Index of the nearest of `k` flat RGB centres (first on ties).
    @inline(__always)
    private static func nearestCentre(_ r: Float, _ g: Float, _ b: Float, _ c: UnsafePointer<Float>, k: Int) -> Int {
        var best = 0, bestD = Float.infinity
        for j in 0..<k {
            let x = r - c[j * 3], y = g - c[j * 3 + 1], z = b - c[j * 3 + 2]
            let d = x * x + y * y + z * z
            if d < bestD { bestD = d; best = j }
        }
        return best
    }

    private static func floodExterior(_ crop: inout Crop) {
        let w = crop.width, n = w * crop.height
        // Each pixel is pushed at most once (marked on push), so the stack never exceeds n.
        let stack = UnsafeMutablePointer<Int32>.allocate(capacity: max(1, n))
        defer { stack.deallocate() }
        crop.exteriorOwn = [Bool](unsafeUninitializedCapacity: n) { own, initialized in
            crop.ring.withUnsafeBufferPointer { ring in
                crop.assignment.withUnsafeBufferPointer { a in
                    let own = own.baseAddress!, a = a.baseAddress!
                    var top = 0
                    for i in 0..<n {
                        own[i] = ring[i]
                        if ring[i] { stack[top] = Int32(i); top += 1 }
                    }
                    while top > 0 {
                        top -= 1
                        let i = Int(stack[top])
                        let x = i % w, label = a[i]
                        if x > 0, !own[i - 1], a[i - 1] == label { own[i - 1] = true; stack[top] = Int32(i - 1); top += 1 }
                        if x + 1 < w, !own[i + 1], a[i + 1] == label { own[i + 1] = true; stack[top] = Int32(i + 1); top += 1 }
                        if i >= w, !own[i - w], a[i - w] == label { own[i - w] = true; stack[top] = Int32(i - w); top += 1 }
                        if i + w < n, !own[i + w], a[i + w] == label { own[i + w] = true; stack[top] = Int32(i + w); top += 1 }
                    }
                }
            }
            initialized = n
        }
    }

    static let enclosedExteriorMinimum = 0.3

    /// Candidate j < k: cluster j pixels within 2 working px of the line polygons;
    /// candidate k + j: the same minus pixels connected to the surroundings; candidate 2k + j:
    /// interior re-cluster j.
    static func candidateMask(_ crop: Crop, candidate: Int) -> [Bool] {
        let n = crop.width * crop.height
        if candidate >= 2 * clusterCount {
            let label = UInt8(candidate - 2 * clusterCount)
            return crop.interiorAssignment.map { $0 == label }
        }
        let label = UInt8(candidate % clusterCount), enclosed = candidate >= clusterCount
        return [Bool](unsafeUninitializedCapacity: n) { mask, count in
            crop.assignment.withUnsafeBufferPointer { a in
                crop.lineDistance2.withUnsafeBufferPointer { d in
                    crop.exteriorOwn.withUnsafeBufferPointer { own in
                        for i in 0..<n { mask[i] = a[i] == label && d[i] <= 4 && !(enclosed && own[i]) }
                    }
                }
            }
            count = n
        }
    }

    /// Label plane with a 2 px border: bit 0 member, bit 1 outside the crop, bit 2 counted in the shell.
    final class Labels {
        static let member: UInt8 = 1, outside: UInt8 = 2, marked: UInt8 = 4
        let width: Int, height: Int, stride: Int
        let base: UnsafeMutablePointer<UInt8>
        /// Scratch for `measureCluster`: each shell pixel is marked once, so a shell holds at most width * height.
        let shell: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>
        init(width: Int, height: Int) {
            self.width = width; self.height = height; stride = width + 4
            shell = .allocate(capacity: max(1, width * height))
            base = .allocate(capacity: stride * (height + 4))
            base.initialize(repeating: Labels.outside, count: stride * (height + 4))
            for y in 0..<height { (base + (y + 2) * stride + 2).update(repeating: 0, count: width) }
        }
        deinit { base.deallocate(); shell.deallocate() }
        func at(_ i: Int) -> UnsafeMutablePointer<UInt8> { base + (i / width + 2) * stride + i % width + 2 }
    }

    private static func measureCluster(_ crop: Crop, members: [Int], labels: Labels, scale s: Double,
                                       into c: inout PipelineStyleFeatures.Cluster) {
        let w = crop.width
        let count = members.count
        c.count = count
        guard count >= 4 else { return }
        let member = Labels.member, marked = Labels.marked, pw = labels.stride
        // Members' label-plane cells (one division each instead of one per visit).
        let cells = UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>.allocate(capacity: count)
        defer { cells.deallocate() }
        for (index, i) in members.enumerated() { let p = labels.at(i); cells[index] = p; p.pointee = member }
        let offsets = [(-2, 0), (2, 0), (0, -2), (0, 2), (-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
        let paddedOffsets = UnsafeMutablePointer<Int>.allocate(capacity: 12), cropOffsets = UnsafeMutablePointer<Int>.allocate(capacity: 12)
        defer { paddedOffsets.deallocate(); cropOffsets.deallocate() }
        for (o, (dx, dy)) in offsets.enumerated() { paddedOffsets[o] = dy * pw + dx; cropOffsets[o] = dy * w + dx }
        var exterior = 0, perimeter = 0, coreCount = 0
        var neighbours = [Int](repeating: 0, count: clusterCount), shell = 0, shellExterior = 0
        let shellPixels = labels.shell
        var maximumDistance: Int32 = 0
        crop.exteriorDistance2.withUnsafeBufferPointer { dist in
            for i in members { maximumDistance = max(maximumDistance, dist[i]) }
        }
        // Squared distances can reach w^2 + h^2; such clusters (and few members over a wide range, where
        // clearing the histogram would cost more) take the median by selection.
        let useHistogram = maximumDistance <= maximumDistanceHistogram && Int(maximumDistance) <= 64 * count + 1024
        var histogram = [Int](repeating: 0, count: useHistogram ? Int(maximumDistance) + 1 : 1)
        var all = [Int](repeating: 0, count: 768), core = all
        withPointers(crop, &histogram, &all, &core) { own, dist, rgb, a, histogram, all, core in
            neighbours.withUnsafeMutableBufferPointer { neighbours in
                var exteriorTotal = 0, perimeterTotal = 0, coreTotal = 0, shellTotal = 0, shellExteriorTotal = 0
                for (index, i) in members.enumerated() {
                    let p = cells[index]
                    if own[i] { exteriorTotal += 1 }
                    // perimeter: 4-neighbour erosion with zero border
                    if p[-1] & p[1] & p[-pw] & p[pw] & member == 0 { perimeterTotal += 1 }
                    // core: no non-cluster pixel within distance < 1.5 (3x3); outside the crop does not count
                    let isCore = p[-pw - 1] & 3 != 0 && p[-pw] & 3 != 0 && p[-pw + 1] & 3 != 0 && p[-1] & 3 != 0
                        && p[1] & 3 != 0 && p[pw - 1] & 3 != 0 && p[pw] & 3 != 0 && p[pw + 1] & 3 != 0
                    let r = Int(rgb[i * 3]), g = 256 + Int(rgb[i * 3 + 1]), b = 512 + Int(rgb[i * 3 + 2])
                    all[r] += 1; all[g] += 1; all[b] += 1
                    if isCore { coreTotal += 1; core[r] += 1; core[g] += 1; core[b] += 1 }
                    if useHistogram { histogram[Int(dist[i])] += 1 }
                    // shell: pixels within Euclidean distance 2 outside the mask
                    for o in 0..<12 where p[paddedOffsets[o]] == 0 {
                        let q = p + paddedOffsets[o]
                        q.pointee = marked
                        shellPixels[shellTotal] = q
                        shellTotal += 1
                        let j = i + cropOffsets[o]
                        neighbours[Int(a[j])] += 1
                        if own[j] { shellExteriorTotal += 1 }
                    }
                }
                exterior = exteriorTotal; perimeter = perimeterTotal; coreCount = coreTotal
                shell = shellTotal; shellExterior = shellExteriorTotal
            }
        }
        for index in 0..<count { cells[index].pointee = 0 }
        for index in 0..<shell { shellPixels[index].pointee = 0 }
        c.exterior = Double(exterior) / Double(count)
        let useCore = coreCount >= 4
        let source = useCore ? core : all, total = useCore ? coreCount : count
        c.core = (0..<3).map { ch in histogramMedian(Array(source[(256 * ch)..<(256 * ch + 256)]), count: total) }
        c.coreCount = total
        c.strokeWidth = 2 * Double(count) / Double(max(1, perimeter)) / s
        if useHistogram {
            c.exteriorDistance = squaredHistogramMedian(histogram, count: count) / s
        } else {
            // sqrt is monotone: the k-th smallest root is the root of the k-th smallest squared distance.
            var values = crop.exteriorDistance2.withUnsafeBufferPointer { dist in members.map { dist[$0] } }
            let median: Double = values.withUnsafeMutableBufferPointer { v in
                func kth(_ k: Int) -> Double { selectInt32(v.baseAddress!, count: v.count, k); return Double(v[k]).squareRoot() }
                if count % 2 == 1 { return kth(count / 2) }
                let upper = kth(count / 2)
                // After selecting rank count / 2, the lower half holds ranks below it: its maximum is rank count / 2 - 1.
                var lower = v[0]
                for i in 0..<(count / 2) { lower = max(lower, v[i]) }
                return (Double(lower).squareRoot() + upper) / 2
            }
            c.exteriorDistance = median / s
        }
        c.neighbourPurity = Double(neighbours.max() ?? 0) / Double(max(1, shell))
        c.neighbours = neighbours.map { Double($0) / Double(max(1, shell)) }
        c.shellExterior = Double(shellExterior) / Double(max(1, shell))
    }

    /// Crop planes and three mutable histograms as buffer pointers for `measureCluster`.
    private static func withPointers(
        _ crop: Crop, _ histogram: inout [Int], _ all: inout [Int], _ core: inout [Int],
        _ body: (UnsafeBufferPointer<Bool>, UnsafeBufferPointer<Int32>, UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>,
                 UnsafeMutableBufferPointer<Int>, UnsafeMutableBufferPointer<Int>, UnsafeMutableBufferPointer<Int>) -> Void
    ) {
        crop.exteriorOwn.withUnsafeBufferPointer { own in
            crop.exteriorDistance2.withUnsafeBufferPointer { dist in
                crop.rgb.withUnsafeBufferPointer { rgb in
                    crop.assignment.withUnsafeBufferPointer { a in
                        histogram.withUnsafeMutableBufferPointer { histogram in
                            all.withUnsafeMutableBufferPointer { all in
                                core.withUnsafeMutableBufferPointer { core in
                                    body(own, dist, rgb, a, histogram, all, core)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Largest squared exterior distance counted with a histogram in `measureCluster`.
    static let maximumDistanceHistogram: Int32 = 1 << 16

    /// Partially orders `a` so that a[k] is its k-th smallest value, a[..<k] <= a[k] <= a[(k + 1)...] (Hoare quickselect).
    static func selectInt32(_ a: UnsafeMutablePointer<Int32>, count: Int, _ k: Int) {
        func swap(_ x: Int, _ y: Int) { let t = a[x]; a[x] = a[y]; a[y] = t }
        var lo = 0, hi = count - 1
        while hi > lo {
            let mid = lo + (hi - lo) / 2
            if a[mid] < a[lo] { swap(mid, lo) }
            if a[hi] < a[lo] { swap(hi, lo) }
            if a[hi] < a[mid] { swap(hi, mid) }
            let pivot = a[mid]
            var i = lo, j = hi
            while i <= j {
                while a[i] < pivot { i += 1 }
                while a[j] > pivot { j -= 1 }
                if i <= j { swap(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { return }
        }
    }

    static func ringBins(font: Double, scale s: Double) -> Int { min(40, max(12, Int((0.3 * font * s).rounded(.up)))) }

    static func ringProfile(_ crop: Crop, cluster j: Int, scale s: Double, font: Double) -> [PipelineStyleFeatures.Ring?] {
        let n = crop.width * crop.height
        let mask = candidateMask(crop, candidate: j)
        let distance2 = squaredDistance(to: mask, width: crop.width, height: crop.height)
        let limit = max(2, 0.45 * font * s), limit2 = limit * limit
        let bins = ringBins(font: font, scale: s)
        // bin b holds b - 0.5 < d <= b + 0.5; the bin of every squared distance below (bins + 1)^2, the first
        // one past the last bin (the bin grows with the distance).
        let top = (bins + 1) * (bins + 1)
        let binOf = [Int](unsafeUninitializedCapacity: top) { out, count in
            for d2 in 0..<top { out[d2] = Int((Double(d2).squareRoot() - 0.5).rounded(.up)) }
            count = top
        }
        // Members per bin in raster order, flat (counting sort).
        var start = [Int](repeating: 0, count: bins + 2)
        var flat: [Int] = []
        distance2.withUnsafeBufferPointer { d in
            crop.lineDistance2.withUnsafeBufferPointer { line in
                binOf.withUnsafeBufferPointer { binOf in
                    var bin = [UInt8](repeating: 0, count: n)
                    bin.withUnsafeMutableBufferPointer { bin in
                        for i in 0..<n {
                            let v = Int(d[i])
                            guard v > 0, v < top, Double(line[i]) <= limit2 else { continue }
                            let b = binOf[v]
                            if b >= 1, b <= bins { bin[i] = UInt8(b); start[b + 1] += 1 }
                        }
                        for b in 1...(bins + 1) { start[b] += start[b - 1] }
                        var next = start
                        flat = [Int](repeating: 0, count: start[bins + 1])
                        flat.withUnsafeMutableBufferPointer { flat in
                            for i in 0..<n where bin[i] != 0 { let b = Int(bin[i]); flat[next[b]] = i; next[b] += 1 }
                        }
                    }
                }
            }
        }
        return crop.rgb.withUnsafeBufferPointer { rgb in
            flat.withUnsafeBufferPointer { flat in
                (1...bins).map { b -> PipelineStyleFeatures.Ring? in
                    let pixels = flat[start[b]..<start[b + 1]]
                    guard pixels.count >= 4 else { return nil }
                    var histograms = [Int](repeating: 0, count: 768)
                    for i in pixels { histograms[Int(rgb[i * 3])] += 1; histograms[256 + Int(rgb[i * 3 + 1])] += 1; histograms[512 + Int(rgb[i * 3 + 2])] += 1 }
                    let median = (0..<3).map {
                        histogramMedian(Array(histograms[(256 * $0)..<(256 * $0 + 256)]), count: pixels.count)
                    }
                    var histogram = [Int](repeating: 0, count: 1531)
                    for i in pixels {
                        var total: Double = 0
                        for ch in 0..<3 { total += abs(Double(rgb[i * 3 + ch]) - median[ch]) }
                        histogram[Int((total * 2).rounded())] += 1
                    }
                    return .init(distance: Double(b) / s, median: median, mad: histogramMedian(histogram, count: pixels.count) / 2)
                }
            }
        }
    }

    // MARK: primitives

    /// Exact squared Euclidean distance to the nearest `true` pixel (Felzenszwalb); Int32.max with none.
    static func squaredDistance(to target: [Bool], width w: Int, height h: Int) -> [Int32] {
        let n = w * h
        var out = [Int32](repeating: 0, count: n)
        guard n > 0 else { return out }
        // Column steps above `far` mean no target pixel in the column (steps stay below 2 * far).
        let far = Int32(1 << 28)
        let vp = UnsafeMutablePointer<Int>.allocate(capacity: w), vf = UnsafeMutablePointer<Int>.allocate(capacity: w)
        let zn = UnsafeMutablePointer<Int>.allocate(capacity: w + 1), zd = UnsafeMutablePointer<Int>.allocate(capacity: w + 1)
        defer { vp.deallocate(); vf.deallocate(); zn.deallocate(); zd.deallocate() }
        target.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                let steps = o.baseAddress!
                // Bool is stored as one byte 0/1; `keep` is 0 on a target pixel, all ones elsewhere.
                let t = UnsafeRawPointer(t.baseAddress!).assumingMemoryBound(to: UInt8.self)
                @inline(__always) func keep(_ i: Int) -> Int32 { Int32(t[i]) &- 1 }
                // Column pass: for a 0/infinity input two row-major sweeps equal the 1-D transform.
                for x in 0..<w { steps[x] = far & keep(x) }
                var row = w
                while row < n {
                    for x in 0..<w { steps[row + x] = (steps[row - w + x] &+ 1) & keep(row + x) }
                    row += w
                }
                row = n - 2 * w
                while row >= 0 {
                    for x in 0..<w { steps[row + x] = min(steps[row + x], steps[row + w + x] &+ 1) }
                    row -= w
                }
                // Row pass (Felzenszwalb) over the finite columns only, breakpoints as exact fractions zn/zd
                // (zd > 0): an infinite column never attains a row minimum, a row without one stays Int32.max.
                for y in 0..<h {
                    let r = steps + y * w
                    var k = -1
                    for q in 0..<w {
                        let step = Int(r[q])
                        guard step < Int(far) else { continue }
                        let fq = step * step
                        guard k >= 0 else { k = 0; vp[0] = q; vf[0] = fq; continue }
                        let gq = fq + q * q
                        var num = 0, den = 1
                        while true {
                            let p = vp[k]
                            num = gq - (vf[k] + p * p); den = 2 * (q - p)
                            // intersection <= previous breakpoint (the first one is -infinity)
                            if k > 0, num * zd[k] <= zn[k] * den { k -= 1 } else { break }
                        }
                        k += 1; vp[k] = q; vf[k] = fq; zn[k] = num; zd[k] = den
                    }
                    guard k >= 0 else { r.update(repeating: .max, count: w); continue }
                    // Parabola j covers q in (z[j], z[j + 1]], i.e. from floor(z[j]) + 1.
                    var q = 0
                    for j in 0...k {
                        var end = w
                        if j < k {
                            let a = zn[j + 1], b = zd[j + 1]
                            let floorDiv = a >= 0 ? a / b : -((-a + b - 1) / b)
                            end = min(w, floorDiv + 1)
                        }
                        let p = vp[j], fp = vf[j]
                        while q < end { r[q] = Int32(clamping: (q - p) * (q - p) + fp); q += 1 }
                    }
                }
            }
        }
        return out
    }

    static let peakBin = 6.0
    static let peakMinimumShare = 0.01
    static let peakCount = 8
    static let peakSamples = 20_000

    /// CIE Lab of an sRGB colour (D65).
    static func lab(_ c: [Double]) -> [Double] {
        func linear(_ v: Double) -> Double {
            let c = v / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(c[0]), g = linear(c[1]), b = linear(c[2])
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]
    }

    /// CIE76 colour difference of two sRGB colours.
    static func deltaE(_ a: [Double], _ b: [Double]) -> Double {
        let p = lab(a), q = lab(b)
        return ((p[0] - q[0]) * (p[0] - q[0]) + (p[1] - q[1]) * (p[1] - q[1]) + (p[2] - q[2]) * (p[2] - q[2])).squareRoot()
    }

    /// Local maxima (26-neighbourhood) of a Lab histogram over the line pixels holding at least 1% of them;
    /// each peak's colour is the channel median of the pixels in its 3x3x3 bins. Thin lettering blends
    /// its ink with the outline, so the k-means cores can miss the ink while a peak still sits on it.
    /// `lab`'s channel linearisation of each byte value.
    static let linearTable: [Double] = (0..<256).map { v in
        let c = Double(v) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func densityPeaks(_ crop: Crop) -> [PipelineStyleFeatures.Mode] {
        var lineIndices: [Int] = []
        for i in crop.lines.indices where crop.lines[i] { lineIndices.append(i) }
        guard lineIndices.count >= 16 else { return [] }
        let step = max(1, lineIndices.count / peakSamples)
        let samples = stride(from: 0, to: lineIndices.count, by: step).map { lineIndices[$0] }
        func pack(_ k: (Int, Int, Int)) -> Int { ((k.0 + 64) << 16) | ((k.1 + 64) << 8) | (k.2 + 64) }
        func unpack(_ p: Int) -> (Int, Int, Int) { ((p >> 16) - 64, ((p >> 8) & 255) - 64, (p & 255) - 64) }
        // The bin depends on the colour alone: memoise it (direct-mapped, 24-bit key; -1 empty).
        let cacheSize = 4096
        var cacheKey = [Int32](repeating: -1, count: cacheSize), cacheValue = [Int](repeating: 0, count: cacheSize)
        let keys: [(Int, Int, Int)] = crop.rgb.withUnsafeBufferPointer { rgb in
            samples.map { i in
                let r = Int(rgb[i * 3]), g = Int(rgb[i * 3 + 1]), b = Int(rgb[i * 3 + 2])
                let colour = Int32(r << 16 | g << 8 | b)
                let slot = (r &* 7 ^ g &* 61 ^ b &* 509 ^ (r ^ g) << 4) & (cacheSize - 1)
                if cacheKey[slot] == colour { return unpack(cacheValue[slot]) }
                // `lab` inline, the channel linearisation from a table (same arithmetic).
                let lr = linearTable[r], lg = linearTable[g], lb = linearTable[b]
                let x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
                let y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
                let z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
                func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
                let fx = f(x), fy = f(y), fz = f(z)
                let l0 = 116 * fy - 16, l1 = 500 * (fx - fy), l2 = 200 * (fy - fz)
                let k = (Int((l0 / peakBin).rounded(.down)), Int((l1 / peakBin).rounded(.down)), Int((l2 / peakBin).rounded(.down)))
                cacheKey[slot] = colour; cacheValue[slot] = pack(k)
                return k
            }
        }
        var counts: [Int: Int] = [:]
        for k in keys { counts[pack(k), default: 0] += 1 }
        let total = Double(samples.count)
        var peaks: [(count: Int, packed: Int, key: (Int, Int, Int))] = []
        var seen = Set<Int>()
        for k in keys {
            let packed = pack(k)
            guard seen.insert(packed).inserted, let c = counts[packed], Double(c) >= peakMinimumShare * total else { continue }
            var isPeak = true
            for a in -1...1 { for b in -1...1 { for d in -1...1 where (a, b, d) != (0, 0, 0) {
                if let n = counts[pack((k.0 + a, k.1 + b, k.2 + d))], n > c { isPeak = false }
            } } }
            if isPeak { peaks.append((c, packed, k)) }
        }
        peaks.sort { $0.count != $1.count ? $0.count > $1.count : $0.packed > $1.packed }
        return peaks.prefix(peakCount).map { peak in
            let members = samples.indices.filter {
                abs(keys[$0].0 - peak.key.0) <= 1 && abs(keys[$0].1 - peak.key.1) <= 1 && abs(keys[$0].2 - peak.key.2) <= 1
            }.map { samples[$0] }
            return PipelineStyleFeatures.Mode(rgb: channelMedian(crop.rgb, indices: members), share: Double(peak.count) / total)
        }
    }

    /// Features of each colour option of a block: the pick first, then its density peaks.
    static func peakFeatures(_ f: PipelineStyleFeatures, pick: [Double], pickLogit: Double, outline: [Double]) -> (colours: [[Double]], x: [[Double]]) {
        let ring = f.ringBackground
        let colours = [pick] + f.modes.map(\.rgb)
        let shares = f.modes.map(\.share)
        func lc(_ c: [Double]) -> (Double, Double) { let l = lab(c); return (l[0], (l[1] * l[1] + l[2] * l[2]).squareRoot()) }
        let (lp, cp) = lc(pick)
        let x: [[Double]] = colours.indices.map { i in
            let colour = colours[i], (l, c) = lc(colour)
            let share = i == 0 ? 0 : shares[i - 1]
            let rank = i == 0 ? -1 : Double(shares.firstIndex(of: share)!)
            return [i == 0 ? 1 : 0, share, rank, deltaE(colour, pick), deltaE(colour, ring), deltaE(colour, outline),
                    l, c, l - lp, c - cp, deltaE(pick, ring), deltaE(pick, outline), pickLogit, f.font / 100,
                    Double(f.modes.count), deltaE(colour, ring) - deltaE(pick, ring)]
        }
        return (colours, x)
    }

    static func channelMedian(_ rgb: [UInt8], indices: [Int]) -> [Double] {
        guard !indices.isEmpty else { return [255, 255, 255] }
        var histograms = [Int](repeating: 0, count: 768)
        histograms.withUnsafeMutableBufferPointer { h in
            rgb.withUnsafeBufferPointer { rgb in
                for i in indices { h[Int(rgb[i * 3])] += 1; h[256 + Int(rgb[i * 3 + 1])] += 1; h[512 + Int(rgb[i * 3 + 2])] += 1 }
            }
        }
        return (0..<3).map { histogramMedian(Array(histograms[(256 * $0)..<(256 * $0 + 256)]), count: indices.count) }
    }

    /// numpy-style median (mean of the two middle values) of a value histogram.
    static func histogramMedian(_ histogram: [Int], count: Int) -> Double {
        func kth(_ k: Int) -> Int { histogramRank(histogram, k) }
        return count % 2 == 1 ? Double(kth(count / 2)) : Double(kth(count / 2 - 1) + kth(count / 2)) / 2
    }

    /// Median of sqrt(value) over a histogram of squared distances.
    static func squaredHistogramMedian(_ histogram: [Int], count: Int) -> Double {
        func kth(_ k: Int) -> Double { Double(histogramRank(histogram, k)).squareRoot() }
        return count % 2 == 1 ? kth(count / 2) : (kth(count / 2 - 1) + kth(count / 2)) / 2
    }

    /// Value of the k-th (0-based) histogram sample.
    private static func histogramRank(_ histogram: [Int], _ k: Int) -> Int {
        var cumulative = 0
        for (value, c) in histogram.enumerated() {
            cumulative += c
            if cumulative > k { return value }
        }
        return histogram.count - 1
    }
}

// MARK: - Decisions (TRAIN-fit trees/constants in PipelineStyleParameters, PipelineWeights.swift)

/// Flattened gradient-boosted trees (sklearn GradientBoostingClassifier export).
struct PipelineStyleForest: Sendable {
    let base: Double
    let rate: Double
    let roots: [Int32]
    let feature: [Int16]
    let threshold: [Double]
    let left: [Int32]
    let right: [Int32]
    let value: [Double]

    /// Raw log-odds; inputs are compared as Float like sklearn trees.
    func logit(_ x: [Double]) -> Double {
        var z = base
        for root in roots {
            var node = Int(root)
            while left[node] >= 0 {
                node = Double(Float(x[Int(feature[node])])) <= threshold[node] ? Int(left[node]) : Int(right[node])
            }
            z += rate * value[node]
        }
        return z
    }
}

extension PipelineStyleEstimator {
    private static let colourNorm = 441.6729559300637
    static let plainCandidates = clusterCount

    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        let x = a[0] - b[0], y = a[1] - b[1], z = a[2] - b[2]
        return (x * x + y * y + z * z).squareRoot() / colourNorm
    }

    static func luminance(_ c: [Double]) -> Double { 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2] }

    static func chroma(_ c: [Double]) -> Double { ((c.max() ?? 0) - (c.min() ?? 0)) / 255 }

    /// numpy-style per-channel median of a few colours.
    static func median(_ colours: [[Double]]) -> [Double] {
        (0..<3).map { ch in
            let values = colours.map { $0[ch] }.sorted(), middle = values.count / 2
            return values.count % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2
        }
    }

    /// The per-block part of `candidateFeatures`, shared by every candidate.
    struct CandidateContext {
        let ids: [Int], pool: [Int], maxDistance: Double
        /// The plain candidate with the largest ring share; nil without one (each candidate then uses itself).
        let background: Int?
        let luminances: [Double]
        init(_ f: PipelineStyleFeatures) {
            let cl = f.clusters
            ids = cl.indices.filter { cl[$0].valid }
            let bigIDs = ids.filter { cl[$0].inLines >= 0.08 }
            pool = bigIDs.isEmpty ? ids : bigIDs
            maxDistance = pool.map { cl[$0].exteriorDistance }.max() ?? 0
            let plain = ids.filter { $0 < PipelineStyleEstimator.plainCandidates }
            var bgj: Int?
            if let first = plain.first {
                var best = first
                for i in plain where cl[i].inRing > cl[best].inRing { best = i }
                bgj = best
            }
            background = bgj
            luminances = cl.map { PipelineStyleEstimator.luminance($0.core) }
        }
    }

    /// Fill-candidate features (order matches model.py cand_x + twin).
    static func candidateFeatures(_ f: PipelineStyleFeatures, _ j: Int, consensus: [Double]?,
                                  context: CandidateContext) -> [Double] {
        let cl = f.clusters, c = cl[j], font = f.font
        let ids = context.ids, pool = context.pool, maxDistance = context.maxDistance, lums = context.luminances
        let colour = c.core, lum = lums[j]
        let sw = c.strokeWidth / font
        let fM = c.inLines, fR = c.inRing
        let bgj = context.background ?? j
        var d = bgj
        if let top = c.neighbours.max(), top > 0 { d = c.neighbours.firstIndex(of: top)! }
        let dc = cl[d].valid ? cl[d] : cl[bgj]
        let count = Double(ids.count)
        var darker = 0, nearer = 0
        for i in ids {
            if lums[i] < lum { darker += 1 }
            if cl[i].exteriorDistance < c.exteriorDistance { nearer += 1 }
        }
        var x: [Double] = [
            c.exterior, log((fM + 0.01) / (fR + 0.01)), fM, fR, lum / 255,
            distance(colour, f.ringBackground), c.neighbourPurity, sw, chroma(colour),
            lum > 200 ? 1 : 0, c.exteriorDistance / font, Double(c.coreCount) / Double(max(1, c.count)),
            c.shellExterior, c.exteriorDistance >= maxDistance && pool.contains(j) ? 1 : 0,
            consensus.map { distance(colour, $0) } ?? 0, c.enclosed ? 1 : 0, c.interior ? 1 : 0,
            Double(darker) / count,
            Double(nearer) / count,
            dc.exterior, cl[d].inRing, dc.exteriorDistance / font, distance(colour, dc.core),
            (lum - luminance(dc.core)) / 255, distance(colour, cl[bgj].core), (lum - lums[bgj]) / 255,
            consensus == nil ? 0 : 1
        ]
        x.reserveCapacity(x.count + 5)
        // relation to the most similar other candidate (e.g. a purer interior twin)
        var i = -1, nearest = 0.0
        for o in ids where o != j {
            let value = distance(colour, cl[o].core)
            if i < 0 || value < nearest { i = o; nearest = value }
        }
        if i >= 0 {
            x += [nearest, fR - cl[i].inRing, (c.exteriorDistance - cl[i].exteriorDistance) / font,
                  cl[i].interior || cl[i].enclosed ? 1 : 0, fM - cl[i].inLines]
        } else {
            x += [1, 0, 0, 0, 0]
        }
        return x
    }

    /// The best-scoring valid fill candidate and its logit.
    static func scoredPick(_ f: PipelineStyleFeatures, forest: PipelineStyleForest,
                           consensus: [Double]?) -> (index: Int, score: Double)? {
        var best: Int?, bestScore = -Double.infinity
        let context = CandidateContext(f)
        for j in f.clusters.indices where f.clusters[j].valid {
            let score = forest.logit(candidateFeatures(f, j, consensus: consensus, context: context))
            if score > bestScore { best = j; bestScore = score }
        }
        return best.map { ($0, bestScore) }
    }

    /// Distance from the far ring, ignoring the component pointing back to the fill.
    static func halo(_ c: [Double], far: [Double], fill: [Double]) -> Double {
        var v = (0..<3).map { c[$0] - far[$0] }
        var u = (0..<3).map { far[$0] - fill[$0] }
        let norm = (u[0] * u[0] + u[1] * u[1] + u[2] * u[2]).squareRoot()
        if norm > 1e-9 {
            u = u.map { $0 / norm }
            let projection = v[0] * u[0] + v[1] * u[1] + v[2] * u[2]
            if projection < 0 { v = (0..<3).map { v[$0] - projection * u[$0] } }
        }
        return (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot() / colourNorm
    }

    struct OutlineObservation {
        var features: [Double]
        var colour: [Double]
        var ringWidth: Double
    }

    static func outlineObservation(_ f: PipelineStyleFeatures, fill j: Int, rings profile: [PipelineStyleFeatures.Ring?],
                                   background: [Double]) -> OutlineObservation? {
        let rings = profile.compactMap { $0 }
        guard let far = rings.last else { return nil }
        let fill = f.clusters[j].core
        let limit = max(3, 0.22 * f.font)
        let nearRings = rings.filter { $0.distance >= 1.5 && $0.distance <= limit }
        let near = nearRings.isEmpty ? [rings[0]] : nearRings
        var peakIndex = 0, peakScore = -Double.infinity
        for (index, ring) in near.enumerated() {
            let score = halo(ring.median, far: far.median, fill: fill)
            if score > peakScore { peakIndex = index; peakScore = score }
        }
        let peak = near[peakIndex], colour = peak.median
        let step = peakScore
        var width: Double = 0, seen = false
        for ring in rings {
            if ring.distance == peak.distance { seen = true }
            if seen {
                if distance(ring.median, colour) > 0.5 * step { break }
                width = ring.distance
            }
        }
        let x: [Double] = [
            step, distance(colour, fill), distance(far.median, fill), peak.mad / 441, far.mad / 441,
            luminance(colour) / 255, luminance(fill) / 255, f.clusters[j].inRing, distance(colour, background),
            luminance(colour) > 200 ? 1 : 0, width / f.font, log1p(step * 441), log1p(step * 441 / (1 + far.mad + peak.mad)),
            chroma(fill), chroma(colour), f.font / 100
        ]
        return OutlineObservation(features: x, colour: colour, ringWidth: width)
    }

    static func rgb(_ c: [Double]) -> PipelineRGB {
        func channel(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded(.toNearestOrEven)))) }
        return PipelineRGB(r: channel(c[0]), g: channel(c[1]), b: channel(c[2]))
    }

    static func decide(_ analyses: inout [BlockAnalysis?], fonts: [CGFloat]) -> [PipelineStyle] {
        typealias P = PipelineStyleParameters
        // pass 1: per-block fill pick, page consensus colour
        let picked = analyses.compactMap { analysis in
            analysis.flatMap { a in scoredPick(a.features, forest: P.fillPass1, consensus: nil).map { a.features.clusters[$0.index].core } }
        }
        let consensus = picked.isEmpty ? nil : median(picked)
        var results: [PipelineStyle] = fonts.map {
            PipelineStyle(fontPixels: $0, bold: false, textColor: PipelineRGB(r: 0, g: 0, b: 0), strokeColor: nil, strokeWidth: 0)
        }
        var observations: [OutlineObservation?] = Array(repeating: nil, count: analyses.count)
        var scores: [Double?] = Array(repeating: nil, count: analyses.count)
        // Blocks are independent given the consensus (each ring profile is a distance transform).
        analyses.withUnsafeMutableBufferPointer { analyses in
            results.withUnsafeMutableBufferPointer { results in
                observations.withUnsafeMutableBufferPointer { observations in
                    scores.withUnsafeMutableBufferPointer { scores in
                        DispatchQueue.concurrentPerform(iterations: analyses.count) { index in
                            guard var analysis = analyses[index],
                                  let (j, pickLogit) = scoredPick(analysis.features, forest: P.fillPass2, consensus: consensus)
                            else { return }
                            let f = analysis.features
                            let profile = analysis.profile(j)
                            let rings = profile.compactMap { $0 }
                            let background = (rings.isEmpty ? f.ringBackground : median(rings.suffix(3).map(\.median)))
                                .map { $0.rounded(.toNearestOrEven) }
                            results[index].textColor = rgb(f.clusters[j].core)
                            let observation = outlineObservation(f, fill: j, rings: profile, background: background)
                            if let observation {
                                observations[index] = observation
                                scores[index] = P.outline.logit(observation.features)
                            }
                            // Second stage: keep the pick or move to a density peak of the line pixels.
                            if let peaks = P.fillPeaks, !f.modes.isEmpty {
                                let options = peakFeatures(f, pick: f.clusters[j].core, pickLogit: pickLogit,
                                                           outline: observation?.colour ?? f.ringBackground)
                                var best = 0, bestScore = -Double.infinity
                                for (i, x) in options.x.enumerated() {
                                    let score = peaks.logit(x)
                                    if score > bestScore { best = i; bestScore = score }
                                }
                                results[index].textColor = rgb(options.colours[best])
                            }
                            analyses[index] = analysis
                        }
                    }
                }
            }
        }
        // pass 2: page consensus of the outline score (lettering is consistent within a page)
        let present = scores.compactMap { $0 }
        guard !present.isEmpty else { return results }
        let pageScore = PipelineRemovalMask.median(present)
        for index in analyses.indices {
            guard let score = scores[index], let observation = observations[index] else { continue }
            let z = P.outlinePage[0] * score + P.outlinePage[1] * pageScore + P.outlinePage[2]
            if z >= 0 {
                results[index].strokeColor = rgb(observation.colour)
                let width = P.outlineWidthRing * observation.ringWidth + P.outlineWidthFont * Double(fonts[index]) + P.outlineWidthBias
                results[index].strokeWidth = CGFloat(max(0, width))
            }
        }
        return results
    }
}

// MARK: - Page style consistency

/// A page letters with a few styles, and S8 misses drift off them. Blocks whose every pair lies within
/// a style distance of 15 (complete linkage; CIE76 fill dE; half the stroke dE when both have an outline;
/// an outline mismatch counts as 40) share one style: the group's medoid fill, the majority outline, the
/// medoid stroke among outlined members and the median stroke width per font px. Bold and size
/// stay per block. Text under 4 characters (SFX, ruby, fragments; mostly not GT lettering) takes
/// no part. Fit on TRAIN folds against the colour GT (`port-eval/colorfix/sim.py`).
enum PipelineStyleConsistency {
    static let threshold = 15.0
    static let outlineMismatch = 40.0
    static let strokeWeight = 0.5
    static let minimumCharacters = 4

    static func deltaE(_ a: PipelineRGB, _ b: PipelineRGB) -> Double {
        PipelineStyleEstimator.deltaE([Double(a.r), Double(a.g), Double(a.b)], [Double(b.r), Double(b.g), Double(b.b)])
    }

    static func distance(_ a: PipelineStyle, _ b: PipelineStyle) -> Double {
        var d = deltaE(a.textColor, b.textColor)
        switch (a.strokeColor, b.strokeColor) {
        case let (s?, t?): d = max(d, strokeWeight * deltaE(s, t))
        case (nil, nil): break
        default: d = max(d, outlineMismatch)
        }
        return d
    }

    static func unify(_ all: [PipelineStyle], characters: [Int]) -> [PipelineStyle] {
        let members = all.indices.filter { characters[$0] >= minimumCharacters }
        let unified = unify(members.map { all[$0] })
        var result = all
        for (k, index) in members.enumerated() { result[index] = unified[k] }
        return result
    }

    static func unify(_ styles: [PipelineStyle]) -> [PipelineStyle] {
        let n = styles.count
        guard n >= 2 else { return styles }
        var d = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let value = distance(styles[i], styles[j])
                d[i * n + j] = value
                d[j * n + i] = value
            }
        }
        // Complete linkage: repeatedly merge the two groups whose farthest pair is closest, while that
        // pair stays within the threshold (no chaining of similar-but-distinct colours).
        var groups = (0..<n).map { [$0] }
        while true {
            var best = Double.infinity, pair: (Int, Int)?
            for a in groups.indices {
                for b in (a + 1)..<groups.count {
                    var link = 0.0
                    for i in groups[a] { for j in groups[b] { link = max(link, d[i * n + j]) } }
                    if link <= threshold, link < best { best = link; pair = (a, b) }
                }
            }
            guard let (a, b) = pair else { break }
            groups[a] += groups[b]
            groups.remove(at: b)
        }
        var result = styles
        for group in groups {
            guard group.count >= 2 else { continue }
            var medoid = group[0], best = Double.infinity
            for i in group {
                var total = 0.0
                for j in group { total += d[i * n + j] }
                if total < best { best = total; medoid = i }
            }
            let outlined = group.filter { styles[$0].strokeColor != nil }
            var strokeMedoid: Int?
            var bestStroke = Double.infinity
            for i in outlined {
                var total = 0.0
                for j in outlined { total += deltaE(styles[i].strokeColor!, styles[j].strokeColor!) }
                if total < bestStroke { bestStroke = total; strokeMedoid = i }
            }
            let outline = 2 * outlined.count >= group.count
            let ratios = outlined.map { Double(styles[$0].strokeWidth) / max(1, Double(styles[$0].fontPixels)) }.sorted()
            var ratio = 0.0
            if !ratios.isEmpty {
                let mid = ratios.count / 2
                ratio = ratios.count % 2 == 1 ? ratios[mid] : (ratios[mid - 1] + ratios[mid]) / 2
            }
            for index in group {
                result[index].textColor = styles[medoid].textColor
                if outline, let strokeMedoid {
                    result[index].strokeColor = styles[strokeMedoid].strokeColor
                    result[index].strokeWidth = CGFloat(ratio * Double(styles[index].fontPixels))
                } else {
                    result[index].strokeColor = nil
                    result[index].strokeWidth = 0
                }
            }
        }
        return result
    }
}

// MARK: - Bold (source weight)

/// Body of the picked fill inside the lines: pixels within deltaE 15 of the fill in the line polygons grown by
/// 0.1 font, minus the components that reach the grown region's edge (balloon/background of the fill colour).
/// `ridge`: 75th percentile of the body's distance-transform ridge (local 3x3 maxima) as full width / font;
/// `cover`: body share of the line polygon area. Rule and thresholds: `port-eval/bold/bo` (TRAIN folds).
extension PipelineStyleEstimator {
    struct BoldMeasure { var ridge: Double; var cover: Double }
    static let boldMaximumPixels = 2_000_000

    static func boldMeasure(_ image: CGImage, block: PipelineBlock, font: Double, fill: PipelineRGB,
                            raster: PipelinePageRaster?) -> BoldMeasure? {
        guard font.isFinite, font > 0,
              let (crop, s) = makeCrop(image, block: block, font: font, raster: raster, limit: boldMaximumPixels) else { return nil }
        let w = crop.width, h = crop.height, n = w * h
        let lineCount = crop.lines.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard lineCount >= 16 else { return nil }
        let grow = max(1, Int(0.1 * font * s))
        // ROI: within `grow` of the lines. Every line pixel lies in the lines' box, so the transform of that box
        // grown by `grow` is exact inside it, and every pixel outside it is farther than `grow`.
        var lx0 = w, ly0 = h, lx1 = -1, ly1 = -1
        crop.lines.withUnsafeBufferPointer { lines in
            for y in 0..<h {
                let row = y * w
                for x in 0..<w where lines[row + x] {
                    if x < lx0 { lx0 = x }
                    if x > lx1 { lx1 = x }
                    if y < ly0 { ly0 = y }
                    ly1 = y
                }
            }
        }
        let rx0 = max(0, lx0 - grow), ry0 = max(0, ly0 - grow), rx1 = min(w - 1, lx1 + grow), ry1 = min(h - 1, ly1 + grow)
        let rw = rx1 - rx0 + 1, rh = ry1 - ry0 + 1
        let windowLines = [Bool](unsafeUninitializedCapacity: rw * rh) { out, count in
            crop.lines.withUnsafeBufferPointer { lines in
                for y in 0..<rh { for x in 0..<rw { out[y * rw + x] = lines[(y + ry0) * w + x + rx0] } }
            }
            count = rw * rh
        }
        let windowDistance2 = squaredDistance(to: windowLines, width: rw, height: rh)
        var roi = [Bool](repeating: false, count: n)
        let grow2 = grow * grow
        roi.withUnsafeMutableBufferPointer { roi in
            windowDistance2.withUnsafeBufferPointer { d in
                for y in 0..<rh { for x in 0..<rw { roi[(y + ry0) * w + x + rx0] = Int(d[y * rw + x]) <= grow2 } }
            }
        }
        let linear = linearTable
        let target = lab([Double(fill.r), Double(fill.g), Double(fill.b)])
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        func near(_ r: Double, _ g: Double, _ b: Double) -> Bool {
            let fy = f(0.2126 * r + 0.7152 * g + 0.0722 * b)
            let dl = 116 * fy - 16 - target[0]
            // Adding the non-negative a/b terms never lowers the rounded sum: a lightness gap alone decides.
            guard dl * dl < 225 else { return false }
            let fx = f((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047), fz = f((0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883)
            let da = 500 * (fx - fy) - target[1], db = 200 * (fy - fz) - target[2]
            return dl * dl + da * da + db * db < 225
        }
        // The test depends on the colour alone: memoise it (direct-mapped, 24-bit key; -1 empty).
        let cacheSize = 4096
        var cacheKey = [Int32](repeating: -1, count: cacheSize)
        var cacheValue = [Bool](repeating: false, count: cacheSize)
        var body = [Bool](repeating: false, count: n)
        body.withUnsafeMutableBufferPointer { body in
            roi.withUnsafeBufferPointer { roi in
                crop.rgb.withUnsafeBufferPointer { rgb in
                    cacheKey.withUnsafeMutableBufferPointer { cacheKey in
                        cacheValue.withUnsafeMutableBufferPointer { cacheValue in
                            linear.withUnsafeBufferPointer { linear in
                                for y in ry0...ry1 {
                                    for i in (y * w + rx0)...(y * w + rx1) where roi[i] {
                                        let r = Int(rgb[3 * i]), g = Int(rgb[3 * i + 1]), b = Int(rgb[3 * i + 2])
                                        let key = Int32(r << 16 | g << 8 | b)
                                        let slot = (r &* 7 ^ g &* 61 ^ b &* 509 ^ (r ^ g) << 4) & (cacheSize - 1)
                                        if cacheKey[slot] == key { body[i] = cacheValue[slot]; continue }
                                        let value = near(linear[r], linear[g], linear[b])
                                        cacheKey[slot] = key; cacheValue[slot] = value
                                        body[i] = value
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // Drop body components (4-connected) holding a pixel on the edge of the grown region.
        var stack: [Int] = []
        for y in ry0...ry1 {
            for i in (y * w + rx0)...(y * w + rx1) where body[i] {
                let x = i % w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 || !roi[i - 1] || !roi[i + 1] || !roi[i - w] || !roi[i + w] {
                    body[i] = false; stack.append(i)
                }
            }
        }
        func visit(_ j: Int) { if body[j] { body[j] = false; stack.append(j) } }
        while let i = stack.popLast() {
            let x = i % w
            if x > 0 { visit(i - 1) }
            if x < w - 1 { visit(i + 1) }
            if i >= w { visit(i - w) }
            if i + w < n { visit(i + w) }
        }
        var bodyCount = 0, covered = 0
        var bx0 = w, by0 = h, bx1 = -1, by1 = -1
        for y in ry0...ry1 {
            for x in rx0...rx1 where body[y * w + x] {
                bodyCount += 1
                if crop.lines[y * w + x] { covered += 1 }
                if x < bx0 { bx0 = x }
                if x > bx1 { bx1 = x }
                if y < by0 { by0 = y }
                by1 = y
            }
        }
        guard bodyCount >= 30 else { return nil }
        // Distance to the nearest non-body pixel on the body's box grown by 1 (body never touches the crop
        // edge, so that ring is non-body and clamping any farther pixel onto it is no farther: exact).
        let ox = bx0 - 1, oy = by0 - 1, bw = bx1 - bx0 + 3, bh = by1 - by0 + 3
        let outside = [Bool](unsafeUninitializedCapacity: bw * bh) { out, count in
            for y in 0..<bh { for x in 0..<bw { out[y * bw + x] = !body[(y + oy) * w + x + ox] } }
            count = bw * bh
        }
        let distance2 = squaredDistance(to: outside, width: bw, height: bh)
        var ridge: [Double] = []
        for y in 1..<(bh - 1) {
            for x in 1..<(bw - 1) where !outside[y * bw + x] {
                let d = distance2[y * bw + x]
                var top = true
                for dy in -1...1 where top {
                    let row = (y + dy) * bw
                    for dx in -1...1 where distance2[row + x + dx] > d { top = false; break }
                }
                if top { ridge.append(2 * Double(d).squareRoot()) }
            }
        }
        ridge.sort()
        let q = 0.75 * Double(ridge.count - 1), lo = Int(q), hi = min(ridge.count - 1, lo + 1)
        let p75 = ridge[lo] + (ridge[hi] - ridge[lo]) * (q - Double(lo))
        return BoldMeasure(ridge: p75 / (font * s), cover: Double(covered) / Double(lineCount))
    }
}

