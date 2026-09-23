import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationOverlapTests {
    @Test func originalImageRemainsVisibleUntilTranslationCompletes() async throws {
        let recorder = OverlapRecorder(blockedAPI: 0)
        let preloader = preloader(recorder)
        let session = session(preloader)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let imageView = UIImageView(image: image)
        let visible = ReaderTranslationPage(imageView: imageView)
        visible.sourcePage = page(0)
        let value = settings
        defer { session.close(); preloader.cancel() }
        session.update(items: [.init(page(0))], visible: [visible], context: "chapter")
        session.enable(settings: value)
        try await waitUntil { await recorder.api == [0] }
        #expect(visible.regions.isEmpty)
        #expect(imageView.image === image)
        #expect(imageView.subviews.isEmpty)
        #expect(!visible.hasCompletedTranslation(settings: value))
        #expect(!visible.canExportTranslation)
        #expect(await recorder.completed.isEmpty)
        await recorder.release()
        try await waitUntil { visible.hasCompletedTranslation(settings: value) }
        #expect(visible.regions.first?.source == "Text")
        #expect(visible.regions.first?.translation == "translated")
        #expect(!imageView.subviews.isEmpty)
        #expect(visible.canExportTranslation)
    }

    @Test func compressedLookaheadDownloadsDuringCurrentOCRWithoutDecodingAnotherPage() async throws {
        let recorder = OverlapRecorder(blockedOCR: 0)
        let preloader = ReaderTranslationPreloader(
            translator: { regions, _, _ in try await recorder.translate(regions) },
            recognizer: { page, _ in try await recorder.recognize(page.index) },
            dataPrefetcher: { page in await recorder.prefetch(page.index) })
        preloader.nextPage = { _ in page(1) }
        let work = Task { try await preloader.translate(page(0), settings: settings) }
        defer { preloader.cancel(); work.cancel() }
        try await waitUntil {
            let downloaded = await recorder.prefetched
            let recognized = await recorder.ocr
            return downloaded == [1] && recognized == [0]
        }
        #expect(await recorder.api.isEmpty)
        #expect(await recorder.ocr == [0])
        await recorder.release()
        _ = try await work.value
        try await waitUntil { await recorder.ocr == [0, 1] }
        #expect(await recorder.prefetched == [1])
    }

    @Test func cachedOCRDoesNotRedownloadLookaheadImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var value = settings
        value.rightToLeftPanelOrder = false
        value.includePageImage = false
        let key = ReaderTranslationCacheIdentity.ocr(page: page(1).translationCacheKey, settings: value)
        try await disk.storeRegions([OverlapRecorder.region(1)], for: key, kind: .ocr,
                                    generation: await disk.currentGeneration(settings: value))
        let recorder = OverlapRecorder()
        let preloader = ReaderTranslationPreloader(diskCache: disk,
            translator: { regions, _, _ in try await recorder.translate(regions) },
            recognizer: { page, _ in try await recorder.recognize(page.index) },
            dataPrefetcher: { page in await recorder.prefetch(page.index) })
        preloader.nextPage = { _ in page(1) }
        defer { preloader.cancel() }
        _ = try await preloader.translate(page(0), settings: value)
        preloader.nextPage = nil
        _ = try await preloader.translate(page(1), settings: value)
        #expect(await recorder.prefetched.isEmpty)
        #expect(await recorder.ocr == [0])
        #expect(await recorder.completed == [0, 1])
    }

    @Test func cancellingReaderCancelsCompressedLookaheadDownload() async throws {
        let recorder = OverlapRecorder(blockedOCR: 0)
        let preloader = ReaderTranslationPreloader(
            translator: { regions, _, _ in regions },
            recognizer: { page, _ in try await recorder.recognize(page.index) },
            dataPrefetcher: { page in try await recorder.blockedPrefetch(page.index) })
        preloader.nextPage = { _ in page(1) }
        let work = Task { try await preloader.translate(page(0), settings: settings) }
        defer { preloader.cancel(); work.cancel() }
        try await waitUntil { await recorder.prefetched == [1] }
        preloader.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        try await waitUntil { await recorder.cancelledData == [1] }
        #expect(await recorder.ocr.allSatisfy { $0 == 0 })
    }

    @Test func lowMemorySkipsSpeculativeDownloadAndOCRButDemandCanRecover() async throws {
        let recorder = OverlapRecorder()
        let preloader = ReaderTranslationPreloader(
            translator: { regions, _, _ in try await recorder.translate(regions) },
            recognizer: { page, _ in try await recorder.recognize(page.index) },
            dataPrefetcher: { page in await recorder.prefetch(page.index) },
            availableMemory: { 0 })
        preloader.nextPage = { _ in page(1) }
        defer { preloader.cancel() }
        _ = try await preloader.translate(page(0), settings: settings)
        preloader.nextPage = nil
        _ = try await preloader.translate(page(1), settings: settings)
        #expect(await recorder.prefetched.isEmpty)
        #expect(await recorder.ocr == [0, 1])
        #expect(await recorder.completed == [0, 1])
    }

    @Test func turningToLookaheadPromotesItsOCRInsteadOfRestartingIt() async throws {
        let recorder = OverlapRecorder(blockedOCR: 1, blockedAPI: 0)
        let preloader = preloader(recorder)
        let session = session(preloader)
        defer { session.close() }
        let items = (0..<3).map { ReaderTranslationSession.Item(page($0)) }
        session.update(items: items, visible: [], context: "chapter", currentPageIndex: 0)
        session.enable(settings: settings)
        try await waitUntil { await recorder.reached(ocr: [0, 1], api: [0]) }
        let imageView = UIImageView()
        let visible = ReaderTranslationPage(imageView: imageView)
        visible.sourcePage = page(1)
        session.update(items: items, visible: [visible], context: "chapter", currentPageIndex: 1)
        try await waitUntil { await recorder.cancelledAPI == [0] }
        #expect(await recorder.cancelledOCR.isEmpty)
        #expect(await recorder.ocr == [0, 1])
        await recorder.release()
        try await waitUntil { await recorder.completed.contains(1) }
        #expect(await recorder.ocr.filter { $0 == 1 }.count == 1)
    }

    @Test func completedLookaheadOCRSurvivesExitAndReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = OverlapRecorder(blockedAPI: 0)
        let preloader = preloader(recorder, disk: disk)
        preloader.nextPage = { _ in page(1) }
        let work = Task { try await preloader.translate(page(0), settings: settings) }
        let key = ReaderTranslationCacheIdentity.ocr(page: page(1).translationCacheKey, settings: settings)
        try await waitUntil { (try? await disk.contains(key, kind: .ocr)) == true }
        preloader.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        let reopened = ReaderTranslationPreloader(diskCache: ReaderTranslationDiskCache(directory: root),
                                                  translator: { regions, _, _ in regions }, recognizer: { _, _ in
            Issue.record("Completed lookahead OCR must be restored from disk")
            throw URLError(.cannotDecodeContentData)
        })
        let restored = try await reopened.translate(page(1), settings: settings)
        #expect(restored.first?.id == "1")
        #expect(await recorder.ocr == [0, 1])
    }

    @Test func oneAheadOCRRunsDuringAPIWaitAndIsConsumedOnceInReaderOrder() async throws {
        let recorder = OverlapRecorder(blockedAPI: 2)
        let preloader = preloader(recorder)
        let session = session(preloader)
        defer { session.close() }
        session.update(items: (0..<5).map { .init(page($0)) }, visible: [], context: "chapter", currentPageIndex: 2)
        session.enable(settings: settings)
        try await waitUntil { await recorder.reached(ocr: [2, 3], api: [2]) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(await recorder.ocr == [2, 3]) // Never start an unbounded OCR queue.
        #expect(await recorder.completed.isEmpty)
        await recorder.release()
        try await waitUntil { await recorder.completed.count == 5 }
        #expect(await recorder.ocr == [2, 3, 1, 4, 0])
        #expect(await recorder.api == [2, 3, 1, 4, 0])
    }

    @Test func leavingCancelsAPIAndSpeculativeOCRWithoutStartingMorePages() async throws {
        let recorder = OverlapRecorder(blockedOCR: 1, blockedAPI: 0)
        let preloader = preloader(recorder)
        let session = session(preloader)
        session.update(items: (0..<4).map { .init(page($0)) }, visible: [], context: "chapter", currentPageIndex: 0)
        session.enable(settings: settings)
        try await waitUntil { await recorder.reached(ocr: [0, 1], api: [0]) }
        session.close()
        try await waitUntil { await recorder.cancelled(ocr: [1], api: [0]) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(await recorder.ocr == [0, 1])
        #expect(await recorder.api == [0])
        #expect(session.state == .off)
    }

    @Test func failingAheadOCRDoesNotAbortTheActiveTranslation() async throws {
        let recorder = OverlapRecorder(blockedAPI: 0, failedOCR: 1)
        let preloader = preloader(recorder)
        let session = session(preloader)
        defer { session.close() }
        session.update(items: (0..<3).map { .init(page($0)) }, visible: [], context: "chapter", currentPageIndex: 0)
        session.enable(settings: settings)
        try await waitUntil { await recorder.reached(ocr: [0, 1], api: [0]) }
        await recorder.release()
        try await waitUntil { await recorder.completed == [0, 2] }
        #expect(await recorder.ocr == [0, 1, 2])
        #expect(session.state == .on)
    }

    @Test func parentTaskCancellationAlsoStopsLookaheadWithoutSessionCallbacks() async throws {
        let recorder = OverlapRecorder(blockedOCR: 1, blockedAPI: 0)
        let preloader = preloader(recorder)
        preloader.nextPage = { _ in page(1) }
        let work = Task { try await preloader.translate(page(0), settings: settings) }
        try await waitUntil { await recorder.reached(ocr: [0, 1], api: [0]) }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        try await waitUntil { await recorder.cancelled(ocr: [1], api: [0]) }
    }

    @Test func alreadyTranslatedLookaheadDoesNotRepeatOCR() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = ReaderTranslationCacheIdentity.translation(page: page(1).translationCacheKey, settings: settings)
        try await disk.storeRegions([OverlapRecorder.region(1)], for: key, kind: .translation, generation: await disk.currentGeneration())
        let recorder = OverlapRecorder(blockedAPI: 0)
        let preloader = preloader(recorder, disk: disk)
        let session = session(preloader, disk: disk)
        defer { session.close() }
        session.update(items: (0..<3).map { .init(page($0)) }, visible: [], context: "chapter", currentPageIndex: 0)
        session.enable(settings: settings)
        try await waitUntil { await recorder.api == [0] }
        try await Task.sleep(for: .milliseconds(40))
        // Disk restoration can finish before lookahead selection, letting page 2
        // start immediately. Cached page 1 must never run OCR or an API request.
        let beforeRelease = await recorder.ocr
        #expect(beforeRelease == [0] || beforeRelease == [0, 2])
        #expect(await recorder.api == [0])
        await recorder.release()
        try await waitUntil { await recorder.completed == [0, 2] }
        #expect(await recorder.ocr == [0, 2])
    }

    private var settings: ReaderTranslationSettings {
        var value = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "overlap-tests-" + UUID().uuidString)!)
        // Exercise the supported one-request, OCR-only lookahead path.
        value.maximumConcurrentRequests = 1
        return value
    }
    private func page(_ index: Int) -> Page {
        Page(sourceId: "overlap-tests", chapterId: "chapter", index: index, imageURL: "https://example.invalid/\(index)")
    }
    private func preloader(_ recorder: OverlapRecorder, disk: ReaderTranslationDiskCache? = nil) -> ReaderTranslationPreloader {
        ReaderTranslationPreloader(diskCache: disk, translator: { regions, _, _ in try await recorder.translate(regions) },
                                   recognizer: { page, _ in try await recorder.recognize(page.index) })
    }
    private func session(_ preloader: ReaderTranslationPreloader, disk: ReaderTranslationDiskCache? = nil) -> ReaderTranslationSession {
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, settings, progress in
            try await preloader.translate(page, settings: settings, onProgress: progress)
        }, cancelProcessing: { preloader.cancel() },
           cancelProcessingForPage: { preloader.cancel(preservingRecognitionFor: $0) }, diskCache: disk)
        preloader.nextPage = { [weak session] page in session?.nextPageForRecognition(after: page) }
        return session
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor OverlapRecorder {
    var prefetched: [Int] = []
    var cancelledData: [Int] = []
    func prefetch(_ index: Int) { prefetched.append(index) }
    func blockedPrefetch(_ index: Int) async throws {
        prefetched.append(index)
        do { while true { try await Task.sleep(for: .milliseconds(5)) } }
        catch { cancelledData.append(index); throw error }
    }
    var ocr: [Int] = []
    var api: [Int] = []
    var completed: [Int] = []
    var cancelledOCR: [Int] = []
    var cancelledAPI: [Int] = []
    private var released = false
    private let blockedOCR: Int?
    private let blockedAPI: Int?
    private let failedOCR: Int?
    init(blockedOCR: Int? = nil, blockedAPI: Int? = nil, failedOCR: Int? = nil) {
        self.blockedOCR = blockedOCR; self.blockedAPI = blockedAPI; self.failedOCR = failedOCR
    }
    func reached(ocr: [Int], api: [Int]) -> Bool { self.ocr == ocr && self.api == api }
    func cancelled(ocr: [Int], api: [Int]) -> Bool { cancelledOCR == ocr && cancelledAPI == api }
    func release() { released = true }
    func recognize(_ index: Int) async throws -> [ReaderTranslationRegion] {
        ocr.append(index)
        if index == failedOCR { throw URLError(.cannotDecodeContentData) }
        do {
            while index == blockedOCR && !released { try await Task.sleep(for: .milliseconds(5)) }
            try Task.checkCancellation()
        } catch { cancelledOCR.append(index); throw error }
        return [Self.region(index)]
    }
    func translate(_ regions: [ReaderTranslationRegion]) async throws -> [ReaderTranslationRegion] {
        let index = Int(regions[0].id)!
        api.append(index)
        do {
            while index == blockedAPI && !released { try await Task.sleep(for: .milliseconds(5)) }
            try Task.checkCancellation()
        } catch { cancelledAPI.append(index); throw error }
        completed.append(index)
        return regions.map { var region = $0; region.translation = "translated"; return region }
    }
    static func region(_ index: Int) -> ReaderTranslationRegion {
        .init(id: String(index), rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), source: "Text")
    }
}
