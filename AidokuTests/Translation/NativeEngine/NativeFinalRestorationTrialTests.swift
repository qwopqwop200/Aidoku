import CoreGraphics
import Testing
@testable import Aidoku

private final class FinalTrialTestCandidate: NativeFinalRestorationCandidate {
    var trialSurface: NativeResidualTopology.Surface
    init() {
        trialSurface = .init(width: 40, height: 32,
            rgba: Array(repeating: [UInt8](arrayLiteral: 200, 211, 222, 255), count: 1280).flatMap { $0 },
            safe: [UInt8](repeating: 1, count: 1280), luminance: [UInt8](repeating: 100, count: 1280),
            surfaceRevision: 7, coreClear: true, innerCoreClear: false, residualLettering: true)
    }
    func hole(x: Int, y: Int) {
        let i = y * 40 + x
        trialSurface.safe[i] = 0
        trialSurface.rgba.replaceSubrange((i * 4)..<(i * 4 + 4), with: [10, 20, 30, 60])
    }
}
@Suite struct NativeFinalRestorationTrialTests {
    private var geometry: NativeFinalRestorationTrial.Geometry {
        .init(imageSize: CGSize(width: 40, height: 32), frame: CGRect(x: 0, y: 0, width: 40, height: 32),
              cropOrigin: .zero, scale: CGSize(width: 1, height: 1), sourceBounds: [0.25, 0.25, 0.5, 0.5], sourceFontSize: 8)
    }

    @Test func sharedPixelsRecheckDropsInitialChromaticExemption() throws {
        let candidate = FinalTrialTestCandidate()
        candidate.hole(x: 15, y: 13); candidate.hole(x: 16, y: 14)
        let coverage = try #require(NativeFinalRestorationTrial.marginCoverage(geometry: geometry,
            sourceFrame: geometry.frame, oldPlate: CGRect(x: 8, y: 6, width: 24, height: 20),
            padding: CGSize(width: 3, height: 4), displayedFontSize: 10))
        #expect(coverage.regions == [[8, 6, 24, 20]] && coverage.core == [[10, 8, 20, 16]])
        #expect(NativeFinalRestorationTrial.certifiesEarlyMargin(surface: candidate.trialSurface, coverage: coverage,
            sourceVertical: false, sourceSingleColumn: true, restorationMethod: "chromatic-balloon-glyphs",
            sourceGlyphsVerified: true, sourceErasureVerified: true))
        #expect(!NativeFinalRestorationTrial.certifiesEarlyMargin(surface: candidate.trialSurface, coverage: coverage,
            sourceVertical: false, sourceSingleColumn: true, restorationMethod: "chromatic-balloon-glyphs",
            sourceGlyphsVerified: true, sourceErasureVerified: true, groupRecheck: true))
    }
}
