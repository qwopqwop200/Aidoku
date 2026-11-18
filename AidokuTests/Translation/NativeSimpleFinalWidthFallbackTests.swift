import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeSimpleFinalWidthFallbackTests {
    private enum FixtureFailure: Error { case noSafe(String), other }
    private func cause(_ error: Error) -> String? {
        guard case FixtureFailure.noSafe(let owner) = error else { return nil }
        return owner
    }

    @Test func actualCallerSlotAndFrameWidthsHaveExplicitNonHistoricalAuthority() throws {
        let slot = try NativeSimpleFinalWidthFallback.callerWidth(frameOutputWidth: 37,
            slotNormalized: [0.1, 0.2, 0.24, 0.3], pageOutputWidth: 1000)
        #expect(slot.pixels == 240)
        #expect(slot.authority.contains("current-caller-balloon-layout-slot"))
        #expect(slot.authority.contains("not-historical"))
        let frame = try NativeSimpleFinalWidthFallback.callerWidth(frameOutputWidth: 37,
            slotNormalized: nil, pageOutputWidth: 1000)
        #expect(frame.pixels == 37 && frame.authority.contains("current-caller-item-frame"))
        #expect(throws: NativeSimpleFinalWidthFallback.InputFailure.self) {
            try NativeSimpleFinalWidthFallback.callerWidth(frameOutputWidth: 37,
                slotNormalized: [0, 0, .nan, 0.3], pageOutputWidth: 1000)
        }
    }

    @Test func recoveryChangesOnlyExplicitKnownOwnersAndRetainsCompleteInventory() throws {
        let inventory = ["a", "b", "c"]
        var replacements: [String] = [], attempts = 0
        let recovered = try NativeSimpleFinalWidthFallback.recover(initialFailure: FixtureFailure.noSafe("a,b"),
            owners: inventory, eligible: Set(inventory), cause: cause, replace: { owner in
                replacements.append(owner)
                return true
            }, attempt: {
                attempts += 1
                #expect(inventory == ["a", "b", "c"])
                if attempts == 1 { throw FixtureFailure.noSafe("a,b") }
                return "complete-page-verified"
            })
        #expect(replacements == ["a", "b"] && attempts == 2)
        #expect(recovered.value == "complete-page-verified")
        #expect(recovered.receipt.changedOwners == ["a", "b"])
        #expect(recovered.receipt.attempts.count == 3)
        #expect(recovered.receipt.audit["ownersDropped"] as? Int == 0)
    }

    @Test func repeatedOwnerAndUnknownFailureStopWithoutUnboundedRetries() {
        for failure in [FixtureFailure.noSafe("a"), FixtureFailure.noSafe("unknown"), FixtureFailure.other] {
            var replacements = 0, attempts = 0
            do {
                _ = try NativeSimpleFinalWidthFallback.recover(initialFailure: failure, owners: ["a"], eligible: ["a"],
                    cause: cause, replace: { _ in replacements += 1; return true }, attempt: {
                        attempts += 1
                        throw FixtureFailure.noSafe("a")
                    }) as (value: Int, receipt: NativeSimpleFinalWidthFallback.Receipt)
                Issue.record("Unresolved failure unexpectedly succeeded")
            } catch let stopped as NativeSimpleFinalWidthFallback.Failure {
                #expect(stopped.receipt.changedOwners.count <= 1)
            } catch { Issue.record("Unexpected error \(error)") }
            #expect(replacements <= 1 && attempts <= 1)
        }
    }

    @Test func cancellationPropagatesWithoutRecoveryWrapping() {
        #expect(throws: CancellationError.self) {
            try NativeSimpleFinalWidthFallback.recover(initialFailure: FixtureFailure.noSafe("a"),
                owners: ["a"], eligible: ["a"], cause: cause, replace: { _ in throw CancellationError() },
                attempt: { 1 })
        }
    }

    @Test func scopedRollbackHasDistinctRenderedPolicyVersion() {
        NativeSimpleTextLayout.withEnabled(true) {
            NativeSimpleTextLayout.withWidthFit(true) {
                let selected = NativeSimpleFinalWidthFallback.withEnabled(true) { NativeSimpleTextLayout.version }
                let rollback = NativeSimpleFinalWidthFallback.withEnabled(false) { NativeSimpleTextLayout.version }
                #expect(selected != rollback)
                #expect(selected == NativeSimpleFinalWidthFallback.version + "-coherent-repeat-runs-v1")
                #expect(rollback == "coretext-single-source-width-v6-coherent-repeat-runs-v1")
            }
        }
    }
}
