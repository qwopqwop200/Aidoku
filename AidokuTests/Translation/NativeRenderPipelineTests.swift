import Testing
import UIKit
@testable import Aidoku

/// Production layout, live drawing and export contracts use the same generated page fixtures.
@Suite(.serialized) @MainActor
struct NativeRenderPipelineTests {
    @Test(arguments: [false, true])
    func nativeLiveAndExportPreserveGeometryAndSourcePixels(tall: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let settings = fixtureSettings()
        let fixture = makeFixture(tall: tall)
        let liveScale: CGFloat = tall ? 2 : window.screen.scale
        let items = ReaderTranslationRegion.layoutItems(fixture.regions, imageSize: fixture.image.size)
        let layout = try await NativeTranslationLayoutPlanner.prepareLayoutData(
            items: items, imageSize: fixture.image.size,
            sourceRect: CGRect(origin: .zero, size: fixture.viewport), settings: settings.overlay,
            targetLanguage: "ko", viewport: fixture.viewport)
        let decoded = try JSONDecoder().decode(NativeTranslationLayout.self, from: layout)
        #expect(decoded.imageSize == fixture.image.size && decoded.viewport == fixture.viewport)
        #expect(decoded.sourceRect == CGRect(origin: .zero, size: fixture.viewport))
        #expect(decoded.items.map(\.text) == fixture.regions.compactMap(\.translation))
        #expect(decoded.items.allSatisfy { $0.fontSize > 0 && $0.rect.width > 0 && $0.rect.height > 0 })

        let live = try await NativeTranslationRenderer.render(
            image: fixture.image, imageSize: fixture.image.size, items: items, settings: settings.overlay,
            targetLanguage: "ko", viewport: fixture.viewport, scale: liveScale, aspectFit: false,
            preparedLayout: layout, composeSource: false)
        #expect(live.renderedItemCount == fixture.regions.count)
        #expect(live.overlayImage.cgImage?.width == Int(fixture.viewport.width * liveScale))
        #expect(live.overlayImage.cgImage?.height == Int(fixture.viewport.height * liveScale))

        let loaded = try await ReaderTranslationImageExporter.renderLoadedImage(
            image: fixture.image, regions: fixture.regions, settings: settings,
            viewport: fixture.viewport, scale: 2, aspectFit: false, dark: false,
            host: window, cache: nil, key: "native-pipeline")
        try validateComposite(loaded, fixture: fixture)

        let prepared = Task<Data, Error> { layout }
        let snapshot = try await ReaderTranslationImageExporter.renderCacheSnapshot(
            image: fixture.image, imageSize: fixture.image.size, regions: fixture.regions,
            settings: settings, viewport: fixture.viewport, scale: 2, aspectFit: false,
            host: window, dark: false, preparedLayout: prepared)
        try validateComposite(snapshot, fixture: fixture)

        if !tall {
            var pdfBytes = 0, layerBytes = 0
            let exported = try await ReaderTranslationImageExporter.render(
                image: fixture.image, regions: fixture.regions, settings: settings,
                viewport: fixture.viewport, aspectFit: false, host: window, hasImagePermit: true,
                onNativePDFCapture: { data in pdfBytes = data.count },
                onNativeLayersCapture: { data in
                    layerBytes = data.count
                    _ = try JSONDecoder().decode(ReaderTranslationImageExporter.ExportLayers.self, from: data)
                })
            #expect(pdfBytes > 0 && layerBytes > 0)
            try validateComposite(exported, fixture: fixture)
        }
    }

    @Test func repeatedSourceRepairsPreservePrefixAndLaterDrawing() async throws {
        let scale: CGFloat = 3
        try await Task.detached {
            let viewport = CGSize(width: 390, height: 585), bounds = CGRect(origin: .zero, size: viewport)
            let bitmap = try NativeTranslationRenderer.WorkerLiveBitmap(
                pixels: CGSize(width: viewport.width * scale, height: viewport.height * scale), bounds: bounds)
            defer { bitmap.close() }
            let context = try #require(bitmap.context)
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(bounds)
            let source = try #require(CGContext(data: nil, width: 160, height: 160, bitsPerComponent: 8,
                bytesPerRow: 640, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            source.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            source.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            let sourceImage = try #require(source.makeImage())
            let patches = (0..<6).map { index in
                NativeTranslationRenderer.SourcePatch(image: sourceImage,
                    rect: CGRect(x: 24 + index % 2 * 170, y: 40 + index / 2 * 150, width: 40, height: 40))
            }
            for patch in patches {
                #expect(NativeTranslationRenderer.admittedDirectSourceFrame(patch, viewport: viewport, scale: scale) == patch.rect)
            }
            var accepted = 0
            for patch in patches {
                if try NativeTranslationRenderer.paintDirectSourcePatch(patch,
                    context: context, backing: bitmap.backing, viewport: viewport) { accepted += 1 }
            }
            #expect(accepted == 6, "All six requests must reach the direct source-patch compositor, never fallback")
            // A later draw must stay above the repair; a remote prefix pixel must remain untouched.
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 30, y: 47, width: 5, height: 5))
            let pixels = try #require(bitmap.backing?.backgroundRGBA(context: context, userRect: bounds))
            func pixel(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
                let offset = Int(y * scale) * context.width * 4 + Int(x * scale) * 4
                return Array(pixels[offset..<offset + 4])
            }
            #expect(pixel(3, 3) == [255, 0, 0, 255])
            #expect(pixel(31, 48) == [0, 0, 255, 255])
            for patch in patches { #expect(pixel(patch.rect.midX, patch.rect.midY) == [0, 255, 0, 255]) }
        }.value
    }

    private struct Fixture {
        let image: UIImage
        let viewport: CGSize
        let regions: [ReaderTranslationRegion]
    }

    private func fixtureSettings() -> ReaderTranslationSettings {
        var value = ReaderTranslationSettings()
        value.overlay = ReaderTranslationSettings.defaultOverlay
        value.overlay.preserveSourceColors = true
        value.targetLanguage = "ko"
        return value
    }

    private func makeFixture(tall: Bool) -> Fixture {
        let size = CGSize(width: 780, height: tall ? 2340 : 1170)
        let count = tall ? 6 : 4
        let regions = (0..<count).map { index in
            let rect = CGRect(x: index % 2 == 0 ? 0.12 : 0.57,
                              y: 0.08 + CGFloat(index / 2) * (tall ? 0.3 : 0.45), width: 0.27, height: tall ? 0.1 : 0.19)
            return ReaderTranslationRegion(id: "fixture-\(index)", rect: rect,
                source: "明日はきっと大丈夫", translation: "내일은 분명 괜찮을 거야. \(index)", sourceOrientation: .horizontal)
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: size, format: format).image { drawing in
            UIColor(white: 0.94, alpha: 1).setFill(); drawing.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1).setFill()
            drawing.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            for region in regions {
                let box = CGRect(x: region.rect.minX * size.width, y: region.rect.minY * size.height,
                                 width: region.rect.width * size.width, height: region.rect.height * size.height)
                UIColor.white.setFill(); UIBezierPath(roundedRect: box.insetBy(dx: -12, dy: -12), cornerRadius: 24).fill()
                (region.source as NSString).draw(in: box.insetBy(dx: 12, dy: 15), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 25), .foregroundColor: UIColor.black])
            }
        }
        return Fixture(image: source,
                       viewport: CGSize(width: 390, height: size.height / 2), regions: regions)
    }

    private func validateComposite(_ image: UIImage, fixture: Fixture) throws {
        let actual = try #require(image.cgImage)
        #expect(actual.width == Int(fixture.image.size.width) && actual.height == Int(fixture.image.size.height))
        let reference = try #require(fixture.image.cgImage)
        let crop = CGRect(x: 4, y: 4, width: 8, height: 8)
        let a = try #require(actual.cropping(to: crop).flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        let b = try #require(reference.cropping(to: crop).flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        #expect(a.bytes.count == b.bytes.count)
        // A remote solid source-art marker must remain intact; AA tolerance applies only to glyph contours.
        #expect(zip(a.bytes, b.bytes).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    }
}
