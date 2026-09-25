import Testing
import UIKit
import Nuke
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationAPIPipelineTests {
    @Test func distantSourceKeepsCompressedDiskDataWithoutRetainingDecodedPixels() async throws {
        let dataCache = try DataCache(name: "handoff-images-" + UUID().uuidString)
        defer { dataCache.removeAll() }
        let pipeline = ImagePipeline {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HandoffImageURLProtocol.self]
            configuration.urlCache = nil
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.dataCache = dataCache
            $0.dataCachePolicy = .storeOriginalData
            $0.imageCache = ImageCache()
        }
        let loader = ReaderTranslationImageLoader(pipeline: pipeline)
        let url = URL(string: "https://handoff-image.invalid/" + UUID().uuidString)!
        let page = Page(sourceId: "", chapterId: "test", index: 40, imageURL: url.absoluteString)
        let request = await ReaderPageView.imageRequest(url: url, sourceKey: page.sourceId)
        try await loader.prefetchData(page)
        #expect(pipeline.cache.cachedImage(for: request, caches: .memory) == nil)
        #expect(try await loader.load(page, cacheInMemory: false).size.width == 1)
        #expect(pipeline.cache.cachedImage(for: request, caches: .memory) == nil)
        #expect(pipeline.cache.cachedData(for: request) != nil)
        #expect(try await loader.load(page, cacheInMemory: true).size.width == 1)
        #expect(pipeline.cache.cachedImage(for: request, caches: .memory) != nil)
        #expect(HandoffImageURLProtocol.count(for: url) == 1, "Prefetch, distant OCR and visible image must share one download")
    }

    @Test func distantLookaheadIsCancelledUnderMemoryPressure() async throws {
        let budget = HandoffMemoryBudget()
        let recorder = APIPipelineRecorder(blocked: [0, 1])
        let preloader = ReaderTranslationPreloader(
            translator: { try await recorder.translate($0, settings: $1, progress: $2) },
            recognizer: { page, _ in try await recorder.recognize(page.index) }, availableMemory: { budget.value })
        preloader.nextPage = { _ in page(1) }
        let first = Task { try await preloader.translate(page(0), settings: settings()) }
        defer { preloader.cancel(); first.cancel() }
        try await waitUntil { Set(await recorder.published) == [0, 1] }
        budget.lower()
        preloader.cancel(preservingRecognitionFor: page(20))
        try await waitUntil { Set(await recorder.cancelled) == [0, 1] }
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test func downloadedLookaheadSurvivesCancellationOfItsOCRBarrier() async throws {
        let recorder = APIPipelineRecorder(blocked: [20], blockedOCR: [0])
        let downloads = APIPipelineSnapshots()
        let preloader = ReaderTranslationPreloader(
            translator: { try await recorder.translate($0, settings: $1, progress: $2) },
            recognizer: { page, _ in try await recorder.recognize(page.index) },
            dataPrefetcher: { page in await downloads.append([APIPipelineRecorder.region(page.index)]) })
        preloader.nextPage = { $0.index == 0 ? page(1) : nil }
        let value = settings()
        let first = Task { try await preloader.translate(page(0), settings: value) }
        defer { preloader.cancel(); first.cancel() }
        try await waitUntil {
            let count = await downloads.values.count
            let recognized = await recorder.ocr
            return count == 1 && recognized == [0]
        }
        preloader.cancel(preservingRecognitionFor: page(20))
        let destination = Task { try await preloader.translate(page(20), settings: value) }
        defer { destination.cancel() }
        try await waitUntil { await recorder.completed.contains(1) }
        #expect(await recorder.ocr.filter { $0 == 1 }.count == 1)
        #expect(await downloads.values.count == 1)
        await recorder.release(20)
        _ = try await destination.value
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test func retainedDistantWorkIsDiscardedWhenTranslationSettingsChange() async throws {
        let recorder = APIPipelineRecorder(blocked: [0, 1])
        let preloader = preloader(recorder)
        preloader.nextPage = { $0.index == 0 ? page(1) : nil }
        let first = Task { try await preloader.translate(page(0), settings: settings()) }
        defer { preloader.cancel(); first.cancel() }
        try await waitUntil { Set(await recorder.published) == [0, 1] }
        preloader.cancel(preservingRecognitionFor: page(20))
        var changed = settings()
        changed.targetLanguage = "en"
        #expect(try await preloader.translate(page(20), settings: changed).first?.translation == "complete-en-20")
        try await waitUntil { Set(await recorder.cancelled) == [0, 1] }
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test func cachedTextLookaheadNeedsNoImageHeadroomOrDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var value = settings()
        value.includePageImage = false
        let key = ReaderTranslationCacheIdentity.ocr(page: page(1).translationCacheKey, settings: value)
        try await disk.storeRegions([APIPipelineRecorder.region(1)], for: key, kind: .ocr,
                                   generation: await disk.currentGeneration(settings: value))
        let recorder = APIPipelineRecorder(blocked: [0])
        let preloader = ReaderTranslationPreloader(diskCache: disk,
            translator: { try await recorder.translate($0, settings: $1, progress: $2) },
            recognizer: { page, _ in try await recorder.recognize(page.index) },
            dataPrefetcher: { _ in Issue.record("Cached text must not download an image") },
            availableMemory: { 512 * 1_024 * 1_024 })
        preloader.nextPage = { _ in page(1) }
        let first = Task { try await preloader.translate(page(0), settings: value) }
        defer { preloader.cancel(); first.cancel() }
        try await waitUntil { await recorder.completed == [1] }
        #expect(await recorder.ocr == [0])
        await recorder.release(0)
        _ = try await first.value
    }

    @Test(arguments: [false, true])
    func repeatedDemandAdoptsActiveOCRAndAPIWithoutRestarting(blockOCR: Bool) async throws {
        let recorder = APIPipelineRecorder(blocked: [0], blockedOCR: blockOCR ? [0] : [])
        let preloader = preloader(recorder)
        let value = settings()
        let first = Task { try await preloader.translate(page(0), settings: value) }
        defer { preloader.cancel(); first.cancel() }
        try await waitUntil { blockOCR ? await recorder.ocr == [0] : await recorder.published == [0] }
        let snapshots = APIPipelineSnapshots()
        let second = Task {
            try await preloader.translate(page(0), settings: value) { await snapshots.append($0) }
        }
        defer { second.cancel() }
        await recorder.releaseRecognition(0)
        try await waitUntil { await snapshots.values.last?.first?.translation == "partial-ko-0" }
        await recorder.release(0)
        #expect(try await second.value.first?.translation == "complete-ko-0")
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await recorder.ocr == [0])
        #expect(await recorder.started == [0])
        #expect(await recorder.cancelled.isEmpty)
    }

    @Test func distantStartedLookaheadFinishesIntoDiskAndIsNotRepeated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = APIPipelineRecorder(blocked: [0, 1, 20])
        let preloader = preloader(recorder, disk: disk)
        preloader.nextPage = { $0.index == 0 ? page(1) : page(21) }
        let value = settings()
        let first = Task { try await preloader.translate(page(0), settings: value) }
        defer { preloader.cancel(); first.cancel() }
        try await waitUntil { Set(await recorder.published) == [0, 1] }
        preloader.cancel(preservingRecognitionFor: page(20))
        let destination = Task { try await preloader.translate(page(20), settings: value) }
        defer { destination.cancel() }
        try await waitUntil { await recorder.published.contains(20) }
        #expect(await recorder.cancelled == [0])
        #expect(await recorder.started == [0, 1, 20])
        #expect(await recorder.maximumActive == 2)
        await recorder.release(1)
        let key = ReaderTranslationCacheIdentity.translation(page: page(1).translationCacheKey, settings: value)
        try await waitUntil { (try? await disk.contains(key, kind: .translation)) == true }
        preloader.nextPage = nil
        await recorder.release(20)
        _ = try await destination.value
        _ = try await preloader.translate(page(1), settings: value)
        #expect(await recorder.ocr.filter { $0 == 1 }.count == 1)
        #expect(await recorder.started.filter { $0 == 1 }.count == 1)
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test func failedAPIPreservesPartialTranslationWithoutCompletingDiskCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let preloader = ReaderTranslationPreloader(diskCache: disk, translator: { regions, _, progress in
            var partial = regions
            partial[0].translation = "캐시된 번역"
            try await progress?(partial)
            throw RemoteTranslationError.missingCredential
        }, recognizer: { _, _ in [APIPipelineRecorder.region(0), APIPipelineRecorder.region(1)] },
           availableMemory: { UInt64.max })
        defer { preloader.cancel() }
        let value = settings()
        do {
            _ = try await preloader.translate(page(0), settings: value)
            Issue.record("Expected provider failure")
        } catch let fallback as ReaderTranslationOCRFallback {
            #expect(fallback.regions[0].translation == "캐시된 번역")
            #expect(fallback.regions[1].translation == nil)
            #expect(fallback.underlying is RemoteTranslationError)
        }
        let key = ReaderTranslationCacheIdentity.translation(page: page(0).translationCacheKey, settings: value)
        #expect(try await disk.contains(key, kind: .translation) == false)
    }

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

    @Test func pageTurnPauseAndAnchorUpdateKeepOneStartedLookahead() async throws {
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
                #expect(await recorder.cancelled == [0])
            }
            session.update(items: items, visible: [], context: "chapter", currentPageIndex: destination)
            try await waitUntil { await recorder.started.contains(destination) }
            #expect(await recorder.started.filter { $0 == destination }.count == 1)
            #expect(await recorder.ocr.filter { $0 == destination }.count == 1)
            #expect(await recorder.cancelled == [0])
            #expect(await recorder.maximumActive == 2)
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

    @Test func cachedPageTurnsReuseTheUpcomingOCRAndAPIThroughPauseAndAnchorUpdate() async throws {
        let recorder = APIPipelineRecorder(blocked: [4])
        let preloader = preloader(recorder)
        let cache = ReaderTranslationSessionCache()
        for index in 0..<4 {
            var region = APIPipelineRecorder.region(index)
            region.translation = "cached"
            try cache.store([region], for: page(index).translationCacheKey)
        }
        var calls = 0
        let session = ReaderTranslationSession(process: { page, settings, progress in
            calls += 1
            return try await preloader.translate(page, settings: settings, onProgress: progress)
        }, cancelProcessing: { preloader.cancel() },
           cancelProcessingForPage: { preloader.cancel(preservingRecognitionFor: $0) },
           availableMemory: { UInt64.max }, cache: cache)
        defer { session.close() }
        let items = (0...4).map { ReaderTranslationSession.Item(page($0)) }
        session.update(items: items, visible: [], context: "chapter", currentPageIndex: 0)
        session.enable(settings: settings())
        try await waitUntil { await recorder.published == [4] }
        for destination in 1...3 {
            session.pauseForPageTurn(preservingRecognitionFor: page(destination))
            session.update(items: items, visible: [], context: "chapter", currentPageIndex: destination)
            try await waitUntil { calls == destination + 1 }
        }
        await recorder.release(4)
        try await waitUntil { cache.contains(page(4).translationCacheKey) }
        #expect(await recorder.ocr == [4])
        #expect(await recorder.started == [4])
        #expect(await recorder.cancelled.isEmpty)
        #expect(await recorder.maximumActive == 1)
    }

    @Test(arguments: ["uncached", "distant", "off", "pressure", "settings"])
    func upcomingWorkPreservationStillCancelsWhenNoLongerUseful(reason: String) async throws {
        let recorder = APIPipelineRecorder(blocked: [4])
        let preloader = preloader(recorder)
        let budget = HandoffMemoryBudget()
        let cache = ReaderTranslationSessionCache()
        for index in [0, 1, 2, 3, 10] {
            var region = APIPipelineRecorder.region(index)
            region.translation = "cached"
            try cache.store([region], for: page(index).translationCacheKey)
        }
        let session = ReaderTranslationSession(process: { page, settings, progress in
            try await preloader.translate(page, settings: settings, onProgress: progress)
        }, cancelProcessing: { preloader.cancel() },
           cancelProcessingForPage: { preloader.cancel(preservingRecognitionFor: $0) },
           availableMemory: { budget.value }, cache: cache)
        defer { session.close() }
        let items = [0, 1, 2, 3, 4, 10].map { ReaderTranslationSession.Item(page($0)) }
        let value = settings()
        session.update(items: items, visible: [], context: "chapter", currentPageIndex: 0)
        session.enable(settings: value)
        try await waitUntil { await recorder.published == [4] }
        if reason == "uncached" {
            cache.clear()
            for index in [0, 2, 3, 10] {
                var region = APIPipelineRecorder.region(index)
                region.translation = "cached"
                try cache.store([region], for: page(index).translationCacheKey)
            }
        }
        if reason == "pressure" { budget.lower() }
        session.pauseForPageTurn(preservingRecognitionFor: page(reason == "distant" ? 10 : 1))
        if reason == "off" { session.disable() }
        if reason == "settings" {
            var changed = value
            changed.targetLanguage = value.targetLanguage == "en" ? "ko" : "en"
            session.enable(settings: changed)
        }
        try await waitUntil { await recorder.cancelled.contains(4) }
        #expect(await recorder.completed.contains(4) == false)
        if reason == "uncached" {
            session.update(items: items, visible: [], context: "chapter", currentPageIndex: 1)
            try await waitUntil { await recorder.completed.contains(1) }
            #expect(await recorder.started.prefix(2) == [4, 1])
        }
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
        func measure(concurrency: Int) async throws -> Int {
            let recorder = APIPipelineRecorder(blocked: Set(0..<6))
            let preloader = preloader(recorder)
            preloader.nextPage = { page in page.index < 5 ? self.page(page.index + 1) : nil }
            let value = settings(concurrency: concurrency)
            let work = Task {
                for index in 0..<6 {
                    let result = try await preloader.translate(page(index), settings: value)
                    #expect(result.first?.translation == "complete-\(value.targetLanguage)-\(index)")
                }
            }
            defer { work.cancel(); preloader.cancel() }
            try await waitUntil { await recorder.published.contains(0) }
            if concurrency > 1 {
                // Page one must start while page zero is still blocked.
                try await waitUntil { await recorder.published.contains(1) }
                #expect(await recorder.completed.isEmpty)
            }
            for index in 0..<6 {
                try await waitUntil { await recorder.published.contains(index) }
                await recorder.release(index)
            }
            try await work.value
            #expect(await recorder.started.sorted() == Array(0..<6))
            #expect(await recorder.completed.sorted() == Array(0..<6))
            #expect(await recorder.ocr == Array(0..<6))
            return await recorder.maximumActive
        }
        #expect(try await measure(concurrency: 1) == 1)
        #expect(try await measure(concurrency: 16) == 2)
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

private final class HandoffMemoryBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var available = UInt64.max
    var value: UInt64 { lock.withLock { available } }
    func lower() { lock.withLock { available = 256 * 1_024 * 1_024 } }
}

private final class HandoffImageURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var counts: [URL: Int] = [:]
    static func count(for url: URL) -> Int { lock.withLock { counts[url, default: 0] } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "handoff-image.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.withLock { Self.counts[url, default: 0] += 1 }
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
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

    init(blocked: Set<Int> = [], failed: Set<Int> = [], blockedOCR: Set<Int> = []) {
        self.blocked = blocked; self.failed = failed
        self.blockedOCR = blockedOCR
    }
    func release(_ index: Int) { blocked.remove(index) }
    func releaseRecognition(_ index: Int) { blockedOCR.remove(index) }
    func recognize(_ index: Int) async throws -> [ReaderTranslationRegion] {
        ocr.append(index)
        while blockedOCR.contains(index) { try await Task.sleep(for: .milliseconds(5)) }
        await Task.yield()
        try Task.checkCancellation()
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
