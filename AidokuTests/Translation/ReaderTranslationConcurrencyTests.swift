import Testing
import Foundation
import CoreGraphics
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationConcurrencyTests {
    @Test func ordinaryPageTranslatesAllDialogueInOneProviderRequest() async throws {
        let client = ConcurrencyProbe()
        await client.release()
        let service = ReaderTranslationService(client: client)
        let input = regions(prefix: "page", count: 16)
        let translated = try await service.translate(regions: input, settings: settings(concurrency: 8))
        #expect(await client.calls == 1)
        #expect(translated.map(\.id) == input.map(\.id))
        #expect(translated.compactMap(\.translation) == input.map { "translated " + $0.source })
    }

    @Test func providerQueueHonorsAllMetadataPrioritiesAfterPages() async throws {
        let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let recorder = PermitRecorder()
        let blocker = Task { try await limiter.withPermit { try await recorder.enter("active", blocked: true) } }
        defer { blocker.cancel() }
        try await waitUntil { await recorder.order == ["active"] }
        let priorities: [(String, TranslationRequestPriority)] = [
            ("tag", .metadata(.tag)), ("author", .metadata(.author)),
            ("description", .metadata(.description)), ("title", .metadata(.mangaTitle)),
            ("section", .metadata(.sourceMenuTitle)), ("prefetch", .prefetch), ("page", .foreground)
        ]
        var tasks: [Task<Void, Error>] = []
        defer { tasks.forEach { $0.cancel() } }
        for (index, entry) in priorities.enumerated() {
            tasks.append(Task { try await limiter.withPermit(priority: entry.1) { try await recorder.enter(entry.0) } })
            try await waitUntil { await limiter.queuedRequestCount == index + 1 }
        }
        await recorder.release()
        try await blocker.value
        for task in tasks { try await task.value }
        #expect(await recorder.order == ["active", "page", "prefetch", "section", "title", "description", "author", "tag"])
        #expect(TitleTranslationKind.sourceLabel.priority == .sourceMenuTitle)
        #expect(TitleTranslationKind.manga.priority == .mangaTitle)
        #expect(TitleTranslationKind.chapter.priority == .mangaTitle)
        #expect(TitleTranslationKind.description.priority == .description)
        #expect(TitleTranslationKind.author.priority == .author)
        #expect(TitleTranslationKind.tag.priority == .tag)
    }

    @Test func readerPreemptsActiveAndQueuedMetadataThenResumesAfterLastReaderLeaves() async throws {
        let client = ConcurrencyProbe()
        let service = ReaderTranslationService(client: client)
        let value = settings(concurrency: 1)
        let owner = UUID()
        let otherOwner = UUID()
        let metadata = Task { try await service.translateMetadata(regions: regions(prefix: "metadata", count: 1), settings: value) }
        defer { metadata.cancel() }
        try await waitUntil { await client.active == 1 }
        let queued = Task { try await service.translateMetadata(regions: regions(prefix: "queued", count: 1), settings: value) }
        defer { queued.cancel() }
        await service.setReaderActive(true, owner: owner)
        await service.setReaderActive(true, owner: otherOwner)
        try await waitUntil { await client.active == 0 }
        let page = Task { try await service.translate(regions: regions(prefix: "page", count: 1), settings: value) }
        defer { page.cancel() }
        try await waitUntil { await client.active == 1 }
        await client.release()
        #expect(try await page.value.first?.translation == "translated page text 0")
        #expect(await client.calls == 2)
        await service.setReaderActive(false, owner: owner)
        #expect(await client.calls == 2)
        await service.setReaderActive(false, owner: otherOwner)
        #expect(try await metadata.value.first?.translation == "translated metadata text 0")
        #expect(try await queued.value.first?.translation == "translated queued text 0")
        #expect(await client.calls == 4)
        #expect(await client.peak == 1)
    }

    @Test func cancelledMetadataWaitingForReaderNeverReachesProvider() async throws {
        let client = ConcurrencyProbe()
        let service = ReaderTranslationService(client: client)
        let owner = UUID()
        await service.setReaderActive(true, owner: owner)
        let metadata = Task {
            try await service.translateMetadata(regions: regions(prefix: "cancelled", count: 1), settings: settings(concurrency: 1))
        }
        metadata.cancel()
        await #expect(throws: CancellationError.self) { try await metadata.value }
        await service.setReaderActive(false, owner: owner)
        #expect(await client.calls == 0)
    }

    @Test func cachedBatchOutsideConcurrencyWindowSurvivesProviderFailure() async throws {
        let client = CacheFailureProbe()
        let cache = try TranslationCache(configuration: .init(diskEnabled: false, maxSizeMiB: 10))
        let service = TranslationService(client: client, cache: cache)
        let configuration = settings(concurrency: 1).configuration
        let cached = ReaderTranslationService.plans(regions: regions(prefix: "cached", count: 2),
                                                    settings: settings(concurrency: 1))[0].request
        let missing = ReaderTranslationService.plans(regions: regions(prefix: "missing", count: 1),
                                                     settings: settings(concurrency: 1))[0].request
        _ = try await service.translate(cached, configuration: configuration)
        await client.fail()
        let progress = CacheBatchProgress()
        await #expect(throws: RemoteTranslationError.self) {
            try await BoundedTranslationBatchExecutor.translate(
                [missing, cached], configuration: configuration, service: service,
                maximumConcurrentRequests: 1,
                onBatchCompleted: { index, _ in await progress.append(index) }
            )
        }
        #expect(await progress.indices == [1])
        #expect(await client.calls == 2)
    }

    @Test func readerHonorsConcurrencyAboveSixteen() async throws {
        let client = ConcurrencyProbe()
        let service = ReaderTranslationService(client: client)
        let value = settings(concurrency: 32)
        let regions = regions(prefix: "wide", count: 2_500)
        #expect(ReaderTranslationService.plans(regions: regions, settings: value).count > 32)
        let work = Task { try await service.translate(regions: regions, settings: value) }
        defer { work.cancel() }
        try await waitUntil { await client.active == 32 }
        #expect(await client.peak == 32)
        await client.release()
        #expect(try await work.value.count == regions.count)
        #expect(await client.peak == 32)
    }

    @Test(arguments: [false, true])
    func imageCapabilityUsesTheActualRequestConcurrencyCap(unsupported: Bool) async throws {
        let client = ConcurrencyProbe()
        let service = ReaderTranslationService(client: client)
        var value = settings(concurrency: 4)
        value.provider = .custom
        value.custom.baseURL = "https://concurrency-fixture.example/" + UUID().uuidString + "/v1"
        value.custom.model = "image-concurrency-fixture"
        // Validate the fixture before waiting for provider admission, so a
        // configuration failure cannot be reported as a concurrency timeout.
        _ = try value.configuration.validatedEndpoint()
        value.includePageImage = true
        TranslationImageSupport.shared.record(unsupported ? .unsupported : .supported, for: value.configuration)
        let input = regions(prefix: "image-capability", count: 300)
        #expect(ReaderTranslationService.plans(regions: input, settings: value).count > 4)
        let capturedSettings = value
        let work = Task {
            try await service.translate(regions: input, settings: capturedSettings,
                                        preparedImageJPEG: unsupported ? nil : Data([0xff, 0xd8, 0xff, 0xd9]))
        }
        defer { work.cancel() }
        let expectedConcurrency = unsupported ? 4 : 2
        try await waitUntil { await client.active == expectedConcurrency }
        #expect(await client.peak == expectedConcurrency)
        await client.release()
        let result = try await work.value
        #expect(result.map(\.id) == input.map(\.id))
        #expect(result.compactMap(\.translation) == input.map { "translated " + $0.source })
        #expect(await client.imageAttachments.allSatisfy { $0 == !unsupported })
        #expect(await client.peak == expectedConcurrency)
    }

    @Test func currentAndPrefetchShareTheConfiguredRequestCap() async throws {
        let client = ConcurrencyProbe()
        let service = ReaderTranslationService(client: client)
        let value = settings(concurrency: 4)
        let first = Task { try await service.translate(regions: regions(prefix: "current", count: 300), settings: value) }
        defer { first.cancel() }
        try await waitUntil { await client.active == 4 }
        let second = Task {
            try await service.translate(regions: regions(prefix: "ahead", count: 300), settings: value, priority: .prefetch)
        }
        defer { second.cancel() }
        await client.release()
        #expect(try await first.value.count == 300)
        #expect(try await second.value.count == 300)
        #expect(await client.peak <= 4)
    }

    @Test func queuedForegroundPrecedesPrefetchAndCancelledWaiterDoesNotConsumePermit() async throws {
        let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let recorder = PermitRecorder()
        let first = Task { try await limiter.withPermit { try await recorder.enter("active", blocked: true) } }
        defer { first.cancel() }
        try await waitUntil { await recorder.order == ["active"] }
        let prefetch = Task { try await limiter.withPermit(priority: .prefetch) { try await recorder.enter("prefetch") } }
        defer { prefetch.cancel() }
        try await waitUntil { await limiter.queuedRequestCount == 1 }
        let cancelled = Task { try await limiter.withPermit { try await recorder.enter("cancelled") } }
        defer { cancelled.cancel() }
        try await waitUntil { await limiter.queuedRequestCount == 2 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let visible = Task { try await limiter.withPermit { try await recorder.enter("visible") } }
        defer { visible.cancel() }
        try await waitUntil { await limiter.queuedRequestCount == 2 }
        await recorder.release()
        try await first.value
        try await visible.value
        try await prefetch.value
        #expect(await recorder.order == ["active", "visible", "prefetch"])
    }

    @Test func raisingLimitAdmitsWaitersAndLoweringLimitDrainsExistingRequests() async throws {
        let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let recorder = PermitRecorder()
        let first = Task { try await limiter.withPermit { try await recorder.enter("first", blocked: true) } }
        defer { first.cancel() }
        try await waitUntil { await recorder.order == ["first"] }
        let second = Task { try await limiter.withPermit { try await recorder.enter("second", blocked: true) } }
        defer { second.cancel() }
        try await waitUntil { await limiter.queuedRequestCount == 1 }
        await limiter.setMaximumConcurrentRequests(2)
        try await waitUntil { await recorder.order == ["first", "second"] }
        await limiter.setMaximumConcurrentRequests(1)
        let third = Task { try await limiter.withPermit { try await recorder.enter("third") } }
        defer { third.cancel() }
        try await waitUntil { await limiter.queuedRequestCount == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await limiter.queuedRequestCount == 1)
        #expect(await recorder.order == ["first", "second"])
        await recorder.release()
        try await second.value
        try await third.value
        #expect(await recorder.order == ["first", "second", "third"])
    }

    @Test func promotionFillsForegroundSlotsWithoutWaitingForSlowPrefetchBatches() async throws {
        let client = ConcurrencyProbe()
        let service = ReaderTranslationService(client: client)
        let promotion = TranslationRequestPromotion()
        let work = Task {
            try await service.translate(regions: regions(prefix: "promoted", count: 300),
                                        settings: settings(concurrency: 4), priority: .promotable(promotion))
        }
        defer { work.cancel() }
        try await waitUntil { await client.active == 2 }
        promotion.promote()
        try await waitUntil { await client.active == 4 }
        #expect(await client.peak == 4)
        await client.release()
        #expect(try await work.value.count == 300)
        #expect(await client.peak == 4)
    }

    @Test func unpromotedSchedulerCompletesAndCancelsWithoutWaitingForPromotion() async throws {
        for cancel in [false, true] {
            let client = ConcurrencyProbe()
            let service = ReaderTranslationService(client: client)
            let promotion = TranslationRequestPromotion()
            let work = Task {
                try await service.translate(regions: regions(prefix: "unpromoted", count: 300),
                                            settings: settings(concurrency: 4), priority: .promotable(promotion))
            }
            defer { work.cancel() }
            try await waitUntil { await client.active == 2 }
            if cancel {
                work.cancel()
                await #expect(throws: CancellationError.self) { try await work.value }
            } else {
                await client.release()
                #expect(try await work.value.count == 300)
            }
            #expect(await client.peak == 2)
        }
    }

    @Test func promotionReordersAlreadyQueuedProviderRequests() async throws {
        let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let recorder = PermitRecorder()
        let promotion = TranslationRequestPromotion()
        let first = Task { try await limiter.withPermit { try await recorder.enter("active", blocked: true) } }
        defer { first.cancel() }
        try await waitUntil { await recorder.order == ["active"] }
        let ahead = Task { try await limiter.withPermit(priority: .prefetch) { try await recorder.enter("ahead") } }
        defer { ahead.cancel() }
        try await waitUntil { await limiter.queuedRequestCount == 1 }
        let destination = Task {
            try await limiter.withPermit(priority: .promotable(promotion)) { try await recorder.enter("destination") }
        }
        defer { destination.cancel() }
        try await waitUntil { await limiter.queuedRequestCount == 2 }
        promotion.promote()
        await recorder.release()
        try await first.value
        try await ahead.value
        try await destination.value
        #expect(await recorder.order == ["active", "destination", "ahead"])
    }

    private func settings(concurrency: Int) -> ReaderTranslationSettings {
        var value = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "concurrency-" + UUID().uuidString)!)
        value.maximumConcurrentRequests = concurrency
        return value
    }
    private func regions(prefix: String, count: Int) -> [ReaderTranslationRegion] {
        (0..<count).map { .init(id: "\(prefix)-\($0)", rect: .zero, source: "\(prefix) text \($0)") }
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !(await condition()) {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor ConcurrencyProbe: RemoteTranslating {
    var active = 0
    var peak = 0
    var calls = 0
    var imageAttachments: [Bool] = []
    private var released = false
    func release() { released = true }
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        calls += 1
        imageAttachments.append(request.imageJPEG != nil)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(5))
        return RemoteTranslationBatchResult(translations: request.segments.map { .init(id: $0.id, text: "translated " + $0.text) },
                                            source: .network, providerRequestID: nil)
    }
}

private actor PermitRecorder {
    var order: [String] = []
    private var released = false
    func release() { released = true }
    func enter(_ name: String, blocked: Bool = false) async throws {
        order.append(name)
        while blocked && !released { try await Task.sleep(for: .milliseconds(5)) }
    }
}

private actor CacheFailureProbe: RemoteTranslating {
    private var failing = false
    var calls = 0
    func fail() { failing = true }
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        calls += 1
        if failing { throw RemoteTranslationError.missingCredential }
        return .init(translations: request.segments.map { .init(id: $0.id, text: "cached translation") },
                     source: .network, providerRequestID: nil)
    }
}

private actor CacheBatchProgress {
    var indices: [Int] = []
    func append(_ index: Int) { indices.append(index) }
}
