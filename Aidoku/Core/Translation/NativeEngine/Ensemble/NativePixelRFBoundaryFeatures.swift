import Foundation

/// Contextual glyph-boundary features. Inputs are original pixels, RF outputs
/// and primary classifier probabilities; no target mask or case identity.
enum NativePixelRFBoundaryFeatures {
    enum Failure: Error { case invalidInput }
    static let featureCount = 55
    typealias MeanFilter = ([Float], Int, Int, Int) throws -> [Float]

    /// Versioned extension: source RGB edge distance and uncapped larger
    /// context distinguish solid background fields from glyph interiors.
    static func extractEdgeContext(rgb: [UInt8], probabilities: [Float], nativeMask: [UInt8],
                                   coarseRF: [Float], fullRF: [Float], width: Int, height: Int,
                                   fontPixels: Double, boxMean: MeanFilter? = nil) throws -> NativePixelRFFeatures.Matrix {
        // Populate the final row stride directly. The first 55 fields are the
        // same graph as extract(), without an intermediate 55-column matrix.
        let count = 60, font = max(1, fontPixels)
        var values = try extractValues(rgb: rgb, probabilities: probabilities, nativeMask: nativeMask,
            coarseRF: coarseRF, fullRF: fullRF, width: width, height: height, fontPixels: fontPixels,
            boxMean: boxMean, featureCount: count)
        let n = width * height
        for (column, threshold) in [8, 32, 64].enumerated() {
            let distance = try NativePixelRFBoundarySegmentation.uniformDistances(rgb: rgb, width: width,
                height: height, contrastThreshold: threshold)
            for i in 0..<n { values[i * count + 55 + column] = Float(min(Double(distance[i]) / font, 1)) }
        }
        var gradient = [Float](repeating: 0, count: n)
        for c in 0..<3 {
            let channel = (0..<n).map { Float(rgb[$0 * 3 + c]) }
            let high = maximum(channel, width: width, height: height, size: 3)
            let negativeLow = maximum(channel.map { -$0 }, width: width, height: height, size: 3)
            for i in 0..<n { gradient[i] = max(gradient[i], (high[i] + negativeLow[i]) / 255) }
        }
        let size = max(3, min(257, Int((font * 0.5).rounded(.toNearestOrEven)) | 1))
        let mean = try filteredMean(gradient, width: width, height: height, size: size, filter: boxMean)
        for i in 0..<n {
            values[i * count + 58] = gradient[i]
            values[i * count + 59] = mean[i]
        }
        return .init(values: values, featureCount: count, pixelCount: n)
    }

    static func extract(rgb: [UInt8], probabilities p: [Float], nativeMask: [UInt8],
                        coarseRF: [Float], fullRF: [Float], width w: Int, height h: Int,
                        fontPixels: Double, boxMean: MeanFilter? = nil) throws -> NativePixelRFFeatures.Matrix {
        let values = try extractValues(rgb: rgb, probabilities: p, nativeMask: nativeMask,
            coarseRF: coarseRF, fullRF: fullRF, width: w, height: h, fontPixels: fontPixels,
            boxMean: boxMean, featureCount: featureCount)
        return .init(values: values, featureCount: featureCount, pixelCount: w * h)
    }

    private static func extractValues(rgb: [UInt8], probabilities p: [Float], nativeMask: [UInt8],
                                      coarseRF: [Float], fullRF: [Float], width w: Int, height h: Int,
                                      fontPixels: Double, boxMean: MeanFilter?, featureCount: Int) throws -> [Float] {
        guard w > 0, h > 0, w <= 1_500_000 / h, fontPixels.isFinite, (0...65534).contains(fontPixels), fontPixels > 0 else {
            throw Failure.invalidInput
        }
        let n = w * h
        guard rgb.count == n * 3, p.count == n, nativeMask.count == n, coarseRF.count == n * 4, fullRF.count == n * 27,
              p.allSatisfy({ $0.isFinite && (0...1).contains($0) }), coarseRF.allSatisfy(\.isFinite),
              fullRF.allSatisfy(\.isFinite) else { throw Failure.invalidInput }
        var values = [Float](repeating: 0, count: n * featureCount)
        var luminance = [Float](repeating: 0, count: n)
        func store(_ plane: [Float], _ column: Int) {
            for i in 0..<n { values[i * featureCount + column] = plane[i] }
        }
        for i in 0..<n {
            let r = Float(rgb[i * 3]) / 255, g = Float(rgb[i * 3 + 1]) / 255, b = Float(rgb[i * 3 + 2]) / 255
            let rg = r * 0.2126 + g * 0.7152
            luminance[i] = rg + b * 0.0722
            let offset = i * featureCount
            values[offset] = p[i]; values[offset + 1] = nativeMask[i] == 0 ? 0 : 1
            values[offset + 2] = r; values[offset + 3] = g; values[offset + 4] = b
            values[offset + 5] = luminance[i]
            values[offset + 6] = max(r, max(g, b)) - min(r, min(g, b))
            for c in 0..<4 { values[offset + 7 + c] = coarseRF[i * 4 + c] }
            for c in 0..<27 { values[offset + 28 + c] = fullRF[i * 27 + c] }
        }
        let fontWindow = max(3, min(65, Int((max(1, fontPixels) * 0.25).rounded(.toNearestOrEven)) | 1))
        var fontLuminanceMean: [Float]?
        for (index, size) in [3, 5, 9].enumerated() {
            let column = 11 + index * 3
            store(maximum(p, width: w, height: h, size: size), column)
            store(try filteredMean(p, width: w, height: h, size: size, filter: boxMean), column + 1)
            let mean = try filteredMean(luminance, width: w, height: h, size: size, filter: boxMean)
            if size == fontWindow { fontLuminanceMean = mean }
            for i in 0..<n { values[i * featureCount + column + 2] = luminance[i] - mean[i] }
        }
        let font = Float(max(1, fontPixels))
        for (index, threshold) in [Float(0.25), 0.5].enumerated() {
            let distance = NativePixelRFFeatures.distance(toNonzero: p.map { $0 >= threshold ? 1 : 0 }, width: w, height: h)
            for i in 0..<n {
                values[i * featureCount + 20 + index] = Float(min(distance[i], 8)) / 8
                values[i * featureCount + 26 + index] = min(Float(distance[i]) / font, 1)
            }
        }
        let size = fontWindow
        // The font-derived window can equal a fixed window above. Reuse its
        // already-written fields, including the selected provider's rounding.
        let mean: [Float]
        if let index = [3, 5, 9].firstIndex(of: size), let existingMean = fontLuminanceMean {
            let column = 11 + index * 3
            for i in 0..<n {
                values[i * featureCount + 22] = values[i * featureCount + column]
                values[i * featureCount + 23] = values[i * featureCount + column + 1]
                values[i * featureCount + 24] = values[i * featureCount + column + 2]
            }
            // Variance needs the mean itself; subtraction cannot reconstruct
            // it bit-exactly from the luminance residual stored above.
            mean = existingMean
        } else {
            store(maximum(p, width: w, height: h, size: size), 22)
            store(try filteredMean(p, width: w, height: h, size: size, filter: boxMean), 23)
            mean = try filteredMean(luminance, width: w, height: h, size: size, filter: boxMean)
            for i in 0..<n { values[i * featureCount + 24] = luminance[i] - mean[i] }
        }
        let meanSquare = try filteredMean(luminance.map { $0 * $0 }, width: w, height: h, size: size, filter: boxMean)
        for i in 0..<n {
            let variance = max(0, meanSquare[i] - mean[i] * mean[i])
            values[i * featureCount + 25] = sqrt(variance)
        }
        return values
    }

    /// Boundary models keep their native rounding; final features inject their
    /// existing OpenCV provider directly instead of computing and replacing it.
    private static func filteredMean(_ values: [Float], width: Int, height: Int, size: Int,
                             filter: MeanFilter?) throws -> [Float] {
        if let filter { return try filter(values, width, height, size) }
        return NativePixelRFFeatures.boxMean(values, width: width, height: height, size: size)
    }

    /// Separable sliding maxima match rectangular OpenCV dilation. Repeated
    /// edge samples do not change a maximum, including one-pixel crops.
    static func maximum(_ input: [Float], width w: Int, height h: Int, size: Int) -> [Float] {
        let radius = size / 2
        var horizontal = [Float](repeating: 0, count: input.count)
        var output = horizontal
        var queue = [Int](repeating: 0, count: max(w, h))
        for y in 0..<h {
            var head = 0, tail = 0, right = 0
            for x in 0..<w {
                let end = min(w - 1, x + radius)
                while right <= end {
                    while tail > head && input[y * w + queue[tail - 1]] <= input[y * w + right] { tail -= 1 }
                    queue[tail] = right; tail += 1; right += 1
                }
                while queue[head] < x - radius { head += 1 }
                horizontal[y * w + x] = input[y * w + queue[head]]
            }
        }
        for x in 0..<w {
            var head = 0, tail = 0, bottom = 0
            for y in 0..<h {
                let end = min(h - 1, y + radius)
                while bottom <= end {
                    while tail > head && horizontal[queue[tail - 1] * w + x] <= horizontal[bottom * w + x] { tail -= 1 }
                    queue[tail] = bottom; tail += 1; bottom += 1
                }
                while queue[head] < y - radius { head += 1 }
                output[y * w + x] = horizontal[queue[head] * w + x]
            }
        }
        return output
    }
}
