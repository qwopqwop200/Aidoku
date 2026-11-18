import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// Native request planning and final-paint binding regressions.
@Suite(.serialized)
struct NativeCohortFitPlannerTests {
    private typealias P = NativeCohortFitPlanner
    private func items() -> [NativeAOTRawTextPainter.Item] {
        ["a", "b", "peer"].enumerated().map { i, id in
            .init(id: id, text: "Alpha beta", frame: CGRect(x: 50, y: 40 + i * 110, width: 300, height: 80),
                fontSize: 20, lineHeight: 28, chosenFill: CGColor(gray: 0, alpha: 1), colorAuthority: "synthetic-native-test")
        }
    }
    private func raw() -> [[String: Any]] {
        items().map { item in
            var row: [String: Any] = ["id": item.id, "text": item.text, "fontSize": 20.0,
                "sourceFontSize": 23.0, "fontReference": 20.0]
            if item.id != "peer" { row["typographyGroupID"] = "family" }
            return row
        }
    }
    private func page() throws -> CGImage {
        let c = try #require(CGContext(data: nil, width: 420, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 420, height: 400))
        return try #require(c.makeImage())
    }
    private func policy() -> [String: Any] {
        ["version": 1, "authority": "explicit-caller-cohort-fit-planning-v1",
         "mayAdjustRequestedDisplayFont": true, "completeDeclaredOwnerInventory": true,
         "declaredOwnerIDs": ["a", "b", "peer"], "scales": P.scales,
         "minimumOutputFontPixels": 12.0, "originalRequestedFonts": ["a": 20.0, "b": 20.0, "peer": 20.0],
         "fixedOwners": [String]()]
    }

    @Test func originalCallerLockLocksWholeFamilyButInjectedPreserveDoesNot() throws {
        let declared = raw()
        var options = declared
        for i in options.indices { options[i]["renderPreserveRequestedFontSize"] = true }
        let unlocked = try P.families(items: items(), declaredRaw: declared, membershipRaw: options, policy: .onFailure)
        #expect(unlocked.allSatisfy { !$0.locked })
        for (key, value) in [("renderPreserveRequestedFontSize", true), ("noShrink", true), ("allowShrink", false)] {
            var locked = declared; locked[0][key] = value
            let f = try P.families(items: items(), declaredRaw: locked, membershipRaw: options, policy: .onFailure)
            #expect(f.first { $0.owners.contains("a") }?.owners == ["a", "b"])
            #expect(f.first { $0.owners.contains("a") }?.locked == true)
            #expect(f.first { $0.owners == ["peer"] }?.locked == false)
        }
        let fixed = P.Policy(minimumOutputFontPixels: 12, fixedOwners: ["b"], authority: "test-explicit-fixed")
        #expect(try P.families(items: items(), declaredRaw: declared, membershipRaw: options, policy: fixed)
            .first { $0.owners.contains("a") }?.locked == true)
    }

    @Test func heldOrAbsentMembersNeverBecomeSmallerSplitFamily() throws {
        var declared = raw(); declared[1]["keptLettering"] = true
        let selected = items().filter { $0.id != "b" }
        for membership in [declared, declared.filter { $0["id"] as? String != "b" }] {
            let f = try P.families(items: selected, declaredRaw: declared, membershipRaw: membership, policy: .onFailure)
            let family = try #require(f.first { $0.owners.contains("a") })
            #expect(family.owners == ["a", "b"])
            #expect(family.indices == [0] && family.locked)
            #expect(family.lockReasons.contains("incomplete-rendered-family"))
        }
    }

    @Test func upstreamSourceGroupsDoNotMergeNativeFontFamilies() throws {
        var declared = raw()
        for i in declared.indices {
            declared[i]["sourceTypographyGroup"] = "shared-upstream"
            declared[i]["sourceFontFitGroupID"] = "fit-only"
        }
        var requests = items()
        let peer = requests[2]
        requests[2] = .init(id: peer.id, text: peer.text, frame: peer.frame,
            fontSize: 77.6812744140625, lineHeight: 108.7537841796875,
            chosenFill: peer.chosenFill, colorAuthority: peer.colorAuthority)
        requests = requests.enumerated().map { index, item in
            guard index < 2 else { return item }
            return .init(id: item.id, text: item.text, frame: item.frame, fontSize: 48,
                lineHeight: 67.2, chosenFill: item.chosenFill, colorAuthority: item.colorAuthority)
        }
        let f = try P.families(items: requests, declaredRaw: declared, membershipRaw: declared, policy: .onFailure)
        #expect(f.count == 2)
        #expect(f.first { $0.owners == ["a", "b"] }?.locked == false)
        #expect(f.first { $0.owners == ["peer"] }?.locked == false)
        declared[2]["noShrink"] = true
        let locked = try P.families(items: requests, declaredRaw: declared, membershipRaw: declared, policy: .onFailure)
        #expect(locked.first { $0.owners == ["peer"] }?.locked == true)
        #expect(locked.first { $0.owners == ["a", "b"] }?.locked == false)
        for i in declared.indices { declared[i].removeValue(forKey: "typographyGroupID") }
        #expect(try P.families(items: requests, declaredRaw: declared, membershipRaw: declared, policy: .onFailure)
            .allSatisfy { $0.owners.count == 1 })
    }

    @Test func oldAndCurrentNativeTypographyRelationsStillUnionWithoutSplitting() throws {
        let declared = raw()
        var current = raw(); current[0].removeValue(forKey: "typographyGroupID")
        current[1]["typographyGroupID"] = "new-native-family"
        current[2]["typographyGroupID"] = "new-native-family"
        let policy = P.Policy(minimumOutputFontPixels: 12, fixedOwners: ["a"], authority: "test")
        let f = try P.families(items: items(), declaredRaw: declared, membershipRaw: current, policy: policy)
        #expect(f.count == 1 && f[0].owners == ["a", "b", "peer"] && f[0].locked)
    }

    @Test func authenticOptionalNullGroupsAndFlagsAreAbsentWithoutMutatingInputs() throws {
        var declared = raw()
        for i in declared.indices {
            declared[i]["sourceTypographyGroup"] = NSNull()
            declared[i]["noShrink"] = NSNull()
            declared[i]["allowShrink"] = NSNull()
        }
        declared[2]["typographyGroupID"] = NSNull()
        let before = try JSONSerialization.data(withJSONObject: declared, options: [.sortedKeys])
        let f = try P.families(items: items(), declaredRaw: declared, membershipRaw: declared, policy: .onFailure)
        #expect(f.count == 2 && f.allSatisfy { !$0.locked })
        _ = try P.explicitHostPolicy(policy(), items: items(), declaredRaw: declared)
        #expect(try JSONSerialization.data(withJSONObject: declared, options: [.sortedKeys]) == before)
        var missingAuthority = policy(); missingAuthority["mayAdjustRequestedDisplayFont"] = NSNull()
        #expect(throws: P.Failure.self) { try P.explicitHostPolicy(missingAuthority, items: items(), declaredRaw: declared) }
        var malformedOption = policy(); malformedOption["refineRecoveredSoftCuts"] = NSNull()
        #expect(throws: P.Failure.self) { try P.explicitHostPolicy(malformedOption, items: items(), declaredRaw: declared) }
    }

    @Test func duplicateInventoryMalformedFlagsAndFamilyIDsReject() throws {
        let badFlags: [Any] = ["false", 0, 1]
        for value in badFlags {
            var declared = raw(); declared[0]["noShrink"] = value
            #expect(throws: P.Failure.self) {
                try P.families(items: items(), declaredRaw: declared, membershipRaw: raw(), policy: .onFailure)
            }
        }
        let badGroups: [Any] = ["   ", 42, String(repeating: "g", count: 257)]
        for value in badGroups {
            var declared = raw(); declared[0]["sourceTypographyGroup"] = value
            #expect(throws: P.Failure.self) {
                try P.families(items: items(), declaredRaw: declared, membershipRaw: raw(), policy: .onFailure)
            }
        }
        #expect(throws: P.Failure.self) {
            try P.families(items: items(), declaredRaw: raw() + [raw()[0]], membershipRaw: raw(), policy: .onFailure)
        }
        #expect(throws: P.Failure.self) {
            try P.families(items: items() + [items()[0]], declaredRaw: raw(), membershipRaw: raw(), policy: .onFailure)
        }
    }

    @Test func hostExplicitPolicyCannotLieAboutInventoryFontsOrBooleanTypes() throws {
        _ = try P.explicitHostPolicy(policy(), items: items(), declaredRaw: raw())
        let malformedPolicies: [(String, Any)] = [("mayAdjustRequestedDisplayFont", 1), ("version", true),
            ("fixedOwners", "a"), ("declaredOwnerIDs", ["a", "b"]),
            ("originalRequestedFonts", ["a": 19.0, "b": 20.0, "peer": 20.0])]
        for (key, value) in malformedPolicies {
            var malformed = policy(); malformed[key] = value
            #expect(throws: P.Failure.self) { try P.explicitHostPolicy(malformed, items: items(), declaredRaw: raw()) }
        }
        let badPeerFlags: [Any] = [false, "true", 1]
        for bad in badPeerFlags {
            #expect(throws: P.Failure.self) { try P.requireCompletePeerContext(bad) }
        }
        try P.requireCompletePeerContext(nil); try P.requireCompletePeerContext(true)
    }

    @Test func eightRequestsAreGlobalRatiosAndLockedFamiliesStayExact() throws {
        var declared = raw(); declared[0]["noShrink"] = true
        var trials: [[P.Item]] = [], receipts: [[String: Any]] = []
        #expect(throws: P.Failure.self) {
            try P.run(items: items(), authenticatedOptions: raw(), declaredRaw: declared, membershipRaw: raw(),
                policy: .onFailure, outputScale: 1, record: { receipts.append($0) }) { request in
                trials.append(request); throw NativeFinalTextPaintAdmission.Failure.noSafePlacement("a")
            }
        }
        #expect(trials.count == 8)
        for (request, scale) in zip(trials, P.scales) {
            #expect(request[0].fontSize == 20 && request[1].fontSize == 20)
            #expect(abs(request[2].fontSize - 20 * scale) < 1e-7)
            #expect(abs(request[2].lineHeight - 28 * scale) < 1e-7)
            #expect(request[2].frame == items()[2].frame && request[2].chosenFill == items()[2].chosenFill)
        }
        #expect(receipts.last?["status"] as? String == "bounded-planning-unresolved")
        #expect((receipts.first?["attempts"] as? [[String: Any]])?.first?["error"] is String)
    }

    @Test func floorRejectsWholeProposalWithoutClampingIndividualOwners() throws {
        var trials: [[P.Item]] = []
        let floor = P.Policy(minimumOutputFontPixels: 14, fixedOwners: [], authority: "test")
        #expect(throws: P.Failure.self) {
            try P.run(items: items(), authenticatedOptions: raw(), declaredRaw: raw(), membershipRaw: raw(),
                policy: floor, outputScale: 1) { request in
                trials.append(request); throw NativeFinalTextPaintAdmission.Failure.noSafePlacement("a")
            }
        }
        #expect(trials.count == 7 && trials.last?.first?.fontSize == 14)
    }

    @Test func heterogeneousOriginalFamilyLocksWithoutNormalizationAndAllLockedMakesNoExtraPaint() throws {
        var heterogeneous = items()
        let old = heterogeneous[1]
        heterogeneous[1] = .init(id: old.id, text: old.text, frame: old.frame,
            fontSize: 21, lineHeight: 29.4, chosenFill: old.chosenFill, colorAuthority: old.colorAuthority)
        let families = try P.families(items: heterogeneous, declaredRaw: raw(), membershipRaw: raw(), policy: .onFailure)
        #expect(families.first { $0.owners.contains("a") }?.lockReasons.contains("incompatible-requested-fonts") == true)
        let locked = P.Policy(minimumOutputFontPixels: 12, fixedOwners: ["a", "peer"], authority: "test")
        var calls = 0
        #expect(throws: P.Failure.self) {
            try P.run(items: items(), authenticatedOptions: raw(), declaredRaw: raw(), membershipRaw: raw(),
                policy: locked, outputScale: 1) { _ in
                calls += 1; throw NativeFinalTextPaintAdmission.Failure.noSafePlacement("a")
            }
        }
        #expect(calls == 1)
    }

    @Test func originalSuccessReturnedExactlyAndUnrelatedFailureNeverTriggersPlanning() throws {
        let original = P.Layer(image: try page(), expectedItems: 3, paintedItems: 3, complete: true, audit: ["test": "sentinel"])
        var calls = 0
        let result = try P.run(items: items(), authenticatedOptions: raw(), declaredRaw: raw(), membershipRaw: raw(),
            policy: .onFailure, outputScale: 1) { _ in calls += 1; return original }
        #expect(calls == 1 && result.layer.image === original.image)
        #expect(NSDictionary(dictionary: result.layer.audit).isEqual(to: original.audit))
        calls = 0
        #expect(throws: P.Failure.self) {
            try P.run(items: items(), authenticatedOptions: raw(), declaredRaw: raw(), membershipRaw: raw(),
                policy: .onFailure, outputScale: 1) { _ in calls += 1; throw P.Failure.invalidPolicy }
        }
        #expect(calls == 1)
        #expect(throws: CancellationError.self) {
            try P.run(items: items(), authenticatedOptions: raw(), declaredRaw: raw(), membershipRaw: raw(),
                policy: .onFailure, outputScale: 1) { _ in throw CancellationError() }
        }
    }

    @Test func counterfeitSuccessAfterFailureHasNoRealCompletedPaintAndRejects() throws {
        let fake = P.Layer(image: try page(), expectedItems: 3, paintedItems: 3, complete: true,
            audit: ["finalPaintBoundsChecked": true, "finalCompositeAlphaVerified": true])
        var calls = 0
        #expect(throws: P.Failure.self) {
            try P.run(items: items(), authenticatedOptions: raw(), declaredRaw: raw(), membershipRaw: raw(),
                policy: .onFailure, outputScale: 1) { _ in
                calls += 1
                if calls == 1 { throw NativeFinalTextPaintAdmission.Failure.noSafePlacement("a") }
                return fake
            }
        }
        #expect(calls == 2) // binding failure aborts; it is not another capacity retry
    }

    @Test func actualNativeFinalCompletionAdmitsWithoutUsingDebugGlyphExports() throws {
        let background = try page(), declared = raw()
        var options = declared
        for i in options.indices { options[i]["renderPreserveRequestedFontSize"] = true }
        var calls = 0
        let result = try P.run(items: items(), authenticatedOptions: options, declaredRaw: declared,
            membershipRaw: options, policy: .onFailure, outputScale: 1) { request in
            calls += 1
            if calls == 1 { throw NativeFinalTextPaintAdmission.Failure.noSafePlacement("synthetic-trigger") }
            return try NativeAOTRawTextPainter.renderCentered(items: request, rawItems: options,
                viewport: CGSize(width: 420, height: 400), restored: background, allowShrink: false)
        }
        #expect(calls == 2 && result.receipt["selectedScale"] as? Double == 0.95)
        #expect(result.layer.complete && result.layer.paintedItems == 3)
        #expect(NSDictionary(dictionary: declared[0]).isEqual(to: raw()[0]))
    }

    @Test func realNativeImageWithTamperedChosenFontAuditIsRejected() throws {
        let background = try page(); var calls = 0
        #expect(throws: P.Failure.self) {
            try P.run(items: items(), authenticatedOptions: raw(), declaredRaw: raw(), membershipRaw: raw(),
                policy: .onFailure, outputScale: 1) { request in
                calls += 1
                if calls == 1 { throw NativeFinalTextPaintAdmission.Failure.noSafePlacement("synthetic-trigger") }
                let layer = try NativeAOTRawTextPainter.renderCentered(items: request, rawItems: raw(),
                    viewport: CGSize(width: 420, height: 400), restored: background, allowShrink: false)
                var audit = layer.audit
                var rows = try #require(audit["rawNativeItems"] as? [[String: Any]])
                rows[0]["fontSize"] = 123.0; audit["rawNativeItems"] = rows
                return P.Layer(image: layer.image, expectedItems: layer.expectedItems,
                    paintedItems: layer.paintedItems, complete: layer.complete, audit: audit)
            }
        }
        #expect(calls == 2)
    }

    @Test func historicalRecoveryStatusNeverTriggersSuccessfulRequestRefinement() throws {
        let old = P.Layer(image: try page(), expectedItems: 3, paintedItems: 3, complete: true,
            audit: ["fixedFontRecovery": ["status": "recovered"], "softWordCuts": 2])
        #expect(!P.trustedRecoveredMarker(old))
        var calls = 0
        let result = try P.run(items: items(), authenticatedOptions: raw(), declaredRaw: raw(), membershipRaw: raw(),
            policy: .onFailure, outputScale: 1) { _ in calls += 1; return old }
        #expect(calls == 1 && result.layer.image === old.image)
    }

    @Test func recoveredQualityIsSoftAndRequiresPerOwnerNonincrease() {
        let before = ["a": P.RowQuality(cuts: 2, isolatedRows: 1), "peer": P.RowQuality(cuts: 0, isolatedRows: 0)]
        #expect(P.strictlyImproves(["a": .init(cuts: 1, isolatedRows: 1), "peer": .init(cuts: 0, isolatedRows: 0)], before))
        #expect(!P.strictlyImproves(["a": .init(cuts: 1, isolatedRows: 1), "peer": .init(cuts: 1, isolatedRows: 0)], before))
        #expect(!P.strictlyImproves(["a": .init(cuts: 1, isolatedRows: 2), "peer": .init(cuts: 0, isolatedRows: 0)], before))
        #expect(!P.strictlyImproves(before, before))
    }

    @Test func unobservedRecoveredQualityFixtureCannotLaunchPlanAndIsReturnedExactly() throws {
        // Deliberately incomplete synthetic metadata tests dispatch/fail-closed behavior;
        // this is NOT a native recovered-paint proof or production success claim.
        let fixture = P.Layer(image: try page(), expectedItems: 3, paintedItems: 3, complete: true,
            audit: ["recoveryDrawBudget": ["recoveryActive": true]])
        var calls = 0
        let result = try P.run(items: items(), authenticatedOptions: raw(), declaredRaw: raw(), membershipRaw: raw(),
            policy: .onFailure, outputScale: 1) { _ in calls += 1; return fixture }
        #expect(calls == 1 && result.layer.image === fixture.image)
        #expect(result.receipt["status"] as? String == "valid-recovered-incumbent-retained-quality-inspection-unavailable")
    }
    @Test func nativeContractAndProofFailuresNeverEnterSingletonFallback() throws {
        let errors: [Error] = [
            NativeAOTRawTextPainter.FontContractFailure(group: "synthetic-family", requestedFonts: [20, 24]),
            P.Failure.invalidPolicy, P.Failure.unboundCompletedPaint,
            NativeFinalTextPaintAdmission.Failure.noSafePlacement("synthetic-owner"), CancellationError()
        ]
        for error in errors {
            var called = false
            do {
                let _: Int = try P.exhaustedCapacityFallback(after: error) { called = true; return 7 }
                Issue.record("Non-capacity or unplanned failure reached singleton fallback")
            } catch {
                #expect(!called)
            }
        }
    }

    @Test func exhaustedCompletePagePlanningCanUseOriginalRequestFallback() throws {
        var calls = 0
        let value = try P.exhaustedCapacityFallback(after: P.Failure.boundedPlanningUnresolved) {
            calls += 1
            return "original-request"
        }
        #expect(calls == 1 && value == "original-request")
    }


    @Test func belowMinimumFallbackStepsOnlyCauseFamiliesAndHonorsPixelFloor() throws {
        // Modeled on page 0314: one owner requests 59.16 px beside 26.23 px peers.
        let fonts: [(String, CGFloat)] = [("1", 26.23), ("3", 59.16), ("5", 26.23), ("tiny", 15)]
        let items = fonts.enumerated().map { i, entry in
            NativeAOTRawTextPainter.Item(id: entry.0, text: "text", frame: CGRect(x: 10, y: 10 + i * 100, width: 79, height: 90),
                fontSize: entry.1, lineHeight: entry.1 * 1.2, chosenFill: CGColor(gray: 0, alpha: 1), colorAuthority: "synthetic-native-test")
        }
        let families = items.indices.map { P.Family(owners: [items[$0].id], indices: [$0], lockReasons: []) }
            + [P.Family(owners: ["locked"], indices: [], lockReasons: ["caller"])]
        #expect(P.belowMinimumScales.first! < P.scales.last!)
        #expect(P.capacityCauseOwners(NativeFinalTextPaintAdmission.Failure.noSafePlacement("6,3")) == ["6", "3"])
        #expect(P.capacityCauseOwners(P.Failure.boundedPlanningUnresolved).isEmpty)
        let stepped: Set<Int> = [1]
        let first = P.belowMinimumFamilyScales(items: items, families: families, stepped: stepped, scale: 0.6,
                                               minimumOutputFontPixels: 12, outputScale: 1)
        // Non-cause families repeat the final ladder request exactly (0.65, or 1 under the floor/locked).
        #expect(first == [0.65, 0.6, 0.65, 1, 1])
        let last = P.belowMinimumFamilyScales(items: items, families: families, stepped: stepped, scale: 0.2,
                                              minimumOutputFontPixels: 12, outputScale: 1)
        #expect(abs(last[1] - 12 / 59.16) < 1e-9)
        #expect(Double(items[1].fontSize) * last[1] >= 12 - 1e-9)
        // A cause family already under the floor at 0.65 is never shrunk further.
        let floorBound = P.belowMinimumFamilyScales(items: items, families: families, stepped: [3], scale: 0.5,
                                                    minimumOutputFontPixels: 12, outputScale: 1)
        #expect(floorBound[3] == 1)
    }

    @Test func belowMinimumFallbackIsInapplicableToNonCapacityFailures() throws {
        var calls = 0
        let result = try P.belowMinimumScaleFallback(items: items(), authenticatedOptions: raw(), declaredRaw: raw(),
            membershipRaw: raw(), policy: .onFailure, outputScale: 1, after: P.Failure.invalidPolicy) { _ in
            calls += 1
            throw P.Failure.invalidPolicy
        }
        #expect(result == nil && calls == 0)
    }
}
