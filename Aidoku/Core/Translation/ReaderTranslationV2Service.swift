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
    /// Bump whenever V2 output for the same page/settings can change.
    static let version = "v2-pipeline-1"

    enum Failure: Error { case imageUnavailable, encodingFailed }

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
    private var modelGeneration: UInt64 = 0
    /// Non-LLM compute admission: S1-S4 (before the provider call) and the back
    /// work have separate slots. The back slot brackets the overlapped S8/S6/S7
    /// (which run during the provider call) and, separately, the S9/S10 tail; it
    /// is never held while merely waiting for the provider.
    nonisolated let frontSlots: V2ComputeSlots
    nonisolated let backSlots: V2ComputeSlots
    /// Coalesced page work (visible demand joins and promotes a look-ahead).
    private var inflight: [String: Flight] = [:]

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
        frontSlots: Int = 2, backSlots: Int = 2
    ) {
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
                Task { await self.releaseModels() }
            }
        }
    }

    deinit { memoryObserver.map(NotificationCenter.default.removeObserver) }

    // MARK: Models

    var hasResidentModels: Bool { models != nil }

    /// Loads every V2 model once per session (lazily, off the cooperative pool).
    func residentModels() async throws -> V2Models {
        if let models { return models }
        if let loading { return try await loading.value }
        let generation = modelGeneration
        let loader = loadModels
        let task = Task.detached(priority: .userInitiated) { try loader() }
        loading = task
        do {
            let loaded = try await task.value
            if modelGeneration == generation {
                models = loaded
                loading = nil
            }
            return loaded
        } catch {
            if modelGeneration == generation { loading = nil }
            throw error
        }
    }

    /// Reader-open warm-up; failures surface on the first page instead.
    func prewarm() async { _ = try? await residentModels() }

    /// Memory pressure: drop the resident set. Pages already running keep their
    /// own reference until they finish; the next page reloads lazily.
    func releaseModels() {
        modelGeneration &+= 1
        models = nil
        loading = nil
    }

    // MARK: Cache identity

    static func cacheKey(page: String, crop: CGRect, settings: ReaderTranslationSettings) -> String {
        let config = settings.configuration
        let identity = ReaderTranslationCacheIdentity.encoded([
            version, page,
            [crop.minX, crop.minY, crop.width, crop.height].map { String(Double($0)) }.joined(separator: ","),
            config.provider.rawValue, config.apiProtocol.rawValue, config.baseURL, config.model,
            config.credentialAccount, String(config.credentialGeneration), config.reasoningEffort.rawValue,
            config.instructions, settings.sourceLanguage, settings.targetLanguage,
            TranslationHTTPCodec.letteringPolicy, TranslationHTTPCodec.sfxPolicy, TranslationHTTPCodec.backgroundPolicy,
            ReaderTranslationCacheIdentity.encoded(ReaderTranslationLanguageFilter.identity(settings: settings) ?? []),
            ReaderTranslationLanguageFilter.v2SourcePolicy
        ])
        // Distinct prefix: legacy and V2 rows can never be read as each other.
        return "v2-" + version + "-" + identity
    }

    private static func imageKey(_ key: String) -> String { key + "-image" }
    private static func blocksKey(_ key: String) -> String { key + "-blocks" }

    // MARK: Pages

    struct PageOutput: Sendable {
        let image: CGImage
        let timings: V2Timings?
        let fromCache: Bool
    }

    /// Translates one upright page and returns the fully rendered page bitmap.
    /// Concurrent calls for the same cache key share one computation; a
    /// foreground caller promotes a running look-ahead. The shared work is
    /// cancelled when its last consumer is cancelled.
    func translatePage(
        _ source: CGImage, cacheKey key: String?, settings: ReaderTranslationSettings,
        priority: TranslationRequestPriority = .foreground
    ) async throws -> PageOutput {
        try Task.checkCancellation()
        guard let key else { return try await compute(source, key: nil, settings: settings, priority: priority) }
        let flight: Flight
        if let existing = inflight[key] {
            flight = existing
        } else {
            let promotion = TranslationRequestPromotion()
            let task = Task { [weak self] () throws -> PageOutput in
                guard let self else { throw CancellationError() }
                return try await self.compute(source, key: key, settings: settings, priority: .promotable(promotion))
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

    var inflightCount: Int { inflight.count }
    func consumerCount(_ key: String) -> Int { inflight[key]?.consumers ?? 0 }

    private func compute(
        _ source: CGImage, key: String?, settings: ReaderTranslationSettings, priority: TranslationRequestPriority
    ) async throws -> PageOutput {
        try Task.checkCancellation()
        let cache = key == nil ? nil : diskCache
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
        // Memory admission (reclaims caches/legacy OCR runtimes when short).
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
        let page = V2Page(id: key ?? UUID().uuidString, image: source)
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
                    return try await translate(eligible, CGSize(width: page.width, height: page.height),
                                               settings, jpeg, priority)
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
        if let key, let cache, result.failure == nil {
            // JPEG encoding and the disk write run after the page is returned for display.
            let blocks = result.blocks
            let storesBlocks = replayBlocks == nil
            Task.detached(priority: .utility) {
                if storesBlocks, let translationGeneration, let data = try? JSONEncoder().encode(blocks) {
                    try? await cache.store(data, for: Self.blocksKey(key), kind: .translation, generation: translationGeneration)
                }
                if let layoutGeneration, let data = Self.encode(output) {
                    try? await cache.store(data, for: Self.imageKey(key), kind: .layout, generation: layoutGeneration)
                }
            }
        }
        return PageOutput(image: output, timings: result.timings, fromCache: false)
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

    var waitingCount: Int { lock.withLock { waiters.count } }
    var availableCount: Int { lock.withLock { available } }

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

    func releaseFront() {
        let release = lock.withLock { () -> Bool in
            defer { holdsFront = false }
            return holdsFront
        }
        if release { front.release() }
    }

    func releaseBack() {
        let release = lock.withLock { () -> Bool in
            defer { holdsBack = false }
            return holdsBack
        }
        if release { back.release() }
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
