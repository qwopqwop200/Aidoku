import CoreGraphics
import CoreML
import Foundation

/// Internal to NativeAdmittedAOTPageRoute's serial actor. Never use concurrently.
/// Whole-page 1024 FP16 transport, ported from the validated scalar AOT seam.
@available(iOS 16.0, macOS 13.0, *)
final class NativeAOTResidentModel {
    private let model: MLModel
    private let image: MLMultiArray
    private let mask: MLMultiArray
    private let provider: MLDictionaryFeatureProvider
    private(set) var preprocessingSeconds: Double = 0
    private(set) var predictionSeconds: Double = 0
    private(set) var scatterSeconds: Double = 0

    init(compiledURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        image = try MLMultiArray(shape: [1, 3, 1024, 1024], dataType: .float16)
        mask = try MLMultiArray(shape: [1, 1, 1024, 1024], dataType: .float16)
        guard image.strides.map(\.intValue) == [3145728, 1048576, 1024, 1],
              mask.strides.map(\.intValue) == [1048576, 1048576, 1024, 1] else {
            throw NativeAdmittedAOTPageRoute.Failure.modelContract
        }
        provider = try MLDictionaryFeatureProvider(dictionary: ["masked_image": image, "mask": mask])
    }

    func restore(rgba: [UInt8], removal: [UInt8], width: Int, height: Int) throws -> CGImage {
        try Task.checkCancellation()
        let preparationStart = Date()
        let content = try NativeResidentAOT.prepareRGBA(rgba: rgba, finalMask: removal,
            width: width, height: height, image: image, mask: mask)
        try Task.checkCancellation()
        preprocessingSeconds = Date().timeIntervalSince(preparationStart)
        let predictionStart = Date()
        // Core ML's synchronous prediction cannot be interrupted mid-kernel;
        // cancellation is checked before and after and no cancelled final is returned.
        let output = try autoreleasepool { try model.prediction(from: provider) }
        predictionSeconds = Date().timeIntervalSince(predictionStart)
        try Task.checkCancellation()
        let scatterStart = Date()
        guard let raw = output.featureValue(for: "raw_rgb")?.multiArrayValue,
              raw.shape.map(\.intValue) == [1, 3, 1024, 1024], raw.dataType == .float16,
              raw.strides.map(\.intValue) == [3145728, 1048576, 1024, 1] else {
            throw NativeAdmittedAOTPageRoute.Failure.modelContract
        }
        let restored: [UInt8]
        do {
            restored = try NativeResidentAOT.composeRGBA(source: rgba, finalMask: removal,
                width: width, height: height, raw: raw, content: content)
        } catch is CancellationError { throw CancellationError() }
        catch { throw NativeAdmittedAOTPageRoute.Failure.modelContract }
        // Outside the ORIGINAL mask remains byte-exact; padding is inference-only.
        let result = try NativeAdmittedAOTPageRoute.image(rgba: restored, width: width, height: height)
        scatterSeconds = Date().timeIntervalSince(scatterStart)
        return result
    }
}
