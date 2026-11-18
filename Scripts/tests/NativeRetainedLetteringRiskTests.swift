import Foundation

@main enum NativeRetainedLetteringRiskTests {
    typealias Risk = NativeRetainedLetteringRisk
    typealias Span = Risk.Span
    static var assertions = 0

    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        assertions += 1
    }

    static func main() {
        let old = [Span(y: 0, left: 0, right: 2)]
        let new = [Span(y: 1, left: 2, right: 4)]
        var calls: [[Int]] = []
        func evaluate(
            _ before: [Span]? = nil, _ after: [Span]? = nil,
            width: Int = 4, height: Int = 2, budget: Int = 4,
            runs: Int = 10, tolerance: Double = 0,
            sample: ((Int, Int) -> Bool?)? = { _, _ in false }
        ) -> Risk.Decision {
            Risk.evaluate(old: before, new: after, pageWidth: width, pageHeight: height,
                          maximumSamples: budget, maximumRuns: runs, tolerance: tolerance, sampler: sample)
        }
        func abstains(_ decision: Risk.Decision, _ reason: Risk.Reason) {
            check(!decision.available && !decision.admit && decision.before == nil && decision.after == nil,
                  "Abstention must retain baseline and withhold both counts")
            check(decision.reason == reason, "Explicit abstention reason: \(reason)")
        }

        let equal = evaluate(old, new, sample: { x, _ in x % 2 == 0 })
        check(equal.available && equal.admit && equal.before == 1 && equal.after == 1, "Equal count permits move")
        let increased = evaluate(old, new, sample: { _, y in y == 1 })
        check(increased.available && !increased.admit && increased.before == 0 && increased.after == 2
              && increased.reason == .increasedRisk, "Increased count vetoes move")
        let decreased = evaluate(new, old, sample: { _, y in y == 1 })
        check(decreased.available && decreased.admit && decreased.before == 2 && decreased.after == 0, "Decrease permitted")
        check(evaluate(old, new, tolerance: 2, sample: { _, y in y == 1 }).admit, "Explicit tolerance boundary")
        check(!evaluate(old, new, tolerance: 1.99, sample: { _, y in y == 1 }).admit, "Tolerance below delta blocks")
        let emptyRisk = evaluate(old, new, sample: { x, y in
            calls.append([x, y])
            return false
        })
        check(emptyRisk.available && emptyRisk.admit && emptyRisk.before == 0 && emptyRisk.after == 0,
              "Observed empty source risk is legal")
        check(calls == [[0, 0], [1, 0], [2, 1], [3, 1]] && emptyRisk.samples == 4, "Exact deterministic calls")
        abstains(evaluate(nil, new), .missingForeground)
        abstains(evaluate(old, nil), .missingForeground)
        abstains(evaluate(old, new, sample: nil), .missingSampler)
        abstains(evaluate([], [], sample: nil), .missingSampler)
        let unknown = evaluate(old, new, sample: { x, y in y == 1 && x == 3 ? nil : false })
        abstains(unknown, .unknownRisk)
        check(unknown.samples == 4, "Late unknown cannot publish partial counts")
        let immediateUnknown = evaluate(old, new, sample: { _, _ in nil })
        abstains(immediateUnknown, .unknownRisk)
        check(immediateUnknown.samples == 1, "Unknown stops immediately")

        // All invalid geometry and excessive work must be rejected before any sampler call.
        var unexpectedReads = 0
        let tracked: (Int, Int) -> Bool? = { _, _ in unexpectedReads += 1; return false }
        abstains(evaluate(old, new, budget: 3, sample: tracked), .sampleBudgetExceeded)
        abstains(evaluate(old, new, runs: 1, sample: tracked), .runBudgetExceeded)
        abstains(evaluate(old, new, width: 0, sample: tracked), .invalidDimensions)
        abstains(evaluate(old, new, height: -1, sample: tracked), .invalidDimensions)
        abstains(evaluate(old, new, budget: -1, sample: tracked), .invalidBudget)
        abstains(evaluate(old, new, runs: -1, sample: tracked), .invalidBudget)
        for tolerance in [Double.nan, .infinity, -.infinity, -1] {
            abstains(evaluate(old, new, tolerance: tolerance, sample: tracked), .invalidTolerance)
        }
        for invalid in [Span(y: -1, left: 0, right: 1), Span(y: 2, left: 0, right: 1),
                        Span(y: 0, left: -1, right: 1), Span(y: 0, left: 2, right: 2),
                        Span(y: 0, left: 3, right: 2), Span(y: 0, left: 3, right: 5),
                        Span(y: Int.max, left: Int.min, right: Int.max)] {
            abstains(evaluate(old, [invalid], sample: tracked), .invalidSpan)
        }
        let overlap = [Span(y: 0, left: 1, right: 3), Span(y: 0, left: 0, right: 2)]
        abstains(evaluate(overlap, [], sample: tracked), .overlappingSpans)
        abstains(evaluate([], overlap, sample: tracked), .overlappingSpans)
        abstains(evaluate(old + old, [], sample: tracked), .overlappingSpans)
        abstains(evaluate([Span(y: 0, left: 0, right: Int.max)], old,
                          width: Int.max, budget: Int.max, sample: tracked), .sampleBudgetExceeded)
        check(unexpectedReads == 0, "Preflight failures must perform zero sampler reads")

        let adjacent = [Span(y: 0, left: 2, right: 4), Span(y: 0, left: 0, right: 2)]
        calls = []
        let joined = evaluate(adjacent, [], sample: { x, y in calls.append([x, y]); return true })
        check(joined.before == 4 && joined.after == 0 && joined.admit, "Adjacent runs count each pixel once")
        check(calls == [[0, 0], [1, 0], [2, 0], [3, 0]], "Unsorted runs canonicalized deterministically")
        let same = evaluate(old, old, sample: { _, _ in true })
        check(same.before == 2 && same.after == 2 && same.samples == 4 && same.admit,
              "Cross-candidate overlap is counted separately")
        let emptyForeground = evaluate([], [], budget: 0, runs: 0, sample: tracked)
        check(emptyForeground.available && emptyForeground.admit && emptyForeground.samples == 0,
              "Explicit empty foreground needs no sampling")
        check(unexpectedReads == 0, "Empty foreground performs zero reads")
        let extreme = evaluate([Span(y: Int.max - 1, left: Int.max - 1, right: Int.max)], [],
                               width: Int.max, height: Int.max, budget: 1, sample: { x, y in
            check(x == Int.max - 1 && y == Int.max - 1, "Extreme integral geometry remains in domain")
            return true
        })
        check(extreme.before == 1 && extreme.admit, "No source area multiplication overflow")

        // Exhaustive independent pixel-set oracle: all 256 observed risk maps on 4x2.
        for mask in 0..<256 {
            let result = evaluate(old, new, sample: { x, y in mask & (1 << (y * 4 + x)) != 0 })
            let before = [0, 1].filter { mask & (1 << $0) != 0 }.count
            let after = [6, 7].filter { mask & (1 << $0) != 0 }.count
            check(result.available && result.before == before && result.after == after
                  && result.admit == (after <= before) && result.samples == 4, "Exhaustive count oracle \(mask)")
        }
        print("PASS: \(assertions) assertions; 256 exhaustive risk maps; no source/image/model/file reads")
    }
}
