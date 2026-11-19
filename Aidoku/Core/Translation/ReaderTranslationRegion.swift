import CoreGraphics
import Foundation

struct ReaderTranslationRegion: Equatable, Sendable {
    let id: String
    let rect: CGRect // Normalized image coordinates, top-left origin.
    let source: String
    var translation: String?
    /// A classified effect retains its source pixels even though its translated
    /// text is stored for diagnostics and cache reuse.
    var keepsClassifiedSFXSource = false
    /// Changed symbol-only output may need typesetting; identical output keeps source pixels.
    var rendersUnchangedSymbols = false
    var polygon: [CGPoint] = [] // Normalized; retain the detector/merger geometry.
    var confidence: Double = 1
    var sourceImageAspectRatio: Double? = nil
    var translationOrder: Int? = nil
    var translationOrderVersion: String? = nil
    var sourceOrientation: BrowserOCRSourceOrientation = .unknown
    var sourceSingleVerticalColumn: Bool?
    var translationReuseIdentity: NativeTranslationReuseIdentity?
    /// Explicit optional-recovery failure stored with older cache rows.
    var translationRecoveryFailure: String? = nil

    mutating func applyTranslation(_ segment: RemoteTranslatedSegment) {
        // A false OCR detection is not lettering: keep its original pixels and
        // ignore any schema-required text returned with the error role.
        if segment.textRole == .error {
            translation = source
            keepsClassifiedSFXSource = false
            rendersUnchangedSymbols = false
            return
        }
        let keepSFX = segment.isSFX == true || segment.textRole == .sfx
        let effectiveText = segment.textRole == .background ? source : segment.text
        let original = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceScalars = original.unicodeScalars
        let renderSymbols = !keepSFX && segment.textRole != .background &&
            effectiveText.trimmingCharacters(in: .whitespacesAndNewlines) != original &&
            !sourceScalars.isEmpty && sourceScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) ||
                    CharacterSet.whitespacesAndNewlines.contains($0)
            }
        // Object lettering is translated by the provider for diagnostics, but
        // its original pixels must not receive a speech-style overlay.
        translation = effectiveText
        keepsClassifiedSFXSource = keepSFX
        rendersUnchangedSymbols = renderSymbols
    }
}
