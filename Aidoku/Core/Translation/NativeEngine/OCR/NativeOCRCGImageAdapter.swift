// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

@available(iOS 18.0, *)
enum NativeOCRCGImageAdapter {
    /// Converts into deterministic RGBA8/premultiplied-last bytes. The returned
    /// frame owns its storage, so Core Graphics does not outlive the task.
    static func makeRGBAFrame(from image: CGImage) -> NativeOCRRGBAFrame? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let rowResult = width.multipliedReportingOverflow(by: 4)
        guard !rowResult.overflow else { return nil }
        let bytesPerRow = rowResult.partialValue
        let countResult = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !countResult.overflow else { return nil }

        var bytes = [UInt8](repeating: 0, count: countResult.partialValue)
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let baseAddress = storage.baseAddress else { return false }
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
                return false
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else { return nil }
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
        await Task.detached(priority: .userInitiated) {
            makeRGBAFrame(from: image)
        }.value
    }
}
