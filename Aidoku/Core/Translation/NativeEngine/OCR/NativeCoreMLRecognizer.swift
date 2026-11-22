import CoreGraphics
@preconcurrency import CoreML
import Foundation

// PP-OCRv6 recognition crop preparation and CTC decoding (V2 S3 runs the model).

@available(iOS 18.0, *)
enum NativeCoreMLRecognizerError: Error, Equatable, LocalizedError {
    case modelOutputShape(expected: [Int], actual: [Int])
    case unsupportedModelOutputType

    var errorDescription: String? { NSLocalizedString("OCR_ERROR_OUTPUT") }
}

@available(iOS 18.0, *)
struct NativeCoreMLCTCTokenObservation: Equatable, Sendable {
    let text: String
    let confidence: Double
}

@available(iOS 18.0, *)
struct NativeCoreMLRecognitionBucket: Equatable, Hashable, Sendable {
    let width: Int
    let timeSteps: Int

    init(width: Int) {
        self.width = width
        // Two width strides followed by pooling: floor(ceil(width / 4) / 2).
        timeSteps = (width + 3) / 8
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLPreparedTensor: Equatable, Sendable {
    let values: [Float]
    let resizedWidth: Int
    let bucket: NativeCoreMLRecognitionBucket
    let rotatedCounterClockwise: Bool
}

@available(iOS 18.0, *)
enum NativeCoreMLRecognitionPreprocessor {
    static let targetHeight = 48

    struct Plan: Sendable {
        let resizedWidth: Int
        let bucket: NativeCoreMLRecognitionBucket
        let rotatedCounterClockwise: Bool
        let cropWidth: Int
        let cropHeight: Int
        let orientedWidth: Int
        let orientedHeight: Int
        let homography: Homography
    }

    fileprivate struct Quad: Sendable {
        let topLeft: CGPoint
        let topRight: CGPoint
        let bottomRight: CGPoint
        let bottomLeft: CGPoint
    }

    struct Homography: Sendable {
        let a, b, c, d, e, f, g, h: Double
    }

    /// Manga crop plan: exact (dynamic) tensor width; a 4-point polygon must
    /// already be in reading order (TL, TR, BR, BL).
    static func plan(polygon: [CGPoint]) -> Plan? {
        guard let quad = makeQuad(polygon), let homography = makeHomography(quad) else { return nil }
        let widthTop = distance(quad.topLeft, quad.topRight)
        let widthBottom = distance(quad.bottomLeft, quad.bottomRight)
        let heightLeft = distance(quad.topLeft, quad.bottomLeft)
        let heightRight = distance(quad.topRight, quad.bottomRight)
        let width = max(widthTop, widthBottom)
        let height = max(heightLeft, heightRight)
        // Finite input points can still produce overflowing distances or
        // dimensions outside Int's range. Reject before converting geometry.
        guard width.isFinite, height.isFinite,
              width < Double(Int.max), height < Double(Int.max) else { return nil }
        let cropWidth = max(1, Int(floor(width)))
        let cropHeight = max(1, Int(floor(height)))
        guard cropWidth > 1, cropHeight > 1 else { return nil }

        // Decide the reading axis before raster rounding. Flooring short edges
        // can turn a 1.49 aspect ratio into 1.5 and rotate the same lettering
        // differently at different detector resolutions.
        let rotated = height / width >= 1.5
        let orientedWidth = rotated ? cropHeight : cropWidth
        let orientedHeight = rotated ? cropWidth : cropHeight
        let ratio = Double(orientedWidth) / Double(max(1, orientedHeight))
        // Publisher's rule uses the natural width BEFORE clipping: ordinary
        // lines cap at 640, only natural widths above 2000 can use up to 2400.
        let naturalWidth = (Double(targetHeight) * ratio).rounded(.toNearestOrEven)
        let desiredWidth = Int(max(1, min(naturalWidth > 2_000 ? 2_400 : 640, naturalWidth)))
        let bucket = NativeCoreMLRecognitionBucket(width: max(32, desiredWidth))
        return Plan(
            resizedWidth: desiredWidth, bucket: bucket, rotatedCounterClockwise: rotated,
            cropWidth: cropWidth, cropHeight: cropHeight, orientedWidth: orientedWidth,
            orientedHeight: orientedHeight, homography: homography
        )
    }

    static func prepare(frame: NativeOCRRGBAFrame, plan: Plan) -> NativeCoreMLPreparedTensor? {
        let targetWidth = plan.bucket.width
        let planeSize = targetHeight * targetWidth
        var values = [Float](repeating: 0, count: planeSize * 3)
        let cropWidth = Double(plan.cropWidth)
        let cropHeight = Double(plan.cropHeight)
        let orientedWidth = Double(plan.orientedWidth)
        let orientedHeight = Double(plan.orientedHeight)
        let resizedWidth = Double(plan.resizedWidth)
        let sourceMaximumX = Double(frame.width - 1)
        let sourceMaximumY = Double(frame.height - 1)
        let homography = plan.homography
        // With g == h == 0 the projective denominator is exactly 1.0 for every
        // finite u/v in [0, 1] (signed zeros included), and IEEE division by
        // 1.0 is the identity. Skipping it is therefore bit-identical.
        let isAffine = homography.g == 0 && homography.h == 0
        var valid = true
        // Each column uses the same normalized crop coordinate on all 48
        // rows. Keep the scalar operation order, but calculate it only once.
        let columnCoordinates = (0..<plan.resizedWidth).map { column in
            let orientedX = (Double(column) + 0.5) * orientedWidth / resizedWidth - 0.5
            return min(max(orientedX / (plan.rotatedCounterClockwise ? cropHeight : cropWidth), 0), 1)
        }

        let axis = isAffine && homography.b == 0 && homography.d == 0
            ? sampleAxisAligned(frame: frame, plan: plan, columns: columnCoordinates) : nil

        // Exact scalar Paddle/OpenCV sampling contract. The immutable source and
        // disjoint output slots make this kernel safe for the recognizer's
        // bounded region-level task group.
        values.withUnsafeMutableBufferPointer { destination in
            frame.bytes.withUnsafeBufferPointer { sourceBytes in
                guard let output = destination.baseAddress, let source = sourceBytes.baseAddress else {
                    valid = false
                    return
                }
                if plan.rotatedCounterClockwise, let axis,
                   let first = axis.y.first, let last = axis.y.last,
                   abs(last.near - first.near) / frame.bytesPerRow < axis.y.count {
                    sampleUpscaledVertical(source: source, output: output, xAxis: axis.x,
                                           yAxis: axis.y, targetWidth: targetWidth, planeSize: planeSize)
                    return
                }
                for row in 0..<targetHeight {
                    let orientedY = (Double(row) + 0.5) * orientedHeight / Double(targetHeight) - 0.5
                    let rowCoordinate = plan.rotatedCounterClockwise
                        ? min(max((Double(plan.cropWidth - 1) - orientedY) / cropWidth, 0), 1)
                        : min(max(orientedY / cropHeight, 0), 1)
                    for column in 0..<plan.resizedWidth {
                        let xWeight, yWeight: Double
                        let topLeft, topRight, bottomLeft, bottomRight: Int
                        if let axis {
                            let x = axis.x[plan.rotatedCounterClockwise ? row : column]
                            let y = axis.y[plan.rotatedCounterClockwise ? column : row]
                            xWeight = x.weight
                            yWeight = y.weight
                            topLeft = y.near + x.near
                            topRight = y.near + x.far
                            bottomLeft = y.far + x.near
                            bottomRight = y.far + x.far
                        } else {
                            let u = plan.rotatedCounterClockwise ? rowCoordinate : columnCoordinates[column]
                            let v = plan.rotatedCounterClockwise ? columnCoordinates[column] : rowCoordinate
                            var projectedX = homography.a * u + homography.b * v + homography.c
                            var projectedY = homography.d * u + homography.e * v + homography.f
                            if !isAffine {
                                let denominator = homography.g * u + homography.h * v + 1
                                guard denominator.isFinite, abs(denominator) > 0.000_000_1 else {
                                    valid = false
                                    return
                                }
                                projectedX /= denominator
                                projectedY /= denominator
                            }
                            let sourceX = min(max(projectedX, 0), sourceMaximumX)
                            let sourceY = min(max(projectedY, 0), sourceMaximumY)
                            guard sourceX.isFinite, sourceY.isFinite else {
                                valid = false
                                return
                            }
                            let x0 = Int(floor(sourceX))
                            let y0 = Int(floor(sourceY))
                            let x1 = min(x0 + 1, frame.width - 1)
                            let y1 = min(y0 + 1, frame.height - 1)
                            xWeight = sourceX - Double(x0)
                            yWeight = sourceY - Double(y0)
                            topLeft = y0 * frame.bytesPerRow + x0 * 4
                            topRight = y0 * frame.bytesPerRow + x1 * 4
                            bottomLeft = y1 * frame.bytesPerRow + x0 * 4
                            bottomRight = y1 * frame.bytesPerRow + x1 * 4
                        }
                        let inverseXWeight = 1 - xWeight
                        let inverseYWeight = 1 - yWeight

                        @inline(__always)
                        func interpolate(_ channel: Int) -> Float {
                            let top = Double(source[topLeft + channel]) * inverseXWeight
                                + Double(source[topRight + channel]) * xWeight
                            let bottom = Double(source[bottomLeft + channel]) * inverseXWeight
                                + Double(source[bottomRight + channel]) * xWeight
                            let value = top * inverseYWeight + bottom * yWeight
                            return Float(value / 127.5 - 1)
                        }

                        let outputIndex = row * targetWidth + column
                        // Paddle's RecResizeImg converts RGBA to BGR, then
                        // applies (channel / 255 - 0.5) / 0.5. Padding stays 0.
                        output[outputIndex] = interpolate(2)
                        output[planeSize + outputIndex] = interpolate(1)
                        output[planeSize * 2 + outputIndex] = interpolate(0)
                    }
                }
            }
        }
        guard valid else { return nil }
        return NativeCoreMLPreparedTensor(
            values: values, resizedWidth: plan.resizedWidth, bucket: plan.bucket,
            rotatedCounterClockwise: plan.rotatedCounterClockwise
        )
    }

    /// On a rotated axis-aligned crop, an output row holds its source X fixed.
    /// Adjacent columns can therefore reuse the exact horizontal interpolation
    /// when bilinear sampling revisits either of the same two source rows.
    private static func sampleUpscaledVertical(
        source: UnsafePointer<UInt8>, output: UnsafeMutablePointer<Float>,
        xAxis: [AxisSample], yAxis: [AxisSample], targetWidth: Int, planeSize: Int
    ) {
        typealias RGB = (red: Double, green: Double, blue: Double)
        for (row, x) in xAxis.enumerated() {
            let inverseX = 1 - x.weight
            let leftColumn = source + x.near
            let rightColumn = source + x.far
            @inline(__always)
            func horizontal(_ rowOffset: Int) -> RGB {
                let left = leftColumn + rowOffset
                let right = rightColumn + rowOffset
                return (
                    Double(left[0]) * inverseX + Double(right[0]) * x.weight,
                    Double(left[1]) * inverseX + Double(right[1]) * x.weight,
                    Double(left[2]) * inverseX + Double(right[2]) * x.weight
                )
            }
            var nearOffset = -1, farOffset = -1
            var top: RGB = (0, 0, 0), bottom: RGB = (0, 0, 0)
            let line = output + row * targetWidth
            for (column, y) in yAxis.enumerated() {
                if y.near != nearOffset {
                    let previousTop = top
                    top = y.near == farOffset ? bottom : horizontal(y.near)
                    bottom = y.far == nearOffset ? previousTop : horizontal(y.far)
                    nearOffset = y.near
                    farOffset = y.far
                }
                let inverseY = 1 - y.weight
                line[column] = Float((top.blue * inverseY + bottom.blue * y.weight) / 127.5 - 1)
                line[planeSize + column] = Float((top.green * inverseY + bottom.green * y.weight) / 127.5 - 1)
                line[planeSize * 2 + column] = Float((top.red * inverseY + bottom.red * y.weight) / 127.5 - 1)
            }
        }
    }

    private struct AxisSample {
        let near: Int
        let far: Int
        let weight: Double
    }

    /// Exact separable axis-aligned warp. Generic affine/projective paths
    /// still exercise their existing per-cell projection and validity rules.
    private static func sampleAxisAligned(frame: NativeOCRRGBAFrame, plan: Plan, columns: [Double]) -> (x: [AxisSample], y: [AxisSample])? {
        let homography = plan.homography
        let rotated = plan.rotatedCounterClockwise
        let cropWidth = Double(plan.cropWidth)
        let cropHeight = Double(plan.cropHeight)
        let orientedHeight = Double(plan.orientedHeight)
        let rows = (0..<targetHeight).map { row in
            let y = (Double(row) + 0.5) * orientedHeight / Double(targetHeight) - 0.5
            return rotated ? min(max((Double(plan.cropWidth - 1) - y) / cropWidth, 0), 1) : min(max(y / cropHeight, 0), 1)
        }
        func samples(_ coordinates: [Double], horizontal: Bool) -> [AxisSample]? {
            let maximum = horizontal ? frame.width - 1 : frame.height - 1
            let stride = horizontal ? 4 : frame.bytesPerRow
            var result: [AxisSample] = []
            result.reserveCapacity(coordinates.count)
            for coordinate in coordinates {
                // Keep multiply/add order used by the generic branch. The
                // omitted coordinate has zero coefficient; its only possible
                // IEEE difference is the sign of zero, which clamps to the
                // same source pixel and normalizes identically.
                let projected = horizontal
                    ? homography.a * coordinate + homography.b * 0 + homography.c
                    : homography.d * 0 + homography.e * coordinate + homography.f
                let source = min(max(projected, 0), Double(maximum))
                guard source.isFinite else { return nil }
                let near = Int(floor(source))
                let far = min(near + 1, maximum)
                let weight = source - Double(near)
                result.append(.init(near: near * stride, far: far * stride, weight: weight))
            }
            return result
        }
        guard let xs = samples(rotated ? rows : columns, horizontal: true),
              let ys = samples(rotated ? columns : rows, horizontal: false) else { return nil }
        return (xs, ys)
    }

    private static func makeQuad(_ polygon: [CGPoint]) -> Quad? {
        let finite = polygon.filter { $0.x.isFinite && $0.y.isFinite }
        guard finite.count == polygon.count, finite.count >= 2 else { return nil }
        if finite.count == 4 {
            let quad = Quad(topLeft: finite[0], topRight: finite[1], bottomRight: finite[2], bottomLeft: finite[3])
            guard abs(signedArea(quad)) > 0.5 else { return nil }
            return quad
        }

        guard let minimumX = finite.map(\.x).min(),
              let maximumX = finite.map(\.x).max(),
              let minimumY = finite.map(\.y).min(),
              let maximumY = finite.map(\.y).max(),
              maximumX - minimumX > 1, maximumY - minimumY > 1 else { return nil }
        return Quad(
            topLeft: CGPoint(x: minimumX, y: minimumY),
            topRight: CGPoint(x: maximumX, y: minimumY),
            bottomRight: CGPoint(x: maximumX, y: maximumY),
            bottomLeft: CGPoint(x: minimumX, y: maximumY)
        )
    }

    private static func makeHomography(_ quad: Quad) -> Homography? {
        let x0 = Double(quad.topLeft.x)
        let y0 = Double(quad.topLeft.y)
        let x1 = Double(quad.topRight.x)
        let y1 = Double(quad.topRight.y)
        let x2 = Double(quad.bottomRight.x)
        let y2 = Double(quad.bottomRight.y)
        let x3 = Double(quad.bottomLeft.x)
        let y3 = Double(quad.bottomLeft.y)
        let dx1 = x1 - x2
        let dx2 = x3 - x2
        let dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2
        let dy2 = y3 - y2
        let dy3 = y0 - y1 + y2 - y3
        let g: Double
        let h: Double
        if abs(dx3) < 0.000_000_1, abs(dy3) < 0.000_000_1 {
            g = 0
            h = 0
        } else {
            let denominator = dx1 * dy2 - dx2 * dy1
            guard abs(denominator) > 0.000_000_1 else { return nil }
            g = (dx3 * dy2 - dx2 * dy3) / denominator
            h = (dx1 * dy3 - dx3 * dy1) / denominator
        }
        let homography = Homography(
            a: x1 - x0 + g * x1, b: x3 - x0 + h * x3, c: x0,
            d: y1 - y0 + g * y1, e: y3 - y0 + h * y3, f: y0, g: g, h: h
        )
        let values = [homography.a, homography.b, homography.c, homography.d, homography.e, homography.f, g, h]
        return values.allSatisfy(\.isFinite) ? homography : nil
    }

    private static func signedArea(_ quad: Quad) -> Double {
        let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        var area = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += Double(points[index].x * next.y - next.x * points[index].y)
        }
        return area * 0.5
    }

    private static func distance(_ left: CGPoint, _ right: CGPoint) -> Double {
        hypot(Double(right.x - left.x), Double(right.y - left.y))
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLDecodedText: Equatable, Sendable {
    let text: String
    let confidence: Double
    var tokenObservations: [NativeCoreMLCTCTokenObservation] = []
}

@available(iOS 18.0, *)
enum NativeCoreMLCTCDecoder {
    /// Decodes the compact output layout: row 0 indices, row 1 scores, then
    /// optionally four (index, score) top-k row pairs for the n-gram arbiter.
    static func decode(
        output: MLMultiArray, dictionary: [String], expectedShape: [Int], languageModel: NativeMangaNGram? = nil
    ) throws -> NativeCoreMLDecodedText {
        let actualShape = output.shape.map(\.intValue)
        guard actualShape.count == 2, actualShape[0] == 2 || actualShape[0] == 10,
              (4...400).contains(actualShape[1]) else {
            throw NativeCoreMLRecognizerError.modelOutputShape(expected: expectedShape, actual: actualShape)
        }
        let decoded = try decodeCompact(output: output, dictionary: dictionary, timeSteps: actualShape[1])
        guard actualShape[0] == 10, let languageModel else { return decoded }
        return try correctCompact(output: output, decoded: decoded, dictionary: dictionary,
            timeSteps: actualShape[1], model: languageModel)
    }

    private static func correctCompact(output: MLMultiArray, decoded: NativeCoreMLDecodedText,
                                       dictionary: [String], timeSteps: Int, model: NativeMangaNGram) throws -> NativeCoreMLDecodedText {
        let pointer = output.dataPointer.assumingMemoryBound(to: Float.self)
        let rowStride = output.strides[0].intValue, timeStride = output.strides[1].intValue
        var previous = -1
        var candidates: [[NativeMangaNGram.Choice]] = []
        for step in 0..<timeSteps {
            let index = Int(pointer[step * timeStride])
            let score = Double(pointer[rowStride + step * timeStride])
            if index > 0 {
                let base = NativeMangaNGram.Choice(text: dictionary[index - 1], probability: score)
                if index != previous { candidates.append([base]) }
                if score >= (candidates.last?.first?.probability ?? 0) {
                    var choices = [base], seen: Set<Int> = [index]
                    for rank in 0..<4 {
                        let raw = pointer[(2 + rank * 2) * rowStride + step * timeStride]
                        let probability = pointer[(3 + rank * 2) * rowStride + step * timeStride]
                        guard raw.isFinite, raw.rounded(.towardZero) == raw, raw >= 0, raw <= Float(dictionary.count),
                              probability.isFinite, probability >= 0, probability <= 1.001 else {
                            throw NativeCoreMLRecognizerError.unsupportedModelOutputType
                        }
                        let alternative = Int(raw)
                        if alternative > 0, seen.insert(alternative).inserted {
                            choices.append(.init(text: dictionary[alternative - 1], probability: Double(probability)))
                        }
                    }
                    candidates[candidates.count - 1] = choices
                }
            }
            previous = index
        }
        guard candidates.count == decoded.tokenObservations.count else {
            throw NativeCoreMLRecognizerError.unsupportedModelOutputType
        }
        let result = model.correct(candidates)
        guard result.changedTokens > 0 else { return decoded }
        // Acceptance confidence remains the original visual confidence. LM
        // scores neither inflate nor replace the detector/recognizer signal.
        return NativeCoreMLDecodedText(text: result.choices.map(\.text).joined(), confidence: decoded.confidence,
            tokenObservations: zip(result.choices, decoded.tokenObservations).map { choice, original in
                .init(text: choice.text, confidence: choice.text == original.text ? original.confidence : choice.probability)
            })
    }

    private static func decodeCompact(
        output: MLMultiArray, dictionary: [String], timeSteps: Int
    ) throws -> NativeCoreMLDecodedText {
        guard output.dataType == .float32, output.strides.count == 2, !dictionary.isEmpty else {
            throw NativeCoreMLRecognizerError.unsupportedModelOutputType
        }
        let pointer = output.dataPointer.assumingMemoryBound(to: Float.self)
        let rowStride = output.strides[0].intValue
        let timeStride = output.strides[1].intValue
        var collapse = Collapse()
        for step in 0..<timeSteps {
            let rawIndex = pointer[step * timeStride]
            let score = pointer[rowStride + step * timeStride]
            guard rawIndex.isFinite, score.isFinite, rawIndex.rounded(.towardZero) == rawIndex, rawIndex >= 0,
                  rawIndex <= Float(dictionary.count), score >= 0, score <= 1.001 else {
                throw NativeCoreMLRecognizerError.unsupportedModelOutputType
            }
            collapse.append(index: Int(rawIndex), confidence: Double(score), dictionary: dictionary)
        }
        return collapse.result
    }

    /// First-emission confidence contract: later repeated scores never
    /// replace the original acceptance signal.
    private struct Collapse {
        var previousIndex = -1
        var text = ""
        var confidenceSum = 0.0
        var tokens: [NativeCoreMLCTCTokenObservation] = []

        mutating func append(index: Int, confidence: Double, dictionary: [String]) {
            if index > 0, index != previousIndex {
                let token = dictionary[index - 1]
                text += token
                confidenceSum += confidence
                tokens.append(.init(text: token, confidence: confidence))
            }
            previousIndex = index
        }

        var result: NativeCoreMLDecodedText {
            .init(text: text, confidence: tokens.isEmpty ? 0 : confidenceSum / Double(tokens.count), tokenObservations: tokens)
        }
    }
}
