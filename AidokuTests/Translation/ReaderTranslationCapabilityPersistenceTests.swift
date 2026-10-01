import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationCapabilityPersistenceTests {
    @Test func demandFallbackSurvivesReopen() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = settings()
        let disk = ReaderTranslationDiskCache(directory: root)
        try await disk.synchronizeSettings(settings)
        let page = page(0)
        let session = ReaderTranslationSession(process: { _, settings, _ in
            TranslationImageSupport.shared.record(.unsupported, for: settings.configuration)
            try await disk.synchronizeSettings(settings)
            return [Self.region(0, translated: true)]
        }, diskCache: disk, availableMemory: { .max })
        defer { session.close() }
        session.update(items: [.init(page)], visible: [], context: "capability")
        session.enable(settings: settings)
        try await waitUntil {
            (try? await disk.translatedRegions(page: page.translationCacheKey, settings: settings)) != nil
        }
        await session.flushPendingDiskStores()
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.translatedRegions(page: page.translationCacheKey, settings: settings)?.first?.translation == "문을 열고 들어오세요.")
    }

    @Test func speculativeFallbackSurvivesReopen() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = settings()
        let disk = ReaderTranslationDiskCache(directory: root)
        try await disk.synchronizeSettings(settings)
        let preloader = ReaderTranslationPreloader(diskCache: disk, translator: { regions, settings, _ in
            if regions.first?.id == "0" {
                while true { try await Task.sleep(for: .milliseconds(20)) }
            }
            TranslationImageSupport.shared.record(.unsupported, for: settings.configuration)
            try await disk.synchronizeSettings(settings)
            return [Self.region(1, translated: true)]
        }, recognizer: { page, _ in [Self.region(page.index)] }, availableMemory: { .max })
        preloader.nextPage = { current in current.index == 0 ? page(1) : nil }
        let work = Task { try await preloader.translate(page(0), settings: settings) }
        defer { work.cancel(); preloader.cancel() }
        try await waitUntil {
            (try? await disk.translatedRegions(page: page(1).translationCacheKey, settings: settings)) != nil
        }
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.translatedRegions(page: page(1).translationCacheKey, settings: settings)?.first?.translation == "문을 열고 들어오세요.")
    }

    @Test func firstEnablePreservesSeededTranslationMemory() async throws {
        let settings = settings()
        let cache = ReaderTranslationSessionCache()
        let page = page(0)
        let stored = Self.region(0, translated: true)
        try cache.store([stored], for: page.translationCacheKey)
        var requests = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            requests += 1
            return [Self.region(0, translated: true)]
        }, availableMemory: { .max }, cache: cache)
        defer { session.close() }
        session.update(items: [.init(page)], visible: [], context: "seeded")
        session.enable(settings: settings)
        #expect(cache.regions(for: page.translationCacheKey)?.first?.translation == stored.translation)
        await Task.yield()
        #expect(requests == 0)
    }

    @Test func recoveredImageSupportDiscardsCompletedSessionMemory() async throws {
        let settings = settings()
        TranslationImageSupport.shared.record(.unsupported, for: settings.configuration)
        let cache = ReaderTranslationSessionCache()
        var requests = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            requests += 1
            var result = Self.region(0, translated: true)
            result.translation = requests == 1 ? "텍스트 번역" : "이미지 번역"
            return [result]
        }, availableMemory: { .max }, cache: cache)
        defer { session.close() }
        let page = page(0)
        session.update(items: [.init(page)], visible: [], context: "recovery")
        session.enable(settings: settings)
        try await waitUntil { cache.regions(for: page.translationCacheKey)?.first?.translation == "텍스트 번역" }
        TranslationImageSupport.shared.record(.supported, for: settings.configuration)
        session.refreshImageSupport()
        try await waitUntil { cache.regions(for: page.translationCacheKey)?.first?.translation == "이미지 번역" }
        #expect(requests == 2)
        session.refreshImageSupport()
        #expect(requests == 2)
    }

    @Test func imageLookupRejectsOldMemoryBeforeRecoveryNotification() async throws {
        let settings = settings()
        TranslationImageSupport.shared.record(.unsupported, for: settings.configuration)
        let cache = ReaderTranslationSessionCache()
        let page = page(0)
        let stored = Self.region(0, translated: true)
        try cache.store([stored], for: page.translationCacheKey)
        var requests = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            requests += 1
            return [Self.region(0, translated: true)]
        }, availableMemory: { .max }, cache: cache)
        defer { session.close() }
        session.update(items: [.init(page)], visible: [], context: "before-notification")
        session.enable(settings: settings)
        #expect(try await session.cachedRegions(for: page, settings: settings)?.first?.translation == stored.translation)
        TranslationImageSupport.shared.record(.supported, for: settings.configuration)
        // Deliberately do not refresh the session: notification delivery is queued.
        #expect(try await session.cachedRegions(for: page, settings: settings) == nil)
        #expect(requests == 0, "A cache-only lookup must not start replacement translation")
    }

    @Test func fallbackNotificationPreservesActiveRequest() async throws {
        let settings = settings()
        let cache = ReaderTranslationSessionCache()
        var requests = 0
        var cancelled = 0
        var session: ReaderTranslationSession!
        session = ReaderTranslationSession(process: { _, settings, _ in
            requests += 1
            TranslationImageSupport.shared.record(.unsupported, for: settings.configuration)
            session.refreshImageSupport()
            try Task.checkCancellation()
            return [Self.region(0, translated: true)]
        }, cancelProcessing: { cancelled += 1 }, availableMemory: { .max }, cache: cache)
        defer { session.close(); session = nil }
        let page = page(0)
        session.update(items: [.init(page)], visible: [], context: "fallback")
        session.enable(settings: settings)
        let initialCancellations = cancelled
        try await waitUntil { cache.regions(for: page.translationCacheKey)?.first?.translation != nil }
        #expect(requests == 1)
        #expect(cancelled == initialCancellations)
    }

    @Test func clearRejectsFallbackWrite() async throws {
        try await rejectsStaleWrite(change: .clear)
    }

    @Test func settingsChangeRejectsFallbackWrite() async throws {
        try await rejectsStaleWrite(change: .settings)
    }

    @Test func settingsRoundTripRejectsFallbackWrite() async throws {
        try await rejectsStaleWrite(change: .settingsRoundTrip)
    }

    @Test func explicitImageRecoveryRejectsFallbackWrite() async throws {
        try await rejectsStaleWrite(change: .imageRecovery)
    }

    private enum Change { case clear, settings, settingsRoundTrip, imageRecovery }

    private func rejectsStaleWrite(change: Change) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = settings()
        let disk = ReaderTranslationDiskCache(directory: root)
        try await disk.synchronizeSettings(settings)
        let token = try #require(await disk.captureTranslationWrite(settings: settings))
        TranslationImageSupport.shared.record(.unsupported, for: settings.configuration)
        switch change {
        case .clear:
            try await disk.clear()
        case .settings, .settingsRoundTrip:
            var changed = settings
            changed.model += "-changed"
            try await disk.synchronizeSettings(changed)
            if change == .settingsRoundTrip { try await disk.synchronizeSettings(settings) }
        case .imageRecovery:
            TranslationImageSupport.shared.record(.supported, for: settings.configuration)
        }
        let destination = await disk.resolveTranslationWrite(page: "page", settings: settings, token: token)
        #expect(destination == nil)
        #expect(try await disk.translatedRegions(page: "page", settings: settings) == nil)
    }

    private func settings() -> ReaderTranslationSettings {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.provider = .custom
        settings.custom.baseURL = "https://capability-persistence.invalid"
        settings.model = name
        settings.sourceLanguage = "en"
        settings.includePageImage = true
        settings.maximumConcurrentRequests = 2
        return settings
    }

    private func page(_ index: Int) -> Page {
        Page(sourceId: "capability", chapterId: "chapter", index: index, imageURL: "https://capability.invalid/\(index)")
    }

    nonisolated private static func region(_ index: Int, translated: Bool = false) -> ReaderTranslationRegion {
        var region = ReaderTranslationRegion(id: String(index), rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2),
                                             source: "Please open the door and come inside.")
        if translated { region.translation = "문을 열고 들어오세요." }
        return region
    }

    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
