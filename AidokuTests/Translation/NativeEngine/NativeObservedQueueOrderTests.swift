import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeObservedQueueOrderTests {
    @Test func diffusePreservesTheOwningQueueOrderInsteadOfSortingTheMask() throws {
        let width = 32, height = 32
        var pixels = NativeRestorationPixels(width: width, height: height)
        for i in 0..<pixels.count {
            pixels.paint(i, NativeRestorationRGB([Double((i * 37 + 13) % 256), Double((i * 53 + 7) % 256), Double((i * 73 + 19) % 256)]))
        }
        let palette = NativeRestorationPixels.Palette(foreground: .init([0,0,0]), background: .init([240,240,240]), stroke: nil)
        let state = try #require(NativeObservedRestoreState(pixels, box: CGRect(x:4,y:4,width:24,height:24), palette: palette, options: .init()))
        let ascending = (8..<24).flatMap { y in (8..<24).map { y * width + $0 } }
        let ordered = Array(ascending.reversed())
        state.mask = Array(repeating: 0, count: pixels.count)
        for i in ordered { state.mask[i] = 1 }
        state.queue = ordered + Array(repeating: 0, count: pixels.count - ordered.count)
        state.queueTail = ordered.count
        state.coreCount = ordered.count
        let originalMask = state.mask
        var seed = pixels, frontMask = originalMask
        NativeObservedRestorationHelpers.fillFromDonorFront(p:&seed.rgba,w:width,n:pixels.count,queue:ordered,tail:ordered.count,
            mask:&frontMask,donorBlocked:state.donorBlocked,paintMask:originalMask)
        let expected = NativeRestorationPixels.harmonicFill(pixels,mask:originalMask,blocked:state.donorBlocked,seed:seed,
            accelerated:false,orderedQueue:ordered)
        let sorted = NativeRestorationPixels.harmonicFill(pixels,mask:originalMask,blocked:state.donorBlocked,seed:seed,
            accelerated:false,orderedQueue:ascending)
        #expect(expected.rgba != sorted.rgba)
        let actual = try #require(state.diffuse(nil))
        #expect(actual.rgba == expected.rgba)
        #expect(Array(state.queue.prefix(state.queueTail)) == ordered)
    }
}
