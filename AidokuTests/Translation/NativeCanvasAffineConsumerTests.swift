import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor struct NativeCanvasAffineConsumerTests {
    private let page = CGSize(width: 40, height: 40)
    private func source(edge: Int = 2, alpha: UInt8 = 255) throws -> CGImage {
        let pixel: [UInt8] = alpha == 255 ? [40,100,180,255] : [20,50,90,128]
        let data = Data(Array(repeating: pixel, count: edge * edge).flatMap { $0 })
        return try #require(CGImage(width: edge, height: edge, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: edge * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func capture(_ source: CGImage, permission: Bool, cleanup: CGRect? = nil) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: page, format: format).image { value in
            let c = value.cgContext
            c.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [10.0/255,20.0/255,30.0/255,1])!)
            c.fill(CGRect(origin: .zero, size: page))
            c.concatenate(CGAffineTransform(a: 1.5, b: 0, c: 0, d: 2, tx: 0.25, ty: 0.375))
            let before = c.ctm, clip = c.boundingBoxOfClipPath
            let session = NativeCanvasTextureResampler.Session(); defer { session.close() }
            let patch = NativeTranslationRenderer.SourcePatch(image: source,
                rect: CGRect(x: 2.25, y: 3.25, width: 14.5, height: 12.5), cleanupClip: cleanup)
            NativeTranslationRenderer.drawSourcePatch(patch, context: c, usesLiveTextureSampling: true,
                canvasSession: session, allowsOpaqueAffineSampling: permission)
            #expect(c.ctm == before)
            #expect(c.boundingBoxOfClipPath == clip)
        }
        let cg = try #require(image.cgImage)
        let c = try #require(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        c.draw(cg, in: CGRect(origin: .zero, size: page))
        return Data(bytes: try #require(c.data), count: cg.width * cg.height * 4)
    }

    @Test func transformedOpaqueCanvasPaintsOnceInDeviceCoordinatesAndPreservesBackdrop() throws {
        let actual = try capture(source(), permission: true)
        // Literal CSS edges round to x[2,17],y[3,16]. The nonuniform
        // device-edge pass gives x[3,26],y[6,32] before parent translation.
        // Pixel centers therefore cover x3...25,y6...31 at the chosen offset.
        var expected = Data()
        for y in 0..<40 { for x in 0..<40 {
            expected.append(contentsOf: (3..<26).contains(x) && (6..<32).contains(y)
                ? [40,100,180,255] : [10,20,30,255])
        } }
        #expect(actual == expected)
        let former = try capture(source(), permission: false)
        #expect(actual != former)
    }

    @Test(arguments: ["translucent", "minified", "fractional-clip"])
    func unsupportedAffineCasesKeepTheExistingCoreGraphicsPath(_ mode: String) throws {
        let image = try source(edge: mode == "minified" ? 64 : 2, alpha: mode == "translucent" ? 128 : 255)
        let clip = mode == "fractional-clip" ? CGRect(x: 4.125, y: 5.375, width: 8.75, height: 6.125) : nil
        #expect(try capture(image, permission: true, cleanup: clip) == capture(image, permission: false, cleanup: clip))
    }

    @Test func cancellationDoesNotRestartSourcePaintingThroughFallback() async throws {
        let image = try source()
        let task = Task { @MainActor in try capture(image, permission: true) }
        task.cancel()
        let actual = try await task.value
        #expect(actual == Data(Array(repeating: [UInt8(10),20,30,255], count: 40 * 40).flatMap { $0 }))
    }
}
