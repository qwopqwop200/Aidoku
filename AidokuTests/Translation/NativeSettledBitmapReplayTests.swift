import CryptoKit
import Foundation
import ImageIO
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

    @Test func settledPNGSurvivesMemoryClearAndColdDiskReplayWithExactIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let cache = ReaderTranslationRenderCache(disk: disk)
        func makePage(gray: CGFloat, withOverlay: Bool = false) throws -> UIImage {
            let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(gray: gray, alpha: 1)
            context.fill(bounds)
            if withOverlay { paintOverlay(context) }
            return UIImage(cgImage: try #require(context.makeImage()), scale: 1, orientation: .up)
        }
        let source = try makePage(gray: 0.5)
        let finished = try makePage(gray: 0.5, withOverlay: true)
        let png = try #require(finished.pngData())
        let sourceDigest = try #require(ReaderTranslationRenderAsset.digestSource(source))
        let asset = ReaderTranslationRenderAsset(typography: png,
            layers: .init(masks: [], surfaces: [], paintBounds: [[0, 0, size.width, size.height]], includesSourcePage: true),
            displayRect: bounds, sourceSize: size, regions: [], sourceDigest: sourceDigest, typographySize: size)
        let generation = await disk.currentGeneration()
        await cache.storeRenderAsset(asset, key: "settled", diskGeneration: generation)
        cache.clearMemory()
        let key = ReaderTranslationRenderCache.renderAssetStorageKey("settled")
        let bytes = try #require(try await disk.data(for: key, kind: .layout))
        #expect(ReaderTranslationCacheCodec.isSettledRenderArchive(bytes))
        let cold = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: directory))
        let reopened = try #require(await cold.renderAsset(for: "settled", regions: [], sourceSize: size, sourceDigest: sourceDigest))
        #expect(reopened.typography == png)
        #expect(reopened.displayRect == bounds)
        #expect(!reopened.supportsOutputSize(CGSize(width: size.width + 1, height: size.height)))
        let changedSource = try makePage(gray: 1)
        let changedDigest = try #require(ReaderTranslationRenderAsset.digestSource(changedSource))
        #expect(sourceDigest != changedDigest)
        #expect(await cold.renderAsset(for: "settled", regions: [], sourceSize: size, sourceDigest: changedDigest) == nil)
        let different = ReaderTranslationRegion(id: "r", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                                               source: "changed", translation: "changed")
        #expect(await cold.renderAsset(for: "settled", regions: [different], sourceSize: size, sourceDigest: sourceDigest) == nil)

        let legacyBytes = try JSONEncoder().encode(asset)
        let legacyKey = ReaderTranslationRenderCache.renderAssetStorageKey("legacy")
        try await disk.store(legacyBytes, for: legacyKey, kind: .layout, generation: generation)
        #expect(await cold.renderAsset(for: "legacy", regions: [], sourceSize: size, sourceDigest: changedDigest) == nil)
        let validLegacy = try #require(await cold.renderAsset(for: "legacy", regions: [], sourceSize: size, sourceDigest: sourceDigest))
        #expect(validLegacy.typography == png)
        let legacy = try #require(ReaderTranslationRenderAsset.decodeFromDisk(legacyBytes))
        let previous = try await ReaderTranslationImageExporter.compositeLoadedImage(source, asset: legacy, size: size, priority: .foreground)
        let replayed = try await ReaderTranslationImageExporter.compositeLoadedImage(source, asset: reopened, size: size, priority: .foreground)
        #expect(try pixels(replayed) == pixels(previous))

        for component in [png, Data(sourceDigest.utf8)] {
            let range = try #require(bytes.range(of: component))
            var damaged = bytes
            damaged[range.lowerBound] ^= 1
            #expect(ReaderTranslationRenderAsset.decodeFromDisk(damaged) == nil)
        }
        #expect(ReaderTranslationRenderAsset.decodeFromDisk(bytes.dropLast()) == nil)

        let trailer = ReaderTranslationCacheCodec.settledRenderTrailer
        let payload = bytes.dropLast(trailer.count + SHA256.Digest.byteCount)
        var fields = try #require(try PropertyListSerialization.propertyList(from: payload, options: 0, format: nil) as? [String: Any])
        fields["version"] = ReaderTranslationRenderAsset.currentVersion - 1
        var obsolete = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
        obsolete.append(contentsOf: SHA256.hash(data: obsolete))
        obsolete.append(trailer)
        #expect(ReaderTranslationRenderAsset.decodeFromDisk(obsolete) == nil)
    }

    @Test func freshlyRenderedPageColdReopensWithIdenticalPixels() async throws {
        final class BundleToken {}
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "VerticalSingleGlyphBalloon", withExtension: "png"))
        let decoder = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let raster = try #require(CGImageSourceCreateImageAtIndex(decoder, 0, nil))
        let source = UIImage(cgImage: raster, scale: 1, orientation: .up)
        let regions = [ReaderTranslationRegion(id: "line", rect: CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.35),
                                                source: "泣", translation: "울음")]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let cache = ReaderTranslationRenderCache(disk: disk)
        let settings = ReaderTranslationSettings()
        let key = "full-settled-page"
        func render(_ cache: ReaderTranslationRenderCache) async throws -> ReaderTranslationImageExporter.LoadedPresentation {
            try await ReaderTranslationImageExporter.renderLoadedPresentation(image: source, regions: regions, settings: settings,
                viewport: source.size, scale: 1, aspectFit: true, dark: false, host: nil, cache: cache, key: key, pageIdentity: key)
        }
        let fresh = try await render(cache)
        #expect(fresh.freshSettledSource)
        let displayed = try pixels(fresh.image)
        #expect(try displayed != pixels(source))
        while cache.pendingAssetWrites > 0 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        cache.clearMemory()
        let reopenedDisk = ReaderTranslationDiskCache(directory: directory)
        let storageKey = ReaderTranslationRenderCache.renderAssetStorageKey(key)
        let bytes = try #require(try await reopenedDisk.data(for: storageKey, kind: .layout))
        #expect(ReaderTranslationCacheCodec.isSettledRenderArchive(bytes))
        let reopened = try #require(ReaderTranslationRenderAsset.decodeFromDisk(bytes))
        #expect(reopened.matches(regions: regions, sourceSize: source.size, sourceDigest: ReaderTranslationRenderAsset.digestSource(source)))
        let cold = try await render(ReaderTranslationRenderCache(disk: reopenedDisk))
        #expect(!cold.freshSettledSource)
        #expect(try pixels(cold.image) == displayed)
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
