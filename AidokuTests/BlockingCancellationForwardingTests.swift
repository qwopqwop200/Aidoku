import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct BlockingCancellationForwardingTests {
    @Test func cooperativeOperationReceivesCancellation() async throws {
        let state = BlockingCancellationState()
        let outer = Task.detached {
            BlockingTask(forwardsCancellation: true) {
                state.markStarted()
                do { try await Task.sleep(for: .seconds(4)); return false }
                catch { return Task.isCancelled }
            }.get()
        }
        try await waitStarted(state)
        outer.cancel()
        #expect(await outer.value)
    }

    @Test func cancelledNoncooperativeOperationStillOwnsCallerUntilActualCompletion() async throws {
        let state = BlockingCancellationState()
        let release = BlockingCancellationGate()
        let outer = Task.detached {
            let value = BlockingTask(forwardsCancellation: true) {
                state.markStarted()
                await release.wait()
                return Task.isCancelled
            }.get()
            state.markFinished()
            return value
        }
        defer { outer.cancel(); Task { await release.release() } }
        try await waitStarted(state)
        outer.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!state.finished, "Caller/admission must remain joined while inner work still owns resources")
        await release.release()
        #expect(await outer.value)
        #expect(state.finished)
    }

    @Test func defaultBridgePreservesLegacyCancellationAndOptionalNilCompletion() async throws {
        let state = BlockingCancellationState()
        let release = BlockingCancellationGate()
        let outer = Task.detached {
            BlockingTask {
                state.markStarted()
                await release.wait()
                return Task.isCancelled
            }.get()
        }
        defer { outer.cancel(); Task { await release.release() } }
        try await waitStarted(state)
        outer.cancel()
        await release.release()
        #expect(!(await outer.value))
        let nilValue = BlockingTask<Int?>(forwardsCancellation: true) { nil }
        #expect(nilValue.get() == nil)
        #expect(nilValue.get() == nil)
    }

    private func waitStarted(_ state: BlockingCancellationState) async throws {
        for _ in 0..<200 where !state.started { try await Task.sleep(for: .milliseconds(5)) }
        try #require(state.started)
    }
}

private final class BlockingCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didFinish = false
    var started: Bool { lock.withLock { didStart } }
    var finished: Bool { lock.withLock { didFinish } }
    func markStarted() { lock.withLock { didStart = true } }
    func markFinished() { lock.withLock { didFinish = true } }
}
private actor BlockingCancellationGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
