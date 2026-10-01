import Testing
import CoreGraphics
import Foundation
@testable import Aidoku

struct NativeForeignBackgroundCompositorTests {
    @Test func canonicalPrefixKeepsPixelOrientationAndAlphaOutsideOwner() async throws {
        try await Task.detached {
            let (context, backing) = try Self.context()
            context.setFillColor(CGColor(red: 0.7, green: 0.1, blue: 0.2, alpha: 0.5))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 8))
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 36, width: 64, height: 12))
            let frame = CGRect(x: 0, y: 0, width: 64, height: 48)
            let before = try #require(backing.backgroundRGBA(context: context, userRect: frame))
            let transform = context.ctm, clip = context.boundingBoxOfClipPath
            let result = try #require(try NativeForeignBackgroundCompositor.compose(panel: Self.panel(),
                foreign: [Self.fill()], context: context, backing: backing))
            let bytes = try #require(result.image.dataProvider?.data as Data?)
            #expect(bytes.count == before.count)
            // The owner occupies rows20..60. Distinct top/bottom and partial
            // alpha sentinels detect a prefix-leaf or final-image Y inversion.
            for rows in [0..<16,72..<96] {
                for y in rows {
                    let start = y * 128 * 4
                    #expect(bytes.subdata(in: start..<(start + 128 * 4)) == before.subdata(in: start..<(start + 128 * 4)))
                }
            }
            #expect(backing.backgroundRGBA(context: context, userRect: frame) == before)
            #expect(context.ctm == transform && context.boundingBoxOfClipPath == clip)
            #expect(result.frame == frame)
        }.value
    }

    @Test(arguments: ["missing-capability", "rounded", "clip", "overflow", "too-many", "changed-context"])
    func unsupportedStateDeclinesWithoutMutation(reason: String) async throws {
        try await Task.detached {
            let (context, backing) = try Self.context()
            var panel = Self.panel(), fills = [Self.fill()]
            var capability: NativeCanvasBacking? = backing
            switch reason {
            case "missing-capability": capability = nil
            case "rounded": panel.radius = 3
            case "clip": panel.clipped = true
            case "overflow": panel.overflowClip = true
            case "too-many": fills = Array(repeating: Self.fill(), count: 3)
            case "changed-context": context.clip(to: CGRect(x: 0, y: 0, width: 32, height: 48))
            default: Issue.record("unknown fixture")
            }
            let raw = try #require(context.data)
            let before = Data(bytes: raw, count: context.bytesPerRow * context.height)
            let transform = context.ctm, clip = context.boundingBoxOfClipPath
            let result = try NativeForeignBackgroundCompositor.compose(panel: panel, foreign: fills,
                context: context, backing: capability)
            #expect(result == nil)
            #expect(Data(bytes: raw, count: context.bytesPerRow * context.height) == before)
            #expect(context.ctm == transform && context.boundingBoxOfClipPath == clip)
        }.value
    }

    private static func context() throws -> (CGContext, NativeCanvasBacking) {
        let context = try #require(CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8,
            bytesPerRow: 128 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: 96); context.scaleBy(x: 2, y: -2)
        let backing = try #require(NativeCanvasBacking.freshCanonicalBitmap(context: context, pixelExtent: CGSize(width: 128, height: 96)))
        return (context, backing)
    }
    private static func panel() -> NativeTranslationSourceStylePostPolish.Panel {
        var panel = NativeTranslationSourceStylePostPolish.Panel(rect: CGRect(x: 10, y: 10, width: 20, height: 20),
            background: [237,232,215], coverage: [])
        panel.radius = 0; return panel
    }
    private static func fill() -> NativeCaptionPacking.ForeignFill {
        .init(rect: CGRect(x: 13, y: 14, width: 8, height: 9), color: [220,30,40],
            backgroundPosition: CGPoint(x: 3, y: 4), backgroundSize: CGSize(width: 8, height: 9))
    }
}
