import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct NativeColumnErasureExportTests {
    @Test(arguments: [false, true])
    func distantAuxiliarySourceErasureSurvivesPNGAndPDFExportClipping(capturePDF: Bool) throws {
        let size = CGSize(width: 220, height: 220), frame = CGRect(origin: .zero, size: size)
        let descriptor: [String: Any] = ["id": "column", "text": "검증", "x": 50, "y": 80, "width": 120, "height": 60,
            "fontSize": 18, "lineHeight": 22, "paddingTop": 4, "paddingBottom": 4, "paddingLeft": 4, "paddingRight": 4,
            "sourceTextOnly": false, "balancedColumn": true, "sourceErasureRGB": [255,255,255],
            "sourceBounds": [0.2,0.3,0.4,0.2], "sourceFrame": [0,0,220,220],
            "auxiliaryInkRects": [[0.85,0.05,0.04,0.05]], "fontScript": "korean", "wrappingScript": "korean"]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: frame, viewport: size, items: [item])
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.blue.setFill(); context.fill(frame)
        }
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.visible = true; settings.preserveSourceColors = false; settings.opacity = 1
        settings.mode = .translateOnly; settings.textPlacement = .replace
        let result = try NativeTranslationRenderer.renderSynchronously(layout: layout, image: source, settings: settings,
            composeSource: false, capturePDF: capturePDF)
        let auxiliaryPoint = CGPoint(x: 190, y: 15)
        #expect(!item.rect.insetBy(dx: -2, dy: -2).contains(auxiliaryPoint))
        #expect(result.paintBounds.contains { $0.contains(auxiliaryPoint) })
        let data = try #require(capturePDF ? result.exportPDFData : result.overlayImage.pngData())
        let layers = ReaderTranslationImageExporter.ExportLayers(masks: [], surfaces: [],
            paintBounds: result.paintBounds.map { [$0.minX,$0.minY,$0.width,$0.height] })
        let exported = try ReaderTranslationImageExporter.composite(image: source, typography: data, layers: layers,
            displayRect: frame, size: size)
        let pixels = try #require(exported.cgImage.flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        let restored = 15 * pixels.bytesPerRow + 190 * 4
        #expect(Array(pixels.bytes[restored..<(restored + 4)]) == [255,255,255,255])
        let untouched = 10 * pixels.bytesPerRow + 10 * 4
        #expect(Array(pixels.bytes[untouched..<(untouched + 4)]) == [0,0,255,255])
    }
}
