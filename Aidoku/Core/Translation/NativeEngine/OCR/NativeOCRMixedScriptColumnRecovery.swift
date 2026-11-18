import CoreGraphics
import Foundation

/// Legacy stored data only. No independent OCR reading or provider context is produced.
struct ReaderTranslationSourceOCRAlternative: Codable, Equatable, Sendable {
    let originalText: String
    let exactReading: String
    let paddedReading: String
    let rect: CGRect
    let primaryConfidence: Double
    let exactConfidence: Float
    let paddedConfidence: Float
}
