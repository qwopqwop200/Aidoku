import Foundation
import Testing
@testable import Aidoku

@MainActor
struct ReauditMangaLoadOwnershipTests {
    @Test func queuedOldCallbackCannotApplyAfterReplacementLoad() async {
        let owner = MangaDataLoadOwnership()
        let old = owner.begin()
        let gate = Gate()
        var applied = false
        let queued = Task { @MainActor in
            await gate.wait()
            return owner.performPartial(expectedID: old) { applied = true }
        }
        await gate.waitUntilSuspended()
        let current = owner.begin()
        await gate.release()
        let accepted = await queued.value
        #expect(!accepted && !applied)
        #expect(owner.isCurrent(current))
    }

    @Test func finalResultRevokesPartialCallbacksButRetainsCurrentLoad() {
        let owner = MangaDataLoadOwnership()
        let current = owner.begin()
        var value = "initial"
        let before = owner.performPartial(expectedID: current) { value = "partial" }
        #expect(before && value == "partial")
        value = "final"
        owner.closePartialResults(expectedID: current)
        let after = owner.performPartial(expectedID: current) { value = "late partial" }
        #expect(!after && value == "final")
        #expect(owner.isCurrent(current))
    }

    @Test func finishingOlderLoadCannotRevokeReplacementAndSourceChangeRevokesBoth() {
        let owner = MangaDataLoadOwnership()
        let old = owner.begin()
        let current = owner.begin()
        owner.finish(expectedID: old)
        #expect(owner.isCurrent(current))
        owner.invalidate()
        var applied = false
        let oldAccepted = owner.performPartial(expectedID: old) { applied = true }
        let currentAccepted = owner.performPartial(expectedID: current) { applied = true }
        #expect(!oldAccepted && !currentAccepted && !applied)
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var ready: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                ready?.resume()
                ready = nil
            }
        }
        func waitUntilSuspended() async {
            if continuation != nil { return }
            await withCheckedContinuation { ready = $0 }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }
}
