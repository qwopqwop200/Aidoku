import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativePDFCropTests {
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }
    private func capture(_ bounds: CGRect, pixels: CGSize) throws -> NativeTranslationPDFCapture.Capture {
        try NativeTranslationPDFCapture.capture(bounds: bounds, pixels: pixels, deviceScale: 3) { context in
            context.setFillColor(CGColor(gray: 1,alpha: 1))
            context.fill(CGRect(x: -100,y: -100,width: 1000,height: 1000))
            context.setFillColor(CGColor(gray: 0,alpha: 1))
            // Distinct horizontal and vertical edges reveal either crop offset.
            context.fill(CGRect(x: 66,y: 0,width: 100,height: 10))
            context.fill(CGRect(x: 11,y: 21,width: 20,height: 10))
        }
    }
    @Test func aspectFitRoundoffDoesNotMoveSavedArtworkByOnePoint() throws {
        let bounds = ReaderTranslationGeometry.displayRect(CGRect(x: 0,y: 0,width: 1,height: 1),
            imageSize: CGSize(width: 100,height: 273),bounds: CGRect(x: 0,y: 0,width: 390,height: 700),aspectFit: true)
        #expect(bounds.origin.y < 0 && bounds.origin.y > -0.001)
        #expect(floor(bounds.origin.y) == -1)
        let expected = CGRect(x: 66,y: 0,width: 256,height: 700)
        #expect(NativeTranslationPDFCapture.integralCaptureRect(bounds) == expected)
        let outputSize = CGSize(width: 256,height: 700)
        let actual = try capture(bounds,pixels: outputSize)
        let reference = try capture(expected,pixels: outputSize)
        #expect(actual.mediaBox.size == expected.size)
        #expect(try pixels(actual.image) == pixels(reference.image))
    }
    @Test func floatRectRoundingPrecedesIntegralCropAndPageExtent() throws {
        let bounds = CGRect(x: 10.9999999,y: 20.9999999,width: 99.999999,height: 39.999999)
        let expected = CGRect(x: 11,y: 21,width: 100,height: 40)
        #expect(NativeTranslationPDFCapture.integralCaptureRect(bounds) == expected)
        let actual = try capture(bounds,pixels: expected.size)
        let reference = try capture(expected,pixels: expected.size)
        #expect(actual.mediaBox == CGRect(origin: .zero,size: expected.size))
        #expect(try pixels(actual.image) == pixels(reference.image))
        #expect(NativeTranslationPDFCapture.integralCaptureRect(CGRect(x: -0.75,y: -1.75,width: 100,height: 40)).origin == CGPoint(x: 0,y: -1))
    }
}
