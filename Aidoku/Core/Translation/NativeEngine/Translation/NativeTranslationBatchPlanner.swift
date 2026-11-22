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
        targetLanguage: String
    ) -> [NativeTranslationBatchPlan] {
        let admissible = RemoteTranslationRequest.admissibleSegmentIndices(in: candidates.map(\.segment))
            .map { candidates[$0] }
        var batches: [NativeTranslationBatchPlan] = []
        var cursor = 0

        while cursor < admissible.count {
            var selection: [NativeTranslationBatchCandidate] = []
            var sourceBytes = 0
            while cursor < admissible.count, selection.count < RemoteTranslationRequest.maximumSegments {
                let candidate = admissible[cursor]
                let nextBytes = sourceBytes + candidate.segment.text.utf8.count
                if nextBytes > RemoteTranslationRequest.maximumSourceBytes { break }
                selection.append(candidate)
                sourceBytes = nextBytes
                cursor += 1
            }
            guard !selection.isEmpty else {
                cursor += 1 // Progress guarantee if the hard limits ever change.
                continue
            }

            batches.append(NativeTranslationBatchPlan(
                request: RemoteTranslationRequest(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                                                  segments: selection.map(\.segment)),
                inputIndicesBySegmentID: Dictionary(uniqueKeysWithValues: selection.map { ($0.segment.id, $0.inputIndex) })
            ))
        }
        return batches
    }
}
