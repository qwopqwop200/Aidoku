import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeCanvasTextureResamplerTests {
    @Test func floatSourceOverPreservesDestinationAndBlendsOnce() throws {
        let pixels = Data([0, 0, 0, 0, 30, 20, 10, 128, 70, 80, 90, 255])
        let image = try #require(CGImage(width: 3, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let result = try NativeCanvasTextureResampler.compositeCanvasImage(image: image,
            destinationPixels: CGSize(width: 3, height: 1), cropPixels: CGRect(x: 0, y: 0, width: 3, height: 1),
            backgroundRGBA: Data([11, 22, 33, 64, 50, 40, 30, 128, 41, 65, 87, 255]))
        #expect(result.dataProvider!.data! as Data == Data([11, 22, 33, 64, 55, 40, 25, 192, 70, 80, 90, 255]))
    }
    @Test func compositedVisibleCropRetainsFullDestinationUV() throws {
        let input = try source(), size = CGSize(width: 173, height: 91)
        var background = Data(count: 173 * 91 * 4)
        for i in 0..<(173 * 91) {
            background[i * 4] = UInt8(i % 63); background[i * 4 + 1] = UInt8(i % 91)
            background[i * 4 + 2] = 17; background[i * 4 + 3] = 128
        }
        let full = try NativeCanvasTextureResampler.compositeCanvasImage(image: input, destinationPixels: size,
            cropPixels: CGRect(origin: .zero, size: size), backgroundRGBA: background)
        var croppedBackground = Data(), expected = Data()
        let fullBytes = full.dataProvider!.data! as Data
        for row in 27..<74 {
            let range = ((row * 173 + 63) * 4)..<((row * 173 + 134) * 4)
            croppedBackground.append(background[range]); expected.append(fullBytes[range])
        }
        let crop = try NativeCanvasTextureResampler.compositeCanvasImage(image: input, destinationPixels: size,
            cropPixels: CGRect(x: 63, y: 27, width: 71, height: 47), backgroundRGBA: croppedBackground)
        #expect(crop.dataProvider!.data! as Data == expected)
        #expect(throws: NativeCanvasTextureResampler.Failure.self) {
            _ = try NativeCanvasTextureResampler.compositeCanvasImage(image: input, destinationPixels: size,
                cropPixels: CGRect(x: 63, y: 27, width: 71, height: 47), backgroundRGBA: Data(count: 3))
        }
        // Malformed destination bytes must fail before consulting/uploading a source.
        let closed = NativeCanvasTextureResampler.Session(); closed.close()
        do {
            _ = try NativeCanvasTextureResampler.compositeCanvasImage(image: input, destinationPixels: size,
                cropPixels: CGRect(x: 63, y: 27, width: 71, height: 47), backgroundRGBA: Data(count: 3), session: closed)
            Issue.record("Malformed destination was admitted")
        } catch NativeCanvasTextureResampler.Failure.invalidGeometry {
            // Validation precedes the closed source-session rejection.
        } catch {
            Issue.record("Source consulted before destination validation: \(error)")
        }
    }
    private func source() throws -> CGImage {
        var bytes = Data(count: 16 * 12 * 4)
        for i in 0..<(16 * 12) {
            let alpha = [0, 64, 128, 255][i % 4]
            bytes[i * 4] = UInt8((i * 23 % 256) * alpha / 255)
            bytes[i * 4 + 1] = UInt8((i * 41 % 256) * alpha / 255)
            bytes[i * 4 + 2] = UInt8((i * 11 % 256) * alpha / 255)
            bytes[i * 4 + 3] = UInt8(alpha)
        }
        return try #require(CGImage(width: 16, height: 12, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    @Test func premultipliedIdentityAndVisibleCrop() throws {
        let input = try source()
        let identity = try NativeCanvasTextureResampler.resample(image: input, outputPixelSize: CGSize(width: 16, height: 12))
        #expect(identity.dataProvider!.data! as Data == input.dataProvider!.data! as Data)
        let full = try NativeCanvasTextureResampler.resample(image: input, outputPixelSize: CGSize(width: 173, height: 91))
        let crop = try NativeCanvasTextureResampler.canvasImage(image: input, destinationPixels: CGSize(width: 173, height: 91), cropPixels: CGRect(x: 63, y: 27, width: 71, height: 47))
        let bytes = full.dataProvider!.data! as Data
        var expected = Data()
        for row in 27..<74 { expected.append(bytes[((row * 173 + 63) * 4)..<((row * 173 + 134) * 4)]) }
        #expect(crop.dataProvider!.data! as Data == expected)
        #expect(crop.width == 71 && crop.height == 47)
    }
    @Test func offscreenExtentDoesNotAllocateFullDestination() throws {
        let output = try NativeCanvasTextureResampler.canvasImage(image: source(), destinationPixels: CGSize(width: 16384, height: 16384), cropPixels: CGRect(x: 16000, y: 16000, width: 8, height: 8))
        #expect(output.width == 8 && output.height == 8)
        #expect((output.dataProvider!.data! as Data).count == 256)
    }
    @Test func closedSessionRejectsNewFiltering() throws {
        let session = NativeCanvasTextureResampler.Session(), input = try source()
        _ = try NativeCanvasTextureResampler.resample(image: input, outputPixelSize: CGSize(width: 32, height: 24), session: session)
        session.close()
        #expect(throws: NativeCanvasTextureResampler.Failure.self) {
            _ = try NativeCanvasTextureResampler.resample(image: input, outputPixelSize: CGSize(width: 32, height: 24), session: session)
        }
    }
    @Test func cancelledFilteringDoesNotPublishImage() async throws {
        let input = try source()
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try NativeCanvasTextureResampler.resample(image: input, outputPixelSize: CGSize(width: 173, height: 91))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
