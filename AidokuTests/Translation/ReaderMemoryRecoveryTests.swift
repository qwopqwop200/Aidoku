import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderMemoryRecoveryTests {
    @Test func leavingReaderDuringReclamationDoesNotRestartOCR() async throws {
        var available: UInt64 = 1_274 * 1_024 * 1_024
        var completed = 0
        let reclaim = MemoryRetryGate()
        let retry = MemoryRetryGate()
        defer { reclaim.cancel(); retry.cancel() }
        let session = ReaderTranslationSession(process: { _, _, _ in completed += 1; return [] },
            availableMemory: { available }, reclaimMemory: {
                try? await reclaim.wait()
                available = 2_000 * 1_024 * 1_024
            }, waitForMemoryRetry: { try await retry.wait() })
        defer { session.close() }
        session.update(items: [.init(Page(sourceId: "memory-regression", chapterId: "test", index: 13))],
                       visible: [], context: "test")
        session.enable(settings: ReaderTranslationSettings())
        try await RegressionTestWait.until { reclaim.suspensions == 1 }
        session.close()
        // Deliberately deliver both callbacks after cancellation. Even a
        // cancellation-insensitive reclaimer must never resurrect OCR.
        reclaim.release()
        try await RegressionTestWait.until { retry.suspensions == 1 }
        retry.release()
        try await RegressionTestWait.until { retry.resumptions == 1 }
        #expect(completed == 0)
        #expect(session.state == .off)
    }

    @Test func blockedPageReclaimsMemoryAndResumesWithoutNavigation() async throws {
        var available: UInt64 = 1_274 * 1_024 * 1_024
        var reclaimed = 0
        var completed = 0
        let retry = MemoryRetryGate()
        defer { retry.cancel() }
        let session = ReaderTranslationSession(process: { _, _, _ in completed += 1; return [] },
            availableMemory: { available }, reclaimMemory: {
                reclaimed += 1
                available = 2_000 * 1_024 * 1_024
            }, waitForMemoryRetry: { try await retry.wait() })
        defer { session.close() }
        session.update(items: [.init(Page(sourceId: "memory-regression", chapterId: "test", index: 13))],
                       visible: [], context: "test", currentPageIndex: 13)
        session.enable(settings: ReaderTranslationSettings())
        try await RegressionTestWait.until { retry.suspensions == 1 }
        #expect(completed == 0)
        retry.release()
        try await RegressionTestWait.until { completed == 1 }
        #expect(reclaimed == 1)
        #expect(session.state == .on)
    }

    @Test func persistentPressureDoesNotReloadModelsOnEveryRetry() async throws {
        var reclaimed = 0
        var completed = 0
        let retry = MemoryRetryGate()
        defer { retry.cancel() }
        let session = ReaderTranslationSession(process: { _, _, _ in completed += 1; return [] },
            availableMemory: { 1_274 * 1_024 * 1_024 }, reclaimMemory: { reclaimed += 1 },
            waitForMemoryRetry: { try await retry.wait() })
        defer { session.close() }
        session.update(items: [.init(Page(sourceId: "memory-regression", chapterId: "test", index: 13))],
                       visible: [], context: "test")
        session.enable(settings: ReaderTranslationSettings())
        // Exercise two entire retry cycles, then disable with a third pending.
        for cycle in 1...2 {
            try await RegressionTestWait.until { retry.suspensions == cycle }
            retry.release()
        }
        try await RegressionTestWait.until { retry.suspensions == 3 }
        #expect(reclaimed == 1)
        #expect(completed == 0)
        session.disable()
        retry.release()
        try await RegressionTestWait.until { retry.resumptions == 3 }
        #expect(session.state == .off)
        #expect(completed == 0)
        #expect(reclaimed == 1)
        #expect(retry.suspensions == 3)
    }
}

/// Manual backoff: cancellation is intentionally ignored until the test delivers
/// the late completion, exercising the production task's cancellation guard.
@MainActor private final class MemoryRetryGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var suspensions = 0
    private(set) var resumptions = 0
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            precondition(self.continuation == nil)
            self.continuation = continuation
            suspensions += 1
        }
        resumptions += 1
    }
    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
    func cancel() {
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }
}
