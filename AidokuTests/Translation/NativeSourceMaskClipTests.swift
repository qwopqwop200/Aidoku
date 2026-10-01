import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor struct NativeSourceMaskClipTests {
    @Test(arguments: [
        [162.55462184873952, 212.3529411764706, 67.5126050420168, 86.35714285714286,
         162.546875, 212.34375, 67.5, 86.34375],
        [-20.009, -10.019, 100.009, 99.989, -20.0, -10.015625, 100.0, 99.984375]
    ])
    func capturedRepairUsesCanvasLayoutUnitsWithoutChangingPixelsOrCleanupClip(values: [Double]) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let repair = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 2))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 1, y: 0, width: 1, height: 2))
        }
        let raw = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        let clip = CGRect(x: 0.009, y: 0.019, width: 200.009, height: 300.019)
        let image = try #require(repair.cgImage)
        var restoration = NativeTranslationRestoration.Result()
        restoration.patches = [.init(image: image, rect: raw, itemID: "repair", cleanupClip: clip)]
        let patches = NativeTranslationRenderer.snapshotSourcePatches(restoration: restoration,
            cards: [], gloss: .init(), visible: true)
        let patch = try #require(patches.first)
        #expect(patches.count == 1)
        #expect(patch.rect == CGRect(x: values[4], y: values[5], width: values[6], height: values[7]))
        #expect(patch.authoredCanvasRect == raw)
        #expect(patch.cleanupClip == clip)
        let before = try #require(NativeOCRCGImageAdapter.makeRGBAFrame(from: image))
        let after = try #require(NativeOCRCGImageAdapter.makeRGBAFrame(from: patch.image))
        #expect(before.bytes == after.bytes)
        let encoded = try ReaderTranslationImageExporter.encodeSourceMasks(patches)
        #expect(encoded[0].frame == Array(values[4..<8]).map { CGFloat($0) })
        #expect(encoded[0].cleanupClip == nil)
    }

    @Test func savedRepairMatchesFrozenRawCanvasAndExplicitCompositeClipStaysOptional() throws {
        let format = UIGraphicsImageRendererFormat();format.scale = 1;format.preferredRange = .standard
        let repair = UIGraphicsImageRenderer(size: CGSize(width: 100,height: 100),format: format).image { context in
            UIColor.red.setFill();context.fill(CGRect(x: 0,y: 0,width: 50,height: 100))
            UIColor.blue.setFill();context.fill(CGRect(x: 50,y: 0,width: 50,height: 100))
        }
        let source = UIGraphicsImageRenderer(size: CGSize(width: 200,height: 200),format: format).image { context in
            UIColor.white.setFill();context.fill(CGRect(x: 0,y: 0,width: 200,height: 200))
        }
        let patch = NativeTranslationRenderer.SourcePatch(image: try #require(repair.cgImage),
            rect: CGRect(x: -20,y: -10,width: 100,height: 100),cleanupClip: CGRect(x: 0,y: 0,width: 100,height: 100))
        let masks = try ReaderTranslationImageExporter.encodeSourceMasks([patch])
        #expect(masks[0].frame == [-20,-10,100,100])
        #expect(masks[0].cleanupClip == nil)
        let rawLayers = ReaderTranslationImageExporter.ExportLayers(masks: masks, surfaces: [], paintBounds: [])
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { $0.beginPage() }
        let displayRect = CGRect(x: -50, y: -50, width: 200, height: 200)
        let size = CGSize(width: 200, height: 200)
        let actual = try ReaderTranslationImageExporter.composite(image: source, typography: pdf,
            layers: rawLayers, displayRect: displayRect, size: size)
        let frozen = try LegacyReaderTranslationCompositor.composite(image: source, typography: pdf,
            layers: rawLayers, displayRect: displayRect, size: size)
        let actualPixels = try #require(actual.cgImage.flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        let frozenPixels = try #require(frozen.cgImage.flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        #expect(actualPixels.bytes == frozenPixels.bytes)
        // Frozen export paints the complete canvas even outside the live CSS clip.
        #expect(Array(actualPixels.bytes[(60 * actualPixels.bytesPerRow + 40 * 4)..<(60 * actualPixels.bytesPerRow + 40 * 4 + 4)]) == [255, 0, 0, 255])
        #expect(Array(actualPixels.bytes[(45 * actualPixels.bytesPerRow + 60 * 4)..<(45 * actualPixels.bytesPerRow + 60 * 4 + 4)]) == [255, 0, 0, 255])
        // Keep explicit clip decoding/composition covered independently of save semantics.
        var clippedMasks = masks
        clippedMasks[0].cleanupClip = [0, 0, 100, 100]
        let layers = ReaderTranslationImageExporter.ExportLayers(masks: clippedMasks,surfaces: [],paintBounds: [])
        let replay = try JSONDecoder().decode(ReaderTranslationImageExporter.ExportLayers.self,from: JSONEncoder().encode(layers))
        let exported = try ReaderTranslationImageExporter.composite(image: source,typography: #require(source.pngData()),layers: replay,
            displayRect: CGRect(x: -50,y: -50,width: 200,height: 200),size: CGSize(width: 200,height: 200))
        let frame = try #require(exported.cgImage.flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        func pixel(_ x: Int,_ y: Int) -> [UInt8] {
            let start = y*frame.bytesPerRow+x*4;return Array(frame.bytes[start..<(start+4)])
        }
        #expect(pixel(40,60) == [255,255,255,255])
        #expect(pixel(60,45) == [255,255,255,255])
        #expect(pixel(60,60) == [255,0,0,255])
        // Blue begins at globalX30; cropping must not stretch the remaining red.
        #expect(pixel(85,60) == [0,0,255,255])
        #expect(pixel(90,60) == [0,0,255,255])
    }
}
