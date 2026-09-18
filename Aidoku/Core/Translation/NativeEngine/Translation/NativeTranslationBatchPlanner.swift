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

/// Keeps a page in one reading-order request to minimize full-page completion
/// time. Only the request's segment and source-byte limits split a large page.
enum NativeTranslationBatchPlanner {
    static func makeBatches(
        candidates: [NativeTranslationBatchCandidate],
        sourceLanguage: String,
        targetLanguage: String,
        context: [String],
        glossary: [TranslationGlossaryEntry],
        includesNeighborContext: Bool = false
    ) -> [NativeTranslationBatchPlan] {
        let admissible = RemoteTranslationRequest
            .admissibleSegmentIndices(
                in: candidates.map(\.segment)
            )
            .map { candidates[$0] }
        var batches: [NativeTranslationBatchPlan] = []
        var cursor = 0

        while cursor < admissible.count {
            let selectionStart = cursor
            var selection: [NativeTranslationBatchCandidate] = []
            var sourceBytes = 0
            while cursor < admissible.count,
                  selection.count < RemoteTranslationRequest.maximumSegments
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
                    context: includesNeighborContext && context.isEmpty
                        ? neighborContext(in: admissible, range: selectionStart..<cursor) : context,
                    glossary: glossary
                ),
                inputIndicesBySegmentID: Dictionary(
                    uniqueKeysWithValues: selection.map {
                        ($0.segment.id, $0.inputIndex)
                    }
                )
            ))
        }
        return batches
    }

    /// At most two nearby OCR utterances, already available before dispatch.
    /// Keep complete strings (no truncated names/words), and never wait for
    /// another translation batch. Only admissible, language-filtered inputs
    /// reach the reader planner. No page-wide context or extra provider call.
    static func neighborContext(
        in candidates: [NativeTranslationBatchCandidate], range: Range<Int>
    ) -> [String] {
        var result: [String] = []
        for (index, label) in [(range.lowerBound - 1, "Previous"), (range.upperBound, "Next")] {
            guard candidates.indices.contains(index) else { continue }
            let text = candidates[index].segment.text
            guard text.utf8.count <= 240 else { continue }
            result.append("\(label) OCR utterance (context only): \(text)")
        }
        return result
    }
}
