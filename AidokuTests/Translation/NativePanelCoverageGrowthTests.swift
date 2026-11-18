import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativePanelCoverageGrowthTests {
    @Test func recordedCapacityRecoveryCannotEnlargeAlreadyCoveredSource() {
        // Same-label baseline/witness/candidate geometry from the highest-area
        // 0757 g8 and 0586 g4 regressions. These are fixtures, never production IDs.
        let fixtures: [(CGRect, CGRect, CGRect, CGFloat)] = [
            (CGRect(x: 306.8602838079489, y: 101.7662667838667, width: 43.004814848041974, height: 54.44287392440275),
             CGRect(x: 315.11624823320034, y: 103.04260794967115, width: 32.63014958757884, height: 52.47955643147651),
             CGRect(x: 297.71397983986276, y: 101.0662667838667, width: 56.528125, height: 55.842873924402745), 2.25),
            (CGRect(x: 57.04112224050987, y: 122.9117368458679, width: 23.234999999999992, height: 47.196257506434094),
             CGRect(x: 59.88275664855591, y: 123.82327709465257, width: 17.46068058335716, height: 46.1130945030806),
             CGRect(x: 53.08469581069489, y: 122.2567343437232, width: 37.37738581121481, height: 48.59625750643409),
             2.095281670002859)
        ]
        for (baseline, witness, enlarged, guardSize) in fixtures {
            let required = witness.union(witness.insetBy(dx: -guardSize, dy: -guardSize).intersection(baseline))
            #expect(!NativeTextBoxContainment.addsOnlyRequiredSourceCoverage(panel: enlarged,
                baseline: baseline, required: required))
            #expect(NativeTextBoxContainment.addsOnlyRequiredSourceCoverage(panel: baseline,
                baseline: baseline, required: required))
        }
    }

    @Test func sourceWitnessMayRequireNewCoverageButNotExtraCorners() {
        let baseline = CGRect(x: 10, y: 10, width: 20, height: 20)
        let required = CGRect(x: 15, y: 10, width: 20, height: 20)
        let repaired = CGRect(x: 10, y: 10, width: 25, height: 20)
        #expect(NativeTextBoxContainment.addsOnlyRequiredSourceCoverage(panel: repaired,
            baseline: baseline, required: required))
        #expect(!NativeTextBoxContainment.addsOnlyRequiredSourceCoverage(panel: baseline,
            baseline: baseline, required: required))
        let diagonal = CGRect(x: 20, y: 20, width: 20, height: 20)
        #expect(!NativeTextBoxContainment.addsOnlyRequiredSourceCoverage(panel: baseline.union(diagonal),
            baseline: baseline, required: diagonal))
        #expect(NativeTextBoxContainment.addsOnlyRequiredSourceCoverage(panel: diagonal,
            baseline: baseline, required: diagonal))
    }

    @Test func roomyContourSearchFallsBackToCompleteCoverageRectangle() throws {
        let surface = NativeTextBoxContainment.Surface(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            spans: [(0, 100), (0, 100)], color: nil)
        let baseline = CGRect(x: 20, y: 20, width: 30, height: 50)
        let required = CGRect(x: 22, y: 22, width: 26, height: 46)
        let accepts: (CGRect) -> Bool = {
            NativeTextBoxContainment.addsOnlyRequiredSourceCoverage(panel: $0, baseline: baseline, required: required)
        }
        let proposed = try #require(surface.rectangularPanel(covering: required,
            near: CGRect(x: 5, y: 5, width: 80, height: 80), within: baseline,
            accepts: accepts, allowsExactCover: true, boundaryInset: 0.7))
        #expect(baseline.contains(proposed))
        #expect(proposed.contains(required))
        #expect(surface.contains(proposed))
    }

    @Test func coverageRepairAtNewEdgeRetainsSearcherClearance() throws {
        let surface = NativeTextBoxContainment.Surface(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            spans: [(0, 100), (0, 100)], color: nil)
        let baseline = CGRect(x: 20, y: 20, width: 30, height: 50)
        let required = CGRect(x: 22, y: 22, width: 32, height: 46)
        let inset: CGFloat = 0.7
        let searchLimit = baseline.union(required).insetBy(dx: -inset, dy: -inset)
        let repaired = try #require(surface.rectangularPanel(covering: required, near: baseline,
            within: searchLimit, accepts: {
                NativeTextBoxContainment.addsOnlyRequiredSourceCoverage(panel: $0, baseline: baseline, required: required)
            }, allowsExactCover: true, boundaryInset: inset))
        #expect(repaired.contains(required))
        #expect(repaired.maxX == required.maxX)
        #expect(surface.contains(repaired.insetBy(dx: -inset, dy: -inset)))
    }
}
