import CoreGraphics
@preconcurrency import CoreML
import Foundation

// S1: RF-DETR 648 layout regions (text, SFX, balloon, frame) for the V2 pipeline.
//
// Numerics follow the legacy NativeRFDETRLayoutTensorContract exactly: sRGB
// white-matted RGB, PyTorch antialiased triangle resize to 648x648 with
// half-pixel centers, ImageNet normalization, global top-160 (query, class)
// ranking with per-class floors, 162x162 instance-mask logits sampled
// bilinearly (logit > 0). The legacy actor's caches, raw-cache policy,
// semantic grids and support grids are not needed by V2 and are omitted.

@available(iOS 18.0, macOS 15.0, *)
final class V2RFDETRModel: @unchecked Sendable {
    static let resourceName = "KoharuHighres648FP16"
    static let side = 648
    static let maskSide = 162
    static let queries = 300
    static let classes = 5
    static let mean: [Float] = [0.485, 0.456, 0.406]
    static let std: [Float] = [0.229, 0.224, 0.225]
    /// Per-class floors in model class order: text, SFX, balloon, frame.
    static let thresholds: [Float] = [0.25, 0.20, 0.50, 0.50]
    static let selectedCount = 160

    enum Failure: Error { case modelContract(String), nonfiniteOutput }

    struct RawOutput: @unchecked Sendable {
        let boxes: MLMultiArray
        let logits: MLMultiArray
        let masks: MLMultiArray
    }

    let model: MLModel
    let executor = V2SerialExecutor(label: "Aidoku.V2.RFDETR")

    init(compiledURL: URL) throws {
        let configuration = MLModelConfiguration()
#if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
#else
        configuration.computeUnits = .cpuAndGPU
#endif
        configuration.modelDisplayName = "Koharu RF-DETR648 V2"
        model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        guard let input = model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint,
              input.dataType == .float32, input.shape.map(\.intValue) == [1, 3, Self.side, Self.side] else {
            throw Failure.modelContract("image")
        }
    }

    /// Synchronous inference; call through `executor`.
    func predict(_ raster: V2PageRaster) throws -> RawOutput {
        let input = try Self.preprocess(raster)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
        let output = try model.prediction(from: provider)
        func array(_ name: String, _ shape: [Int]) throws -> MLMultiArray {
            guard let value = output.featureValue(for: name)?.multiArrayValue, value.dataType == .float32,
                  value.shape.map(\.intValue) == shape, value.strides.allSatisfy({ $0.intValue > 0 }) else {
                throw Failure.modelContract(name)
            }
            return value
        }
        return RawOutput(boxes: try array("boxes", [1, Self.queries, 4]),
                         logits: try array("logits", [1, Self.queries, Self.classes]),
                         masks: try array("instance_masks", [1, Self.queries, Self.maskSide, Self.maskSide]))
    }

    private struct Filter { let first: Int; let weights: [Float] }

    /// PyTorch CPU bilinear antialias separable triangle filter (legacy copy).
    private static func filters(source: Int, target: Int) -> [Filter] {
        let scale = Float(source) / Float(target)
        let support = max(scale, 1), inverse = 1 / support
        return (0..<target).map { i in
            let center = scale * (Float(i) + 0.5)
            let first = max(0, Int(center - support + 0.5))
            let end = min(source, Int(center + support + 0.5))
            var weights = (first..<end).map { j in max(0, 1 - abs((Float(j) + 0.5 - center) * inverse)) }
            let sum = weights.reduce(Float(0), +)
            for j in weights.indices { weights[j] /= sum }
            return Filter(first: first, weights: weights)
        }
    }

    private struct ResizeKernel: @unchecked Sendable {
        let source: UnsafePointer<UInt8>
        let output: UnsafeMutablePointer<Float>
        let sourceWidth: Int
        let horizontal: [Filter]
        let vertical: [Filter]

        // Same per-row horizontal pass, vertical accumulation order and
        // normalization as the legacy kernel; reads RGBA instead of packed RGB.
        func write(rows outputRows: Range<Int>) {
            let side = V2RFDETRModel.side
            var rows: [Int: [Float]] = [:]
            var normalized = [Float](repeating: 0, count: sourceWidth * 3)
            for y in outputRows {
                let filter = vertical[y]
                let required = filter.first..<(filter.first + filter.weights.count)
                rows = rows.filter { required.contains($0.key) }
                for row in required where rows[row] == nil {
                    var resized = [Float](repeating: 0, count: side * 3)
                    normalized.withUnsafeMutableBufferPointer { buffer in
                        let values = buffer.baseAddress!
                        let rowBytes = source + row * sourceWidth * 4
                        for x in 0..<sourceWidth {
                            values[x * 3] = Float(rowBytes[x * 4]) / 255
                            values[x * 3 + 1] = Float(rowBytes[x * 4 + 1]) / 255
                            values[x * 3 + 2] = Float(rowBytes[x * 4 + 2]) / 255
                        }
                        for x in 0..<side {
                            let filter = horizontal[x]
                            let first = values + filter.first * 3
                            var red: Float = 0, green: Float = 0, blue: Float = 0
                            for (j, weight) in filter.weights.enumerated() {
                                red += first[j * 3] * weight
                                green += first[j * 3 + 1] * weight
                                blue += first[j * 3 + 2] * weight
                            }
                            resized[x] = red
                            resized[side + x] = green
                            resized[2 * side + x] = blue
                        }
                    }
                    rows[row] = resized
                }
                for channel in 0..<3 {
                    let channelOffset = channel * side
                    let target = output + channel * side * side + y * side
                    for x in 0..<side { target[x] = 0 }
                    for j in filter.weights.indices {
                        let weight = filter.weights[j]
                        rows[filter.first + j]!.withUnsafeBufferPointer { row in
                            let pixels = row.baseAddress! + channelOffset
                            for x in 0..<side { target[x] += pixels[x] * weight }
                        }
                    }
                    let mean = V2RFDETRModel.mean[channel], std = V2RFDETRModel.std[channel]
                    for x in 0..<side { target[x] = (target[x] - mean) / std }
                }
            }
        }
    }

    static func preprocess(_ raster: V2PageRaster) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        let output = result.dataPointer.assumingMemoryBound(to: Float.self)
        let horizontal = filters(source: raster.width, target: side)
        let vertical = filters(source: raster.height, target: side)
        raster.rgba.withUnsafeBufferPointer { rgba in
            let kernel = ResizeKernel(source: rgba.baseAddress!, output: output, sourceWidth: raster.width,
                                      horizontal: horizontal, vertical: vertical)
            let rowsPerBand = 54
            DispatchQueue.concurrentPerform(iterations: (side + rowsPerBand - 1) / rowsPerBand) { band in
                let start = band * rowsPerBand
                kernel.write(rows: start..<min(start + rowsPerBand, side))
            }
        }
        return result
    }
}

@available(iOS 18.0, macOS 15.0, *)
enum V2LayoutDetection {
    static func detect(_ page: V2Page, models: V2Models) async throws -> [V2LayoutRegion] {
        try await detect(V2PageRaster(page.image), models: models)
    }

    static func detect(_ raster: V2PageRaster, models: V2Models) async throws -> [V2LayoutRegion] {
        let model = models.layout
        return try await model.executor.run {
            let raw = try model.predict(raster)
            return try decode(raw, width: raster.width, height: raster.height)
        }
    }

    static func kind(modelClass: Int) -> V2LayoutKind? {
        switch modelClass {
        case 0: .text
        case 1: .sfx
        case 2: .balloon
        case 3: .frame
        default: nil
        }
    }

    private static func sigmoid(_ value: Float) -> Float {
        value >= 0 ? 1 / (1 + exp(-value)) : exp(value) / (1 + exp(value))
    }

    /// Pure decode of one RF-DETR output into page-pixel regions, ordered by
    /// descending score. Each region's mask covers its integral bounds.
    static func decode(_ raw: V2RFDETRModel.RawOutput, width: Int, height: Int) throws -> [V2LayoutRegion] {
        let queries = V2RFDETRModel.queries, classes = V2RFDETRModel.classes, maskSide = V2RFDETRModel.maskSide
        let boxData = raw.boxes.dataPointer.assumingMemoryBound(to: Float.self)
        let logitData = raw.logits.dataPointer.assumingMemoryBound(to: Float.self)
        let maskData = raw.masks.dataPointer.assumingMemoryBound(to: Float.self)
        let boxStride = raw.boxes.strides.map(\.intValue), logitStride = raw.logits.strides.map(\.intValue)
        let maskStride = raw.masks.strides.map(\.intValue)
        let thresholds = V2RFDETRModel.thresholds
        let floor = thresholds.min() ?? 0
        var scores: [(flat: Int, confidence: Float)] = []
        for q in 0..<queries {
            for c in 0..<classes {
                let value = logitData[q * logitStride[1] + c * logitStride[2]]
                guard value.isFinite else { throw V2RFDETRModel.Failure.nonfiniteOutput }
                let confidence = sigmoid(value)
                if confidence >= floor { scores.append((q * classes + c, confidence)) }
            }
        }
        scores.sort { $0.confidence == $1.confidence ? $0.flat < $1.flat : $0.confidence > $1.confidence }
        let selected = scores.prefix(V2RFDETRModel.selectedCount).filter {
            let c = $0.flat % classes
            return c < thresholds.count && $0.confidence >= thresholds[c]
        }
        let page = CGRect(x: 0, y: 0, width: width, height: height)
        var regions: [V2LayoutRegion] = []
        for candidate in selected {
            let q = candidate.flat / classes, c = candidate.flat % classes
            guard let kind = kind(modelClass: c) else { continue }
            let v = (0..<4).map { boxData[q * boxStride[1] + $0 * boxStride[2]] }
            guard v.allSatisfy(\.isFinite), v[2] >= 0, v[3] >= 0 else { throw V2RFDETRModel.Failure.nonfiniteOutput }
            let box = CGRect(x: CGFloat(v[0] - v[2] / 2) * CGFloat(width), y: CGFloat(v[1] - v[3] / 2) * CGFloat(height),
                             width: CGFloat(v[2]) * CGFloat(width), height: CGFloat(v[3]) * CGFloat(height))
            let bounds = box.integral.intersection(page)
            guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else { continue }
            let plane = maskData + q * maskStride[1]
            let rowStride = maskStride[2], pixelStride = maskStride[3]
            let x0 = Int(bounds.minX), y0 = Int(bounds.minY), w = Int(bounds.width), h = Int(bounds.height)
            var mask = [UInt8](repeating: 0, count: w * h)
            // Legacy NativeRFDETRLayoutMask.contains: half-pixel bilinear sampling, logit > 0.
            var columns = [(Int, Int, Float)](repeating: (0, 0, 0), count: w)
            for x in 0..<w {
                let sx = max(0, (Float(x0 + x) + 0.5) * Float(maskSide) / Float(width) - 0.5)
                let a = min(maskSide - 1, Int(sx))
                columns[x] = (a, min(maskSide - 1, a + 1), sx - Float(a))
            }
            for y in 0..<h {
                let sy = max(0, (Float(y0 + y) + 0.5) * Float(maskSide) / Float(height) - 0.5)
                let a = min(maskSide - 1, Int(sy)), b = min(maskSide - 1, a + 1), dy = sy - Float(a)
                let top = plane + a * rowStride, bottom = plane + b * rowStride
                for x in 0..<w {
                    let (l, r, dx) = columns[x]
                    let upper = top[l * pixelStride] * (1 - dx) + top[r * pixelStride] * dx
                    let lower = bottom[l * pixelStride] * (1 - dx) + bottom[r * pixelStride] * dx
                    if upper * (1 - dy) + lower * dy > 0 { mask[y * w + x] = 255 }
                }
            }
            regions.append(V2LayoutRegion(kind: kind, bounds: bounds, score: candidate.confidence, mask: mask))
        }
        return regions
    }
}
