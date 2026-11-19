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

    private func png(width: Int, height: Int) throws -> Data {
        let image = try solidImage(width: width, height: height)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func cappedSizeKeepsAspectAndNeverExceedsTheCap() {
        #expect(!ImagePixelCap.exceeds(width: 100, height: 100, maxPixels: 10_000))
        #expect(ImagePixelCap.exceeds(width: 101, height: 100, maxPixels: 10_000))
        #expect(ImagePixelCap.exceeds(width: Int.max, height: 2, maxPixels: 10_000))
        #expect(!ImagePixelCap.exceeds(width: 0, height: 5, maxPixels: 1))
        let fitting = ImagePixelCap.cappedSize(width: 90, height: 100, maxPixels: 10_000)
        #expect(fitting.width == 90 && fitting.height == 100)
        #expect(ImagePixelCap.thumbnailMaxPixelSize(width: 100, height: 100, maxPixels: 10_000) == nil)
        for (width, height) in [(1000, 500), (333, 7777), (40_000, 3), (1, 50_000), (12_345, 12_345)] {
            let capped = ImagePixelCap.cappedSize(width: width, height: height, maxPixels: 10_000)
            #expect(capped.width * capped.height <= 10_000)
            #expect(capped.width >= 1 && capped.height >= 1 && capped.width <= width && capped.height <= height)
            if min(capped.width, capped.height) >= 20 {
                let ratio = Double(width) / Double(height), cappedRatio = Double(capped.width) / Double(capped.height)
                #expect(abs(cappedRatio / ratio - 1) < 0.06)
            }
            let side = ImagePixelCap.thumbnailMaxPixelSize(width: width, height: height, maxPixels: 10_000)
            #expect(side != nil)
            if let side {
                let short = Double(min(width, height)) * Double(side) / Double(max(width, height))
                #expect(side * max(1, Int(short.rounded(.up))) <= 10_000)
            }
        }
        #expect(ImagePixelCap.cappedDecodedBytes(1_000_000, maxPixels: 10_000) == 40_000)
        #expect(ImagePixelCap.cappedDecodedBytes(400, maxPixels: 10_000) == 400)
        #expect(ImagePixelCap.maxPixels >= 60_000_000 && ImagePixelCap.maxPixels <= 70_000_000)
    }

    @Test func pageAtOrBelowTheCapEntersThePipelineUnchanged() throws {
        let image = try solidImage(width: 100, height: 100)
        let page = V2Page(id: "p", image: image, readingDirection: .leftToRight)
        let capped = try #require(V2Pipeline.cappedPage(page, maxPixels: 10_000))
        // Same CGImage object: every stage sees exactly today's pixels.
        #expect(capped.image === image)
        #expect(V2Pipeline.cappedPage(page)?.image === image)
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

    @Test func translationDecodeUsesAThumbnailOnlyAboveTheCap() throws {
        let data = try png(width: 300, height: 200)
        let small = try #require(ImagePixelCap.decodeImage(data)?.cgImage)
        #expect(small.width == 300 && small.height == 200)

        let bounded = try #require(ImagePixelCap.decodeImage(data, maxPixels: 6_000))
        let raster = try #require(bounded.cgImage)
        #expect(raster.width * raster.height <= 6_000)
        #expect(raster.width > raster.height)
        #expect(bounded.imageOrientation == .up)
        #expect(ImagePixelCap.pixelSize(of: data).map { [$0.width, $0.height] } == [300, 200])
    }

    @Test func nukeDecoderDownsamplesOverCapPagesRegardlessOfTheReaderSetting() throws {
        let data = try png(width: 300, height: 200)
        let request = ImageRequest(url: URL(string: "https://example.invalid/page.png"))
        let context = ImageDecodingContext(request: request, data: data)

        #expect(ImagePixelCap.decodingContext(context).request.thumbnail == nil)
        let capped = ImagePixelCap.decodingContext(context, maxPixels: 6_000)
        #expect(capped.request.thumbnail != nil)
        let decoder = try #require(ImageDecoders.Default(context: capped))
        let raster = try #require(try decoder.decode(data).image.cgImage)
        #expect(raster.width * raster.height <= 6_000)

        // A thumbnail the reader already requested is kept as is.
        var thumbnailRequest = request
        thumbnailRequest.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: 50)
        let existing = ImageDecodingContext(request: thumbnailRequest, data: data)
        #expect(ImagePixelCap.decodingContext(existing, maxPixels: 6_000).request.thumbnail == thumbnailRequest.thumbnail)
    }
}
