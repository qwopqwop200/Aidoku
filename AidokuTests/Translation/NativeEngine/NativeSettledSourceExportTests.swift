import Testing
import UIKit
@testable import Aidoku

struct NativeSettledSourceExportTests {
    private typealias Exporter = ReaderTranslationImageExporter
    private let frame = CGRect(x: 42.25, y: 87.75, width: 430, height: 107.5)
    private let pixels: [UInt8] = [100, 25, 10, 128, 10, 20, 30, 255, 0, 0, 0, 0, 10, 50, 4, 64]

    private func image(_ bytes: [UInt8]) throws -> UIImage {
        UIImage(cgImage: try NativeMandatoryDisplayStroke.image(bytes, width: 4, height: 1))
    }

    private func canonical(_ value: UIImage) throws -> [UInt8] {
        try NativeMandatoryDisplayStroke.rgba(#require(value.cgImage))
    }

    @Test func exportsSettledRasterOnceAndKeepsLegacyBlend() throws {
        let original = try image(pixels)
        var translated = pixels
        translated.replaceSubrange(4..<8, with: [255, 0, 0, 255])
        let size = CGSize(width: 4, height: 1)
        let bounds = [[frame.minX, frame.minY, frame.width, frame.height]]
        let marked = Exporter.ExportLayers(masks: [], surfaces: [], paintBounds: bounds, includesSourcePage: true)
        let replay = try JSONDecoder().decode(Exporter.ExportLayers.self, from: JSONEncoder().encode(marked))
        #expect(replay.includesSourcePage == true)
        for bytes in [pixels, translated] {
            let layer = try image(bytes)
            let result = try Exporter.composite(image: original, typography: .bitmap(layer), layers: replay,
                displayRect: frame, size: size, nativeBitmap: true)
            #expect(try canonical(result) == canonical(layer))
        }
        let legacy = Exporter.ExportLayers(masks: [], surfaces: [], paintBounds: bounds)
        let legacyResult = try Exporter.composite(image: original, typography: .bitmap(original), layers: legacy,
            displayRect: frame, size: size, nativeBitmap: true)
        let actual = try canonical(legacyResult)
        #expect(stride(from: 3, to: actual.count, by: 4).map { actual[$0] } == [192, 255, 0, 112])
        var invalid = marked
        invalid.sourceRestorations = [[frame.minX, frame.minY, 1, 1]]
        #expect(throws: (any Error).self) {
            try Exporter.composite(image: original, typography: .bitmap(original), layers: invalid,
                displayRect: frame, size: size, nativeBitmap: true)
        }
    }

    @Test func settledPNGReplayKeepsLetterboxedPixelsAndResizesWhenNeeded() throws {
        let original = try image(pixels)
        let size = original.size
        let png = try #require(original.pngData())
        let bitmap = try #require(UIImage(data: png))
        let layers = Exporter.ExportLayers(masks: [], surfaces: [],
            paintBounds: [[frame.minX, frame.minY, frame.width, frame.height]], includesSourcePage: true)
        for target in [size, CGSize(width: 8, height: 2)] {
            let replay = try Exporter.composite(image: original, typography: png, layers: layers,
                displayRect: frame, size: target, nativeBitmap: true)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let reference = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                bitmap.draw(in: CGRect(origin: .zero, size: target))
            }
            #expect(replay.size == target && replay.scale == 1)
            #expect(try canonical(replay) == canonical(reference))
        }
    }

    @Test func sizeMatchedStandardBitmapReusesItsPixelsWithoutChangingRGBA() throws {
        let original = try image(pixels)
        let size = CGSize(width: 4, height: 1)
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 4, height: 1,
            bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try #require(original.cgImage), in: CGRect(origin: .zero, size: size))
        let raw = try #require(context.makeImage())
        let bitmap = UIImage(cgImage: raw, scale: 2, orientation: .up)
        let marked = Exporter.ExportLayers(masks: [], surfaces: [],
            paintBounds: [[frame.minX, frame.minY, frame.width, frame.height]], includesSourcePage: true)
        let direct = try Exporter.composite(image: original, typography: .bitmap(bitmap), layers: marked,
            displayRect: frame, size: size, nativeBitmap: true)
        let drawn = try Exporter.composite(image: original, typography: .bitmap(bitmap), layers: marked,
            displayRect: frame, size: size)
        #expect(direct.cgImage === raw)
        #expect(direct.scale == 1 && direct.size == size)
        #expect(try canonical(direct) == canonical(drawn))

        let stretched = try Exporter.composite(image: original, typography: .bitmap(bitmap), layers: marked,
            displayRect: frame, size: CGSize(width: 8, height: 2), nativeBitmap: true)
        #expect(stretched.cgImage !== raw && stretched.cgImage?.width == 8)
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let p3 = try #require(CGContext(data: nil, width: 4, height: 1,
            bitsPerComponent: 8, bytesPerRow: 0, space: displayP3,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        p3.draw(raw, in: CGRect(origin: .zero, size: size))
        let wide = try #require(p3.makeImage())
        let wideResult = try Exporter.composite(image: original, typography: .bitmap(UIImage(cgImage: wide)), layers: marked,
            displayRect: frame, size: size, nativeBitmap: true)
        #expect(wideResult.cgImage !== wide)
    }
}
