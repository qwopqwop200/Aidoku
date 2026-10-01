import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct NativeDirectExportTests {
    private let size = CGSize(width: 120, height: 160)
    private var bounds: CGRect { CGRect(origin: .zero, size: size) }

    private func bitmap(_ paint: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: paint)
    }

    private func pixels(_ image: UIImage) throws -> Data {
        let image = try #require(image.cgImage)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }

    @Test(arguments: [false, true])
    func directBitmapKeepsFullSettledCoverageAndLogicalScale(stretched: Bool) throws {
        let source = bitmap { context in
            UIColor.white.setFill(); context.fill(bounds)
            UIColor.green.setFill(); context.fill(CGRect(x: 4, y: 80, width: 20, height: 30))
        }
        let overlay = bitmap { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 8, y: 12, width: 28, height: 32))
            UIColor.blue.withAlphaComponent(0.5).setFill(); context.fill(CGRect(x: 60, y: 55, width: 20, height: 20))
        }
        // Native images carry a logical scale even when their CGImage already
        // has the exact output density. Direct composition must preserve it.
        let scaledOverlay = UIImage(cgImage: try #require(overlay.cgImage), scale: 2, orientation: .up)
        let outputSize = stretched ? CGSize(width: 180, height: 80) : size
        let layers = ReaderTranslationImageExporter.ExportLayers(masks: [], surfaces: [], paintBounds: [[60, 55, 20, 20]])
        let direct = try ReaderTranslationImageExporter.composite(image: source, typography: .bitmap(scaledOverlay),
            layers: layers, displayRect: bounds, size: outputSize, nativeBitmap: true)
        let encoded = try ReaderTranslationImageExporter.composite(image: source, typography: #require(overlay.pngData()),
            layers: layers, displayRect: bounds, size: outputSize, nativeBitmap: true)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let destination = CGRect(origin: .zero, size: outputSize)
        let expected = UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            source.draw(in: destination)
            overlay.draw(in: destination)
        }
        #expect(try pixels(direct) == pixels(expected), "Source repairs outside text bounds and translucent lettering must survive")
        #expect(try pixels(direct) == pixels(encoded), "Cold pixels and serialized native asset replay must agree")
    }


    @Test func nativeInputsRetainGeometryValidation() throws {
        let source = bitmap { context in UIColor.white.setFill(); context.fill(bounds) }
        let layers = ReaderTranslationImageExporter.ExportLayers(masks: [], surfaces: [], paintBounds: [])
        let invalid = NativeTranslationRenderer.SourcePatch(image: try #require(source.cgImage),
            rect: CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20))
        #expect(throws: ReaderTranslationImageExporter.ExportError.self) {
            try ReaderTranslationImageExporter.composite(image: source, typography: .bitmap(source),
                layers: layers, sourcePatches: [invalid], displayRect: bounds, size: size, nativeBitmap: true)
        }
        #expect(throws: ReaderTranslationImageExporter.ExportError.self) {
            try ReaderTranslationImageExporter.composite(image: source, typography: .bitmap(UIImage()),
                layers: layers, displayRect: bounds, size: size, nativeBitmap: true)
        }
    }

    @Test func cancelledDirectCompositeDoesNotReturnPixels() async throws {
        let source = bitmap { context in UIColor.white.setFill(); context.fill(bounds) }
        let layers = ReaderTranslationImageExporter.ExportLayers(masks: [], surfaces: [], paintBounds: [])
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ReaderTranslationImageExporter.composite(image: source, typography: .bitmap(source),
                layers: layers, displayRect: bounds, size: size, nativeBitmap: true)
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
    }
}
