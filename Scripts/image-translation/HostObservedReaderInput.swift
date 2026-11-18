import CoreGraphics
import Foundation

/// Host-only native ingress for the UNMODIFIED shared Reader postprocess.
/// Root's explicit observed-replay build replaces only pipeline.recognize with
/// load(image:configuration:). A normal build never consults this scope.
@available(macOS 15.0, *)
enum HostObservedReaderInput {
    enum Failure: Error { case missingScope, source, configuration, RFReplayRequired, RFUnavailable }
    fileprivate final class Invocation: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func record() { lock.lock(); calls += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    struct Context: Sendable {
        let page: HostObservedOCRReplay.Page
        /// Caller-supplied FROZEN upstream settings, not newly requested DET /
        /// resize/crop settings. The original composite config SHA stays on page.
        let expectedReaderConfiguration: ReaderOCRConfiguration
        let preRecognition: HostObservedOCRReplay.PreRecognition
        let recognitionAdmission: NativeSimpleRecognitionAdmission.Configuration?
        let deduplication: NativeSimpleOCRDedup.Configuration?
        let changedCoreReplay: (@Sendable () throws -> ChangedCore)?
        fileprivate let invocation = Invocation()
        init(page: HostObservedOCRReplay.Page, expectedReaderConfiguration: ReaderOCRConfiguration,
             preRecognition: HostObservedOCRReplay.PreRecognition,
             recognitionAdmission: NativeSimpleRecognitionAdmission.Configuration?,
             deduplication: NativeSimpleOCRDedup.Configuration?,
             changedCoreReplay: (@Sendable () throws -> ChangedCore)? = nil) {
            self.page = page; self.expectedReaderConfiguration = expectedReaderConfiguration
            self.preRecognition = preRecognition; self.recognitionAdmission = recognitionAdmission
            self.deduplication = deduplication
            self.changedCoreReplay = changedCoreReplay
        }
    }
    /// NEW bank table ordinals are never advertised as original old-bank packet IDs.
    struct ChangedCore: Sendable {
        let lines: [NativeCoreMLOCRLine]
        let geometry: [NativeOCRIndividualGeometryHypotheses.Individual]
        let selectedBoxes: Int
        let tableScheduledSourceIndices: [Int]
        let receipt: Data
    }
    @TaskLocal static var current: Context?
    @TaskLocal static var observer: (@Sendable (Result) -> Void)?

    struct Result: Sendable {
        let width: Int
        let height: Int
        let lines: [NativeCoreMLOCRLine]
        let individualGeometry: [NativeOCRIndividualGeometryHypotheses.Individual]
        let selectedBoxes: Int
        let detectedBoxes: Int
        let totalMilliseconds: Double
        let sourceVerificationMilliseconds: Double
        let consumerReplayMilliseconds: Double
        let sourceEncodedSHA256: String
        let originalProducerSHA256: String
        let originalPacketOrdinals: [Int]
        var packetOrdinalDomain = "original-observed-module-api-packets"
        var tableScheduledSourceIndices: [Int] = []
        var recognitionBankReceipt: Data? = nil
        let replayDisposition = "authenticated-core-observations-current-consumer-no-core-prediction"
        let newCorePredictions = 0
        let globalDBMapAvailable = false
        // These legacy recovery families were not run by the authenticated raw
        // source-anchor ingress. No unavailable detector/REC array is invented.
        let recoveryCandidates: [NativeCoreMLOCRLine] = []
        let isolatedLines: [NativeCoreMLOCRLine] = []
        let splitLines: [NativeCoreMLOCRLine] = []
        let gapLines: [NativeCoreMLOCRGapLine] = []
        let frameConversionMilliseconds: Double = 0
        let detectionMilliseconds: Double = 0
        let recognitionMilliseconds: Double = 0
        let stackedRowSplitMilliseconds: Double = 0
        let unitMilliseconds: Double = 0
        let unitLineCount = 0
        // The old live snapshot is UNAVAILABLE, never recreated from final
        // owners. Authentic raw module observations remain in the original bank.
        var ensembleStageSnapshot: NativeOCREnsembleStageSnapshot? { nil }
        var rawCanonicalReceipt: NativeOCRRawCanonicalRuntime.Receipt? { nil }
    }

    struct Evaluation: Sendable {
        let regions: [ReaderTranslationRegion]
        let phases: [String: Double]
    }

    /// Call BEFORE invoking ReaderOCRService: RF occurs ahead of native ingress.
    /// Use a dedicated process with immutable startup replay-only environment;
    /// never switch an already initialized capture session into this scope.
    static func evaluate(context: Context,
                         operation: @Sendable () async throws -> Evaluation) async throws -> Evaluation {
        let environment = ProcessInfo.processInfo.environment
        // Existing generated build constant is true ONLY when live native
        // pipeline.recognize was removed. This must fail before any Reader call
        // in an ordinary binary, not merely detect unintended NN afterward.
        guard HostBuildMode.savedReaderReplay,
              environment["AIDOKU_HOST_RF_RAW_MODE"] == "replay-only",
              let archive = environment["AIDOKU_HOST_RF_RAW_ARCHIVE"], archive.hasPrefix("/"),
              environment["AIDOKU_DISABLE_RF_LAYOUT"] != "1" else { throw Failure.RFReplayRequired }
        try HostRFRawReplay.preflight()
        let scope = Context(page: context.page, expectedReaderConfiguration: context.expectedReaderConfiguration,
            preRecognition: context.preRecognition, recognitionAdmission: context.recognitionAdmission,
            deduplication: context.deduplication, changedCoreReplay: context.changedCoreReplay)
        return try await $current.withValue(scope) {
            let result = try await operation()
            // Reader normally tolerates absent RF. An exact cache replay must
            // not quietly publish that fallback as the requested full route.
            guard scope.invocation.count == 1 else { throw Failure.missingScope }
            guard let modelTime = result.phases["rfLayoutModel"], modelTime == 0 else { throw Failure.RFUnavailable }
            return result
        }
    }

    static func load(image: CGImage, configuration: ReaderOCRConfiguration) throws -> Result {
        guard let context = current else { throw Failure.missingScope }
        guard configuration == context.expectedReaderConfiguration else { throw Failure.configuration }
        let started = ProcessInfo.processInfo.systemUptime
        let page = context.page
        guard image.width == page.contract.width, image.height == page.contract.height,
              try HostRenderProvenance.fileSHA256(page.originalSourceURL) == page.contract.sourceEncodedSHA256,
              try NativeRFDETRSourceImage.decode(image).identity == page.contract.sourceImageIdentity else { throw Failure.source }
        guard page.observedDecodes.allSatisfy({
            $0.request.callerConfidenceThreshold.bitPattern == configuration.confidenceThreshold.bitPattern
        }) else { throw Failure.configuration }
        let verified = ProcessInfo.processInfo.systemUptime
        let lines: [NativeCoreMLOCRLine]
        let geometry: [NativeOCRIndividualGeometryHypotheses.Individual]
        let selectedBoxes: Int
        let originalOrdinals: [Int]
        let changed: ChangedCore?
        if let replay = context.changedCoreReplay {
            let value = try replay(); changed = value
            lines = value.lines; geometry = value.geometry; selectedBoxes = value.selectedBoxes; originalOrdinals = []
        } else {
            let result = try page.replay(preRecognition: context.preRecognition,
                recognitionAdmission: context.recognitionAdmission, deduplication: context.deduplication)
            changed = nil; lines = result.lines; geometry = result.geometry.individuals
            selectedBoxes = result.scheduledSource165Indices.count; originalOrdinals = result.originalPacketOrdinals
        }
        context.invocation.record()
        let finished = ProcessInfo.processInfo.systemUptime
        var output = Result(width: page.contract.width, height: page.contract.height, lines: lines,
            individualGeometry: geometry, selectedBoxes: selectedBoxes,
            detectedBoxes: page.originalDetectors.count,
            totalMilliseconds: (finished - started) * 1000,
            sourceVerificationMilliseconds: (verified - started) * 1000,
            consumerReplayMilliseconds: (finished - verified) * 1000,
            sourceEncodedSHA256: page.contract.sourceEncodedSHA256,
            originalProducerSHA256: page.contract.producerSHA256!, originalPacketOrdinals: originalOrdinals)
        if let changed {
            output.packetOrdinalDomain = "new-actual-rec-after-optional-gate-before-nms"
            output.tableScheduledSourceIndices = changed.tableScheduledSourceIndices
            output.recognitionBankReceipt = changed.receipt
        }
        observer?(output)
        return output
    }
}
