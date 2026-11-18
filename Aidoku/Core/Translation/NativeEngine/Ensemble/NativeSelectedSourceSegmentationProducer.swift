import CoreGraphics
import Foundation
import CryptoKit

/// Complete selected source-only mask graph. The same typed producer runs on
/// iOS and macOS; there is no Python process or legacy-segmentation fallback.
final class NativeSelectedSourceSegmentationProducer {
    enum Failure: Error { case invalidInput, invalidModelOutput, sourceMismatch, unsupportedLegacyStageObserver }
    /// Comparison-only global simplification. Context83 and its exterior/body
    /// recovery remain unchanged; only the style78 weak-pixel head is replaced.
    static let connectedWeakEnabled = ProcessInfo.processInfo.environment["AIDOKU_SEGMENTATION_CONNECTED_WEAK"] == "1"
    static let activePolicyRevision = connectedWeakEnabled ? "context83-source-connected-weak-v1" : NativeSegmentationFinalPolicy.policyRevision
    static let activePolicySHA256: String = {
        guard connectedWeakEnabled else { return NativeSegmentationFinalPolicy.policySHA256 }
        let contract = "source-connected-weak-v1|base-policy=" + NativeSegmentationFinalPolicy.policySHA256 + "|8-connected-unpruned-mask|seed=max-primary-boundary-strength-code>existing-weak-limit|style78-not-loaded-or-executed"
        return SHA256.hash(data: Data(contract.utf8)).map { String(format: "%02x", $0) }.joined()
    }()
    protocol PixelClassifier {
        var featureCount: Int { get }
        func probabilities(_ features: NativePixelRFFeatures.Matrix) throws -> [Double]
    }
    struct Models {
        let observations: NativeSourceSegmentationObservations.Models
        let context83: any PixelClassifier
        let style78: (any PixelClassifier)?
        init(observations: NativeSourceSegmentationObservations.Models,
             context83: any PixelClassifier, style78: (any PixelClassifier)?) throws {
            guard context83.featureCount == 83,
                  style78.map({ $0.featureCount == 78 }) ?? NativeSelectedSourceSegmentationProducer.connectedWeakEnabled else { throw Failure.invalidInput }
            self.observations = observations; self.context83 = context83; self.style78 = style78
        }
    }
    struct Output {
        let mask: [UInt8]
        let primary: [Float]
        let boundary: [Float]
        let rawNative: [UInt8]
        let completed: [UInt8]
        let audit: [String: Any]
    }
    /// Synchronous borrowed observations; retaining them can extend COW lifetimes.
    /// Codes are the ORIGINAL policy decision ABI, not cache quantization.
    struct ReplayStage {
        let width: Int
        let height: Int
        let fontPixels: Double
        let primary: [Float]
        let boundary: [Float]
        let rawNative: [UInt8]
        let completed: [UInt8]
        let filledBase: [UInt8]
        let jointCodes: [UInt16]
        let jointComputationRadius: Int
        let weakPositions: [Int]
        let auxiliaryCodes: [UInt16]
        let sourceStyle18: [Double]
        let auxiliaryStyle18: [Double]
        let finalMask: [UInt8]
    }
    typealias ReplayObserver = (ReplayStage) throws -> Void
    typealias Capture = (String, NativePixelRFFeatures.Matrix, [Int]) throws -> Void
    private let models: Models
    private let operations: any NativeSegmentationFinalFeatures.ImageOperations

    init(models: Models, operations: any NativeSegmentationFinalFeatures.ImageOperations) {
        self.models = models; self.operations = operations
    }

    func predict(rgb: [UInt8], width: Int, height: Int, polygons: [[CGPoint]], fontPixels: Double,
                 coarseRF: [Float], fullRF: [Float], affinity: [Float], rfModelWeightsSHA256: String,
                 capture: Capture? = nil, replayObserver: ReplayObserver? = nil) throws -> Output {
        guard !Self.connectedWeakEnabled || (capture == nil && replayObserver == nil) else {
            throw Failure.unsupportedLegacyStageObserver
        }
        let observed = try NativeSourceSegmentationObservations.sourceCrop(rgb: rgb, width: width, height: height,
            polygons: polygons, fontPixels: fontPixels, coarseRF: coarseRF, fullRF: fullRF,
            rfModelWeightsSHA256: rfModelWeightsSHA256, models: models.observations)
        return try finalMask(rgb: rgb, width: width, height: height, fontPixels: fontPixels,
            coarseRF: coarseRF, fullRF: fullRF, affinity: affinity, rfModelWeightsSHA256: rfModelWeightsSHA256,
            observations: observed, capture: capture, replayObserver: replayObserver)
    }

    func finalMask(rgb: [UInt8], width: Int, height: Int, fontPixels: Double,
                   coarseRF: [Float], fullRF: [Float], affinity: [Float], rfModelWeightsSHA256: String,
                   observations observed: NativeSourceSegmentationObservations.Output, capture: Capture? = nil, replayObserver: ReplayObserver? = nil) throws -> Output {
        // The old stage ABI includes learned style78 codes/styles. Never invent
        // those observations when the head is absent in this candidate graph.
        guard !Self.connectedWeakEnabled || (capture == nil && replayObserver == nil) else {
            throw Failure.unsupportedLegacyStageObserver
        }
        guard rfModelWeightsSHA256 == "03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255" else {
            throw Failure.sourceMismatch
        }
        guard width > 0, height > 0, width <= 1_500_000 / height, fontPixels.isFinite, fontPixels > 0 else {
            throw Failure.invalidInput
        }
        let n = width * height
        guard rgb.count == n * 3, coarseRF.count == n * 4, fullRF.count == n * 27,
              affinity.count == 5, affinity.allSatisfy(\.isFinite), observed.rawNative.count == n,
              observed.completed.mask.count == n, observed.primary.count == n, observed.boundary.count == n,
              observed.primary.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              observed.boundary.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.invalidInput }
        try Task.checkCancellation()
        let base = try operations.fillExternalContours(observed.completed.mask, width: width, height: height)
        let distance = try operations.distance(base.map { $0 == 0 ? UInt8(1) : 0 }, width: width,
            height: height, metric: .chebyshev, labels: false).values
        let jointRadius = NativeSegmentationFinalPolicy.requiredJointRadius
        let domain = (0..<n).filter { base[$0] != 0 || distance[$0] <= Float(jointRadius) }
        let edge = try NativeSegmentationFinalFeatures.edgeContext(rgb: rgb, primary: observed.primary,
            native: observed.rawNative, coarseRF: coarseRF, fullRF: fullRF,
            width: width, height: height, fontPixels: fontPixels, operations: operations)
        // Context83 rows end their lifetime before allocating the weak auxiliary rows.
        let joint = try contextCodes(edge: edge, base: base, boundary: observed.boundary,
            width: width, height: height, fontPixels: fontPixels, domain: domain, capture: capture)
        var codes = [UInt16](repeating: 65535, count: n)
        for (row, pixel) in domain.enumerated() { codes[pixel] = joint[row] }
        let style = try NativeSegmentationFinalFeatures.style(rgb: rgb, base: base, distance: distance,
            primary: observed.primary, boundary: observed.boundary, width: width, height: height,
            fontPixels: fontPixels, affinity: affinity)
        let unpruned = try NativeSegmentationFinalPolicy.apply(.init(width: width, height: height, base: base,
            primary: observed.primary, boundary: observed.boundary, jointCodes: codes, style: style,
            auxiliaryCodes: [UInt16](repeating: 8191, count: n)))
        if Self.connectedWeakEnabled {
            let connected = try NativeSegmentationFinalPolicy.connectedWeak(mask: unpruned.mask,
                primary: observed.primary, boundary: observed.boundary, width: width, height: height)
            return Output(mask: connected.mask, primary: observed.primary, boundary: observed.boundary,
                rawNative: observed.rawNative, completed: observed.completed.mask,
                audit: ["policySHA256": Self.activePolicySHA256, "policyRevision": Self.activePolicyRevision,
                    "finalPolicyEngine": "native-context83-source-connected-weak", "jointModelSHA256": NativeSegmentationFinalPolicy.jointModelSHA256,
                    "context83Executed": true, "style78Executed": false, "auxiliaryModelSHA256": "not-executed",
                    "jointPixels": domain.count, "jointComputationRadius": jointRadius,
                    "weakCleanup": "8-connected-to-observed-nonweak-primary-or-boundary",
                    "weakSourceStrengthLimit": NativeSegmentationFinalPolicy.accepted.auxiliaryPixelGate.maximumSourceStrengthCode,
                    "unsupportedWeakPixelsRemoved": connected.auxiliaryRemoved,
                    "GTRead": false, "storedMaskRead": false, "bboxMaskClipping": false, "legacyFallback": false])
        }
        let weak = (0..<n).filter {
            let strength = min(64, Int(ceil(max(observed.primary[$0], observed.boundary[$0]) * 64 - 1e-6)))
            return unpruned.mask[$0] != 0 && strength <= 12
        }
        let rawDistance = try operations.distance(observed.rawNative.map { $0 == 0 ? UInt8(1) : 0 },
            width: width, height: height, metric: .chebyshev, labels: false).values
        let rawStyle = try NativeSegmentationFinalFeatures.style(rgb: rgb, base: observed.rawNative, distance: rawDistance,
            primary: observed.primary, boundary: observed.primary, width: width, height: height,
            fontPixels: fontPixels, affinity: affinity)
        let auxiliary = try auxiliaryCodes(edge: edge, style: rawStyle, positions: weak, capture: capture)
        // Geometry and member votes already produced this exact unpruned mask.
        var mask = unpruned.mask
        var auxiliaryRemoved = 0
        let gate = NativeSegmentationFinalPolicy.accepted.auxiliaryPixelGate
        for (row, pixel) in weak.enumerated() {
            guard auxiliary[row] < 8192 else { throw Failure.invalidModelOutput }
            if auxiliary[row] < gate.thresholdCode {
                mask[pixel] = 0
                auxiliaryRemoved += 1
            }
        }
        if let replayObserver {
            try replayObserver(.init(width: width, height: height, fontPixels: fontPixels,
                primary: observed.primary, boundary: observed.boundary, rawNative: observed.rawNative,
                completed: observed.completed.mask, filledBase: base, jointCodes: codes, jointComputationRadius: jointRadius,
                weakPositions: weak, auxiliaryCodes: auxiliary, sourceStyle18: style,
                auxiliaryStyle18: rawStyle, finalMask: mask))
        }
        return Output(mask: mask, primary: observed.primary, boundary: observed.boundary, rawNative: observed.rawNative,
            completed: observed.completed.mask, audit: ["policySHA256": NativeSegmentationFinalPolicy.policySHA256,
                "jointModelSHA256": NativeSegmentationFinalPolicy.jointModelSHA256,
                "auxiliaryModelSHA256": NativeSegmentationFinalPolicy.auxiliaryModelSHA256,
                "finalPolicyEngine": "native-context83-style78", "jointPixels": domain.count,
                "jointComputationRadius": jointRadius, "jointDomainABI": "full-fields-policy-radius-v1",
                "auxiliaryPixels": weak.count, "auxiliaryRemoved": auxiliaryRemoved,
                "sourceStyle18": style, "auxiliarySourceStyle18": rawStyle,
                "GTRead": false, "storedMaskRead": false, "legacyFallback": false])
    }

    private func contextCodes(edge: NativePixelRFFeatures.Matrix, base: [UInt8], boundary: [Float],
                              width: Int, height: Int, fontPixels: Double, domain: [Int], capture: Capture?) throws -> [UInt16] {
        guard !domain.isEmpty else { return [] }
        let features = try NativeSegmentationFinalFeatures.context(edge: edge, base: base, boundary: boundary,
            width: width, height: height, fontPixels: fontPixels, positions: domain, operations: operations)
        try capture?("context83", features, domain)
        return try quantize(models.context83.probabilities(features), expected: domain.count)
    }
    private func auxiliaryCodes(edge: NativePixelRFFeatures.Matrix, style: [Double], positions: [Int],
                                capture: Capture?) throws -> [UInt16] {
        guard !positions.isEmpty else { return [] }
        let features = try NativeSegmentationFinalFeatures.auxiliary(edge: edge, style: style, positions: positions)
        try capture?("style78", features, positions)
        guard let style78 = models.style78 else { throw Failure.invalidInput }
        return try quantize(style78.probabilities(features), expected: positions.count)
    }
    private func quantize(_ probabilities: [Double], expected: Int) throws -> [UInt16] {
        guard probabilities.count == expected else { throw Failure.invalidModelOutput }
        return try probabilities.map { try NativeSegmentationFinalPolicy.quantize(probability: $0) }
    }
}
