import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeRetainedFootprintMemoTests {
    private typealias N = NativeFinalTextPaintAdmission
    private typealias P = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    private func fill(extraPixel: Bool = false) throws -> P {
        var rgba = [UInt8](repeating: 0, count: 13 * 11 * 4)
        for y in 2..<9 { for x in 3..<10 { rgba[(y * 13 + x) * 4 + 3] = 255 } }
        if extraPixel { rgba[(10 * 13 + 12) * 4 + 3] = 255 }
        let image = try NativeMandatoryDisplayStroke.image(rgba, width: 13, height: 11)
        var result = P(image: image, frame: CGRect(x: 30, y: 40, width: 13, height: 11),
            fontOutputPixels: 24, ownerID: "synthetic-owner")
        result.sourceStyle = .init(sourceFontPixels: 24, bands: [.init(rgb: [50, 80, 120], width: 2)], shadow: nil)
        return result
    }
    private func same(_ a: N.Footprint, _ b: N.Footprint) -> Bool {
        a.bounds == b.bounds && a.pixels == b.pixels && a.readableBounds == b.readableBounds
            && a.runs.count == b.runs.count
            && zip(a.runs, b.runs).allSatisfy { $0.y == $1.y && $0.left == $1.left && $0.right == $1.right }
    }

    @Test func sameLiveRasterReusesDigestWithoutReusingDifferentPixels() throws {
        let first = try fill()
        let changed = try fill(extraPixel: true)
        let memo = N.RetainedFootprintMemo()
        try N.$retainedFootprintMemo.withValue(memo) {
            let baseline = try N.retainedFootprint(first)
            #expect(same(try N.retainedFootprint(first), baseline))
            #expect(!same(try N.retainedFootprint(changed), baseline))
        }
        #expect(memo.audit["rasterDigestIdentityHits"] as? Int == 1)
        #expect(memo.audit["canonicalRGBABytesRead"] as? Int == 2 * 13 * 11 * 4)
        #expect(memo.audit["retainedCGImages"] as? Int == 0)
    }
    @Test func integerTranslationReusesExactLocalAlphaAcrossEquivalentImages() throws {
        let first = try fill(), baseline = try N.retainedFootprint(first), memo = N.RetainedFootprintMemo()
        var moved = try fill(); moved.frame = moved.frame.offsetBy(dx: 17, dy: 29); moved.ownerID = "other-owner"
        let actual = try N.$retainedFootprintMemo.withValue(memo) {
            _ = try N.retainedFootprint(first)
            return try N.retainedFootprint(moved)
        }
        #expect(same(actual, baseline.translated(CGPoint(x: 17, y: 29))))
        #expect(memo.audit["hits"] as? Int == 1 && memo.audit["entries"] as? Int == 1)
        #expect(memo.audit["retainedCGImages"] as? Int == 0)
    }
    @Test func tightCropDigestFollowsItsImmutableSourceAcrossTranslationsAndReplacements() throws {
        let memo = N.RetainedFootprintMemo()
        let first = try fill()
        var moved = first
        moved.frame = first.frame.offsetBy(dx: 7, dy: -5)
        var changed = try fill(extraPixel: true)
        changed.ownerID = first.ownerID
        let expected = try [first, moved, changed].map { try N.retainedFootprint(N.tight($0)) }
        try N.$retainedFootprintMemo.withValue(memo) {
            for (i, primitive) in [first, moved, changed].enumerated() {
                let crop = try N.tight(primitive)
                #expect(same(try N.retainedFootprint(crop), expected[i]))
            }
        }
        #expect(memo.audit["tightBoundsHits"] as? Int == 1)
        #expect((memo.audit["tightDigestHits"] as? Int ?? 0) + (memo.audit["rasterDigestIdentityHits"] as? Int ?? 0) >= 1)
        #expect(memo.audit["retainedCGImages"] as? Int == 0)
    }

    @Test func smallRequestBudgetRetainsSpaceForMeasuredFootprints() {
        let audit = N.RetainedFootprintMemo(byteLimit: 65_536).audit
        #expect((audit["cropWitnessPayloadReserve"] as? Int ?? .max) <= 4_096)
        #expect((audit["geometryAndKeyPayloadByteLimit"] as? Int ?? 0) >= 61_440)
    }

    @Test func disabledCropWitnessBudgetStillRejectsEmptyGlyphAlpha() throws {
        let memo = N.RetainedFootprintMemo(byteLimit: 0)
        var value = try fill()
        let width = value.image.width, height = value.image.height
        value.image = try NativeMandatoryDisplayStroke.image(
            [UInt8](repeating: 0, count: width * height * 4), width: width, height: height)
        N.$retainedFootprintMemo.withValue(memo) {
            #expect(throws: NativeMandatoryDisplayStroke.Failure.self) { try N.tight(value) }
        }
        #expect(memo.audit["cropWitnessPayloadReserve"] as? Int == 0)
        #expect(memo.audit["tightSourceEntries"] as? Int == 0)
    }

    @Test func everyRasterAndPaintParameterChangeIsComparedWithUncachedNativeAlpha() throws {
        let base = try fill(), memo = N.RetainedFootprintMemo()
        var stroke = base; stroke.displayStrokeRatio = 0.035
        var font = P(image: base.image, frame: base.frame, fontOutputPixels: 32, ownerID: base.ownerID)
        font.sourceStyle = base.sourceStyle
        var shadow = base
        shadow.sourceStyle = .init(sourceFontPixels: 24, bands: [.init(rgb: [50, 80, 120], width: 3)],
            shadow: .init(rgb: [0, 0, 0], offset: [2, 3]))
        let variants = [base, stroke, font, shadow, try fill(extraPixel: true)]
        for value in variants {
            let expected = try N.retainedFootprint(value)
            let actual = try N.$retainedFootprintMemo.withValue(memo) { try N.retainedFootprint(value) }
            #expect(same(actual, expected))
        }
        #expect(memo.audit["entries"] as? Int == variants.count)
        #expect(memo.audit["hits"] as? Int == 0)
    }
    @Test func zeroRetentionBudgetCannotRejectAnOtherwiseValidNativeFootprint() throws {
        let value = try fill(), expected = try N.retainedFootprint(value)
        let memo = N.RetainedFootprintMemo(byteLimit: 0, entryLimit: 0)
        try N.$retainedFootprintMemo.withValue(memo) {
            let first = try N.retainedFootprint(value)
            let second = try N.retainedFootprint(value)
            #expect(same(first, expected))
            #expect(same(second, expected))
        }
        #expect(memo.audit["entries"] as? Int == 0)
        #expect(memo.audit["geometryAndKeyPayloadBytes"] as? Int == 0)
    }
    @Test func fractionalOriginsBypassMemoWithoutChangingExistingGeometry() throws {
        var value = try fill(); value.frame = value.frame.offsetBy(dx: 0.5, dy: 0.25)
        let expected = try N.retainedFootprint(value), memo = N.RetainedFootprintMemo()
        let actual = try N.$retainedFootprintMemo.withValue(memo) { try N.retainedFootprint(value) }
        #expect(same(expected, actual))
        #expect(memo.audit["entries"] as? Int == 0 && memo.audit["bypasses"] as? Int == 1)
    }
    @Test func invalidPaintStillThrowsAndNeverProducesCachedSuccess() throws {
        var invalid = try fill()
        invalid.sourceStyle = .init(sourceFontPixels: 24, bands: [.init(rgb: [0, 0, 0], width: 1_000)], shadow: nil)
        let memo = N.RetainedFootprintMemo()
        var rejected = false
        do { _ = try N.$retainedFootprintMemo.withValue(memo) { try N.retainedFootprint(invalid) } }
        catch { rejected = true }
        #expect(rejected && memo.audit["entries"] as? Int == 0)
    }
    @Test func boundedEvictionRecomputesOldShapesWithoutChangingTheirAlpha() throws {
        let first = try fill(), second = try fill(extraPixel: true)
        let expected = try N.retainedFootprint(first), memo = N.RetainedFootprintMemo(entryLimit: 1)
        let actual = try N.$retainedFootprintMemo.withValue(memo) {
            _ = try N.retainedFootprint(first)
            _ = try N.retainedFootprint(second)
            return try N.retainedFootprint(first)
        }
        #expect(same(expected, actual))
        #expect(memo.audit["entries"] as? Int == 1 && memo.audit["evictions"] as? Int == 2)
        let retained = try #require(memo.audit["geometryAndKeyPayloadBytes"] as? Int)
        let limit = try #require(memo.audit["geometryAndKeyPayloadByteLimit"] as? Int)
        #expect(retained <= limit)
    }
}
