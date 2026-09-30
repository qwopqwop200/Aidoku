import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderRenderPreparationCancellationTests {
    @Test func newPreparationDoesNotJoinCancelledWorkStillUnwinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: directory))
        let latch = PreparationCancellationLatch()
        let old = Task {
            try await cache.prepare("page") {
                await latch.wait()
                try Task.checkCancellation()
            }
        }
        defer { latch.release(); old.cancel(); cache.clearMemory() }
        while !latch.waiting { await Task.yield() }
        cache.cancelPreparation(for: "page")
        var replacementRan = false
        // Release the old work from inside the replacement. The replacement
        // must be admitted even while cancelled old work has not finished.
        let replacement = Task {
            try await cache.prepare("page") {
                replacementRan = true
                latch.release()
            }
        }
        // Bounded condition prevents a regression from hanging the test runner.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !replacementRan, ContinuousClock.now < deadline { await Task.yield() }
        latch.release()
        _ = await old.result
        _ = await replacement.result
        #expect(replacementRan)
    }

    @Test func cancelledCallerDoesNotStartPreparation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: directory))
        var operationRan = false
        let caller = Task {
            try? await Task.sleep(for: .seconds(10))
            do {
                try await cache.prepare("page") { operationRan = true }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        caller.cancel()
        #expect(await caller.value)
        #expect(!operationRan)
    }
}

@MainActor private final class PreparationCancellationLatch {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
