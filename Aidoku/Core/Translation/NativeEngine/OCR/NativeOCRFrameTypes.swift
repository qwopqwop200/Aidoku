// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

/// Immutable, tightly described RGBA pixels. Row padding is accepted but is never
/// read as pixels.
@available(iOS 18.0, *)
struct NativeOCRRGBAFrame: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    init?(width: Int, height: Int, bytesPerRow: Int? = nil, bytes: [UInt8]) {
        guard width > 0, height > 0 else { return nil }
        let minimumBytesPerRow = width.multipliedReportingOverflow(by: 4)
        guard !minimumBytesPerRow.overflow else { return nil }
        let resolvedBytesPerRow = bytesPerRow ?? minimumBytesPerRow.partialValue
        guard resolvedBytesPerRow >= minimumBytesPerRow.partialValue else { return nil }
        let requiredBytes = resolvedBytesPerRow.multipliedReportingOverflow(by: height)
        guard !requiredBytes.overflow, bytes.count >= requiredBytes.partialValue else { return nil }
        self.width = width
        self.height = height
        self.bytesPerRow = resolvedBytesPerRow
        self.bytes = bytes
    }
}
