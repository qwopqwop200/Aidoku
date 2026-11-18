import CoreGraphics
import Foundation

extension NativePhysicalSourceStyle {
    struct AcceptedBodyResult {
        let features: [Double]
        let weight: [String: Any]
        let measurements: [String: Any]
    }

    /// Retains the ACTUAL appearance graph's original colour role separation.
    /// This is NOT the zero-style-head baseline: colour/outline heads remain.
    /// No font, PCA, template or learned weight model is accessed here.
    static func estimateAcceptedBody(rgb: [UInt8], width: Int, height: Int, mask: [UInt8],
        fontPrior: Double, bbox: CGRect, fillRGB: [Double], outlineRGB: [Double]?,
        outlineWidth: Double, backgroundRGB: [Double], boldThreshold: Double = 0.10) throws -> AcceptedBodyResult {
        guard width > 0, height > 0, width <= 1_500_000 / height,
              rgb.count == width * height * 3, mask.count == width * height else { throw Failure.dimensions }
        func colour(_ values: [Double]) -> Bool {
            values.count == 3 && values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 255 }
        }
        guard colour(fillRGB), colour(backgroundRGB), outlineRGB.map(colour) != false,
              fontPrior.isFinite, fontPrior > 0, outlineWidth.isFinite, outlineWidth >= 0,
              boldThreshold.isFinite, boldThreshold >= 0,
              bbox.minX.isFinite, bbox.minY.isFinite, bbox.width.isFinite, bbox.height.isFinite,
              bbox.width > 0, bbox.height > 0 else { throw Failure.nonfinite }
        let n = width * height, em = max(1, fontPrior)
        var body = [UInt8](repeating: 0, count: n), owned = 0, bodyPixels = 0
        func squared(_ pixel: Int, _ colour: [Double]) -> Double {
            let i = pixel * 3
            let r = Double(rgb[i]) - colour[0], g = Double(rgb[i + 1]) - colour[1], b = Double(rgb[i + 2]) - colour[2]
            return r * r + g * g + b * b
        }
        for i in 0..<n where mask[i] != 0 {
            owned += 1
            if squared(i, fillRGB) <= 1024 { body[i] = 1; bodyPixels += 1 }
        }
        let distance = NativePhysicalAcceptedBodyMath.distances(body, width: width, height: height)
        var ridges: [Float] = []
        var boundaryCount = 0, outlineBoundary = 0
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x
            guard mask[i] != 0 else { continue }
            // Match OpenCV erosion's default morphology border: only actual
            // in-crop neighbours can establish the observed own-mask boundary.
            var boundary = false, maximum = body[i] != 0
            for yy in max(0, y - 1)...min(height - 1, y + 1) {
                for xx in max(0, x - 1)...min(width - 1, x + 1) {
                    if mask[yy * width + xx] == 0 { boundary = true }
                    if distance[yy * width + xx] > distance[i] + 0.000001 { maximum = false }
                }
            }
            if boundary {
                boundaryCount += 1
                if let outlineRGB, squared(i, outlineRGB) <= 1024 { outlineBoundary += 1 }
            }
            if maximum { ridges.append(distance[i]) }
        } }
        ridges.sort()
        let median: Double
        if ridges.isEmpty { median = 0 }
        else { median = (Double(ridges[(ridges.count - 1) / 2]) + Double(ridges[ridges.count / 2])) / 2 }
        let stem = 2 * median, density = stem / em
        let boundarySupport = Double(outlineBoundary) / Double(max(1, boundaryCount))
        let contrast = sqrt(zip(fillRGB, backgroundRGB).reduce(0) { sum, pair in
            sum + (pair.0 - pair.1) * (pair.0 - pair.1)
        }) / 441.673
        let features = [density, Double(bodyPixels) / Double(max(1, owned)),
            Double(owned) / max(1, Double(bbox.width * bbox.height)), boundarySupport, outlineWidth / em, contrast]
        guard features.allSatisfy({ $0.isFinite }) else { throw Failure.nonfinite }
        let bold = density >= boldThreshold, label = bold ? "bold" : "regular"
        let measurement: [String: Any] = ["features": features,
            "featureNames": ["acceptedFillStemDiameter/priorEM", "acceptedFillOwnedFraction", "ownedBBoxFraction",
                "acceptedOutlineBoundarySupport", "acceptedOutlineWidth/priorEM", "acceptedFillBackgroundRGBContrast"],
            "stemDiameterPx": stem, "sourceEMCarrierPx": em, "bodyPixels": bodyPixels, "ownedPixels": owned,
            "emptyBodyObservation": bodyPixels == 0, "originalSourceFillRGB": fillRGB,
            "originalSourceOutlineRGB": outlineRGB as Any? ?? NSNull(), "originalSourceBackgroundRGB": backgroundRGB,
            "retainedStyleModels": true, "fontHeadCalls": 0, "weightHeadCalls": 0, "GTAtInference": false,
            "distanceABI": "exact-Euclidean-with-explicit-one-pixel-background-border"]
        let weight: [String: Any] = ["sourceWeight": label, "renderWeight": label, "renderBold": bold,
            "strokeDensityScore": density, "globalThreshold": boldThreshold,
            "version": "accepted-appearance-physical-body-density-v1", "retainedStyleModels": true,
            "sourceOnly": true, "GTAtInference": false, "fontHeadCalls": 0, "weightHeadCalls": 0,
            "sourceEMAuthority": "constructor-geometric-prior; no accepted-font-head output"]
        return AcceptedBodyResult(features: features, weight: weight, measurements: measurement)
    }
}

/// Shared pure geometry for the accepted-body and source-width adapters.
enum NativePhysicalAcceptedBodyMath {
    /// Separable squared-distance envelope; no native bridge/model dependency.
    static func distances(_ mask: [UInt8], width: Int, height: Int) -> [Float] {
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
        var sites = [Int](repeating: 0, count: height + 2), cuts = [Double](repeating: 0, count: height + 3)
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
}
