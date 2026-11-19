import Testing
import Foundation
import CoreGraphics
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationConcurrencyTests {

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

    /// Page translation always attaches a page image; probes never decode it.
    private static let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
    private func settings(concurrency: Int) -> ReaderTranslationSettings {
        var value = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "concurrency-" + UUID().uuidString)!)
        value.maximumConcurrentRequests = concurrency
        // Fixture lines are English; the default manga tier admits only CJK sources.
        value.usesOCRLanguagePolicy = false
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

private actor PartialCallbackLifetime {
    var callbackStarted = false
    var callbackCancelled = false
    var callbackFinished = false
    var returned = false
    private var continuation: CheckedContinuation<Void, Never>?

    func holdCallback() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                callbackStarted = true
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        callbackFinished = true
    }

    private func recordCancellation() { callbackCancelled = true }
    func recordReturn() { returned = true }
    func releaseCallback() { continuation?.resume(); continuation = nil }
}

private struct FailingPartialProbe: RemoteTranslating {
    let lifetime: PartialCallbackLifetime

    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        throw RemoteTranslationError.missingCredential
    }

    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration,
                   onPartial: RemoteTranslationPartialHandler?) async throws -> RemoteTranslationBatchResult {
        onPartial?(request.segments.map { .init(id: $0.id, text: "partial translation") })
        while await !lifetime.callbackStarted { try await Task.sleep(for: .milliseconds(5)) }
        throw RemoteTranslationError.missingCredential
    }
}
