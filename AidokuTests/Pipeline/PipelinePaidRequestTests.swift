import Foundation
import Testing
@testable import Aidoku

/// A provider request outlives the page that sent it, and transient failures retry.
struct PipelinePaidRequestTests {
    @Test func cancelledWaiterReturnsAtOnceWhileTheRequestFinishes() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let finished = Box()
        let request = Task { () throws -> Int in
            for await _ in gate.stream { break }
            finished.set()
            return 7
        }
        let waiter = Task { try await PipelinePaidRequest.awaitUnlessCancelled(request) }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(!finished.value)                    // the waiter did not wait for the request
        gate.continuation.yield()
        #expect(try await request.value == 7)       // the request was not cancelled
        #expect(finished.value)
        #expect(try await PipelinePaidRequest.awaitUnlessCancelled(request) == 7)  // an uncancelled waiter gets the result
    }

    @Test func transientProviderFailuresAreRetried() {
        #expect(ReaderTranslationService.isTransient(RemoteTranslationError.httpStatus(502, requestID: nil), attempt: 1))
        #expect(ReaderTranslationService.isTransient(RemoteTranslationError.httpStatus(429, requestID: nil), attempt: 0))
        #expect(!ReaderTranslationService.isTransient(RemoteTranslationError.httpStatus(401, requestID: nil), attempt: 0))
        #expect(ReaderTranslationService.isTransient(RemoteTranslationError.transport(.timedOut), attempt: 0))
        #expect(ReaderTranslationService.isTransient(RemoteTranslationError.invalidResponse("x"), attempt: 0))
        #expect(!ReaderTranslationService.isTransient(RemoteTranslationError.invalidResponse("x"), attempt: 1))
        #expect(!ReaderTranslationService.isTransient(RemoteTranslationError.missingCredential, attempt: 0))
        #expect(!ReaderTranslationService.isTransient(CancellationError(), attempt: 0))
    }

    /// Look-ahead never takes the last compute slot; a waiting look-ahead raised to foreground takes it at once.
    @Test func computeSlotsKeepOneSlotForTheVisiblePage() async throws {
        let slots = PipelineComputeSlots(count: 2)
        try await slots.acquire(priority: .prefetch)
        let priorities = TranslationRequestPrioritySet()
        priorities.set(.prefetch, for: UUID())
        let admitted = Box()
        let waiting = Task {
            try await slots.acquire(priority: .shared(priorities))
            admitted.set()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!admitted.value)
        priorities.set(.foreground, for: UUID())
        try await waiting.value
        #expect(admitted.value)
    }

    /// A visible page's tail queued after a look-ahead page gets the next free slot; look-ahead never takes the last one.
    @Test func computeSlotsAdmitAVisibleTailBeforeQueuedLookahead() async throws {
        let slots = PipelineComputeSlots(count: 2)
        try await slots.acquire(priority: .foreground)
        try await slots.acquire(priority: .foreground)
        let lookaheadAdmitted = Box(), tailAdmitted = Box()
        let lookahead = Task {
            try await slots.acquire(priority: .prefetch)
            lookaheadAdmitted.set()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let tail = Task {
            try await slots.acquire(priority: .foreground)
            tailAdmitted.set()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        slots.release()
        try await tail.value
        #expect(tailAdmitted.value)
        #expect(!lookaheadAdmitted.value)
        slots.release()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!lookaheadAdmitted.value)            // one free slot stays reserved for a visible page
        slots.release()
        try await lookahead.value
        #expect(lookaheadAdmitted.value)
    }

    /// Look-ahead holds at most cap - 1 provider permits, so a visible page's request starts at once.
    @Test func providerLimiterKeepsOnePermitForTheVisiblePage() async throws {
        let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 2, foregroundReserve: 1)
        let gate = AsyncStream<Void>.makeStream()
        let holding = Task { try await limiter.withPermit(priority: .prefetch) { for await _ in gate.stream { break } } }
        try await Task.sleep(nanoseconds: 20_000_000)
        let queued = Box()
        let lookahead = Task { try await limiter.withPermit(priority: .prefetch) { queued.set() } }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!queued.value)
        try await limiter.withPermit(priority: .foreground) {}
        gate.continuation.yield()
        try await holding.value
        try await lookahead.value
        #expect(queued.value)
    }

    @Test func firstConnectionLossRetriesWithoutBackoff() {
        let lost = RemoteTranslationError.transport(.networkConnectionLost)
        #expect(ReaderTranslationService.retryDelay(after: lost, attempt: 0) == 0)
        #expect(ReaderTranslationService.retryDelay(after: lost, attempt: 1) == 3_000_000_000)
        #expect(ReaderTranslationService.retryDelay(after: RemoteTranslationError.transport(.timedOut), attempt: 0)
            == 1_000_000_000)
    }

    @Test func connectionWarmUpOnlyTargetsIdleOrigins() throws {
        let warmth = ProviderConnectionWarmth()
        let origin = try #require(ProviderConnectionWarmth.origin(of: URL(string: "https://API.example/v1/responses")!))
        #expect(origin == "https://api.example:443")
        #expect(warmth.begin(origin, warmUp: true, now: 10))
        #expect(!warmth.begin(origin, warmUp: true, now: 10.5))  // a warm-up is in flight
        warmth.end(origin, now: 11)
        #expect(!warmth.begin(origin, warmUp: true, now: 12))    // used 1 s ago
        #expect(warmth.begin(origin, warmUp: false, now: 12))    // traffic is never throttled
        warmth.end(origin, now: 12)
        #expect(warmth.begin(origin, warmUp: true, now: 14.5))
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}
