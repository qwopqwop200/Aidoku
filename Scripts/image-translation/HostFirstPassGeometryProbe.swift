import CoreGraphics
import CryptoKit
import Foundation

/// HOST ONLY. Observe the real production first recognize() arguments, never a
/// separately reconstructed geometry plan. No recognizer instance/model is made.
@available(iOS 18.0, *)
enum HostFirstPassGeometryProbe {
    enum Failure: Error {
        case replayRequired
        case scopedDetectionUnsupported
        case invalidInput
        case repeatedRecognition
        case receiptMismatch
        case firstPassNotReached
    }

    private struct AuditedStop: Error {
        let token: UUID
    }

    struct Region: Codable, Sendable {
        let sourceIndex: Int
        let polygon: [CGPoint]
        let samplingPolygon: [CGPoint]?
        let isThinFinePrintRecovery: Bool
        let finePrintRetryPolygons: [[CGPoint]]
        let useProvidedOrder: Bool
        let minimumSequenceWidth: Int
        let recognitionColumnEvidence: NativeOCRDetectorColumnEvidence?
        let photometricMode: String

        init(_ region: NativeCoreMLRecognitionRegion) {
            sourceIndex = region.sourceIndex
            polygon = region.polygon
            samplingPolygon = region.samplingPolygon
            isThinFinePrintRecovery = region.isThinFinePrintRecovery
            finePrintRetryPolygons = region.finePrintRetryPolygons
            useProvidedOrder = region.useProvidedOrder
            minimumSequenceWidth = region.minimumSequenceWidth
            recognitionColumnEvidence = region.recognitionColumnEvidence
            photometricMode = region.photometricMode.rawValue
        }
    }

    struct Receipt: Codable, Sendable {
        let schemaVersion: Int
        let token: UUID
        let sourceSHA256: String
        let width: Int
        let height: Int
        let requestID: String
        let confidenceThreshold: Double
        let recognitionCalls: Int
        let recognizerModelCalls: Int
        let regions: [Region]
    }

    final class Context: @unchecked Sendable {
        let receiptURL: URL
        let sourceSHA256: String
        let width: Int
        let height: Int
        private let token = UUID()
        private let lock = NSLock()
        private var cancelled = false
        private var calls = 0
        private var captured: Receipt?
        private var receiptDigest: String?

        init(receiptURL: URL, sourceSHA256: String, width: Int, height: Int) throws {
            guard sourceSHA256.count == 64, sourceSHA256.allSatisfy({ $0.isHexDigit }), width > 0, height > 0 else {
                throw Failure.invalidInput
            }
            self.receiptURL = receiptURL
            self.sourceSHA256 = sourceSHA256
            self.width = width
            self.height = height
        }

        func cancel() { lock.withLock { cancelled = true } }

        func checkCancellation() throws {
            try Task.checkCancellation()
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }

        fileprivate func capture(frame: NativeOCRRGBAFrame, regions: [NativeCoreMLRecognitionRegion],
                                 requestID: String, threshold: Double,
                                 cancellationCheck: @Sendable () throws -> Void) throws -> Never {
            try checkCancellation()
            try cancellationCheck()
            guard frame.width == width, frame.height == height, !requestID.isEmpty,
                  threshold.isFinite, (0...1).contains(threshold) else { throw Failure.invalidInput }
            let snapshot = Receipt(schemaVersion: 1, token: token, sourceSHA256: sourceSHA256,
                width: width, height: height, requestID: requestID, confidenceThreshold: threshold,
                recognitionCalls: 1, recognizerModelCalls: 0, regions: regions.map(Region.init))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(snapshot)
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                guard calls == 0 else { throw Failure.repeatedRecognition }
                calls += 1
                // Receipt persistence failure is a genuine failure, never a successful sentinel.
                try bytes.write(to: receiptURL, options: .atomic)
                captured = snapshot
                receiptDigest = Self.digest(bytes)
            }
            try checkCancellation()
            try cancellationCheck()
            throw AuditedStop(token: token)
        }

        /// Call from a catch while the typed error is still intact. Never accept
        /// a status string, matching error description, dump presence or old file.
        func verifiedReceipt(for error: Error) throws -> Receipt? {
            try checkCancellation()
            guard let stop = error as? AuditedStop, stop.token == token else { return nil }
            return try lock.withLock {
                guard !cancelled, calls == 1, let receipt = captured, let digest = receiptDigest,
                      receipt.token == token, receipt.sourceSHA256 == sourceSHA256,
                      receipt.recognitionCalls == 1, receipt.recognizerModelCalls == 0 else {
                    throw Failure.receiptMismatch
                }
                let bytes = try Data(contentsOf: receiptURL)
                guard Self.digest(bytes) == digest else { throw Failure.receiptMismatch }
                return receipt
            }
        }

        private static func digest(_ bytes: Data) -> String {
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    @TaskLocal static var current: Context?

    /// Run the ordinary Reader path and intercept only our in-memory, persisted
    /// receipt sentinel. An empty/no-first-pass production return is not a hit.
    static func audit(context: Context, operation: @Sendable () async throws -> Void) async throws -> Receipt {
        try await $current.withValue(context) {
            do {
                try await operation()
            } catch {
                if let receipt = try context.verifiedReceipt(for: error) { return receipt }
                throw error
            }
            try context.checkCancellation()
            throw Failure.firstPassNotReached
        }
    }

    final class Recognizer: NativeCoreMLRecognizing, @unchecked Sendable {
        let context: Context
        let recoverySequenceWidthLimit: Int
        init(context: Context, recoverySequenceWidthLimit: Int = 0) {
            self.context = context
            self.recoverySequenceWidthLimit = recoverySequenceWidthLimit
        }
        func prepare() async throws { try context.checkCancellation() }
        func prepareIdlePreservingDemandCapacity() async throws { try context.checkCancellation() }
        func recognize(frame: NativeOCRRGBAFrame, regions: [NativeCoreMLRecognitionRegion], requestID: String,
                       confidenceThreshold: Double,
                       cancellationCheck: @escaping @Sendable () throws -> Void) async throws -> NativeCoreMLRecognitionResult {
            try context.capture(frame: frame, regions: regions, requestID: requestID,
                                threshold: confidenceThreshold, cancellationCheck: cancellationCheck)
        }
        func cancelCurrent() { context.cancel() }
        func cancelPreparation() {}
        func purgeResources() async {}
    }

    /// Preparation is intentionally model-free; absent probability replay cannot
    /// fall back to the normal detector's bootstrap prediction.
    struct ReplayDetector: NativeCoreMLDetecting {
        func prepare(sourceWidth: Int, sourceHeight: Int) async throws { try Task.checkCancellation() }
        func warmUpModel() async throws { try Task.checkCancellation() }
        func detect(frame: NativeOCRRGBAFrame, requestID: String, configuration: NativeCoreMLDBPostprocessConfiguration,
                    cancellationCheck: @escaping @Sendable () throws -> Void) async throws -> NativeCoreMLDetectionResult {
            try await detect(frame: frame, requestID: requestID, configuration: configuration, recognitionScopes: nil,
                             probabilityObserver: nil, cancellationCheck: cancellationCheck)
        }
        func detect(frame: NativeOCRRGBAFrame, requestID: String, configuration: NativeCoreMLDBPostprocessConfiguration,
                    recognitionScopes: [CGRect]?,
                    cancellationCheck: @escaping @Sendable () throws -> Void) async throws -> NativeCoreMLDetectionResult {
            try await detect(frame: frame, requestID: requestID, configuration: configuration,
                             recognitionScopes: recognitionScopes, probabilityObserver: nil, cancellationCheck: cancellationCheck)
        }
        func detect(frame: NativeOCRRGBAFrame, requestID: String, configuration: NativeCoreMLDBPostprocessConfiguration,
                    recognitionScopes: [CGRect]?, probabilityObserver: NativeMainEnsembleOCRProbability.Observer?,
                    cancellationCheck: @escaping @Sendable () throws -> Void) async throws -> NativeCoreMLDetectionResult {
            try Task.checkCancellation()
            try cancellationCheck()
            guard recognitionScopes == nil else { throw Failure.scopedDetectionUnsupported }
            guard HostDirectionReplay.current?.map != nil else { throw Failure.replayRequired }
            guard let result = try HostDirectionReplay.detection(frame: frame, requestID: requestID,
                configuration: configuration, probabilityObserver: probabilityObserver) else { throw Failure.replayRequired }
            try Task.checkCancellation()
            try cancellationCheck()
            return result
        }
        func cancelCurrent() {}
        func cancelPreparation() {}
        func purgeResources() async {}
    }

    /// Replace only the host-generated Reader service's pipeline constructor.
    /// A fresh service/pipeline is required per Context (Reader caches models).
    /// The host injects HostResources.bundle at this call site. Keep it lazy:
    /// probe runs do not prepare models and must never evaluate that getter.
    static func makePipeline(modelTier: IPhoneOCRModelTier, detectorMaximumSide: Int? = nil,
                             recognizerMaximumWidth: Int? = nil,
                             existingDetector: NativeCoreMLDetector? = nil,
                             bundle: @autoclosure () -> Bundle = Bundle.main) -> NativeCoreMLOCRPipeline {
        guard let context = current else {
            return NativeCoreMLOCRPipeline(modelTier: modelTier, detectorMaximumSide: detectorMaximumSide,
                                          recognizerMaximumWidth: recognizerMaximumWidth,
                                          existingDetector: existingDetector, bundle: bundle())
        }
        let profile = NativeCoreMLOCRModelProfile.profile(for: modelTier)
        return NativeCoreMLOCRPipeline(detector: ReplayDetector(), recognizer: Recognizer(context: context),
                                       postprocessConfiguration: profile.postprocessConfiguration)
    }
}
