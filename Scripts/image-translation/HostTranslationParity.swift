import Foundation
import CoreGraphics
import ImageIO

/// Host equivalents of the UIKit page-image preparation and the reader's
/// completed-batch balloon recovery. Keep the policy in step with the reader.
enum HostTranslationParity {
    static func translationJPEG(_ image: CGImage) throws -> Data {
        guard image.width > 0, image.height > 0 else {
            throw RemoteTranslationError.invalidRequest("The page image is empty.")
        }
        let ratio = min(1, 2048 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let normalized = context.makeImage() else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        CGImageDestinationAddImage(destination, normalized,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 4 * 1024 * 1024 else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        return data as Data
    }

    /// Mirrors ReaderTranslationService's one retry after a completed filtered
    /// batch silently preserves independently verified Japanese balloon prose.
    static func recoveringBalloonDialogue(
        request: RemoteTranslationRequest,
        result: RemoteTranslationBatchResult,
        regionsByID: [String: ReaderTranslationRegion],
        retry: @Sendable (RemoteTranslationRequest) async throws -> RemoteTranslationBatchResult
    ) async throws -> RemoteTranslationBatchResult {
        try Task.checkCancellation()
        let missed = Set(result.translations.compactMap { translated -> String? in
            guard let region = regionsByID[translated.id],
                  ReaderTranslationLanguageFilter.requiresBalloonTranslation(region,
                    translation: translated.text, target: request.targetLanguage) else { return nil }
            return translated.id
        })
        guard !missed.isEmpty else { return result }
        var recovery = RemoteTranslationRequest(sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage,
            segments: request.segments.filter { missed.contains($0.id) },
            context: request.context, glossary: request.glossary)
        recovery.copyImageRepresentation(from: request)
        HostDump.capture("balloon-translation-recovery-request", recovery)
        let retried = try await retry(recovery)
        HostDump.capture("balloon-translation-recovery-result", retried)
        let replacements = Dictionary(retried.translations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        for id in missed {
            guard let region = regionsByID[id], let translated = replacements[id],
                  !ReaderTranslationLanguageFilter.requiresBalloonTranslation(region,
                    translation: translated.text, target: request.targetLanguage) else {
                throw RemoteTranslationError.invalidResponse("balloon dialogue was not translated")
            }
        }
        return .init(translations: result.translations.map { replacements[$0.id] ?? $0 },
            source: .network, providerRequestID: retried.providerRequestID)
    }
}
