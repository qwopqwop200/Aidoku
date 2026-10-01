import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor struct NativeSettledBitmapReplayTests {
    private let size = CGSize(width: 100, height: 90)
    private var bounds: CGRect { CGRect(origin: .zero, size: size) }
    private let textBounds = CGRect(x: 60, y: 55, width: 20, height: 20)
    private let repairBounds = CGRect(x: 8, y: 12, width: 28, height: 32)

    private func bitmap(opaque: Bool, paint: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: paint)
    }
    private func paintOverlay(_ context: CGContext) {
        context.setFillColor(UIColor.red.cgColor)
        context.fill(repairBounds)
        context.setFillColor(UIColor.blue.cgColor)
        context.fill(textBounds)
    }
    private func pixels(_ image: UIImage) throws -> Data {
        let image = try #require(image.cgImage)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }

    @Test func persistedNativeBitmapRetainsSettledSourceRepairBeyondTextBounds() async throws {
        let source = bitmap(opaque: true) { context in
            UIColor.gray.setFill(); context.fill(bounds)
        }
        let overlay = bitmap(opaque: false) { paintOverlay($0.cgContext) }
        let original = ReaderTranslationRenderAsset(typography: try #require(overlay.pngData()),
            layers: .init(masks: [], surfaces: [], paintBounds: [[60, 55, 20, 20]]),
            displayRect: bounds, sourceSize: size, regions: [],
            sourceDigest: ReaderTranslationRenderAsset.digestSource(source), typographySize: size)
        let asset = try JSONDecoder().decode(ReaderTranslationRenderAsset.self, from: JSONEncoder().encode(original))
        #expect(asset.isValid)
        #expect(asset.layers.masks.isEmpty, "Live repairs are already baked in this native bitmap")
        let result = try await ReaderTranslationImageExporter.compositeLoadedImage(source, asset: asset, size: size, priority: .foreground)
        let expected = bitmap(opaque: true) { _ in
            source.draw(in: bounds)
            overlay.draw(in: bounds)
        }
        #expect(try pixels(result) == pixels(expected), "Text paint bounds must not cut settled restoration margins")
    }

    @Test(arguments: [false, true])
    func legacyPNGAndVectorPagesKeepMeasuredTypographyClipping(vector: Bool) async throws {
        let source = bitmap(opaque: true) { context in
            UIColor.gray.setFill(); context.fill(bounds)
        }
        let typography: Data
        if vector {
            typography = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
                context.beginPage(); paintOverlay(context.cgContext)
            }
        } else {
            typography = try #require(bitmap(opaque: false) { paintOverlay($0.cgContext) }.pngData())
        }
        let result = try ReaderTranslationImageExporter.composite(image: source, typography: typography,
            layers: .init(masks: [], surfaces: [], paintBounds: [[60, 55, 20, 20]]), displayRect: bounds, size: size)
        let expected = bitmap(opaque: true) { context in
            source.draw(in: bounds)
            UIColor.blue.setFill(); context.fill(textBounds)
        }
        #expect(try pixels(result) == pixels(expected), "The explicit native bitmap route must not weaken legacy/vector clipping")
    }
}
