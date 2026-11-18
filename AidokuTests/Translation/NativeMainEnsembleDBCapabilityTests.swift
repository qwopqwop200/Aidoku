import CoreGraphics
import Foundation
import UIKit
import Testing
@testable import Aidoku

/// Fixed synthetic contracts exercise admission only. No model resources,
/// shared stores, HTTP, corpus paths, test bypasses or producer attestation.
@Suite struct NativeMainEnsembleDBCapabilityTests {
    private typealias Capability = NativeMainEnsembleDBCapability
    private typealias Probability = NativeMainAOTRemovalMaskBuilder.SourceProbability

    private actor CallProbe {
        private var calls = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func invoked() {
            calls += 1
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
        func count() -> Int { calls }
        func waitForCall() async {
            if calls > 0 { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    @available(iOS 18.0, *)
    private func image(gray: CGFloat = 0.5, side: Int = 64) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(context.makeImage())
    }

    @available(iOS 18.0, *)
    private func producer(package: String = String(repeating: "c", count: 64),
                          configuration: String = String(repeating: "d", count: 64),
                          abi: String = "synthetic-input-abi-v1", units: String = "syntheticCPU",
                          maximum: Int = 64) -> Capability.Producer {
        .init(modelResource: "synthetic-contract-no-model-file", modelPackageSHA256: package,
            backend: "synthetic", computeUnits: units, preprocessABI: abi,
            preprocessSHA256: String(repeating: "e", count: 64), effectiveConfigurationSHA256: configuration,
            maximumSide: maximum, canvasWidth: 64, canvasHeight: 64, resizedWidth: 32, resizedHeight: 32)
    }

    @available(iOS 18.0, *)
    private func key(source: CGImage? = nil, width: Int = 64, height: Int = 64) throws -> Capability.Key {
        let identity = try source.map { try NativeRFDETRSourceImage.decode($0).identity }
            ?? String(repeating: "a", count: 64)
        return .init(source: .init(canonicalIdentity: identity, detectorInputIdentity: String(repeating: "b", count: 64),
            width: width, height: height), producer: producer())
    }

    @available(iOS 18.0, *)
    private func grid(expected: Capability.Key, width: Int = 32, height: Int = 32,
                      regionX: Int = 0, regionWidth: Int = 32, values: [Float]? = nil) -> Capability.Grid {
        .init(sourceWidth: expected.source.width, sourceHeight: expected.source.height,
            resizedWidth: 32, resizedHeight: 32, regionX: regionX, regionY: 0, regionWidth: regionWidth,
            regionHeight: 32, width: width, height: height,
            values: values ?? [Float](repeating: 0.25, count: width * height))
    }

    @available(iOS 18.0, *)
    private func record(expected: Capability.Key, source: Capability.Source? = nil,
                        observedProducer: Capability.Producer? = nil, proven: Bool = true,
                        grid: Capability.Grid? = nil, origin: Capability.Origin = .live,
                        digest: String? = nil) -> Capability.Record {
        let actualGrid = grid ?? self.grid(expected: expected)
        return .init(source: source ?? expected.source, producer: proven ? observedProducer ?? expected.producer : nil,
            grid: actualGrid, mapSHA256: digest ?? Capability.digest(actualGrid.values), origin: origin)
    }

    @available(iOS 18.0, *)
    private func prepared(source: CGImage, expected: Capability.Key,
                          record: Capability.Record, values: [Float]? = nil,
                          width: Int = 32, height: Int = 32) throws -> NativeMainEnsemblePreparedDB {
        try NativeMainEnsemblePreparedDB(probability: Probability(original: source, width: width, height: height,
            values: values ?? record.grid.values, capability: record), expected: expected, detectorCalls: 0,
            lease: NativeMainEnsembleEvidenceLease(release: {}))
    }

    @available(iOS 18.0, *)
    @Test func preparedJPEGMatchesBoundPixelsAndFallsBackForAnotherOriginal() throws {
        let evidence = ReaderTranslationPreparedEvidence(store: NativeMainEnsembleEvidenceStore())
        let original = try image(gray: 0.2), other = try image(gray: 0.7)
        try evidence.bind(original: original)
        let observed = try NativeRFDETRSourceImage.decode(original).identity
        if NativeMainEnsembleRenderer.enabled {
            #expect(evidence.sourceIdentity(for: original) == observed)
        }
        #expect(evidence.sourceIdentity(for: other) == nil)
        let upright = UIImage(cgImage: original)
        let cached = try ReaderTranslationImagePreparation.preparedPage(upright, evidence: evidence)
        let fresh = try ReaderTranslationImagePreparation.preparedPage(upright)
        #expect(cached.jpeg == fresh.jpeg && cached.sourceIdentity == observed)
        let foreign = try ReaderTranslationImagePreparation.preparedPage(UIImage(cgImage: other), evidence: evidence)
        let foreignIdentity = try NativeRFDETRSourceImage.decode(other).identity
        #expect(foreign.sourceIdentity == foreignIdentity && foreignIdentity != observed)
        let rotated = UIImage(cgImage: original, scale: 1, orientation: .left)
        #expect(try ReaderTranslationImagePreparation.preparedPage(rotated, evidence: evidence).sourceIdentity == nil)
    }

    @available(iOS 18.0, *)
    @Test func preparedEvidencePinsGridWithoutAllowingRebindAfterSourceRelease() throws {
        let store = NativeMainEnsembleEvidenceStore()
        let evidence = ReaderTranslationPreparedEvidence { try store.lease(original: $0) }
        let consumer = try image()
        weak var producerImage: CGImage?
        try autoreleasepool {
            let source = try image()
            producerImage = source
            try evidence.bind(original: source)
            try evidence.bind(original: source)
            try store.register(probability: .init(original: source, width: 1, height: 1, values: [0.5]))
            #expect(throws: ReaderTranslationPreparedEvidence.Failure.self) {
                try evidence.bind(original: consumer)
            }
        }
        #expect(producerImage == nil)
        #expect(throws: ReaderTranslationPreparedEvidence.Failure.self) {
            try evidence.bind(original: consumer)
        }
        for gray: CGFloat in [0, 0.1, 0.2, 0.3] {
            try store.register(probability: .init(original: image(gray: gray), width: 1, height: 1, values: [0]))
        }
        try withExtendedLifetime(evidence) {
            let result = try store.evidence(original: consumer)
            let pinned = try #require(result.probability)
            #expect(pinned.original === consumer)
            #expect(pinned.values == [0.5])
        }
    }

    @available(iOS 18.0, *)
    @Test func renderStoreReadsCurrentEvidenceWithThePreparedOriginal() throws {
        let store = NativeMainEnsembleEvidenceStore()
        let original = try image(), equal = try image(), different = try image(gray: 0)
        let expected = try key(source: original)
        let db = try prepared(source: original, expected: expected, record: record(expected: expected))
        try db.validate(original: original)
        let binding = db.sourceBinding
        let equalBinding = try NativeMainEnsemblePreparedDB.SourceBinding(original: equal)
        let differentBinding = try NativeMainEnsemblePreparedDB.SourceBinding(original: different)
        #expect(binding.original === original && binding.identity == expected.source.canonicalIdentity)
        #expect(throws: NativeMainEnsemblePreparedDB.Failure.self) { try db.validate(original: equal) }
        #expect(store.ocr(source: binding) == nil && store.sourceRevision(source: binding) == nil)
        #expect(try store.evidence(source: binding).regions.isEmpty)

        let packetBinding = try NativeMainEnsembleOCREvidence.liveBinding(original: original)
        let packet = try NativeMainEnsembleOCREvidence.Packet(binding: packetBinding, stages: [])
        try store.register(ocr: packet, original: original)
        try store.register(probability: .init(original: original, width: 1, height: 1, values: [-0.0]))
        for revision in [Data([1]), Data([2]), nil] {
            try store.register(sourceRevision: revision, original: original)
            #expect(store.sourceRevision(source: binding) == revision)
            #expect(try store.sourceRevision(original: equal) == revision)
            #expect(store.sourceRevision(source: equalBinding) == revision)
            #expect(store.sourceRevision(source: differentBinding) == nil)
        }
        #expect(store.ocr(source: equalBinding)?.binding.candidateIdentity == packetBinding.candidateIdentity)
        #expect(store.ocr(source: differentBinding) == nil)
        #expect(NativeMainEnsembleOCREvidence.Binding.candidateIdentity(for: binding.identity) == packetBinding.candidateIdentity)
        let rebound = try #require(store.evidence(source: equalBinding).probability)
        #expect(rebound.original === equal && rebound.values.first?.bitPattern == Float(-0.0).bitPattern)
        #expect(try store.evidence(source: differentBinding).probability == nil)
    }

    @available(iOS 18.0, *)
    @Test func storedProbabilityReleasesProducerImageAndRebindsBothLookups() throws {
        let store = NativeMainEnsembleEvidenceStore()
        let consumer = try image()
        let expected = try key(source: consumer)
        let capability = record(expected: expected)
        weak var producerImage: CGImage?
        try autoreleasepool {
            let producer = try image()
            #expect(producer !== consumer)
            producerImage = producer
            try store.register(probability: .init(original: producer, width: capability.grid.width,
                height: capability.grid.height, values: capability.grid.values, capability: capability))
        }
        #expect(producerImage == nil)
        let stored = try store.currentProbability(original: consumer, expected: expected)
        let evidence = try store.evidence(original: consumer)
        let current = try #require(stored)
        let legacy = try #require(evidence.probability)
        for result in [current, legacy] {
            #expect(result.original === consumer)
            #expect(result.values == capability.grid.values)
            #expect(result.capability?.mapSHA256 == capability.mapSHA256)
        }
        let foreign = try image(gray: 0)
        let unrelated = try store.evidence(original: foreign)
        #expect(unrelated.probability == nil)
    }

    @available(iOS 18.0, *)
    @Test func fullPageProbabilityCapturesOnlyThePreparedRFOriginal() throws {
        let original = try image(), equal = try image(), other = try image(gray: 0.1)
        let scope = NativeRFOCRSourceReuse(original: original)
        let expected = try key(source: original)
        let otherExpected = try key(source: other)
        let sample = NativeMainEnsembleOCRProbability.Sample(sourceWidth: 64, sourceHeight: 64,
            resizedWidth: 32, resizedHeight: 32, region: CGRect(x: 0, y: 0, width: 32, height: 32),
            width: 32, height: 32, values: grid(expected: expected).values, producer: expected.producer,
            detectorInputIdentity: expected.source.detectorInputIdentity)
        let store = NativeMainEnsembleEvidenceStore()
        let callbacks = try NativeRFOCRSourceReuse.$active.withValue(scope) {
            #expect(NativeMainEnsemblePreparedDB.SourceBinding(preparedOCROriginal: original) == nil)
            _ = try scope.source(for: original, consume: true)
            let prepared = try #require(NativeMainEnsemblePreparedDB.SourceBinding(preparedOCROriginal: original))
            #expect(prepared.original === original && prepared.identity == expected.source.canonicalIdentity)
            #expect(NativeMainEnsemblePreparedDB.SourceBinding(preparedOCROriginal: equal) == nil)
            return [original, other].map { NativeMainEnsembleOCRProbability.fullPageObserver(original: $0, store: store) }
        }
        scope.close()
        for (index, callback) in callbacks.enumerated() {
            #expect(callback(sample).currentProducerVerified)
            let image = index == 0 ? original : other
            let key = index == 0 ? expected : otherExpected
            let cached = try store.currentProbability(original: image, expected: key)
            let probability = try #require(cached)
            #expect(probability.original === image && probability.capability?.source == key.source)
            #expect(probability.values.map(\.bitPattern) == sample.values.map(\.bitPattern))
        }
    }

    @available(iOS 18.0, *)
    @Test func coldProbabilityAdmissionRequiresTheSameBoundOriginal() throws {
        let original = try image(), duplicate = try image()
        let bound = try NativeMainEnsemblePreparedDB.SourceBinding(original: original)
        let other = try NativeMainEnsemblePreparedDB.SourceBinding(original: duplicate)
        #expect(bound.identity == other.identity && original !== duplicate)
        let expected = try key(source: original)
        let cells = grid(expected: expected)
        let capture = NativeMainEnsembleDBCapture()
        let observe = NativeMainEnsembleOCRProbability.observer(source: bound, register: { try capture.store($0) })
        let sample = NativeMainEnsembleOCRProbability.Sample(sourceWidth: 64, sourceHeight: 64, resizedWidth: 32,
            resizedHeight: 32, region: CGRect(x: 0, y: 0, width: 32, height: 32), width: 32, height: 32,
            values: cells.values, producer: expected.producer, detectorInputIdentity: expected.source.detectorInputIdentity)
        let status = observe(sample)
        #expect(status.currentProducerVerified)
        let probability = try capture.take()
        #expect(probability.original === original && probability.capability?.source == expected.source)
        let store = NativeMainEnsembleEvidenceStore()
        #expect(throws: NativeMainAOTRemovalMaskBuilder.Failure.self) {
            try store.register(probability: probability, source: other)
        }
        #expect(try store.currentProbability(original: original, expected: expected) == nil)
        try store.register(probability: probability, source: bound)
        let retained = try #require(try store.currentProbability(original: original, expected: expected))
        #expect(retained.original === original && retained.values == cells.values)
    }

    @available(iOS 18.0, *)
    @Test func residentAdmissionBindsCurrentPixelsProducerAndCancellation() async throws {
        let store = NativeMainEnsembleEvidenceStore()
        let original = try image(), equal = try image(), changed = try image(gray: 0)
        let expected = try key(source: original), observed = record(expected: expected)
        let probability = Probability(original: original, width: 32, height: 32, values: observed.grid.values, capability: observed)
        try store.register(probability: probability)
        let binding = try NativeMainEnsemblePreparedDB.SourceBinding(original: equal)
        let lease = try store.lease(source: binding)
        let stored = try store.currentPreparedProbability(source: binding, expected: expected, lease: lease,
                                                                      consumerConfigurationSHA256: "current")
        let admitted = try #require(stored)
        #expect(admitted.probability.original === equal)
        #expect(admitted.detectorCalls == 0 && admitted.currentConsumerConfigurationSHA256 == "current")
        #expect(admitted.probability.capability?.mapSHA256 == observed.mapSHA256)
        let foreign = try NativeMainEnsemblePreparedDB.SourceBinding(original: changed)
        #expect(throws: Capability.Failure.self) {
            _ = try store.currentPreparedProbability(source: foreign, expected: expected, lease: lease, consumerConfigurationSHA256: nil)
        }
        #expect(throws: NativeMainEnsemblePreparedDB.Failure.self) {
            _ = try NativeMainEnsemblePreparedDB(probability: probability, source: binding, expected: expected, detectorCalls: 0, lease: lease)
        }
        let otherModel = Capability.Key(source: expected.source, producer: producer(maximum: 96))
        #expect(try store.currentPreparedProbability(source: binding, expected: otherModel, lease: lease, consumerConfigurationSHA256: nil) == nil)
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return try store.currentPreparedProbability(source: binding, expected: expected, lease: lease, consumerConfigurationSHA256: nil)
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    }

    @available(iOS 18.0, *)
    @Test func digestPreservesCanonicalFloatBitsAndConsumerAuditIsNotProducerIdentity() throws {
        #expect(Capability.digest([0, 0.25, 0.5, 1]) ==
            "853c546e8e6312a0ab23b67267d5ba1a34b3120a2f472181f6e6d00786aa3a69")
        #expect(Capability.digest([Float(0)]) != Capability.digest([Float(bitPattern: 0x80000000)]))
        let expected = try key()
        var actual = record(expected: expected)
        actual.consumerConfigurationSHA256 = String(repeating: "f", count: 64)
        try Capability.validate(actual, expected: expected)
    }

    @available(iOS 18.0, *)
    @Test func rejectsDifferentSourceAndFixedProducerContracts() throws {
        let expected = try key()
        for source in [
            Capability.Source(canonicalIdentity: String(repeating: "f", count: 64),
                detectorInputIdentity: expected.source.detectorInputIdentity, width: 64, height: 64),
            Capability.Source(canonicalIdentity: expected.source.canonicalIdentity,
                detectorInputIdentity: String(repeating: "f", count: 64), width: 64, height: 64)
        ] {
            #expect(throws: Capability.Failure.self) {
                try Capability.validate(record(expected: expected, source: source), expected: expected)
            }
        }
        for changed in [producer(package: String(repeating: "f", count: 64)),
                        producer(configuration: String(repeating: "f", count: 64)),
                        producer(abi: "different-preprocess"), producer(units: "differentUnits"), producer(maximum: 96)] {
            #expect(throws: Capability.Failure.self) {
                try Capability.validate(record(expected: expected, observedProducer: changed), expected: expected)
            }
        }
        #expect(throws: Capability.Failure.self) {
            try Capability.validate(record(expected: expected, proven: false), expected: expected)
        }
        #expect(throws: Capability.Failure.self) {
            try Capability.validate(record(expected: expected, origin: .legacyUnproven), expected: expected)
        }
    }

    @available(iOS 18.0, *)
    @Test func rejectsPartialPaddedUpsizedMalformedAndChangedProbabilityMaps() throws {
        let expected = try key()
        for malformed in [grid(expected: expected, regionX: 1), grid(expected: expected, regionWidth: 31),
                          grid(expected: expected, width: 64), grid(expected: expected, values: [0.25])] {
            #expect(throws: Capability.Failure.self) {
                try Capability.validate(record(expected: expected, grid: malformed), expected: expected)
            }
        }
        for value: Float in [.nan, .infinity, -.infinity, -0.1, 1.1] {
            var values = [Float](repeating: 0.25, count: 1024)
            values[7] = value
            #expect(throws: Capability.Failure.self) {
                try Capability.validate(record(expected: expected, grid: grid(expected: expected, values: values)),
                    expected: expected)
            }
        }
        #expect(throws: Capability.Failure.self) {
            try Capability.validate(record(expected: expected, digest: String(repeating: "0", count: 64)), expected: expected)
        }
        let smallSource = try key(width: 16, height: 16)
        #expect(throws: Capability.Failure.self) {
            try Capability.validate(record(expected: smallSource), expected: smallSource)
        }
    }

    @available(iOS 18.0, *)
    @Test func currentResidentAndAuthenticatedReplayNeverCallDetectorFallback() async throws {
        let expected = try key(), current = record(expected: expected)
        let replay = record(expected: expected, origin: .authenticatedReplay)
        let fresh = record(expected: expected, origin: .freshCurrentDetector)
        let probe = CallProbe()
        let resident = try await Capability.resolve(expected: expected, resident: current, replay: nil,
            allowOneCurrentDetector: true, fallback: { await probe.invoked(); return fresh })
        #expect(resident.detectorCalls == 0)
        let authenticated = try await Capability.resolve(expected: expected, resident: nil, replay: replay,
            allowOneCurrentDetector: true, fallback: { await probe.invoked(); return fresh })
        #expect(authenticated.detectorCalls == 0)
        #expect(authenticated.record.origin == .authenticatedReplay)
        #expect(await probe.count() == 0)
    }

    @available(iOS 18.0, *)
    @Test func staleOrLegacyResidentAllowsExactlyOneAuthorizedCurrentFallback() async throws {
        let expected = try key(), fresh = record(expected: expected, origin: .freshCurrentDetector)
        let stale = record(expected: expected, observedProducer: producer(configuration: String(repeating: "f", count: 64)))
        let legacy = record(expected: expected, proven: false, origin: .legacyUnproven)
        for resident in [stale, legacy] {
            let probe = CallProbe()
            let result = try await Capability.resolve(expected: expected, resident: resident, replay: nil,
                allowOneCurrentDetector: true, fallback: { await probe.invoked(); return fresh })
            #expect(result.detectorCalls == 1)
            #expect(result.record.origin == .freshCurrentDetector)
            #expect(await probe.count() == 1)
        }
        let probe = CallProbe()
        await #expect(throws: Capability.Failure.self) {
            _ = try await Capability.resolve(expected: expected, resident: nil, replay: nil,
                allowOneCurrentDetector: false, fallback: { await probe.invoked(); return fresh })
        }
        #expect(await probe.count() == 0)
    }

    @available(iOS 18.0, *)
    @Test func corruptedReplayAndWrongFreshOriginDoNotRetryOrSilentlyFallBack() async throws {
        let expected = try key(), fresh = record(expected: expected, origin: .freshCurrentDetector)
        for invalid in [record(expected: expected, origin: .authenticatedReplay, digest: String(repeating: "0", count: 64)),
                        record(expected: expected, origin: .live)] {
            let probe = CallProbe()
            await #expect(throws: Capability.Failure.self) {
                _ = try await Capability.resolve(expected: expected, resident: nil, replay: invalid,
                    allowOneCurrentDetector: true, fallback: { await probe.invoked(); return fresh })
            }
            #expect(await probe.count() == 0)
        }
        let wrongFresh = record(expected: expected, origin: .live), probe = CallProbe()
        await #expect(throws: Capability.Failure.self) {
            _ = try await Capability.resolve(expected: expected, resident: nil, replay: nil,
                allowOneCurrentDetector: true, fallback: { await probe.invoked(); return wrongFresh })
        }
        #expect(await probe.count() == 1)
    }

    @available(iOS 18.0, *)
    @Test func cancellationBeforeLookupAndAfterOneFallbackPropagates() async throws {
        let expected = try key(), current = record(expected: expected)
        let fresh = record(expected: expected, origin: .freshCurrentDetector), beforeProbe = CallProbe()
        let before = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await Capability.resolve(expected: expected, resident: current, replay: nil,
                allowOneCurrentDetector: true, fallback: { await beforeProbe.invoked(); return fresh })
        }
        before.cancel()
        await #expect(throws: CancellationError.self) { _ = try await before.value }
        #expect(await beforeProbe.count() == 0)
        let duringProbe = CallProbe()
        let during = Task {
            try await Capability.resolve(expected: expected, resident: nil, replay: nil,
                allowOneCurrentDetector: true, fallback: {
                    await duringProbe.invoked()
                    while !Task.isCancelled { await Task.yield() }
                    return fresh
                })
        }
        await duringProbe.waitForCall()
        during.cancel()
        await #expect(throws: CancellationError.self) { _ = try await during.value }
        #expect(await duringProbe.count() == 1)
    }

    @available(iOS 18.0, *)
    @Test func preparedDBBindsActualCanonicalPixelsDimensionsAndOriginalObject() throws {
        let original = try image(), equalPixels = try image(), foreign = try image(gray: 0)
        let expected = try key(source: original), valid = record(expected: expected)
        let prepared = try prepared(source: original, expected: expected, record: valid)
        try prepared.validate(original: original)
        #expect(prepared.probability.original === original)
        #expect(throws: NativeMainEnsemblePreparedDB.Failure.self) { try prepared.validate(original: equalPixels) }
        #expect(throws: NativeMainEnsemblePreparedDB.Failure.self) { try prepared.validate(original: foreign) }
        #expect(throws: Capability.Failure.self) { _ = try self.prepared(source: foreign, expected: expected, record: valid) }
        let differentSize = try image(side: 32)
        #expect(throws: Capability.Failure.self) {
            _ = try self.prepared(source: differentSize, expected: expected, record: valid)
        }
        let legacy = Probability(original: original, width: 32, height: 32, values: valid.grid.values)
        #expect(throws: NativeMainEnsemblePreparedDB.Failure.self) {
            _ = try NativeMainEnsemblePreparedDB(probability: legacy, expected: expected, detectorCalls: 0,
                lease: NativeMainEnsembleEvidenceLease(release: {}))
        }
    }

    @available(iOS 18.0, *)
    @Test func preparedDBRejectsCarrierDimensionsCountAndExactBitDigestMismatch() throws {
        let original = try image(), expected = try key(source: original)
        let valid = record(expected: expected)
        #expect(throws: NativeMainEnsemblePreparedDB.Failure.self) {
            _ = try prepared(source: original, expected: expected, record: valid, width: 16)
        }
        #expect(throws: NativeMainEnsemblePreparedDB.Failure.self) {
            _ = try prepared(source: original, expected: expected, record: valid, values: [0.25])
        }
        var changed = valid.grid.values
        changed[0] = 0.5
        #expect(throws: NativeMainEnsemblePreparedDB.Failure.self) {
            _ = try prepared(source: original, expected: expected, record: valid, values: changed)
        }
        let zero = record(expected: expected, grid: grid(expected: expected, values: [Float](repeating: 0, count: 1024)))
        var differentBits = zero.grid.values
        differentBits[0] = Float(bitPattern: 0x80000000)
        #expect(throws: NativeMainEnsemblePreparedDB.Failure.self) {
            _ = try prepared(source: original, expected: expected, record: zero, values: differentBits)
        }
    }

    @available(iOS 18.0, *)
    @Test func preparedImmutableValuesStayIndependentAfterCallerMutationAndCancellation() async throws {
        let original = try image(), expected = try key(source: original)
        var values = [Float](repeating: 0.25, count: 1024)
        let valid = record(expected: expected, grid: grid(expected: expected, values: values))
        let prepared = try prepared(source: original, expected: expected, record: valid, values: values)
        values[0] = 0.75
        try prepared.validate(original: original)
        #expect(prepared.probability.values[0] == 0.25)
        #expect(prepared.probability.capability?.grid.values[0] == 0.25)
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            try prepared.validate(original: prepared.probability.original)
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
}
