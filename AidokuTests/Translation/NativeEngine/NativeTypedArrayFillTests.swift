import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeTypedArrayFillTests {
    @Test func negativeAbsoluteEndWrapsAcrossRowsLikeFrozenTypedArray() {
        var mask = [UInt8](repeating: 0, count: 192)
        // Literal frozen excluded rectangle [-45, 2, 8, 5] in a 16x12 crop.
        // The first two rows end at -18 and -2, which become 174 and 190.
        for row in 1...9 {
            NativeTypedArrayFill.fill(&mask, value: 1, start: Double(row * 16 + 1), end: Double(row * 16 - 34))
        }
        #expect(mask == (0..<192).map { (17..<190).contains($0) ? UInt8(1) : 0 })
    }

    @Test func typedFillClampsInfiniteAndFractionalIndicesWithoutIntegerOverflow() {
        var bytes = [UInt8](repeating: 0, count: 7)
        NativeTypedArrayFill.fill(&bytes, value: 9, start: -Double.infinity, end: -1.9)
        #expect(bytes == [9, 9, 9, 9, 9, 9, 0])
        NativeTypedArrayFill.fill(&bytes, value: 3, start: .nan, end: 2.9)
        #expect(bytes == [3, 3, 9, 9, 9, 9, 0])
        NativeTypedArrayFill.fill(&bytes, value: 4, start: 6, end: Double.infinity)
        #expect(bytes == [3, 3, 9, 9, 9, 9, 4])
        NativeTypedArrayFill.fill(&bytes, value: 1, start: 1e308, end: -1e308)
        #expect(bytes == [3, 3, 9, 9, 9, 9, 4])
    }

    @Test func shortOptionalMasksMatchUndefinedBrowserCellsInFullForcedPolicy() throws {
        let rgba = Array(repeating: [UInt8](arrayLiteral: 200, 210, 220, 255), count: 400).flatMap { $0 }
        let box = CGRect(x: 7, y: 7, width: 5, height: 5)
        let baseline = NativeForcedSourceInpainting.restore(rgba: rgba, width: 20, height: 20, box: box, palette: nil)
        let expected = try #require(baseline.result)
        for mask in [[UInt8](), [1]] {
            var options = NativeForcedSourceInpainting.Options()
            options.excludedMask = mask; options.protected = mask
            let tested = NativeForcedSourceInpainting.restore(rgba: rgba, width: 20, height: 20, box: box, palette: nil, options: options)
            let actual = try #require(tested.result)
            #expect(tested.failure == baseline.failure && actual.rgba == expected.rgba)
            #expect(actual.layoutSafe == expected.layoutSafe && actual.method == expected.method)
        }
    }

}
