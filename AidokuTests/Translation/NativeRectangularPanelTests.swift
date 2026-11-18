import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct NativeRectangularPanelTests {
    @Test(arguments: [CGFloat(1), CGFloat(1.75), CGFloat(3)])
    func polygonAndGutterCannotCarveSolidPanel(deviceScale: CGFloat) throws {
        let size = CGSize(width: 64, height: 64)
        let bounds = CGRect(origin: .zero, size: size)
        let rect = CGRect(x: 12, y: 12, width: 40, height: 40)
        let value: [String: Any] = ["id": "rectangle", "text": "A", "x": 12, "y": 12,
            "width": 40, "height": 40, "fontSize": 10, "lineHeight": 12,
            "sourceBounds": [0.25, 0.25, 0.25, 0.25], "sourceFrame": [0, 0, 64, 64]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: bounds, viewport: size, items: [item])
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: nil,
            settings: ReaderTranslationSettings.defaultOverlay)
        var card = try #require(plan.cards.first)
        card.sourcePlateOwnerRect = rect
        card.straightenedPanelRect = rect
        card.background = NativeTranslationRenderer.color([30, 80, 140])
        card.drawsPanel = true
        card.textBoxClip = [CGPoint(x: 12, y: 12), CGPoint(x: 52, y: 12), CGPoint(x: 32, y: 52)]
        card.textBoxBackgroundClip = CGRect(x: 12, y: 12, width: 5, height: 5)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bitmap = UIGraphicsImageRenderer(size: size, format: format).image { output in
            NativeTranslationRenderer.draw(card, context: output.cgContext, opacity: 1,
                paintsBackground: true, paintsText: false, paintsSourcePanels: false)
        }
        let pdf = try NativeTranslationPDFCapture.capture(bounds: bounds, pixels: size,
            deviceScale: deviceScale, alignsToLogicalBounds: true, paint: { context in
                NativeTranslationRenderer.draw(card, context: context, opacity: 1,
                    paintsBackground: true, paintsText: false, paintsSourcePanels: false, pixelSnapScale: deviceScale)
            })
        for image in [try #require(bitmap.cgImage), pdf.image] {
            var rgba = [UInt8](repeating: 0, count: 64 * 64 * 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(data: bytes.baseAddress, width: 64, height: 64,
                    bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: bounds)
            }
            for y in 13..<51 { for x in 13..<51 {
                #expect(rgba[(y * 64 + x) * 4 + 3] == 255)
            } }
            #expect(rgba[(4 * 64 + 4) * 4 + 3] == 0)
        }
    }

    @Test func rectangularContainmentCoversOwnerWithoutFollowingContour() throws {
        let surface = NativeTextBoxContainment.Surface(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            spans: [(35, 65), (20, 80), (10, 90), (5, 95), (5, 95), (10, 90), (20, 80), (35, 65)], color: nil)
        let owner = CGRect(x: 40, y: 40, width: 20, height: 20)
        let rectangle = try #require(surface.rectangularPanel(covering: owner, near: surface.rect, within: surface.rect))
        #expect(rectangle.contains(owner))
        for row in surface.spans.indices {
            let top = CGFloat(row) * 12.5, bottom = top + 12.5
            if top < rectangle.maxY && bottom > rectangle.minY {
                #expect(rectangle.minX >= surface.spans[row].0)
                #expect(rectangle.maxX <= surface.spans[row].1)
            }
        }
        #expect(surface.rectangularPanel(covering: CGRect(x: 0, y: 0, width: 100, height: 100),
            near: surface.rect, within: surface.rect) == nil)
    }
}
