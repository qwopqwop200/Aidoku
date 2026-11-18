import Foundation

extension NativeSelectedSourceSegmentationProducer {
    typealias SourceReplayObserver = (SourceNativeInput, ReplayStage) throws -> Void
    struct SourceOutput {
        let input: SourceNativeInput
        let audit: [String: Any]
    }
    /// Native full-source constructor seam used on iOS and macOS. The caller
    /// unions overlapping same-page own masks into context AFTER all owners run.
    /// Live OCR8, text, membership and source binding are preserved unchanged.
    func segment(_ input: SourceNativeInput, capture: Capture? = nil, replayObserver: SourceReplayObserver? = nil) throws -> SourceOutput {
        try input.validate(requirePredictions: false)
        let boundObserver: ReplayObserver?
        if let replayObserver { boundObserver = { try replayObserver(input, $0) } }
        else { boundObserver = nil }
        let prediction = try predict(rgb: input.rgb, width: input.width, height: input.height,
            polygons: input.memberPolygons, fontPixels: input.fontPriorSourcePixels,
            coarseRF: input.coarseRF, fullRF: input.rf, affinity: input.affinityScores,
            rfModelWeightsSHA256: input.rfModelWeightsSHA256, capture: capture, replayObserver: boundObserver)
        var output = input
        output.primary = prediction.primary
        output.boundary = prediction.boundary
        output.rawNative = prediction.rawNative
        output.completed = prediction.completed
        output.ownMask = prediction.mask
        output.contextMask = prediction.mask
        // sourceCrop classifies width*height real RGB pixels in both forests
        // (NativePixelRFFeatures / NativePixelRFBoundaryFeatures), without image
        // padding or sparse scatter. This must change if that producer changes;
        // zero probability is an observed value, not an availability sentinel.
        let n = input.width * input.height
        guard prediction.primary.count == n, prediction.boundary.count == n, prediction.rawNative.count == n,
              prediction.primary.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              prediction.boundary.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              prediction.rawNative.allSatisfy({ $0 == 0 || $0 == 1 || $0 == 255 }) else {
            throw SourceNativeInput.Failure.invalidPredictions
        }
        output.observationValid = [UInt8](repeating: 1, count: n)
        return SourceOutput(input: output, audit: prediction.audit)
    }
}
