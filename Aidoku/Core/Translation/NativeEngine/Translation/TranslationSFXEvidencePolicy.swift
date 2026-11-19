import Foundation
import CryptoKit

/// Source-bound auxiliary observations. No classification,
/// source rewriting, ownership, erasure or rendering decisions are made here.
enum TranslationSFXEvidencePolicy {
    static let cacheVersion = "llm-sfx-v73-dialogue-typography"
    static let evidenceVersion = "sfx-source-hints-v4-complete-prediction-inspection"

    /// Codable observations for the request's per-segment `sfx_evidence` field.
    /// No role, filter, text correction, or render authorization is produced here.
    struct Binding: Codable, Hashable, Sendable {
        let imageIdentity: String
        let sourceTextSHA256: String
        let sourceBounds: [Double]
    }

    enum Observation: String, Codable, Sendable {
        case present, absent, unmeasured
    }

    struct PixelObservations: Codable, Hashable, Sendable {
        let binding: Binding
        var openingQuote: Observation = .unmeasured
        var closingQuote: Observation = .unmeasured
        var alignedTextColumn: Observation = .unmeasured
        var irregularGlyphScaleOrOrientation: Observation = .unmeasured
        var enclosingContainer: Observation = .unmeasured
    }

    struct OCRQuotes: Codable, Hashable, Sendable {
        let openingCount: Int
        let closingCount: Int
        let matchedPairs: Int
        let unmatchedCount: Int
    }

    enum InspectionCheck: String, Codable, Sendable {
        case ownLettering, quoteEndpoints, nativeContourVersusRFSFX, rfTextVersusRFSFX
        case pixelEvidenceConflict, missingPixelObservations
        case rfTextOnlyPrediction, rfSFXOnlyPrediction, weakRFTextPrediction, weakRFSFXPrediction
        case noRFTextOrSFXPrediction
    }

    /// Preserve weak competing hypotheses for inspection, never as role answers.
    private static func predictionInspectionChecks(_ native: NativeTranslationRoleEvidence?) -> [InspectionCheck] {
        let hasText = (native?.rfTextConfidence ?? 0) > 0 && (native?.rfTextBBoxCoverage ?? 0) > 0
        let hasEffect = (native?.rfSFXConfidence ?? 0) > 0 && (native?.rfSFXBBoxCoverage ?? 0) > 0
        var checks: [InspectionCheck] = []
        if hasEffect, native?.contourVerified == true { checks.append(.nativeContourVersusRFSFX) }
        if hasText && hasEffect { checks.append(.rfTextVersusRFSFX) }
        if hasText && !hasEffect { checks.append(.rfTextOnlyPrediction) }
        if hasEffect && !hasText { checks.append(.rfSFXOnlyPrediction) }
        if hasText, (native?.rfTextConfidence ?? 0) < 0.5 { checks.append(.weakRFTextPrediction) }
        if hasEffect, (native?.rfSFXConfidence ?? 0) < 0.5 { checks.append(.weakRFSFXPrediction) }
        if !hasText && !hasEffect { checks.append(.noRFTextOrSFXPrediction) }
        return checks
    }

    struct Evidence: Codable, Hashable, Sendable {
        let policyVersion: String
        let binding: Binding
        let ocrQuotes: OCRQuotes
        let nativeRF: NativeTranslationRoleEvidence?
        let pixels: PixelObservations?
        let inspectionChecks: [InspectionCheck]

        func isBound(source: String, bounds: [Double], imageIdentity: String) -> Bool {
            guard let current = TranslationSFXEvidencePolicy.binding(source: source, bounds: bounds,
                imageIdentity: imageIdentity) else { return false }
            return policyVersion == evidenceVersion && binding == current &&
                (pixels.map { $0.binding == current } ?? true) &&
                (nativeRF.map { $0.isBound(source: source, bounds: bounds, imageIdentity: imageIdentity) } ?? true)
        }
    }

    static func binding(source: String, bounds: [Double], imageIdentity: String) -> Binding? {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard !source.isEmpty, source.utf8.count <= 16_384,
              imageIdentity.count == 64, imageIdentity.unicodeScalars.allSatisfy(hex.contains),
              bounds.count == 4, bounds.allSatisfy(\.isFinite), bounds[0] >= 0, bounds[1] >= 0,
              bounds[2] > 0, bounds[3] > 0, bounds[0] + bounds[2] <= 1, bounds[1] + bounds[3] <= 1 else { return nil }
        return Binding(imageIdentity: imageIdentity,
            sourceTextSHA256: SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined(),
            sourceBounds: bounds)
    }

    /// Call only with native evidence and pixel observations for the original source image.
    /// Invalid/stale auxiliaries are omitted independently; valid competing observations survive.
    static func make(source: String, bounds: [Double], imageIdentity: String,
                     nativeRF: NativeTranslationRoleEvidence? = nil, pixels: PixelObservations? = nil) -> Evidence? {
        guard let binding = binding(source: source, bounds: bounds, imageIdentity: imageIdentity) else { return nil }
        let native = nativeRF.flatMap { $0.isBound(source: source, bounds: bounds, imageIdentity: imageIdentity) ? $0 : nil }
        let pixels = pixels.flatMap { $0.binding == binding ? $0 : nil }
        let quotes = quoteSyntax(source)
        var checks: [InspectionCheck] = [.ownLettering]
        if quotes.openingCount + quotes.closingCount > 0 || pixels?.openingQuote == .present || pixels?.closingQuote == .present {
            checks.append(.quoteEndpoints)
        }
        checks.append(contentsOf: predictionInspectionChecks(native))
        if let pixels {
            let quoteConflict = (quotes.openingCount > 0 && pixels.openingQuote == .absent) ||
                (quotes.closingCount > 0 && pixels.closingQuote == .absent)
            let typographyConflict = pixels.irregularGlyphScaleOrOrientation == .present &&
                (pixels.openingQuote == .present || pixels.closingQuote == .present || pixels.alignedTextColumn == .present)
            if quoteConflict || typographyConflict { checks.append(.pixelEvidenceConflict) }
            if [pixels.openingQuote, pixels.closingQuote, pixels.alignedTextColumn,
                pixels.irregularGlyphScaleOrOrientation, pixels.enclosingContainer].contains(.unmeasured) {
                checks.append(.missingPixelObservations)
            }
        } else {
            checks.append(.missingPixelObservations)
        }
        return Evidence(policyVersion: evidenceVersion, binding: binding, ocrQuotes: quotes,
            nativeRF: native, pixels: pixels, inspectionChecks: checks)
    }

    /// Syntax only: matched Japanese/curly/ASCII quote pairs never establish a role.
    private static func quoteSyntax(_ source: String) -> OCRQuotes {
        let pairs: [Character: Character] = ["「": "」", "『": "』", "“": "”", "‘": "’", "\"": "\""]
        let closings = Set(pairs.values)
        var stack: [Character] = []
        var opening = 0, closing = 0, matched = 0
        for character in source {
            if character == "\"", stack.last == character {
                closing += 1; matched += 1; stack.removeLast()
            } else if let end = pairs[character] {
                opening += 1; stack.append(end)
            } else if closings.contains(character) {
                closing += 1
                if stack.last == character { matched += 1; stack.removeLast() }
            }
        }
        return OCRQuotes(openingCount: opening, closingCount: closing, matchedPairs: matched,
            unmatchedCount: opening + closing - 2 * matched)
    }
}
