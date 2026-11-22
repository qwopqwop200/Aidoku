import CoreGraphics
import Foundation
import ImageIO
import Nuke
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Aidoku

/// The shared decoded-pixel cap (`ImagePixelCap`) on the V2 page entry, the
/// translation decoders and the global Nuke decoder. Every case injects a small
/// cap so the synthetic images stay tiny.
struct V2HugePageCapTests {
    private func solidImage(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8) = (200, 40, 90)) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = rgb.0; pixels[index + 1] = rgb.1; pixels[index + 2] = rgb.2
        }
        let image = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage()
        }
        return try #require(image)
    }


    @Test func cappedSizeKeepsAspectAndNeverExceedsTheCap() {
        #expect(!ImagePixelCap.exceeds(width: 100, height: 100, maxPixels: 10_000))
        #expect(ImagePixelCap.exceeds(width: Int.max, height: 2, maxPixels: 10_000))
        for (width, height) in [(1000, 500), (40_000, 3), (12_345, 12_345)] {
            let capped = ImagePixelCap.cappedSize(width: width, height: height, maxPixels: 10_000)
            #expect(capped.width * capped.height <= 10_000)
            #expect(capped.width >= 1 && capped.height >= 1 && capped.width <= width && capped.height <= height)
        }
        #expect(ImagePixelCap.cappedDecodedBytes(1_000_000, maxPixels: 10_000) == 40_000)
    }

    @Test func pageAtOrBelowTheCapEntersThePipelineUnchanged() throws {
        let image = try solidImage(width: 100, height: 100)
        let page = V2Page(id: "p", image: image, readingDirection: .leftToRight)
        #expect(V2Pipeline.cappedPage(page, maxPixels: 10_000)?.image === image)
    }

    @Test func pageAboveTheCapIsDownscaledWithItsAspectAndIdentityKept() throws {
        let image = try solidImage(width: 400, height: 250)
        let page = V2Page(id: "huge", image: image, readingDirection: .topToBottom)
        let capped = try #require(V2Pipeline.cappedPage(page, maxPixels: 10_000))
        #expect(capped.id == "huge")
        #expect(capped.readingDirection == .topToBottom)
        #expect(capped.width * capped.height <= 10_000)
        #expect(capped.width * capped.height > 9_000)
        #expect(abs(Double(capped.width) / Double(capped.height) - 1.6) < 0.05)
        // The capped page is an sRGB RGBA8 raster the pipeline converts without loss.
        #expect(capped.image.colorSpace?.name == CGColorSpace.sRGB)
        let raster = try V2PageRaster(capped.image)
        let center = ((raster.height / 2) * raster.width + raster.width / 2) * 4
        #expect(Array(raster.rgba[center..<center + 4]) == [200, 40, 90, 255])
    }

    @Test func nukeDecoderDownsamplesOverCapPagesRegardlessOfTheReaderSetting() throws {
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try solidImage(width: 300, height: 200), nil)
        #expect(CGImageDestinationFinalize(destination))
        let data = png as Data
        let request = ImageRequest(url: URL(string: "https://example.invalid/page.png"))
        let context = ImageDecodingContext(request: request, data: data)

        #expect(ImagePixelCap.decodingContext(context).request.thumbnail == nil)
        let capped = ImagePixelCap.decodingContext(context, maxPixels: 6_000)
        #expect(capped.request.thumbnail != nil)
        let decoder = try #require(ImageDecoders.Default(context: capped))
        let raster = try #require(try decoder.decode(data).image.cgImage)
        #expect(raster.width * raster.height <= 6_000)
    }
}
