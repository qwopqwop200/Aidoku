import CoreML
import Foundation

enum IPhoneOCRSettings { static let defaultRecognizerMaximumWidth = 1_280 }
enum NativeCoreMLRecognizerError: Error { case modelInputCreationFailed }
enum InjectedFailure: Error { case prediction }

enum ReaderTranslationSession {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var available: UInt64 = 0
    static func setAvailable(_ value: UInt64) { lock.withLock { available = value } }
    static func processAvailableMemory() -> UInt64 { lock.withLock { available } }
}

private actor Pause {
    private var waiter: CheckedContinuation<Void, Never>?
    private var parked: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation {
            parked = $0
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilHeld() async {
        if parked != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() { parked?.resume(); parked = nil }
}

private typealias Store = Predictor.ModelStore
private typealias Access = Predictor.ModelAccess
private let variant = NativeCoreMLRecognitionModelVariant(width: 96, batchSize: 1)!

private func acquire(_ store: Store, holding pause: Pause? = nil) async throws -> Access {
    try await store.withPredictionModel(for: variant) { access in
        if let pause { await pause.hold() }
        try Task.checkCancellation()
        return access
    }
}

private func concurrent(_ store: Store) async throws -> (Access, Access) {
    let pause = Pause()
    async let first = acquire(store, holding: pause)
    await pause.waitUntilHeld()
    let second = await Task { try await acquire(store) }.result
    await pause.release()
    return (try await first, try second.get())
}

private func outputBits(_ model: MLModel, input: MLFeatureProvider) async throws -> [String: [UInt32]] {
    let output = try await model.prediction(from: input)
    var bits = [String: [UInt32]]()
    for name in output.featureNames {
        let array = output.featureValue(for: name)!.multiArrayValue!
        bits[name] = (0..<array.count).map { index in
            array.dataType == .int32 ? UInt32(bitPattern: array[index].int32Value) : array[index].floatValue.bitPattern
        }
    }
    precondition(Set(bits.keys) == ["ctc_indices", "ctc_scores", "ctc_topk_indices", "ctc_topk_scores"])
    return bits
}

@main private enum Regression {
    static func main() async throws {
        let url = try await MLModel.compileModel(at: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { try? FileManager.default.removeItem(at: url) }
        let makeStore = { try Store(asset: MLModelAsset(url: url), assetURL: url,
                                    maximumResidentModels: 2, usesDynamicModel: true) }
        let gate = UInt64(3) << 30
        for memory in [UInt64.max, 0, gate - 1] {
            ReaderTranslationSession.setAvailable(memory)
            let (first, second) = try await concurrent(makeStore())
            precondition(first.handle.model === second.handle.model && !second.wasLoaded)
        }

        ReaderTranslationSession.setAvailable(gate)
        let store = try makeStore()
        let serial = try await acquire(store)
        let (primary, replica) = try await concurrent(store)
        precondition(serial.handle.model === primary.handle.model && primary.handle.model !== replica.handle.model)
        let input = try MLMultiArray(shape: variant.inputShape.map(NSNumber.init(value:)), dataType: .float32)
        for i in 0..<input.count { input[i] = NSNumber(value: Float(i % 127) / 64 - 1) }
        let features = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
        let expected = try await outputBits(primary.handle.model, input: features)
        let actual = try await outputBits(replica.handle.model, input: features)
        precondition(actual == expected)

        // A single primary failure must propagate. An accepted replica failure
        // also propagates, and only subsequent work falls back to the primary.
        do {
            try await store.withPredictionModel(for: variant) { _ in throw InjectedFailure.prediction }
            fatalError("primary failure swallowed")
        } catch InjectedFailure.prediction {}
        let firstHold = Pause()
        async let held = acquire(store, holding: firstHold)
        await firstHold.waitUntilHeld()
        do {
            try await store.withPredictionModel(for: variant) { access in
                precondition(access.handle.model === replica.handle.model)
                throw InjectedFailure.prediction
            }
            fatalError("replica failure swallowed")
        } catch InjectedFailure.prediction {}
        let fallback = try await acquire(store)
        precondition(fallback.handle.model === primary.handle.model)
        await firstHold.release()
        _ = try await held
        await store.purge()

        // Cancel the secondary while the primary is still parked. A later
        // eligible request can acquire a new secondary after cancellation.
        let primaryHold = Pause(), secondaryHold = Pause()
        async let pendingPrimary = acquire(store, holding: primaryHold)
        await primaryHold.waitUntilHeld()
        let cancelled = Task { try await acquire(store, holding: secondaryHold) }
        await secondaryHold.waitUntilHeld()
        cancelled.cancel()
        await secondaryHold.release()
        do { _ = try await cancelled.value; fatalError("superseded output escaped") } catch is CancellationError {}
        let replacement = try await acquire(store)
        precondition(replacement.wasLoaded)
        await store.purge()
        await primaryHold.release()
        do { _ = try await pendingPrimary; fatalError("purged output escaped") } catch is CancellationError {}

        let (_, recent) = try await concurrent(store)
        try await Task.sleep(for: .seconds(2.3))
        let (_, retained) = try await concurrent(store)
        precondition(!retained.wasLoaded && recent.handle.model === retained.handle.model)
        try await Task.sleep(for: .seconds(8.3))
        let (_, expired) = try await concurrent(store)
        precondition(expired.wasLoaded && retained.handle.model !== expired.handle.model)

        // Budget oscillation must not pay repeated model construction costs.
        for _ in 0..<12 {
            ReaderTranslationSession.setAvailable(gate - 1)
            let low = try await concurrent(store)
            precondition(low.0.handle.model === low.1.handle.model)
            ReaderTranslationSession.setAvailable(gate + 1)
            let high = try await concurrent(store)
            precondition(high.0.handle.model === high.1.handle.model)
        }
        try await Task.sleep(for: .seconds(3.2))
        let recovered = try await concurrent(store)
        precondition(recovered.0.handle.model !== recovered.1.handle.model && recovered.1.wasLoaded)

        // A warning or background event relinquishes optional residency.
        // Only official cancellation/purge can invalidate an accepted prediction.
        for warning in [false, true] {
            let first = Pause(), second = Pause()
            async let primary = acquire(store, holding: first)
            await first.waitUntilHeld()
            async let secondary = acquire(store, holding: second)
            await second.waitUntilHeld()
            if warning { await store.trimReplicaForPressure() } else { await store.setForeground(false) }
            await second.release()
            let live = try await secondary
            let fallback = try await acquire(store)
            await first.release()
            let original = try await primary
            precondition(original.handle.model !== live.handle.model && fallback.handle.model === original.handle.model)
            if warning { try await Task.sleep(for: .seconds(3.2)) } else { await store.setForeground(true) }
            let next = try await concurrent(store)
            precondition(next.1.wasLoaded && next.1.handle.model !== live.handle.model)
        }
        print("PASS dynamic REC real handle identity, compact outputs, headroom, failure, cancellation, purge and idle expiry")
    }
}
