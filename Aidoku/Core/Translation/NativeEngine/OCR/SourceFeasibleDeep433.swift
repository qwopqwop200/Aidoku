import Foundation
import CoreGraphics

/// Ordering policy only. The bank supplies actual native-passed candidates and
/// binds the source once; callback records real424/426 observations, never allows ink.
enum SourceFeasibleDeep433 {
    struct Nominee {
        let key: String
        let polygon: [CGPoint]
        let score: Double
        let ordinal: Int
        let actualNativePassed: Bool
        let sourceHardEmpty: Bool
    }
    enum Verdict: String { case noPositiveExtraLoss, positiveExtraLoss, unavailable }
    struct Evaluation { let verdict: Verdict; let receipt: [String: Any] }
    struct Output { let selected: Nominee?; let receipt: [String: Any] }
    private static func geometryKey(_ q: [CGPoint]) -> String {
        let pairs = q.map { p in
            String((Double(p.x) == 0 ? 0.0 : Double(p.x)).bitPattern) + ":" +
                String((Double(p.y) == 0 ? 0.0 : Double(p.y)).bitPattern)
        }
        var variants: [String] = []
        for reverse in [false, true] {
            let a = reverse ? Array(pairs.reversed()) : pairs
            for k in 0..<4 { variants.append((0..<4).map { a[($0+k)%4] }.joined(separator: ";")) }
        }
        return variants.min()!
    }
    static func choose(_ nominees: [Nominee], actualMargin: Double?, rootBindingVerified: Bool,
        rootBindingReceipt: [String: Any], maximumCandidates: Int = 16,
        evaluate: (Nominee) -> Evaluation) -> Output {
        var receipt: [String: Any] = ["family": "source-cost433-feasible-deep-select",
            "rootBinding": rootBindingReceipt, "maximumCandidates": maximumCandidates,
            "unknownMeansBackground": false, "ownershipChanged": false,
            "nativeFailedCandidateMayBeSelected": false, "repairApplied": false,
            "rootFrameValidationOnce": true]
        guard rootBindingVerified, let margin = actualMargin, margin.isFinite,
              maximumCandidates >= 1, maximumCandidates <= 16 else {
            receipt["status"] = "fallback-binding-or-model-unavailable"
            receipt["testedCandidates"] = [[String: Any]]()
            return .init(selected: nil, receipt: receipt)
        }
        let ordered = nominees.enumerated().filter { _, n in
            n.actualNativePassed && n.sourceHardEmpty && !n.key.isEmpty &&
                n.score.isFinite && n.score > margin && n.score > 0 && n.polygon.count == 4 &&
                n.polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }.sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            if a.element.ordinal != b.element.ordinal { return a.element.ordinal < b.element.ordinal }
            return a.offset < b.offset
        }
        var seen = Set<String>(), unique: [Nominee] = []
        for row in ordered where seen.insert(geometryKey(row.element.polygon)).inserted { unique.append(row.element) }
        var tested: [[String: Any]] = []
        receipt["actualMargin"] = margin
        receipt["eligibleNativePassedOffers"] = ordered.count
        receipt["uniqueNativePassedGeometries"] = unique.count
        receipt["candidateBudgetTruncated"] = unique.count > maximumCandidates
        for candidate in unique.prefix(maximumCandidates) {
            let result = evaluate(candidate)
            tested.append(["key": candidate.key, "polygon": candidate.polygon.map { [Double($0.x), Double($0.y)] },
                "score": candidate.score, "rawOrdinal": candidate.ordinal,
                "actualNativePassed": true, "verdict": result.verdict.rawValue,
                "sourceFeasibility": result.receipt])
            if result.verdict == .unavailable {
                receipt["status"] = "fallback-source-evaluation-unavailable"
                receipt["testedCandidates"] = tested
                return .init(selected: nil, receipt: receipt)
            }
            if result.verdict == .noPositiveExtraLoss {
                receipt["status"] = "selected-first-native-passed-without-positive-extra-loss"
                receipt["testedCandidates"] = tested
                receipt["selectedKey"] = candidate.key
                receipt["selectedPolygon"] = candidate.polygon.map { [Double($0.x), Double($0.y)] }
                receipt["selectedScore"] = candidate.score
                receipt["postguardAlreadyRunForExactSelectedKeyAndQuad"] = true
                return .init(selected: candidate, receipt: receipt)
            }
        }
        receipt["status"] = unique.isEmpty ? "fallback-no-native-passed-model-nominee" : "fallback-tested-top-budget-all-positive"
        receipt["testedCandidates"] = tested
        return .init(selected: nil, receipt: receipt)
    }
}
