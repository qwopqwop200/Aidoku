import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Scheduling-only optimizations: disk writes never hold the image permit or
/// block the translation worker, and reclaim releases caches before OCR models.
@Suite(.serialized) @MainActor
struct ReaderSchedulingOptimizationTests {
    nonisolated private static let region = ReaderTranslationRegion(id: "one", rect: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.1),
                                                        source: "HELLO WORLD", translation: "번역", sourceOrientation: .horizontal)

    private func settings(_ defaults: UserDefaults) -> ReaderTranslationSettings {
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.maximumConcurrentRequests = 1
        settings.includePageImage = false
        settings.rightToLeftPanelOrder = false
        settings.translationSourceLanguages = []
        return settings
    }

    @Test func recognitionStoreRunsAfterImagePermitIsReleased() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        let settings = settings(defaults)
        let disk = ReaderTranslationDiskCache(directory: root)
        let page = Page(sourceId: "permit-store", chapterId: root.lastPathComponent, index: 0)
        let probe = SchedulingProbe()
        let preloader = ReaderTranslationPreloader(diskCache: disk, translator: { regions, _, _ in
            regions.map { var value = $0; value.translation = "번역"; return value }
        }, recognizer: { page, _ in
            [ReaderTranslationRegion(id: String(page.index), rect: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.1),
                                     source: "HELLO WORLD", sourceOrientation: .horizontal)]
        }, availableMemory: { .max }, storeRecognition: { regions, key, generation in
            // If the OCR permit were still held here, this acquisition could not
            // complete until the store returned.
            let acquired = Task.detached { try await TranslationImageWorkBudget.shared.withPermit { true } }
            let deadline = Date().addingTimeInterval(3)
            let flag = SchedulingFlag()
            Task.detached { if (try? await acquired.value) == true { flag.set() } }
            while !flag.isSet, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            if !flag.isSet { acquired.cancel() }
            await probe.record(permitFree: flag.isSet)
            try? await disk.storeRegions(regions, for: key, kind: .ocr, generation: generation)
        })
        let result = try await preloader.translate(page, settings: settings)
        #expect(result.first?.translation == "번역")
        #expect(await probe.permitFree == [true])
        let key = ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: settings)
        #expect(try await disk.contains(key, kind: .ocr))
    }

    @Test func recognitionIsPersistedWithDefaultStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        let settings = settings(defaults)
        let disk = ReaderTranslationDiskCache(directory: root)
        let page = Page(sourceId: "default-store", chapterId: root.lastPathComponent, index: 0)
        var recognitions = 0
        let counter = SchedulingCounter()
        let preloader = ReaderTranslationPreloader(diskCache: disk, translator: { regions, _, _ in regions }, recognizer: { _, _ in
            await counter.increment()
            return [Self.region]
        }, availableMemory: { .max })
        _ = try await preloader.translate(page, settings: settings)
        recognitions = await counter.value
        #expect(recognitions == 1)
        let key = ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: settings)
        #expect(try await disk.regions(for: key, kind: .ocr)?.map(\.source) == [Self.region.source])
    }

    @Test func translationWritesDoNotBlockWorkerAndPendingValuesPreventDuplicateWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        let settings = settings(defaults)
        let disk = ReaderTranslationDiskCache(directory: root)
        let gate = SchedulingGate()
        let pages = (0..<3).map { Page(sourceId: "pending-store", chapterId: root.lastPathComponent, index: $0) }
        var processed: [Int] = []
        let session = ReaderTranslationSession(process: { page, _, _ in
            processed.append(page.index)
            return [Self.region]
        }, diskCache: disk, availableMemory: { .max }, storeTranslation: { regions, key, generation in
            await gate.wait()
            try? await disk.storeRegions(regions, for: key, kind: .translation, generation: generation)
        })
        defer { session.close(); Task { await gate.release() } }
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "pending-store")
        session.enable(settings: settings)
        // Every page completes while no write has finished.
        try await waitUntil { processed.count == 3 && session.pendingDiskStoreCount == 3 }
        // Dropping memory state must not re-run OCR/API for a page whose write is pending.
        session.suspendWorkForResourcePressure()
        let restored = try await session.cachedRegions(for: pages[0], settings: settings)
        #expect(restored?.first?.translation == Self.region.translation)
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "pending-store")
        session.enable(settings: settings)
        try await Task.sleep(for: .milliseconds(200))
        #expect(processed == [0, 1, 2])
        await gate.release()
        await session.flushPendingDiskStores()
        #expect(session.pendingDiskStoreCount == 0)
        for page in pages {
            let key = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings)
            #expect(try await disk.contains(key, kind: .translation))
        }
        #expect(processed == [0, 1, 2])
    }

    @Test func pendingTranslationWritesAreBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        let settings = settings(defaults)
        let disk = ReaderTranslationDiskCache(directory: root)
        let gate = SchedulingGate()
        let count = ReaderTranslationSession.maximumPendingDiskStores + 4
        let pages = (0..<count).map { Page(sourceId: "bounded-store", chapterId: root.lastPathComponent, index: $0) }
        var processed = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            processed += 1
            return [Self.region]
        }, diskCache: disk, availableMemory: { .max }, storeTranslation: { regions, key, generation in
            await gate.wait()
            try? await disk.storeRegions(regions, for: key, kind: .translation, generation: generation)
        })
        defer { session.close(); Task { await gate.release() } }
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "bounded-store")
        session.enable(settings: settings)
        let limit = ReaderTranslationSession.maximumPendingDiskStores
        try await waitUntil { processed == limit + 1 }
        try await Task.sleep(for: .milliseconds(200))
        // The completed page after the limit waits for the oldest write.
        #expect(processed == limit + 1)
        #expect(session.pendingDiskStoreCount == limit)
        await gate.release()
        try await waitUntil { processed == count }
        await session.flushPendingDiskStores()
        for page in pages {
            let key = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings)
            #expect(try await disk.contains(key, kind: .translation))
        }
    }

    @Test func reclaimPurgesCachesBeforeOCRModels() async {
        let headroom = TranslationImageWorkBudget.minimumHeadroom
        let steps = SchedulingSteps()
        let memory = SchedulingMemory(value: headroom - 1)
        // Caches alone restore headroom: keep warm OCR models.
        var purged = await TranslationImageWorkBudget.reclaimIdleResources(
            requiredHeadroom: headroom, availableMemory: { memory.value },
            purgeCaches: { steps.append("caches"); memory.value = headroom },
            purgeModels: { steps.append("models") })
        #expect(!purged)
        #expect(steps.values == ["caches"])
        // Still short after caches: models are released as before.
        memory.value = headroom - 1
        purged = await TranslationImageWorkBudget.reclaimIdleResources(
            requiredHeadroom: headroom, availableMemory: { memory.value },
            purgeCaches: { steps.append("caches") },
            purgeModels: { steps.append("models") })
        #expect(purged)
        #expect(steps.values == ["caches", "caches", "models"])
    }

    @Test func firstSynchronizationAfterOpenUsesShortDelay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let pages = (0..<3).map { Page(sourceId: "first-sync", chapterId: root.lastPathComponent, index: $0) }
        let owner = SchedulingOwner(pages: pages)
        var validatedAt: TimeInterval?
        let session = ReaderTranslationSession(validate: { _ in
            if validatedAt == nil { validatedAt = ProcessInfo.processInfo.systemUptime }
        }, process: { _, _, _ in [Self.region] }, availableMemory: { .max })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session, readSettings: { settings }, setEnabled: { _ in })
        defer { coordinator.close() }
        let start = ProcessInfo.processInfo.systemUptime
        coordinator.resume()
        try await waitUntil { validatedAt != nil }
        // The conservative navigation debounce is 350 ms.
        #expect(try #require(validatedAt) - start < 0.3)
    }

    private func waitUntil(seconds: Double = 8, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await condition()) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor SchedulingProbe {
    var permitFree: [Bool] = []
    func record(permitFree value: Bool) { permitFree.append(value) }
}

private actor SchedulingCounter {
    var value = 0
    func increment() { value += 1 }
}

private final class SchedulingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class SchedulingSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class SchedulingMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UInt64
    init(value: UInt64) { storage = value }
    var value: UInt64 {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

/// Holds every waiter until released; later waiters pass straight through.
private actor SchedulingGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor private final class SchedulingOwner: UIViewController, ReaderTranslationOwner {
    let translationUpcomingPages: [Aidoku.Page]
    let translationChapterKey = "first-sync"
    private let imageView = UIImageView(image: UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40)).image { _ in })
    let page: ReaderTranslationPage
    var translationVisiblePages: [ReaderTranslationPage] { [page] }

    init(pages: [Aidoku.Page]) {
        translationUpcomingPages = pages
        page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = pages[0]
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
