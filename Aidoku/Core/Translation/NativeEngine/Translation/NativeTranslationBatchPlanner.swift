// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

struct NativeTranslationBatchCandidate: Hashable, Sendable {
    let inputIndex: Int
    let segment: RemoteTranslationSegment
}

struct NativeTranslationBatchPlan: Hashable, Sendable {
    let request: RemoteTranslationRequest
    let inputIndicesBySegmentID: [String: Int]
}

/// Creates stable, reading-order translation chunks for the containing browser
/// translation service. A small leading request lowers time-to-first-overlay;
/// content-defined tail batches amortize provider latency without depending on
/// tracker IDs that can reset between otherwise identical frames.
enum NativeTranslationBatchPlanner {
    static let leadingMinimumSegments = 2
    static let leadingMaximumSegments = 4
    static let tailMinimumStableSegments = 32
    static let tailMaximumSegments = RemoteTranslationRequest.maximumSegments
    private static let leadingBoundaryMask: UInt64 = 0b11
    private static let tailBoundaryMask: UInt64 = 0b1111

    static func makeBatches(
        candidates: [NativeTranslationBatchCandidate],
        sourceLanguage: String,
        targetLanguage: String,
        context: [String],
        glossary: [TranslationGlossaryEntry]
    ) -> [NativeTranslationBatchPlan] {
        let admissible = RemoteTranslationRequest
            .admissibleSegmentIndices(
                in: candidates.map(\.segment)
            )
            .map { candidates[$0] }
        var batches: [NativeTranslationBatchPlan] = []
        var cursor = 0
        var isLeadingBatch = true

        while cursor < admissible.count {
            var selection: [NativeTranslationBatchCandidate] = []
            var sourceBytes = 0
            let minimumSegments = isLeadingBatch
                ? leadingMinimumSegments
                : tailMinimumStableSegments
            let maximumSegments = isLeadingBatch
                ? leadingMaximumSegments
                : tailMaximumSegments
            let boundaryMask = isLeadingBatch
                ? leadingBoundaryMask
                : tailBoundaryMask
            while cursor < admissible.count,
                  selection.count < maximumSegments
            {
                let candidate = admissible[cursor]
                let nextBytes =
                    sourceBytes + candidate.segment.text.utf8.count
                if nextBytes > RemoteTranslationRequest.maximumSourceBytes {
                    break
                }
                selection.append(candidate)
                sourceBytes = nextBytes
                cursor += 1
                if selection.count >= minimumSegments,
                   isStableBoundaryAnchor(
                       sourceText: candidate.segment.text,
                       mask: boundaryMask
                   )
                {
                    break
                }
            }
            guard !selection.isEmpty else {
                // `admissibleSegmentIndices` already rejects an individually
                // unsafe segment. Keep this defensive progress guarantee so a
                // future hard-limit change cannot trap the planner in a loop.
                cursor += 1
                continue
            }

            batches.append(NativeTranslationBatchPlan(
                request: RemoteTranslationRequest(
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    segments: selection.map(\.segment),
                    context: context,
                    glossary: glossary
                ),
                inputIndicesBySegmentID: Dictionary(
                    uniqueKeysWithValues: selection.map {
                        ($0.segment.id, $0.inputIndex)
                    }
                )
            ))
            isLeadingBatch = false
        }
        return batches
    }

    /// Deliberately hashes source content rather than tracker identity. Identical
    /// OCR in a newly numbered frame therefore retains the same batch shape.
    private static func isStableBoundaryAnchor(
        sourceText: String,
        mask: UInt64
    ) -> Bool {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in sourceText.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash & mask == 0
    }
}
