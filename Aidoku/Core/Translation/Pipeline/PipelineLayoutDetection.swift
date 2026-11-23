import CoreGraphics
@preconcurrency import CoreML
import Foundation

// S1: RF-DETR 648 layout regions (text, SFX, balloon, frame). Numerics follow the legacy
// tensor contract exactly: PyTorch antialiased triangle resize, ImageNet normalization,
// global top-160 (query, class) ranking with per-class floors. The bundled package drops the
// never-read `instance_masks` output (boxes/logits bit-identical), so Core ML skips the mask head.

@available(iOS 18.0, macOS 15.0, *)
final class PipelineRFDETRModel: @unchecked Sendable {
    static let resourceName = "KoharuHighres648FP16"
    static let side = 648
    static let queries = 300
    static let classes = 5
    static let mean: [Float] = [0.485, 0.456, 0.406]
    static let std: [Float] = [0.229, 0.224, 0.225]
    /// Per-class floors in model class order: text, SFX, balloon, frame.
    static let thresholds: [Float] = [0.25, 0.20, PipelineLayoutRegion.balloonFloor, 0.50]
    static let selectedCount = 160

    enum Failure: Error { case modelContract(String), nonfiniteOutput }

    struct RawOutput: @unchecked Sendable {
        let boxes: MLMultiArray
        let logits: MLMultiArray
    }

    let model: MLModel
    let executor = PipelineSerialExecutor(label: "Aidoku.Pipeline.RFDETR")

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

    /// Synchronous inference; call through `executor`.
    func predict(_ raster: PipelinePageRaster) throws -> RawOutput {
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
        return RawOutput(boxes: try array("boxes", [1, Self.queries, 4]),
                         logits: try array("logits", [1, Self.queries, Self.classes]))
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

        // The legacy kernel's arithmetic and order (horizontal pass per row, then vertical
        // accumulation from 0), vectorized across channels / output columns only, so every float
        // is bit-identical; a band's horizontal rows share one scratch buffer.
        func write(rows outputRows: Range<Int>) {
            let side = PipelineRFDETRModel.side, plane = side * side
            guard let firstRow = outputRows.first.map({ vertical.first[$0] }),
                  let lastRow = outputRows.last.map({ vertical.first[$0] + vertical.count[$0] }) else { return }
            let rowCount = lastRow - firstRow
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: rowCount * 3 * side)
            defer { scratch.deallocate() }
            // One source row as unit floats (r, g, b, unused): each tap is one SIMD4 multiply then
            // add, the same per-channel operations in the same order as the scalar legacy kernel.
            let line = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: sourceWidth)
            defer { line.deallocate() }
            PipelineRFDETRModel.unit.withUnsafeBufferPointer { unitBuffer in
                horizontal.weights.withUnsafeBufferPointer { weightBuffer in
                horizontal.first.withUnsafeBufferPointer { firstBuffer in
                horizontal.count.withUnsafeBufferPointer { countBuffer in
                horizontal.offset.withUnsafeBufferPointer { offsetBuffer in
                    let unit = unitBuffer.baseAddress!, weights = weightBuffer.baseAddress!
                    let firsts = firstBuffer.baseAddress!, counts = countBuffer.baseAddress!
                    let offsets = offsetBuffer.baseAddress!
                    for row in firstRow..<lastRow {
                        let rowBytes = source + row * sourceWidth * 4
                        var x = 0
                        let floats = UnsafeMutableRawPointer(line)
                        while x + 4 <= sourceWidth {
                            let bytes = UnsafeRawPointer(rowBytes + x * 4).loadUnaligned(as: SIMD16<UInt8>.self)
                            floats.storeBytes(of: SIMD16<Float>(bytes) / 255, toByteOffset: x * 16, as: SIMD16<Float>.self)
                            x += 4
                        }
                        while x < sourceWidth {
                            let pixel = rowBytes + x * 4
                            line[x] = SIMD4(unit[Int(pixel[0])], unit[Int(pixel[1])], unit[Int(pixel[2])], 0)
                            x += 1
                        }
                        let resized = scratch + (row - firstRow) * 3 * side
                        x = 0
                        while x + 2 <= side {
                            let tapA = weights + offsets[x], pixelsA = line + firsts[x], countA = counts[x]
                            let tapB = weights + offsets[x + 1], pixelsB = line + firsts[x + 1], countB = counts[x + 1]
                            var sumA = SIMD4<Float>(repeating: 0), sumB = SIMD4<Float>(repeating: 0)
                            let shared = min(countA, countB)
                            for j in 0..<shared {
                                sumA += pixelsA[j] * tapA[j]
                                sumB += pixelsB[j] * tapB[j]
                            }
                            for j in shared..<countA { sumA += pixelsA[j] * tapA[j] }
                            for j in shared..<countB { sumB += pixelsB[j] * tapB[j] }
                            resized[x] = sumA[0]; resized[side + x] = sumA[1]; resized[2 * side + x] = sumA[2]
                            resized[x + 1] = sumB[0]; resized[side + x + 1] = sumB[1]; resized[2 * side + x + 1] = sumB[2]
                            x += 2
                        }
                        while x < side {
                            let tap = weights + offsets[x], pixels = line + firsts[x]
                            var sum = SIMD4<Float>(repeating: 0)
                            for j in 0..<counts[x] { sum += pixels[j] * tap[j] }
                            resized[x] = sum[0]; resized[side + x] = sum[1]; resized[2 * side + x] = sum[2]
                            x += 1
                        }
                    }
                }}}}
            }
            // Vertical taps summed in registers from 0, per element in the legacy order.
            typealias Lanes = SIMD8<Float>
            vertical.weights.withUnsafeBufferPointer { weightBuffer in
                for y in outputRows {
                    let count = vertical.count[y], tap = weightBuffer.baseAddress! + vertical.offset[y]
                    for channel in 0..<3 {
                        let target = output + channel * plane + y * side
                        let rows = scratch + (vertical.first[y] - firstRow) * 3 * side + channel * side
                        let mean = PipelineRFDETRModel.mean[channel], std = PipelineRFDETRModel.std[channel]
                        var x = 0
                        while x + Lanes.scalarCount <= side {
                            var sum = Lanes(repeating: 0)
                            for j in 0..<count {
                                sum += UnsafeRawPointer(rows + j * 3 * side + x).loadUnaligned(as: Lanes.self) * tap[j]
                            }
                            UnsafeMutableRawPointer(target + x).storeBytes(of: (sum - mean) / std, as: Lanes.self)
                            x += Lanes.scalarCount
                        }
                        while x < side {
                            var sum: Float = 0
                            for j in 0..<count { sum += rows[j * 3 * side + x] * tap[j] }
                            target[x] = (sum - mean) / std
                            x += 1
                        }
                    }
                }
            }
        }
    }

    static func makeInput() throws -> MLMultiArray {
        try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
    }

    /// Fills a contiguous [1, 3, side, side] Float32 tensor.
    static func preprocess(_ raster: PipelinePageRaster, into result: MLMultiArray) {
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
enum PipelineLayoutDetection {
    static func detect(_ raster: PipelinePageRaster, models: PipelineModels) async throws -> [PipelineLayoutRegion] {
        let model = models.layout
        return try await model.executor.run {
            try decode(model.predict(raster), width: raster.width, height: raster.height)
        }
    }

    static func kind(modelClass: Int) -> PipelineLayoutKind? {
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

    /// Pure decode of one RF-DETR output into page-pixel regions, ordered by descending score.
    static func decode(_ raw: PipelineRFDETRModel.RawOutput, width: Int, height: Int) throws -> [PipelineLayoutRegion] {
        let queries = PipelineRFDETRModel.queries, classes = PipelineRFDETRModel.classes
        // Copied under the array's lock: a GPU-backed output is only coherent inside withUnsafeBufferPointer.
        let boxData = raw.boxes.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        let logitData = raw.logits.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        let boxStride = raw.boxes.strides.map(\.intValue), logitStride = raw.logits.strides.map(\.intValue)
        let thresholds = PipelineRFDETRModel.thresholds
        let floor = thresholds.min() ?? 0
        var scores: [(flat: Int, confidence: Float)] = []
        for q in 0..<queries {
            for c in 0..<classes {
                let value = logitData[q * logitStride[1] + c * logitStride[2]]
                guard value.isFinite else { throw PipelineRFDETRModel.Failure.nonfiniteOutput }
                let confidence = sigmoid(value)
                if confidence >= floor { scores.append((q * classes + c, confidence)) }
            }
        }
        scores.sort { $0.confidence == $1.confidence ? $0.flat < $1.flat : $0.confidence > $1.confidence }
        let selected = scores.prefix(PipelineRFDETRModel.selectedCount).filter {
            let c = $0.flat % classes
            return c < thresholds.count && $0.confidence >= thresholds[c]
        }
        let page = CGRect(x: 0, y: 0, width: width, height: height)
        var regions: [PipelineLayoutRegion] = []
        for candidate in selected {
            let q = candidate.flat / classes, c = candidate.flat % classes
            guard let kind = kind(modelClass: c) else { continue }
            let v = (0..<4).map { boxData[q * boxStride[1] + $0 * boxStride[2]] }
            guard v.allSatisfy(\.isFinite), v[2] >= 0, v[3] >= 0 else { throw PipelineRFDETRModel.Failure.nonfiniteOutput }
            let box = CGRect(x: CGFloat(v[0] - v[2] / 2) * CGFloat(width), y: CGFloat(v[1] - v[3] / 2) * CGFloat(height),
                             width: CGFloat(v[2]) * CGFloat(width), height: CGFloat(v[3]) * CGFloat(height))
            let bounds = box.integral.intersection(page)
            guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else { continue }
            regions.append(PipelineLayoutRegion(kind: kind, bounds: bounds, score: candidate.confidence))
        }
        return regions
    }
}
