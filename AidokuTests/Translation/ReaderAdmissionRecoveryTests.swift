import Foundation
import Testing
@testable import Aidoku

@Suite struct ReaderAdmissionRecoveryTests {
    @Test func concurrentPressureWaitersShareSuccessfulCacheReclamation() async throws {
        let state = ConcurrentRecoveryState()
        let release = RecoveryRelease()
        let tasks = (0..<8).map { _ in
            Task {
                await TranslationImageWorkBudget.reclaimIdleResources(
                    requiredHeadroom: 100,
                    availableMemory: { state.available() },
                    purgeCaches: {
                        state.beganCachePurge()
                        await release.wait()
                        state.restoreHeadroom()
                    },
                    purgeModels: { state.purgedModels() }
                )
            }
        }
        // The owner reads before and after gate admission; seven other callers
        // each observe pressure before queueing. No wall-clock sleep is needed.
        do {
            try await RegressionTestWait.until { state.readCount >= 9 && state.cachePurges >= 1 }
        } catch {
            await release.open()
            for task in tasks { task.cancel() }
            throw error
        }
        #expect(state.cachePurges == 1)
        await release.open()
        for task in tasks { #expect(!(await task.value)) }
        #expect(state.cachePurges == 1)
        #expect(state.modelPurges == 0)
    }

    @Test func recoveredHeadroomKeepsWarmResources() async {
        let calls = AdmissionRecoveryCalls()
        let purged = await TranslationImageWorkBudget.reclaimIdleResources(
            requiredHeadroom: 100,
            availableMemory: { 100 },
            purgeCaches: { await calls.append("caches") },
            purgeModels: { await calls.append("models") }
        )
        #expect(!purged)
        #expect(await calls.values.isEmpty)
    }

    @Test func cancelledNavigationDoesNotEvictResources() async {
        let calls = AdmissionRecoveryCalls()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TranslationImageWorkBudget.reclaimIdleResources(
                requiredHeadroom: 100,
                availableMemory: { 0 },
                purgeCaches: { await calls.append("caches") },
                purgeModels: { await calls.append("models") }
            )
        }.value
        #expect(!result)
        #expect(await calls.values.isEmpty)
    }

    @Test func navigationCancelledDuringCachePurgeKeepsOCRWarm() async {
        let calls = AdmissionRecoveryCalls()
        let result = await Task {
            await TranslationImageWorkBudget.reclaimIdleResources(
                requiredHeadroom: 100,
                availableMemory: { 0 },
                purgeCaches: {
                    await calls.append("caches")
                    withUnsafeCurrentTask { $0?.cancel() }
                },
                purgeModels: { await calls.append("models") }
            )
        }.value
        #expect(!result)
        #expect(await calls.values == ["caches"])
    }

    @Test func persistentPressureStillReleasesModels() async {
        let calls = AdmissionRecoveryCalls()
        let purged = await TranslationImageWorkBudget.reclaimIdleResources(
            requiredHeadroom: 100,
            availableMemory: { 0 },
            purgeCaches: { await calls.append("caches") },
            purgeModels: { await calls.append("models") }
        )
        #expect(purged)
        #expect(await calls.values == ["caches", "models"])
    }
}

private actor AdmissionRecoveryCalls {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private final class ConcurrentRecoveryState: @unchecked Sendable {
    private let lock = NSLock()
    private var memory: UInt64 = 0
    private var reads = 0
    private var caches = 0
    private var models = 0
    var readCount: Int { lock.withLock { reads } }
    var cachePurges: Int { lock.withLock { caches } }
    var modelPurges: Int { lock.withLock { models } }
    func available() -> UInt64 { lock.withLock { reads += 1; return memory } }
    func beganCachePurge() { lock.withLock { caches += 1 } }
    func purgedModels() { lock.withLock { models += 1 } }
    func restoreHeadroom() { lock.withLock { memory = 100 } }
}

private actor RecoveryRelease {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
