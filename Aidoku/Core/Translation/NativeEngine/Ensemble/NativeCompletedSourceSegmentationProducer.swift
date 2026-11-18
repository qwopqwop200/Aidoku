import CoreGraphics
import Foundation

/// Global primary/boundary completed-mask graph, with no context83/style78
/// classifier, four-member refinement or post-boundary external-contour fill.
/// Existing learned primary/boundary observations remain available downstream.
final class NativeCompletedSourceSegmentationProducer {
    enum Failure: Error { case invalidInput, unsupportedLegacyStageObserver }
    static let policyRevision = "primary-boundary-completed-v1"
    // Canonical graph-contract digest; supplied by the artifact patch generator.
    static let policySHA256 = "4e90ff32e63c44e3b3b45d43b2fa058474e815cca5c63adb0d205363807c502d"
    private let models: NativeSourceSegmentationObservations.Models

    init(bundle: Bundle = .main, sourceDirectory: URL? = nil) throws {
        models = try NativeSourceSegmentationObservations.Models(assetDirectory: sourceDirectory, bundle: bundle)
    }
    init(models: NativeSourceSegmentationObservations.Models) { self.models = models }

    func predict(rgb: [UInt8], width: Int, height: Int, polygons: [[CGPoint]], fontPixels: Double,
                 coarseRF: [Float], fullRF: [Float], affinity: [Float],
                 rfModelWeightsSHA256: String) throws -> NativeSelectedSourceSegmentationProducer.Output {
        guard width > 0, height > 0, width <= 1_500_000 / height,
              fontPixels.isFinite, fontPixels > 0, affinity.count == 5, affinity.allSatisfy(\.isFinite) else {
            throw Failure.invalidInput
        }
        try Task.checkCancellation()
        let observed = try NativeSourceSegmentationObservations.sourceCrop(rgb: rgb, width: width, height: height,
            polygons: polygons, fontPixels: fontPixels, coarseRF: coarseRF, fullRF: fullRF,
            rfModelWeightsSHA256: rfModelWeightsSHA256, models: models)
        try Task.checkCancellation()
        let n = width * height
        guard observed.primary.count == n, observed.boundary.count == n, observed.rawNative.count == n,
              observed.completed.mask.count == n, observed.completed.mask.allSatisfy({ $0 == 0 || $0 == 255 }),
              observed.primary.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              observed.boundary.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw Failure.invalidInput
        }
        return .init(mask: observed.completed.mask, primary: observed.primary, boundary: observed.boundary,
            rawNative: observed.rawNative, completed: observed.completed.mask,
            audit: ["policySHA256": Self.policySHA256, "policyRevision": Self.policyRevision,
                "finalPolicyEngine": "native-primary-boundary-completed", "maskStage": "boundary-completed",
                "context83Executed": false, "style78Executed": false, "ensembleRefinementExecuted": false,
                "postBoundaryHoleFillExecuted": false, "primaryBoundaryObservationsRetained": true,
                "GTRead": false, "storedMaskRead": false, "bboxMaskClipping": false, "legacyFallback": false])
    }

    func segment(_ input: SourceNativeInput,
                 replayObserver: NativeSelectedSourceSegmentationProducer.SourceReplayObserver? = nil)
                 throws -> NativeSelectedSourceSegmentationProducer.SourceOutput {
        // The legacy stage ABI requires unavailable joint/style decisions.
        // Do not manufacture zeros, old headers or fake learned probabilities.
        guard replayObserver == nil else { throw Failure.unsupportedLegacyStageObserver }
        try input.validate(requirePredictions: false)
        let prediction = try predict(rgb: input.rgb, width: input.width, height: input.height,
            polygons: input.memberPolygons, fontPixels: input.fontPriorSourcePixels,
            coarseRF: input.coarseRF, fullRF: input.rf, affinity: input.affinityScores,
            rfModelWeightsSHA256: input.rfModelWeightsSHA256)
        var output = input
        output.primary = prediction.primary; output.boundary = prediction.boundary
        output.rawNative = prediction.rawNative; output.completed = prediction.completed
        output.ownMask = prediction.mask; output.contextMask = prediction.mask
        output.observationValid = [UInt8](repeating: 1, count: input.width * input.height)
        return .init(input: output, audit: prediction.audit)
    }
}

/// Temporary global comparison selector, shared by host and app. No page gates.
/// With the flag absent, model construction and calls are the existing graph.
final class NativeSourceSegmentationExecution {
    enum MinimalFailure: Error { case minimalTypedEntryRequired, minimalPolicyRequired }
    enum Purpose { case featureObservations, erasure }
    static var minimalConfiguration: NativeMinimalSourceSegmentation.Configuration? { NativeSourceInferencePolicy.minimalSegmentationConfiguration }
    static let completedOnlyEnabled = ProcessInfo.processInfo.environment["AIDOKU_SEGMENTATION_COMPLETED_ONLY"] == "1"
    static let policySHA256 = minimalConfiguration?.policySHA256 ?? (completedOnlyEnabled ? NativeCompletedSourceSegmentationProducer.policySHA256 : NativeSelectedSourceSegmentationProducer.activePolicySHA256)
    static let policyRevision = minimalConfiguration?.policyRevision ?? (completedOnlyEnabled ? NativeCompletedSourceSegmentationProducer.policyRevision : NativeSelectedSourceSegmentationProducer.activePolicyRevision)
    /// Rich feature observations keep their real legacy policy identity. The
    /// independent erasure mask may replay a smaller policy from actual p.
    static let erasurePolicySHA256 = NativeSourceInferencePolicy.erasureSegmentationConfiguration?.policySHA256 ?? policySHA256
    static let erasurePolicyRevision = NativeSourceInferencePolicy.erasureSegmentationConfiguration?.policyRevision ?? policyRevision
    private enum Program {
        case minimal(NativeMinimalSourceSegmentation)
        case completed(NativeCompletedSourceSegmentationProducer)
        case refined(NativeSelectedSourceSegmentationProducer)
    }
    private let program: Program
    init(bundle: Bundle = .main, sourceDirectory: URL? = nil, numericDirectory: URL? = nil,
         purpose: Purpose = .featureObservations) throws {
        try NativeSourceInferencePolicy.validate()
        let configuration = purpose == .erasure ?
            (NativeSourceInferencePolicy.erasureSegmentationConfiguration ?? Self.minimalConfiguration) : Self.minimalConfiguration
        if let configuration {
            // This branch is BEFORE all legacy primary+boundary/context/style
            // construction, not a late return after eager model initialization.
            program = .minimal(try NativeMinimalSourceSegmentation(configuration: configuration,
                bundle: bundle, sourceDirectory: sourceDirectory))
        } else if Self.completedOnlyEnabled {
            program = .completed(try NativeCompletedSourceSegmentationProducer(bundle: bundle, sourceDirectory: sourceDirectory))
        } else {
            program = .refined(try NativeSelectedSourceSegmentationProducer(bundle: bundle, sourceDirectory: sourceDirectory, numericDirectory: numericDirectory))
        }
    }
    var isMinimal: Bool {
        if case .minimal = program { return true }
        return false
    }
    func predictMinimal(_ input: NativeMinimalSourceSegmentation.Input) throws -> NativeMinimalSourceSegmentation.Output {
        guard case .minimal(let producer) = program else { throw MinimalFailure.minimalPolicyRequired }
        return try producer.predict(input)
    }
    func predict(rgb: [UInt8], width: Int, height: Int, polygons: [[CGPoint]], fontPixels: Double,
                 coarseRF: [Float], fullRF: [Float], affinity: [Float], rfModelWeightsSHA256: String)
                 throws -> NativeSelectedSourceSegmentationProducer.Output {
        switch program {
        case .minimal: throw MinimalFailure.minimalTypedEntryRequired
        case .completed(let producer): return try producer.predict(rgb: rgb, width: width, height: height, polygons: polygons, fontPixels: fontPixels, coarseRF: coarseRF, fullRF: fullRF, affinity: affinity, rfModelWeightsSHA256: rfModelWeightsSHA256)
        case .refined(let producer): return try producer.predict(rgb: rgb, width: width, height: height, polygons: polygons, fontPixels: fontPixels, coarseRF: coarseRF, fullRF: fullRF, affinity: affinity, rfModelWeightsSHA256: rfModelWeightsSHA256)
        }
    }
    func segment(_ input: SourceNativeInput, replayObserver: NativeSelectedSourceSegmentationProducer.SourceReplayObserver? = nil)
                 throws -> NativeSelectedSourceSegmentationProducer.SourceOutput {
        switch program {
        case .minimal: throw MinimalFailure.minimalTypedEntryRequired
        case .completed(let producer): return try producer.segment(input, replayObserver: replayObserver)
        case .refined(let producer): return try producer.segment(input, replayObserver: replayObserver)
        }
    }
}
