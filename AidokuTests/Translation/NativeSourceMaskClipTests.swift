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

}
