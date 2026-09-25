import Foundation
import Testing
@testable import AidokuRunner

struct NetworkCancellationTests {
    @Test func cancelledBridgeJoinsCleanupBeforeReturning() async throws {
        let state = CancellationProbe()
        let worker = Task.detached {
            let bridge = BlockingTask(forwardsCancellation: true) {
                await state.markStarted()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { await state.markCancelled() }
                await state.waitForRelease()
                return 42
            }
            let result = bridge.get()
            await state.markReturned()
            return result
        }
        defer { worker.cancel() }
        try await waitUntil { await state.started }
        worker.cancel()
        try await waitUntil { await state.cancelled }
        #expect(await !state.returned)
        await state.release()
        #expect(await worker.value == 42)
        #expect(await state.returned)
    }

    @Test func cancelledRateWaitNeverConsumesNextPermit() async throws {
        let limiter = RateLimit()
        await limiter.set(permits: 1, period: 60)
        try await limiter.acquire()
        let waiter = Task { () -> Bool in
            do { try await limiter.acquire(); return true }
            catch { return false }
        }
        waiter.cancel()
        #expect(await !waiter.value)
        #expect(await limiter.requestsInPeriod == 1)
        await limiter.set(permits: 2, period: 60)
        try await limiter.acquire()
        #expect(await limiter.requestsInPeriod == 2)
    }

    @Test func netSendCancellationInterruptsRateWaitWithoutStartingAnotherTransport() async throws {
        let state = CancellationProbe()
        let worker = Task.detached {
            let store = GlobalStore()
            let url = URL(string: "https://fixture.invalid/image")!
            let descriptor = store.store(NetRequest(method: .get, url: url))
            let net = Net(store: store, requestHandler: { _ in
                await state.recordRequest()
                return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            net.setRateLimit(permits: 1, period: 60, unit: 0)
            let first = net.send(descriptor: descriptor)
            await state.markStarted()
            let cancelled = net.send(descriptor: descriptor)
            return (first, cancelled)
        }
        defer { worker.cancel() }
        try await waitUntil { await state.started }
        worker.cancel()
        let (first, cancelled) = await worker.value
        #expect(first == Net.Result.success.rawValue)
        #expect(cancelled == Net.Result.requestError.rawValue)
        #expect(await state.requests == 1)
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw CancellationProbeFailure.timedOut
    }
}

private enum CancellationProbeFailure: Error { case timedOut }
private actor CancellationProbe {
    var started = false
    var cancelled = false
    var returned = false
    var requests = 0
    func recordRequest() { requests += 1 }
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func markStarted() { started = true }
    func markCancelled() { cancelled = true }
    func markReturned() { returned = true }
    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
