// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
enum BrowserOCRSourceOrientation: String, Equatable, Encodable, Sendable {
    case horizontal, vertical, unknown

    init(tolerantRawValue: String?) {
        self = tolerantRawValue.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}
