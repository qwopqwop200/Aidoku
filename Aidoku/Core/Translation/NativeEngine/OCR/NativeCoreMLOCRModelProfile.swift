// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

@available(iOS 18.0, *)
struct NativeCoreMLOCRModelProfile: Equatable, Sendable {
    let tier: IPhoneOCRModelTier
    let detectorResourceName: String
    let recognizerResourceName: String
    let dictionaryResourceName: String
    let expectedDictionaryCharacterCount: Int
    let postprocessConfiguration: NativeCoreMLDBPostprocessConfiguration

    /// Detector components scoring at least this (below the box threshold) may be
    /// recovered by the adjacent-line pass (`NativeOCRAdjacentLineRecovery.boxThreshold`).
    static let adjacentLineRecoveryBoxThreshold = 0.5

    static func profile(for tier: IPhoneOCRModelTier) -> Self {
        switch tier {
        case .medium:
            Self(
                tier: tier,
                detectorResourceName: "PP-OCRv6-Medium-DetShapes",
                recognizerResourceName: "PP-OCRv6-Medium-RecWidths",
                dictionaryResourceName:
                    "ppocrv6_medium_rec_character_dict",
                expectedDictionaryCharacterCount: 18_709,
                postprocessConfiguration: .production.withRecoveryBoxThreshold(adjacentLineRecoveryBoxThreshold)
            )
        case .small:
            Self(
                tier: tier,
                detectorResourceName: "PP-OCRv6-Small-DetShapes",
                recognizerResourceName: "PP-OCRv6-Small-RecWidths",
                dictionaryResourceName:
                    "ppocrv6_small_rec_character_dict",
                expectedDictionaryCharacterCount: 18_709,
                postprocessConfiguration: .production.withRecoveryBoxThreshold(adjacentLineRecoveryBoxThreshold)
            )
        case .manga:
            Self(
                tier: tier,
                detectorResourceName: "PP-OCRv6-Manga-DetShapes",
                recognizerResourceName: "PP-OCRv6-Manga-RecWidths",
                dictionaryResourceName: "ppocrv6_manga_rec_character_dict",
                expectedDictionaryCharacterCount: 19_054,
                postprocessConfiguration: .manga
            )
        case .tiny:
            Self(
                tier: tier,
                detectorResourceName: "PP-OCRv6-Tiny-DetShapes",
                recognizerResourceName: "PP-OCRv6-Tiny-RecWidths",
                dictionaryResourceName:
                    "ppocrv6_tiny_rec_character_dict",
                expectedDictionaryCharacterCount: 6_905,
                postprocessConfiguration: .tiny
            )
        }
    }
}
