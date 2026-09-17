import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderMemoryRecoveryTests {
    @Test func leavingReaderDuringReclamationDoesNotRestartOCR() async throws {
        var available: UInt64 = 1_274 * 1_024 * 1_024
        var started = false
        var completed = 0
        let session = ReaderTranslationSession(process: { _, _, _ in completed += 1; return [] },
            availableMemory: { available }, reclaimMemory: {
                started = true
                try? await Task.sleep(for: .milliseconds(200))
                available = 2_000 * 1_024 * 1_024
            })
        session.update(items: [.init(Page(sourceId: "memory-regression", chapterId: "test", index: 13))],
                       visible: [], context: "test")
        session.enable(settings: ReaderTranslationSettings())
        for _ in 0..<100 where !started { try await Task.sleep(for: .milliseconds(10)) }
        #expect(started)
        session.close()
        try await Task.sleep(for: .milliseconds(2_300))
        #expect(completed == 0)
        #expect(session.state == .off)
    }

    @Test func blockedPageReclaimsMemoryAndResumesWithoutNavigation() async throws {
        var available: UInt64 = 1_274 * 1_024 * 1_024
        var reclaimed = 0
        var completed = 0
        let session = ReaderTranslationSession(process: { _, _, _ in completed += 1; return [] },
            availableMemory: { available }, reclaimMemory: {
                reclaimed += 1
                available = 2_000 * 1_024 * 1_024
            })
        defer { session.close() }
        session.update(items: [.init(Page(sourceId: "memory-regression", chapterId: "test", index: 13))],
                       visible: [], context: "test", currentPageIndex: 13)
        session.enable(settings: ReaderTranslationSettings())
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(reclaimed == 1)
        #expect(completed == 1)
        #expect(session.state == .on)
    }

    @Test func persistentPressureDoesNotReloadModelsOnEveryRetry() async throws {
        var reclaimed = 0
        var completed = 0
        let session = ReaderTranslationSession(process: { _, _, _ in completed += 1; return [] },
            availableMemory: { 1_274 * 1_024 * 1_024 }, reclaimMemory: { reclaimed += 1 })
        defer { session.close() }
        session.update(items: [.init(Page(sourceId: "memory-regression", chapterId: "test", index: 13))],
                       visible: [], context: "test")
        session.enable(settings: ReaderTranslationSettings())
        try await Task.sleep(for: .milliseconds(4_300))
        #expect(reclaimed == 1)
        #expect(completed == 0)
        session.disable()
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.state == .off)
        #expect(completed == 0)
    }
}
