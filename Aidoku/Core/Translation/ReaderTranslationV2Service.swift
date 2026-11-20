import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// App-side owner of the opt-in speed-first V2 page pipeline
/// (`Core/Translation/V2`, see Docs/translation-v2.md). The V2 folder itself
/// stays platform-neutral so the Mac host compiles it unchanged; this file
/// adds the iOS resource policy, the live provider call, page admission and
/// the durable cache. Results are fully rendered page bitmaps.
@available(iOS 18.0, *)
actor ReaderTranslationV2Service {
    static let shared = ReaderTranslationV2Service()
    /// Bump whenever the translated blocks for the same page/settings can change (S1-S5:
    /// OCR, grouping, request or response handling). Keys both cache rows.
    static let version = "v2-pipeline-1"
    /// Bump whenever only the rendering can change (S6-S10 and the S4b lettering boxes): the
    /// image row is re-rendered from the stored blocks without a new provider call.
    static let renderVersion = "v2-render-2"

    enum Failure: Error { case imageUnavailable }

    struct PoolSizes: Equatable, Sendable {
        var recognizer: Int
        var detector: Int
        var inpainter: Int
    }

    /// iOS pools: recognizer 2 (3 at >= 7 GB physical memory), detector 1-2, AOT 1.
    static func poolSizes(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> PoolSizes {
        let large = physicalMemory >= 7 * 1_024 * 1_024 * 1_024
        return PoolSizes(recognizer: large ? 3 : 2, detector: large ? 2 : 1, inpainter: 1)
    }

    typealias ModelLoader = @Sendable () throws -> V2Models
    typealias BlockTranslator = @Sendable (
        _ blocks: [V2Block], _ pageSize: CGSize, _ settings: ReaderTranslationSettings, _ imageJPEG: Data?,
        _ priority: TranslationRequestPriority
    ) async throws -> [V2Block]

    private let loadModels: ModelLoader
    private let translateBlocks: BlockTranslator
    private let diskCache: ReaderTranslationDiskCache?
    private var models: V2Models?
    private var loading: Task<V2Models, Error>?
    private var loadID: UInt64 = 0
    private var modelGeneration: UInt64 = 0
    /// The last released set while a running page still holds it. Reused instead of
    /// loading a second copy next to it (release happens under memory pressure).
    private weak var retiredModels: V2Models?
    /// Non-LLM compute admission: S1-S4 (before the provider call) and the back
    /// work have separate slots. The back slot brackets the overlapped S8/S6/S7
    /// (which run during the provider call) and, separately, the S9/S10 tail; it
    /// is never held while merely waiting for the provider.
    nonisolated let frontSlots: V2ComputeSlots
    nonisolated let backSlots: V2ComputeSlots
    /// Coalesced page work (visible demand joins and promotes a look-ahead).
    private var inflight: [String: Flight] = [:]
    /// Finished bitmaps by cache key, including pages that are never written
    /// to disk (temporary sessions), so scrolling back reuses them.
    private var memory = V2PageMemoryCache()
    private let availableMemory: @Sendable () -> UInt64
    private let memoryProfile: V2PerformanceProfile

    private final class Flight {
        let task: Task<PageOutput, Error>
        let promotion: TranslationRequestPromotion
        var consumers = 0
        var cancelledConsumers = 0
        init(task: Task<PageOutput, Error>, promotion: TranslationRequestPromotion) {
            self.task = task
            self.promotion = promotion
        }
    }
    private var memoryObserver: NSObjectProtocol?

    init(
        loadModels: @escaping ModelLoader = {
            let sizes = ReaderTranslationV2Service.poolSizes()
            return try V2Models.load(bundle: .main, detectorInstances: sizes.detector, inpainterInstances: sizes.inpainter)
        },
        translateBlocks: @escaping BlockTranslator = { blocks, size, settings, jpeg, priority in
            try await ReaderTranslationService.shared.translateV2(blocks, pageSize: size, settings: settings,
                                                                   imageJPEG: jpeg, priority: priority)
        },
        diskCache: ReaderTranslationDiskCache? = .shared,
        observesMemoryWarnings: Bool = true,
        frontSlots: Int = V2PerformanceProfile.current.frontSlots, backSlots: Int = V2PerformanceProfile.current.backSlots,
        availableMemory: @escaping @Sendable () -> UInt64 = { ProcessMemory.available() },
        memoryProfile: V2PerformanceProfile = .current
    ) {
        self.availableMemory = availableMemory
        self.memoryProfile = memoryProfile
        self.frontSlots = V2ComputeSlots(count: frontSlots)
        self.backSlots = V2ComputeSlots(count: backSlots)
        self.loadModels = loadModels
        self.translateBlocks = translateBlocks
        self.diskCache = diskCache
        if observesMemoryWarnings {
            memoryObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.releaseModels()
                    await self.clearMemory()
                }
            }
        }
    }

    deinit { memoryObserver.map(NotificationCenter.default.removeObserver) }

    // MARK: Models

    /// Loads every V2 model once per session (lazily, off the cooperative pool).
    func residentModels() async throws -> V2Models {
        if let models { return models }
        if let retiredModels {
            models = retiredModels
            return retiredModels
        }
        // A load that was running when the set was released is still joined: it cannot be
        // stopped, and starting another would hold two model sets at once.
        if let loading { return try await loading.value }
        let generation = modelGeneration
        let loader = loadModels
        let task = Task.detached(priority: .userInitiated) { try loader() }
        loading = task
        loadID &+= 1
        let id = loadID
        do {
            let loaded = try await task.value
            if loadID == id { loading = nil }
            if modelGeneration == generation, models == nil {
                models = loaded
            } else if models == nil {
                retiredModels = loaded
            }
            return loaded
        } catch {
            if loadID == id { loading = nil }
            throw error
        }
    }

    /// Reader-open warm-up; failures surface on the first page instead.
    func prewarm() async { _ = try? await residentModels() }

    /// Memory pressure: drop the resident set. Pages already running keep their
    /// own reference until they finish (a page starting meanwhile reuses it); the
    /// next page after that reloads lazily.
    func releaseModels() {
        modelGeneration &+= 1
        if let models { retiredModels = models }
        models = nil
    }

    /// Drops the in-memory page bitmaps (memory pressure; settings reset).
    func clearMemory() { memory.removeAll() }

    // MARK: Cache identity

    static func cacheKey(page: String, crop: CGRect, settings: ReaderTranslationSettings) -> String {
        let config = settings.configuration
        var parts: [String] = [
            version, page,
            [crop.minX, crop.minY, crop.width, crop.height].map { String(Double($0)) }.joined(separator: ","),
            config.provider.rawValue, config.apiProtocol.rawValue, config.baseURL, config.model,
            config.credentialAccount, String(config.credentialGeneration), config.reasoningEffort.rawValue,
            config.instructions, settings.sourceLanguage, settings.targetLanguage,
            TranslationHTTPCodec.letteringPolicy, TranslationHTTPCodec.sfxPolicy, TranslationHTTPCodec.backgroundPolicy,
            ReaderTranslationCacheIdentity.encoded(ReaderTranslationLanguageFilter.identity(settings: settings) ?? []),
            ReaderTranslationLanguageFilter.v2SourcePolicy
        ]
        // Right-to-left adds nothing, so rows cached before direction-aware
        // ordering (always right-to-left) stay valid.
        if settings.readingDirection != .rightToLeft { parts.append("direction:" + settings.readingDirection.rawValue) }
        let identity = ReaderTranslationCacheIdentity.encoded(parts)
        // Distinct prefix: legacy and V2 rows can never be read as each other.
        return "v2-" + version + "-" + identity
    }

    private static func imageKey(_ key: String) -> String { key + "-image-" + renderVersion }
    private static func blocksKey(_ key: String) -> String { key + "-blocks" }

    // MARK: Pages

    struct PageOutput: Sendable {
        let image: CGImage
        let timings: V2Timings?
        let fromCache: Bool
    }

    /// A finished page without computing: the in-memory bitmap, then (for
    /// persisted pages) the disk row. Used to present a cached translation in
    /// the same commit as the source image, so the source never flashes.
    func cachedPage(cacheKey key: String, persists: Bool = true) async -> CGImage? {
        if let image = memory.image(for: key) { return image }
        guard persists, let diskCache, let data = try? await diskCache.data(for: Self.imageKey(key), kind: .layout),
              let image = Self.decode(data) else { return nil }
        remember(image, for: key)
        return image
    }

    private func remember(_ image: CGImage, for key: String) {
        let limit = V2PageMemoryCache.byteLimit(available: availableMemory(), current: memory.bytes, profile: memoryProfile)
        memory.insert(image, for: key, limit: limit)
    }

    /// Translates one upright page and returns the fully rendered page bitmap.
    /// Concurrent calls for the same cache key share one computation; a
    /// foreground caller promotes a running look-ahead. The shared work is
    /// cancelled when its last consumer is cancelled. `persists == false`
    /// (temporary pages) keeps the result in memory only.
    func translatePage(
        _ source: CGImage, cacheKey key: String?, persists: Bool = true, settings: ReaderTranslationSettings,
        priority: TranslationRequestPriority = .foreground
    ) async throws -> PageOutput {
        try Task.checkCancellation()
        guard let key else { return try await compute(source, key: nil, persists: false, settings: settings, priority: priority) }
        if let image = memory.image(for: key) { return PageOutput(image: image, timings: nil, fromCache: true) }
        let flight: Flight
        if let existing = inflight[key] {
            flight = existing
        } else {
            let promotion = TranslationRequestPromotion()
            let task = Task { [weak self] () throws -> PageOutput in
                guard let self else { throw CancellationError() }
                let output = try await self.compute(source, key: key, persists: persists, settings: settings,
                                                    priority: .promotable(promotion))
                await self.remember(output.image, for: key)
                return output
            }
            flight = Flight(task: task, promotion: promotion)
            inflight[key] = flight
        }
        if priority.isForeground { flight.promotion.promote() }
        flight.consumers += 1
        defer { leave(key, flight) }
        return try await withTaskCancellationHandler {
            try await flight.task.value
        } onCancel: {
            Task { await self.consumerCancelled(key, flight) }
        }
    }

    private func consumerCancelled(_ key: String, _ flight: Flight) {
        // Count the cancellation now so the shared work stops immediately
        // when nobody is left, without waiting for the awaiting consumer.
        flight.cancelledConsumers += 1
        if flight.consumers - flight.cancelledConsumers <= 0 {
            flight.task.cancel()
            if inflight[key] === flight { inflight[key] = nil }
        }
    }

    private func leave(_ key: String, _ flight: Flight) {
        flight.consumers -= 1
        if flight.consumers <= 0, inflight[key] === flight { inflight[key] = nil }
    }

    func consumerCount(_ key: String) -> Int { inflight[key]?.consumers ?? 0 }

    private func compute(
        _ source: CGImage, key: String?, persists: Bool, settings: ReaderTranslationSettings, priority: TranslationRequestPriority
    ) async throws -> PageOutput {
        try Task.checkCancellation()
        let cache = key == nil || !persists ? nil : diskCache
        if let key, let cache, let data = try? await cache.data(for: Self.imageKey(key), kind: .layout),
           let image = Self.decode(data) {
            try Task.checkCancellation()
            return PageOutput(image: image, timings: nil, fromCache: true)
        }
        var storedBlocks: [V2Block]?
        if let key, let cache, let data = try? await cache.data(for: Self.blocksKey(key), kind: .translation) {
            storedBlocks = try? JSONDecoder().decode([V2Block].self, from: data)
        }
        let replayBlocks = storedBlocks
        try Task.checkCancellation()
        let translationGeneration = await cache?.currentGeneration(settings: settings, kind: .translation)
        let layoutGeneration = await cache?.currentGeneration(settings: settings, kind: .layout)
        // Memory admission (reclaims caches and models when short).
        try await TranslationImageWorkBudget.shared.withPermit(
            priority: priority,
            decodedBytes: TranslationImageWorkBudget.decodedBytes(width: UInt64(source.width), height: UInt64(source.height))
        ) {}
        let models = try await residentModels()
        let translate = translateBlocks
        let failure = V2TranslationFailureBox()
        let hold = V2SlotHold(front: frontSlots, back: backSlots)
        defer { hold.releaseAll() }
        try await hold.acquireFront(priority: priority)
        let page = V2Page(id: key ?? UUID().uuidString, image: source, readingDirection: settings.readingDirection)
        // The provider only receives the page JPEG when the setting asks for it; encode it
        // concurrently with S1-S4 so it is ready when S5 starts.
        let jpegTask: Task<Data, Error>? = replayBlocks == nil && settings.includePageImage
            ? Task.detached(priority: .userInitiated) {
                try ReaderTranslationImagePreparation.translationJPEG(UIImage(cgImage: source))
            } : nil
        defer { jpegTask?.cancel() }
        let translator: V2Translator = { page, blocks in
            do {
                if let replayBlocks { return Self.replay(replayBlocks, onto: blocks) }
                try Task.checkCancellation()
                return try await Self.translateEligible(blocks, settings: settings) { eligible in
                    let jpeg = try await jpegTask?.value
                    try Task.checkCancellation()
                    let pageSize = CGSize(width: page.width, height: page.height)
                    let ids = Set(eligible.map(\.id))
                    // A sent provider request is paid for: when the page is left (cancelled)
                    // while it runs, the call finishes on its own and its translations are
                    // stored, so coming back replays them instead of paying again.
                    let request = Task { () throws -> [V2Block] in
                        let translated = try await translate(eligible, pageSize, settings, jpeg, priority)
                        if let key, let cache, let translationGeneration,
                           let data = try? JSONEncoder().encode(Self.merged(translated, into: blocks, eligible: ids)) {
                            try? await cache.store(data, for: Self.blocksKey(key), kind: .translation,
                                                   generation: translationGeneration)
                        }
                        return translated
                    }
                    return try await V2PaidRequest.awaitUnlessCancelled(request)
                }
            } catch {
                failure.store(error)
                throw error
            }
        }
        let hooks = V2PipelineHooks(
            // S1-S4 are done: free the front slot before the provider call starts.
            frontFinished: { hold.releaseFront() },
            acquireBack: { try await hold.acquireBack(priority: priority) },
            releaseBack: { hold.releaseBack() },
            predictTranslated: { blocks in
                if let replayBlocks {
                    return Set(Self.replay(replayBlocks, onto: blocks).filter(V2Layout.isPaintable).map(\.id))
                }
                return Self.eligibleForTranslation(blocks, settings: settings)
            })
        let result = await V2Pipeline.run(page, models: models, translate: translator, hooks: hooks)
        hold.releaseAll()
        try Task.checkCancellation()
        if let error = failure.error { throw error }
        guard let output = result.output else { throw Failure.imageUnavailable }
        // Paid provider output is kept even when only rendering failed (S7 inpaint, S9
        // placement, back admission), so a retry re-renders without a new provider call.
        let rendered = result.failure == nil
        let translated = rendered || Self.renderOnlyFailure(result.failure)
        if let key, let cache, translated {
            // JPEG encoding and the disk write run after the page is returned for display.
            let blocks = result.blocks
            let storesBlocks = replayBlocks == nil
            Task.detached(priority: .utility) {
                if storesBlocks, let translationGeneration, let data = try? JSONEncoder().encode(blocks) {
                    try? await cache.store(data, for: Self.blocksKey(key), kind: .translation, generation: translationGeneration)
                }
                if rendered, let layoutGeneration, let data = Self.encode(output) {
                    try? await cache.store(data, for: Self.imageKey(key), kind: .layout, generation: layoutGeneration)
                }
            }
        }
        return PageOutput(image: output, timings: result.timings, fromCache: false)
    }

    /// Whether every recorded page failure is in a rendering stage (the blocks are complete).
    static func renderOnlyFailure(_ failure: String?) -> Bool {
        guard let failure else { return true }
        return failure.components(separatedBy: "; ").allSatisfy { part in
            ["s7:", "s9:", "back:"].contains { part.hasPrefix($0) }
        }
    }

    /// Source-language policy (the legacy `ReaderTranslationLanguageFilter`
    /// rule with the manga recognizer, plus shared-Han recall): only eligible blocks
    /// are sent; excluded blocks keep no translation and their source pixels.
    static func eligibleForTranslation(_ blocks: [V2Block], settings: ReaderTranslationSettings) -> Set<Int> {
        Set(V2Translation.translatable(blocks).filter {
            ReaderTranslationLanguageFilter.allowsV2Source($0.sourceText, settings: settings)
        }.map(\.id))
    }

    static func translateEligible(
        _ blocks: [V2Block], settings: ReaderTranslationSettings,
        translate: ([V2Block]) async throws -> [V2Block]
    ) async throws -> [V2Block] {
        let eligible = eligibleForTranslation(blocks, settings: settings)
        guard !eligible.isEmpty else { return blocks }
        let translated = try await translate(blocks.filter { eligible.contains($0.id) })
        return merged(translated, into: blocks, eligible: eligible)
    }

    static func merged(_ translated: [V2Block], into blocks: [V2Block], eligible: Set<Int>) -> [V2Block] {
        let byID = Dictionary(translated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return blocks.map { eligible.contains($0.id) ? byID[$0.id] ?? $0 : $0 }
    }

    /// Reapplies cached translations to a deterministic re-run of the same page.
    static func replay(_ stored: [V2Block], onto blocks: [V2Block]) -> [V2Block] {
        let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return blocks.map { block in
            guard let match = byID[block.id], match.sourceText == block.sourceText else { return block }
            var output = block
            output.translation = match.translation
            output.role = match.role
            return output
        }
    }

    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// Bounded LRU of finished V2 page bitmaps. The normal budget is at least 32 MB, otherwise a quarter
/// of the headroom above the image-work reserve, at most 192 MB (`V2PerformanceProfile` relaxes it in developer builds).
struct V2PageMemoryCache {
    static let minimumBytes = 32 * 1_024 * 1_024
    static let maximumBytes = 192 * 1_024 * 1_024

    private var entries: [String: (image: CGImage, cost: Int)] = [:]
    private var order: [String] = []
    private(set) var bytes = 0
    var count: Int { entries.count }

    static func byteLimit(available: UInt64, current: Int, profile: V2PerformanceProfile = .normal) -> Int {
        let reserve = profile.minimumHeadroom
        let spare = available > reserve ? available - reserve : 0
        let divisor = UInt64(max(1, profile.pageCacheSpareDivisor))
        let allowance = min(UInt64(profile.pageCacheMaximumBytes), spare / divisor + UInt64(max(0, current)) / divisor)
        return max(profile.pageCacheMinimumBytes, Int(allowance))
    }

    static func cost(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    mutating func image(for key: String) -> CGImage? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.image
    }

    mutating func insert(_ image: CGImage, for key: String, limit: Int) {
        let cost = Self.cost(image)
        remove(key)
        guard cost <= limit else { return }
        while bytes + cost > limit, let oldest = order.first { remove(oldest) }
        entries[key] = (image, cost)
        order.append(key)
        bytes += cost
    }

    mutating func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        bytes -= entry.cost
        order.removeAll { $0 == key }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        bytes = 0
    }

    private mutating func touch(_ key: String) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }
}

/// Priority-ordered counting semaphore: foreground (or promoted) waiters are
/// admitted before look-ahead, FIFO within a rank; waiting is cancellable.
final class V2ComputeSlots: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let priority: TranslationRequestPriority
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var available: Int
    private var waiters: [Waiter] = []

    init(count: Int) { available = max(1, count) }

    func acquire(priority: TranslationRequestPriority) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let admitted: Bool = lock.withLock {
                    if available > 0 && waiters.isEmpty {
                        available -= 1
                        return true
                    }
                    waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
                    return false
                }
                if admitted { continuation.resume() }
            }
        } onCancel: {
            let cancelled: Waiter? = lock.withLock {
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    func release() {
        let next: Waiter? = lock.withLock {
            guard !waiters.isEmpty else {
                available += 1
                return nil
            }
            // Ranks are read at release time so a promoted look-ahead jumps ahead.
            var best = 0
            for index in waiters.indices.dropFirst()
            where waiters[index].priority.schedulingRank < waiters[best].priority.schedulingRank {
                best = index
            }
            return waiters.remove(at: best)
        }
        next?.continuation.resume()
    }
}

/// One page's slot ownership across the pipeline's provider boundary.
final class V2SlotHold: @unchecked Sendable {
    private let lock = NSLock()
    private let front: V2ComputeSlots
    private let back: V2ComputeSlots
    private var holdsFront = false
    private var holdsBack = false

    init(front: V2ComputeSlots, back: V2ComputeSlots) {
        self.front = front
        self.back = back
    }

    func acquireFront(priority: TranslationRequestPriority) async throws {
        try await front.acquire(priority: priority)
        lock.withLock { holdsFront = true }
    }

    func acquireBack(priority: TranslationRequestPriority) async throws {
        try await back.acquire(priority: priority)
        lock.withLock { holdsBack = true }
    }

    func releaseFront() { release(\.holdsFront, front) }
    func releaseBack() { release(\.holdsBack, back) }

    private func release(_ held: ReferenceWritableKeyPath<V2SlotHold, Bool>, _ slots: V2ComputeSlots) {
        let release = lock.withLock { () -> Bool in
            defer { self[keyPath: held] = false }
            return self[keyPath: held]
        }
        if release { slots.release() }
    }

    func releaseAll() {
        releaseFront()
        releaseBack()
    }
}

/// Records the provider error so a failed S5 fails the page instead of
/// presenting an untranslated "translated" bitmap.
final class V2TranslationFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var error: Error? { lock.withLock { stored } }
    func store(_ error: Error) { lock.withLock { if stored == nil { stored = error } } }
}

/// Build-time V2 performance profile. Builds compiled with the
/// `AIDOKU_DEVELOPER_PERFORMANCE` condition (`Aidoku/Aidoku.xcconfig`) relax the
/// memory caps that make V2 refuse, wait or evict, and raise page compute,
/// look-ahead and provider concurrency, scaled by physical memory and cores.
/// Every other build (and any test host) uses `normal`, today's values.
/// Live admission still compares against `ProcessMemory.available()`; the
/// developer headroom never drops below `safetyMargin`, and memory warnings
/// still release the models and the page cache.
struct V2PerformanceProfile: Equatable, Sendable {
    /// Image admission: required headroom = max(minimum, decoded * multiplier + reserve).
    var minimumHeadroom: UInt64
    var decodeWorkingMultiplier: UInt64
    var decodeReserve: UInt64
    /// Finished-page LRU: max(minimum, min(maximum, spare / divisor)).
    var pageCacheMinimumBytes: Int
    var pageCacheMaximumBytes: Int
    var pageCacheSpareDivisor: Int
    /// V2 compute slots before (S1-S4) and after (S6-S10) the provider call.
    var frontSlots: Int
    var backSlots: Int
    /// Pages added to the reader's automatic look-ahead count.
    var lookaheadExtraPages: Int
    /// Upper bound on concurrent V2 provider (LLM) requests.
    var providerConcurrencyCap: Int

    private static let mib: UInt64 = 1_024 * 1_024
    private static let gib: UInt64 = 1_024 * mib
    /// Headroom the developer profile never spends.
    static let safetyMargin: UInt64 = 512 * mib

    static let normal = Self(
        minimumHeadroom: 1_280 * mib, decodeWorkingMultiplier: 3, decodeReserve: 512 * mib,
        pageCacheMinimumBytes: 32 * Int(mib), pageCacheMaximumBytes: 192 * Int(mib), pageCacheSpareDivisor: 4,
        frontSlots: 2, backSlots: 2, lookaheadExtraPages: 0, providerConcurrencyCap: 3)

    static var isDeveloperBuild: Bool {
#if AIDOKU_DEVELOPER_PERFORMANCE
        true
#else
        false
#endif
    }

    /// The profile of this process (fixed at first use).
    static let current: Self = {
        let environment = ProcessInfo.processInfo.environment
        let testHost = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        return resolve(developer: isDeveloperBuild && !testHost, physicalMemory: ProcessInfo.processInfo.physicalMemory,
                       processorCount: ProcessInfo.processInfo.activeProcessorCount)
    }()

    /// Pure: the profile for a build flag, physical memory and core count.
    /// Device classes use the physical memory iOS reports (a "6 GB" iPhone
    /// reports about 5.5 GiB); below that class the developer build stays normal.
    static func resolve(developer: Bool, physicalMemory: UInt64, processorCount: Int) -> Self {
        guard developer else { return normal }
        var profile: Self
        if physicalMemory >= 11 * gib {
            profile = Self(
                minimumHeadroom: 640 * mib, decodeWorkingMultiplier: 3, decodeReserve: 256 * mib,
                pageCacheMinimumBytes: 96 * Int(mib), pageCacheMaximumBytes: 768 * Int(mib), pageCacheSpareDivisor: 2,
                frontSlots: 4, backSlots: 4, lookaheadExtraPages: 3, providerConcurrencyCap: 8)
        } else if physicalMemory >= 7 * gib {
            profile = Self(
                minimumHeadroom: 768 * mib, decodeWorkingMultiplier: 3, decodeReserve: 320 * mib,
                pageCacheMinimumBytes: 64 * Int(mib), pageCacheMaximumBytes: 512 * Int(mib), pageCacheSpareDivisor: 3,
                frontSlots: 3, backSlots: 4, lookaheadExtraPages: 2, providerConcurrencyCap: 6)
        } else if physicalMemory >= 5 * gib {
            profile = Self(
                minimumHeadroom: 896 * mib, decodeWorkingMultiplier: 3, decodeReserve: 384 * mib,
                pageCacheMinimumBytes: 64 * Int(mib), pageCacheMaximumBytes: 320 * Int(mib), pageCacheSpareDivisor: 3,
                frontSlots: 3, backSlots: 3, lookaheadExtraPages: 1, providerConcurrencyCap: 4)
        } else {
            return normal
        }
        // Safety clamps: never below the normal values for concurrency, never
        // more compute slots than half the cores, headroom above the margin and
        // the page cache within a sixteenth of physical memory.
        let slotCeiling = max(normal.frontSlots, max(1, processorCount) / 2)
        profile.frontSlots = max(normal.frontSlots, min(profile.frontSlots, slotCeiling))
        profile.backSlots = max(normal.backSlots, min(profile.backSlots, slotCeiling))
        profile.minimumHeadroom = max(safetyMargin, profile.minimumHeadroom)
        profile.decodeReserve = max(safetyMargin / 2, profile.decodeReserve)
        let cacheCeiling = Int(clamping: max(UInt64(normal.pageCacheMaximumBytes), physicalMemory / 16))
        profile.pageCacheMaximumBytes = min(profile.pageCacheMaximumBytes, cacheCeiling)
        profile.pageCacheMinimumBytes = min(profile.pageCacheMinimumBytes, profile.pageCacheMaximumBytes)
        return profile
    }

    /// Image-work headroom for a decode of `decodedBytes` (saturating).
    func requiredHeadroom(decodedBytes: UInt64) -> UInt64 {
        let (working, overflow) = decodedBytes.multipliedReportingOverflow(by: decodeWorkingMultiplier)
        let (total, additionOverflow) = working.addingReportingOverflow(decodeReserve)
        return overflow || additionOverflow ? .max : max(minimumHeadroom, total)
    }

    /// The reader's look-ahead page count for an automatic count.
    func lookaheadCount(automatic: Int) -> Int { automatic + lookaheadExtraPages }

    /// V2 provider concurrency for the user's request-concurrency setting.
    func providerConcurrency(setting: Int) -> Int { max(1, min(providerConcurrencyCap, setting)) }
}

/// Awaits a provider request without cancelling it when the waiting page is cancelled:
/// the waiter throws `CancellationError` at once, the request keeps running (at most
/// `maximumOrphans` at a time; beyond that it is cancelled as before) and stores its result.
enum V2PaidRequest {
    static let maximumOrphans = 2
    private static let orphans = V2OrphanCounter()

    static func awaitUnlessCancelled<T: Sendable>(_ request: Task<T, Error>) async throws -> T {
        let once = V2ResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                once.install(continuation)
                Task {
                    let result = await request.result
                    once.resume(with: result)
                }
            }
        } onCancel: {
            if orphans.adopt(request, limit: maximumOrphans) == false { request.cancel() }
            once.resume(with: .failure(CancellationError()))
        }
    }
}

/// Counts provider requests that outlive their page; each is released when it finishes.
final class V2OrphanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func adopt<T: Sendable>(_ request: Task<T, Error>, limit: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < limit else { return false }
        count += 1
        Task { [weak self] in
            _ = await request.result
            self?.release()
        }
        return true
    }

    private func release() { lock.lock(); count -= 1; lock.unlock() }
}

/// Resumes a continuation exactly once (result or cancellation, whichever comes first),
/// including a resume that arrives before the continuation is installed.
final class V2ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending {
            done = true
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        guard let continuation else { pending = pending ?? result; lock.unlock(); return }
        done = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
