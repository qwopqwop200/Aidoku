import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeFrozenBackingInvariantTests {
    @Test func recordedLateCrossingNeedsEarlierContractAndCannotDiscardWitness() throws {
        // 0064 ID 5: source-owner proxy is covered by the old panel, while
        // v51 reaches containment with this already enlarged backing.
        let baseline = CGRect(x: 261.82824999999997, y: 49.063215,
            width: 25.479999999999983, height: 60.912000000000006)
        let late = CGRect(x: 254.86917, y: 47.53125, width: 33.33882999999997, height: 63.51675)
        let owner = CGRect(x: 262.128, y: 49.535999999999994,
            width: 24.079999999999984, height: 59.51200000000001)
        let witness = CGRect(x: 255.21286927835052, y: 49.535999999999994,
            width: 30.995130721649446, height: 60.13866486486487)
        let invariant = try #require(NativeTextBoxContainment.BackingInvariant(baseline: baseline,
            surface: nil, protectedRects: []))
        #expect(!invariant.admits(late, required: owner))
        #expect(invariant.admits(baseline, required: owner))
        // Owner coverage does not prove this larger witness is covered. A
        // rollback to baseline cannot be labeled a complete source repair.
        #expect(!invariant.admits(baseline, required: witness))
    }

    @Test func lateExpandedBaselineCannotLaunderEarlierCrossing() throws {
        let original = CGRect(x: 20, y: 20, width: 20, height: 40)
        let expanded = original.insetBy(dx: -4, dy: -2)
        let required = original.insetBy(dx: 1, dy: 1)
        let invariant = try #require(NativeTextBoxContainment.BackingInvariant(baseline: original,
            surface: nil, protectedRects: []))
        // The old local guard accepts an already bad incoming rectangle as its
        // baseline. The frozen stage contract rejects the same final rectangle.
        #expect(NativeTextBoxContainment.addsOnlyRequiredSourceCoverage(panel: expanded,
            baseline: expanded, required: required))
        #expect(!invariant.admits(expanded, required: required))
        #expect(invariant.admits(original, required: required))
    }

    @Test func broaderResampledContourCannotReplaceFrozenContour() throws {
        let original = CGRect(x: 20, y: 20, width: 20, height: 40)
        let surface = NativeTextBoxContainment.Surface(rect: CGRect(x: 10, y: 10, width: 40, height: 60),
            spans: [(18, 42), (10, 50), (18, 42)], color: nil)
        let invariant = try #require(NativeTextBoxContainment.BackingInvariant(baseline: original,
            surface: surface, protectedRects: []))
        let sourceExtension = CGRect(x: 17, y: 20, width: 23, height: 40)
        #expect(!invariant.admits(sourceExtension, required: sourceExtension))
        #expect(invariant.admits(original, required: original))
    }

    @Test func newProtectedPixelsCannotBeBoughtByEqualOverlapArea() throws {
        let original = CGRect(x: 10, y: 10, width: 20, height: 20)
        let target = CGRect(x: 20, y: 10, width: 20, height: 20)
        let invariant = try #require(NativeTextBoxContainment.BackingInvariant(baseline: original,
            surface: nil, protectedRects: [target]))
        let moved = CGRect(x: 15, y: 10, width: 15, height: 20)
        #expect(invariant.admits(moved, required: moved))
        let outside = CGRect(x: 25, y: 10, width: 10, height: 20)
        #expect(!invariant.admits(outside, required: outside))
    }

    @Test func necessaryUnprotectedCoverageCanGrowWithoutCarving() throws {
        let original = CGRect(x: 10, y: 10, width: 20, height: 20)
        let required = CGRect(x: 15, y: 10, width: 20, height: 20)
        let invariant = try #require(NativeTextBoxContainment.BackingInvariant(baseline: original,
            surface: nil, protectedRects: []))
        #expect(invariant.admits(original.union(required), required: required))
        #expect(!invariant.admits(original, required: required))
    }
}
