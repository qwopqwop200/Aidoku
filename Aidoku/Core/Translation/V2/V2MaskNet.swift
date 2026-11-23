@preconcurrency import CoreML
import Foundation

/// S6 glyph classifier: a compact U-Net (Core ML, FP16) over one block crop, box-downscaled by the
/// smallest integer factor that brings the median line thickness to at most `targetThickness` px. Input 1 x 6 x H x W
/// (RGB, max |RGB - background|, line polygon and ROI coverage, all 0-1; H and W multiples of `align`),
/// output the per-pixel glyph probability. Fit on train GT glyph masks (port-eval/convmask/tools/train.py).
final class V2MaskNet: @unchecked Sendable {
    static let resourceName = "V2MaskUNet-FP16"
    static let targetThickness: Double = 64
    static let align = 8
    static let channels = 6

    /// Blocks call `predict` concurrently (Core ML predictions are thread-safe; each call has its own input).
    let model: MLModel

    init(compiledURL: URL) throws {
        let configuration = MLModelConfiguration()
        // One small prediction per block at a new size: on the Mac CPU-only S6 took a third of the time of
        // CPU+GPU (per-shape GPU dispatch); the Neural Engine would recompile per shape.
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: compiledURL, configuration: configuration)
    }

    /// The app bundle's model (nil when missing: S6 then erases the dilated line polygons).
    static let bundled: V2MaskNet? = Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc")
        .flatMap { try? V2MaskNet(compiledURL: $0) }

    /// Downscale factor for a block of median line thickness `thickness`.
    static func factor(_ thickness: Double) -> Int { max(1, Int((thickness / targetThickness).rounded(.up))) }

    /// Probabilities (row-major `height` x `width`) for an input of `channels` planes of `height` x `width`.
    func predict(_ input: MLMultiArray, height: Int, width: Int) throws -> [Float] {
        let features = try MLDictionaryFeatureProvider(dictionary: ["input": input])
        let result = try model.prediction(from: features)
        guard let prob = result.featureValue(for: "prob")?.multiArrayValue, prob.shape.count == 4,
              prob.shape[2].intValue == height, prob.shape[3].intValue == width else { throw Failure.modelContract }
        return Self.plane(prob, height: height, width: width)
    }

    enum Failure: Error { case modelContract }

    /// Row-major copy of a 1 x 1 x H x W array (output rows may be padded).
    static func plane(_ array: MLMultiArray, height: Int, width: Int) -> [Float] {
        let rowStride = array.strides[2].intValue, columnStride = array.strides[3].intValue
        var out = [Float](repeating: 0, count: height * width)
        if array.dataType == .float32 {
            let p = array.dataPointer.assumingMemoryBound(to: Float.self)
            for y in 0..<height { for x in 0..<width { out[y * width + x] = p[y * rowStride + x * columnStride] } }
        } else {
            for y in 0..<height {
                for x in 0..<width { out[y * width + x] = array[[0, 0, y, x] as [NSNumber]].floatValue }
            }
        }
        return out
    }
}
