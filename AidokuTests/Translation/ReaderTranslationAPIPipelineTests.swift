import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationAPIPipelineTests {
    @Test func nextPageAPIOverlapsBlockedCurrentPageAndLookaheadStaysBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = APIPipelineRecorder(blocked: [0, 1])
        let preloader = preloader(recorder, disk: disk)
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, settings, progress in
            try await preloader.translate(page, settings: settings, onProgress: progress)
        }, cancelProcessing: { preloader.cancel() },
           cancelProcessingForPage: { preloader.cancel(preservingRecognitionFor: $0) }, diskCache: disk,
           availableMemory: { 4 * 1_024 * 1_024 * 1_024 })
        preloader.nextPage = { [weak session] page in session?.nextPageForRecognition(after: page) }
        defer { session.close() }
        let value = settings()
        session.update(items: (0..<5).map { .init(page($0)) }, visible: [], context: "chapter", currentPageIndex: 0)
        session.enable(settings: value)
        try await waitUntil { Set(await recorder.published) == [0, 1] }
        #expect(await recorder.ocr == [0, 1])
        #expect(await recorder.maximumActive == 2)
        #expect(await recorder.completed.isEmpty)
        let key = ReaderTranslationCacheIdentity.translation(page: page(1).translationCacheKey, settings: value)
        #expect(try await disk.contains(key, kind: .translation) == false)
        session.close()
        try await waitUntil { Set(await recorder.cancelled) == [0, 1] }
        #expect(try await disk.contains(key, kind: .translation) == false)
        #expect(session.state == .off)
    }

    @Test func turningToLookaheadReplaysPartialTranslationAndKeepsItsAPIAlive() async throws {
        let recorder = APIPipelineRecorder(blocked: [0, 1])
        let preloader = preloader(recorder)
        preloader.nextPage = { _ in page(1) }
        let first = Task { try await preloader.translate(page(0), settings: settings()) }
        defer { preloader.cancel(); first.cancel() }
        try await waitUntil { Set(await recorder.published) == [0, 1] }
        preloader.cancel(preservingRecognitionFor: page(1))
        let snapshots = APIPipelineSnapshots()
        let second = Task {
            try await preloader.translate(page(1), settings: settings()) { await snapshots.append($0) }
        }
        defer { second.cancel() }
        await #expect(throws: CancellationError.self) { try await first.value }
        try await waitUntil { await snapshots.values.first?.first?.translation == "partial-ko-1" }
        #expect(await recorder.started.filter { $0 == 1 }.count == 1)
        #expect(await recorder.ocr.filter { $0 == 1 }.count == 1)
        #expect(await recorder.cancelled == [0])
        await recorder.release(1)
        #expect(try await second.value.first?.translation == "complete-ko-1")
    }

    @Test func pageTurnPauseAndAnchorUpdatePreserveDestinationButDiscardSkippedLookahead() async throws {
        for destination in [1, 3] {
            let recorder = APIPipelineRecorder(blocked: [0, 1, 3])
            let preloader = preloader(recorder)
            let session = ReaderTranslationSession(process: { page, settings, progress in
                try await preloader.translate(page, settings: settings, onProgress: progress)
            }, cancelProcessing: { preloader.cancel() },
               cancelProcessingForPage: { preloader.cancel(preservingRecognitionFor: $0) },
               availableMemory: { 4 * 1_024 * 1_024 * 1_024 })
            preloader.nextPage = { [weak session] page in session?.nextPageForRecognition(after: page) }
            defer { session.close() }
            let items = (0..<4).map { ReaderTranslationSession.Item(page($0)) }
            session.update(items: items, visible: [], context: "chapter", currentPageIndex: 0)
            session.enable(settings: settings())
            try await waitUntil { Set(await recorder.published) == [0, 1] }
            session.pauseForPageTurn(preservingRecognitionFor: page(destination))
            try await waitUntil { await recorder.cancelled.contains(0) }
            // The debounce must not launch the new destination early.
            try await Task.sleep(for: .milliseconds(350))
            #expect(await recorder.started == [0, 1])
            if destination == 1 {
                #expect(await recorder.cancelled == [0])
            } else {
                try await waitUntil { await recorder.cancelled.contains(1) }
            }
            session.update(items: items, visible: [], context: "chapter", currentPageIndex: destination)
            try await waitUntil { await recorder.started.contains(destination) }
            #expect(await recorder.started.filter { $0 == destination }.count == 1)
            #expect(await recorder.ocr.filter { $0 == destination }.count == 1)
            if destination == 1 { #expect(await recorder.cancelled == [0]) }
        }
    }

    @Test func navigationAdoptsInProgressOCRWithoutStartingItAgain() async throws {
        let recorder = APIPipelineRecorder(blocked: [0, 1], blockedOCR: [1])
        let preloader = preloader(recorder)
        preloader.nextPage = { _ in page(1) }
        let first = Task { try await preloader.translate(page(0), settings: settings()) }
        defer { preloader.cancel(); first.cancel() }
        try await waitUntil { await recorder.ocr == [0, 1] }
        preloader.cancel(preservingRecognitionFor: page(1))
        let second = Task { try await preloader.translate(page(1), settings: settings()) }
        defer { second.cancel() }
        await recorder.releaseRecognition(1)
        try await waitUntil { await recorder.started.contains(1) }
        await recorder.release(1)
        #expect(try await second.value.first?.translation == "complete-ko-1")
        #expect(await recorder.ocr == [0, 1])
        #expect(await recorder.started.filter { $0 == 1 }.count == 1)
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test func arrivingAtAlreadyActivePageKeepsItsWorkAcrossRepeatedCancellation() async throws {
        let recorder = APIPipelineRecorder(blocked: [1, 2])
        let preloader = preloader(recorder)
        preloader.nextPage = { _ in page(2) }
        let first = Task { try await preloader.translate(page(1), settings: settings()) }
        defer { preloader.cancel(); first.cancel() }
        try await waitUntil { Set(await recorder.published) == [1, 2] }
        preloader.cancel(preservingRecognitionFor: page(1))
        // The post-debounce anchor update repeats cancellation.
        preloader.cancel(preservingRecognitionFor: page(1))
        try await waitUntil { await recorder.cancelled == [2] }
        preloader.nextPage = nil
        let second = Task { try await preloader.translate(page(1), settings: settings()) }
        defer { second.cancel() }
        await recorder.release(1)
        #expect(try await second.value.first?.translation == "complete-ko-1")
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await recorder.ocr.filter { $0 == 1 }.count == 1)
        #expect(await recorder.started.filter { $0 == 1 }.count == 1)
        #expect(await recorder.cancelled == [2])
    }

    @Test func sessionTransfersActiveDestinationBeforeCancellingItsOldConsumer() async throws {
        let recorder = APIPipelineRecorder(blocked: [0, 1, 2])
        let preloader = preloader(recorder)
        var calls: [Int] = []
        let session = ReaderTranslationSession(process: { page, settings, progress in
            calls.append(page.index)
            return try await preloader.translate(page, settings: settings, onProgress: progress)
        }, cancelProcessing: { preloader.cancel() },
           cancelProcessingForPage: { preloader.cancel(preservingRecognitionFor: $0) },
           availableMemory: { 4 * 1_024 * 1_024 * 1_024 })
        preloader.nextPage = { [weak session] page in session?.nextPageForRecognition(after: page) }
        defer { session.close() }
        let items = (0..<3).map { ReaderTranslationSession.Item(page($0)) }
        session.update(items: items, visible: [], context: "chapter", currentPageIndex: 0)
        session.enable(settings: settings())
        try await waitUntil { Set(await recorder.published) == [0, 1] }
        await recorder.release(0)
        try await waitUntil { calls == [0, 1] }
        session.pauseForPageTurn(preservingRecognitionFor: page(1))
        session.update(items: items, visible: [], context: "chapter", currentPageIndex: 1)
        try await waitUntil { calls == [0, 1, 1] }
        await recorder.release(1)
        try await waitUntil { await recorder.completed.contains(1) }
        #expect(await recorder.started.filter { $0 == 1 }.count == 1)
        #expect(await recorder.ocr.filter { $0 == 1 }.count == 1)
        #expect(await recorder.cancelled.contains(1) == false)
    }

    @Test func coordinatorKeepsDebounceAndAdoptsDestinationWork() async throws {
        let recorder = APIPipelineRecorder(blocked: [0, 1, 2])
        let preloader = preloader(recorder)
        let owner = APIPipelineOwner(pages: (0..<3).map { page($0) })
        var calls: [Int] = []
        let session = ReaderTranslationSession(process: { page, settings, progress in
            calls.append(page.index)
            return try await preloader.translate(page, settings: settings, onProgress: progress)
        }, cancelProcessing: { preloader.cancel() },
           cancelProcessingForPage: { preloader.cancel(preservingRecognitionFor: $0) },
           availableMemory: { 4 * 1_024 * 1_024 * 1_024 })
        preloader.nextPage = { [weak session] page in session?.nextPageForRecognition(after: page) }
        var value = settings()
        value.automaticallyTranslate = true
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session,
                                                        readSettings: { value }, setEnabled: { _ in })
        defer { coordinator.close() }
        coordinator.resume()
        try await waitUntil { Set(await recorder.published) == [0, 1] }
        owner.translationCurrentPageIndex = 1
        let movedAt = ProcessInfo.processInfo.systemUptime
        coordinator.visiblePagesDidChange()
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls == [0])
        try await waitUntil { calls.contains(1) }
        #expect(ProcessInfo.processInfo.systemUptime - movedAt >= 0.35)
        #expect(await recorder.started.filter { $0 == 1 }.count == 1)
        #expect(await recorder.ocr.filter { $0 == 1 }.count == 1)
        #expect(await recorder.cancelled == [0])
    }

    @Test func directParentCancellationStopsBothPageRequests() async throws {
        let recorder = APIPipelineRecorder(blocked: [0, 1])
        let preloader = preloader(recorder)
        preloader.nextPage = { _ in page(1) }
        let work = Task { try await preloader.translate(page(0), settings: settings()) }
        defer { preloader.cancel() }
        try await waitUntil { Set(await recorder.started) == [0, 1] }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        try await waitUntil { Set(await recorder.cancelled) == [0, 1] }
    }

    @Test func speculativeFailureDoesNotAbortCurrentPageAndIsSurfacedOnDemand() async throws {
        let recorder = APIPipelineRecorder(blocked: [0], failed: [1])
        let preloader = preloader(recorder)
        preloader.nextPage = { _ in page(1) }
        let work = Task { try await preloader.translate(page(0), settings: settings()) }
        defer { preloader.cancel(); work.cancel() }
        try await waitUntil { Set(await recorder.started) == [0, 1] }
        await recorder.release(0)
        #expect(try await work.value.first?.translation == "complete-ko-0")
        do {
            _ = try await preloader.translate(page(1), settings: settings())
            Issue.record("Expected the speculative API failure")
        } catch let fallback as ReaderTranslationOCRFallback {
            #expect(fallback.underlying as? RemoteTranslationError == .httpStatus(503, requestID: nil))
        }
        #expect(await recorder.started.filter { $0 == 1 }.count == 1)
    }

    @Test func finishedLookaheadIsPersistedBeforeCurrentPageCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = APIPipelineRecorder(blocked: [0])
        let preloader = preloader(recorder, disk: disk)
        preloader.nextPage = { _ in page(1) }
        let value = settings()
        let work = Task { try await preloader.translate(page(0), settings: value) }
        defer { preloader.cancel(); work.cancel() }
        let key = ReaderTranslationCacheIdentity.translation(page: page(1).translationCacheKey, settings: value)
        try await waitUntil { (try? await disk.contains(key, kind: .translation)) == true }
        #expect(await recorder.completed == [1])
        preloader.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.translatedRegions(page: page(1).translationCacheKey, settings: value)?.first?.translation == "complete-ko-1")
    }

    @Test func existingOCRAndTranslationCacheDoesNotTriggerAnotherPrefetchAPI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = settings()
        let generation = await disk.currentGeneration()
        let cachePage = page(1).translationCacheKey
        try await disk.storeRegions([APIPipelineRecorder.region(1)],
                                    for: ReaderTranslationCacheIdentity.ocr(page: cachePage, settings: value), kind: .ocr, generation: generation)
        var translated = APIPipelineRecorder.region(1)
        translated.translation = "cached"
        try await disk.storeRegions([translated], for: ReaderTranslationCacheIdentity.translation(page: cachePage, settings: value),
                                    kind: .translation, generation: generation)
        let recorder = APIPipelineRecorder()
        let preloader = preloader(recorder, disk: disk)
        preloader.nextPage = { _ in page(1) }
        defer { preloader.cancel() }
        _ = try await preloader.translate(page(0), settings: value)
        let cached = try await preloader.translate(page(1), settings: value)
        #expect(cached.first?.translation == "cached")
        #expect(await recorder.started == [0])
        #expect(await recorder.ocr == [0])
        try await disk.clear()
        let result = try await preloader.translate(page(1), settings: value)
        #expect(result.first?.translation == "complete-ko-1")
        #expect(await recorder.started == [0, 1])
        #expect(await recorder.ocr == [0, 1])
    }

    @Test func differentTranslationSettingsCannotPromoteStaleAPIWork() async throws {
        let recorder = APIPipelineRecorder(blocked: [0, 1])
        let preloader = preloader(recorder)
        preloader.nextPage = { _ in page(1) }
        let first = Task { try await preloader.translate(page(0), settings: settings()) }
        defer { preloader.cancel(); first.cancel() }
        try await waitUntil { Set(await recorder.started) == [0, 1] }
        preloader.cancel(preservingRecognitionFor: page(1))
        var changed = settings()
        changed.targetLanguage = "fr"
        await recorder.release(1)
        let result = try await preloader.translate(page(1), settings: changed)
        #expect(result.first?.translation == "complete-fr-1")
        #expect(await recorder.languages.contains("fr"))
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test func controlledProviderWaitBenchmark() async throws {
        func measure(concurrency: Int) async throws -> Double {
            let recorder = APIPipelineRecorder(delayMilliseconds: 200)
            let preloader = preloader(recorder)
            preloader.nextPage = { page in page.index < 5 ? self.page(page.index + 1) : nil }
            defer { preloader.cancel() }
            let value = settings(concurrency: concurrency)
            let start = ProcessInfo.processInfo.systemUptime
            for index in 0..<6 { _ = try await preloader.translate(page(index), settings: value) }
            #expect(await recorder.started.sorted() == Array(0..<6))
            #expect(await recorder.ocr == Array(0..<6))
            return ProcessInfo.processInfo.systemUptime - start
        }
        let serial = try await measure(concurrency: 1)
        let overlapped = try await measure(concurrency: 16)
        print("API_PIPELINE_CONTROLLED_SECONDS serial=\(serial) overlapped=\(overlapped)")
        #expect(overlapped < serial * 0.8)
    }

    private func settings(concurrency: Int = 16) -> ReaderTranslationSettings {
        let name = "api-pipeline-" + UUID().uuidString
        var value = ReaderTranslationSettings(defaults: UserDefaults(suiteName: name)!)
        value.maximumConcurrentRequests = concurrency
        return value
    }
    private func page(_ index: Int) -> Page {
        Page(sourceId: "api-pipeline", chapterId: "chapter", index: index, imageURL: "https://example.invalid/\(index)")
    }
    private func preloader(_ recorder: APIPipelineRecorder, disk: ReaderTranslationDiskCache? = nil) -> ReaderTranslationPreloader {
        ReaderTranslationPreloader(diskCache: disk, translator: { regions, settings, progress in
            try await recorder.translate(regions, settings: settings, progress: progress)
        }, recognizer: { page, _ in try await recorder.recognize(page.index) })
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor APIPipelineSnapshots {
    var values: [[ReaderTranslationRegion]] = []
    func append(_ value: [ReaderTranslationRegion]) { values.append(value) }
}

private actor APIPipelineRecorder {
    var ocr: [Int] = []
    var started: [Int] = []
    var published: [Int] = []
    var completed: [Int] = []
    var cancelled: [Int] = []
    var languages: [String] = []
    var maximumActive = 0
    private var active = 0
    private var blocked: Set<Int>
    private var blockedOCR: Set<Int>
    private let failed: Set<Int>
    private let delayMilliseconds: Int

    init(blocked: Set<Int> = [], failed: Set<Int> = [], delayMilliseconds: Int = 0, blockedOCR: Set<Int> = []) {
        self.blocked = blocked; self.failed = failed; self.delayMilliseconds = delayMilliseconds
        self.blockedOCR = blockedOCR
    }
    func release(_ index: Int) { blocked.remove(index) }
    func releaseRecognition(_ index: Int) { blockedOCR.remove(index) }
    func recognize(_ index: Int) async throws -> [ReaderTranslationRegion] {
        ocr.append(index)
        while blockedOCR.contains(index) { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(25))
        return [Self.region(index)]
    }
    func translate(
        _ regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings, progress: ReaderTranslationService.Progress?
    ) async throws -> [ReaderTranslationRegion] {
        let index = Int(regions[0].id)!
        started.append(index)
        languages.append(settings.targetLanguage)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if failed.contains(index) { throw RemoteTranslationError.httpStatus(503, requestID: nil) }
        var partial = regions
        partial[0].translation = "partial-\(settings.targetLanguage)-\(index)"
        do {
            try await progress?(partial)
            published.append(index)
            while blocked.contains(index) { try await Task.sleep(for: .milliseconds(5)) }
            try await Task.sleep(for: .milliseconds(delayMilliseconds))
            try Task.checkCancellation()
        } catch { cancelled.append(index); throw error }
        completed.append(index)
        return regions.map { var region = $0; region.translation = "complete-\(settings.targetLanguage)-\(index)"; return region }
    }
    static func region(_ index: Int) -> ReaderTranslationRegion {
        .init(id: String(index), rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), source: "Text \(index)")
    }
}


@MainActor private final class APIPipelineOwner: UIViewController, ReaderTranslationOwner {
    let translationUpcomingPages: [Aidoku.Page]
    let translationVisiblePages: [ReaderTranslationPage] = []
    let translationChapterKey = "chapter"
    var translationCurrentPageIndex = 0
    init(pages: [Aidoku.Page]) {
        translationUpcomingPages = pages
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
