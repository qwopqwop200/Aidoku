import Foundation
import Testing
@testable import Aidoku

@Suite struct ReaderAdmissionRecoveryTests {
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
