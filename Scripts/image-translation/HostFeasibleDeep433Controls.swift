import Foundation
import CoreGraphics

@available(macOS 15.0, *)
extension HostSourceRepairControls {
    static func runFeasible433() throws -> [String: Any] {
        typealias P = SourceFeasibleDeep433
        struct Failure: Error { let name: String }
        var checks: [String] = []
        func check(_ ok: Bool, _ name: String) throws {
            guard ok else { throw Failure(name: name) }; checks.append(name)
        }
        func nominee(_ key: String, _ score: Double, _ ordinal: Int, _ x: CGFloat,
                     passed: Bool = true, hardEmpty: Bool = true) -> P.Nominee {
            .init(key: key, polygon: [.init(x: x, y: 0), .init(x: x+4, y: 0),
                .init(x: x+4, y: 8), .init(x: x, y: 8)], score: score, ordinal: ordinal,
                actualNativePassed: passed, sourceHardEmpty: hardEmpty)
        }
        let input = [nominee("lower", 0.85, 3, 30), nominee("best-veto", 0.99, 0, 0),
            nominee("next-safe", 0.93, 1, 10), nominee("native-failed", 1, 4, 40, passed: false)]
        var order: [String] = []
        let next = P.choose(input, actualMargin: 0.8, rootBindingVerified: true,
            rootBindingReceipt: ["orderingControlOnly": true]) { n in
            order.append(n.key)
            return .init(verdict: n.key == "best-veto" ? .positiveExtraLoss : .noPositiveExtraLoss,
                receipt: ["controlVerdictOnly": true])
        }
        try check(order == ["best-veto", "next-safe"] && next.selected?.key == "next-safe",
            "score-descending-native-only-next-safe-after-positive")
        var called = false
        let missing = P.choose(input, actualMargin: 0.8, rootBindingVerified: false,
            rootBindingReceipt: [:]) { _ in called = true; return .init(verdict: .noPositiveExtraLoss, receipt: [:]) }
        try check(missing.selected == nil && !called, "missing-binding-fallback-with-zero-queries")
        let allVeto = P.choose(input, actualMargin: 0.8, rootBindingVerified: true,
            rootBindingReceipt: [:]) { _ in .init(verdict: .positiveExtraLoss, receipt: [:]) }
        try check(allVeto.selected == nil, "all-positive-fallback")
        let bounded = P.choose(input, actualMargin: 0.8, rootBindingVerified: true,
            rootBindingReceipt: [:], maximumCandidates: 1) { n in
            .init(verdict: n.key == "best-veto" ? .positiveExtraLoss : .noPositiveExtraLoss, receipt: [:]) }
        try check(bounded.selected == nil, "top-budget-fallback-no-untested-candidate")
        let absentModel = P.choose(input, actualMargin: nil, rootBindingVerified: true,
            rootBindingReceipt: [:]) { _ in .init(verdict: .noPositiveExtraLoss, receipt: [:]) }
        try check(absentModel.selected == nil, "missing-model-fallback")
        let unavailable = P.choose(input, actualMargin: 0.8, rootBindingVerified: true,
            rootBindingReceipt: [:]) { _ in .init(verdict: .unavailable, receipt: [:]) }
        try check(unavailable.selected == nil, "source-unavailable-fallback")
        var duplicates = input
        duplicates.insert(nominee("duplicate-best", 0.98, 0, 0), at: 1)
        var tested = [String]()
        _ = P.choose(duplicates, actualMargin: 0.8, rootBindingVerified: true,
            rootBindingReceipt: [:]) { n in tested.append(n.key); return .init(verdict: .positiveExtraLoss, receipt: [:]) }
        try check(tested == ["best-veto", "next-safe", "lower"], "geometry-dedup-before-budget")
        let tie = P.choose([nominee("late", 0.9, 9, 10), nominee("early", 0.9, 2, 0)],
            actualMargin: 0.8, rootBindingVerified: true, rootBindingReceipt: [:]) { _ in
            .init(verdict: .noPositiveExtraLoss, receipt: [:]) }
        try check(tie.selected?.key == "early", "stable-ordinal-score-tie")
        var config = NativeOCRSourceLocalJoint369Capture.ExportConfiguration()
        try check(!config.requestsSourceCost433FeasibleSelect, "433-default-off")
        config.enabled = true; config.families = ["source-cost433-feasible-deep-select"]
        try check(config.requestsSourceCost430DeepSelect && config.requestsPositiveLoss424 &&
            config.requestsPositiveLoss426 && config.requestsNativeAdmission425 &&
            !config.requestsSourceCost427MixedSelect, "433-direct430-424-426-425-not-mixed427")
        config.families = ["source-cost430-deep-select"]
        try check(!config.requestsSourceCost433FeasibleSelect, "430-retains-old-control-path")
        return ["status": "pass", "checks": checks, "orderingPolicyControlsOnly": true,
            "nativeAdmissionOrPhysicalPassNotSimulated": true, "detectorCalls": 0, "recognizerCalls": 0]
    }
}
