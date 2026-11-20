import Foundation
import Testing
@testable import Aidoku

/// A provider request outlives the page that sent it, and transient failures retry.
struct V2PaidRequestTests {
    @Test func cancelledWaiterReturnsAtOnceWhileTheRequestFinishes() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let finished = Box()
        let request = Task { () throws -> Int in
            for await _ in gate.stream { break }
            finished.set()
            return 7
        }
        let waiter = Task { try await V2PaidRequest.awaitUnlessCancelled(request) }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(!finished.value)                    // the waiter did not wait for the request
        gate.continuation.yield()
        #expect(try await request.value == 7)       // the request was not cancelled
        #expect(finished.value)
    }

    @Test func uncancelledWaiterGetsTheResult() async throws {
        let request = Task { () throws -> String in "ok" }
        #expect(try await V2PaidRequest.awaitUnlessCancelled(request) == "ok")
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

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}
