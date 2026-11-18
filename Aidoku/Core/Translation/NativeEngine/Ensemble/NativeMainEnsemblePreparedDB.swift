import CoreGraphics
import Foundation

/// Invocation-local immutable source/producer/grid plus RAM evidence pin.
/// No registry. Snapshot/worker/prepared page retain it through cold composition.
/// As with source-image caches, the caller must not mutate CGDataProvider backing
/// memory externally after admission; normal decoded ImageIO/UIImage pages are immutable.
final class NativeMainEnsemblePreparedDB: @unchecked Sendable {
    enum Failure: Error {case requiredDBUnavailable,expectedConfigurationUnavailable,differentOriginal,observerUnavailable,invalidCarrier}
    let probability: NativeMainAOTRemovalMaskBuilder.SourceProbability
    let expected: NativeMainEnsembleDBCapability.Key
    let detectorCalls: Int
    let currentConsumerConfigurationSHA256: String?
    let sourceBinding: SourceBinding
    private let lease: NativeMainEnsembleEvidenceLease
    /// Created only from the actual full-resolution pixels. The short-lived
    /// binding keeps the original object and digest, not a second RGB raster.
    struct SourceBinding: Sendable {
        let original: CGImage
        let verifiedIdentity: NativeRFOCRSourceReuse.VerifiedIdentity
        var identity: String { verifiedIdentity.digest }

        init(original: CGImage) throws {
            try Task.checkCancellation()
            try self.init(ocrEvidenceOriginal: original)
            try Task.checkCancellation()
        }

        /// Capture only a digest already prepared by RF for this exact image.
        init?(preparedOCROriginal original: CGImage) {
            guard let verified = NativeRFOCRSourceReuse.active?.verifiedIdentity(for: original) else { return nil }
            self.original = original
            self.verifiedIdentity = verified
        }

        /// Live OCR checks cancellation at its existing Reader phase boundaries.
        init(ocrEvidenceOriginal original: CGImage) throws {
            verifiedIdentity = try NativeRFOCRSourceReuse.active?.verifiedIdentity(for: original)
                ?? NativeRFOCRSourceReuse.VerifiedIdentity(original: original)
            self.original = original
        }
    }

    convenience init(probability: NativeMainAOTRemovalMaskBuilder.SourceProbability,
                     expected: NativeMainEnsembleDBCapability.Key, detectorCalls: Int,
                     lease: NativeMainEnsembleEvidenceLease, currentConsumerConfigurationSHA256: String? = nil) throws {
        try Task.checkCancellation()
        guard probability.capability != nil else { throw Failure.requiredDBUnavailable }
        guard probability.original.width == expected.source.width, probability.original.height == expected.source.height else {
            throw NativeMainEnsembleDBCapability.Failure.sourceMismatch
        }
        try self.init(probability: probability, source: SourceBinding(original: probability.original), expected: expected,
                      detectorCalls: detectorCalls, lease: lease, currentConsumerConfigurationSHA256: currentConsumerConfigurationSHA256)
    }

    init(probability: NativeMainAOTRemovalMaskBuilder.SourceProbability, source: SourceBinding,
         expected: NativeMainEnsembleDBCapability.Key, detectorCalls: Int,
         lease: NativeMainEnsembleEvidenceLease, currentConsumerConfigurationSHA256: String? = nil) throws {
        try Task.checkCancellation()
        guard let record = probability.capability else { throw Failure.requiredDBUnavailable }
        guard probability.original === source.original else { throw Failure.differentOriginal }
        guard source.original.width == expected.source.width, source.original.height == expected.source.height,
              source.identity == expected.source.canonicalIdentity else {
            throw NativeMainEnsembleDBCapability.Failure.sourceMismatch
        }
        try NativeMainEnsembleDBCapability.validate(record, expected: expected)
        // The grid's exact digest and finite values have just been validated.
        // Independently supplied carriers must match even the sign bit of zero.
        guard probability.width == record.grid.width, probability.height == record.grid.height,
              probability.values.count == record.grid.values.count,
              probability.values.withUnsafeBytes({ carrier in
                  record.grid.values.withUnsafeBytes { grid in
                      carrier.baseAddress == grid.baseAddress || memcmp(carrier.baseAddress!, grid.baseAddress!, grid.count) == 0
                  }
              }) else { throw Failure.invalidCarrier }
        try Task.checkCancellation()
        self.sourceBinding = source
        self.probability = probability
        self.expected = expected
        self.detectorCalls = detectorCalls
        self.lease = lease
        self.currentConsumerConfigurationSHA256 = currentConsumerConfigurationSHA256
    }

    func validate(original:CGImage) throws {
        try Task.checkCancellation()
        guard probability.original === original else {throw Failure.differentOriginal}
        // The constructor seals every source/grid/producer/carrier check. All
        // retained fields are immutable values; don't rehash full maps per facade.
    }
    deinit {lease.release()}
}

/// One detector callback capture, never a global observer or fabricated empty map.
final class NativeMainEnsembleDBCapture: @unchecked Sendable {
    struct RejectedSample: Error {
        let status: NativeMainEnsembleOCRProbability.Status
        let detail: String?
    }
    private let lock=NSLock()
    private var values=[NativeMainAOTRemovalMaskBuilder.SourceProbability]()
    private var rejection: RejectedSample?
    func record(_ report: NativeMainEnsembleOCRProbability.Report) {
        guard !report.registered else { return }
        lock.lock(); defer { lock.unlock() }
        rejection = RejectedSample(status: report.status, detail: report.detail)
    }
    func store(_ value:NativeMainAOTRemovalMaskBuilder.SourceProbability) throws {
        lock.lock();defer {lock.unlock()}
        guard values.isEmpty else {throw NativeMainEnsemblePreparedDB.Failure.observerUnavailable}
        values.append(value)
    }
    func take() throws -> NativeMainAOTRemovalMaskBuilder.SourceProbability {
        lock.lock();defer {lock.unlock()}
        if let rejection { throw rejection }
        guard values.count==1,let result=values.first,result.capability != nil else {
            throw NativeMainEnsemblePreparedDB.Failure.observerUnavailable
        }
        return result
    }
}
