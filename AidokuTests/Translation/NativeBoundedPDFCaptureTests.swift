import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeBoundedPDFCaptureTests {
    private let bounds = CGRect(x: 2.25, y: 3.5, width: 64.25, height: 80.5)
    private let pixels = CGSize(width: 128, height: 160)

    @Test(arguments: [CGFloat(1), 1.75, 3])
    func boundedDocumentPreservesUnboundedRaster(scale: CGFloat) throws {
        let paint: (CGContext) -> Void = { context in
            context.setFillColor(CGColor(red: 0.15, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 5, y: 9, width: 42.5, height: 60.25))
            context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.05, alpha: 0.65))
            context.fill(CGRect(x: 20.25, y: 15.5, width: 12.5, height: 18.25))
        }
        let ordinary = try NativeTranslationPDFCapture.captureDocument(bounds: bounds, pixels: pixels,
            deviceScale: scale, alignsToLogicalBounds: true, paint: paint)
        let bounded = try NativeTranslationPDFCapture.captureDocument(bounds: bounds, pixels: pixels,
            deviceScale: scale, alignsToLogicalBounds: true, maximumBytes: 65_536, paint: paint)
        #expect(bounded.data.count > 0 && bounded.data.count <= 65_536)
        #expect(bounded.mediaBox == ordinary.mediaBox)
        let a = try NativeTranslationPDFCapture.rasterize(data: ordinary.data, pixels: pixels)
        let b = try NativeTranslationPDFCapture.rasterize(data: bounded.data, pixels: pixels)
        let aBytes = try #require(a.dataProvider?.data)
        let bBytes = try #require(b.dataProvider?.data)
        #expect((aBytes as Data) == (bBytes as Data))
    }

    @Test
    func exhaustedConsumerCannotReturnPartialDocument() {
        #expect(throws: NativeTranslationPDFCapture.DocumentBudgetError.self) {
            _ = try NativeTranslationPDFCapture.captureDocument(bounds: bounds, pixels: pixels,
                maximumBytes: 1) { context in
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(bounds)
            }
        }
    }

    @Test(arguments: [0, -1, 48 * 1_024 * 1_024 + 1])
    func invalidBudgetIsRejectedBeforePainting(limit: Int) {
        var painted = false
        #expect(throws: NativeTranslationPDFCapture.CaptureError.self) {
            _ = try NativeTranslationPDFCapture.captureDocument(bounds: bounds, pixels: pixels,
                maximumBytes: limit) { _ in painted = true }
        }
        #expect(!painted)
    }
}
