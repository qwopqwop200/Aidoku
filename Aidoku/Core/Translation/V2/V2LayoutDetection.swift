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
// No V2 stage reads region masks, so `detect` neither reads the 31 MB mask
// output (Core ML materializes it lazily) nor samples it; `decode` keeps the
// mask path for callers that ask for it.

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
        /// Nil when predicted with `masks: false`.
        let masks: MLMultiArray?
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

    /// Model-owned input tensor, refilled for every page (calls are serialized by `executor`).
    private var input: MLMultiArray?

    /// Synchronous inference; call through `executor`. Pass `masks: false` when the
    /// instance masks are not needed (the output is then not validated or read).
    func predict(_ raster: V2PageRaster, masks: Bool = true) throws -> RawOutput {
        let input = try self.input ?? Self.makeInput()
        self.input = input
        Self.preprocess(raster, into: input)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
        let output = try model.prediction(from: provider)
        func array(_ name: String, _ shape: [Int]) throws -> MLMultiArray {
            guard let value = output.featureValue(for: name)?.multiArrayValue, value.dataType == .float32,
                  value.shape.map(\.intValue) == shape, value.strides.allSatisfy({ $0.intValue > 0 }) else {
                throw Failure.modelContract(name)
            }
            return value
        }
        let maskShape = [1, Self.queries, Self.maskSide, Self.maskSide]
        return RawOutput(boxes: try array("boxes", [1, Self.queries, 4]),
                         logits: try array("logits", [1, Self.queries, Self.classes]),
                         masks: masks ? try array("instance_masks", maskShape) : nil)
    }

    /// Flattened per-output-pixel filter taps: output `i` reads source
    /// `first[i] ..< first[i] + count[i]` with `weights[offset[i]...]`.
    private struct Taps {
        var first: [Int] = [], count: [Int] = [], offset: [Int] = [], weights: [Float] = []

        /// PyTorch CPU bilinear antialias separable triangle filter (legacy copy).
        init(source: Int, target: Int) {
            let scale = Float(source) / Float(target)
            let support = max(scale, 1), inverse = 1 / support
            for i in 0..<target {
                let center = scale * (Float(i) + 0.5)
                let lower = max(0, Int(center - support + 0.5))
                let end = min(source, Int(center + support + 0.5))
                var taps = (lower..<end).map { j in max(0, 1 - abs((Float(j) + 0.5 - center) * inverse)) }
                let sum = taps.reduce(Float(0), +)
                for j in taps.indices { taps[j] /= sum }
                first.append(lower)
                count.append(taps.count)
                offset.append(weights.count)
                weights += taps
            }
        }
    }

    /// Byte -> Float(byte) / 255, exactly as the legacy per-pixel division.
    private static let unit: [Float] = (0..<256).map { Float($0) / 255 }

    private struct ResizeKernel: @unchecked Sendable {
        let source: UnsafePointer<UInt8>
        let output: UnsafeMutablePointer<Float>
        let sourceWidth: Int
        let horizontal: Taps
        let vertical: Taps

        // Same arithmetic, accumulation order and normalization as the legacy
        // kernel (per-row horizontal pass, then vertical accumulation from 0);
        // the horizontal rows of one band live in one contiguous scratch buffer.
        func write(rows outputRows: Range<Int>) {
            let side = V2RFDETRModel.side, plane = side * side
            guard let firstRow = outputRows.first.map({ vertical.first[$0] }),
                  let lastRow = outputRows.last.map({ vertical.first[$0] + vertical.count[$0] }) else { return }
            let rowCount = lastRow - firstRow
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: rowCount * 3 * side)
            defer { scratch.deallocate() }
            V2RFDETRModel.unit.withUnsafeBufferPointer { unitBuffer in
                horizontal.weights.withUnsafeBufferPointer { weightBuffer in
                    let unit = unitBuffer.baseAddress!, weights = weightBuffer.baseAddress!
                    for row in firstRow..<lastRow {
                        let rowBytes = source + row * sourceWidth * 4
                        let resized = scratch + (row - firstRow) * 3 * side
                        for x in 0..<side {
                            let tap = weights + horizontal.offset[x]
                            var pixel = rowBytes + horizontal.first[x] * 4
                            var red: Float = 0, green: Float = 0, blue: Float = 0
                            for j in 0..<horizontal.count[x] {
                                let weight = tap[j]
                                red += unit[Int(pixel[0])] * weight
                                green += unit[Int(pixel[1])] * weight
                                blue += unit[Int(pixel[2])] * weight
                                pixel += 4
                            }
                            resized[x] = red
                            resized[side + x] = green
                            resized[2 * side + x] = blue
                        }
                    }
                }
            }
            for y in outputRows {
                let first = vertical.first[y], count = vertical.count[y], offset = vertical.offset[y]
                for channel in 0..<3 {
                    let target = output + channel * plane + y * side
                    target.initialize(repeating: 0, count: side)
                    for j in 0..<count {
                        let weight = vertical.weights[offset + j]
                        let pixels = scratch + (first + j - firstRow) * 3 * side + channel * side
                        for x in 0..<side { target[x] += pixels[x] * weight }
                    }
                    let mean = V2RFDETRModel.mean[channel], std = V2RFDETRModel.std[channel]
                    for x in 0..<side { target[x] = (target[x] - mean) / std }
                }
            }
        }
    }

    static func makeInput() throws -> MLMultiArray {
        try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
    }

    static func preprocess(_ raster: V2PageRaster) throws -> MLMultiArray {
        let result = try makeInput()
        preprocess(raster, into: result)
        return result
    }

    /// Fills a contiguous [1, 3, side, side] Float32 tensor.
    static func preprocess(_ raster: V2PageRaster, into result: MLMultiArray) {
        let output = result.dataPointer.assumingMemoryBound(to: Float.self)
        let horizontal = Taps(source: raster.width, target: side)
        let vertical = Taps(source: raster.height, target: side)
        raster.rgba.withUnsafeBufferPointer { rgba in
            let kernel = ResizeKernel(source: rgba.baseAddress!, output: output, sourceWidth: raster.width,
                                      horizontal: horizontal, vertical: vertical)
            let rowsPerBand = 54
            DispatchQueue.concurrentPerform(iterations: (side + rowsPerBand - 1) / rowsPerBand) { band in
                let start = band * rowsPerBand
                kernel.write(rows: start..<min(start + rowsPerBand, side))
            }
        }
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
            // No V2 stage reads `V2LayoutRegion.mask`, so S1 skips mask sampling.
            let raw = try model.predict(raster, masks: false)
            return try decode(raw, width: raster.width, height: raster.height, masks: false)
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
    /// descending score. With `masks`, each region's mask covers its integral
    /// bounds; without, `mask` is nil and `raw.masks` is never read.
    static func decode(_ raw: V2RFDETRModel.RawOutput, width: Int, height: Int,
                       masks: Bool = true) throws -> [V2LayoutRegion] {
        let queries = V2RFDETRModel.queries, classes = V2RFDETRModel.classes, maskSide = V2RFDETRModel.maskSide
        let boxData = raw.boxes.dataPointer.assumingMemoryBound(to: Float.self)
        let logitData = raw.logits.dataPointer.assumingMemoryBound(to: Float.self)
        let boxStride = raw.boxes.strides.map(\.intValue), logitStride = raw.logits.strides.map(\.intValue)
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
            guard masks else {
                regions.append(V2LayoutRegion(kind: kind, bounds: bounds, score: candidate.confidence, mask: nil))
                continue
            }
            guard let maskArray = raw.masks else { throw V2RFDETRModel.Failure.modelContract("instance_masks") }
            let maskData = maskArray.dataPointer.assumingMemoryBound(to: Float.self)
            let maskStride = maskArray.strides.map(\.intValue)
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
