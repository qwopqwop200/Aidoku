import Foundation

/// Frozen context83/style78 source features. Only source pixels, native model
/// posteriors and full-query RF observations enter this graph.
enum NativeSegmentationFinalFeatures {
    enum Failure: Error { case invalidInput, invalidLabels }
    enum DistanceMetric { case chebyshev, manhattan, euclidean5 }
    protocol ImageOperations {
        func boxMean(_ values: [Float], width: Int, height: Int, size: Int) throws -> [Float]
        func distance(_ nonzero: [UInt8], width: Int, height: Int, metric: DistanceMetric,
                      labels: Bool) throws -> (values: [Float], labels: [Int32]?)
        func fillExternalContours(_ mask: [UInt8], width: Int, height: Int) throws -> [UInt8]
    }
    typealias Matrix = NativePixelRFFeatures.Matrix

    /// Existing native edge60 with OpenCV's exact Float32 box-filter rounding.
    static func edgeContext(rgb: [UInt8], primary: [Float], native: [UInt8], coarseRF: [Float], fullRF: [Float],
                            width: Int, height: Int, fontPixels: Double, operations: any ImageOperations) throws -> Matrix {
        try NativePixelRFBoundaryFeatures.extractEdgeContext(rgb: rgb, probabilities: primary,
            nativeMask: native, coarseRF: coarseRF, fullRF: fullRF, width: width, height: height,
            fontPixels: fontPixels, boxMean: { values, width, height, size in
                try operations.boxMean(values, width: width, height: height, size: size)
            })
    }

    /// Selected-domain rows conserve memory without changing any spatial field.
    static func context(edge: Matrix, base: [UInt8], boundary: [Float], width: Int, height: Int,
                        fontPixels: Double, positions: [Int], operations: any ImageOperations) throws -> Matrix {
        let n = width * height, font = Float(max(1, fontPixels))
        guard edge.featureCount == 60, edge.pixelCount == n, base.count == n, boundary.count == n,
              positions.allSatisfy({ (0..<n).contains($0) }) else { throw Failure.invalidInput }
        var values = [Float](repeating: 0, count: positions.count * 83)
        for (row, pixel) in positions.enumerated() {
            for c in 0..<60 { values[row * 83 + c] = edge.values[pixel * 60 + c] }
            values[row * 83 + 60] = boundary[pixel]
        }
        func store(_ field: [Float], _ column: Int) {
            for (row, pixel) in positions.enumerated() { values[row * 83 + column] = field[pixel] }
        }
        let filled = base.map { $0 == 0 ? Float(0) : 1 }
        let quarter = max(3, min(65, Int((max(1, fontPixels) * 0.25).rounded(.toNearestOrEven)) | 1))
        for (ordinal, size) in [3, 7, 15, quarter].enumerated() {
            // Quarter-font context is often one of the fixed windows. Both
            // fields already exist in the selected rows; no spatial work or
            // additional retained plane is needed to reproduce those columns.
            if ordinal == 3, let previous = [3, 7, 15].firstIndex(of: size) {
                for row in positions.indices {
                    for c in 0..<4 { values[row * 83 + 73 + c] = values[row * 83 + 61 + previous * 4 + c] }
                }
                continue
            }
            for (sourceOrdinal, field) in [boundary, filled].enumerated() {
                let column = 61 + ordinal * 4 + sourceOrdinal * 2
                store(NativePixelRFBoundaryFeatures.maximum(field, width: width, height: height, size: size), column)
                store(try operations.boxMean(field, width: width, height: height, size: size), column + 1)
            }
        }
        for (ordinal, threshold) in [Float(0.1), 0.5].enumerated() {
            let outside = boundary.map { $0 < threshold ? UInt8(1) : 0 }
            let distances = try operations.distance(outside, width: width, height: height, metric: .euclidean5, labels: false).values
            store(distances.map { min($0 / font, 1) }, 77 + ordinal)
        }
        let primary = (0..<n).map { edge.values[$0 * 60] }
        var seed = (0..<n).map { primary[$0] >= 0.75 && boundary[$0] >= 0.5 }
        if !seed.contains(true) { seed = (0..<n).map { primary[$0] >= 0.25 || boundary[$0] >= 0.25 } }
        if seed.contains(true) {
            let nearest = try operations.distance(seed.map { $0 ? UInt8(0) : 1 }, width: width, height: height,
                metric: .euclidean5, labels: true)
            guard let labels = nearest.labels, labels.count == n else { throw Failure.invalidLabels }
            var colors: [[Float]] = [[0, 0, 0]]
            for i in 0..<n where seed[i] { colors.append(Array(edge.values[(i * 60 + 2)..<(i * 60 + 5)])) }
            for (row, pixel) in positions.enumerated() {
                let label = Int(labels[pixel])
                guard label >= 0, label < colors.count else { throw Failure.invalidLabels }
                let color = colors[label], offset = pixel * 60
                let red = abs(edge.values[offset + 2] - color[0])
                let green = abs(edge.values[offset + 3] - color[1])
                let blue = abs(edge.values[offset + 4] - color[2])
                values[row * 83 + 79] = min(nearest.values[pixel] / font, 1)
                values[row * 83 + 80] = max(red, green, blue)
                values[row * 83 + 81] = ((red + green) + blue) / 3
            }
        } else {
            for row in positions.indices { for column in 79...81 { values[row * 83 + column] = 1 } }
        }
        let outside = try operations.distance(base.map { $0 == 0 ? UInt8(1) : 0 }, width: width, height: height,
            metric: .euclidean5, labels: false).values
        store(outside.map { min($0 / font, 1) }, 82)
        return .init(values: values, featureCount: 83, pixelCount: positions.count)
    }

    static func auxiliary(edge: Matrix, style: [Double], positions: [Int]) throws -> Matrix {
        guard edge.featureCount == 60, style.count == 18,
              positions.allSatisfy({ (0..<edge.pixelCount).contains($0) }) else { throw Failure.invalidInput }
        var values = [Float](repeating: 0, count: positions.count * 78)
        for (row, pixel) in positions.enumerated() {
            for c in 0..<60 { values[row * 78 + c] = edge.values[pixel * 60 + c] }
            for c in 0..<18 { values[row * 78 + 60 + c] = Float(style[c]) }
        }
        return .init(values: values, featureCount: 78, pixelCount: positions.count)
    }

    /// NumPy Float32 source reductions, with Float64 linear quantile interpolation.
    static func style(rgb: [UInt8], base: [UInt8], distance: [Float], primary: [Float], boundary: [Float],
                      width: Int, height: Int, fontPixels: Double, affinity: [Float]) throws -> [Double] {
        let n = width * height
        guard n > 0, rgb.count == n * 3, base.count == n, distance.count == n,
              primary.count == n, boundary.count == n, affinity.count == 5 else { throw Failure.invalidInput }
        var light = [Float](repeating: 0, count: n), colors = [[Float]](repeating: [], count: 3), chroma = light
        for c in 0..<3 { colors[c] = (0..<n).map { Float(rgb[$0 * 3 + c]) / 255 } }
        for i in 0..<n {
            light[i] = (colors[0][i] * 0.2126 + colors[1][i] * 0.7152) + colors[2][i] * 0.0722
            chroma[i] = max(colors[0][i], colors[1][i], colors[2][i]) - min(colors[0][i], colors[1][i], colors[2][i])
        }
        let radius = max(3, min(12, fontPixels * 0.1))
        let ring = (0..<n).filter { distance[$0] > 0 && Double(distance[$0]) <= radius }
        var result = [Double](repeating: 0, count: 7)
        if !ring.isEmpty {
            let high = NativePixelRFBoundaryFeatures.maximum(light, width: width, height: height, size: 3)
            let negativeLow = NativePixelRFBoundaryFeatures.maximum(light.map { -$0 }, width: width, height: height, size: 3)
            let values = ring.map { light[$0] }, gradient = ring.map { high[$0] + negativeLow[$0] }
            let sorted = values.sorted()
            // axis=0 RGB variance uses the contiguous three-lane reduction order.
            var colorStd: Float = 0
            for c in 0..<3 { colorStd = max(colorStd, linearStd(ring.map { colors[c][$0] })) }
            result = [Double(std(values)), quantile(sorted, 0.95) - quantile(sorted, 0.05),
                Double(mean(ring.map { chroma[$0] })), Double(colorStd), Double(mean(gradient)),
                Double(gradient.filter { $0 > 0.1 }.count) / Double(ring.count),
                Double(values.filter { $0 < 0.95 }.count) / Double(ring.count)]
        }
        var seed = (0..<n).filter { primary[$0] >= 0.5 && boundary[$0] >= 0.3 }
        if seed.isEmpty { seed = (0..<n).filter { base[$0] != 0 } }
        if seed.isEmpty { result += [Double](repeating: 0, count: 5) }
        else {
            let values = seed.map { light[$0] }
            result += [Double(mean(values)), Double(std(values)), Double(mean(seed.map { chroma[$0] })),
                Double(values.filter { $0 < 0.25 }.count) / Double(seed.count),
                Double(values.filter { $0 > 0.75 }.count) / Double(seed.count)]
        }
        result += [min(1, fontPixels / 128)] + affinity.map(Double.init)
        return result
    }

    private static func quantile(_ sorted: [Float], _ fraction: Double) -> Double {
        let position = Double(sorted.count - 1) * fraction, lower = Int(floor(position))
        let upper = min(sorted.count - 1, lower + 1), weight = position - Double(lower)
        let delta = Double(sorted[upper] - sorted[lower])
        return weight >= 0.5 ? Double(sorted[upper]) - delta * (1 - weight) : Double(sorted[lower]) + delta * weight
    }
    private static func mean(_ values: [Float]) -> Float { pairwise(values, start: 0, count: values.count) / Float(values.count) }
    private static func std(_ values: [Float]) -> Float {
        let m = mean(values)
        return sqrt(mean(values.map { let d = $0 - m; return d * d }))
    }
    private static func linearStd(_ values: [Float]) -> Float {
        let m = values.reduce(Float(0), +) / Float(values.count)
        let variance = values.reduce(Float(0)) { sum, value in let d = value - m; return sum + d * d }
        return sqrt(variance / Float(values.count))
    }
    /// NumPy's eight-lane Float32 pairwise reduction, block size128.
    private static func pairwise(_ values: [Float], start: Int, count: Int) -> Float {
        if count < 8 {
            var result: Float = -0.0
            for i in start..<(start + count) { result += values[i] }
            return result
        }
        if count <= 128 {
            var lane = Array(values[start..<(start + 8)]), i = 8
            while i <= count - 8 {
                for c in 0..<8 { lane[c] += values[start + i + c] }
                i += 8
            }
            var result = ((lane[0] + lane[1]) + (lane[2] + lane[3])) + ((lane[4] + lane[5]) + (lane[6] + lane[7]))
            while i < count { result += values[start + i]; i += 1 }
            return result
        }
        let split = (count / 2) - (count / 2) % 8
        return pairwise(values, start: start, count: split) + pairwise(values, start: start + split, count: count - split)
    }
}
