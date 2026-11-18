import Foundation

/// Source-support groups elect boundaries jointly across all producers. The
/// uncertainty model consumes confidence and relative evidence agreement only.
/// Targets, source IDs, RGB, absolute dimensions and aspect ratios are absent.
@available(iOS 18.0, *)
enum NativeOCRSharedLineElection {
    typealias P = NativeOCRPhysicalPaintSupport
    typealias R = NativeOCRGeometryRepresentativeSelection
    static let environmentKey = "AIDOKU_OCR_SHARED_LINE_POLICY"

    struct Policy: Decodable, Sendable {
        let schema: String
        let riskThreshold: Double
        let models: [R.Model]
        var preserveMeasuredBoundaryWitnesses: Bool? = nil

        func validate() throws {
            guard schema == "shared-line-evidence-uncertainty-v1", riskThreshold.isFinite,
                  (0...1).contains(riskThreshold), models.count == 5 else { throw Failure.invalidPolicy }
            for model in models {
                try model.validate()
                guard model.featureNames == featureNames else { throw Failure.invalidPolicy }
            }
        }
    }
    struct Observation {
        let polygon: [P.Point]
        let confidence: Double
    }
    struct Report: Codable, Equatable, Sendable {
        let inputCount: Int
        let keptIndices: [Int]
        let groupCount: Int
        let groupLeaders: [Int]
        let retainedUncertainGroups: [Int]
        let groupRisks: [Double]
        let riskThreshold: Double
        let restoredObservationIndices: [Int]
        let missingEvidenceKeptIndices: [Int]
        var boundaryWitnessIndices: [Int] = []
    }
    struct Result { let keptIndices: [Int]; let report: Report }
    enum Failure: Error { case invalidPolicy, invalidAlignment }

    private static let channels = [7, 0, 5, 6, 1, 8, 9]
    static var featureNames: [String] {
        let names = NativeOCRLineAgreementFeatures.names
        var result = [String]()
        for aggregate in ["leader", "mean", "std", "min", "max"] {
            result += names.map { "\(aggregate)/\($0)" }
        }
        for a in channels { for b in channels where a < b {
            result.append("winnerIoU/\(names[a])/\(names[b])")
        } }
        result += channels.map { "leaderGap/\(names[$0])" }
        result += channels.map { "winnerSupport80/\(names[$0])" }
        result += ["count", "minimumLeaderIoU", "meanLeaderIoU"]
        return result
    }
    /// Stabilizes ties between native and vectorized floating-point reductions.
    /// This does not quantize output polygons, confidence metadata or GT metrics.
    private static func stable(_ value: Double) -> Double {
        (value * 1e9).rounded(.toNearestOrEven) / 1e9
    }

    static func select(bank: P.Bank, features: [[Double]], available: [Bool],
                       detectors: [Observation], recognition: [Observation], policy: Policy,
                       cancellationCheck: () throws -> Void = {}) throws -> Result {
        try policy.validate()
        let rows = bank.input.candidates
        let n = rows.count
        guard features.count == n, available.count == n,
              features.allSatisfy({ $0.count == NativeOCRLineAgreementFeatures.names.count }) else {
            throw Failure.invalidAlignment
        }
        let x = features.map { $0.map(stable) }
        let valid = rows.indices.map { available[$0] && x[$0].allSatisfy(\.isFinite) && bank.support[$0] != nil }
        let ranks = x.map { $0[7] + $0[8] }
        let order = rows.indices.sorted { ranks[$0] == ranks[$1] ? $0 < $1 : ranks[$0] > ranks[$1] }
        var pair = Array(repeating: [Double](repeating: 0, count: n), count: n)
        for i in rows.indices {
            try cancellationCheck()
            pair[i][i] = 1
            if i + 1 < n { for j in (i + 1)..<n {
                let value = stable(P.iou(rows[i].polygon, rows[j].polygon))
                pair[i][j] = value
                pair[j][i] = value
            } }
        }
        var owner = Array(repeating: -1, count: n)
        var groups = [[Int]]()
        var leaders = [Int]()
        for i in order where owner[i] < 0 {
            try cancellationCheck()
            var members = [Int]()
            for j in rows.indices where owner[j] < 0 {
                var compatible = j == i
                if !compatible, valid[i], valid[j], pair[i][j] >= 0.5,
                   let a = bank.support[i], let b = bank.support[j], a.rfScope == b.rfScope {
                    let common = a.cells.intersection(b.cells).count
                    compatible = Double(common) >= Double(a.cells.count) * 0.5
                        && Double(common) >= Double(b.cells.count) * 0.5
                }
                if compatible { owner[j] = groups.count; members.append(j) }
            }
            leaders.append(i)
            groups.append(members)
        }
        var kept = Set(leaders)
        var restored = [Int]()
        // Preserve every strongest actual detector/OCR observation, not copied
        // recognition attributed to a newly proposed boundary.
        for (observations, minimum) in [(recognition, 0.45), (detectors, 0.085)] {
            for observation in observations where observation.confidence >= minimum
                && observation.confidence.isFinite && P.valid(observation.polygon) {
                try cancellationCheck()
                let agreement = rows.map { stable(P.iou($0.polygon, observation.polygon)) }
                guard let best = agreement.max(), best > (kept.map { agreement[$0] }.max() ?? 0) else { continue }
                let candidates = rows.indices.filter { agreement[$0] >= best }
                if let index = candidates.min(by: { ranks[$0] == ranks[$1] ? $0 < $1 : ranks[$0] > ranks[$1] }) {
                    kept.insert(index)
                    restored.append(index)
                }
            }
        }
        var risks = [Double]()
        var uncertain = [Int]()
        var boundaryWitnesses = [Int]()
        if policy.preserveMeasuredBoundaryWitnesses == true {
            for members in groups {
                for kind in 0..<2 {
                    let candidates = members.filter { kind == 0 ? rows[$0].halo : rows[$0].completeInk }
                    let largest = candidates.compactMap { bank.support[$0]?.cells.count }.max()
                    guard let largest else { continue }
                    let choices = candidates.filter { bank.support[$0]?.cells.count == largest }
                    if let index = choices.min(by: { ranks[$0] == ranks[$1] ? $0 < $1 : ranks[$0] > ranks[$1] }) {
                        kept.insert(index)
                        boundaryWitnesses.append(index)
                    }
                }
            }
        }
        for (groupIndex, members) in groups.enumerated() {
            try cancellationCheck()
            guard members.allSatisfy({ valid[$0] }) else {
                kept.formUnion(members)
                risks.append(1)
                uncertain.append(groupIndex)
                continue
            }
            let leader = leaders[groupIndex]
            let count = Double(members.count)
            let columns = NativeOCRLineAgreementFeatures.names.indices
            let means = columns.map { c in members.reduce(0.0) { $0 + x[$1][c] } / count }
            let deviation = columns.map { c in
                sqrt(members.reduce(0.0) { let d = x[$1][c] - means[c]; return $0 + d * d } / count)
            }
            let minima = columns.map { c in members.map { x[$0][c] }.min()! }
            let maxima = columns.map { c in members.map { x[$0][c] }.max()! }
            var values = x[leader] + means + deviation + minima + maxima
            var winners = [Int: Int]()
            for c in channels {
                // members are in input order; equal observations have a stable winner.
                winners[c] = members.min { x[$0][c] == x[$1][c] ? $0 < $1 : x[$0][c] > x[$1][c] }
            }
            for a in channels { for b in channels where a < b {
                values.append(pair[winners[a]!][winners[b]!])
            } }
            values += channels.map { x[winners[$0]!][$0] - x[leader][$0] }
            values += channels.map { c in Double(members.filter { pair[winners[c]!][$0] >= 0.8 }.count) / count }
            values += [count, members.map { pair[leader][$0] }.min()!, members.reduce(0.0) { $0 + pair[leader][$1] } / count]
            let risk = policy.models.map { $0.predict(values) }.max()!
            guard risk.isFinite else { throw Failure.invalidPolicy }
            risks.append(risk)
            if risk >= policy.riskThreshold {
                kept.formUnion(members)
                uncertain.append(groupIndex)
            }
        }
        let selected = kept.sorted()
        return .init(keptIndices: selected, report: .init(inputCount: n, keptIndices: selected,
            groupCount: groups.count, groupLeaders: leaders, retainedUncertainGroups: uncertain,
            groupRisks: risks, riskThreshold: policy.riskThreshold, restoredObservationIndices: restored,
            missingEvidenceKeptIndices: rows.indices.filter { !valid[$0] }, boundaryWitnessIndices: boundaryWitnesses))
    }
}
