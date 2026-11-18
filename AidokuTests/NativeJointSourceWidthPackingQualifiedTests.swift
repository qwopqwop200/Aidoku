import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

/// Native glyph/effect supports; no corpus IDs, images or copied packing logic.
@Suite(.serialized) @MainActor
struct NativeJointSourceWidthPackingQualifiedTests {
    private typealias J = NativeJointSourceWidthPacking
    private typealias N = NativeFinalTextPaintAdmission
    private typealias P = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    private let page = CGRect(x: 0, y: 0, width: 3000, height: 1000)

    private func nativeRun() throws -> [P] {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 32, nil)
        let words = try NativeWholeWordWrap.layout(text: "WORD", font: font, size: 32,
            width: 180, color: CGColor(gray: 0, alpha: 1))
        try #require(words.completeOwnership && words.unresolvedGlyphRanges.isEmpty)
        let plan = try NativeWholeWordGlyphPainter.positionRetainedPitch(words, width: 180,
            pitch: 64, outwardExtent: 4)
        let glyph = try NativeWholeWordGlyphPainter.raster(plan, origin: CGPoint(x: 40, y: 80),
            scale: 1, pagePixels: page.size)
        func normalized(_ r: CGRect) -> [Double] {
            [r.minX/page.width, r.minY/page.height, r.width/page.width, r.height/page.height].map(Double.init)
        }
        let capacity = page.insetBy(dx: 1, dy: 1)
        let allowed = normalized(capacity)
        var fills: [P] = [], x: CGFloat = 400
        for i in 0..<11 {
            var f = glyph
            f.ownerID = "owner-\(i)"
            f.displayStrokeEndpoint = 255
            f.displayStrokeRatio = 0.125
            f.textPlacementGuide = .init(rectNormalized: normalized(CGRect(x: 100+i*200,
                y: 80, width: 24, height: 600)), horizontal: .center, vertical: .center)
            f.textExpansionPolicy = .init(allowedRectNormalized: allowed, candidates: [allowed],
                maskCoverage: [1], backgroundRisk: [0], sourceFontPixels: 32,
                kind: "source-near-limited-expansion", maskRectNormalized: nil, maskSpansNormalized: nil)
            f.sourceClusterAlignment = .init(groupID: "complete-source-run", axis: .top,
                anchorNormalized: 0.08, anchorPolicy: "source-near-final-alpha", anchorsToSourceStart: true)
            f.placementDomain = { capacity.contains($0) }
            let support = try N.retainedFootprint(f)
            f.frame = f.frame.offsetBy(dx: x-support.bounds.minX, dy: 80-support.bounds.minY)
            let placed = try N.retainedFootprint(f)
            try #require(capacity.contains(placed.bounds))
            x = placed.bounds.maxX+6
            fills.append(f)
        }
        return fills
    }

    @Test func paintedCouplingRetainsCompleteElevenOwnerRun() throws {
        let fills = try nativeRun()
        let support = try fills.map { try N.retainedFootprint($0) }
        #expect(J.sourceRuns(fills, page: page).count == 11)
        #expect(J.sourceRuns(fills, page: page, supports: support) == [Array(0..<11)])
    }

    @Test func actuallyIsolatedOwnerRemainsPinnedSeparateRun() throws {
        var fills = try nativeRun()
        fills[0].frame = fills[0].frame.offsetBy(dx: -360, dy: 0)
        let support = try fills.map { try N.retainedFootprint($0) }
        let runs = J.sourceRuns(fills, page: page, supports: support)
        #expect(runs == [[0], Array(1..<11)])
    }
}
