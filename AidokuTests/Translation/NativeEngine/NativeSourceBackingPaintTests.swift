import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeSourceBackingPaintTests {
    private func pixels(_ paint: (CGContext) -> Void) throws -> [UInt8] {
        let scale = CGFloat(3192) / 390
        let width = 260, height = 720
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { memory in
            let context = try #require(CGContext(data: memory.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -223, y: -397)
            context.setFillColor(NativeTranslationRenderer.color([72, 54, 41]))
            context.fill(CGRect(x: 223, y: 397, width: 40, height: 90))
            paint(context)
        }
        return bytes
    }

    @Test func vectorBackingUsesItsLocalClipAtThePaintedBorderOrigin() throws {
        // Frozen real7/card19: DOM coordinates and retained global dataset
        // differ from the local CSS path's device-snapped containing border.
        let frame = CGRect(x: 225.796875, y: 398.53125, width: 25.265625, height: 82.453125)
        let backing = NativePanelGeometry.Backing(frame: frame,
            coverage: [CGRect(x: 226.84818744659424, y: 424.78125, width: 23.23075, height: 29)],
            color: [62, 53, 41])
        let original = backing.coverage
        let actual = try pixels { NativeTranslationRenderer.drawSourceBacking(backing, context: $0, pixelSnapScale: 3) }
        let expected = try pixels { context in
            let border = CGRect(x: CGFloat(Float(225 + 2.0 / 3)), y: CGFloat(Float(398 + 2.0 / 3)),
                width: CGFloat(Float(25 + 1.0 / 3)), height: CGFloat(Float(82 + 1.0 / 3)))
            context.clip(to: CGRect(x: border.minX + 1.05131244659424, y: border.minY + 26.25,
                width: 23.23075, height: 29))
            context.setFillColor(NativeTranslationRenderer.color([62, 53, 41]))
            // The selected clip lies away from all rounded corners; the
            // captured border is sufficient as an independent fill control.
            context.fill(border)
        }
        let former = try pixels { context in
            context.clip(to: backing.coverage[0])
            context.setFillColor(NativeTranslationRenderer.color([62, 53, 41]))
            context.fill(frame)
        }
        #expect(actual == expected)
        #expect(actual != former)
        #expect(backing.frame == frame && backing.coverage == original)
    }

    @Test func bitmapBackingKeepsItsExistingClipAndRestoresGraphicsState() throws {
        let backing = NativePanelGeometry.Backing(frame: CGRect(x: 225.796875, y: 398.53125,
            width: 25.265625, height: 82.453125),
            coverage: [CGRect(x: 226.84818744659424, y: 424.78125, width: 23.23075, height: 29)],
            color: [62, 53, 41])
        let actual = try pixels { context in
            NativeTranslationRenderer.drawSourceBacking(backing, context: context)
            context.fill(CGRect(x: 223, y: 400, width: 1, height: 1))
        }
        let expected = try pixels { context in
            context.saveGState()
            context.addPath(CGPath(roundedRect: backing.frame, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.clip(); context.addRects(backing.coverage); context.clip()
            context.setFillColor(NativeTranslationRenderer.color([62, 53, 41])); context.fill(backing.frame)
            context.restoreGState()
            context.fill(CGRect(x: 223, y: 400, width: 1, height: 1))
        }
        #expect(actual == expected)
    }
}
