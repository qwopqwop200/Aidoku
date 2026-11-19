import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// V2Pipeline orchestration: the single shared page decode and the contract that lets
/// S8/S6/S7 run during S5 (none of them reads the translation or the dialogue/sfx role).
struct V2PipelineSchedulingTests {
    static func image(alpha: CGFloat, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        let width = 64, height = 48
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.7, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: alpha))
        context.fill(CGRect(x: 10, y: 10, width: 30, height: 20))
        return context.makeImage()!
    }

    @Test func opaqueSRGBPageIsConvertedOnceAndMatchesBothFormats() throws {
        let image = Self.image(alpha: 1)
        let pixels = V2Pipeline.decodePixels(image)
        #expect(pixels.conversions == 1 && pixels.failure == nil)
        let raster = try #require(pixels.raster)
        let frame = try #require(pixels.frame)
        #expect(raster.rgba == (try V2PageRaster(image)).rgba)
        #expect(frame.bytes == NativeOCRCGImageAdapter.makeRGBAFrame(from: image)?.bytes)
    }

    @Test func translucentPageKeepsSeparateConversions() throws {
        let image = Self.image(alpha: 0.5)
        let pixels = V2Pipeline.decodePixels(image)
        #expect(pixels.conversions == 2)
        #expect(try #require(pixels.raster).rgba == (try V2PageRaster(image)).rgba)
        #expect(try #require(pixels.frame).bytes == NativeOCRCGImageAdapter.makeRGBAFrame(from: image)?.bytes)
        #expect(!V2Pipeline.isOpaque([255, 255, 255, 255, 0, 0, 0, 254]))
        #expect(V2Pipeline.isOpaque([1, 2, 3, 255, 0, 0, 0, 255]))
    }

    @Test func removalMaskIgnoresTranslationAndSFXRole() {
        let page = V2StyleTests.page(background: 1, ink: 0, ring: nil)
        let rgba = V2RemovalMask.rgbaBytes(page.image)!
        let source = V2StyleTests.column
        var translated = source
        translated.translation = "번역"
        translated.role = .sfx
        #expect(V2Pipeline.eraseInput(source) == V2Pipeline.eraseInput(translated))
        let before = V2RemovalMask.build(rgba: rgba, width: page.width, height: page.height, blocks: [source], layout: [])
        let after = V2RemovalMask.build(rgba: rgba, width: page.width, height: page.height, blocks: [translated], layout: [])
        #expect(before == after && before.contains { $0 != 0 })
        var background = source
        background.role = .background
        #expect(V2Pipeline.eraseInput(source) != V2Pipeline.eraseInput(background))
    }

    @Test func styleIgnoresTranslationAndRole() {
        let page = V2StyleTests.page(background: 0.45, ink: 0, ring: 1)
        let source = V2StyleTests.column
        var translated = source
        translated.translation = "번역"
        translated.role = .sfx
        #expect(V2Pipeline.styleInput(source) == V2Pipeline.styleInput(translated))
        let before = V2Style.estimate(page, blocks: [source]).map(\.style)
        let after = V2Style.estimate(page, blocks: [translated]).map(\.style)
        #expect(before == after && before.first! != nil)
    }
}
