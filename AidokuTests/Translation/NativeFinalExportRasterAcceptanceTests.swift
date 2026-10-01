import Testing

struct NativeFinalExportRasterAcceptanceTests {
    @Test func lowColorAndBoundedSparseDifferencesAreAccepted() {
        for (changed, delta) in [(0, 0), (152, 4), (12_620, 3), (310, 1), (1290 * 2400, 4)] {
            #expect(NativeFinalExportRasterAcceptance.accepts(referenceWidth: 1290, referenceHeight: 2400,
                actualWidth: 1290, actualHeight: 2400, changedPixels: changed,
                pixelsOverLowDeltaLimit: delta > 4 ? changed : 0, maximumChannelDelta: delta))
        }
        // Focused17: the 152-pixel outline fringe has the same painted font/baseline;
        // page 8's 12,620 pixels differ by at most 3 color levels with unchanged layout.
        // These cases have the stated delta at every changed pixel; mixed cases are below.
        for (changed, delta, accepted) in [(73, 10, true), (3096, 16, true), (3097, 16, false),
                                          (3097, 4, true), (1, 17, false), (1290 * 2400, 5, false)] {
            #expect(NativeFinalExportRasterAcceptance.accepts(referenceWidth: 1290, referenceHeight: 2400,
                actualWidth: 1290, actualHeight: 2400, changedPixels: changed,
                pixelsOverLowDeltaLimit: delta > 4 ? changed : 0, maximumChannelDelta: delta) == accepted)
        }
        // Floor the sparse quota: a 999-pixel image cannot accept one pixel over 4.
        #expect(!NativeFinalExportRasterAcceptance.accepts(referenceWidth: 999, referenceHeight: 1,
            actualWidth: 999, actualHeight: 1, changedPixels: 1, pixelsOverLowDeltaLimit: 1, maximumChannelDelta: 5))
        #expect(NativeFinalExportRasterAcceptance.accepts(referenceWidth: 1000, referenceHeight: 1,
            actualWidth: 1000, actualHeight: 1, changedPixels: 1, pixelsOverLowDeltaLimit: 1, maximumChannelDelta: 16))
    }

    @Test func independentLowColorDifferencesDoNotSpendTheSparseModerateBudget() {
        // Actual focused24 page11: raw5,572/max16, of which1,901 pixels exceed4.
        // Raw metrics remain complete even when color categories compose.
        for (changed, stronger, maximum, accepted) in [
            (5572, 1901, 16, true), (100_000, 3096, 16, true), (100_000, 3097, 16, false),
            (100_000, 1, 17, false), (100_000, 1, 255, false), (100_000, 0, 4, true),
            (100_000, 0, 16, false), (100_000, -1, 4, false), (100, 101, 16, false),
            (100_000, 1, 4, false)
        ] {
            #expect(NativeFinalExportRasterAcceptance.accepts(referenceWidth: 1290, referenceHeight: 2400,
                actualWidth: 1290, actualHeight: 2400, changedPixels: changed,
                pixelsOverLowDeltaLimit: stronger, maximumChannelDelta: maximum) == accepted)
        }
    }

    @Test func materialGlyphShapeAndColorChangesRemainFailures() {
        // The measured page0 maximum255 fails even if only one pixel exceeded4.
        #expect(!NativeFinalExportRasterAcceptance.accepts(referenceWidth: 1290, referenceHeight: 2400,
            actualWidth: 1290, actualHeight: 2400, changedPixels: 5804, pixelsOverLowDeltaLimit: 1, maximumChannelDelta: 255))
        func glyph(shift: Int = 0, thick: Bool = false, extraLine: Bool = false) -> [UInt8] {
            (0..<64).map { index in
                let x = index % 8, y = index / 8
                let stem = (x == 2 + shift || (thick && x == 3 + shift)) && (1...5).contains(y)
                let foot = y == 5 && ((2 + shift)...(5 + shift)).contains(x)
                let added = extraLine && y == 7 && (2...5).contains(x)
                return stem || foot || added ? 20 : 255
            }
        }
        let original = glyph()
        for candidate in [glyph(shift: 1), glyph(thick: true), glyph(extraLine: true), [UInt8](repeating: 255, count: 64)] {
            let differences = zip(original, candidate).map { abs(Int($0) - Int($1)) }
            let changed = differences.filter { $0 != 0 }.count, maximum = differences.max() ?? 0
            #expect(changed > 0 && maximum > 16)
            #expect(!NativeFinalExportRasterAcceptance.accepts(referenceWidth: 8, referenceHeight: 8,
                actualWidth: 8, actualHeight: 8, changedPixels: changed,
                pixelsOverLowDeltaLimit: differences.filter { $0 > 4 }.count, maximumChannelDelta: maximum))
        }
    }

    @Test func dimensionsAndMalformedMeasurementsCannotPass() {
        #expect(!NativeFinalExportRasterAcceptance.accepts(referenceWidth: 1290, referenceHeight: 2400,
            actualWidth: 2400, actualHeight: 1290, changedPixels: 0, pixelsOverLowDeltaLimit: 0, maximumChannelDelta: 0))
        #expect(!NativeFinalExportRasterAcceptance.accepts(referenceWidth: 0, referenceHeight: 2400,
            actualWidth: 0, actualHeight: 2400, changedPixels: 0, pixelsOverLowDeltaLimit: 0, maximumChannelDelta: 0))
        #expect(!NativeFinalExportRasterAcceptance.accepts(referenceWidth: Int.max, referenceHeight: 2,
            actualWidth: Int.max, actualHeight: 2, changedPixels: 0, pixelsOverLowDeltaLimit: 0, maximumChannelDelta: 0))
        for (changed, delta) in [(-1, 1), (1, -1), (101, 1), (0, 1), (1, 0)] {
            #expect(!NativeFinalExportRasterAcceptance.accepts(referenceWidth: 10, referenceHeight: 10,
                actualWidth: 10, actualHeight: 10, changedPixels: changed,
                pixelsOverLowDeltaLimit: delta > 4 ? changed : 0, maximumChannelDelta: delta))
        }
    }
}
