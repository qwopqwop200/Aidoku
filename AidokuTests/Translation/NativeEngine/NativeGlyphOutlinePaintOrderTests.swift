import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite @MainActor struct NativeGlyphOutlinePaintOrderTests {
    typealias Order = NativeTranslationTypography.OutlinePaintOrder
    private let fill = NativeTranslationRenderer.color([188, 80, 121])
    private let outline = NativeTranslationRenderer.color([230, 239, 243])

    private func pixels(size: CGSize, paint: (CGContext) -> Void) throws -> (bytes: [UInt8], width: Int) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3; format.opaque = true; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            paint(renderer.cgContext)
        }
        let cgImage = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return (bytes, cgImage.width)
    }

    private func fillPixels(_ bytes: [UInt8]) -> Int {
        var count: Int = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let red: Int = Int(bytes[index])
            let green: Int = Int(bytes[index + 1])
            let blue: Int = Int(bytes[index + 2])
            let matchesRed: Bool = abs(red - 188) <= 3
            let matchesGreen: Bool = abs(green - 80) <= 3
            let matchesBlue: Bool = abs(blue - 121) <= 3
            if matchesRed && matchesGreen && matchesBlue { count += 1 }
        }
        return count
    }

    private func maximumInteriorWidth(_ bitmap: (bytes: [UInt8], width: Int)) -> Int {
        let rowBytes = bitmap.width * 4
        var widest: Int = 0
        for start in stride(from: 0, to: bitmap.bytes.count, by: rowBytes) {
            let row = Array(bitmap.bytes[start..<(start + rowBytes)])
            widest = max(widest, fillPixels(row))
        }
        return widest
    }

    @Test func standaloneStrokeFirstDefaultRetainsInteriorWhileNormalPaintNarrowsIt() throws {
        let style = NativeTranslationTypography.Style(fontName: "Helvetica-Bold", fontSize: 64,
            foreground: fill, outline: outline, outlineWidth: 6, tracking: 0, lineHeight: 80)
        #expect(style.outlinePaintOrder == .strokeThenFill)
        let size = CGSize(width: 120, height: 100)
        let layout = NativeTranslationTypography.layout(text: "H", in: size, style: style)
        let original = try pixels(size: size) { NativeTranslationTypography.draw(layout: layout, in: $0) }
        let strokeFirst = try pixels(size: size) {
            NativeTranslationTypography.draw(layout: layout, in: $0, outlinePaintOrder: .strokeThenFill)
        }
        let fillFirst = try pixels(size: size) {
            NativeTranslationTypography.draw(layout: layout, in: $0, outlinePaintOrder: .fillThenStroke)
        }
        let defaultUnchanged = original.bytes == strokeFirst.bytes
        #expect(defaultUnchanged)
        #expect(fillPixels(fillFirst.bytes) > 0)
        #expect(fillPixels(fillFirst.bytes) < fillPixels(strokeFirst.bytes))
        // A centered six-point stroke covers three points of each outer edge
        // when it paints last. Compare the actual interior, not the stroke box.
        #expect(maximumInteriorWidth(fillFirst) + 6 < maximumInteriorWidth(strokeFirst))
    }
}
