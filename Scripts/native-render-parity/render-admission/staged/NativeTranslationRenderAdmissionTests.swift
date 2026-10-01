import Foundation
import Testing
@testable import Aidoku

@MainActor
struct NativeTranslationRenderAdmissionTests {
    @Test
    func queuedCancellationPreservesFIFOAndExclusiveResources() async throws {
        let gate = NativeTranslationRenderAdmission()
        let first = try await gate.acquire()
        let phase = AdmissionTestPhase()
        let probe = AdmissionTestProbe()
        let a = Task.detached {
            let lease = try await gate.acquire()
            await probe.begin("a")
            await phase.wait()
            await probe.end()
            await lease.release()
        }
        try await admissionWait { await gate.queuedCount == 1 }
        let b = Task.detached { () -> Bool in
            do {
                let lease = try await gate.acquire()
                await probe.begin("canceled-b")
                await probe.end()
                await lease.release()
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        try await admissionWait { await gate.queuedCount == 2 }
        let c = Task.detached {
            let lease = try await gate.acquire()
            await probe.begin("c")
            await Task.yield()
            await probe.end()
            await lease.release()
        }
        try await admissionWait { await gate.queuedCount == 3 }
        b.cancel()
        #expect(await b.value)
        #expect(await gate.queuedCount == 2)
        #expect(await first.release())
        try await admissionWait { await probe.order == ["a"] }
        #expect(await probe.active == 1)
        #expect(await gate.queuedCount == 1)
        await phase.open()
        try await a.value
        try await c.value
        #expect(await probe.order == ["a", "c"])
        #expect(await probe.maximumActive == 1)
        #expect(await probe.active == 0)
        #expect(await gate.queuedCount == 0)
    }

    @Test
    func cancellationRacingGrantCannotLeakOrReleaseAnotherOwner() async throws {
        let gate = NativeTranslationRenderAdmission()
        for iteration in 0..<64 {
            let first = try await gate.acquire()
            let queued = Task.detached { () -> Bool in
                do {
                    let lease = try await gate.acquire()
                    await Task.yield()
                    // Active cancellation does not revoke this lease. Its owner
                    // tears down and releases whether cancellation won or not.
                    let released = await lease.release()
                    return released
                } catch is CancellationError { return true }
                catch { return false }
            }
            try await admissionWait { await gate.queuedCount == 1 }
            if iteration % 2 == 0 {
                queued.cancel()
                #expect(await first.release())
            } else {
                async let released = first.release()
                queued.cancel()
                #expect(await released)
            }
            #expect(await queued.value)
            let next = try await gate.acquire()
            #expect(!(await first.release()))
            // Releasing the previous token again must not surrender this owner.
            let behind = Task.detached { try await gate.acquire() }
            try await admissionWait { await gate.queuedCount == 1 }
            #expect(await next.release())
            let last = try await behind.value
            #expect(!(await next.release()))
            #expect(await last.release())
        }
        #expect(await gate.queuedCount == 0)
    }

    @Test
    func activeCancellationKeepsLeaseUntilAwaitedPhaseAndTeardownFinish() async throws {
        let gate = NativeTranslationRenderAdmission()
        let phase = AdmissionTestPhase()
        let probe = AdmissionTestProbe()
        let active = Task.detached { () -> Bool in
            do {
                let lease = try await gate.acquire()
                await probe.begin("first")
                await phase.wait() // Models a MainActor phase with owned resources.
                let canceled = Task.isCancelled
                await probe.end() // Actual owned-resource teardown precedes release.
                await lease.release()
                return canceled
            } catch { return false }
        }
        try await admissionWait { await probe.order == ["first"] }
        let second = Task.detached {
            let lease = try await gate.acquire()
            await probe.begin("second")
            await probe.end()
            await lease.release()
        }
        try await admissionWait { await gate.queuedCount == 1 }
        active.cancel()
        await Task.yield()
        #expect(await probe.order == ["first"])
        #expect(await probe.active == 1)
        #expect(await gate.queuedCount == 1)
        await phase.open()
        #expect(await active.value)
        try await second.value
        #expect(await probe.order == ["first", "second"])
        #expect(await probe.maximumActive == 1)
        #expect(await probe.active == 0)
    }

    @Test
    func boundedQueueRejectsOverflowAndPreCanceledTaskDoesNotEnqueue() async throws {
        let gate = NativeTranslationRenderAdmission(maximumQueuedWaiters: 2)
        let first = try await gate.acquire()
        let a = Task.detached { try await gate.acquire() }
        try await admissionWait { await gate.queuedCount == 1 }
        let b = Task.detached { try await gate.acquire() }
        try await admissionWait { await gate.queuedCount == 2 }
        do {
            _ = try await gate.acquire()
            Issue.record("Expected bounded queue refusal")
        } catch NativeTranslationRenderAdmission.Failure.queueFull { }
        let phase = AdmissionTestPhase()
        let canceled = Task.detached { () -> Bool in
            await phase.wait()
            do {
                let lease = try await gate.acquire()
                await lease.release()
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        canceled.cancel()
        await phase.open()
        #expect(await canceled.value)
        #expect(await gate.queuedCount == 2)
        a.cancel(); b.cancel()
        do { _ = try await a.value; Issue.record("Canceled waiter a returned") } catch is CancellationError { }
        do { _ = try await b.value; Issue.record("Canceled waiter b returned") } catch is CancellationError { }
        #expect(await gate.queuedCount == 0)
        #expect(await first.release())
    }
}

nonisolated private func admissionWait(_ predicate: @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !(await predicate()) {
        guard clock.now < deadline else { throw AdmissionTestFailure.deadline }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum AdmissionTestFailure: Error { case deadline }

private actor AdmissionTestPhase {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        opened = true
        let pending = waiting
        waiting.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private actor AdmissionTestProbe {
    private(set) var order: [String] = []
    private(set) var active = 0
    private(set) var maximumActive = 0
    func begin(_ id: String) {
        order.append(id)
        active += 1
        maximumActive = max(maximumActive, active)
    }
    func end() { active -= 1 }
}
