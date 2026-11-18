import CoreGraphics
import Foundation

/// Source arithmetic only. No model/font/registry/GT or semantic role inputs.
/// A supplied mask retains its own upstream producer cost. This helper removes
/// appearance/weight heads, not the detector or segmentation that made the mask.
enum NativePhysicalSourceStyle {
    static let revision = "physical-source-palette-density-v1"
    enum Failure: Error { case dimensions, nonfinite }
    struct Result {
        let style: [String: Any]
        let weight: [String: Any]
        let display: [String: Any]
        let measurements: [String: Any]
    }

    static func estimate(rgb: [UInt8], width: Int, height: Int, mask: [UInt8],
        fontPrior: Double, bbox: CGRect, primary: [Float]? = nil,
        rfText: [Float]? = nil, boldThreshold: Double = 0.12) throws -> Result {
        guard width > 0, height > 0, width <= 1_500_000 / height else { throw Failure.dimensions }
        let n = width * height
        guard rgb.count == n * 3, mask.count == n,
              primary == nil || primary?.count == n,
              rfText == nil || rfText?.count == n else { throw Failure.dimensions }
        guard fontPrior.isFinite, fontPrior > 0, boldThreshold.isFinite, boldThreshold >= 0,
              bbox.minX.isFinite, bbox.minY.isFinite, bbox.width.isFinite, bbox.height.isFinite,
              bbox.width > 0, bbox.height > 0,
              primary?.allSatisfy({ $0.isFinite }) != false,
              rfText?.allSatisfy({ $0.isFinite }) != false else { throw Failure.nonfinite }
        let own = mask.map { UInt8($0 == 0 ? 0 : 1) }
        let owned = own.reduce(0) { $0 + Int($1) }
        let expanded = dilated(own, width: width, height: height, radius: 3)
        var context = [UInt8](repeating: 0, count: n)
        for i in 0..<n where expanded[i] != 0 && own[i] == 0 {
            if (primary?[i] ?? 0) < 0.1 && (rfText?[i] ?? 0) < 0.2 { context[i] = 1 }
        }
        let contextPixels = context.reduce(0) { $0 + Int($1) }
        let background: [Int]
        if let colour = dominant(rgb, selected: context).colour { background = colour }
        else if let colour = dominant(rgb, selected: own.map { $0 == 0 ? 1 : 0 }).colour { background = colour }
        else { background = medianColour(rgb, selected: [UInt8](repeating: 1, count: n)) ?? [255, 255, 255] }
        let distance = distances(own, width: width, height: height)
        let ownedDistances = distance.enumerated().compactMap { own[$0.offset] != 0 ? Double($0.element) : nil }.sorted()
        let interiorThreshold = max(1, quantile(ownedDistances, fraction: 0.4))
        var interiorInk = [UInt8](repeating: 0, count: n)
        var ink = [UInt8](repeating: 0, count: n)
        for i in 0..<n where own[i] != 0 {
            if colourDistanceSquared(rgb, i, background) >= 400 {
                ink[i] = 1
                if Double(distance[i]) >= interiorThreshold { interiorInk[i] = 1 }
            }
        }
        let fill = dominant(rgb, selected: interiorInk).colour ?? dominant(rgb, selected: ink).colour ??
            dominant(rgb, selected: own).colour ?? background
        let eroded = eroded3(own, width: width, height: height)
        var contour = [UInt8](repeating: 0, count: n)
        var boundaryCount = 0
        for i in 0..<n where own[i] != 0 {
            if eroded[i] == 0 { boundaryCount += 1 }
            if colourDistanceSquared(rgb, i, fill) >= 1024 && colourDistanceSquared(rgb, i, background) >= 400 {
                contour[i] = 1
            }
        }
        let outlineObservation = dominant(rgb, selected: contour)
        var outlinePixels = 0, boundaryColour = 0
        for i in 0..<n where outlineObservation.cluster[i] != 0 {
            outlinePixels += 1
            if own[i] != 0 && eroded[i] == 0 { boundaryColour += 1 }
        }
        let boundarySupport = Double(boundaryColour) / Double(max(1, boundaryCount))
        let outlinePresent = outlineObservation.colour != nil && boundarySupport >= 0.15 &&
            Double(outlinePixels) >= max(4, Double(owned) * 0.015)
        var outlineWidth: Double?
        if outlinePresent {
            let outlineDistance = distances(outlineObservation.cluster, width: width, height: height)
            outlineWidth = median(ridgeValues(outlineDistance, mask: outlineObservation.cluster, width: width, height: height))
        }
        var fillMask = [UInt8](repeating: 0, count: n)
        for i in 0..<n where own[i] != 0 && colourDistanceSquared(rgb, i, fill) <= 1024 { fillMask[i] = 1 }
        let fillDistance = distances(fillMask, width: width, height: height)
        let stemDiameter = 2 * (median(ridgeValues(fillDistance, mask: fillMask, width: width, height: height)) ?? 0)
        let em = max(1, fontPrior), density = stemDiameter / em, bold = density >= boldThreshold
        let fillLuminance = 0.2126 * Double(fill[0]) + 0.7152 * Double(fill[1]) + 0.0722 * Double(fill[2])
        let display: [String: Any] = ["fillRGB": fill,
            "outlineRGB": fillLuminance >= 127.5 ? [0, 0, 0] : [255, 255, 255],
            "outlineWidthPx": max(1, em * 0.035), "strokeBeforeFill": true]
        let measurements: [String: Any] = ["ownedPixels": owned, "backgroundContextPixels": contextPixels,
            "fillPixels": fillMask.reduce(0) { $0 + Int($1) }, "fillStemDiameterPx": stemDiameter,
            "sourceEMCarrierPx": em, "boundaryColourSupport": boundarySupport,
            "ownedBBoxFraction": Double(owned) / max(1, Double(bbox.width * bbox.height)),
            "emptyMask": owned == 0, "sourceAuxiliaryHeadCalls": 0,
            "insufficientObservedBackground": contextPixels == 0,
            "distanceABI": "exact-Euclidean-with-explicit-one-pixel-background-border; not OpenCV-DIST5 bit parity"]
        let style: [String: Any] = ["fill": ["rgb": fill, "colors": [fill]],
            "background": ["rgb": background, "colors": [background]],
            "outline": ["present": outlinePresent, "rgb": outlinePresent ? outlineObservation.colour as Any? ?? NSNull() : NSNull(),
                "widthPx": outlineWidth as Any? ?? NSNull()],
            "shadow": ["present": false, "rgb": NSNull(),
                "baselinePolicy": "removed-shadow-estimator; absent hypothesis, not evidence of absence"],
            "sourceOnly": true, "GTAtInference": false, "version": revision,
            "sourceAuxiliaryHeadCalls": 0, "physicalMeasurements": measurements]
        let label = bold ? "bold" : "regular"
        let weight: [String: Any] = ["sourceWeight": label, "renderWeight": label, "renderBold": bold,
            "strokeDensityScore": density, "globalThreshold": boldThreshold,
            "sourceOnly": true, "GTAtInference": false, "version": revision,
            "sourceAuxiliaryHeadCalls": 0, "sourceEMAuthority": "constructor-geometric-prior; no font-head output"]
        return Result(style: style, weight: weight, display: display, measurements: measurements)
    }

    private static func colourDistanceSquared(_ rgb: [UInt8], _ pixel: Int, _ colour: [Int]) -> Int {
        let i = pixel * 3, r = Int(rgb[i]) - colour[0], g = Int(rgb[i + 1]) - colour[1], b = Int(rgb[i + 2]) - colour[2]
        return r * r + g * g + b * b
    }
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return quantile(values.sorted(), fraction: 0.5)
    }
    private static func quantile(_ sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Double(sorted.count - 1) * fraction, lo = Int(index), hi = min(sorted.count - 1, Int(index.rounded(.up)))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (index - Double(lo))
    }
    private static func medianColour(_ rgb: [UInt8], selected: [UInt8]) -> [Int]? {
        var histograms = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3), count = 0
        for i in selected.indices where selected[i] != 0 {
            count += 1
            for c in 0..<3 { histograms[c][Int(rgb[i * 3 + c])] += 1 }
        }
        guard count > 0 else { return nil }
        return histograms.map { histogram in
            let lower = (count - 1) / 2, upper = count / 2
            var cumulative = 0, low = 0, high = 0, found = false
            for value in 0..<256 {
                cumulative += histogram[value]
                if !found && cumulative > lower { low = value; found = true }
                if cumulative > upper { high = value; break }
            }
            return Int((Double(low + high) / 2).rounded(.toNearestOrEven))
        }
    }
    private static func dominant(_ rgb: [UInt8], selected: [UInt8]) -> (colour: [Int]?, cluster: [UInt8]) {
        var counts = [Int](repeating: 0, count: 4096), best = 0, total = 0
        func code(_ i: Int) -> Int { Int(rgb[i * 3] / 16) * 256 + Int(rgb[i * 3 + 1] / 16) * 16 + Int(rgb[i * 3 + 2] / 16) }
        for i in selected.indices where selected[i] != 0 { counts[code(i)] += 1; total += 1 }
        var cluster = [UInt8](repeating: 0, count: selected.count)
        guard total > 0 else { return (nil, cluster) }
        for i in 1..<4096 where counts[i] > counts[best] { best = i }
        for i in selected.indices where selected[i] != 0 && code(i) == best { cluster[i] = 1 }
        return (medianColour(rgb, selected: cluster), cluster)
    }
    private static func dilated(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        var horizontal = [UInt8](repeating: 0, count: mask.count), result = horizontal
        for y in 0..<height {
            var sum = 0
            for x in 0..<min(width, radius) { sum += Int(mask[y * width + x]) }
            for x in 0..<width {
                if x + radius < width { sum += Int(mask[y * width + x + radius]) }
                if x - radius - 1 >= 0 { sum -= Int(mask[y * width + x - radius - 1]) }
                horizontal[y * width + x] = sum > 0 ? 1 : 0
            }
        }
        for x in 0..<width {
            var sum = 0
            for y in 0..<min(height, radius) { sum += Int(horizontal[y * width + x]) }
            for y in 0..<height {
                if y + radius < height { sum += Int(horizontal[(y + radius) * width + x]) }
                if y - radius - 1 >= 0 { sum -= Int(horizontal[(y - radius - 1) * width + x]) }
                result[y * width + x] = sum > 0 ? 1 : 0
            }
        }
        return result
    }
    private static func eroded3(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: mask.count)
        guard width > 2, height > 2 else { return result }
        for y in 1..<(height - 1) { for x in 1..<(width - 1) {
            var positive = true
            for dy in -1...1 { for dx in -1...1 where mask[(y + dy) * width + x + dx] == 0 { positive = false } }
            result[y * width + x] = positive ? 1 : 0
        } }
        return result
    }
    /// Exact separable Euclidean distance. The explicit exterior zero border
    /// makes full-mask/single-pixel cases finite rather than OpenCV's sentinel.
    private static func distances(_ mask: [UInt8], width: Int, height: Int) -> [Float] {
        var squared = [Float](repeating: 0, count: mask.count)
        for y in 0..<height {
            var last = -1
            for x in 0..<width {
                let i = y * width + x
                if mask[i] == 0 { last = x }
                squared[i] = Float((x - last) * (x - last))
            }
            last = width
            for x in stride(from: width - 1, through: 0, by: -1) {
                let i = y * width + x
                if mask[i] == 0 { last = x }
                squared[i] = min(squared[i], Float((last - x) * (last - x)))
            }
        }
        var sites = [Int](repeating: 0, count: height + 2)
        var cuts = [Double](repeating: 0, count: height + 3)
        var f = [Double](repeating: 0, count: height + 2)
        for x in 0..<width {
            f[0] = 0; f[height + 1] = 0
            for y in 0..<height { f[y + 1] = Double(squared[y * width + x]) }
            var k = 0; sites[0] = 0; cuts[0] = -.infinity; cuts[1] = .infinity
            for q in 1..<(height + 2) {
                var s: Double
                repeat {
                    let p = sites[k]
                    s = ((f[q] + Double(q * q)) - (f[p] + Double(p * p))) / Double(2 * (q - p))
                    if s <= cuts[k] { k -= 1 } else { break }
                } while k >= 0
                k += 1; sites[k] = q; cuts[k] = s; cuts[k + 1] = .infinity
            }
            k = 0
            for q in 1..<(height + 1) {
                while cuts[k + 1] < Double(q) { k += 1 }
                let delta = q - sites[k]
                squared[(q - 1) * width + x] = Float(sqrt(Double(delta * delta) + f[sites[k]]))
            }
        }
        return squared
    }
    private static func ridgeValues(_ distance: [Float], mask: [UInt8], width: Int, height: Int) -> [Double] {
        var values: [Double] = []
        for y in 0..<height { for x in 0..<width where mask[y * width + x] != 0 {
            let value = distance[y * width + x]
            var maximum = true
            for yy in max(0, y - 1)...min(height - 1, y + 1) {
                for xx in max(0, x - 1)...min(width - 1, x + 1) where distance[yy * width + xx] > value + 0.000001 { maximum = false }
            }
            if maximum { values.append(Double(value)) }
        } }
        return values
    }
}
