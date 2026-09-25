// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

@available(iOS 18.0, *)
enum NativeOCRCGImageAdapter {
    /// Converts into deterministic RGBA8/premultiplied-last bytes. The returned
    /// frame owns its storage, so Core Graphics does not outlive the task.
    static func makeRGBAFrame(from image: CGImage) -> NativeOCRRGBAFrame? {
        guard !Task.isCancelled else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let rowResult = width.multipliedReportingOverflow(by: 4)
        guard !rowResult.overflow else { return nil }
        let bytesPerRow = rowResult.partialValue
        let countResult = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !countResult.overflow else { return nil }

        // The full, unpadded destination is overwritten with .copy below,
        // including transparent source pixels. Avoid zero-filling the same
        // multi-megabyte buffer immediately before Core Graphics writes it.
        let bytes = [UInt8](unsafeUninitializedCapacity: countResult.partialValue) { storage, initializedCount in
            guard let baseAddress = storage.baseAddress else { return }
            // Image masks stencil only covered pixels even with .copy. Keep
            // the historical transparent background for their untouched pixels.
            if image.isMask { storage.initialize(repeating: 0) }
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:
                    CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            initializedCount = countResult.partialValue
        }
        guard bytes.count == countResult.partialValue else { return nil }
        return NativeOCRRGBAFrame(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytes: bytes
        )
    }

    static func makeRGBAFrameOffMain(
        from image: CGImage
    ) async -> NativeOCRRGBAFrame? {
        guard !Task.isCancelled else { return nil }
        let work = Task.detached(priority: .userInitiated) {
            makeRGBAFrame(from: image)
        }
        return await withTaskCancellationHandler {
            let result = await work.value
            return Task.isCancelled ? nil : result
        } onCancel: { work.cancel() }
    }
}
