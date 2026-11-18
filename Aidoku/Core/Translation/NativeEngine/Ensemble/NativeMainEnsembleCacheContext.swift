import CoreGraphics
import Foundation

/// One live page scope shared by the main ensemble, source palette bridge and
/// downstream painter. No inference, global residency, rendering or file access.
/// promptVersion: technical-review-v1 + main-integration-v1.
final class NativeMainEnsembleCacheContext {
    static let evidenceKey = "nativeMainEnsembleCacheContext"

    struct Configuration {
        var enabled = true
        var paletteMemoEnabled = true
        var neutralShellMemoEnabled = true
        var pixelBuffersEnabled = true
        var regionIndexEnabled = true
        var pixelCacheMiB: Double = 96
        var pixelCacheEntries = 256
        var regionCacheMiB: Double = 16
        var regionCacheEntries = 512
        var gridSide = 24
        var rfMinConfidence: Double = 0.5

        /// Each flag independently restores the corresponding uncached behavior.
        /// A budget limits retained cache payload, not consumer/CGContext memory.
        static func numeric(_ parameters: [String: Double]) -> Configuration {
            var result = Configuration()
            func number(_ key: String, _ fallback: Double) -> Double {
                guard let v = parameters[key], v.isFinite else { return fallback }
                return v
            }
            result.enabled = number("enabled", 1) > 0
            result.paletteMemoEnabled = number("paletteMemoEnabled", 1) > 0
            result.neutralShellMemoEnabled = number("neutralShellMemoEnabled", 1) > 0
            result.pixelBuffersEnabled = number("pixelBuffersEnabled", 1) > 0
            result.regionIndexEnabled = number("regionIndexEnabled", 1) > 0
            result.pixelCacheMiB = min(1024, max(0, number("pixelCacheMiB", 96)))
            result.pixelCacheEntries = Int(min(4096, max(0, number("pixelCacheEntries", 256))))
            result.regionCacheMiB = min(512, max(1, number("regionCacheMiB", 16)))
            result.regionCacheEntries = Int(min(8192, max(1, number("regionCacheEntries", 512))))
            result.gridSide = Int(min(64, max(4, number("gridSide", 24))))
            result.rfMinConfidence = min(1, max(0, number("rfMinConfidence", 0.5)))
            return result
        }
    }

    private enum ObservationStage: String { case sourcePalette, neutralShell }
    private struct MemoKey: Hashable {
        let stage: ObservationStage
        let valueType: ObjectIdentifier
    }
    private struct MemoSlot {
        let object: Any
        let valueTypeName: String
        let close: () -> Void
        let statistics: () -> [String: Int]

        func summary(stage: ObservationStage) -> [String: Any] {
            ["stage": stage.rawValue, "valueType": valueTypeName, "counts": statistics()]
        }
    }

    let configuration: Configuration
    let pixelCache: NativeEnsembleCachePixels
    private let lock = NSLock()
    private var page: Ensemble100Page?
    private var memos: [MemoKey: MemoSlot] = [:]
    private var regions: NativeEnsembleCacheRegions?
    private var finalMemoStatistics: [[String: Any]] = []
    private var finalRegionStatistics: [String: Int] = [:]

    init(page: Ensemble100Page, configuration: Configuration = Configuration()) {
        self.page = page
        self.configuration = configuration
        pixelCache = NativeEnsembleCachePixels(maxCacheMiB: configuration.pixelCacheMiB,
            maxEntries: configuration.pixelCacheEntries,
            enabled: configuration.enabled && configuration.pixelBuffersEnabled)
    }

    deinit { close() }

    /// Preserve every item/pixel/evidence field, adding only in-memory handles.
    /// Call again with a new mask/restoration when appropriate; pixel keys include
    /// actual image identity and regionIndex(for:) checks the complete snapshot.
    func attaching(to input: Ensemble100Page) -> Ensemble100Page {
        lock.lock()
        let compatible = page?.original === input.original
        lock.unlock()
        guard compatible else { return input }
        var evidence = input.savedEvidence
        evidence[Self.evidenceKey] = self
        evidence[NativeEnsembleCachePixels.evidenceKey] = pixelCache
        return Ensemble100Page(sourceSHA256: input.sourceSHA256, original: input.original,
            restored: input.restored, removalMask: input.removalMask, viewport: input.viewport,
            items: input.items, rfRegions: input.rfRegions, savedEvidence: evidence)
    }

    static func from(_ page: Ensemble100Page) -> NativeMainEnsembleCacheContext? {
        page.savedEvidence[evidenceKey] as? NativeMainEnsembleCacheContext
    }

    static func withPage<Result>(_ page: Ensemble100Page, configuration: Configuration = Configuration(),
                                _ body: (Ensemble100Page, NativeMainEnsembleCacheContext) throws -> Result) rethrows -> Result {
        let context = NativeMainEnsembleCacheContext(page: page, configuration: configuration)
        defer { context.close() }
        return try body(context.attaching(to: page), context)
    }

    /// The generic value type keeps this helper independent of palette renderer
    /// implementation files. ONE typed memo per stage is shared by all consumers.
    /// Follow NativeEnsembleObservationMemo.inputContractVersion when computing.
    func sourcePalette<Value>(original: CGImage, bounds: [Double], polygon: [[Double]]?,
                              opaqueDependencies: Data? = nil,
                              compute: () throws -> Value) rethrows -> Value {
        guard let memo: NativeEnsembleObservationMemo<Value> = memo(for: .sourcePalette) else { return try compute() }
        return try memo.value(original: original, bounds: bounds, polygon: polygon,
            opaqueDependencies: opaqueDependencies, compute: compute)
    }

    func neutralShell<Value>(original: CGImage, bounds: [Double], polygon: [[Double]]?,
                             compute: () throws -> Value) rethrows -> Value {
        guard let memo: NativeEnsembleObservationMemo<Value> = memo(for: .neutralShell) else { return try compute() }
        return try memo.value(original: original, bounds: bounds, polygon: polygon, compute: compute)
    }

    /// Prefer these optional-context adapters over `context?.observe(...) ?? ...`:
    /// Optional.none can itself be a completed and cached neutral-shell result.
    static func sourcePalette<Value>(context: NativeMainEnsembleCacheContext?, original: CGImage,
                                     bounds: [Double], polygon: [[Double]]?,
                                     opaqueDependencies: Data? = nil,
                                     compute: () throws -> Value) rethrows -> Value {
        if let context {
            return try context.sourcePalette(original: original, bounds: bounds, polygon: polygon,
                opaqueDependencies: opaqueDependencies, compute: compute)
        }
        return try compute()
    }

    static func neutralShell<Value>(context: NativeMainEnsembleCacheContext?, original: CGImage,
                                    bounds: [Double], polygon: [[Double]]?,
                                    compute: () throws -> Value) rethrows -> Value {
        if let context { return try context.neutralShell(original: original, bounds: bounds, polygon: polygon, compute: compute) }
        return try compute()
    }

    /// Lazy geometry-only preparation; no eager source/mask decode or model warmup.
    /// RF support remains unverified model evidence, never permission to drop OCR.
    /// A nil/closed index or index error requires the existing consumer fallback.
    func regionIndex(for input: Ensemble100Page) -> NativeEnsembleCacheRegions? {
        lock.lock()
        let compatible = page?.original === input.original
        let previous = regions
        lock.unlock()
        guard compatible, configuration.enabled, configuration.regionIndexEnabled else { return nil }
        if let previous, previous.matches(input) { return previous }
        let next = NativeEnsembleCacheRegions(input, parameters: [
            "maxCacheMiB": configuration.regionCacheMiB, "maxEntries": Double(configuration.regionCacheEntries),
            "gridSide": Double(configuration.gridSide), "rfMinConfidence": configuration.rfMinConfidence
        ])
        lock.lock()
        guard page != nil else { lock.unlock(); next.close(); return nil }
        let replaced = regions
        regions = next
        lock.unlock()
        replaced?.close()
        return next
    }

    var statistics: [String: Any] {
        lock.lock()
        let slots = Array(memos)
        let region = regions
        let memoFinal = finalMemoStatistics
        let regionFinal = finalRegionStatistics
        let active = page != nil
        lock.unlock()
        let observationStats: [[String: Any]] = slots.map { key, slot in
            slot.summary(stage: key.stage)
        }
        return ["active": active, "pixels": pixelCache.statistics,
                "observations": active ? observationStats : memoFinal,
                "regions": region?.statistics ?? regionFinal,
                "observationInputContract": NativeEnsembleObservationMemo<Int>.inputContractVersion]
    }

    func close() {
        lock.lock()
        guard page != nil else { lock.unlock(); return }
        page = nil
        let slots = Array(memos)
        let region = regions
        memos.removeAll(keepingCapacity: false)
        regions = nil
        lock.unlock()
        // No context lock is held while entering a child cache/callback lock.
        var summaries: [[String: Any]] = []
        for (key, slot) in slots {
            slot.close()
            summaries.append(slot.summary(stage: key.stage))
        }
        region?.close()
        let regionStats = region?.statistics ?? [:]
        pixelCache.close()
        lock.lock()
        finalMemoStatistics = summaries
        finalRegionStatistics = regionStats
        lock.unlock()
    }

    private func memo<Value>(for stage: ObservationStage) -> NativeEnsembleObservationMemo<Value>? {
        lock.lock(); defer { lock.unlock() }
        guard let page else { return nil }
        let key = MemoKey(stage: stage, valueType: ObjectIdentifier(Value.self))
        if let stored = memos[key]?.object as? NativeEnsembleObservationMemo<Value> { return stored }
        let stageEnabled = stage == .sourcePalette ? configuration.paletteMemoEnabled : configuration.neutralShellMemoEnabled
        let memo = NativeEnsembleObservationMemo<Value>(original: page.original, enabled: configuration.enabled && stageEnabled)
        memos[key] = MemoSlot(object: memo, valueTypeName: String(reflecting: Value.self),
            close: { memo.close() }, statistics: { memo.statistics })
        return memo
    }
}
