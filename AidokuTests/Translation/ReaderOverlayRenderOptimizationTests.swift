import Testing
import UIKit
import CoreImage
import ImageIO
@testable import Aidoku

/// Output-identity guards for the overlay render/export caches and the
/// single-pass composite. Every optimized result is compared byte-for-byte
/// with the previous implementation.
@Suite(.serialized)
@MainActor
struct ReaderOverlayRenderOptimizationTests {
    // MARK: Fixtures

    private static func source(size: CGSize, transparentBand: Bool = true) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            for y in stride(from: 0, to: Int(size.height), by: 7) {
                for x in stride(from: 0, to: Int(size.width), by: 5) {
                    UIColor(red: CGFloat(x % 255) / 255, green: CGFloat(y % 255) / 255,
                            blue: CGFloat((x * 3 + y) % 255) / 255, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 5, height: 7))
                }
            }
            if transparentBand {
                context.cgContext.clear(CGRect(x: 0, y: 0, width: size.width, height: 9))
                UIColor(white: 0.2, alpha: 0.37).setFill()
                context.fill(CGRect(x: 0, y: 9, width: size.width, height: 6))
            }
            UIColor.black.setStroke()
            context.cgContext.setLineWidth(1.3)
            context.cgContext.strokeEllipse(in: CGRect(x: 11.5, y: 23.25, width: size.width * 0.6, height: size.height * 0.4))
        }
    }

    private static func maskURL(_ size: CGSize, color: UIColor) -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
        return "data:image/png;base64," + image.pngData()!.base64EncodedString()
    }

    private static func typography(bounds: CGRect) -> Data {
        UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("번역된 대사입니다. Translation!" as NSString).draw(
                in: CGRect(x: 40, y: 50, width: 140, height: 80),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 15), .foregroundColor: UIColor.black])
            UIColor(red: 1, green: 1, blue: 1, alpha: 0.8).setFill()
            UIBezierPath(roundedRect: CGRect(x: 30, y: 180, width: 120, height: 40), cornerRadius: 8).fill()
            ("SFX" as NSString).draw(at: CGPoint(x: 50, y: 190),
                withAttributes: [.font: UIFont.italicSystemFont(ofSize: 18), .foregroundColor: UIColor.red])
        }
    }

    private static func layers(surfaces: Bool) -> ReaderTranslationImageExporter.ExportLayers {
        .init(
            masks: [
                .init(frame: [20.5, 30.25, 60, 40], opacity: 1, png: maskURL(CGSize(width: 60, height: 40), color: .white)),
                .init(frame: [100, 150, 33.3, 21.7], opacity: 0.55,
                      png: maskURL(CGSize(width: 67, height: 43), color: UIColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 0.7)))
            ],
            surfaces: surfaces ? [.init(frame: [28, 175, 126, 50], radius: 8, blur: 6, saturation: 1.4)] : [],
            paintBounds: [[36, 46, 150, 90], [26, 176, 130, 48]]
        )
    }

    /// The composite exactly as shipped before the single-pass change.
    private static func referenceComposite(image: UIImage, typography: Data,
                                           layers: ReaderTranslationImageExporter.ExportLayers,
                                           displayRect: CGRect, size: CGSize) throws -> UIImage {
        let scale = size.width / displayRect.width
        let scaleY = size.height / displayRect.height
        func outputFrame(_ values: [CGFloat]) -> CGRect {
            CGRect(x: (values[0] - displayRect.minX) * scale, y: (values[1] - displayRect.minY) * scaleY,
                   width: values[2] * scale, height: values[3] * scaleY)
        }
        let masks = try layers.masks.map { mask -> (UIImage, CGRect, CGFloat) in
            let encoded = try #require(mask.png.split(separator: ",", maxSplits: 1).last)
            let data = try #require(Data(base64Encoded: String(encoded)))
            let source = try #require(CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary))
            let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return (UIImage(cgImage: pixels), outputFrame(mask.frame), mask.opacity)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let destination = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let cleaned = renderer.image { _ in
            image.draw(in: destination)
            for (mask, rect, opacity) in masks { mask.draw(in: rect, blendMode: .normal, alpha: opacity) }
        }
        let cgImage = try #require(cleaned.cgImage)
        let source = CIImage(cgImage: cgImage).clampedToExtent()
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let surfaces = layers.surfaces.map { ($0, outputFrame($0.frame)) }
        let paintBounds = layers.paintBounds.map(outputFrame)
        let provider = try #require(CGDataProvider(data: typography as CFData))
        let page = try #require(CGPDFDocument(provider)?.page(at: 1))
        let pageBounds = page.getBoxRect(.mediaBox)
        return renderer.image { drawing in
            cleaned.draw(in: destination)
            for (surface, frame) in surfaces {
                let crop = frame.integral.intersection(destination)
                guard !crop.isEmpty else { continue }
                let filtered = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: surface.blur * scale])
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: surface.saturation])
                let ciRect = CGRect(x: crop.minX, y: size.height - crop.maxY, width: crop.width, height: crop.height)
                guard let patch = context.createCGImage(filtered, from: ciRect) else { continue }
                drawing.cgContext.saveGState()
                UIBezierPath(roundedRect: frame, cornerRadius: surface.radius * scale).addClip()
                UIImage(cgImage: patch).draw(in: crop)
                drawing.cgContext.restoreGState()
            }
            if !paintBounds.isEmpty {
                drawing.cgContext.saveGState()
                drawing.cgContext.addRects(paintBounds)
                drawing.cgContext.clip()
                drawing.cgContext.translateBy(x: 0, y: size.height)
                drawing.cgContext.scaleBy(x: size.width / pageBounds.width, y: -size.height / pageBounds.height)
                drawing.cgContext.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
                drawing.cgContext.drawPDFPage(page)
                drawing.cgContext.restoreGState()
            }
        }
    }

    private struct RawBitmap: Equatable {
        let width, height, bytesPerRow, bitsPerPixel: Int
        let bitmapInfo: UInt32
        let bytes: Data
    }

    private static func raw(_ image: UIImage) throws -> RawBitmap {
        let cg = try #require(image.cgImage)
        let data = try #require(cg.dataProvider?.data) as Data
        return RawBitmap(width: cg.width, height: cg.height, bytesPerRow: cg.bytesPerRow,
                         bitsPerPixel: cg.bitsPerPixel, bitmapInfo: cg.bitmapInfo.rawValue, bytes: data)
    }

    // MARK: Composite

    @Test(arguments: [false, true])
    func compositeIsPixelIdenticalToTwoPassReference(surfaces: Bool) throws {
        let display = CGRect(x: 0, y: 0, width: 240, height: 320)
        let typography = Self.typography(bounds: display)
        let layers = Self.layers(surfaces: surfaces)
        for (imageSize, outputSize, rect) in [
            (CGSize(width: 240, height: 320), CGSize(width: 240, height: 320), display),
            (CGSize(width: 600, height: 800), CGSize(width: 517, height: 689), display),
            (CGSize(width: 333, height: 444), CGSize(width: 480, height: 640), display.offsetBy(dx: 3.5, dy: -2.25))
        ] {
            let image = Self.source(size: imageSize)
            let optimized = try ReaderTranslationImageExporter.composite(
                image: image, typography: typography, layers: layers, displayRect: rect, size: outputSize)
            let reference = try Self.referenceComposite(
                image: image, typography: typography, layers: layers, displayRect: rect, size: outputSize)
            #expect(try Self.raw(optimized) == Self.raw(reference))
            #expect(optimized.pngData() == reference.pngData())
        }
    }

    // MARK: Background data URL

    @Test func backgroundDataURLCacheReturnsIdenticalEncodingAndReleasesWithImage() throws {
        ReaderTranslationBackgroundImage.encodedDataURLs.removeAll()
        var image: UIImage? = Self.source(size: CGSize(width: 320, height: 240))
        let fresh = try #require(ReaderTranslationBackgroundImage.prepare(image!).pngData())
        let expected = "data:image/png;base64," + fresh.base64EncodedString()
        let first = try ReaderTranslationBackgroundImage.dataURL(for: image!)
        #expect(first == expected)
        #expect(ReaderTranslationBackgroundImage.encodedDataURLs.count == 1)
        let second = try ReaderTranslationBackgroundImage.dataURL(for: image!)
        #expect(second == expected)
        // Oversized sources are downsampled first; the cached value must match.
        let large = Self.source(size: CGSize(width: 2_600, height: 2_000), transparentBand: false)
        let largeExpected = "data:image/png;base64,"
            + (try #require(ReaderTranslationBackgroundImage.prepare(large).pngData())).base64EncodedString()
        #expect(try ReaderTranslationBackgroundImage.dataURL(for: large) == largeExpected)
        #expect(try ReaderTranslationBackgroundImage.dataURL(for: large) == largeExpected)
        // A different instance with the same pixels is a separate key.
        let copy = UIImage(cgImage: try #require(image?.cgImage))
        #expect(try ReaderTranslationBackgroundImage.dataURL(for: copy) == expected)
        #expect(ReaderTranslationBackgroundImage.encodedDataURLs.count
                <= ReaderTranslationBackgroundImage.encodedDataURLs.capacity)
        image = nil
        _ = copy
        ReaderTranslationBackgroundImage.encodedDataURLs.removeAll()
        #expect(ReaderTranslationBackgroundImage.encodedDataURLs.count == 0)
    }

    @Test func cachedBackgroundBypassesBusyEncoderWhileColdBackgroundRemainsBounded() async throws {
        ReaderTranslationBackgroundImage.encodedDataURLs.removeAll()
        let hot = Self.source(size: CGSize(width: 32, height: 32))
        let cold = Self.source(size: CGSize(width: 33, height: 32))
        let encoded = try ReaderTranslationBackgroundImage.dataURL(for: hot)
        let expected = try #require(encoded)
        let gate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let blocker = Task {
            try await gate.withPermit {
                entered.continuation.yield(())
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
        }
        defer {
            release.continuation.finish()
            entered.continuation.finish()
            blocker.cancel()
        }
        var admission = entered.stream.makeAsyncIterator()
        _ = await admission.next()
        let coldTask = Task { try await ReaderTranslationBackgroundImage.scheduledDataURL(for: cold, gate: gate) }
        defer { coldTask.cancel() }
        var result: String?
        let hotTask = Task { result = try await ReaderTranslationBackgroundImage.scheduledDataURL(for: hot, gate: gate) }
        defer { hotTask.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            let queued = await gate.queuedRequestCount
            if result != nil && queued > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        // A regression must fail without hanging behind the intentionally held permit.
        #expect(result == expected)
        #expect(await gate.queuedRequestCount == 1)
        #expect(ReaderTranslationBackgroundImage.encodedDataURLs.value(for: cold) == nil)
        release.continuation.finish()
        try await blocker.value
        try await hotTask.value
        let coldResult = try await coldTask.value
        #expect(coldResult == ReaderTranslationBackgroundImage.encodedDataURLs.value(for: cold))
        #expect(coldResult != nil)
    }

    @Test func cancelledBackgroundCacheHitStillHonorsCancellation() async throws {
        let image = Self.source(size: CGSize(width: 32, height: 32))
        _ = try ReaderTranslationBackgroundImage.dataURL(for: image)
        let gate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let task = Task { @MainActor in
            try await ReaderTranslationBackgroundImage.scheduledDataURL(for: image, gate: gate)
        }
        // MainActor inheritance guarantees the body cannot run before this cancel.
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled cache hit returned an encoding")
        } catch is CancellationError {
            #expect(await gate.queuedRequestCount == 0)
        }
    }

    @Test func identityCacheIsWeakAndBounded() async throws {
        let cache = ReaderTranslationImageIdentityCache<String>(capacity: 2)
        var images: [UIImage] = autoreleasepool { (0..<4).map { _ in Self.source(size: CGSize(width: 8, height: 8)) } }
        for (index, image) in images.enumerated() { cache.store("v\(index)", for: image) }
        #expect(cache.count == 2)
        #expect(cache.value(for: images[0]) == nil)
        #expect(cache.value(for: images[3]) == "v3")
        #expect(cache.value(for: images[2]) == "v2")
        weak var released: UIImage?
        autoreleasepool {
            let transient = Self.source(size: CGSize(width: 8, height: 8))
            released = transient
            cache.store("transient", for: transient)
        }
        autoreleasepool { images.removeAll() }
        #expect(released == nil)
        for _ in 0..<50 where cache.count > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cache.count == 0)
    }

    // MARK: Source digest

    @Test func sourceDigestCacheMatchesUncachedDigest() throws {
        ReaderTranslationRenderAsset.sourceDigests.removeAll()
        let image = Self.source(size: CGSize(width: 200, height: 150))
        let first = try #require(ReaderTranslationRenderAsset.digestSource(image))
        #expect(ReaderTranslationRenderAsset.sourceDigests.value(for: image) == first)
        #expect(ReaderTranslationRenderAsset.digestSource(image) == first)
        // A fresh instance over the same pixels is hashed from scratch.
        let twin = UIImage(cgImage: try #require(image.cgImage), scale: image.scale, orientation: image.imageOrientation)
        #expect(ReaderTranslationRenderAsset.sourceDigests.value(for: twin) == nil)
        #expect(ReaderTranslationRenderAsset.digestSource(twin) == first)
        let other = Self.source(size: CGSize(width: 200, height: 151))
        #expect(ReaderTranslationRenderAsset.digestSource(other) != first)
        #expect(ReaderTranslationRenderAsset.sourceDigests.count <= ReaderTranslationRenderAsset.sourceDigests.capacity)
    }

    // MARK: Measurement cache

    @Test func measurementCacheIsBoundedAndReturnsCalculatedValues() {
        let cache = BrowserOverlayTextMeasurementCache()
        let hot = BrowserOverlayDisplayVariant.plain("hot", vertical: false)
        var calls = 0
        func size(_ variant: BrowserOverlayDisplayVariant, _ width: CGFloat) -> CGSize {
            cache.measuredSize(for: variant, width: width, fontSize: 12) {
                calls += 1
                return CGSize(width: width, height: CGFloat(variant.hashValue & 0xff))
            }
        }
        #expect(size(hot, 1) == CGSize(width: 1, height: CGFloat(hot.hashValue & 0xff)))
        for index in 0..<40_000 {
            let variant = BrowserOverlayDisplayVariant.plain("v\(index)", vertical: false)
            #expect(size(variant, CGFloat(index)) == CGSize(width: CGFloat(index), height: CGFloat(variant.hashValue & 0xff)))
            // A value in active use survives generation turnover.
            if index % 1_000 == 0 {
                let before = calls
                _ = size(hot, 1)
                if index > 0 { #expect(calls == before) }
            }
            #expect(cache.entryCount <= 16_384)
        }
        #expect(calls == 40_001)
        let before = calls
        _ = size(BrowserOverlayDisplayVariant.plain("v39999", vertical: false), 39_999)
        #expect(calls == before)
        cache.removeAll()
        #expect(cache.entryCount == 0)
    }
}
