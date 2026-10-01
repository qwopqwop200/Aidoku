import Testing

struct NativeFinalExportDisplacementTests {
    private let width = 1024
    private let height = 512

    @Test func commonSubpixelCoverageAndOnePixelMovesPreserveShape() {
        let reference = glyphs()
        for axis in 0..<2 {
            for direction in [-1, 1] {
                for quarter in 1...4 {
                    let actual = shifted(reference, axis: axis, direction: direction, quarter: quarter)
                    let evidence = NativeFinalExportRasterAcceptance.displacement(
                        reference: reference, actual: actual, width: width, height: height, actualWidth: width, actualHeight: height)
                    #expect(evidence != nil)
                    #expect(evidence?.axis == (axis == 0 ? "y" : "x"))
                    #expect(evidence?.direction == direction)
                    #expect(evidence?.coverage == Double(quarter) / 4)
                    #expect(evidence?.maximumFitResidual == 0)
                }
            }
        }
    }

    @Test func materialAndIndependentlyScatteredGlyphChangesFail() {
        let reference = glyphs()
        for axis in 0..<2 {
            for direction in [-2, 2] {
                rejects(reference, shifted(reference, axis: axis, direction: direction))
            }
        }
        var thicker = reference
        for y in 0..<64 {
            for x in 1..<96 where reference[(y * width + x - 1) * 4] == 3 {
                paint(&thicker, x: x, y: y, color: 3)
            }
        }
        rejects(reference, thicker)
        var missing = reference
        rectangle(&missing, x: 60...75, y: 10...48, color: 255)
        rejects(reference, missing)
        var extraLine = reference
        rectangle(&extraLine, x: 14...68, y: 51...53)
        rejects(reference, extraLine)
        var alteredFont = reference
        rectangle(&alteredFont, x: 34...58, y: 11...47, color: 255)
        rectangle(&alteredFont, x: 38...41, y: 15...43)
        rectangle(&alteredFont, x: 38...53, y: 15...18)
        rectangle(&alteredFont, x: 38...51, y: 28...31)
        rectangle(&alteredFont, x: 38...53, y: 40...43)
        rejects(reference, alteredFont)
        var pair = blank()
        rectangle(&pair, x: 20...23, y: 15...43)
        rectangle(&pair, x: 50...53, y: 15...43)
        // Total ink and every horizontal projection remain exact, and all
        // differences are in a one-pixel neighborhood. A shared move still fails.
        var balanced = pair
        rectangle(&balanced, x: 24...24, y: 15...43)
        rectangle(&balanced, x: 53...53, y: 15...43, color: 255)
        rejects(pair, balanced)
        var independent = blank()
        rectangle(&independent, x: 19...22, y: 15...43)
        rectangle(&independent, x: 51...54, y: 15...43)
        rejects(pair, independent)
    }

    @Test func borderAlphaQuotaDimensionsAndSearchBoundsRemainStrict() {
        let reference = glyphs(), actual = shifted(reference, axis: 0, direction: 1)
        var borderReference = reference, borderActual = actual
        paint(&borderReference, x: 12, y: 13, color: 100)
        paint(&borderActual, x: 12, y: 13, color: 100)
        rejects(borderReference, borderActual)
        var alphaReference = reference, alphaActual = actual
        alphaReference[(20 * width + 20) * 4 + 3] = 254; alphaActual[(20 * width + 20) * 4 + 3] = 254
        rejects(alphaReference, alphaActual)
        var outsideReference = reference, outsideActual = actual
        outsideReference[3] = 0; outsideActual[3] = 0
        let unchangedOutsideAlphaAccepted = NativeFinalExportRasterAcceptance.displacement(reference: outsideReference,
            actual: outsideActual, width: width, height: height, actualWidth: width, actualHeight: height) != nil
        #expect(unchangedOutsideAlphaAccepted)
        outsideActual[3] = 1
        rejects(outsideReference, outsideActual)
        let malformedBufferRejected = NativeFinalExportRasterAcceptance.displacement(reference: reference,
            actual: Array(actual.dropLast()), width: width, height: height, actualWidth: width, actualHeight: height) == nil
        #expect(malformedBufferRejected)
        let zeroWidthRejected = NativeFinalExportRasterAcceptance.displacement(reference: reference,
            actual: actual, width: 0, height: height, actualWidth: 0, actualHeight: height) == nil
        #expect(zeroWidthRejected)
        let overflowingSizeRejected = NativeFinalExportRasterAcceptance.displacement(reference: reference,
            actual: actual, width: Int.max, height: 2, actualWidth: Int.max, actualHeight: 2) == nil
        #expect(overflowingSizeRejected)
        let swappedDimensionsRejected = NativeFinalExportRasterAcceptance.displacement(reference: reference,
            actual: actual, width: width, height: height, actualWidth: height, actualHeight: width) == nil
        #expect(swappedDimensionsRejected)
        var tiny = [UInt8](repeating: 255, count: 24 * 24 * 4), tinyMoved = tiny
        for channel in 0..<3 { tiny[(10 * 24 + 10) * 4 + channel] = 3; tinyMoved[(11 * 24 + 10) * 4 + channel] = 3 }
        #expect(NativeFinalExportRasterAcceptance.displacement(reference: tiny,
            actual: tinyMoved, width: 24, height: 24, actualWidth: 24, actualHeight: 24) == nil)
        var scattered = blank(), scatteredMoved = blank()
        for (x, y) in [(20, 20), (600, 400)] {
            paint(&scattered, x: x, y: y, color: 3)
            paint(&scatteredMoved, x: x, y: y + 1, color: 3)
        }
        rejects(scattered, scatteredMoved)
    }

    private func blank() -> [UInt8] { [UInt8](repeating: 255, count: width * height * 4) }

    private func glyphs() -> [UInt8] {
        var result = blank()
        rectangle(&result, x: 14...17, y: 15...43)
        rectangle(&result, x: 14...29, y: 40...43)
        rectangle(&result, x: 38...53, y: 15...18)
        rectangle(&result, x: 38...41, y: 15...43)
        rectangle(&result, x: 50...53, y: 15...43)
        rectangle(&result, x: 38...53, y: 28...31)
        rectangle(&result, x: 65...68, y: 15...35)
        rectangle(&result, x: 65...68, y: 40...43)
        return result
    }

    private func paint(_ pixels: inout [UInt8], x: Int, y: Int, color: UInt8) {
        for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = color }
    }

    private func rectangle(_ pixels: inout [UInt8], x: ClosedRange<Int>, y: ClosedRange<Int>, color: UInt8 = 3) {
        for row in y { for column in x { paint(&pixels, x: column, y: row, color: color) } }
    }

    private func shifted(_ reference: [UInt8], axis: Int, direction: Int, quarter: Int = 4) -> [UInt8] {
        var result = reference
        for y in 3..<64 {
            for x in 3..<96 {
                let offset = (y * width + x) * 4
                let previous = offset - (axis == 0 ? width : 1) * direction * 4
                for channel in 0..<3 {
                    result[offset + channel] = UInt8((Int(reference[offset + channel]) * (4 - quarter)
                        + Int(reference[previous + channel]) * quarter) / 4)
                }
            }
        }
        return result
    }

    private func rejects(_ reference: [UInt8], _ actual: [UInt8]) {
        // Keep the two 2 MiB RGBA arguments out of assertion macro diagnostics.
        let displacementRejected = NativeFinalExportRasterAcceptance.displacement(
            reference: reference, actual: actual, width: width, height: height, actualWidth: width, actualHeight: height) == nil
        #expect(displacementRejected)
    }
}
