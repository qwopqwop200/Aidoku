import CoreGraphics
import Foundation
import Darwin

/// Native vector capture used by image saving. Reader presentation keeps its
/// independent bitmap scale and never adopts the PDF page's integral crop.
enum NativeTranslationPDFCapture {
    struct Capture { let image: CGImage; let data: Data; let mediaBox: CGRect }
    struct Document { let data: Data; let mediaBox: CGRect }
    struct GradientGeometry { let destination: CGRect; let tile: CGSize; let usesPattern: Bool }
    enum CaptureError: Error { case invalidGeometry, unavailable, invalidPDF }

    static func layoutUnit(_ value: CGFloat) -> CGFloat { (value * 64).rounded(.towardZero) / 64 }

    /// Border painting snaps its edges to the document's device grid. Float
    /// precision is intentional: the settled browser border is a FloatRect.
    static func snappedRect(_ frame: CGRect, deviceScale: CGFloat) -> CGRect {
        guard deviceScale.isFinite, deviceScale > 0 else { return frame }
        func snap(_ value: CGFloat) -> Float { Float(floor(value * deviceScale + 0.5) / deviceScale) }
        func snappedSize(_ extent: CGFloat, _ origin: CGFloat) -> Float {
            let fraction = layoutUnit(origin).truncatingRemainder(dividingBy: 1)
            // Size is snapped relative to the fractional origin. Subtraction
            // happens in Float32 after each edge is rounded, as in FloatSize.
            return snap(fraction + layoutUnit(extent)) - snap(fraction)
        }
        return CGRect(x: CGFloat(snap(layoutUnit(frame.origin.x))), y: CGFloat(snap(layoutUnit(frame.origin.y))),
            width: CGFloat(snappedSize(frame.size.width, frame.origin.x)),
            height: CGFloat(snappedSize(frame.size.height, frame.origin.y)))
    }

    static func roundedPath(_ frame: CGRect, radius: CGFloat, deviceScale: CGFloat) -> CGPath {
        let border = CGRect(x: layoutUnit(frame.origin.x), y: layoutUnit(frame.origin.y),
            width: layoutUnit(frame.size.width), height: layoutUnit(frame.size.height))
        let snapped = snappedRect(border, deviceScale: deviceScale)
        guard border.size.width > 0, border.size.height > 0 else { return CGPath(rect: snapped, transform: nil) }
        let rx = CGFloat(Float(radius) * (Float(snapped.width) / Float(border.size.width)))
        let ry = CGFloat(Float(radius) * (Float(snapped.height) / Float(border.size.height)))
        return CGPath(roundedRect: snapped, cornerWidth: rx, cornerHeight: ry, transform: nil)
    }

    /// Background positioning snaps its intrinsic tile once, then snaps that
    /// tile again at the unsnapped border origin. A smaller second tile cannot
    /// cover the whole destination: that exact containment decision selects a
    /// raster pattern. This is geometry, independent of text/orientation.
    static func gradientGeometry(frame: CGRect, deviceScale: CGFloat) -> GradientGeometry {
        let border = CGRect(x: layoutUnit(frame.origin.x), y: layoutUnit(frame.origin.y),
            width: layoutUnit(frame.size.width), height: layoutUnit(frame.size.height))
        let snapped = snappedRect(border, deviceScale: deviceScale)
        let initial = CGSize(width: layoutUnit(snapped.width), height: layoutUnit(snapped.height))
        let second = snappedRect(CGRect(origin: border.origin, size: initial), deviceScale: deviceScale)
        let tile = CGSize(width: layoutUnit(second.width), height: layoutUnit(second.height))
        let destination = CGRect(x: layoutUnit(snapped.minX), y: layoutUnit(snapped.minY), width: initial.width, height: initial.height)
        let needsPattern = tile.width < destination.width || tile.height < destination.height
        // Large tiles are painted directly instead of allocating a cached tile.
        let usesPattern = needsPattern && tile.width * tile.height <= 512 * 512
        return .init(destination: destination, tile: tile, usesPattern: usesPattern)
    }

    /// Preserve Quartz's actual PDF semantics: axial gradients serialize
    /// natively, while a tiled gradient carries its raster's alpha mask.
    static func drawFallbackGradient(context: CGContext, frame: CGRect, lightSurface: Bool, deviceScale: CGFloat) {
        let geometry = gradientGeometry(frame: frame, deviceScale: deviceScale)
        guard geometry.destination.size.width > 0, geometry.destination.size.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let values: [CGFloat] = lightSurface ? [1, 1, 1] : [7.0 / 255, 9.0 / 255, 13.0 / 255]
        // CSS rgba() colors resolve to packed 8-bit alpha before painting.
        let alpha: CGFloat = ((lightSurface ? CGFloat(0.42) : CGFloat(0.64)) * 255).rounded() / 255
        context.saveGState(); defer { context.restoreGState() }
        context.setAlpha(1)
        context.clip(to: geometry.destination)
        if geometry.usesPattern, geometry.tile.height > 0, geometry.tile.height <= 16_384 {
            let height = Int(ceil(geometry.tile.height))
            guard let bitmap = CGContext(data: nil, width: 1, height: height, bitsPerComponent: 8, bytesPerRow: 4,
                    space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                  let color = CGColor(colorSpace: space, components: values + [alpha]),
                  let gradient = CGGradient(colorsSpace: space, colors: [color, color] as CFArray, locations: [0, 1]) else { return }
            // The generated tile is an actual gradient raster, even when both
            // stops agree. Quartz's RGB dithering survives in its PDF image.
            bitmap.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: geometry.tile.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            guard let image = bitmap.makeImage() else { return }
            // Cached bitmap tiles use image coordinates, independently of
            // the page's top-left layout coordinates. Preserve their row order
            // and phase when Quartz serializes the PDF pattern matrix.
            context.translateBy(x: geometry.destination.minX, y: geometry.destination.minY + geometry.tile.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: geometry.tile.height), byTiling: true)
        } else {
            guard let color = CGColor(colorSpace: space, components: values + [alpha]),
                  let gradient = CGGradient(colorsSpace: space, colors: [color, color] as CFArray, locations: [0, 1]) else { return }
            context.drawLinearGradient(gradient, start: geometry.destination.origin,
                end: CGPoint(x: geometry.destination.minX, y: geometry.destination.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    /// Snapshot requests become FloatRect before IntRect: each component
    /// narrows to Float32, then clamps to Int32 with truncation toward zero.
    /// A tiny negative aspect-fit origin therefore remains zero, not minus one.
    static func integralCaptureRect(_ bounds: CGRect) -> CGRect {
        func component(_ value: CGFloat) -> CGFloat {
            let narrowed = Float(value)
            if narrowed.isNaN || narrowed <= Float(Int32.min) { return CGFloat(Int32.min) }
            if narrowed >= Float(Int32.max) { return CGFloat(Int32.max) }
            return CGFloat(Int32(narrowed))
        }
        return CGRect(x: component(bounds.origin.x), y: component(bounds.origin.y),
            width: component(bounds.size.width), height: component(bounds.size.height))
    }

    /// Bitmap extents must match the dimensions allocated by Int conversion.
    static func validPixelSize(_ pixels: CGSize) -> Bool {
        pixels.width.isFinite && pixels.height.isFinite &&
        pixels.width >= 1 && pixels.height >= 1 &&
        pixels.width.rounded(.towardZero) == pixels.width &&
        pixels.height.rounded(.towardZero) == pixels.height &&
        pixels.width <= 16_384 && pixels.height <= 16_384 &&
        pixels.width * pixels.height <= 12_000_000
    }

    /// Validate the derived transform before allocating or drawing in Quartz.
    static func validatedRasterTransform(media: CGRect, pixels: CGSize) throws -> CGAffineTransform {
        guard validPixelSize(pixels),
              [media.origin.x, media.origin.y, media.size.width, media.size.height,
               media.maxX, media.maxY].allSatisfy(\.isFinite),
              media.size.width > 0, media.size.height > 0 else { throw CaptureError.invalidGeometry }
        let sx = pixels.width / media.width, sy = pixels.height / media.height
        let transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
            tx: -media.minX * sx, ty: -media.minY * sy)
        guard [transform.a, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite),
              transform.a > 0, transform.d > 0 else { throw CaptureError.invalidGeometry }
        return transform
    }

    static func capture(bounds: CGRect, pixels: CGSize, deviceScale: CGFloat = 1,
                        alignsToLogicalBounds: Bool = false, paint: (CGContext) -> Void) throws -> Capture {
        let document = try captureDocument(bounds: bounds, pixels: pixels, deviceScale: deviceScale,
            alignsToLogicalBounds: alignsToLogicalBounds, paint: paint)
        let image = try rasterize(data: document.data, pixels: pixels)
        return Capture(image: image, data: document.data, mediaBox: document.mediaBox)
    }

    /// Export composition can consume the vector document directly without
    /// allocating a second full-page typography bitmap.
    static func captureDocument(bounds: CGRect, pixels: CGSize, deviceScale: CGFloat = 1,
                                alignsToLogicalBounds: Bool = false,
                                paint: (CGContext) -> Void) throws -> Document {
        try captureDocument(bounds: bounds, pixels: pixels, deviceScale: deviceScale,
            alignsToLogicalBounds: alignsToLogicalBounds, maximumBytes: nil, paint: paint)
    }

    enum DocumentBudgetError: Error { case exhausted }

    private final class BoundedSink {
        var pointer: UnsafeMutableRawPointer?
        var capacity = 0
        let limit: Int
        var written = 0
        var exhausted = false
        var cancelled = false
        var allocationFailed = false

        init?(limit: Int) {
            self.limit = limit
        }
        deinit { clear() }
        func clear() {
            if let pointer {
                free(pointer)
            }
            pointer = nil; capacity = 0
        }
        func append(_ buffer: UnsafeRawPointer, count: Int) -> Bool {
            guard !allocationFailed else { return false }
            if pointer == nil {
                let size = min(limit, 65_536)
                guard let allocation = malloc(size) else { allocationFailed = true; return false }
                pointer = allocation; capacity = size
            }
            if count > capacity - written {
                guard let allocation = malloc(limit) else { allocationFailed = true; return false }
                memcpy(allocation, pointer!, written)
                free(pointer!)
                pointer = allocation; capacity = limit
            }
            memcpy(pointer!.advanced(by: written), buffer, count)
            return true
        }
        func flattened() throws -> Data {
            guard written > 0 else { clear(); return Data() }
            guard let output = pointer else { throw CaptureError.unavailable }
            pointer = nil
            capacity = 0
            return Data(bytesNoCopy: output, count: written, deallocator: .custom { pointer, _ in
                free(pointer)
            })
        }
    }

    /// Cap bytes at the consumer, before Quartz can grow an unbounded output buffer.
    /// This bounds serialized bytes, not allocator rounding or native RSS.
    /// Requested bank bytes peak at limit + min(limit, 65_536) during one growth.
    static func captureDocument(bounds: CGRect, pixels: CGSize, deviceScale: CGFloat = 1,
                                alignsToLogicalBounds: Bool = false, maximumBytes: Int?,
                                paint: (CGContext) -> Void) throws -> Document {
        try Task.checkCancellation()
        let components = [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height]
        guard components.allSatisfy(\.isFinite), [bounds.maxX, bounds.maxY].allSatisfy(\.isFinite),
              components.allSatisfy({ Float($0).isFinite && Float($0) >= Float(Int32.min) && Float($0) < Float(Int32.max) }),
              validPixelSize(pixels),
              bounds.size.width >= 1, bounds.size.height >= 1,
              deviceScale.isFinite, deviceScale > 0, Float(deviceScale).isFinite, Float(deviceScale) > 0,
              Float(1 / deviceScale).isFinite, Float(1 / deviceScale) > 0 else {
            throw CaptureError.invalidGeometry
        }
        // The frozen capture truncates the requested page/crop to whole points.
        // Crop origin and media extent round independently, not as one endpoint.
        let crop = integralCaptureRect(bounds)
        var media = CGRect(origin: .zero, size: crop.size)
        let sink: BoundedSink?
        if let maximumBytes {
            guard maximumBytes > 0, maximumBytes <= 48 * 1_024 * 1_024 else { throw CaptureError.invalidGeometry }
            guard let bounded = BoundedSink(limit: maximumBytes) else { throw CaptureError.unavailable }
            sink = bounded
        } else {
            sink = nil
        }
        let storage = NSMutableData()
        let consumer: CGDataConsumer?
        if let sink {
            var callbacks = CGDataConsumerCallbacks(putBytes: { info, buffer, count in
                guard let info else { return 0 }
                let state = Unmanaged<BoundedSink>.fromOpaque(info).takeUnretainedValue()
                if Task.isCancelled { state.cancelled = true; return 0 }
                guard count >= 0, count <= state.limit - state.written else {
                    state.exhausted = true; return 0
                }
                if count > 0, !state.append(buffer, count: count) { return 0 }
                state.written += count
                return count
            }, releaseConsumer: nil)
            consumer = CGDataConsumer(info: Unmanaged.passUnretained(sink).toOpaque(), cbks: &callbacks)
        } else {
            consumer = CGDataConsumer(data: storage as CFMutableData)
        }
        guard let consumer,
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw CaptureError.unavailable }
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: media.height)
        context.scaleBy(x: 1, y: -1)
        // Snapshot painting narrows the page device scale to Float32, then
        // applies its reciprocal computed from the original scale and stored
        // as Float32. Preserve both operations and their
        // order: a 3x page has an effective scale slightly above one. The crop
        // translation follows those scales, so it shares the same precision.
        context.scaleBy(x: CGFloat(Float(deviceScale)), y: CGFloat(Float(deviceScale)))
        let snapshotScale = CGFloat(Float(1 / deviceScale))
        context.scaleBy(x: snapshotScale, y: snapshotScale)
        if alignsToLogicalBounds {
            // Export stretches integral media back to the complete logical bounds.
            // Normalize here, not in glyph anchors, so backing and text agree.
            context.scaleBy(x: crop.width / bounds.width, y: crop.height / bounds.height)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
        } else {
            context.translateBy(x: -crop.origin.x, y: -crop.origin.y)
        }
        paint(context)
        context.endPDFPage()
        context.closePDF()
        try Task.checkCancellation()
        if let sink {
            if sink.cancelled { throw CancellationError() }
            if sink.exhausted { throw DocumentBudgetError.exhausted }
            if sink.allocationFailed { throw CaptureError.unavailable }
            let data = try sink.flattened()
            return Document(data: data, mediaBox: media)
        }
        let data = storage as Data
        return Document(data: data, mediaBox: media)
    }

    static func rasterize(data: Data, pixels: CGSize) throws -> CGImage {
        try Task.checkCancellation()
        guard validPixelSize(pixels),
              let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              document.numberOfPages == 1, let page = document.page(at: 1) else { throw CaptureError.invalidPDF }
        let media = page.getBoxRect(.mediaBox)
        _ = try validatedRasterTransform(media: media, pixels: pixels)
        guard media.size.width.isFinite, media.size.height.isFinite, media.size.width > 0, media.size.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                bytesPerRow: Int(pixels.width) * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.invalidGeometry
        }
        context.scaleBy(x: pixels.width / media.width, y: pixels.height / media.height)
        context.translateBy(x: -media.minX, y: -media.minY)
        context.drawPDFPage(page)
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw CaptureError.unavailable }
        return image
    }
}
