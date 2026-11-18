import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Only synthetic pixels; no model or renderer/backend inference is needed.
@Suite struct ReaderTranslationSourceOrientationTests {
    @Test func sourceCoordinatesMatchDisplayedPixelsForAllOrientations() throws {
        let bitmap = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Encoded 2×3 raster, visually distinguishable without depending on
        // exact UIKit color rounding: a b / c d / e f.
        let a = 4, b = 2, c = 1, d = 3, e = 5, f = 6
        let bytes: [UInt8] = [a, b, c, d, e, f].flatMap { word -> [UInt8] in
            [word & 4 != 0 ? 255 : 0, word & 2 != 0 ? 255 : 0, word & 1 != 0 ? 255 : 0, 255]
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let raw = try #require(CGImage(width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: space, bitmapInfo: bitmap, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let cases: [(UIImage.Orientation, Int, Int, [Int])] = [
            (.up, 2, 3, [a, b, c, d, e, f]),
            (.upMirrored, 2, 3, [b, a, d, c, f, e]),
            (.down, 2, 3, [f, e, d, c, b, a]),
            (.downMirrored, 2, 3, [e, f, c, d, a, b]),
            (.left, 3, 2, [b, d, f, a, c, e]),
            (.leftMirrored, 3, 2, [a, c, e, b, d, f]),
            (.right, 3, 2, [e, c, a, f, d, b]),
            (.rightMirrored, 3, 2, [f, d, b, e, c, a])
        ]
        for (orientation, width, height, expected) in cases {
            let input = UIImage(cgImage: raw, scale: 2, orientation: orientation)
            let upright = ReaderTranslationImagePreparation.uprightSourceImage(input)
            let rendered = NativeTranslationRenderer.ensembleSourceImage(input)
            let actual = try #require(upright.cgImage)
            let dispatch = try #require(rendered.cgImage)
            #expect(upright.imageOrientation == .up)
            #expect(upright.scale == input.scale)
            #expect(upright.size == input.size)
            #expect(actual.width == width && actual.height == height)
            #expect(dispatch.width == width && dispatch.height == height)
            #expect(try pixelCodes(actual, space: space, bitmap: bitmap) == expected)
            #expect(try pixelCodes(dispatch, space: space, bitmap: bitmap) == expected)
            #expect(NativeTranslationRenderer.ensembleSourceImage(upright) === upright)
            if orientation == .up {
                #expect(upright === input)
                #expect(actual === raw)
            }
        }
    }

    private func pixelCodes(_ image: CGImage, space: CGColorSpace, bitmap: CGBitmapInfo) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space, bitmapInfo: bitmap.rawValue))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { pixel in
            let index = pixel * 4
            return (bytes[index] > 127 ? 4 : 0) | (bytes[index + 1] > 127 ? 2 : 0) | (bytes[index + 2] > 127 ? 1 : 0)
        }
    }
}
