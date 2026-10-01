import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor struct NativeCanvasBackingTests {
    private func image() throws -> CGImage {
        let data = Data([25, 10, 5, 100, 0, 0, 0, 0, 0, 80, 10, 160, 60, 5, 5, 80])
        return try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func context(opaque: Bool) throws -> CGContext {
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 48,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<6 { for x in 0..<8 {
            let at = bytes + y * context.bytesPerRow + x * 4
            at[0] = UInt8(10 + x * 3); at[1] = UInt8(20 + y * 5); at[2] = UInt8(x + y + 1); at[3] = opaque ? 255 : 80
        } }
        context.translateBy(x: 0, y: 6); context.scaleBy(x: 2, y: -2)
        return context
    }
    private func draw(_ patch: NativeTranslationRenderer.SourcePatch, context: CGContext,
                      backing: NativeCanvasBacking?, live: Bool = true, clips: Bool = true) {
        UIGraphicsPushContext(context); defer { UIGraphicsPopContext() }
        NativeTranslationRenderer.drawSourcePatch(patch, context: context, appliesCanvasClip: clips,
            usesLiveTextureSampling: live, canvasBacking: backing)
    }

    @Test(arguments: [false, true]) func sourcePatchCopiesExactlyOneFloatSourceOverIntoActualCurrentBacking(opaque: Bool) throws {
        let context = try context(opaque: opaque)
        let backing = try #require(NativeCanvasBacking.freshCanonicalBitmap(context: context, pixelExtent: CGSize(width: 8, height: 6)))
        let full = CGRect(x: 0, y: 0, width: 4, height: 3)
        var expected = try #require(backing.backgroundRGBA(context: context, userRect: full))
        let source = try image()
        let patch = NativeTranslationRenderer.SourcePatch(image: source, rect: CGRect(x: -1, y: 0, width: 4, height: 3),
            cleanupClip: CGRect(x: 0, y: 0, width: 3, height: 2))
        let tileFrame = CGRect(x: 0, y: 0, width: 3, height: 2)
        let background = try #require(backing.backgroundRGBA(context: context, userRect: tileFrame))
        let tile = try NativeCanvasTextureResampler.compositeCanvasImage(image: source,
            destinationPixels: CGSize(width: 8, height: 6), cropPixels: CGRect(x: 2, y: 0, width: 6, height: 4), backgroundRGBA: background)
        let tileBytes = try #require(tile.dataProvider?.data) as Data
        for row in 0..<4 { expected.replaceSubrange(row * 32..<(row * 32 + 24), with: tileBytes[row * 24..<(row * 24 + 24)]) }
        draw(patch, context: context, backing: backing)
        #expect(backing.backgroundRGBA(context: context, userRect: full) == expected)
        #expect(backing.matchesFreshState(context))
        // The untouched border proves a bounded crop, while the alpha80 case
        // rejects applying normal source-over to the already-composited tile.
    }

    @Test func fractionalClipAndSavedPathRetainTheirIndependentExistingPainting() throws {
        let source = try image(), full = CGRect(x: 0, y: 0, width: 4, height: 3)
        for live in [false, true] {
            let actual = try context(opaque: false), old = try context(opaque: false)
            let backing = try #require(NativeCanvasBacking.freshCanonicalBitmap(context: actual, pixelExtent: CGSize(width: 8, height: 6)))
            let oldBacking = try #require(NativeCanvasBacking.freshCanonicalBitmap(context: old, pixelExtent: CGSize(width: 8, height: 6)))
            let patch = NativeTranslationRenderer.SourcePatch(image: source, rect: full,
                cleanupClip: CGRect(x: 0.125, y: 0, width: 3, height: 2))
            draw(patch, context: actual, backing: backing, live: live, clips: live)
            draw(patch, context: old, backing: nil, live: live, clips: live)
            #expect(backing.backgroundRGBA(context: actual, userRect: full) == oldBacking.backgroundRGBA(context: old, userRect: full))
            #expect(backing.matchesFreshState(actual))
        }
        let context = try context(opaque: false)
        #expect(NativeCanvasBacking.freshCanonicalBitmap(context: context, pixelExtent: CGSize(width: 7, height: 6)) == nil)
        let opaqueBacking = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        #expect(NativeCanvasBacking.freshCanonicalBitmap(context: opaqueBacking, pixelExtent: CGSize(width: 8, height: 6)) == nil)
    }
}
