import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeLiveGrowthStateTests {
    private typealias Policy = NativeTypographyPlateGrowth

    private func member(_ id: String, font: Double, cohort: Double, x: CGFloat) -> Policy.Member {
        .init(id: id, source: 20, script: "korean", vertical: false, sourceVertical: true,
            sourceRect: CGRect(x: x, y: 0, width: 20, height: 60), cohortFont: cohort,
            memberFont: font, styleKey: "same-paper-and-ink")
    }

    @Test(arguments: [0, 1, 2])
    func styleCapReadsTheProofRouteAfterTheStrictCohortRetry(mode: Int) {
        var font = 20.0
        var state = Policy.GrowthState(extended: mode != 0, base: mode == 0 ? 20 : 12, interiorBase: nil)
        var growers = [Policy.Grower(id: "grown", source: 20, script: "korean", vertical: false,
            inPlace: true, size: 20, extended: state.extended, base: state.base)]
        var caps: [Double] = []
        Policy.reconcile(&growers, members: {
            [member("grown", font: font, cohort: 12, x: 0), member("peer", font: 12, cohort: 12, x: 200)]
        }, kept: [], run: { _, cap, strict in
            caps.append(cap)
            if strict {
                // Accepted geometry can switch between crop and exterior proof,
                // or establish a larger crop baseline, while keeping its font.
                state = .init(extended: mode != 1, base: mode == 2 ? 16 : 12, interiorBase: nil)
            } else { font = cap }
            return font
        }, readableHold: { _ in 0 }, plateFilled: { _ in false }, interiorGaps: { _, _ in 0 },
           growthState: { _ in state })
        #expect(caps.first == .infinity)
        #expect(caps.count == (mode == 0 ? 2 : 1))
        #expect(growers[0].styleCap == (mode == 0 ? 15 : nil))
        #expect(font == (mode == 0 ? 15 : 20))
    }

    @Test(arguments: [false, true])
    func interiorConsistencyUsesTheCurrentProofAfterStyleCap(replacesInterior: Bool) {
        var font = 20.0
        var state = Policy.GrowthState(extended: true, base: 10, interiorBase: 10)
        var growers = [Policy.Grower(id: "grown", source: 20, script: "korean", vertical: false,
            size: 20, extended: true, base: 10, interiorBase: 10)]
        var caps: [Double] = []
        Policy.reconcile(&growers, members: {
            // Current cohort size prevents the first cap; the lower same-style
            // peer still bounds growth that came only from exterior sampling.
            [member("grown", font: font, cohort: 20, x: 0),
             member("peer", font: 12, cohort: 12, x: 200),
             member("peer-high", font: 20, cohort: 20, x: 400)]
        }, kept: [], run: { _, cap, _ in
            caps.append(cap); font = cap
            state = .init(extended: false, base: cap, interiorBase: replacesInterior ? 14 : nil)
            return font
        }, readableHold: { _ in 0 }, plateFilled: { _ in false },
           interiorGaps: { _, value in value > 14 ? 2 : value >= 14 ? 1 : 0 }, growthState: { _ in state })
        #expect(caps == (replacesInterior ? [15, 14] : [15]))
        #expect(growers[0].interiorRefit == (replacesInterior ? 14 : nil))
    }

    @Test func absentLiveStateRetainsAnExplicitPlateGrowerSnapshot() {
        var growers = [Policy.Grower(id: "grown", source: 20, script: "korean", vertical: false,
            size: 14, extended: false, base: 10)]
        var runs = 0
        Policy.reconcile(&growers, members: {
            [member("grown", font: 14, cohort: 14, x: 0)]
        }, kept: [], run: { _, _, _ in runs += 1; return nil }, readableHold: { _ in 0 },
           plateFilled: { _ in false }, interiorGaps: { _, _ in 0 })
        #expect(runs == 0 && growers[0].size == 14)
    }
}
