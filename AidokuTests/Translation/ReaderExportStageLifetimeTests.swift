import Foundation
import Testing
@testable import Aidoku

@MainActor
struct ReaderExportStageLifetimeTests {
    @Test(arguments: [false, true])
    func abortTearsDownBeforeDrainAndKeepsPermit(untilDeadline: Bool) async throws {
        let gate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let stage = StageProbe()
        let worker = Task {
            try await gate.withPermit { @MainActor in
                try await ReaderTranslationImageExporter.awaitExportStage(
                    timeoutNanoseconds: untilDeadline ? 30_000_000 : 5_000_000_000,
                    teardown: { stage.teardowns += 1 }) {
                        await stage.wait()
                    }
            }
        }
        defer { worker.cancel(); stage.complete() }
        try await waitUntil { stage.continuation != nil }
        if !untilDeadline { worker.cancel() }
        try await waitUntil { stage.teardowns == 1 }
        let successor = Task { try await gate.withPermit { 42 } }
        defer { successor.cancel() }
        try await waitUntil { await gate.queuedRequestCount == 1 }
        #expect(stage.teardowns == 1)
        stage.complete()
        do { _ = try await worker.value; Issue.record("Aborted stage returned output") } catch {}
        #expect(try await successor.value == 42)
        #expect(stage.teardowns == 1)
    }

    @Test func successfulStagePreservesBytesAndDoesNotTeardownLater() async throws {
        let stage = StageProbe()
        let expected = Data([0, 1, 255, 17])
        let actual = try await ReaderTranslationImageExporter.awaitExportStage(
            timeoutNanoseconds: 10_000_000, teardown: { stage.teardowns += 1 }) { expected }
        #expect(actual == expected)
        try await Task.sleep(for: .milliseconds(30))
        #expect(stage.teardowns == 0)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
private final class StageProbe {
    var teardowns = 0
    var continuation: CheckedContinuation<Data, Never>?
    func wait() async -> Data { await withCheckedContinuation { continuation = $0 } }
    func complete() { let pending = continuation; continuation = nil; pending?.resume(returning: Data([1])) }
}
