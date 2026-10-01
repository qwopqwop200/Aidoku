import Testing

struct NativeSourceCanvasRasterAcceptanceTests {
    @Test func permitsSparseSingleLevelRasterRounding() {
        #expect(NativeSourceCanvasRasterAcceptance.accepts(referenceWidth: 480, referenceHeight: 240,
            actualWidth: 480, actualHeight: 240, changedPixels: 1, maximumChannelDelta: 1))
        #expect(NativeSourceCanvasRasterAcceptance.accepts(referenceWidth: 960, referenceHeight: 480,
            actualWidth: 960, actualHeight: 480, changedPixels: 2, maximumChannelDelta: 1))
    }

    @Test func fractionBoundaryIsInclusiveWithoutRoundingUp() {
        #expect(NativeSourceCanvasRasterAcceptance.accepts(referenceWidth: 200, referenceHeight: 100,
            actualWidth: 200, actualHeight: 100, changedPixels: 2, maximumChannelDelta: 1))
        #expect(!NativeSourceCanvasRasterAcceptance.accepts(referenceWidth: 200, referenceHeight: 100,
            actualWidth: 200, actualHeight: 100, changedPixels: 3, maximumChannelDelta: 1))
        #expect(!NativeSourceCanvasRasterAcceptance.accepts(referenceWidth: 199, referenceHeight: 100,
            actualWidth: 199, actualHeight: 100, changedPixels: 2, maximumChannelDelta: 1))
    }

    @Test func rejectsLargerErrorsWidespreadChangesAndChangedDimensions() {
        #expect(!NativeSourceCanvasRasterAcceptance.accepts(referenceWidth: 960, referenceHeight: 480,
            actualWidth: 960, actualHeight: 480, changedPixels: 1, maximumChannelDelta: 2))
        #expect(!NativeSourceCanvasRasterAcceptance.accepts(referenceWidth: 960, referenceHeight: 480,
            actualWidth: 960, actualHeight: 480, changedPixels: 1_000, maximumChannelDelta: 1))
        #expect(!NativeSourceCanvasRasterAcceptance.accepts(referenceWidth: 960, referenceHeight: 480,
            actualWidth: 480, actualHeight: 960, changedPixels: 0, maximumChannelDelta: 0))
    }

    @Test func rejectsInvalidOrOverflowingDimensions() {
        #expect(!NativeSourceCanvasRasterAcceptance.accepts(referenceWidth: 0, referenceHeight: 480,
            actualWidth: 0, actualHeight: 480, changedPixels: 0, maximumChannelDelta: 0))
        #expect(!NativeSourceCanvasRasterAcceptance.accepts(referenceWidth: Int.max, referenceHeight: 2,
            actualWidth: Int.max, actualHeight: 2, changedPixels: 0, maximumChannelDelta: 0))
    }
}
