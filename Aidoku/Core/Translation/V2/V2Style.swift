import CoreGraphics
import Foundation

// S8 source style estimation for the V2 pipeline (see Docs/translation-v2.md).
// Cheap, model-free per-block measurement on a bounded crop:
// - font px: the legacy simple geometric rule (NativeSimpleSourceFont with the
//   production minimal-policy calibration and member-logratio grouping), ported.
// - fill: candidates are k-means colour clusters inside the line polygons, their
//   parts cut off from the surroundings, and a re-clustering of interior pixels;
//   small TRAIN-fit boosted trees (V2StyleParameters) pick the fill from cheap
//   enclosure/contrast/stroke/neighbour features plus a page colour consensus.
//   The colour is the median of the candidate's stroke-core pixels.
// - outline: colour profile of distance rings around the fill mask; presence by
//   boosted trees plus page consensus, width by ring-colour persistence.
// - bold: always regular (no cheap signal; one bold face is bundled).
// Constants were fit on TRAIN and selected on DEV (the out-of-repo research scripts (scripts-style)).

extension V2Style {
    /// Fills `style` on every block; blocks keep order and all other fields.
    static func estimate(_ page: V2Page, blocks: [V2Block]) -> [V2Block] {
        V2StyleEstimator.estimate(page, blocks: blocks)
    }
}

/// Measurement detail (includes the local background colour, which V2Style
/// does not carry) for harness evaluation.
struct V2StyleMeasurement: Sendable, Equatable {
    var style: V2Style
    var background: V2RGB?
    var outlineScore: Double
    var strokeRatio: Double
}

enum V2StyleEstimator {
    static func estimate(_ page: V2Page, blocks: [V2Block]) -> [V2Block] {
        let measured = measure(page, blocks: blocks)
        return zip(blocks, measured).map { block, measurement in
            var block = block
            block.style = measurement.style
            return block
        }
    }

    static func measure(_ page: V2Page, blocks: [V2Block]) -> [V2StyleMeasurement] {
        let fonts = V2SimpleFont.estimate(blocks)
        var analyses = analyzeAll(page.image, blocks: blocks, fonts: fonts)
        return decide(&analyses, fonts: fonts)
    }

    /// Blocks are independent; measure them concurrently.
    static func analyzeAll(_ image: CGImage, blocks: [V2Block], fonts: [CGFloat]) -> [BlockAnalysis?] {
        let results = UnsafeMutableBufferPointer<BlockAnalysis?>.allocate(capacity: blocks.count)
        results.initialize(repeating: nil)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: blocks.count) { index in
            results[index] = analyze(image, block: blocks[index], font: fonts[index])
        }
        return Array(results)
    }
}

// MARK: - Font size (port of NativeSimpleSourceFont, production minimal policy)

enum V2SimpleFont {
    // NativeSourceInferencePolicy minimal-m1-p9-body64-presence95 calibration.
    static let scale = 0.43853239073260936
    static let bias = 4.094089327930639
    static let memberShortScale = 0.4140206805546956
    static let bodyRatioWeight = 0.8212525806130213
    static let maximumLogDistance = 0.9705176286667344
    static let groupedSizeScale = 1.0252379527066393

    static func estimate(_ blocks: [V2Block]) -> [CGFloat] {
        guard !blocks.isEmpty else { return [] }
        var values: [Double] = [], members: [Double] = []
        for block in blocks {
            let width = Double(block.bounds.width), height = Double(block.bounds.height)
            let count = max(1, block.sourceText.unicodeScalars.count)
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
        let order = values.indices.sorted {
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
        for group in groups {
            let sorted = group.map { values[$0] }.sorted(), middle = group.count / 2
            let median = group.count % 2 == 1 ? sorted[middle] :
                sorted[middle - 1] + (sorted[middle] - sorted[middle - 1]) * 0.5
            for index in group { result[index] = median }
        }
        return result.map { CGFloat($0 * groupedSizeScale) }
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

    /// Returns the polygon itself when already convex (same vertex order as the
    /// legacy port), otherwise Andrew's monotone chain hull.
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

/// Cheap colour/structure features of one block crop (working pixels are the
/// crop downscaled to at most `maximumPixels`; lengths are reported in page px).
struct V2StyleFeatures: Sendable {
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
        var count: Int
        var median: [Double]
        var mad: Double
    }
    var font: Double
    var scale: Double = 1
    var ringBackground: [Double] = [255, 255, 255]
    var clusters: [Cluster] = []
    /// Ring profiles outside each cluster mask (only filled for requested clusters).
    var profiles: [Int: [Ring?]] = [:]
}

extension V2StyleEstimator {
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
        var exterior: [Bool] = []
        var exteriorOwn: [Bool] = []
        var exteriorDistance2: [Int32] = []
    }

    /// A measured block: features plus the working crop kept for ring profiles.
    struct BlockAnalysis {
        var features: V2StyleFeatures
        let crop: Crop
        mutating func profile(_ cluster: Int) -> [V2StyleFeatures.Ring?] {
            if let cached = features.profiles[cluster] { return cached }
            let rings = V2StyleEstimator.ringProfile(crop, cluster: cluster, scale: features.scale, font: features.font)
            features.profiles[cluster] = rings
            return rings
        }
    }

    static func analyze(_ image: CGImage, block: V2Block, font: CGFloat) -> BlockAnalysis? {
        let font = Double(font)
        guard var crop = makeCrop(image, block: block, font: font) else { return nil }
        var result = V2StyleFeatures(font: font, scale: crop.scale)
        let n = crop.crop.width * crop.crop.height
        let lineCount = crop.crop.lines.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard lineCount >= 16 else { return nil }
        let s = crop.scale
        crop.crop.lineDistance2 = squaredDistance(to: crop.crop.lines, width: crop.crop.width, height: crop.crop.height)
        let ringRadius = max(2, 0.2 * font * s)
        let ringRadius2 = ringRadius * ringRadius
        crop.crop.ring = crop.crop.lineDistance2.map { Double($0) > ringRadius2 }
        if crop.crop.ring.reduce(0, { $0 + ($1 ? 1 : 0) }) < 16 { crop.crop.ring = crop.crop.lines.map { !$0 } }
        // k-means on line pixels
        let centres = kMeans(crop.crop, k: clusterCount, include: crop.crop.lines)
        crop.crop.assignment = assign(crop.crop, centres: centres)
        let k = clusterCount
        var inLines = [Int](repeating: 0, count: k), inRing = [Int](repeating: 0, count: k)
        var ringCount = 0
        crop.crop.assignment.withUnsafeBufferPointer { assignment in
            crop.crop.lines.withUnsafeBufferPointer { lines in
                crop.crop.ring.withUnsafeBufferPointer { ring in
                    for i in 0..<n {
                        let a = Int(assignment[i])
                        if lines[i] { inLines[a] += 1 }
                        if ring[i] { inRing[a] += 1; ringCount += 1 }
                    }
                }
            }
        }
        result.ringBackground = channelMedian(crop.crop.rgb, mask: crop.crop.ring)
        // exterior: ring plus same-cluster 4-connected regions reachable from ring pixels
        floodExterior(&crop.crop)
        // Line polygons covering the whole crop leave no exterior: every exterior distance would be
        // Int32.max and `measureCluster` would allocate a 2^31-entry histogram.
        guard crop.crop.exterior.contains(true) else { return nil }
        let labels = Labels(width: crop.crop.width, height: crop.crop.height)
        crop.crop.exteriorDistance2 = squaredDistance(to: crop.crop.exterior, width: crop.crop.width, height: crop.crop.height)
        result.clusters = (0..<k).map { j in
            var cluster = V2StyleFeatures.Cluster()
            cluster.inLines = Double(inLines[j]) / Double(lineCount)
            cluster.inRing = Double(inRing[j]) / Double(max(1, ringCount))
            measureCluster(crop.crop, members: candidateMembers(crop.crop, candidate: j), labels: labels, scale: s,
                           into: &cluster)
            return cluster
        }
        // Enclosed variants (candidate k + j): the part of a mostly-exterior cluster that is
        // cut off from the surroundings, e.g. a white fill inside an outline on a white ground.
        for j in 0..<k {
            var cluster = V2StyleFeatures.Cluster()
            cluster.enclosed = true
            if result.clusters[j].valid, result.clusters[j].exterior >= enclosedExteriorMinimum {
                let members = candidateMembers(crop.crop, candidate: k + j)
                cluster.inLines = Double(members.reduce(0) { $0 + (crop.crop.lines[$1] ? 1 : 0) }) / Double(lineCount)
                measureCluster(crop.crop, members: members, labels: labels, scale: s, into: &cluster)
                if cluster.count < 16 { cluster.count = 0 }
            }
            result.clusters.append(cluster)
        }
        // Interior re-clustering (candidates 2k + j): separates a thin fill from art colours it was
        // merged with in the first-level clusters.
        var interior = [Bool](repeating: false, count: n)
        var interiorCount = 0
        for i in 0..<n where crop.crop.lines[i] && !crop.crop.exteriorOwn[i] { interior[i] = true; interiorCount += 1 }
        crop.crop.interiorAssignment = [UInt8](repeating: 255, count: n)
        if interiorCount >= 16 {
            let centres = kMeans(crop.crop, k: interiorClusterCount, include: interior)
            let flat = centres.flatMap { $0 }
            for i in 0..<n where crop.crop.lineDistance2[i] <= 4 && !crop.crop.exteriorOwn[i] {
                let r = Float(crop.crop.rgb[i * 3]), g = Float(crop.crop.rgb[i * 3 + 1]), b = Float(crop.crop.rgb[i * 3 + 2])
                var best = 0, bestD = Float.infinity
                for j in 0..<interiorClusterCount {
                    let x = r - flat[j * 3], y = g - flat[j * 3 + 1], z = b - flat[j * 3 + 2]
                    let d = x * x + y * y + z * z
                    if d < bestD { bestD = d; best = j }
                }
                crop.crop.interiorAssignment[i] = UInt8(best)
            }
        }
        for j in 0..<interiorClusterCount {
            var cluster = V2StyleFeatures.Cluster()
            cluster.interior = true
            if interiorCount >= 16 {
                let members = candidateMembers(crop.crop, candidate: 2 * k + j)
                cluster.inLines = Double(members.reduce(0) { $0 + (crop.crop.lines[$1] ? 1 : 0) }) / Double(lineCount)
                measureCluster(crop.crop, members: members, labels: labels, scale: s, into: &cluster)
                if cluster.count < 16 { cluster.count = 0 }
            }
            result.clusters.append(cluster)
        }
        return BlockAnalysis(features: result, crop: crop.crop)
    }

    private static func makeCrop(_ image: CGImage, block: V2Block, font: Double) -> (crop: Crop, scale: Double)? {
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
        var s = min(1, (Double(maximumPixels) / Double((x1 - x0) * (y1 - y0))).squareRoot())
        var w = x1 - x0, h = y1 - y0
        if s < 1 {
            w = max(4, Int(Double(x1 - x0) * s)); h = max(4, Int(Double(y1 - y0) * s))
            s = Double(w) / Double(x1 - x0)
        }
        guard let source = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else { return nil }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let drawn: Bool = rgba.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = s < 1 ? .medium : .none
            context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2]
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

    // MARK: clustering

    private static func kMeans(_ crop: Crop, k: Int, include: [Bool]) -> [[Float]] {
        let total = include.reduce(0) { $0 + ($1 ? 1 : 0) }
        let step = max(1, total / maximumSamples)
        // Samples as flat RGB triples.
        var samples: [Float] = []
        samples.reserveCapacity(3 * (total / step + 1))
        var seen = 0
        crop.rgb.withUnsafeBufferPointer { rgb in
            include.withUnsafeBufferPointer { m in
                for i in 0..<(crop.width * crop.height) where m[i] {
                    if seen % step == 0 {
                        samples.append(Float(rgb[i * 3])); samples.append(Float(rgb[i * 3 + 1])); samples.append(Float(rgb[i * 3 + 2]))
                    }
                    seen += 1
                }
            }
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
                for _ in 0..<8 {
                    for j in 0..<(3 * k) { sums[j] = 0 }
                    for j in 0..<k { counts[j] = 0 }
                    for i in 0..<count {
                        var best = 0, bestD = Float.infinity
                        for j in 0..<k { let d = d2(i, c + 3 * j); if d < bestD { bestD = d; best = j } }
                        sums[3 * best] += Double(x[3 * i]); sums[3 * best + 1] += Double(x[3 * i + 1])
                        sums[3 * best + 2] += Double(x[3 * i + 2]); counts[best] += 1
                    }
                    for j in 0..<k where counts[j] > 0 {
                        for ch in 0..<3 { c[3 * j + ch] = Float(sums[3 * j + ch] / Double(counts[j])) }
                    }
                }
            }
        }
        return (0..<k).map { Array(centres[(3 * $0)..<(3 * $0 + 3)]) }
    }

    /// numpy.percentile (linear) via selection.
    private static func percentile(_ values: [Float], _ q: Double) -> Float {
        let position = q / 100 * Double(values.count - 1)
        let lower = Int(position), upper = min(values.count - 1, lower + 1)
        let low = select(values, lower)
        let high = upper == lower ? low : select(values, upper)
        return low + Float(position - Double(lower)) * (high - low)
    }

    /// k-th smallest value (0-based), Hoare quickselect on a copy.
    static func select(_ values: [Float], _ k: Int) -> Float {
        var a = values
        var lo = 0, hi = a.count - 1
        while lo < hi {
            let pivot = a[(lo + hi) / 2]
            var i = lo, j = hi
            while i <= j {
                while a[i] < pivot { i += 1 }
                while a[j] > pivot { j -= 1 }
                if i <= j { a.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { return a[k] }
        }
        return a[k]
    }

    private static func assign(_ crop: Crop, centres: [[Float]]) -> [UInt8] {
        let n = crop.width * crop.height
        let flat = centres.flatMap { $0 }
        let k = centres.count
        return [UInt8](unsafeUninitializedCapacity: n) { out, count in
            crop.rgb.withUnsafeBufferPointer { rgb in
                flat.withUnsafeBufferPointer { c in
                    for i in 0..<n {
                        let r = Float(rgb[i * 3]), g = Float(rgb[i * 3 + 1]), b = Float(rgb[i * 3 + 2])
                        var best = 0, bestD = Float.infinity
                        for j in 0..<k {
                            let x = r - c[j * 3], y = g - c[j * 3 + 1], z = b - c[j * 3 + 2]
                            let d = x * x + y * y + z * z
                            if d < bestD { bestD = d; best = j }
                        }
                        out[i] = UInt8(best)
                    }
                }
            }
            count = n
        }
    }

    private static func floodExterior(_ crop: inout Crop) {
        let w = crop.width, h = crop.height, n = w * h
        var own = [Bool](repeating: false, count: n)
        var stack: [Int] = []
        stack.reserveCapacity(n / 4)
        for i in 0..<n where crop.ring[i] { own[i] = true; stack.append(i) }
        crop.assignment.withUnsafeBufferPointer { a in
            while let i = stack.popLast() {
                let x = i % w, label = a[i]
                if x > 0, !own[i - 1], a[i - 1] == label { own[i - 1] = true; stack.append(i - 1) }
                if x + 1 < w, !own[i + 1], a[i + 1] == label { own[i + 1] = true; stack.append(i + 1) }
                if i >= w, !own[i - w], a[i - w] == label { own[i - w] = true; stack.append(i - w) }
                if i + w < n, !own[i + w], a[i + w] == label { own[i + w] = true; stack.append(i + w) }
            }
        }
        crop.exteriorOwn = own
        crop.exterior = own
    }

    static let enclosedExteriorMinimum = 0.3

    /// Candidate j < k: cluster j pixels within 2 working px of the line polygons;
    /// candidate k + j: the same minus pixels connected to the surroundings.
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

    /// Member pixels of `candidateMask(crop, candidate:)` in raster order.
    static func candidateMembers(_ crop: Crop, candidate: Int) -> [Int] {
        let n = crop.width * crop.height
        var members: [Int] = []
        if candidate >= 2 * clusterCount {
            let label = UInt8(candidate - 2 * clusterCount)
            crop.interiorAssignment.withUnsafeBufferPointer { a in
                for i in 0..<n where a[i] == label { members.append(i) }
            }
            return members
        }
        let label = UInt8(candidate % clusterCount), enclosed = candidate >= clusterCount
        crop.assignment.withUnsafeBufferPointer { a in
            crop.lineDistance2.withUnsafeBufferPointer { d in
                crop.exteriorOwn.withUnsafeBufferPointer { own in
                    for i in 0..<n where a[i] == label && d[i] <= 4 && !(enclosed && own[i]) { members.append(i) }
                }
            }
        }
        return members
    }

    /// Per-block label plane on a 2 px border: bit 0 member, bit 1 outside the crop, bit 2 already
    /// counted in the shell. `measureCluster` leaves it as it found it.
    final class Labels {
        static let member: UInt8 = 1, outside: UInt8 = 2, marked: UInt8 = 4
        let width: Int, height: Int, stride: Int
        let base: UnsafeMutablePointer<UInt8>
        init(width: Int, height: Int) {
            self.width = width; self.height = height; stride = width + 4
            base = .allocate(capacity: stride * (height + 4))
            base.initialize(repeating: Labels.outside, count: stride * (height + 4))
            for y in 0..<height { (base + (y + 2) * stride + 2).update(repeating: 0, count: width) }
        }
        deinit { base.deallocate() }
        func at(_ i: Int) -> UnsafeMutablePointer<UInt8> { base + (i / width + 2) * stride + i % width + 2 }
    }

    private static func measureCluster(_ crop: Crop, members: [Int], labels: Labels, scale s: Double,
                                       into c: inout V2StyleFeatures.Cluster) {
        let w = crop.width
        let count = members.count
        c.count = count
        guard count >= 4 else { return }
        let member = Labels.member, marked = Labels.marked, pw = labels.stride
        for i in members { labels.at(i).pointee = member }
        let offsets = [(-2, 0), (2, 0), (0, -2), (0, 2), (-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
        let shellOffsets = offsets.map { dx, dy in (padded: dy * pw + dx, crop: dy * w + dx) }
        var exterior = 0, perimeter = 0, coreCount = 0
        var neighbours = [Int](repeating: 0, count: clusterCount), shell = 0, shellExterior = 0
        var shellPixels: [Int] = []
        var maximumDistance: Int32 = 0
        crop.exteriorDistance2.withUnsafeBufferPointer { dist in
            for i in members { maximumDistance = max(maximumDistance, dist[i]) }
        }
        // Squared distances can reach w^2 + h^2 on long thin crops; a histogram that large would be
        // a huge allocation, so such clusters take the same median from their sorted distances.
        let useHistogram = maximumDistance <= maximumDistanceHistogram
        var histogram = [Int](repeating: 0, count: useHistogram ? Int(maximumDistance) + 1 : 1)
        // Channel histograms of all members and of the core members (medians are order-free).
        var all = [Int](repeating: 0, count: 768), core = all
        withPointers(crop, &histogram, &all, &core) { own, dist, rgb, a, e, histogram, all, core in
            for i in members {
                let p = labels.at(i)
                if own[i] { exterior += 1 }
                // perimeter: 4-neighbour erosion with zero border
                if p[-1] & p[1] & p[-pw] & p[pw] & member == 0 { perimeter += 1 }
                // core: no non-cluster pixel within distance < 1.5 (3x3); outside the crop does not count
                let isCore = p[-pw - 1] & 3 != 0 && p[-pw] & 3 != 0 && p[-pw + 1] & 3 != 0 && p[-1] & 3 != 0
                    && p[1] & 3 != 0 && p[pw - 1] & 3 != 0 && p[pw] & 3 != 0 && p[pw + 1] & 3 != 0
                let r = Int(rgb[i * 3]), g = 256 + Int(rgb[i * 3 + 1]), b = 512 + Int(rgb[i * 3 + 2])
                all[r] += 1; all[g] += 1; all[b] += 1
                if isCore { coreCount += 1; core[r] += 1; core[g] += 1; core[b] += 1 }
                if useHistogram { histogram[Int(dist[i])] += 1 }
                // shell: pixels within Euclidean distance 2 outside the mask
                for offset in shellOffsets where p[offset.padded] == 0 {
                    p[offset.padded] = marked
                    let j = i + offset.crop
                    shellPixels.append(j)
                    shell += 1
                    neighbours[Int(a[j])] += 1
                    if e[j] { shellExterior += 1 }
                }
            }
        }
        for i in members { labels.at(i).pointee = 0 }
        for j in shellPixels { labels.at(j).pointee = 0 }
        c.exterior = Double(exterior) / Double(count)
        let useCore = coreCount >= 4
        let source = useCore ? core : all, total = useCore ? coreCount : count
        c.core = (0..<3).map { ch in histogramMedian(Array(source[(256 * ch)..<(256 * ch + 256)]), count: total) }
        c.coreCount = total
        c.strokeWidth = 2 * Double(count) / Double(max(1, perimeter)) / s
        if useHistogram {
            c.exteriorDistance = squaredHistogramMedian(histogram, count: count) / s
        } else {
            let sorted = members.map { Double(crop.exteriorDistance2[$0]).squareRoot() }.sorted()
            c.exteriorDistance = (count % 2 == 1 ? sorted[count / 2] : (sorted[count / 2 - 1] + sorted[count / 2]) / 2) / s
        }
        c.neighbourPurity = Double(neighbours.max() ?? 0) / Double(max(1, shell))
        c.neighbours = neighbours.map { Double($0) / Double(max(1, shell)) }
        c.shellExterior = Double(shellExterior) / Double(max(1, shell))
    }

    /// Crop planes (exterior-own, exterior distance, RGB, assignment, exterior) and three
    /// mutable histograms as buffer pointers for `measureCluster`.
    private static func withPointers(
        _ crop: Crop, _ histogram: inout [Int], _ all: inout [Int], _ core: inout [Int],
        _ body: (UnsafeBufferPointer<Bool>, UnsafeBufferPointer<Int32>, UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>,
                 UnsafeBufferPointer<Bool>, UnsafeMutableBufferPointer<Int>, UnsafeMutableBufferPointer<Int>,
                 UnsafeMutableBufferPointer<Int>) -> Void
    ) {
        crop.exteriorOwn.withUnsafeBufferPointer { own in
            crop.exteriorDistance2.withUnsafeBufferPointer { dist in
                crop.rgb.withUnsafeBufferPointer { rgb in
                    crop.assignment.withUnsafeBufferPointer { a in
                        crop.exterior.withUnsafeBufferPointer { e in
                            histogram.withUnsafeMutableBufferPointer { histogram in
                                all.withUnsafeMutableBufferPointer { all in
                                    core.withUnsafeMutableBufferPointer { core in
                                        body(own, dist, rgb, a, e, histogram, all, core)
                                    }
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

    static func ringBins(font: Double, scale s: Double) -> Int { min(40, max(12, Int((0.3 * font * s).rounded(.up)))) }

    static func ringProfile(_ crop: Crop, cluster j: Int, scale s: Double, font: Double) -> [V2StyleFeatures.Ring?] {
        let n = crop.width * crop.height
        let mask = candidateMask(crop, candidate: j)
        let distance2 = squaredDistance(to: mask, width: crop.width, height: crop.height)
        let limit = max(2, 0.45 * font * s), limit2 = limit * limit
        let bins = ringBins(font: font, scale: s)
        var members = [[Int]](repeating: [], count: bins + 1)
        for i in 0..<n where distance2[i] > 0 && Double(crop.lineDistance2[i]) <= limit2 {
            // bin b holds b - 0.5 < d <= b + 0.5
            let b = Int((Double(distance2[i]).squareRoot() - 0.5).rounded(.up))
            if b >= 1, b <= bins { members[b].append(i) }
        }
        return (1...bins).map { b -> V2StyleFeatures.Ring? in
            let pixels = members[b]
            guard pixels.count >= 4 else { return nil }
            let median = channelMedian(crop.rgb, indices: pixels)
            var histogram = [Int](repeating: 0, count: 1531)
            for i in pixels {
                var total: Double = 0
                for ch in 0..<3 { total += abs(Double(crop.rgb[i * 3 + ch]) - median[ch]) }
                histogram[Int((total * 2).rounded())] += 1
            }
            return .init(distance: Double(b) / s, count: pixels.count, median: median,
                         mad: histogramMedian(histogram, count: pixels.count) / 2)
        }
    }

    // MARK: primitives

    /// Exact squared Euclidean distance to the nearest `true` pixel (Felzenszwalb).
    static func squaredDistance(to target: [Bool], width w: Int, height h: Int) -> [Int32] {
        let infinity: Int64 = 1 << 40
        let m = max(w, h)
        var grid = [Int64](repeating: 0, count: w * h)
        var out = [Int32](repeating: 0, count: w * h)
        let f = UnsafeMutablePointer<Int64>.allocate(capacity: m), d = UnsafeMutablePointer<Int64>.allocate(capacity: m)
        let v = UnsafeMutablePointer<Int>.allocate(capacity: m), z = UnsafeMutablePointer<Double>.allocate(capacity: m + 1)
        defer { f.deallocate(); d.deallocate(); v.deallocate(); z.deallocate() }
        func transform(_ n: Int) {
            var k = 0
            v[0] = 0; z[0] = -.infinity; z[1] = .infinity
            var q = 1
            while q < n {
                var sValue: Double
                repeat {
                    let p = v[k]
                    sValue = (Double(f[q] + Int64(q * q)) - Double(f[p] + Int64(p * p))) / Double(2 * q - 2 * p)
                    if sValue <= z[k] { k -= 1 } else { break }
                } while k >= 0
                k += 1; v[k] = q; z[k] = sValue; z[k + 1] = .infinity
                q += 1
            }
            k = 0
            for q in 0..<n {
                while z[k + 1] < Double(q) { k += 1 }
                let p = v[k]
                d[q] = Int64((q - p) * (q - p)) + f[p]
            }
        }
        target.withUnsafeBufferPointer { t in
            grid.withUnsafeMutableBufferPointer { g in
                // Column pass: for a 0/infinity input the lower envelope is exactly the squared
                // distance to the nearest target pixel in the column (or infinity), so two
                // row-major sweeps give the same values as the 1-D transform.
                let steps = UnsafeMutablePointer<Int64>.allocate(capacity: w * h)
                defer { steps.deallocate() }
                let none = Int64(Int32.max)
                for x in 0..<w { steps[x] = t[x] ? 0 : none }
                if h > 1 {
                    for y in 1..<h {
                        let row = y * w
                        for x in 0..<w {
                            let above = steps[row - w + x]
                            steps[row + x] = t[row + x] ? 0 : (above == none ? none : above + 1)
                        }
                    }
                }
                for x in 0..<w {
                    let last = (h - 1) * w + x
                    g[last] = steps[last] == none ? infinity : steps[last] * steps[last]
                }
                if h > 1 {
                    for y in stride(from: h - 2, through: 0, by: -1) {
                        let row = y * w
                        for x in 0..<w {
                            let below = steps[row + w + x]
                            let step = min(steps[row + x], below == none ? none : below + 1)
                            steps[row + x] = step
                            g[row + x] = step == none ? infinity : step * step
                        }
                    }
                }
                out.withUnsafeMutableBufferPointer { o in
                    for y in 0..<h {
                        let row = y * w
                        for x in 0..<w { f[x] = g[row + x] }
                        transform(w)
                        for x in 0..<w { o[row + x] = Int32(clamping: d[x]) }
                    }
                }
            }
        }
        return out
    }

    static func channelMedian(_ rgb: [UInt8], mask: [Bool]) -> [Double] {
        var r = [Int](repeating: 0, count: 256), g = r, b = r
        var count = 0
        rgb.withUnsafeBufferPointer { px in
            mask.withUnsafeBufferPointer { m in
                for i in 0..<m.count where m[i] {
                    r[Int(px[i * 3])] += 1; g[Int(px[i * 3 + 1])] += 1; b[Int(px[i * 3 + 2])] += 1
                    count += 1
                }
            }
        }
        guard count > 0 else { return [255, 255, 255] }
        return [histogramMedian(r, count: count), histogramMedian(g, count: count), histogramMedian(b, count: count)]
    }

    static func channelMedian(_ rgb: [UInt8], indices: [Int]) -> [Double] {
        var histograms = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        for i in indices {
            histograms[0][Int(rgb[i * 3])] += 1; histograms[1][Int(rgb[i * 3 + 1])] += 1; histograms[2][Int(rgb[i * 3 + 2])] += 1
        }
        guard !indices.isEmpty else { return [255, 255, 255] }
        return histograms.map { histogramMedian($0, count: indices.count) }
    }

    /// numpy-style median (mean of the two middle values) of a value histogram.
    static func histogramMedian(_ histogram: [Int], count: Int) -> Double {
        func kth(_ k: Int) -> Int {
            var cumulative = 0
            for (value, c) in histogram.enumerated() {
                cumulative += c
                if cumulative > k { return value }
            }
            return histogram.count - 1
        }
        return count % 2 == 1 ? Double(kth(count / 2)) : Double(kth(count / 2 - 1) + kth(count / 2)) / 2
    }

    /// Median of sqrt(value) over a histogram of squared distances.
    static func squaredHistogramMedian(_ histogram: [Int], count: Int) -> Double {
        func kth(_ k: Int) -> Double {
            var cumulative = 0
            for (value, c) in histogram.enumerated() {
                cumulative += c
                if cumulative > k { return Double(value).squareRoot() }
            }
            return Double(histogram.count - 1).squareRoot()
        }
        return count % 2 == 1 ? kth(count / 2) : (kth(count / 2 - 1) + kth(count / 2)) / 2
    }
}

// MARK: - Decisions (TRAIN-fit trees/constants in V2StyleParameters.swift, the out-of-repo research scripts (scripts-style)/model.py)

/// Flattened gradient-boosted trees (sklearn GradientBoostingClassifier export).
struct V2StyleForest: Sendable {
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

extension V2StyleEstimator {
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

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Fill-candidate features (order matches model.py cand_x + twin).
    static func candidateFeatures(_ f: V2StyleFeatures, _ j: Int, consensus: [Double]?) -> [Double] {
        let cl = f.clusters, c = cl[j], font = f.font
        let ids = cl.indices.filter { cl[$0].valid }
        let bigIDs = ids.filter { cl[$0].inLines >= 0.08 }
        let pool = bigIDs.isEmpty ? ids : bigIDs
        let maxDistance = pool.map { cl[$0].exteriorDistance }.max() ?? 0
        let colour = c.core, lum = luminance(colour)
        let sw = c.strokeWidth / font
        let fM = c.inLines, fR = c.inRing
        let plain = ids.filter { $0 < plainCandidates }
        var bgj = j
        if let first = plain.first {
            bgj = first
            for i in plain where cl[i].inRing > cl[bgj].inRing { bgj = i }
        }
        var d = bgj
        if let top = c.neighbours.max(), top > 0 { d = c.neighbours.firstIndex(of: top)! }
        let dc = cl[d].valid ? cl[d] : cl[bgj]
        let count = Double(ids.count)
        var x: [Double] = [
            c.exterior, log((fM + 0.01) / (fR + 0.01)), fM, fR, lum / 255,
            distance(colour, f.ringBackground), c.neighbourPurity, sw, chroma(colour),
            lum > 200 ? 1 : 0, c.exteriorDistance / font, Double(c.coreCount) / Double(max(1, c.count)),
            c.shellExterior, c.exteriorDistance >= maxDistance && pool.contains(j) ? 1 : 0,
            consensus.map { distance(colour, $0) } ?? 0, c.enclosed ? 1 : 0, c.interior ? 1 : 0,
            Double(ids.filter { luminance(cl[$0].core) < lum }.count) / count,
            Double(ids.filter { cl[$0].exteriorDistance < c.exteriorDistance }.count) / count,
            dc.exterior, cl[d].inRing, dc.exteriorDistance / font, distance(colour, dc.core),
            (lum - luminance(dc.core)) / 255, distance(colour, cl[bgj].core), (lum - luminance(cl[bgj].core)) / 255,
            consensus == nil ? 0 : 1
        ]
        // relation to the most similar other candidate (e.g. a purer interior twin)
        let others = ids.filter { $0 != j }
        if let first = others.first {
            var i = first
            for o in others where distance(colour, cl[o].core) < distance(colour, cl[i].core) { i = o }
            x += [distance(colour, cl[i].core), fR - cl[i].inRing, (c.exteriorDistance - cl[i].exteriorDistance) / font,
                  cl[i].interior || cl[i].enclosed ? 1 : 0, fM - cl[i].inLines]
        } else {
            x += [1, 0, 0, 0, 0]
        }
        return x
    }

    static func pickFill(_ f: V2StyleFeatures, forest: V2StyleForest, consensus: [Double]?) -> Int? {
        var best: Int?, bestScore = -Double.infinity
        for j in f.clusters.indices where f.clusters[j].valid {
            let score = forest.logit(candidateFeatures(f, j, consensus: consensus))
            if score > bestScore { best = j; bestScore = score }
        }
        return best
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

    static func outlineObservation(_ f: V2StyleFeatures, fill j: Int, rings profile: [V2StyleFeatures.Ring?],
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

    static func rgb(_ c: [Double]) -> V2RGB {
        func channel(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded(.toNearestOrEven)))) }
        return V2RGB(r: channel(c[0]), g: channel(c[1]), b: channel(c[2]))
    }

    static func decide(_ analyses: inout [BlockAnalysis?], fonts: [CGFloat]) -> [V2StyleMeasurement] {
        typealias P = V2StyleParameters
        // pass 1: per-block fill pick, page consensus colour
        let picked = analyses.compactMap { analysis in
            analysis.flatMap { a in pickFill(a.features, forest: P.fillPass1, consensus: nil).map { a.features.clusters[$0].core } }
        }
        let consensus = picked.isEmpty ? nil : median(picked)
        var results: [V2StyleMeasurement] = fonts.map {
            V2StyleMeasurement(style: V2Style(fontPixels: $0, bold: false, textColor: V2RGB(r: 0, g: 0, b: 0),
                                              strokeColor: nil, strokeWidth: 0),
                               background: nil, outlineScore: -.infinity, strokeRatio: 0)
        }
        var observations: [OutlineObservation?] = Array(repeating: nil, count: analyses.count)
        var scores: [Double?] = Array(repeating: nil, count: analyses.count)
        for index in analyses.indices {
            guard var analysis = analyses[index],
                  let j = pickFill(analysis.features, forest: P.fillPass2, consensus: consensus) else { continue }
            let f = analysis.features
            let profile = analysis.profile(j)
            let rings = profile.compactMap { $0 }
            let background = (rings.isEmpty ? f.ringBackground : median(rings.suffix(3).map(\.median)))
                .map { $0.rounded(.toNearestOrEven) }
            results[index].style.textColor = rgb(f.clusters[j].core)
            results[index].background = rgb(background)
            results[index].strokeRatio = f.clusters[j].strokeWidth / f.font
            results[index].style.bold = results[index].strokeRatio >= P.boldStrokeRatio
            if let observation = outlineObservation(f, fill: j, rings: profile, background: background) {
                observations[index] = observation
                scores[index] = P.outline.logit(observation.features)
            }
            analyses[index] = analysis
        }
        // pass 2: page consensus of the outline score (lettering is consistent within a page)
        let present = scores.compactMap { $0 }
        guard !present.isEmpty else { return results }
        let pageScore = median(present)
        for index in analyses.indices {
            guard let score = scores[index], let observation = observations[index] else { continue }
            let z = P.outlinePage[0] * score + P.outlinePage[1] * pageScore + P.outlinePage[2]
            results[index].outlineScore = z
            if z >= 0 {
                results[index].style.strokeColor = rgb(observation.colour)
                let width = P.outlineWidthRing * observation.ringWidth + P.outlineWidthFont * Double(fonts[index]) + P.outlineWidthBias
                results[index].style.strokeWidth = CGFloat(max(0, width))
            }
        }
        return results
    }
}
