import CoreGraphics
import Foundation
import Vision

/// PP-OCR's bundled dictionaries cannot transcribe these scripts. Keep its
/// manga geometry and CJK/Latin recognition, supplementing only observed script
/// evidence from on-device Vision. No image or OCR text leaves this process.
@available(iOS 18.0, *)
enum ReaderSupplementalOCR {
    static func recognize(image: CGImage, confidenceThreshold: Double) throws -> [NativeCoreMLOCRLine] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  Double(candidate.confidence) >= confidenceThreshold,
                  needsSupplement(candidate.string) else { return nil }
            func pixel(_ point: CGPoint) -> CGPoint {
                CGPoint(x: point.x * CGFloat(image.width), y: (1 - point.y) * CGFloat(image.height))
            }
            return NativeCoreMLOCRLine(
                polygon: [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft].map(pixel),
                text: candidate.string, score: Double(candidate.confidence),
                orientation: .horizontal, orientationIsEstimated: false
            )
        }
    }

    /// One caller-owned supplemental request. Cancellation never publishes
    /// late results; the reader awaits it before advancing to another tile.
    static func recognizeOffActor(image: CGImage, confidenceThreshold: Double) async throws -> [NativeCoreMLOCRLine] {
        let task = Task.detached(priority: Task.currentPriority) {
            try recognize(image: image, confidenceThreshold: confidenceThreshold)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func needsSupplement(_ text: String) -> Bool {
        // Require multiple letters, avoiding a solitary ambiguous glyph in
        // artwork or an otherwise correctly recognized Latin/CJK line.
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let count = letters.filter { scalar in
            switch scalar.value {
            case 0x0400...0x052F, 0x0600...0x06FF, 0x0750...0x077F,
                 0x08A0...0x08FF, 0x0E00...0x0E7F, 0x1100...0x11FF,
                 0x3130...0x318F, 0xAC00...0xD7AF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                return true
            default: return false
            }
        }.count
        return count >= 2 && count * 2 >= letters.count
    }

    static func reconcile(
        native: [NativeCoreMLOCRLine], supplemental: [NativeCoreMLOCRLine]
    ) -> [NativeCoreMLOCRLine] {
        guard !supplemental.isEmpty else { return native }
        func bounds(_ line: NativeCoreMLOCRLine) -> CGRect {
            guard let first = line.polygon.first else { return .null }
            return line.polygon.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
        }
        let replacements = supplemental.map(bounds)
        return native.filter { line in
            let box = bounds(line)
            guard !box.isNull, box.width > 0, box.height > 0 else { return true }
            return !replacements.contains { replacement in
                let intersection = box.intersection(replacement)
                guard !intersection.isNull else { return false }
                let area = intersection.width * intersection.height
                return area / (box.width * box.height) >= 0.5
                    || (area / (replacement.width * replacement.height) >= 0.8
                        && box.height <= replacement.height * 2)
            }
        } + supplemental
    }
}
