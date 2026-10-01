import Testing
@testable import Aidoku

struct NativeSlantedCompletionBoundsTests {
    @Test(arguments: [[1, 1], [1, 2], [2, 1], [2, 2], [1, 5], [5, 1], [2, 5], [5, 2]])
    func seededTinyStrokeStillCompletesWithoutInteriorPixels(_ size: [Int]) {
        let width = size[0], height = size[1]
        var page = NativeRestorationPixels(width: width, height: height)
        page.rgba = Array(repeating: [UInt8](arrayLiteral: 100, 100, 100, 255), count: page.count).flatMap { $0 }
        let original = page.rgba, donor: [UInt8] = [247, 248, 249, 255]
        var output = [UInt8](repeating: 0, count: page.count * 4)
        output.replaceSubrange(0..<4, with: donor)
        var safe = [UInt8](repeating: 1, count: page.count)
        let erased = complete(page, output: &output, safe: &safe, reading: false)
        #expect(erased == page.count - 1)
        #expect(output == Array(repeating: donor, count: page.count).flatMap { $0 })
        #expect(safe == [UInt8](repeating: 1, count: page.count))
        #expect(page.rgba == original)
    }

    @Test(arguments: [[1, 2], [2, 1], [2, 2], [1, 5], [5, 1], [2, 5], [5, 2]])
    func tinyReadingAnnotationDoesNotInventErasureWithoutSupport(_ size: [Int]) {
        var page = NativeRestorationPixels(width: size[0], height: size[1])
        page.rgba = Array(repeating: [UInt8](arrayLiteral: 100, 100, 100, 255), count: page.count).flatMap { $0 }
        let original = page.rgba
        var output = [UInt8](repeating: 0, count: page.count * 4)
        var safe = [UInt8](repeating: 1, count: page.count)
        let erased = complete(page, output: &output, safe: &safe, reading: true)
        #expect(erased == 0)
        #expect(output == [UInt8](repeating: 0, count: page.count * 4))
        #expect(safe == [UInt8](repeating: 1, count: page.count))
        #expect(page.rgba == original)
    }

    private func complete(_ page: NativeRestorationPixels, output: inout [UInt8], safe: inout [UInt8], reading: Bool) -> Int {
        let region = [0.0, 0, Double(page.width), Double(page.height)]
        return NativeSlantedRestoration.completeNativeFringe(page, output: &output, safe: &safe,
            fg: [0, 0, 0], bg: [255, 255, 255], coefficients: [[255, 0, 0], [255, 0, 0], [255, 0, 0]],
            regions: [region], auxiliary: reading ? [region] : [], vertical: reading, lw: page.width, lh: page.height,
            cx: 0, cy: 0, c: 1, s: 0, ox: 0, oy: 0)
    }
}
