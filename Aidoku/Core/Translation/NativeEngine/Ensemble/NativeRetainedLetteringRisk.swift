/// An additional veto for a moved candidate, never a text filter or an incumbent selector.
/// The caller supplies actual foreground-alpha runs in integral source-pixel coordinates.
/// Risk must be observed native (text | SFX) support at source bilinear threshold zero,
/// excluding the existing predicted original erasure mask. No mask construction occurs here.
enum NativeRetainedLetteringRisk {
    struct Span: Equatable {
        let y: Int
        let left: Int
        let right: Int // Half-open [left, right); empty and overlapping runs are invalid.
    }

    enum Reason: String {
        case admitted
        case increasedRisk
        case missingForeground
        case missingSampler
        case invalidDimensions
        case invalidTolerance
        case invalidBudget
        case runBudgetExceeded
        case invalidSpan
        case overlappingSpans
        case sampleBudgetExceeded
        case unknownRisk
    }

    struct Decision: Equatable {
        let available: Bool
        let admit: Bool
        // Both counts are nil on abstention; partial observations never become zero evidence.
        let before: Int?
        let after: Int?
        let reason: Reason
        let samples: Int
    }

    /// Budgets cover BOTH inputs together. Each foreground pixel costs one sample per
    /// candidate, including pixels shared between old and new. Calls are deterministic:
    /// old then new, ascending (y, x). Run validation/sorting is bounded by maximumRuns.
    /// Int geometry cannot represent nonfinite/fractional coordinates; callers converting
    /// floating geometry must reject it rather than truncate or clip it into these spans.
    /// A nil sampler or nil pixel means unknown, whereas observed false is legal empty risk.
    /// Only available && admit clears this extra gate; abstention retains the baseline.
    static func evaluate(
        old: [Span]?,
        new: [Span]?,
        pageWidth: Int,
        pageHeight: Int,
        maximumSamples: Int,
        maximumRuns: Int = 65_536,
        tolerance: Double = 0,
        sampler: ((Int, Int) -> Bool?)?
    ) -> Decision {
        func abstain(_ reason: Reason, samples: Int = 0) -> Decision {
            Decision(available: false, admit: false, before: nil, after: nil, reason: reason, samples: samples)
        }
        guard pageWidth > 0, pageHeight > 0 else { return abstain(.invalidDimensions) }
        guard tolerance.isFinite, tolerance >= 0 else { return abstain(.invalidTolerance) }
        guard maximumSamples >= 0, maximumRuns >= 0 else { return abstain(.invalidBudget) }
        guard let old, let new else { return abstain(.missingForeground) }
        guard let sampler else { return abstain(.missingSampler) }
        guard old.count <= maximumRuns, new.count <= maximumRuns - old.count else {
            return abstain(.runBudgetExceeded)
        }

        var requiredSamples = 0
        var ordered: [[Span]] = []
        for spans in [old, new] {
            for span in spans {
                guard span.y >= 0, span.y < pageHeight,
                      span.left >= 0, span.left < span.right, span.right <= pageWidth else {
                    return abstain(.invalidSpan)
                }
                let length = span.right - span.left
                // Subtraction avoids overflow even with Int.max source dimensions/budgets.
                guard length <= maximumSamples - requiredSamples else { return abstain(.sampleBudgetExceeded) }
                requiredSamples += length
            }
            let sorted = spans.sorted {
                $0.y == $1.y ? $0.left < $1.left : $0.y < $1.y
            }
            var previous: Span?
            for span in sorted {
                if let previous, previous.y == span.y, span.left < previous.right {
                    return abstain(.overlappingSpans)
                }
                previous = span
            }
            ordered.append(sorted)
        }

        var counts = [0, 0]
        var samples = 0
        for candidate in 0..<2 {
            for span in ordered[candidate] {
                for x in span.left..<span.right {
                    samples += 1
                    guard let protected = sampler(x, span.y) else { return abstain(.unknownRisk, samples: samples) }
                    if protected { counts[candidate] += 1 }
                }
            }
        }
        let admit = counts[1] <= counts[0] || Double(counts[1] - counts[0]) <= tolerance
        return Decision(
            available: true, admit: admit, before: counts[0], after: counts[1],
            reason: admit ? .admitted : .increasedRisk, samples: samples
        )
    }
}
