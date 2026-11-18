import Darwin
import CoreML
import Foundation
import CryptoKit

/// Copy actual prediction outputs ONCE; never retain CoreML-owned
/// reusable output memory, model/provider handles, RGB pixels or display items.
/// The sole materializer calls the EXISTING decoder with EACH consumer's config.
@available(iOS 18.0, macOS 15.0, *)
final class NativeRFRawSnapshot: @unchecked Sendable {
    private let arrays: [String: MLMultiArray]
    private let lock = NSLock()
    // Protected by lock. This reduction depends only on the immutable raw tensors.
    private var supportGrid: NativeRFDETRSourceSupportGrid?
    static let tensorPayloadBytes = (300*4 + 300*5 + 300*162*162) * MemoryLayout<Float>.size
    static let reservedBytes = tensorPayloadBytes + NativeRFDETRSourceSupportGrid.planeCount
        * NativeRFDETRSourceSupportGrid.side * NativeRFDETRSourceSupportGrid.side * MemoryLayout<Float>.size
    let byteCost = NativeRFRawSnapshot.reservedBytes
    let modelMilliseconds: Double
    let preprocessingMilliseconds: Double
    let weightsSHA256: String
    let sourceIdentity: String
    let snapshotCopyMilliseconds: Double

    init(actualOutput: MLFeatureProvider, preprocessingMilliseconds: Double,
         modelMilliseconds: Double, weightsSHA256: String, sourceIdentity: String) throws {
        let copyStart = ProcessInfo.processInfo.systemUptime
        var copies: [String: MLMultiArray] = [:]
        for (name, shape) in NativeRFDETRLayoutTensorContract.outputShapes {
            guard let raw = actualOutput.featureValue(for: name)?.multiArrayValue,
                  raw.dataType == .float32, raw.shape.map(\.intValue) == shape,
                  raw.strides.allSatisfy({ $0.intValue > 0 }) else {
                throw NativeRFDETRLayoutError.unsupportedModelContract("raw RF snapshot \(name)")
            }
            let copy = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
            let from = raw.dataPointer.assumingMemoryBound(to: Float.self)
            let to = copy.dataPointer.assumingMemoryBound(to: Float.self)
            let strides = raw.strides.map(\.intValue)
            // Every output has leading batch1. Copy logical tensor elements,
            // preserving values, independent of backing strides or aliasing.
            let contiguous = raw.strides.map(\.intValue) == copy.strides.map(\.intValue)
            if contiguous {
                // Check at the same logical tensor offsets as the strided
                // path; finite validation and copy still share one traversal.
                let chunk = 162 * 162
                for start in stride(from: 0, to: copy.count, by: chunk) {
                    try Task.checkCancellation()
                    let end = min(start + chunk, copy.count)
                    try NativeRFDETRLayoutTensorContract.copyFinite(from: from + start, to: to + start, count: end - start)
                }
            } else {
                // Both validated rank-three outputs have one row per query.
                // The rank-four mask tensor has 162 rows per query.
                let rows = shape.count == 4 ? shape[2] : 1
                let rowStride = shape.count == 4 ? strides[2] : 0
                let width = shape.last!, pixelStride = strides.last!
                for query in 0..<shape[1] {
                    if rows > 1 || query == 0 { try Task.checkCancellation() }
                    let queryStart = query * strides[1]
                    for row in 0..<rows {
                        let input = from + queryStart + row * rowStride
                        let output = to + (query * rows + row) * width
                        for column in 0..<width {
                            let value = input[column * pixelStride]
                            guard value.isFinite else { throw NativeRFDETRLayoutError.nonfiniteOutput }
                            output[column] = value
                        }
                    }
                }
            }
            copies[name] = copy
        }
        try Task.checkCancellation()
        self.arrays = copies
        self.preprocessingMilliseconds = preprocessingMilliseconds
        self.modelMilliseconds = modelMilliseconds
        self.weightsSHA256 = weightsSHA256
        self.sourceIdentity = sourceIdentity
        self.snapshotCopyMilliseconds = (ProcessInfo.processInfo.systemUptime - copyStart) * 1_000
    }

    func materialize(source: any NativeRFDETRInferenceSource, maximumMaskQueries: Int,
                     retainAllQueryMasks: Bool, computeUnits: String, reused: Bool,
                     sourcePreparationMilliseconds: Double = 0) throws -> NativeRFDETRLayoutResult {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        guard source.identity == sourceIdentity else { throw NativeRFDETRLayoutError.invalidImage }
        let provider = try MLDictionaryFeatureProvider(dictionary: arrays.mapValues { MLFeatureValue(multiArray: $0) })
        let start = ProcessInfo.processInfo.systemUptime
        // Critical: NO full-result alias and NO weak-mask promotion. Same exact
        // old function receives the original cap/retention flags each time.
        var bank: NativeRFImmutableMaskBank?
        if retainAllQueryMasks, maximumMaskQueries >= 160, let mask = arrays["instance_masks"],
           mask.strides.map(\.intValue) == [300 * 162 * 162, 162 * 162, 162, 1] {
            // Only independent finite snapshot memory is exposed to consumers.
            let bytes = Data(bytesNoCopy: mask.dataPointer, count: mask.count * MemoryLayout<Float>.size,
                             deallocator: .custom { _, _ in withExtendedLifetime(mask) {} })
            bank = NativeRFImmutableMaskBank(bytes: bytes, width: source.width, height: source.height)
        }
        let value = try NativeRFDETRLayoutTensorContract.decode(provider, source: source,
            maximumMaskQueries: maximumMaskQueries, retainAllQueryMasks: retainAllQueryMasks,
            snapshotSupportGrid: supportGrid, borrowSnapshotWeakMasks: bank != nil)
        supportGrid = value.sourceSupportGrid
        var grid = value.semanticGrid; grid?.modelWeightsSHA256 = weightsSHA256
        return NativeRFDETRLayoutResult(imageIdentity: source.identity, sourceWidth: source.width,
            sourceHeight: source.height, primitives: value.primitives,
            maskQueriesOmittedByBudget: value.omitted,
            preprocessingMilliseconds: reused ? sourcePreparationMilliseconds : preprocessingMilliseconds,
            modelMilliseconds: reused ? 0 : modelMilliseconds,
            decodeMilliseconds: (ProcessInfo.processInfo.systemUptime-start)*1000 + (reused ? 0 : snapshotCopyMilliseconds),
            computeUnits: computeUnits, fromCache: reused, classEvidence: value.classEvidence,
            semanticGrid: grid, sourceSupportGrid: value.sourceSupportGrid, maskBank: bank)
    }
}

/// ONE shared native service, explicitly used by OCR and renderer transactions.
/// The default 64 MiB holds two snapshots, including their shared native17 reductions.
/// Consumer-specific mask inventories and decoded results are owned by callers.
/// At most one distinct inference task; identical callers join it. End-of-page
/// release/pressure invalidates epoch before cancel; stale completion can't enter.
@available(iOS 18.0, macOS 15.0, *)
actor NativeRFRawRequestCache {
    static let shared = NativeRFRawRequestCache()
    struct Key: Hashable, Codable, Sendable {
        let sourceRGBIdentity: String // NativeRFDETRSourceImage.identity, includes dims
        let installedModelTreeSHA256: String // actual compiled URL bytes, once per handle
        let expectedWeightsSHA256: String
        let sourceRevision: String
        let preprocessVersion: String // AA triangle/half-pixel/white sRGB/RGB8/mean/std
        let tensorContractVersion: String // fixed input/output shapes+float32/layout
        let computeUnits: String
        let runtimeVersion: String
        // retainAllQueryMasks/maxMaskQueries/native17 belong to exact materialization,
        // not inference: none changes the model input/output tensor itself.
    }
    static let defaultBudgetBytes = 64 * 1_048_576
    private let maximumEntries = 2
    private var entries: [Key: NativeRFRawSnapshot] = [:]
    private var recency: [Key] = []
    private var retainedBytes = 0
    private var pending: (Key, UUID, Task<NativeRFRawSnapshot, Error>)?
    private var epoch: UInt64 = 0
    private var retainPending = true
    private var inferenceRequests = 0
    private var joinedRequests = 0
    private var cacheHits = 0
    private let budget: Int
    private var purging = false
    private var purgeWaiters: [CheckedContinuation<Void, Never>] = []
    init(budget: Int = NativeRFRawRequestCache.defaultBudgetBytes) { self.budget = max(0, budget) }
    func raw(key: Key, infer: @escaping @Sendable () async throws -> NativeRFRawSnapshot
    ) async throws -> (snapshot: NativeRFRawSnapshot, reused: Bool) {
        try Task.checkCancellation()
        if purging {
            await withCheckedContinuation { purgeWaiters.append($0) }
            try Task.checkCancellation()
        }
        if let value = entries[key] {
            recency.removeAll { $0 == key }; recency.append(key)
            cacheHits += 1; NativeRFRawCacheDiagnostics.event(key, "rawCacheHits")
            return (value, true)
        }
        let generation = epoch
        let operation: (Key, UUID, Task<NativeRFRawSnapshot, Error>)
        let joined: Bool
        if let pending {
            if pending.0 != key {
                // Serialize another admitted source without inventing a busy
                // fallback that might drop mandatory model evidence. Identical
                // keys join below; distinct keys retry after the prior task.
                _ = try? await pending.2.value
                try Task.checkCancellation()
                guard generation == epoch else { throw CancellationError() }
                if self.pending?.1 == pending.1 { self.pending = nil }
                return try await raw(key: key, infer: infer)
            }
            operation = pending; joined = true; joinedRequests += 1
            NativeRFRawCacheDiagnostics.event(key, "singleflightJoins")
        } else {
            // Reserve one incoming snapshot BEFORE predicting/copying. A32MiB
            // budget adapts to one retained entry; zero retains none. This bounds
            // retained payload plus reserved incoming snapshot, not total RSS.
            reserveIncoming(bytes: NativeRFRawSnapshot.reservedBytes)
            operation = (key, UUID(), Task { try await infer() })
            inferenceRequests += 1
            retainPending = true
            pending = operation; joined = false
        }
        do {
            let value = try await operation.2.value
            guard generation == epoch else { throw CancellationError() }
            guard value.weightsSHA256 == key.expectedWeightsSHA256,
                  value.sourceIdentity == key.sourceRGBIdentity else {
                throw NativeRFDETRLayoutError.unsupportedModelContract("shared raw RF weights")
            }
            if pending?.1 == operation.1 {
                pending = nil
                if value.byteCost <= budget, retainPending {
                    reserveIncoming(bytes: value.byteCost)
                    entries[key] = value; recency.append(key); retainedBytes += value.byteCost
                }
            }
            try Task.checkCancellation()
            return (value, joined)
        } catch {
            if pending?.1 == operation.1 { pending = nil }
            throw error
        }
    }
    private func reserveIncoming(bytes: Int) {
        while !recency.isEmpty && (recency.count >= maximumEntries || retainedBytes > max(0, budget - bytes)) {
            let old = recency.removeFirst()
            if let value = entries.removeValue(forKey: old) { retainedBytes -= value.byteCost }
        }
    }
    private func removeCompleted() {
        entries.removeAll(); recency.removeAll(); retainedBytes = 0
    }
    func discardCompleted() {
        removeCompleted()
        if pending != nil { retainPending = false }
    }
    func statistics() -> (retainedBytes: Int, retainedEntries: Int, pending: Bool, purging: Bool, inferenceRequests: Int, joinedRequests: Int, cacheHits: Int) {
        (retainedBytes, entries.count, pending != nil, purging, inferenceRequests, joinedRequests, cacheHits)
    }
    func close() async {
        if purging {
            await withCheckedContinuation { purgeWaiters.append($0) }
            return
        }
        purging = true
        epoch &+= 1; removeCompleted()
        let operation = pending
        operation?.2.cancel()
        // Join even synchronous CoreML work before admitting another source.
        _ = try? await operation?.2.value
        pending = nil; purging = false
        let waiters = purgeWaiters; purgeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Fingerprint the actual installed bytes. A new binding at a reused pathname
/// must see file replacement, in-place writes, directory additions and removals.
enum NativeRFInstalledModelIdentity {
    private struct FileVersion: Equatable {
        let url: URL
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let changeSeconds: Int
        let changeNanos: Int
        let modifiedSeconds: Int
        let modifiedNanos: Int
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var values: [URL: (files: [FileVersion], digest: String)] = [:]
    }
    private static let state = State()

    private static func files(at root: URL) throws -> [FileVersion] {
        var scanError: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, error in scanError = error; return false }) else {
            throw NativeRFDETRLayoutError.modelUnavailable
        }
        var files: [FileVersion] = []
        for case let url as URL in iterator {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw NativeRFDETRLayoutError.modelUnavailable }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR { continue }
            guard kind == S_IFREG else { throw NativeRFDETRLayoutError.modelUnavailable }
            files.append(FileVersion(url: url, device: info.st_dev, inode: info.st_ino, size: info.st_size,
                changeSeconds: info.st_ctimespec.tv_sec, changeNanos: info.st_ctimespec.tv_nsec,
                modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec))
        }
        if let scanError { throw scanError }
        guard !files.isEmpty else { throw NativeRFDETRLayoutError.modelUnavailable }
        return files.sorted { $0.url.path < $1.url.path }
    }

    static func canonicalURL(_ input: URL) throws -> URL {
        guard let path = realpath(input.path, nil) else { throw NativeRFDETRLayoutError.modelUnavailable }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    static func digest(_ input: URL) throws -> String {
        let url = try canonicalURL(input)
        state.lock.lock(); defer { state.lock.unlock() }
        let before = try files(at: url)
        if let cached = state.values[url], cached.files == before { return cached.digest }
        var hash = SHA256()
        for file in before {
            try Task.checkCancellation()
            guard file.url.path.hasPrefix(url.path + "/") else { throw NativeRFDETRLayoutError.modelUnavailable }
            let relative = String(file.url.path.dropFirst(url.path.count + 1))
            hash.update(data: Data("\(relative.utf8.count):\(relative):\(file.size):".utf8))
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            while try autoreleasepool(invoking: {
                guard let block = try handle.read(upToCount: 1_048_576), !block.isEmpty else { return false }
                hash.update(data: block)
                return true
            }) {}
        }
        guard try files(at: url) == before else { throw NativeRFDETRLayoutError.modelUnavailable }
        let value = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if state.values.count >= 8 { state.values.removeAll() }
        state.values[url] = (before, value)
        return value
    }
}

/// Process-launch flag, shared by every iOS/macOS caller and detached task.
/// Read once. Exact-output reuse is shared by default after native parity checks.
/// Explicit 0 (or an unrecognized override) retains the original direct route.
enum NativeRFRawCachePolicy {
    static let enabled = ProcessInfo.processInfo.environment["AIDOKU_RF_RAW_CACHE"].map { $0 == "1" } ?? true
    static func select<Value>(direct: () throws -> Value, cached: () throws -> Value) rethrows -> Value {
        if enabled { return try cached() }
        return try direct()
    }
}
 
/// Bounded compact counters only. Never stores images, arrays, tensors or page IDs.
@available(iOS 18.0, macOS 15.0, *)
enum NativeRFRawCacheDiagnostics {
    private struct Row {
        let key: NativeRFRawRequestCache.Key
        var counters: [String: Int] = [:]
        var consumers: [String: Int] = [:]
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var rows: [NativeRFRawRequestCache.Key: Row] = [:]
        var order: [NativeRFRawRequestCache.Key] = []
    }
    private static let state = State()
    static func event(_ key: NativeRFRawRequestCache.Key, _ name: String,
                      maximumMasks: Int? = nil, retainAll: Bool? = nil) {
        guard NativeRFRawCachePolicy.enabled else { return }
        state.lock.lock(); defer { state.lock.unlock() }
        var row = state.rows[key] ?? Row(key: key)
        row.counters[name, default: 0] += 1
        if let maximumMasks, let retainAll {
            row.consumers["cap\(maximumMasks):retainAll\(retainAll)", default: 0] += 1
        }
        state.rows[key] = row
        state.order.removeAll { $0 == key }; state.order.append(key)
        while state.order.count > 32 { state.rows.removeValue(forKey: state.order.removeFirst()) }
    }
    static func snapshot(sourceIdentity: String) -> [String: Any] {
        guard NativeRFRawCachePolicy.enabled else { return [:] }
        state.lock.lock(); defer { state.lock.unlock() }
        let rows = state.order.compactMap { key -> [String: Any]? in
            guard key.sourceRGBIdentity == sourceIdentity, let row = state.rows[key] else { return nil }
            return ["sourceRGBIdentity": key.sourceRGBIdentity,
                "installedModelTreeSHA256": key.installedModelTreeSHA256,
                "weightsSHA256": key.expectedWeightsSHA256, "sourceRevision": key.sourceRevision,
                "preprocessVersion": key.preprocessVersion, "tensorContractVersion": key.tensorContractVersion,
                "computeUnits": key.computeUnits, "runtimeVersion": key.runtimeVersion,
                "decoderVersion": "selected160-sigmoid-thresholds-ties-sourcecoords-v1",
                "native17Schema": NativeRFDETRSourceSupportGrid.schema,
                "counters": row.counters, "consumerMaskConfigurations": row.consumers]
        }
        return ["schema": "native-rf-raw-cache-counters-v1", "enabled": true,
                "sourceIdentity": sourceIdentity, "rawContracts": rows,
                "retainedPayloadBudgetBytes": NativeRFRawRequestCache.defaultBudgetBytes,
                "maximumRetainedEntries": 2,
                "payloadScope": "hashes, ABI strings and counters only; no RGB, tensors or model output"]
    }
}
