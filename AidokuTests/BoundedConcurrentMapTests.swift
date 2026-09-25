import Foundation
import Testing
@testable import Aidoku

struct BoundedConcurrentMapTests {
    @Test func parallelWindowIsBoundedAndResultsRetainInputOrder() async throws {
        let state = MapSchedulingState()
        let result = try await Array(0..<40).concurrentMap(maximumConcurrentTasks: 3) { index in
            await state.enter()
            try await Task.sleep(for: .milliseconds(index.isMultiple(of: 3) ? 12 : 2))
            await state.leave(cancelled: false)
            return index * 2
        }
        #expect(result == Array(0..<40).map { $0 * 2 })
        #expect(await state.maximum == 3)
    }

    @Test func cancellingParentCancelsActiveSiblingsAndDoesNotStartQueuedItems() async throws {
        let state = MapSchedulingState()
        let task = Task {
            try await Array(0..<40).concurrentMap(maximumConcurrentTasks: 3) { index in
                await state.enter()
                do {
                    try await Task.sleep(for: .seconds(10))
                    await state.leave(cancelled: false)
                    return index
                } catch {
                    await state.leave(cancelled: true)
                    throw error
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await state.started < 3 {
            guard ContinuousClock.now < deadline else { task.cancel(); throw MapSchedulingTimeout.expired }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { throw error }
        #expect(await state.started == 3)
        #expect(await state.cancelled == 3)
        #expect(await state.active == 0)
    }
}

private enum MapSchedulingTimeout: Error { case expired }
private actor MapSchedulingState {
    private(set) var active = 0
    private(set) var maximum = 0
    private(set) var started = 0
    private(set) var cancelled = 0
    func enter() { active += 1; started += 1; maximum = max(maximum, active) }
    func leave(cancelled: Bool) { active -= 1; if cancelled { self.cancelled += 1 } }
}
