func check(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) { precondition(value(), "RF cache check", file: file, line: line) }
import CoreML
import CryptoKit
import Foundation


/// Frozen serial FP32 tensors for upsampling and for filters crossing worker bands.
func rfResizePreservesNormalizedPixels() throws {
    let fixtures = [
        (797, 1187, "9490130ae9bef29bb28128c4150eb467c1aa11d04b9074f7f7c8a35cb9189bc5"),
        (5, 3, "ce833f35a26978440f720a45e2a707f1a5bf2a2bb3199607aeeb75b6961ae141")
    ]
    for (width, height, digest) in fixtures {
        var pixels = Data(count: width * height * 3)
        pixels.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            for i in p.indices { p[i] = UInt8(truncatingIfNeeded: (i &* 29) ^ (i >> 5)) }
        }
        let source = try NativeRFDETRSourceImage(width: width, height: height, rgb: pixels)
        let tensor = try NativeRFDETRLayoutTensorContract.preprocess(source)
        let words = UnsafeRawBufferPointer(start: tensor.dataPointer, count: tensor.count * MemoryLayout<Float>.stride)
        check(SHA256.hash(data: words).map { String(format: "%02x", $0) }.joined() == digest)
    }
}

/// Focused test, zero model loading/prediction or source-image files.
/// Calls production decode on direct synthetic tensors and the copied snapshot.
@available(iOS 18.0, macOS 15.0, *)
func rawSnapshotPreservesEveryConsumerMaskBudget() throws -> NativeRFRawSnapshot {
    var arrays: [String: MLMultiArray] = [:]
    for (name, shape) in NativeRFDETRLayoutTensorContract.outputShapes {
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        let p = a.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<a.count { p[i] = name == "logits" ? -20 : 0 }
        arrays[name] = a
    }
    let boxes = arrays["boxes"]!.dataPointer.assumingMemoryBound(to: Float.self)
    let logits = arrays["logits"]!.dataPointer.assumingMemoryBound(to: Float.self)
    let masks = arrays["instance_masks"]!.dataPointer.assumingMemoryBound(to: Float.self)
    for q in 0..<300 {
        boxes[q*4] = 0.5; boxes[q*4+1] = 0.5; boxes[q*4+2] = 0.5; boxes[q*4+3] = 0.5
        // Query0 accepted text, query1 accepted balloon, others weak. A shared
        // all-query final result would incorrectly expose weak masks to false.
        if q == 0 { logits[0] = 4 }
        if q == 1 { logits[5+2] = 3 }
        for p in 0..<(162*162) { masks[q*162*162+p] = (p+q)%3 == 0 ? 1 : -1 }
    }
    // Noncontiguous boxes force the logical stride-copy path. NaN gaps
    // must not be mistaken for logical tensor elements.
    let storage = UnsafeMutableRawPointer.allocate(byteCount: 300*8*4, alignment: 16)
    storage.initializeMemory(as: UInt8.self, repeating: 0, count: 300*8*4)
    let stridedBoxes = try MLMultiArray(dataPointer: storage, shape: [1,300,4], dataType: .float32,
        strides: [2400,8,2], deallocator: { $0.deallocate() })
    let strided = storage.assumingMemoryBound(to: Float.self)
    for i in 0..<(300*8) where i % 2 == 1 { strided[i] = .nan }
    for q in 0..<300 { for c in 0..<4 { strided[q*8+c*2] = boxes[q*4+c] } }
    arrays["boxes"] = stridedBoxes
    let direct = try MLDictionaryFeatureProvider(dictionary: arrays.mapValues { MLFeatureValue(multiArray: $0) })
    let source = try NativeRFDETRSourceImage(width: 2, height: 2, rgb: Data(repeating: 255, count: 12))
    let snapshot = try NativeRFRawSnapshot(actualOutput: direct, preprocessingMilliseconds: 1,
        modelMilliseconds: 1, weightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256, sourceIdentity: source.identity)
    for (cap, all) in [(0,false),(1,false),(160,false),(160,true)] {
        let expected = try NativeRFDETRLayoutTensorContract.decode(direct, source: source,
            maximumMaskQueries: cap, retainAllQueryMasks: all)
        let actual = try snapshot.materialize(source: source, maximumMaskQueries: cap,
            retainAllQueryMasks: all, computeUnits: "synthetic", reused: true)
        check(actual.primitives.count == expected.primitives.count)
        for (a,b) in zip(actual.primitives, expected.primitives) {
            check(a.queryID == b.queryID && a.semanticClass == b.semanticClass)
            check(a.confidence.bitPattern == b.confidence.bitPattern)
            check(a.normalizedBounds == b.normalizedBounds && a.sourceBounds == b.sourceBounds)
            check(a.mask?.logits == b.mask?.logits)
        }
        check(actual.maskQueriesOmittedByBudget == expected.omitted)
        if all {
            // A single exported weak query must outlive the page without
            // pinning the immutable 300-plane bank. Concurrent raw readers
            // share the one detached set of independent array values.
            let bankIsLive = { [weak bank = actual.pixelInventory.bank] in bank != nil }
            check(bankIsLive() && actual.pixelInventory.queries[299].mask == nil)
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                let exported = actual.classEvidence[299]
                check(exported.mask?.logits.first == expected.classEvidence[299].mask?.logits.first)
            }
            let escaped = actual.classEvidence[299]
            check(!bankIsLive() && escaped.mask?.queryID == 299)
            var copy = actual
            copy.classEvidence = []
            check(copy.classEvidence.isEmpty && actual.classEvidence.count == 300)
            let first = escaped.mask!.logits, next = actual.classEvidence[299].mask!.logits
            first.withUnsafeBufferPointer { a in
                next.withUnsafeBufferPointer { b in check(a.baseAddress == b.baseAddress) }
            }
        }
        check(actual.classEvidence.count == expected.classEvidence.count)
        for (a,b) in zip(actual.classEvidence, expected.classEvidence) {
            check(a.queryID == b.queryID && a.logits == b.logits && a.probabilities == b.probabilities)
            check(a.normalizedBounds == b.normalizedBounds && a.sourceBounds == b.sourceBounds)
            check(a.mask?.logits == b.mask?.logits)
        }
        check(actual.sourceSupportGrid?.native17Fields == expected.sourceSupportGrid.native17Fields)
        check(actual.semanticGrid?.probabilities == expected.semanticGrid?.probabilities)
        check(actual.semanticGrid?.weightedMeanProbabilities == expected.semanticGrid?.weightedMeanProbabilities)
        check(actual.modelMilliseconds == 0 && actual.fromCache)
    }
    // Compare the compact and padded-plane decoder branches independently of
    // the snapshot. Sample the first/tail query and preserve signed zero.
    let rowStride = 164, queryStride = 162 * rowStride
    let padded = UnsafeMutablePointer<Float>.allocate(capacity: 300 * queryStride)
    padded.initialize(repeating: .nan, count: 300 * queryStride)
    let paddedArray = try MLMultiArray(dataPointer: UnsafeMutableRawPointer(padded),
        shape: [1,300,162,162], dataType: .float32,
        strides: [NSNumber(value: 300 * queryStride), NSNumber(value: queryStride), NSNumber(value: rowStride), 1],
        deallocator: { $0.assumingMemoryBound(to: Float.self).deallocate() })
    let cells = 162 * 162
    masks[cells - 1] = -0.0
    masks[300 * cells - 1] = -0.0
    for q in 0..<300 { for y in 0..<162 {
        (padded + q * queryStride + y * rowStride)
            .update(from: masks + q * cells + y * 162, count: 162)
    } }
    var paddedFeatures = arrays
    paddedFeatures["instance_masks"] = paddedArray
    let paddedProvider = try MLDictionaryFeatureProvider(dictionary: paddedFeatures.mapValues { MLFeatureValue(multiArray: $0) })
    let paddedResult = try NativeRFDETRLayoutTensorContract.decode(paddedProvider, source: source,
        maximumMaskQueries: 1, retainAllQueryMasks: true)
    let compactResult = try NativeRFDETRLayoutTensorContract.decode(direct, source: source,
        maximumMaskQueries: 1, retainAllQueryMasks: true)
    // Compare both tiled Core ML layouts to query-major logical reads across
    // every source-support plane, including the final partial row tile.
    let reference = try NativeRFDETRSourceSupportGrid.aggregate(
        boxes: Array(UnsafeBufferPointer(start: boxes, count: 300 * 4)),
        logits: Array(UnsafeBufferPointer(start: logits, count: 300 * 5))
    ) { q, y, x in masks[(q * 162 + y) * 162 + x] }
    for grid in [compactResult.sourceSupportGrid, paddedResult.sourceSupportGrid] {
        check(grid.native17Fields.elementsEqual(reference.native17Fields) { $0.bitPattern == $1.bitPattern })
    }
    for q in [0, 299] {
        let a = paddedResult.classEvidence.first { $0.queryID == q }?.mask?.logits
        let b = compactResult.classEvidence.first { $0.queryID == q }?.mask?.logits
        check(a == b)
        check(a?.last?.bitPattern == 0x8000_0000 && b?.last?.bitPattern == 0x8000_0000)
    }
    // Transpose the same padded storage: column spacing is now 164 floats.
    // All fixture boxes are symmetric. Every resulting support plane and
    // retained mask must be the exact transpose, including negative zero.
    let transposedArray = try MLMultiArray(dataPointer: UnsafeMutableRawPointer(padded), shape: [1,300,162,162],
        dataType: .float32, strides: [NSNumber(value: 300 * queryStride), NSNumber(value: queryStride), 1, NSNumber(value: rowStride)],
        deallocator: nil)
    paddedFeatures["instance_masks"] = transposedArray
    let transposed = try NativeRFDETRLayoutTensorContract.decode(
        MLDictionaryFeatureProvider(dictionary: paddedFeatures.mapValues { MLFeatureValue(multiArray: $0) }),
        source: source, maximumMaskQueries: 1, retainAllQueryMasks: true)
    for plane in 0..<17 {
        for y in 0..<162 { for x in 0..<162 {
            let index = plane * cells + y * 162 + x
            let expected = plane * cells + x * 162 + y
            check(transposed.sourceSupportGrid.native17Fields[index].bitPattern == reference.native17Fields[expected].bitPattern)
        } }
    }
    check(transposed.classEvidence[299].mask?.logits.last?.bitPattern == 0x8000_0000)
    padded[queryStride * 299 + 161 * rowStride + 161] = .infinity
    do {
        _ = try NativeRFDETRLayoutTensorContract.decode(paddedProvider, source: source,
            maximumMaskQueries: 1, retainAllQueryMasks: true)
        fatalError("nonfinite padded mask admitted")
    } catch NativeRFDETRLayoutError.nonfiniteOutput {}
    // Deep-copy proof: mutating CoreML-owned original must not alter snapshot.
    masks[0] = 99
    let after = try snapshot.materialize(source: source, maximumMaskQueries: 160,
        retainAllQueryMasks: true, computeUnits: "synthetic", reused: true)
    check(after.classEvidence.first?.mask?.logits.first == 1)
    masks[0] = .nan
    do {
        _ = try NativeRFRawSnapshot(actualOutput: direct, preprocessingMilliseconds: 1,
            modelMilliseconds: 1, weightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
            sourceIdentity: source.identity)
        fatalError("nonfinite raw admitted")
    } catch NativeRFDETRLayoutError.nonfiniteOutput {}
    return snapshot
}

actor Count {
    private var value = 0
    func next() { value += 1 }
    func read() -> Int { value }
}
actor Signal {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let old = waiters; waiters.removeAll(); for waiter in old { waiter.resume() } }
}
enum FixtureFailure: Error { case intentional }

@available(iOS 18.0, macOS 15.0, *)
func rawCacheGuards(_ fixture: NativeRFRawSnapshot) async throws {
    func key(_ field: String = "") -> NativeRFRawRequestCache.Key {
        .init(sourceRGBIdentity: field == "rgb" ? "different-rgb" : fixture.sourceIdentity,
            installedModelTreeSHA256: field == "model" ? "different-model" : "fixed-model",
            expectedWeightsSHA256: field == "weights" ? "other-weights" : fixture.weightsSHA256,
            sourceRevision: field == "revision" ? "different-revision" : "fixed-revision",
            preprocessVersion: field == "preprocess" ? "different-preprocess" : "fixed-preprocess",
            tensorContractVersion: field == "tensor" ? "different-tensor" : "fixed-tensor",
            computeUnits: field == "compute" ? "different-compute" : "fixed-compute",
            runtimeVersion: field == "runtime" ? "different-runtime" : "fixed-runtime")
    }
    let cache = NativeRFRawRequestCache(budget: 32 * 1_048_576), count = Count()
    for _ in 0..<3 { _ = try await cache.raw(key: key()) { await count.next(); return fixture } }
    let one = await count.read(); check(one == 1)
    for field in ["model", "revision", "preprocess", "tensor", "compute", "runtime"] {
        _ = try await cache.raw(key: key(field)) { await count.next(); return fixture }
        let statistics = await cache.statistics(); check(statistics.retainedBytes == fixture.byteCost)
    }
    for field in ["rgb", "weights"] {
        do { _ = try await cache.raw(key: key(field)) { await count.next(); return fixture }; fatalError("stale raw accepted") }
        catch NativeRFDETRLayoutError.unsupportedModelContract {}
    }
    let calls = await count.read(); check(calls == 9)
    do { _ = try await cache.raw(key: key()) { throw FixtureFailure.intentional }; fatalError("failure admitted") }
    catch FixtureFailure.intentional {}
    var result = try await cache.raw(key: key()) { await count.next(); return fixture }
    check(!result.reused)
    let zero = NativeRFRawRequestCache(budget: 0), zeroCount = Count()
    for _ in 0..<2 { _ = try await zero.raw(key: key()) { await zeroCount.next(); return fixture } }
    let two = await zeroCount.read(); check(two == 2)
    let zeroState = await zero.statistics(); check(zeroState.retainedBytes == 0)

    let shared = NativeRFRawRequestCache(), started = Signal(), finish = Signal()
    let bound = key()
    let first = Task { try await shared.raw(key: bound) { await started.open(); await finish.wait(); return fixture } }
    await started.wait()
    let second = Task { try await shared.raw(key: bound) { fatalError("identical request did not join") } }
    for _ in 0..<10_000 {
        if await shared.statistics().joinedRequests == 1 { break }
        await Task.yield()
    }
    let joined = await shared.statistics(); check(joined.joinedRequests == 1)
    first.cancel(); await finish.open()
    do { _ = try await first.value; fatalError("cancelled subscriber returned raw") } catch is CancellationError {}
    result = try await second.value; check(result.reused)
    let state = await shared.statistics(); check(state.inferenceRequests == 1 && state.retainedBytes == fixture.byteCost)

    let purge = NativeRFRawRequestCache(), began = Signal(), release = Signal()
    let work = Task { try await purge.raw(key: bound) {
        await began.open(); await release.wait(); try Task.checkCancellation(); return fixture
    } }
    await began.wait()
    let closing = Task { await purge.close() }
    for _ in 0..<10_000 {
        if await purge.statistics().purging { break }
        await Task.yield()
    }
    let closingState = await purge.statistics(); check(closingState.purging && closingState.pending)
    await release.open(); await closing.value
    do { _ = try await work.value; fatalError("purged generation returned raw") } catch is CancellationError {}
    let purged = await purge.statistics(); check(purged.retainedBytes == 0 && !purged.pending)
    result = try await purge.raw(key: bound) { fixture }; check(!result.reused)
    await purge.discardCompleted()
    let dropped = await purge.statistics(); check(dropped.retainedBytes == 0)
}

private func matchingOCRProducersRequireTheSameCheckpointAndDecoder() {
    typealias Producer = NativeRFDETRLayoutResource.OCRProducer
    let producer = Producer(resourceName: "a", weightsSHA256: "weights", revision: "r1")
    check(producer == Producer(resourceName: "a", weightsSHA256: "weights", revision: "r1"))
    for different in [
        Producer(resourceName: "b", weightsSHA256: "weights", revision: "r1"),
        Producer(resourceName: "a", weightsSHA256: "other", revision: "r1"),
        Producer(resourceName: "a", weightsSHA256: "weights", revision: "r2"),
        Producer(resourceName: "a", weightsSHA256: "weights", revision: "r1", maximumMaskQueries: 1),
        Producer(resourceName: "a", weightsSHA256: "weights", revision: "r1", retainAllQueryMasks: true)
    ] { check(producer != different) }
}

@available(iOS 18.0, macOS 15.0, *)
@main enum RFSharedCacheSmoke {
    static func main() async throws {
        try rfResizePreservesNormalizedPixels()
        matchingOCRProducersRequireTheSameCheckpointAndDecoder()
        let own = FileManager.default.temporaryDirectory.appendingPathComponent("rf-hash-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: own) }
        for name in ["a", "b"] {
            let folder = own.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: folder.appendingPathComponent("synthetic-output.bin"))
        }
        let a = try NativeRFInstalledModelIdentity.digest(own.appendingPathComponent("a"))
        let b = try NativeRFInstalledModelIdentity.digest(own.appendingPathComponent("b"))
        check(a != b)
        // A model may be republished at the same path. Both an atomic replace
        // and an in-place same-length rewrite must invalidate the old identity.
        let package = own.appendingPathComponent("a")
        let file = package.appendingPathComponent("synthetic-output.bin")
        try Data("b".utf8).write(to: file, options: .atomic)
        let replaced = try NativeRFInstalledModelIdentity.digest(package)
        check(replaced == b)
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: Data("a".utf8))
        try writer.close()
        let rewritten = try NativeRFInstalledModelIdentity.digest(package)
        check(rewritten == a)

        let detachedFlag = await Task.detached { NativeRFRawCachePolicy.enabled }.value
        check(detachedFlag == NativeRFRawCachePolicy.enabled)
        var directCalls = 0, cachedCalls = 0
        _ = NativeRFRawCachePolicy.select(direct: { directCalls += 1; return 1 }, cached: { cachedCalls += 1; return 2 })
        check(directCalls == (NativeRFRawCachePolicy.enabled ? 0 : 1))
        check(cachedCalls == (NativeRFRawCachePolicy.enabled ? 1 : 0))
        let fixture = try rawSnapshotPreservesEveryConsumerMaskBudget()
        try await rawCacheGuards(fixture)
        try await compactDiagnostics(fixture)
        try await interleavedLRUReplay(fixture)
        print("PASS native decode cap0/1/160false+160true; weakmask/native17/deepcopy; RGB/model/runtime/config stale keys; 3requests1raw; singleflight; cancellation subscriber; purge join; bounded/zero budget; failed output retry. Model runs0.")
    }
}

 
@available(iOS 18.0, macOS 15.0, *)
func compactDiagnostics(_ fixture: NativeRFRawSnapshot) async throws {
    let key = NativeRFRawRequestCache.Key(sourceRGBIdentity: "diagnostic-synthetic",
        installedModelTreeSHA256: "diagnostic-model", expectedWeightsSHA256: fixture.weightsSHA256,
        sourceRevision: "fixed", preprocessVersion: "fixed", tensorContractVersion: "fixed",
        computeUnits: "synthetic", runtimeVersion: "synthetic")
    // Diagnostic counts are tested independently from real neural prediction.
    for all in [false, false, true] {
        NativeRFRawCacheDiagnostics.event(key, "consumerRequests", maximumMasks: 160, retainAll: all)
        NativeRFRawCacheDiagnostics.event(key, "decoderMaterializations")
    }
    NativeRFRawCacheDiagnostics.event(key, "actualPredictionCalls")
    let payload = NativeRFRawCacheDiagnostics.snapshot(sourceIdentity: "diagnostic-synthetic")
    if NativeRFRawCachePolicy.enabled {
        let rows = payload["rawContracts"] as! [[String: Any]]
        let counters = rows[0]["counters"] as! [String: Int]
        check(counters["consumerRequests"] == 3 && counters["actualPredictionCalls"] == 1)
        let configurations = rows[0]["consumerMaskConfigurations"] as! [String: Int]
        check(configurations["cap160:retainAllfalse"] == 2 && configurations["cap160:retainAlltrue"] == 1)
        check(JSONSerialization.isValidJSONObject(payload))
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        check(bytes.count < 10_000)
    } else { check(payload.isEmpty) }
    print("PASS processFlag=\(NativeRFRawCachePolicy.enabled); detached flag, OFF direct-only policy, bounded compact counter schema")
}

@available(iOS 18.0, macOS 15.0, *)
func interleavedLRUReplay(_ first: NativeRFRawSnapshot) async throws {
    // Three DIFFERENT true RGB identities; synthetic finite tensors only.
    func fixture(_ gray: UInt8) throws -> NativeRFRawSnapshot {
        var values: [String: MLMultiArray] = [:]
        for (name, shape) in NativeRFDETRLayoutTensorContract.outputShapes {
            let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<array.count { pointer[i] = name == "logits" ? -20 : 0 }
            values[name] = array
        }
        let source = try NativeRFDETRSourceImage(width: 2, height: 2, rgb: Data(repeating: gray, count: 12))
        let provider = try MLDictionaryFeatureProvider(dictionary: values.mapValues { MLFeatureValue(multiArray: $0) })
        return try NativeRFRawSnapshot(actualOutput: provider, preprocessingMilliseconds: 0,
            modelMilliseconds: 0, weightsSHA256: first.weightsSHA256, sourceIdentity: source.identity)
    }
    let second = try fixture(0), third = try fixture(128)
    check(first.sourceIdentity != second.sourceIdentity && second.sourceIdentity != third.sourceIdentity)
    func key(_ value: NativeRFRawSnapshot) -> NativeRFRawRequestCache.Key {
        .init(sourceRGBIdentity: value.sourceIdentity, installedModelTreeSHA256: "same-fixed-model",
            expectedWeightsSHA256: value.weightsSHA256, sourceRevision: "same-fixed-revision",
            preprocessVersion: "same-fixed-preprocess", tensorContractVersion: "same-fixed-tensor",
            computeUnits: "synthetic", runtimeVersion: "synthetic")
    }
    // Mirrors actual asynchronous page overlap: A auxiliary/raw, B auxiliary/raw,
    // A style, B style. cap/retention are consumer settings, never source keys.
    let timeline: [(NativeRFRawSnapshot, Bool)] = [
        (first,false),(first,false),(second,false),(second,false),(first,true),(second,true)
    ]
    var reports: [[String: Any]] = []
    for budget in [64, 32, 0] {
        let cache = NativeRFRawRequestCache(budget: budget * 1_048_576), calls = Count()
        var events: [[String: Any]] = []
        for (value, all) in timeline {
            let result = try await cache.raw(key: key(value)) { await calls.next(); return value }
            let state = await cache.statistics()
            check(state.retainedBytes <= budget * 1_048_576 && state.retainedEntries <= 2)
            events.append(["sourceIdentity": value.sourceIdentity, "cap": 160, "retainAll": all,
                "reused": result.reused, "retainedEntries": state.retainedEntries,
                "retainedPayloadBytes": state.retainedBytes])
        }
        let count = await calls.read()
        check(count == (budget == 64 ? 2 : budget == 32 ? 4 : 6))
        reports.append(["budgetMiB": budget, "consumerRequests": 6,
            "freshClosureCalls": count, "events": events, "actualModelPredictions": 0])
        await cache.close()
        let closed = await cache.statistics()
        check(closed.retainedEntries == 0 && closed.retainedBytes == 0 && !closed.pending)
    }
    // A real two-entry LRU must update recency on hits: A/B, touchA, insertC
    // evictsB. A and C still hit, then B requires one fresh closure.
    let lru = NativeRFRawRequestCache(), calls = Count()
    for value in [first, second] { _ = try await lru.raw(key: key(value)) { await calls.next(); return value } }
    var state = await lru.statistics()
    check(state.retainedEntries == 2 && state.retainedBytes == 2 * first.byteCost)
    _ = try await lru.raw(key: key(first)) { fatalError("A unexpectedly evicted") }
    _ = try await lru.raw(key: key(third)) { await calls.next(); return third }
    _ = try await lru.raw(key: key(first)) { fatalError("MRU A evicted instead of B") }
    _ = try await lru.raw(key: key(third)) { fatalError("C not retained") }
    let restoredB = try await lru.raw(key: key(second)) { await calls.next(); return second }
    check(!restoredB.reused)
    let four = await calls.read(); check(four == 4)
    await lru.discardCompleted()
    state = await lru.statistics(); check(state.retainedEntries == 0 && state.retainedBytes == 0)

    // Pressure during an admitted third-source prediction clears BOTH completed
    // entries and suppresses that pending result's later retention.
    for value in [first, second] { _ = try await lru.raw(key: key(value)) { value } }
    let began = Signal(), release = Signal()
    let pending = Task { try await lru.raw(key: key(third)) {
        await began.open(); await release.wait(); return third
    } }
    await began.wait()
    state = await lru.statistics()
    check(state.pending && state.retainedEntries == 1)
    check(state.retainedBytes + third.byteCost <= 64 * 1_048_576)
    await lru.discardCompleted(); await release.open()
    _ = try await pending.value
    state = await lru.statistics()
    check(state.retainedEntries == 0 && state.retainedBytes == 0 && !state.pending)
    await lru.close()
    let evidence: [String: Any] = ["schema": "synthetic-two-source-three-consumer-lru-v1",
        "modelLoads": 0, "actualModelPredictions": 0, "reports": reports,
        "thirdSourceLRUAndPurgePassed": true]
    print(String(decoding: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), as: UTF8.self))
}
