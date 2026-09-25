import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Product schedulers with controlled transport/OCR/provider operations. This
/// verifies progress and admission ordering, not real GPU or network latency.
@Suite(.serialized) @MainActor
struct ReaderMixedWorkloadSchedulingTests {
    private actor Workload {
        var transports = 0
        var peakTransports = 0
        var transportStarts = 0
        var releaseProvider = false
        var providerOrder: [String] = []
        var decodedBytes = 0
        var peakDecodedBytes = 0

        func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            transports += 1
            transportStarts += 1
            peakTransports = max(peakTransports, transports)
            defer { transports -= 1 }
            try await Task.sleep(for: .seconds(60))
            return (Data([1]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        func provider(_ name: String, block: Bool = false) async throws {
            providerOrder.append(name)
            while block && !releaseProvider { try await Task.sleep(for: .milliseconds(5)) }
        }
        func release() { releaseProvider = true }
        func imageWork(bytes: Int) async throws {
            decodedBytes += bytes
            peakDecodedBytes = max(peakDecodedBytes, decodedBytes)
            defer { decodedBytes -= bytes }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func distantVisibleJumpCompletesWhileBulkTransportAndTranslationAreBacklogged() async throws {
        let suite = "AidokuTests.MixedScheduling.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let workload = Workload()
        let downloadCache = DownloadCache()
        let request = URLRequest(url: URL(string: "https://mixed-fixture.invalid/page.png")!)
        // Twelve different queues saturate the production global download gate.
        let downloads = (0..<12).map { index in
            Task {
                let worker = DownloadTask(id: "mixed-\(index)", cache: downloadCache, downloads: [])
                return await worker.fetchPageResource(for: request, tmpDirectory: .temporaryDirectory,
                    fetch: { try await workload.fetch(request) }, cleanup: { _ in })
            }
        }
        defer { downloads.forEach { $0.cancel() } }
        try await waitUntil { await workload.transports == 5 }

        let provider = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let imageBudget = TranslationImageWorkBudget(availableMemory: { .max })
        let bytes = 4 * 1_024 * 1_024
        // Reproduce translated-download staging: image admission ends before
        // the slow provider wait; a second download queues behind that wait.
        let translatingDownload = Task {
            try await imageBudget.withPermit(priority: .prefetch, decodedBytes: UInt64(bytes)) {
                try await workload.imageWork(bytes: bytes)
            }
            try await provider.withPermit(priority: .prefetch) {
                try await workload.provider("download-active", block: true)
            }
        }
        defer { translatingDownload.cancel() }
        try await waitUntil { await workload.providerOrder == ["download-active"] }
        let queuedTranslation = Task {
            try await provider.withPermit(priority: .prefetch) {
                try await workload.provider("download-queued")
            }
        }
        defer { queuedTranslation.cancel() }
        try await waitUntil { await provider.queuedRequestCount == 1 }

        let pages = (0..<40).map { Aidoku.Page(sourceId: "mixed-reader", chapterId: "chapter", index: $0) }
        let cache = ReaderTranslationSessionCache()
        var started: [Int] = []
        var cancelledOldPage = false
        var destinationStartedAt: TimeInterval?
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, _ in
            started.append(page.index)
            if page.index == 39 { destinationStartedAt = ProcessInfo.processInfo.systemUptime }
            if page.index != 39 {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { if page.index == 0 { cancelledOldPage = true }; throw error }
            }
            try await imageBudget.withPermit(priority: .foreground, decodedBytes: UInt64(bytes)) {
                try await workload.imageWork(bytes: bytes)
            }
            try await provider.withPermit(priority: .foreground) {
                try await workload.provider("reader-\(page.index)")
            }
            return [.init(id: "line", rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2),
                          source: "Hello", translation: "안녕")]
        }, availableMemory: { .max }, cache: cache)
        defer { session.close() }
        let view = UIImageView()
        let visible = ReaderTranslationPage(imageView: view)
        visible.sourcePage = pages[0]
        let items = pages.map(ReaderTranslationSession.Item.init)
        session.update(items: items, visible: [visible], context: "mixed", currentPageIndex: 0)
        session.enable(settings: settings)
        try await waitUntil { started == [0] }

        let navigationAt = ProcessInfo.processInfo.systemUptime
        session.pauseForPageTurn(preservingRecognitionFor: pages[39])
        visible.sourcePage = pages[39]
        session.update(items: items, visible: [visible], context: "mixed", currentPageIndex: 39)
        try await waitUntil { cancelledOldPage && started.contains(39) }
        try await waitUntil { await provider.queuedRequestCount == 2 }
        // Reader OCR has progressed despite every bulk transport being busy and
        // a translated download holding the provider. No decoded permit is held.
        #expect(await workload.transports == 5)
        #expect(await workload.decodedBytes == 0)
        let providerReleasedAt = ProcessInfo.processInfo.systemUptime
        await workload.release()
        try await waitUntil { cache.contains(pages[39].translationCacheKey) }
        let destinationCachedAt = ProcessInfo.processInfo.systemUptime
        let completedCacheBytes = cache.bytes
        #expect(!cache.contains(pages[0].translationCacheKey))
        #expect(completedCacheBytes <= ReaderTranslationSessionCache.byteLimit)
        session.close()
        try await translatingDownload.value
        try await queuedTranslation.value
        #expect(await workload.providerOrder == ["download-active", "reader-39", "download-queued"])
        #expect(started.prefix(2).elementsEqual([0, 39]))
        #expect(!cache.contains(pages[0].translationCacheKey))
        #expect(cache.bytes <= ReaderTranslationSessionCache.byteLimit)
        #expect(await workload.peakDecodedBytes == bytes)
        #expect(await workload.peakTransports == 5)
        #expect(await workload.transportStarts == 5, "Reader completion must not depend on draining the download backlog")
        downloads.forEach { $0.cancel() }
        for download in downloads { #expect(await download.value == nil) }
        #expect(await workload.transports == 0)
        let report: [String: Any] = [
            "scenario": "12 bulk sources + active and queued translated work + 0-to-39 reader jump",
            "scope": "real schedulers; controlled transport/OCR/provider operations; no actual pixel display",
            "navigationToDestinationProcessMS": (try #require(destinationStartedAt) - navigationAt) * 1000,
            "providerReleaseToDestinationCacheMS": (destinationCachedAt - providerReleasedAt) * 1000,
            "peakPageTransports": await workload.peakTransports,
            "providerOrder": await workload.providerOrder,
            "oldPageCancelled": cancelledOldPage,
            "modeledPeakDecodedBytes": await workload.peakDecodedBytes,
            "cacheBytesAtDestinationCompletion": completedCacheBytes,
            "activePageTransportsAfterCancel": await workload.transports
        ]
        let folder = URL.documentsDirectory.appendingPathComponent("ReaderSchedulingEvidence")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("mixed-workload.json"))
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<800 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Mixed workload failed to make expected progress")
        throw CancellationError()
    }
}
