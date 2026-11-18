import CoreGraphics
import Foundation

/// Source-content-addressed handoff from OCR to the production renderer.
/// Retains only three RF results; image names and runtime labels are never keys.
final class NativeMainEnsembleEvidenceStore: @unchecked Sendable {
    typealias Evidence = (regions: [Ensemble100RFRegion], probability: NativeMainAOTRemovalMaskBuilder.SourceProbability?)
    static let shared = NativeMainEnsembleEvidenceStore()
    private let lock = NSLock()
    private var results: [String: NativeRFDETRLayoutResult] = [:]
    private var order: [String] = []
    private var suppliedRegions: [String: [Ensemble100RFRegion]] = [:]
    // Readers bind the immutable grid to their own verified source. Keeping the
    // producer's decoded image here would pin it across the provider wait and
    // until LRU eviction, even after the reader releases the source page.
    private struct StoredProbability {
        let width: Int
        let height: Int
        let values: [Float]
        let capability: NativeMainEnsembleDBCapability.Record?

        init(_ probability: NativeMainAOTRemovalMaskBuilder.SourceProbability) {
            width = probability.width
            height = probability.height
            values = probability.values
            capability = probability.capability
        }

        func bound(to original: CGImage) -> NativeMainAOTRemovalMaskBuilder.SourceProbability {
            .init(original: original, width: width, height: height, values: values, capability: capability)
        }
    }
    private var probabilities: [String: StoredProbability] = [:]
    // Semantically keyed by source AND actual producer; legacy storage is separate.
    private var currentProbabilities: [NativeMainEnsembleDBCapability.Key: StoredProbability] = [:]
    private var sourceRevisions: [String: Data] = [:]
    private var unownedInk: [String: [NativeCausalUnownedInkLiveRecovery.AffiliatedMask]] = [:]
    private var pins = NativeMainEnsembleEvidenceLease.Registry()

    /// One canonical decode; pin the child first without holding this lock.
    /// Never hold parent and child locks together, including release/failure.
    func lease(original: CGImage) throws -> NativeMainEnsembleEvidenceLease {
        try lease(source: NativeMainEnsemblePreparedDB.SourceBinding(original: original))
    }

    func lease(source: NativeMainEnsemblePreparedDB.SourceBinding) throws -> NativeMainEnsembleEvidenceLease {
        try Task.checkCancellation()
        let identity = source.identity
        let ocrLease = try ocrStore.lease(contentIdentity: identity)
        let token: NativeMainEnsembleEvidenceLease.Registry.Token
        do {
            lock.lock(); defer { lock.unlock() }
            token = try pins.acquire(identity: identity)
        } catch {
            ocrLease.release()
            throw error
        }
        return NativeMainEnsembleEvidenceLease { [self] in
            lock.lock()
            pins.release(token)
            trim()
            lock.unlock()
            ocrLease.release()
        }
    }

    func register(unownedMasks: [NativeCausalUnownedInkLiveRecovery.AffiliatedMask], original: CGImage) throws {
        guard unownedMasks.count <= 4, unownedMasks.reduce(0, { $0 + $1.runs.count }) <= 131072 else {
            throw NativeMainEnsembleOCREvidence.Failure.budget
        }
        if unownedMasks.isEmpty {
            lock.lock()
            let noStoredMasks = unownedInk.isEmpty
            lock.unlock()
            if noStoredMasks { return } // OFF/absent: no image decode/hash.
        }
        let identity = try NativeRFDETRSourceImage.decode(original).identity
        lock.lock(); defer { lock.unlock() }
        if unownedMasks.isEmpty {
            // Clear-on-absent remains source-bound if any ledger is populated.
            unownedInk.removeValue(forKey: identity)
            return
        }
        unownedInk[identity] = unownedMasks
        updateRecency(for: identity)
    }

    func unownedMasks(original: CGImage) throws -> [NativeCausalUnownedInkLiveRecovery.AffiliatedMask] {
        lock.lock()
        let noStoredMasks = unownedInk.isEmpty
        lock.unlock()
        guard !noStoredMasks else { return [] } // No full-source decode on empty.
        let identity = try NativeRFDETRSourceImage.decode(original).identity
        lock.lock(); defer { lock.unlock() }
        return unownedInk[identity] ?? []
    }
    private let ocrStore = NativeMainEnsembleOCREvidence.Store()

    func register(ocr: NativeMainEnsembleOCREvidence.Packet, original: CGImage, source: NativeMainEnsemblePreparedDB.SourceBinding? = nil) throws {
        try ocrStore.register(ocr, original: original, source: source)
    }

    func ocr(original: CGImage) throws -> NativeMainEnsembleOCREvidence.Packet? {
        try ocrStore.read(original: original)
    }

    func ocr(source: NativeMainEnsemblePreparedDB.SourceBinding) -> NativeMainEnsembleOCREvidence.Packet? {
        ocrStore.read(contentIdentity: source.identity)
    }

    /// Verified source revisions retain original removal owners separately from
    /// newly translated display owners. No paths, labels or page IDs are keys.
    func register(sourceRevision: Data?, original: CGImage) throws {
        if let sourceRevision, sourceRevision.count > 2 * 1024 * 1024 {
            throw NativeMainEnsembleOCREvidence.Failure.budget
        }
        let identity = try NativeRFDETRSourceImage.decode(original).identity
        lock.lock(); defer { lock.unlock() }
        sourceRevisions[identity] = sourceRevision
        updateRecency(for: identity)
    }

    func sourceRevision(original: CGImage) throws -> Data? {
        try sourceRevision(contentIdentity: NativeRFDETRSourceImage.decode(original).identity)
    }

    func sourceRevision(source: NativeMainEnsemblePreparedDB.SourceBinding) -> Data? {
        sourceRevision(contentIdentity: source.identity)
    }

    private func sourceRevision(contentIdentity: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return sourceRevisions[contentIdentity]
    }

    func register(probability: NativeMainAOTRemovalMaskBuilder.SourceProbability) throws {
        let identity = try NativeRFDETRSourceImage.decode(probability.original).identity
        try register(probability: probability, identity: identity)
    }

    func register(probability: NativeMainAOTRemovalMaskBuilder.SourceProbability, source: NativeMainEnsemblePreparedDB.SourceBinding) throws {
        guard source.original === probability.original else { throw NativeMainAOTRemovalMaskBuilder.Failure.staleOrInvalidProbability }
        try register(probability: probability, identity: source.identity)
    }

    private func register(probability: NativeMainAOTRemovalMaskBuilder.SourceProbability, identity: String) throws {
        var verifiedKey:NativeMainEnsembleDBCapability.Key?
        // No image decode, full-map hashing or cancellation work under store lock.
        if let capability=probability.capability {
            guard let producer=capability.producer,capability.source.canonicalIdentity==identity,
                  capability.grid.sourceWidth==probability.original.width,
                  capability.grid.sourceHeight==probability.original.height,
                  capability.grid.width==probability.width,capability.grid.height==probability.height,
                  capability.mapSHA256==NativeMainEnsembleDBCapability.digest(probability.values) else {
                throw NativeMainAOTRemovalMaskBuilder.Failure.staleOrInvalidProbability
            }
            let key=NativeMainEnsembleDBCapability.Key(source:capability.source,producer:producer)
            try NativeMainEnsembleDBCapability.validate(capability,expected:key)
            verifiedKey=key
        }
        let stored = StoredProbability(probability)
        lock.lock(); defer { lock.unlock() }
        if let key=verifiedKey {
            // At most one producer snapshot per resident source: no config-count leak.
            for old in Array(currentProbabilities.keys) where old.source.canonicalIdentity==identity {
                currentProbabilities.removeValue(forKey:old)
            }
            currentProbabilities[key]=stored
        }
        probabilities[identity] = stored
        updateRecency(for: identity)
    }

    /// Strict-current lookup. Source-only legacy evidence does not satisfy this API.
    func currentProbability(original:CGImage,expected:NativeMainEnsembleDBCapability.Key) throws
        -> NativeMainAOTRemovalMaskBuilder.SourceProbability? {
        let source = try NativeMainEnsemblePreparedDB.SourceBinding(original: original)
        guard let probability = try residentProbability(source: source, expected: expected),
              let record = probability.capability else { return nil }
        try NativeMainEnsembleDBCapability.validate(record, expected: expected)
        return probability
    }

    func currentPreparedProbability(source: NativeMainEnsemblePreparedDB.SourceBinding,
                                    expected: NativeMainEnsembleDBCapability.Key, lease: NativeMainEnsembleEvidenceLease,
                                    consumerConfigurationSHA256: String?) throws -> NativeMainEnsemblePreparedDB? {
        guard let probability = try residentProbability(source: source, expected: expected) else { return nil }
        return try NativeMainEnsemblePreparedDB(probability: probability, source: source, expected: expected, detectorCalls: 0,
                                               lease: lease, currentConsumerConfigurationSHA256: consumerConfigurationSHA256)
    }

    private func residentProbability(source: NativeMainEnsemblePreparedDB.SourceBinding,
                                     expected: NativeMainEnsembleDBCapability.Key) throws -> NativeMainAOTRemovalMaskBuilder.SourceProbability? {
        try Task.checkCancellation()
        guard source.identity == expected.source.canonicalIdentity else { throw NativeMainEnsembleDBCapability.Failure.sourceMismatch }
        lock.lock()
        let stored = currentProbabilities[expected]
        lock.unlock()
        return stored?.bound(to: source.original)
    }

    /// Called with the store lock held, after registering source-bound evidence.
    private func updateRecency(for identity: String) {
        order.removeAll { $0 == identity }
        order.append(identity)
        trim()
    }

    private func trim() {
        while order.count > 3 {
            guard let index = pins.evictionIndex(in: order) else { break }
            let old = order.remove(at: index)
            results.removeValue(forKey: old)
            suppliedRegions.removeValue(forKey: old)
            probabilities.removeValue(forKey: old)
            for key in Array(currentProbabilities.keys) where key.source.canonicalIdentity==old {
                currentProbabilities.removeValue(forKey:key)
            }
            sourceRevisions.removeValue(forKey: old)
            unownedInk.removeValue(forKey: old)
        }
    }

    /// A host/offline caller must verify source provenance before supplying cached predictions.
    func register(regions: [Ensemble100RFRegion], original: CGImage) throws {
        let identity = try NativeRFDETRSourceImage.decode(original).identity
        lock.lock(); defer { lock.unlock() }
        suppliedRegions[identity] = regions
        updateRecency(for: identity)
    }

    func register(rf: NativeRFDETRLayoutResult) {
        lock.lock(); defer { lock.unlock() }
        results[rf.imageIdentity] = rf
        updateRecency(for: rf.imageIdentity)
    }

    func regions(original: CGImage) throws -> [Ensemble100RFRegion] {
        try evidence(original: original).regions
    }

    func makeSimplePlacement(original: CGImage, items: [[String: Any]], viewport: CGSize) throws -> NativeSimpleRFBalloonPlacement? {
        guard let configuration = try NativeSimpleRFBalloonCoreDomain.Configuration.configured() else { return nil }
        let identity = try NativeRFDETRSourceImage.decode(original).identity
        lock.lock()
        let raw = results[identity]
        lock.unlock()
        guard let raw else { throw NativeSimpleRFBalloonPlacement.Failure.unavailableDomain }
        return try NativeSimpleRFBalloonPlacement(original: original, rawRF: raw,
            items: items, viewport: viewport, configuration: configuration)
    }

    func evidence(original: CGImage) throws -> Evidence {
        try evidence(original: original, contentIdentity: NativeRFDETRSourceImage.decode(original).identity)
    }

    func evidence(source: NativeMainEnsemblePreparedDB.SourceBinding) throws -> Evidence {
        try evidence(original: source.original, contentIdentity: source.identity)
    }

    private func evidence(original: CGImage, contentIdentity identity: String) throws -> Evidence {
        lock.lock()
        let result = results[identity]
        let supplied = suppliedRegions[identity]
        let storedProbability = probabilities[identity]
        lock.unlock()
        let probability = storedProbability?.bound(to: original)
        if let supplied { return (supplied, probability) }
        guard let result else { return ([], probability) }
        return (try NativeMainRFRegionAdapter.regions(from: result), probability)
    }
}
