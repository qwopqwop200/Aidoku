// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

enum BrowserOCRSourceOrientation: String, Equatable, Sendable {
    case horizontal
    case vertical
    case unknown

    init(tolerantRawValue: String?) {
        self = tolerantRawValue.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}
