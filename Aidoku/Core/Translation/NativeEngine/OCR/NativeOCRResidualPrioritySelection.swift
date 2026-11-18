import CoreGraphics
import Foundation

/// A source-feature preference with the complete existing selector as fallback.
@available(iOS 18.0, *)
enum NativeOCRResidualPrioritySelection {
    // Passive normal-only family. v361 remains the full fallback until a source-only
    // policy has passed native all-page, pixel and exact-pair physical validation.
    static func sourceNormalMayGenerate(_ source22: [Double]) -> Bool {
        NativeOCRSourceNormalPolicy364.sourceNormalMayGenerate(source22)
    }
    static func sourceNormalAllowsGeometry(_ candidate: NativeOCRResidualCandidate,
        source22: [Double], prior: [CGPoint]) -> Bool {
        if let index = NativeOCRSourceNormalPolicy364.keys.firstIndex(of: candidate.key),
           let geometry = NativeOCRSourceNormalPolicy364.geometry(proposed: candidate.polygon,
               supportPoints: candidate.supportPoints, prior: prior),
           NativeOCRSourceNormalPolicy364.matches(rule: index, source22: source22, geometry: geometry) {
            return true
        }
        guard candidate.key == NativeOCRSourceNormalRouting367.key,
              let geometry = NativeOCRSourceNormalRouting367.geometry(prior: prior,
                  proposed: candidate.polygon, support: candidate.supportPoints) else { return false }
        return NativeOCRSourceNormalRouting367.matches(source22: source22,
            proposalPriorIoU: geometry.0, mandatoryAlongRatio: geometry.1)
    }
    static func sourceNormalPreferredKey(_ candidates: [NativeOCRResidualCandidate],
        source22: [Double], prior: [CGPoint]) -> String? {
        NativeOCRSourceNormalPolicy364.sourceNormalPreferredKey(
            candidates.map { .init(key: $0.key, polygon: $0.polygon, supportPoints: $0.supportPoints) },
            source22: source22, prior: prior)
    }
    // Passive hook: a source-only policy is installed only after frozen-menu scoring
    // and physical review. The immutable old351 geometry selector stays separate.
    static func sourceBodyMayGenerate(_ source22: [Double]) -> Bool {
        source22.count >= 22 && source22[0].isFinite && source22[1].isFinite &&
            source22[1] > 21.021733583846014 && source22[0] <= 0.8871504233061767
    }
    static func sourceBodyPreferredKey(_ candidates: [NativeOCRResidualCandidate],
        source22: [Double], prior: [CGPoint]) -> String? {
        guard sourceBodyMayGenerate(source22),
              let candidate = candidates.first(where: { $0.key == NativeOCRSourceBody357PolicyProposal.key }),
              NativeOCRSourceBody357PolicyProposal.matches(source22: source22,
                proposed: candidate.polygon, prior: prior) else { return nil }
        return candidate.key
    }
    static let reachableLateKeys: Set<String> = [
    "source-normal-private-v1-current-pad025",
    "source-normal-private-v1-current-pad050",
    "source-normal-private-v1-current-pad075",
    "source-normal-private-v1-current-pad300",

    "source-body-cc-v3-incoming-pad0",
    "prior-envelope-v2-n15-a10",
    "prior-envelope-v2-n15-a20",
    "prior-envelope-v2-n20-a10",
    "prior-envelope-v2-n25-a20",
    "prior-envelope-v1-n15-a10",
    "prior-envelope-v1-n15-a15",
    "prior-envelope-v1-n20-a10",
    "angle-envelope-v1-0-r0-n10-a10",
    "angle-envelope-v1-m05-r1-n0-a0",
    "angle-envelope-v1-m1-r0-n0-a0",
    "angle-envelope-v1-m1-r1-n0-a0",
    "angle-envelope-v1-m2-r0-n0-a0",
    "angle-envelope-v1-p05-r0-n0-a05",
    "angle-envelope-v1-p1-r1-n0-a0",
    "angle-envelope-v1-p4-r0-n10-a10",
    "angle-envelope-v1-p4-r1-n25-a25",
    "angle-padding-v1-0-r0-head20",
    "angle-padding-v1-0-r0-right20",
    "angle-padding-v1-0-r0-tail20",
    "angle-padding-v1-0-r1-tail20",
    "angle-padding-v1-m05-r0-head20",
    "angle-padding-v1-m05-r1-head20",
    "angle-padding-v1-m05-r1-right20",
    "angle-padding-v1-p1-r1-left20",
    "asymmetric-support-v1-p00",
    "asymmetric-support-v1-p01",
    "asymmetric-support-v1-p03",
    "asymmetric-support-v1-p05",
    "asymmetric-support-v1-p14",
    "asymmetric-support-v1-p33",
    "asymmetric-support-v1-p36",
    "asymmetric-support-v1-p57",
    "asymmetric-support-v1-p58",
    "asymmetric-support-v1-p59",
    "asymmetric-support-v1-p60",
    "asymmetric-support-v1-p61",
    "asymmetric-support-v1-p66",
    "evidence-forward-v1-side-envelope-v1-left-grid",
    "evidence-forward-v1-side-envelope-v1-normal-head-grid",
    "evidence-forward-v1-side-envelope-v1-normal-head-ink-quarter",
    "evidence-forward-v1-side-envelope-v1-tail-grid",
    "evidence-forward-v1-support-minrect-v1-bounded-mar-retain-span-p0",
    "evidence-forward-v1-support-minrect-v1-bounded-mar-retain-span-p1",
    "peer-chain-v1-p2-head-rf050-sfx060-balloon090-gap1p6-offset0p22",
    "peer-chain-v1-p2-tail-rf050-sfx060-balloon090-gap1p6-offset0p22",
    "peer-chain-v1-p3-both-rf050-sfx060-balloon090-gap1p6-offset0p22",
    "peer-chain-v1-p3-head-rf050-sfx060-balloon090-gap1p6-offset0p22",
    "peer-chain-v1-p3-tail-rf050-sfx060-balloon090-gap1p6-offset0p22",
    "peer-chain-v1-p4-both-rf050-sfx060-balloon090-gap1p6-offset0p22",
    "peer-chain-v1-p4-head-rf050-sfx060-balloon090-gap1p6-offset0p22",
    "peer-chain-v1-p4-tail-rf050-sfx060-balloon090-gap1p6-offset0p22",
    "support-margin-v1-n0-a0",
    "support-margin-v1-n0-a15",
    "support-margin-v1-n10-a10",
    "support-margin-v1-n10-a15",
    "support-margin-v1-n5-a0",
    "support-margin-v1-n5-a10",
    "rf-text-along-v1-r0-p0",
    "rf-text-along-v1-r0-p05",
    "private-pca-normal1-retain-prior-along-turning-component-veto-v1",
    "private-pca-normal-footprint-v1-pad000-retain-current-along"
]
    // Must equal ALL static late-key references, including inherited Bank rules/nodes.

    static let key = "support-minrect-v1-incoming-axis-control-retain-span-p0|enclose75"

    static func preferred(_ candidates: [NativeOCRResidualCandidate], features: [Double], incoming: [CGPoint])
        -> NativeOCRResidualCandidate? {
        // Shared child preference; a miss inherits the complete previous preference.
        if features.count == 22, features.allSatisfy({ $0.isFinite }), incoming.count == 4,
           features[4] <= 0.43705817577646694, features[5] <= 34,
           let candidate = candidates.first(where: { $0.key == "support-blend-v1-normal-complete-v1-s100-w025-f25" }),
           candidate.consumedIndices.isEmpty, candidate.polygon.count == 4,
           !sameQuad(candidate.polygon, incoming) {
            return candidate
        }
        guard features.count >= 22, features[6].isFinite, features[12].isFinite,
              features[6] > 1, features[12] > 0, incoming.count == 4,
              let candidate = candidates.first(where: { $0.key == key }), candidate.consumedIndices.isEmpty,
              candidate.polygon.count == 4, !sameQuad(candidate.polygon, incoming) else { return nil }
        return candidate
    }

    private static func sameQuad(_ polygon: [CGPoint], _ incoming: [CGPoint]) -> Bool {
        for reversed in [false, true] {
            let quad = reversed ? Array(polygon.reversed()) : polygon
            for shift in 0..<4 {
                if (0..<4).allSatisfy({ index in
                    let a = quad[(index + shift) % 4], b = incoming[index]
                    return hypot(a.x - b.x, a.y - b.y) <= 1e-8
                }) { return true }
            }
        }
        return false
    }
    /// Additional common rules over the complete adopted v338 preference.
    static func preferredWithRF(_ candidates: [NativeOCRResidualCandidate], features: [Double], incoming: [CGPoint],
                                rfScopes: [NativeOCRResidualRFTextFeatures.Scope]) -> NativeOCRResidualCandidate? {
        let keys = Set(candidates.lazy.map(\.key).filter { $0.hasPrefix("prior-envelope-v1-") })
        if !keys.isEmpty,
           let key = NativeOCRPriorEnvelope345Selection.preferredKey(source22: features,
                rf8: NativeOCRResidualRFTextFeatures.features(incoming, scopes: rfScopes), admittedKeys: keys),
           let selected = candidates.first(where: { $0.key == key }) {
            return selected
        }
        return priorV345WithRF(candidates, features: features, incoming: incoming, rfScopes: rfScopes)
    }

    static func priorV345WithRF(_ candidates: [NativeOCRResidualCandidate], features: [Double], incoming: [CGPoint],
                                rfScopes: [NativeOCRResidualRFTextFeatures.Scope]) -> NativeOCRResidualCandidate? {
        let prior = priorV338WithRF(candidates, features: features, incoming: incoming, rfScopes: rfScopes)
        guard features.count == 22, incoming.count == 4,
              features.allSatisfy({ $0.isFinite }) else { return prior }
        let rf = NativeOCRResidualRFTextFeatures.features(incoming, scopes: rfScopes)
        guard rf.count == 8, rf.allSatisfy({ $0.isFinite }) else { return prior }
        var v = features + rf
        func quantized(_ value: Double) -> Double? {
            let scaled = value * 100000000.0
            guard scaled.isFinite else { return nil }
            let q = scaled.rounded(.toNearestOrAwayFromZero) / 100000000.0
            return q == 0 ? 0 : q
        }
        for f in 16..<30 {
            guard let value = quantized(v[f]) else { return prior }
            v[f] = value
        }
        // The two derived descriptors are dimensionless native measurement ratios.
        guard let componentRate = quantized(v[5] / max(1, v[1])),
              let lengthWidthRatio = quantized(v[1] * v[3] / max(1e-9, abs(v[2]))) else { return prior }
        let first = v[8] == 2 && v[1] >= 8 && v[7] <= 0.039066220847165385 && v[24] <= 0.89469683
        let second = v[8] == 2 && v[2] >= 0.8 && v[2] < 1.05 &&
            componentRate > 9.155126024999998 && lengthWidthRatio > 11.107142855
        let third = v[8] == 2 && v[4] > 0.5728953308377881
        let fourth = v[10] <= -0.0505742765123692 && v[2] > 1.0006573249223916 && v[22] <= 0
        guard first || second || third || fourth else { return prior }
        var effectivePrior = prior
        if effectivePrior == nil, let encoded = NativeOCRResidualCandidateBank.selectedKey(features) {
            let ranked = encoded.components(separatedBy: " >> ")
            if ranked.count <= 3 && ranked.allSatisfy({ !$0.isEmpty }) {
                for key in ranked {
                    guard let q = candidates.first(where: { $0.key == key }) else { continue }
                    if ranked.count > 1 {
                        guard q.consumedIndices.isEmpty, !sameQuad(q.polygon, incoming) else { continue }
                    }
                    effectivePrior = q; break
                }
            }
        }
        func axis(_ p: [CGPoint]) -> CGPoint? {
            guard p.count == 4, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let a = CGPoint(x: p[1].x-p[0].x, y: p[1].y-p[0].y)
            let b = CGPoint(x: p[3].x-p[0].x, y: p[3].y-p[0].y)
            let e = hypot(a.x,a.y) >= hypot(b.x,b.y) ? a : b
            let length = hypot(e.x,e.y)
            guard length.isFinite, length > 0 else { return nil }
            return .init(x: e.x/length, y: e.y/length)
        }
        let inherited = effectivePrior?.polygon ?? incoming
        guard let candidate = candidates.first(where: {
            $0.key == "private-pca-normal-footprint-v1-pad000-retain-current-along"
        }), candidate.consumedIndices == (effectivePrior?.consumedIndices ?? []),
              candidate.associationKey == (effectivePrior?.associationKey ?? effectivePrior?.key),
              let a = axis(inherited), let b = axis(candidate.polygon),
              abs(a.x*b.x+a.y*b.y) >= cos(3 * .pi / 180),
              NativeOCRNoAlongEndLoss.allows(inherited: inherited, proposed: candidate.polygon),
              !sameQuad(candidate.polygon, incoming) else { return prior }
        return candidate
    }

    static func priorV338WithRF(_ candidates: [NativeOCRResidualCandidate], features: [Double], incoming: [CGPoint],
                                rfScopes: [NativeOCRResidualRFTextFeatures.Scope]) -> NativeOCRResidualCandidate? {
        let prior = priorV337WithRF(candidates, features: features, incoming: incoming, rfScopes: rfScopes)
        guard features.count == 22, incoming.count == 4,
              features.allSatisfy({ $0.isFinite }) else { return prior }
        let rf = NativeOCRResidualRFTextFeatures.features(incoming, scopes: rfScopes)
        guard rf.count == 8, rf.allSatisfy({ $0.isFinite }) else { return prior }
        var v = features + rf
        for f in 16..<30 {
            let scaled = v[f] * 100000000.0
            guard scaled.isFinite else { return prior }
            v[f] = scaled.rounded(.toNearestOrAwayFromZero) / 100000000.0
            if v[f] == 0 { v[f] = 0 }
        }
        let first = v[8] == 0 && v[1] >= 3 && v[1] < 8 && v[2] >= 0.8 && v[2] < 1.05 &&
            v[3] >= 0.85 && v[3] < 1.05 && v[28] <= -2.010935198 && v[10] <= -0.04285714285714283
        let second = v[8] == 0 && v[1] >= 8 && v[2] >= 1.05 && v[3] >= 0.85 && v[3] < 1.05 &&
            v[27] > 1.6387642959999997 && v[0] <= 0.8444822412310745
        guard first || second else { return prior }
        var effectivePrior = prior
        if effectivePrior == nil, let encoded = NativeOCRResidualCandidateBank.selectedKey(features) {
            let ranked = encoded.components(separatedBy: " >> ")
            if ranked.count <= 3 && ranked.allSatisfy({ !$0.isEmpty }) {
                for key in ranked {
                    guard let q = candidates.first(where: { $0.key == key }) else { continue }
                    if ranked.count > 1 {
                        guard q.consumedIndices.isEmpty, !sameQuad(q.polygon, incoming) else { continue }
                    }
                    effectivePrior = q; break
                }
            }
        }
        func axis(_ p: [CGPoint]) -> CGPoint? {
            guard p.count == 4, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let a = CGPoint(x: p[1].x-p[0].x, y: p[1].y-p[0].y)
            let b = CGPoint(x: p[3].x-p[0].x, y: p[3].y-p[0].y)
            let e = hypot(a.x,a.y) >= hypot(b.x,b.y) ? a : b
            let length = hypot(e.x,e.y)
            guard length.isFinite, length > 0 else { return nil }
            return .init(x: e.x/length, y: e.y/length)
        }
        let inherited = effectivePrior?.polygon ?? incoming
        guard let candidate = candidates.first(where: {
            $0.key == "private-pca-normal-footprint-v1-pad000-retain-current-along"
        }), candidate.consumedIndices == (effectivePrior?.consumedIndices ?? []),
              candidate.associationKey == (effectivePrior?.associationKey ?? effectivePrior?.key),
              let a = axis(inherited), let b = axis(candidate.polygon),
              abs(a.x*b.x+a.y*b.y) >= cos(3 * .pi / 180),
              NativeOCRNoAlongEndLoss.allows(inherited: inherited, proposed: candidate.polygon),
              !sameQuad(candidate.polygon, incoming) else { return prior }
        return candidate
    }

    static func priorV337WithRF(_ candidates: [NativeOCRResidualCandidate], features: [Double], incoming: [CGPoint],
                                rfScopes: [NativeOCRResidualRFTextFeatures.Scope]) -> NativeOCRResidualCandidate? {
        let prior = priorV335WithRF(candidates, features: features, incoming: incoming, rfScopes: rfScopes)
        guard features.count == 22, incoming.count == 4,
              features.allSatisfy({ $0.isFinite }) else { return prior }
        let rf = NativeOCRResidualRFTextFeatures.features(incoming, scopes: rfScopes)
        guard rf.count == 8, rf.allSatisfy({ $0.isFinite }) else { return prior }
        var v = features + rf
        for f in 16..<30 {
            let scaled = v[f] * 100000000.0
            guard scaled.isFinite else { return prior }
            v[f] = scaled.rounded(.toNearestOrAwayFromZero) / 100000000.0
            if v[f] == 0 { v[f] = 0 }
        }
        let common = v[8] == 0 && v[1] >= 3 && v[1] < 8 && v[2] < 0.8
        let first = common && v[3] < 0.85 && v[0] <= 0.7637134395476695 && v[18] <= 0.07164018999999999
        let second = common && v[3] >= 0.85 && v[3] < 1.05 &&
            v[10] <= -0.054761904761904776 && v[27] <= 0.965997124
        guard first || second else { return prior }
        var effectivePrior = prior
        if effectivePrior == nil, let encoded = NativeOCRResidualCandidateBank.selectedKey(features) {
            let ranked = encoded.components(separatedBy: " >> ")
            if ranked.count <= 3 && ranked.allSatisfy({ !$0.isEmpty }) {
                for key in ranked {
                    guard let q = candidates.first(where: { $0.key == key }) else { continue }
                    if ranked.count > 1 {
                        guard q.consumedIndices.isEmpty, !sameQuad(q.polygon, incoming) else { continue }
                    }
                    effectivePrior = q; break
                }
            }
        }
        func stableRelativeAxis(_ old: [CGPoint], _ proposed: [CGPoint]) -> Bool {
            func major(_ p: [CGPoint]) -> CGPoint? {
                guard p.count == 4, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
                let a = CGPoint(x: p[1].x-p[0].x, y: p[1].y-p[0].y)
                let b = CGPoint(x: p[3].x-p[0].x, y: p[3].y-p[0].y)
                let e = hypot(a.x,a.y) >= hypot(b.x,b.y) ? a : b
                let length = hypot(e.x,e.y)
                return length > 0 ? .init(x: e.x/length,y: e.y/length) : nil
            }
            guard let a = major(old), let b = major(proposed) else { return false }
            return abs(a.x*b.x+a.y*b.y) >= cos(3 * .pi / 180)
        }
        guard let candidate = candidates.first(where: {
            $0.key == "private-pca-normal1-retain-prior-along-turning-component-veto-v1"
        }), candidate.consumedIndices == (effectivePrior?.consumedIndices ?? []),
              candidate.associationKey == (effectivePrior?.associationKey ?? effectivePrior?.key),
              !sameQuad(candidate.polygon, incoming),
              stableRelativeAxis(effectivePrior?.polygon ?? incoming, candidate.polygon),
              NativeOCRNoAlongEndLoss.allows(inherited: effectivePrior?.polygon ?? incoming,
                                            proposed: candidate.polygon) else { return prior }
        return candidate
    }

    static func priorV335WithRF(_ candidates: [NativeOCRResidualCandidate], features: [Double], incoming: [CGPoint],
                                rfScopes: [NativeOCRResidualRFTextFeatures.Scope]) -> NativeOCRResidualCandidate? {
        if let peer = NativeOCRResidualPeerChainSelection.preferred(candidates, features: features) { return peer }
        let rf = NativeOCRResidualRFTextFeatures.features(incoming, scopes: rfScopes)
        return selectRFAlongV333Common80(features, rfText: rf, candidates: candidates, incoming: incoming) {
            priorV331(candidates, features: features, incoming: incoming, rfScopes: rfScopes)
        }
    }

    static func selectRFAlongV333Common80(_ values: [Double], rfText: [Double],
        candidates: [NativeOCRResidualCandidate], incoming: [CGPoint],
        inherited: () -> NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        let prior = inherited()
        guard values.count == 22, rfText.count == 8, incoming.count == 4,
              values.allSatisfy({ $0.isFinite }), rfText.allSatisfy({ $0.isFinite }),
              incoming.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return prior }
        var v = values + rfText
        for f in 16..<30 {
            let scaled = v[f] * 100000000.0
            guard scaled.isFinite else { return prior }
            let rounded = scaled.rounded(.toNearestOrAwayFromZero) / 100000000.0
            guard rounded.isFinite else { return prior }
            v[f] = rounded == 0 ? 0 : rounded
        }
        // Resolve the authentic complete v331 effective baseline once; nil prior keeps its external semantics.
        var baseline = prior?.polygon
        if baseline == nil, let encoded = NativeOCRResidualCandidateBank.selectedKey(values) {
            let ranked = encoded.components(separatedBy: " >> ")
            if ranked.count <= 3 && ranked.allSatisfy({ !$0.isEmpty }) {
                for key in ranked {
                    guard let q = candidates.first(where: { $0.key == key }) else { continue }
                    if ranked.count > 1 {
                        guard q.consumedIndices.isEmpty, !sameQuad(q.polygon, incoming) else { continue }
                    }
                    baseline = q.polygon
                    break
                }
            }
        }
        func finiteQuadArea(_ p: [CGPoint]) -> Double? {
            guard p.count == 4, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let o = p[0]
            let a = CGPoint(x: p[1].x-o.x, y: p[1].y-o.y)
            let b = CGPoint(x: p[2].x-o.x, y: p[2].y-o.y)
            let c = CGPoint(x: p[3].x-o.x, y: p[3].y-o.y)
            let area = Double(abs(a.x*b.y-a.y*b.x+b.x*c.y-b.y*c.x)) * 0.5
            return area.isFinite && area > 0 ? area : nil
        }
        func preservesPriorNormal(_ old: [CGPoint], _ proposed: [CGPoint]) -> Bool {
            guard old.count == 4, proposed.count == 4,
                  (old + proposed).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
            let a = CGPoint(x: old[1].x-old[0].x, y: old[1].y-old[0].y)
            let b = CGPoint(x: old[3].x-old[0].x, y: old[3].y-old[0].y)
            let e = hypot(a.x, a.y) >= hypot(b.x, b.y) ? a : b
            let length = hypot(e.x, e.y)
            guard length.isFinite, length > 0 else { return false }
            let nx = e.y / length, ny = -e.x / length
            let origin = old[0]
            func projection(_ p: CGPoint) -> CGFloat {
                (p.x-origin.x)*nx + (p.y-origin.y)*ny
            }
            let before = old.map(projection), after = proposed.map(projection)
            return after.min()! <= before.min()! + 1 + 1e-7 &&
                after.max()! >= before.max()! - 1 - 1e-7
        }
        struct Rule { let key: String; let matches: Bool }
        let rules: [Rule] = [
            Rule(key: "rf-text-along-v1-r0-p05", matches: v[29] <= -0.039339255000000004 && v[28] <= -1.74943965),
            Rule(key: "rf-text-along-v1-r0-p0", matches: v[29] <= -0.024431634000000001 && v[4] <= 0.40322580645161288),
            Rule(key: "rf-text-along-v1-r0-p0", matches: v[29] <= -0.024431634000000001 && v[0] <= 0.81798049667192907)
        ]
        for rule in rules where rule.matches {
            guard let q = candidates.first(where: { $0.key == rule.key }),
                  q.consumedIndices.isEmpty, q.polygon.count == 4,
                  q.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  !sameQuad(q.polygon, incoming),
                  NativeOCRNoAlongEndLoss.allows(inherited: baseline ?? incoming, proposed: q.polygon),
                  let priorArea = finiteQuadArea(baseline ?? incoming),
                  let proposedArea = finiteQuadArea(q.polygon),
                  proposedArea / priorArea <= 2.2,
                  preservesPriorNormal(baseline ?? incoming, q.polygon) else { continue }
            return q
        }
        return prior
    }

    static func priorV331(_ candidates: [NativeOCRResidualCandidate], features: [Double], incoming: [CGPoint],
                                rfScopes: [NativeOCRResidualRFTextFeatures.Scope]) -> NativeOCRResidualCandidate? {
        if let peer = NativeOCRResidualPeerChainSelection.preferred(candidates, features: features) { return peer }
        let rf = NativeOCRResidualRFTextFeatures.features(incoming, scopes: rfScopes)
        return selectV330CombinedCommon80Then90(features, rfText: rf, candidates: candidates, incoming: incoming) {
            selectPruned9491Common80Child(features, rfText: rf, candidates: candidates, incoming: incoming) {
            selectV328CombinedPadding80Then90(features, rfText: rf, candidates: candidates, incoming: incoming) {
            selectV327CombinedOldMenu80Then90(features, rfText: rf, candidates: candidates, incoming: incoming) {
            selectR3AngleEnvelope80Child(features, rfText: rf, candidates: candidates, incoming: incoming) {
            selectV325Combined80Then90(features, rfText: rf, candidates: candidates, incoming: incoming) {
            selectNative9464Pruned80Child(features, rfText: rf, candidates: candidates, incoming: incoming) {
            selectSafe9442Ordered80Child(features, rfText: rf, candidates: candidates, incoming: incoming) {
            selectDerived52Atomic80Child(features, rfText: rf, candidates: candidates, incoming: incoming) {
            selectAggressive80ClassChild(features, rfText: rf, candidates: candidates, incoming: incoming) {
            optionalRFSupportedCompactNarrowShort(features, rf: rf, validCandidates: candidates, incoming: incoming) {
                selectAsymmetricClassChild(features, rf: rf, validCandidates: candidates, incoming: incoming) {
                    selectQuantizedRFClassChild(features, rf: rf, validCandidates: candidates, incoming: incoming) {
                        preferred(candidates, features: features, incoming: incoming)
                    }
                }
            }
            }
        }
        }
        }
        }
        }
        }
        }
        }
        }
    }

    static func selectQuantizedRFClassChild(_ values: [Double], rf: [Double], validCandidates: [NativeOCRResidualCandidate],
                                incoming: [CGPoint], inherited: () -> NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Node {
            let feature: Int
            let threshold: Double
            let left: Int
            let right: Int
            let key: String?
        }
        enum Table {
            static let nodes: [String: [Node]] = [
                "0|compact|fit|fit": [
                    Node(feature: 0, threshold: 0.84982369449876605, left: 1, right: 4, key: nil),
                    Node(feature: 28, threshold: 0, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "support-minrect-v1-bounded-mar-tight-p05|enclose75"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|compact|fit|short": [
                    Node(feature: 5, threshold: 14, left: 1, right: 2, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: 19, threshold: 0.089591840000000006, left: 3, right: 4, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "input-footprint-v1-prepared-axis-normal-current-along"),
                ],
                "0|compact|narrow|fit": [
                    Node(feature: 5, threshold: 12, left: 1, right: 2, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: 20, threshold: 0, left: 3, right: 4, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
                ],
                        "0|long|fit|fit": [
                    Node(feature: 25, threshold: 0.13201009, left: 1, right: 4, key: nil),
                    Node(feature: 28, threshold: 0.70094476999999999, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "side-envelope-v1-right-grid"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|long|fit|short": [
                    Node(feature: 1, threshold: 9.4033119027027467, left: 1, right: 2, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: 7, threshold: 0.052261094996459666, left: 3, right: 4, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "normal.owned-shell.context35.v1"),
                ],
                "0|long|wide|fit": [
                    Node(feature: 2, threshold: 1.0697135557054851, left: 1, right: 4, key: nil),
                    Node(feature: 18, threshold: 0.053981479999999998, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "terminal-head-side-joint-v1|side-envelope-v1-normal-tail-grid|terminal-head-palette-gap065-reach3-v1"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|medium|fit|fit": [
                    Node(feature: 3, threshold: 0.9430892172654699, left: 1, right: 4, key: nil),
                    Node(feature: 16, threshold: 0, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "normal-complete-v1-s100-w025"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|medium|fit|short": [
                    Node(feature: 5, threshold: 29, left: 1, right: 2, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: 16, threshold: 0.037375119999999998, left: 3, right: 4, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "terminal-trim-v1|tail|pad04"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|medium|narrow|fit": [
                    Node(feature: 16, threshold: 0.15681818, left: 1, right: 4, key: nil),
                    Node(feature: 24, threshold: 0.88305679999999998, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "side-envelope-v1-full-ink-quarter|enclose25"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|medium|narrow|short": [
                    Node(feature: 0, threshold: 0.90241604048977242, left: 1, right: 2, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: 2, threshold: 0.66777802513874729, left: 3, right: 4, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "support-minrect-v1-incoming-axis-control-tight-p0|enclose25"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|medium|wide|fit": [
                    Node(feature: 10, threshold: -0.0041666666666666519, left: 1, right: 4, key: nil),
                    Node(feature: 27, threshold: 1.93392992, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "terminal-tail-side-joint-v1|side-envelope-v1-full-ink-half|terminal-tail-palette-gap065-reach3-v1"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|medium|wide|short": [
                    Node(feature: 25, threshold: 0.1225308, left: 1, right: 4, key: nil),
                    Node(feature: 10, threshold: 0.0097075868190781185, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "support-minrect-v1-bounded-mar-tight-p0|enclose50"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "1|long|fit|fit": [
                    Node(feature: 7, threshold: 0.042908946273129189, left: 1, right: 2, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "axis-bins-envelope-v1-full"),
                ],
                "1|medium|fit|fit": [
                    Node(feature: 1, threshold: 6.8120646804550233, left: 1, right: 2, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "terminal-head-side-joint-v1|side-envelope-v1-full-ink-half|terminal-head-palette-gap065-reach3-provisional-member-v2"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "2|long|fit|fit": [
                    Node(feature: 5, threshold: 122, left: 1, right: 4, key: nil),
                    Node(feature: 26, threshold: 1.98773646, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "support-minrect-v1-bounded-mar-retain-span-p0"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ]
            ]
        }
        guard values.count == 22, rf.count == 8, values.allSatisfy({ $0.isFinite }), rf.allSatisfy({ $0.isFinite }), incoming.count == 4 else { return inherited() }
        var routing = values + rf
        for f in 16..<30 {
            let scaled = routing[f] * 100000000.0
            guard scaled.isFinite else { return inherited() }
            let rounded = scaled.rounded(.toNearestOrAwayFromZero) / 100000000.0
            guard rounded.isFinite else { return inherited() }
            routing[f] = rounded == 0 ? 0 : rounded
        }
        guard let kind = Int(exactly: routing[8]) else { return inherited() }
        let aspect = routing[1] < 3 ? "compact" : routing[1] < 8 ? "medium" : "long"
        let normal = routing[2] < 0.8 ? "narrow" : routing[2] < 1.05 ? "fit" : "wide"
        let along = routing[3] < 0.85 ? "short" : routing[3] < 1.05 ? "fit" : "long"
        let sourceClass = [String(kind), aspect, normal, along].joined(separator: "|")
        guard let nodes = Table.nodes[sourceClass] else { return inherited() }
        var index = 0
        var key: String?
        for _ in 0...nodes.count {
            guard nodes.indices.contains(index) else { return inherited() }
            let node = nodes[index]
            if node.feature < 0 { key = node.key; break }
            index = routing[node.feature] <= node.threshold ? node.left : node.right
        }
        guard let key, let chosen = validCandidates.first(where: { $0.key == key }),
              chosen.consumedIndices.isEmpty, chosen.polygon.count == 4 else { return inherited() }
        // Native accepted availability is geometric, independent of GT IoU difference.
        for reversed in [false, true] {
            let q = reversed ? Array(chosen.polygon.reversed()) : chosen.polygon
            for shift in 0..<4 {
                if (0..<4).allSatisfy({ i in
                    let a = q[(i + shift) % 4], b = incoming[i]
                    return hypot(a.x - b.x, a.y - b.y) <= 1e-8
                }) { return inherited() }
            }
        }
        return chosen
    }
    static func selectAsymmetricClassChild(_ values: [Double], rf: [Double], validCandidates: [NativeOCRResidualCandidate],
                                incoming: [CGPoint], inherited: () -> NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Node {
            let feature: Int
            let threshold: Double
            let left: Int
            let right: Int
            let key: String?
        }
        enum Table {
            static let nodes: [String: [Node]] = [
                    "0|compact|fit|short": [
                    Node(feature: 5, threshold: 14, left: 1, right: 4, key: nil),
                    Node(feature: 20, threshold: -3.1413540000000002, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "asymmetric-support-v1-p59"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|compact|narrow|fit": [
                    Node(feature: 2, threshold: 0.64599520993457427, left: 1, right: 4, key: nil),
                    Node(feature: 11, threshold: 0.0065335111205505666, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "asymmetric-support-v1-p01"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                            "0|long|wide|fit": [
                    Node(feature: 1, threshold: 15.608139534883723, left: 1, right: 2, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: 18, threshold: 0.020017050000000002, left: 3, right: 4, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "asymmetric-support-v1-p58"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                    "0|medium|fit|short": [
                    Node(feature: 6, threshold: 2.1509306937238128, left: 1, right: 2, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: 26, threshold: 0.97713782999999999, left: 3, right: 4, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "asymmetric-support-v1-p14"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|medium|narrow|fit": [
                    Node(feature: 10, threshold: -0.023020055284534692, left: 1, right: 4, key: nil),
                    Node(feature: 16, threshold: 0.10961538, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "asymmetric-support-v1-p61"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|medium|narrow|short": [
                    Node(feature: 24, threshold: 0.94803623000000004, left: 1, right: 4, key: nil),
                    Node(feature: 1, threshold: 3.2606452421009524, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "asymmetric-support-v1-p57"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|medium|wide|fit": [
                    Node(feature: 21, threshold: 0.97398784000000005, left: 1, right: 4, key: nil),
                    Node(feature: 25, threshold: 0.062363160000000001, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "asymmetric-support-v1-p05"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
                "0|medium|wide|short": [
                    Node(feature: 19, threshold: 0.10531019, left: 1, right: 4, key: nil),
                    Node(feature: 10, threshold: 0.0097075868190781185, left: 2, right: 3, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: "asymmetric-support-v1-p03"),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                    Node(feature: -1, threshold: 0, left: 0, right: 0, key: nil),
                ],
            ]
        }
        guard values.count == 22, rf.count == 8, values.allSatisfy({ $0.isFinite }), rf.allSatisfy({ $0.isFinite }), incoming.count == 4 else { return inherited() }
        var routing = values + rf
        for f in 16..<30 {
            let scaled = routing[f] * 100000000.0
            guard scaled.isFinite else { return inherited() }
            let rounded = scaled.rounded(.toNearestOrAwayFromZero) / 100000000.0
            guard rounded.isFinite else { return inherited() }
            routing[f] = rounded == 0 ? 0 : rounded
        }
        guard let kind = Int(exactly: routing[8]) else { return inherited() }
        let aspect = routing[1] < 3 ? "compact" : routing[1] < 8 ? "medium" : "long"
        let normal = routing[2] < 0.8 ? "narrow" : routing[2] < 1.05 ? "fit" : "wide"
        let along = routing[3] < 0.85 ? "short" : routing[3] < 1.05 ? "fit" : "long"
        let sourceClass = [String(kind), aspect, normal, along].joined(separator: "|")
        guard let nodes = Table.nodes[sourceClass] else { return inherited() }
        var index = 0
        var key: String?
        for _ in 0...nodes.count {
            guard nodes.indices.contains(index) else { return inherited() }
            let node = nodes[index]
            if node.feature < 0 { key = node.key; break }
            index = routing[node.feature] <= node.threshold ? node.left : node.right
        }
        guard let key, let chosen = validCandidates.first(where: { $0.key == key }),
              chosen.consumedIndices.isEmpty, chosen.polygon.count == 4 else { return inherited() }
        // Native accepted availability is geometric, independent of GT IoU difference.
        for reversed in [false, true] {
            let q = reversed ? Array(chosen.polygon.reversed()) : chosen.polygon
            for shift in 0..<4 {
                if (0..<4).allSatisfy({ i in
                    let a = q[(i + shift) % 4], b = incoming[i]
                    return hypot(a.x - b.x, a.y - b.y) <= 1e-8
                }) { return inherited() }
            }
        }
        return chosen
    }
    static func optionalRFSupportedCompactNarrowShort(_ values: [Double], rf: [Double],
        validCandidates: [NativeOCRResidualCandidate], incoming: [CGPoint],
        inherited: () -> NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        guard values.count == 22, rf.count == 8, incoming.count == 4,
              values.allSatisfy({ $0.isFinite }), rf.allSatisfy({ $0.isFinite }) else { return inherited() }
        var routing = values + rf
        for f in 16..<30 {
            let scaled = routing[f] * 100000000.0
            guard scaled.isFinite else { return inherited() }
            let rounded = scaled.rounded(.toNearestOrAwayFromZero) / 100000000.0
            guard rounded.isFinite else { return inherited() }
            routing[f] = rounded == 0 ? 0 : rounded
        }
        guard routing[8] == 0, routing[1] < 3, routing[2] < 0.8, routing[3] < 0.85,
              routing[0] < 0.9, routing[17] > 0.11315116, routing[22] > 0,
              let chosen = validCandidates.first(where: {
                  $0.key == "support-blend-v1-side-envelope-v1-normal-ink-quarter-f75"
              }), chosen.consumedIndices.isEmpty, chosen.polygon.count == 4 else { return inherited() }
        for reversed in [false, true] {
            let q = reversed ? Array(chosen.polygon.reversed()) : chosen.polygon
            for shift in 0..<4 {
                if (0..<4).allSatisfy({ i in
                    let a = q[(i + shift) % 4], b = incoming[i]
                    return hypot(a.x - b.x, a.y - b.y) <= 1e-8
                }) { return inherited() }
            }
        }
        return chosen
    }
    // Ordered shared rules: latest EFFECTIVE matching rule wins; a miss retains
    // all prior same-class rules, then the COMPLETE guarded9442 parent policy.
    // Ordered shared rules: latest EFFECTIVE matching rule wins; a miss retains
    // all prior same-class rules, then the COMPLETE guarded9442 parent policy.
    // Ordered shared rules: latest EFFECTIVE matching rule wins; a miss retains
    // all prior same-class rules, then the COMPLETE actualv3259470 parent policy.
    static func selectV325Guarded80Child(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let sourceClass:String;let cuts:[Cut];let key:String}
        enum Table {static let rules:[Rule]=[
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 16, threshold: 0.059459459999999999, lessOrEqual: false), Cut(feature: 23, threshold: 0.77121156000000002, lessOrEqual: true)], key: "support-blend-v1-axis-bins-envelope-v1-full-f75"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 4, threshold: 0.42763156639902217, lessOrEqual: false), Cut(feature: 9, threshold: 0, lessOrEqual: true)], key: "asymmetric-support-v1-p33"),
        ]}
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}),incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values+rfText
        for f in 16..<30 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        func value(_ f:Int)->Double? {
            guard f>=0,f<v.count else{return nil}
            return v[f]
        }
        var selected:NativeOCRResidualCandidate? = nil
        for rule in Table.rules.reversed() where rule.sourceClass==sourceClass {
            var match=true
            for cut in rule.cuts {
                guard let x=value(cut.feature),cut.lessOrEqual ? x<=cut.threshold:x>cut.threshold else {match=false;break}
            }
            guard match,let q=candidates.first(where:{$0.key==rule.key}),q.consumedIndices.isEmpty,
                  q.polygon.count==4,q.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),!sameQuad(q.polygon,incoming) else{continue}
            selected=q;break
        }
        guard let chosen=selected else{return inherited()}
        let priorPreferred=inherited()
        var priorPolygon=priorPreferred?.polygon
        if priorPolygon==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys=encoded.components(separatedBy:" >> ")
            if rankedKeys.count<=3 && rankedKeys.allSatisfy({!$0.isEmpty}) {
                for key in rankedKeys {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if rankedKeys.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    priorPolygon=q.polygon;break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited:priorPolygon ?? incoming,proposed:chosen.polygon) else{return priorPreferred}
        return chosen
    }

    static func selectV325Common90Recovery(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let sourceClass:String;let cuts:[Cut];let key:String}
        enum Table {static let rules:[Rule]=[
            Rule(sourceClass: "2|medium|fit|fit", cuts: [], key: "support-blend-v1-axis-bins-envelope-v1-full-f50"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 3, threshold: 0.9281612562990742, lessOrEqual: true), Cut(feature: 50, threshold: 0.01274409, lessOrEqual: true)], key: "input-footprint-v1-original-axis-normal-current-along"),
            Rule(sourceClass: "0|medium|fit|short", cuts: [Cut(feature: 21, threshold: 0.82290757000000003, lessOrEqual: true), Cut(feature: 26, threshold: 0.91752725000000002, lessOrEqual: true)], key: "input-footprint-v1-original-direct"),
            Rule(sourceClass: "1|long|fit|fit", cuts: [Cut(feature: 3, threshold: 0.96666666666666667, lessOrEqual: true), Cut(feature: 26, threshold: 1.1472741, lessOrEqual: true)], key: "support-minrect-v1-bounded-mar-tight-p0"),
            Rule(sourceClass: "1|medium|fit|fit", cuts: [Cut(feature: 27, threshold: 1.2557525599999999, lessOrEqual: true), Cut(feature: 24, threshold: 0.98947819000000004, lessOrEqual: true)], key: "normal.owned-shell.v1"),
            Rule(sourceClass: "0|medium|wide|fit", cuts: [Cut(feature: 0, threshold: 0.80000000000000004, lessOrEqual: true), Cut(feature: 1, threshold: 5.3175161238820783, lessOrEqual: true)], key: "support-margin-v1-n0-a0"),
            Rule(sourceClass: "0|compact|fit|short", cuts: [Cut(feature: 0, threshold: 0.90295451234647506, lessOrEqual: false), Cut(feature: 26, threshold: 1.01293075, lessOrEqual: true)], key: "support-blend-v1-side-envelope-v1-right-grid-f75"),
            Rule(sourceClass: "1|long|wide|fit", cuts: [Cut(feature: 3, threshold: 0.96019749522070241, lessOrEqual: false), Cut(feature: 11, threshold: 0.0053317052387462493, lessOrEqual: false)], key: "support-minrect-v1-bounded-mar-retain-span-p1"),
            Rule(sourceClass: "1|long|fit|fit", cuts: [Cut(feature: 29, threshold: -0.053202840000000001, lessOrEqual: false), Cut(feature: 16, threshold: 0, lessOrEqual: false)], key: "support-margin-v1-n0-a0"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 2, threshold: 0.77895983205115815, lessOrEqual: false), Cut(feature: 51, threshold: 2.1000000000000001, lessOrEqual: true)], key: "input-footprint-v1-original-axis-normal-current-along"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 16, threshold: 0.13181818000000001, lessOrEqual: false), Cut(feature: 26, threshold: 0.97729043000000004, lessOrEqual: true)], key: "support-blend-v1-side-envelope-v1-normal-ink-half-f50"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 2, threshold: 0.64585622333257531, lessOrEqual: true), Cut(feature: 5, threshold: 8, lessOrEqual: true)], key: "side-envelope-v1-right-ink-half"),
            Rule(sourceClass: "1|long|fit|fit", cuts: [Cut(feature: 27, threshold: 1.0046533, lessOrEqual: true), Cut(feature: 46, threshold: 6.1930171500000002, lessOrEqual: false)], key: "normal.owned-shell.v1"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 2, threshold: 0.61499069344497115, lessOrEqual: true), Cut(feature: 3, threshold: 0.82432446670896709, lessOrEqual: false)], key: "support-blend-v1-side-envelope-v1-right-ink-half-f75"),
            Rule(sourceClass: "0|compact|fit|fit", cuts: [Cut(feature: 0, threshold: 0.84970716284200498, lessOrEqual: false), Cut(feature: 25, threshold: 0.0142379, lessOrEqual: false)], key: "input-footprint-v1-original-direct"),
            Rule(sourceClass: "1|long|wide|fit", cuts: [Cut(feature: 0, threshold: 0.86386761851813043, lessOrEqual: true), Cut(feature: 11, threshold: 0.0053317052387462493, lessOrEqual: false)], key: "axis-bins-envelope-v1-full"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 2, threshold: 1.0192307692307692, lessOrEqual: false), Cut(feature: 20, threshold: -0.096174659999999995, lessOrEqual: true)], key: "support-minrect-v1-incoming-axis-control-retain-span-p0"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 2, threshold: 0.77221821319674389, lessOrEqual: false), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "support-margin-v1-n5-a10"),
            Rule(sourceClass: "0|compact|wide|fit", cuts: [Cut(feature: 17, threshold: 2.5340000000000001e-05, lessOrEqual: false), Cut(feature: 49, threshold: 9.1963636399999995, lessOrEqual: true)], key: "support-margin-v1-n0-a15"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 19, threshold: 0.088355260000000005, lessOrEqual: true), Cut(feature: 50, threshold: 0.019723790000000001, lessOrEqual: true)], key: "terminal-tail-palette-gap065-reach3-v1"),
            Rule(sourceClass: "1|long|wide|fit", cuts: [Cut(feature: 26, threshold: 3.0819541500000001, lessOrEqual: true), Cut(feature: 10, threshold: -0.0032789952507973402, lessOrEqual: true)], key: "terminal-head-side-joint-v1|side-envelope-v1-normal-head-ink-half|terminal-head-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 1, threshold: 2.4386932882816739, lessOrEqual: false), Cut(feature: 29, threshold: 0.81538264000000005, lessOrEqual: true)], key: "support-blend-v1-side-envelope-v1-right-ink-quarter-f75"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 2, threshold: 1.1818181818181819, lessOrEqual: false), Cut(feature: 26, threshold: 2.3949447899999998, lessOrEqual: true)], key: "terminal-head-palette-gap065-reach3-v1"),
            Rule(sourceClass: "2|long|fit|fit", cuts: [Cut(feature: 18, threshold: 0.040515870000000002, lessOrEqual: false), Cut(feature: 26, threshold: 1.98773646, lessOrEqual: true)], key: "normal.owned-shell.v1"),
            Rule(sourceClass: "1|long|fit|fit", cuts: [Cut(feature: 24, threshold: 0.98809437, lessOrEqual: true), Cut(feature: 21, threshold: 0.96047450000000001, lessOrEqual: true)], key: "terminal-tail-side-joint-v1|side-envelope-v1-full-ink-half|terminal-tail-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|medium|wide|fit", cuts: [Cut(feature: 2, threshold: 1.0966588367082883, lessOrEqual: false), Cut(feature: 18, threshold: 0.061236060000000002, lessOrEqual: false)], key: "input-footprint-v1-original-axis-normal-current-along"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 0, threshold: 0.89883597141657123, lessOrEqual: false), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "terminal-head-side-joint-v1|side-envelope-v1-full-grid|terminal-head-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 0, threshold: 0.93079165142959319, lessOrEqual: false), Cut(feature: 23, threshold: 0.62106317, lessOrEqual: true)], key: "terminal-head-side-joint-v1|side-envelope-v1-normal-head-grid|terminal-head-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 9, threshold: 0, lessOrEqual: true), Cut(feature: 23, threshold: 0.62106317, lessOrEqual: true)], key: "terminal-trim-v1|head|pad04"),
            Rule(sourceClass: "0|medium|narrow|short", cuts: [Cut(feature: 2, threshold: 0.77771644712061971, lessOrEqual: false), Cut(feature: 26, threshold: 2.1881103500000001, lessOrEqual: true)], key: "support-blend-v1-side-envelope-v1-normal-ink-half-f25"),
            Rule(sourceClass: "0|medium|narrow|short", cuts: [Cut(feature: 4, threshold: 0.44587857627765498, lessOrEqual: true), Cut(feature: 21, threshold: 0.72554582000000001, lessOrEqual: true)], key: "terminal-trim-v1|tail|pad04"),
            Rule(sourceClass: "0|compact|fit|fit", cuts: [Cut(feature: 4, threshold: 0.45794024557437535, lessOrEqual: false), Cut(feature: 9, threshold: 0, lessOrEqual: false)], key: "asymmetric-support-v1-p58"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 3, threshold: 0.9064359751497989, lessOrEqual: false), Cut(feature: 4, threshold: 0.49187951512469363, lessOrEqual: false)], key: "axis-bins-center-v1-retain-span"),
            Rule(sourceClass: "0|medium|narrow|short", cuts: [Cut(feature: 2, threshold: 0.57537855250526193, lessOrEqual: true), Cut(feature: 24, threshold: 0.87606448000000003, lessOrEqual: true)], key: "terminal-tail-side-joint-v1|side-envelope-v1-right-grid|terminal-tail-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 19, threshold: 0.10035449, lessOrEqual: false), Cut(feature: 28, threshold: 0, lessOrEqual: false)], key: "side-envelope-v1-left-ink-quarter|enclose50"),
            Rule(sourceClass: "0|medium|wide|fit", cuts: [Cut(feature: 2, threshold: 1.080279998107005, lessOrEqual: true), Cut(feature: 11, threshold: 0.017484662576687546, lessOrEqual: false)], key: "terminal-tail-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 10, threshold: 0.080000000000000002, lessOrEqual: false), Cut(feature: 23, threshold: 0.64014309999999996, lessOrEqual: true)], key: "input-footprint-v1-original-axis-normal-current-along"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 14, threshold: 0.050000000000000003, lessOrEqual: false), Cut(feature: 19, threshold: 0.0080960000000000008, lessOrEqual: true)], key: "terminal-tail-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 19, threshold: 0.02387587, lessOrEqual: true), Cut(feature: 21, threshold: 0.69226321999999996, lessOrEqual: true)], key: "terminal-tail-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|long|narrow|fit", cuts: [Cut(feature: 11, threshold: -0.013809069614240979, lessOrEqual: false), Cut(feature: 17, threshold: 0.0089205799999999991, lessOrEqual: false)], key: "side-envelope-v1-right-ink-quarter"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 13, threshold: 0.050000000000000003, lessOrEqual: false), Cut(feature: 50, threshold: 0.072333919999999996, lessOrEqual: false)], key: "terminal-head-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 11, threshold: -0.040000000000000001, lessOrEqual: true), Cut(feature: 24, threshold: 0.88304183999999997, lessOrEqual: true)], key: "terminal-head-side-joint-v1|side-envelope-v1-head-grid|terminal-head-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|medium|wide|fit", cuts: [Cut(feature: 23, threshold: 0.91191535999999995, lessOrEqual: true), Cut(feature: 11, threshold: 0.040000000000000001, lessOrEqual: false)], key: "terminal-head-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 2, threshold: 0.75354170692106803, lessOrEqual: false), Cut(feature: 18, threshold: 0.1627392, lessOrEqual: false)], key: "support-blend-v1-side-envelope-v1-right-ink-half-f75"),
        ]}
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}),incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values+rfText
        for f in 16..<30 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        func value(_ f:Int)->Double? {
            if f<30{return v[f]}
            let raw:Double
            if f==46 {raw=v[5]/max(1,v[1])}
            else if f==49 {raw=v[5]/max(1,v[1]*max(1e-9,abs(v[3])))}
            else if f==50 {raw=hypot(v[10]/max(1e-9,abs(v[2])),v[11]/max(1e-9,abs(v[3])))}
            else if f==51 {raw=v[1]*v[3]/max(1e-9,abs(v[2]))}
            else{return nil}
            let scaled=raw*100000000.0
            guard scaled.isFinite else{return nil}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            return rounded.isFinite ? (rounded==0 ? 0:rounded):nil
        }
        var selected:NativeOCRResidualCandidate? = nil
        for rule in Table.rules.reversed() where rule.sourceClass==sourceClass {
            var match=true
            for cut in rule.cuts {
                guard let x=value(cut.feature),cut.lessOrEqual ? x<=cut.threshold:x>cut.threshold else {match=false;break}
            }
            guard match,let q=candidates.first(where:{$0.key==rule.key}),q.consumedIndices.isEmpty,
                  q.polygon.count==4,q.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),!sameQuad(q.polygon,incoming) else{continue}
            selected=q;break
        }
        guard let chosen=selected else{return inherited()}
        let priorPreferred=inherited()
        var priorPolygon=priorPreferred?.polygon
        if priorPolygon==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys=encoded.components(separatedBy:" >> ")
            if rankedKeys.count<=3 && rankedKeys.allSatisfy({!$0.isEmpty}) {
                for key in rankedKeys {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if rankedKeys.count>1 {guard q.consumedIndices.isEmpty else{continue}}
                    priorPolygon=q.polygon;break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited:priorPolygon ?? incoming,proposed:chosen.polygon) else{return priorPreferred}
        return chosen
    }

    // Call AFTER the existing peer-first preference; inherited() is ENTIRE actualv325.
    static func selectV325Combined80Then90(_ values:[Double],rfText:[Double],candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint],inherited:()->NativeOCRResidualCandidate?)->NativeOCRResidualCandidate? {
        var prior=inherited()
        if prior==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let ranked=encoded.components(separatedBy:" >> ")
            if ranked.count<=3 && ranked.allSatisfy({!$0.isEmpty}) {
                for key in ranked {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if ranked.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    prior=q;break
                }
            }
        }
        let priority80=selectV325Guarded80Child(values,rfText:rfText,candidates:candidates,incoming:incoming,inherited:{prior})
        if let q=priority80,!sameQuad(q.polygon,prior?.polygon ?? incoming) {return q}
        return selectV325Common90Recovery(values,rfText:rfText,candidates:candidates,incoming:incoming,inherited:{prior})
    }

    static func selectNative9464Pruned80Child(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let sourceClass:String;let cuts:[Cut];let key:String}
        enum Table {static let rules:[Rule]=[
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 5, threshold: 0, lessOrEqual: true), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "evidence-forward-v1-side-envelope-v1-normal-head-grid"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 22, threshold: 0, lessOrEqual: true), Cut(feature: 46, threshold: 5.8491663200000001, lessOrEqual: true)], key: "side-envelope-v1-normal-grid"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 2, threshold: 1, lessOrEqual: false), Cut(feature: 20, threshold: -0.096174659999999995, lessOrEqual: true)], key: "normal.owned-shell.v1"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 4, threshold: 0.44642857142857145, lessOrEqual: false), Cut(feature: 13, threshold: 0.050000000000000003, lessOrEqual: false)], key: "terminal-tail-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 10, threshold: 0.029487179487179452, lessOrEqual: true), Cut(feature: 47, threshold: 0.032169530000000002, lessOrEqual: false)], key: "normal-complete-v1-s100-w025"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 11, threshold: 0.0051739762877686547, lessOrEqual: false), Cut(feature: 14, threshold: 0.5, lessOrEqual: false)], key: "asymmetric-support-v1-p00"),
        ]}
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}),incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values+rfText
        for f in 16..<30 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        func value(_ f:Int)->Double? {
            if f<30{return v[f]}
            let raw:Double
            if f==46 {raw=v[5]/max(1,v[1])}
            else if f==47 {raw=v[10]/max(1e-9,abs(v[2]))}
            else{return nil}
            let scaled=raw*100000000.0
            guard scaled.isFinite else{return nil}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            return rounded.isFinite ? (rounded==0 ? 0:rounded):nil
        }
        var selected:NativeOCRResidualCandidate? = nil
        for rule in Table.rules.reversed() where rule.sourceClass==sourceClass {
            var match=true
            for cut in rule.cuts {
                guard let x=value(cut.feature),cut.lessOrEqual ? x<=cut.threshold:x>cut.threshold else {match=false;break}
            }
            guard match,let q=candidates.first(where:{$0.key==rule.key}),q.consumedIndices.isEmpty,
                  q.polygon.count==4,q.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),!sameQuad(q.polygon,incoming) else{continue}
            selected=q;break
        }
        guard let chosen=selected else{return inherited()}
        let priorPreferred=inherited()
        var priorPolygon=priorPreferred?.polygon
        if priorPolygon==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys=encoded.components(separatedBy:" >> ")
            if rankedKeys.count<=3 && rankedKeys.allSatisfy({!$0.isEmpty}) {
                for key in rankedKeys {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if rankedKeys.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    priorPolygon=q.polygon;break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited:priorPolygon ?? incoming,proposed:chosen.polygon) else{return priorPreferred}
        return chosen
    }

    static func selectSafe9442Ordered80Child(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let sourceClass:String;let cuts:[Cut];let key:String}
        enum Table {static let rules:[Rule]=[
            Rule(sourceClass: "0|compact|fit|fit", cuts: [Cut(feature: 2, threshold: 1, lessOrEqual: false), Cut(feature: 18, threshold: 0.10822727, lessOrEqual: false)], key: "side-envelope-v1-normal-ink-half"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 17, threshold: 0.015853659999999999, lessOrEqual: false), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "axis-bins-envelope-v1-full"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 2, threshold: 0.84126984126984128, lessOrEqual: true), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "axis-bins-envelope-v1-full"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 3, threshold: 0.87661284491557501, lessOrEqual: true), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "axis-bins-envelope-v1-half"),
            Rule(sourceClass: "0|medium|narrow|short", cuts: [Cut(feature: 3, threshold: 0.62875691898102815, lessOrEqual: true), Cut(feature: 6, threshold: 1, lessOrEqual: false)], key: "side-envelope-v1-tail-grid"),
            Rule(sourceClass: "2|long|fit|fit", cuts: [Cut(feature: 28, threshold: 0.069318980000000002, lessOrEqual: true), Cut(feature: 25, threshold: 0.51205237999999997, lessOrEqual: false)], key: "support-margin-v1-n0-a15"),
            Rule(sourceClass: "2|long|fit|fit", cuts: [Cut(feature: 26, threshold: 1.98773646, lessOrEqual: true), Cut(feature: 16, threshold: 0, lessOrEqual: false)], key: "support-minrect-v1-bounded-mar-retain-span-p0"),
            Rule(sourceClass: "0|medium|narrow|short", cuts: [Cut(feature: 1, threshold: 4.5521275592900494, lessOrEqual: false), Cut(feature: 16, threshold: 0.15570612, lessOrEqual: false)], key: "support-blend-v1-axis-bins-envelope-v1-full-f75"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 22, threshold: 0, lessOrEqual: true), Cut(feature: 46, threshold: 5.8491663200000001, lessOrEqual: true)], key: "asymmetric-support-v1-p14"),
            Rule(sourceClass: "0|compact|fit|fit", cuts: [Cut(feature: 0, threshold: 0.90622163934675126, lessOrEqual: false), Cut(feature: 11, threshold: 0.024436955343877423, lessOrEqual: false)], key: "support-minrect-v1-bounded-mar-tight-p0|enclose75"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 10, threshold: 0.080000000000000002, lessOrEqual: false), Cut(feature: 24, threshold: 0.95481302000000001, lessOrEqual: true)], key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 11, threshold: 0.040000000000000001, lessOrEqual: false), Cut(feature: 27, threshold: 0.97760409999999998, lessOrEqual: true)], key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 18, threshold: 0, lessOrEqual: true), Cut(feature: 21, threshold: 0.91754349999999996, lessOrEqual: true)], key: "normal.owned-shell.v1"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 46, threshold: 5.8491663200000001, lessOrEqual: true), Cut(feature: 51, threshold: 13.274509800000001, lessOrEqual: false)], key: "terminal-tail-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 3, threshold: 0.95152984323455581, lessOrEqual: false), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "support-blend-v1-side-envelope-v1-normal-ink-quarter-f75"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 11, threshold: -0.01551040483933268, lessOrEqual: true), Cut(feature: 19, threshold: 0.10947374999999999, lessOrEqual: false)], key: "support-minrect-v1-bounded-mar-tight-p05"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 2, threshold: 0.8924040360038672, lessOrEqual: true), Cut(feature: 10, threshold: 0.080000000000000002, lessOrEqual: false)], key: "normal.owned-shell.v1"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 0, threshold: 0.93418976804072962, lessOrEqual: false), Cut(feature: 27, threshold: 0.95872181000000001, lessOrEqual: true)], key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 5, threshold: 63, lessOrEqual: false), Cut(feature: 24, threshold: 0.89886741999999997, lessOrEqual: true)], key: "normal.owned-shell.v1"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 14, threshold: 0.050000000000000003, lessOrEqual: false), Cut(feature: 16, threshold: 0.08684211, lessOrEqual: false)], key: "terminal-tail-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 4, threshold: 0.42391270910473078, lessOrEqual: true), Cut(feature: 24, threshold: 0.80975794999999995, lessOrEqual: true)], key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
        ]}
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}),incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values+rfText
        for f in 16..<30 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        func value(_ f:Int)->Double? {
            if f<30{return v[f]}
            let raw:Double
            if f==46 {raw=v[5]/max(1,v[1])}
            else if f==51 {raw=v[1]*v[3]/max(1e-9,abs(v[2]))}
            else{return nil}
            let scaled=raw*100000000.0
            guard scaled.isFinite else{return nil}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            return rounded.isFinite ? (rounded==0 ? 0:rounded):nil
        }
        var selected:NativeOCRResidualCandidate? = nil
        for rule in Table.rules.reversed() where rule.sourceClass==sourceClass {
            var match=true
            for cut in rule.cuts {
                guard let x=value(cut.feature),cut.lessOrEqual ? x<=cut.threshold:x>cut.threshold else {match=false;break}
            }
            guard match,let q=candidates.first(where:{$0.key==rule.key}),q.consumedIndices.isEmpty,
                  q.polygon.count==4,q.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),!sameQuad(q.polygon,incoming) else{continue}
            selected=q;break
        }
        guard let chosen=selected else{return inherited()}
        let priorPreferred=inherited()
        var priorPolygon=priorPreferred?.polygon
        if priorPolygon==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys=encoded.components(separatedBy:" >> ")
            if rankedKeys.count<=3 && rankedKeys.allSatisfy({!$0.isEmpty}) {
                for key in rankedKeys {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if rankedKeys.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    priorPolygon=q.polygon;break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited:priorPolygon ?? incoming,proposed:chosen.polygon) else{return priorPreferred}
        return chosen
    }

    static func selectDerived52Atomic80Child(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let cuts:[Cut];let key:String}
        enum Table { static let rules:[String:Rule]=[
                "0|compact|fit|fit": Rule(cuts: [Cut(feature: 2, threshold: 0.86663001011200924, lessOrEqual: true), Cut(feature: 11, threshold: 0.024436955343877423, lessOrEqual: false)], key: "support-minrect-v1-bounded-mar-tight-p0|enclose75"),
                "0|long|fit|fit": Rule(cuts: [Cut(feature: 11, threshold: 0.0058914384908188705, lessOrEqual: false), Cut(feature: 16, threshold: 0.044444440000000002, lessOrEqual: false)], key: "terminal-tail-side-joint-v1|side-envelope-v1-normal-head-ink-half|terminal-tail-palette-gap065-reach3-v1"),
                "0|long|wide|fit": Rule(cuts: [Cut(feature: 4, threshold: 0.41666667889326048, lessOrEqual: true), Cut(feature: 21, threshold: 0.99822288999999997, lessOrEqual: false)], key: "terminal-head-side-joint-v1|side-envelope-v1-normal-ink-quarter|terminal-head-palette-gap065-reach3-v1"),
                "0|medium|fit|fit": Rule(cuts: [Cut(feature: 5, threshold: 31, lessOrEqual: true), Cut(feature: 46, threshold: 8.6798738800000006, lessOrEqual: false)], key: "terminal-head-side-joint-v1|side-envelope-v1-right-ink-half|terminal-head-palette-gap065-reach3-v1"),
                "0|medium|narrow|fit": Rule(cuts: [Cut(feature: 19, threshold: 0.02387587, lessOrEqual: true), Cut(feature: 21, threshold: 0.69181537000000004, lessOrEqual: true)], key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
                "0|medium|narrow|short": Rule(cuts: [Cut(feature: 1, threshold: 5.5217610731130202, lessOrEqual: false), Cut(feature: 6, threshold: 1.4397173800615517, lessOrEqual: false)], key: "support-minrect-v1-bounded-mar-tight-p05|enclose75"),
                "1|long|fit|fit": Rule(cuts: [Cut(feature: 20, threshold: -0.14631479, lessOrEqual: false), Cut(feature: 11, threshold: 0.002205099066429381, lessOrEqual: false)], key: "asymmetric-support-v1-p33"),
                "1|long|fit|short": Rule(cuts: [], key: "axis-bins-envelope-v1-half"),
                "1|medium|fit|short": Rule(cuts: [], key: "asymmetric-support-v1-p61"),
                "1|medium|wide|fit": Rule(cuts: [], key: "terminal-tail-palette-gap065-reach3-v1"),
                "2|long|fit|fit": Rule(cuts: [Cut(feature: 7, threshold: 0.041328699233819211, lessOrEqual: true), Cut(feature: 10, threshold: -0.0024915975417592728, lessOrEqual: true)], key: "axis-bins-center-v1-retain-span"),
        ] }
        guard values.count==22,rfText.count==8,values.allSatisfy({$0.isFinite}),
              rfText.allSatisfy({$0.isFinite}),incoming.count==4,incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values
        for f in 16..<22 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        guard let rule=Table.rules[[String(kind),aspect,normal,along].joined(separator:"|")] else{return inherited()}
        for cut in rule.cuts {
            let value:Double
            if cut.feature<22 {value=v[cut.feature]}
            else if cut.feature==46 {
                let raw=v[5]/max(1,v[1]),scaled=raw*100000000.0
                guard scaled.isFinite else{return inherited()}
                value=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
                guard value.isFinite else{return inherited()}
            } else {return inherited()}
            guard cut.lessOrEqual ? value<=cut.threshold:value>cut.threshold else{return inherited()}
        }
        guard let chosen=candidates.first(where:{$0.key==rule.key}),chosen.consumedIndices.isEmpty,
              chosen.polygon.count==4,chosen.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        for reverse in [false,true] {
            let q=reverse ? Array(chosen.polygon.reversed()):chosen.polygon
            for shift in 0..<4 {
                if (0..<4).allSatisfy({i in hypot(q[(i+shift)%4].x-incoming[i].x,q[(i+shift)%4].y-incoming[i].y)<=1e-8}) {return inherited()}
            }
        }
        let priorPreferred = inherited()
        var priorPolygon = priorPreferred?.polygon
        if priorPolygon == nil, let encoded = NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys = encoded.components(separatedBy: " >> ")
            if rankedKeys.count <= 3 && rankedKeys.allSatisfy({ !$0.isEmpty }) {
                for key in rankedKeys {
                    guard let candidate = candidates.first(where: { $0.key == key }) else { continue }
                    if rankedKeys.count > 1 {
                        guard candidate.consumedIndices.isEmpty, !sameQuad(candidate.polygon, incoming) else { continue }
                    }
                    priorPolygon = candidate.polygon
                    break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited: priorPolygon ?? incoming, proposed: chosen.polygon) else {
            return priorPreferred
        }
        return chosen
    }

    static func aggressiveCanonicalPresenceAndAngle(_ incoming:[CGPoint], candidates:[NativeOCRResidualCandidate]) -> (present:Double,angle:Double) {
        guard incoming.count==4, incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              let canonical=candidates.first(where:{$0.key=="evidence-forward-v1-support-minrect-v1-bounded-mar-retain-span-p0"}),
              canonical.consumedIndices.isEmpty,canonical.polygon.count==4,
              canonical.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {return (0,0)}
        let p=incoming,q=canonical.polygon
        func edge(_ a:CGPoint,_ b:CGPoint)->CGPoint {CGPoint(x:a.x-b.x,y:a.y-b.y)}
        func unit(_ v:CGPoint)->CGPoint? {
            let n=hypot(v.x,v.y);guard n.isFinite,n>0 else{return nil};return CGPoint(x:v.x/n,y:v.y/n)
        }
        let a=edge(p[1],p[0]),b=edge(p[3],p[0])
        guard let along=unit(hypot(a.x,a.y)>=hypot(b.x,b.y) ? a:b),
              let e1=unit(edge(q[1],q[0])),let e3=unit(edge(q[3],q[0])) else{return (0,0)}
        func dot(_ u:CGPoint,_ v:CGPoint)->CGFloat {u.x*v.x+u.y*v.y}
        var axis=abs(dot(e1,along))>=abs(dot(e3,along)) ? e1:e3
        if dot(axis,along)<0 {axis=CGPoint(x:-axis.x,y:-axis.y)}
        let angle=Double(atan2(along.x*axis.y-along.y*axis.x,dot(along,axis)))*180/Double.pi
        let scaled=angle*100000000.0
        guard scaled.isFinite else{return (0,0)}
        let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
        guard rounded.isFinite else{return (0,0)}
        return (1,rounded==0 ? 0:rounded)
    }

    static func selectAggressive80ClassChild(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Rule {let feature:Int;let threshold:Double;let lessOrEqual:Bool;let key:String}
        enum Table {
            static let rules:[String:Rule]=[
                "0|compact|fit|fit": Rule(feature: 36, threshold: 4.76364169, lessOrEqual: false, key: "evidence-forward-v1-side-envelope-v1-left-grid"),
                "0|compact|narrow|fit": Rule(feature: 22, threshold: 0, lessOrEqual: true, key: "side-envelope-v1-full-ink-half|enclose75"),
                "0|compact|narrow|short": Rule(feature: 21, threshold: 0.57863425000000002, lessOrEqual: true, key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along|enclose50"),
                "0|long|fit|fit": Rule(feature: 30, threshold: 0, lessOrEqual: false, key: "evidence-forward-v1-side-envelope-v1-tail-grid"),
                "0|long|wide|fit": Rule(feature: 9, threshold: 0, lessOrEqual: true, key: "asymmetric-support-v1-p36"),
                "0|long|wide|short": Rule(feature: -1, threshold: 0, lessOrEqual: false, key: "support-margin-v1-n5-a0"),
                "0|medium|fit|fit": Rule(feature: 10, threshold: 0.080000000000000002, lessOrEqual: false, key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
                "0|medium|fit|short": Rule(feature: 1, threshold: 4.187843476566222, lessOrEqual: true, key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
                "0|medium|narrow|fit": Rule(feature: 18, threshold: 0, lessOrEqual: true, key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along|enclose50"),
                "0|medium|narrow|short": Rule(feature: 5, threshold: 38, lessOrEqual: false, key: "side-envelope-v1-right-ink-half"),
                "0|medium|wide|fit": Rule(feature: 0, threshold: 0.86944251089918134, lessOrEqual: true, key: "support-minrect-v1-bounded-mar-tight-p05"),
                "1|long|fit|fit": Rule(feature: 21, threshold: 0.97844122, lessOrEqual: false, key: "support-minrect-v1-bounded-mar-retain-span-p0"),
                "2|long|fit|fit": Rule(feature: 3, threshold: 0.9800241657629738, lessOrEqual: true, key: "normal.owned-shell.v1"),
            ]
        }
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}) else {return inherited()}
        var routing=values+rfText
        for f in 16..<30 {
            let scaled=routing[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            routing[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:routing[8]) else{return inherited()}
        let aspect=routing[1]<3 ? "compact":routing[1]<8 ? "medium":"long"
        let normal=routing[2]<0.8 ? "narrow":routing[2]<1.05 ? "fit":"wide"
        let along=routing[3]<0.85 ? "short":routing[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        guard let rule=Table.rules[sourceClass] else{return inherited()}
        if rule.feature>=0 {
            let value:Double
            if rule.feature<30 {value=routing[rule.feature]}
            else {
                let canonical=aggressiveCanonicalPresenceAndAngle(incoming,candidates:candidates)
                if rule.feature==30 {value=canonical.present}
                else if rule.feature==36 {value=canonical.angle}
                else {return inherited()}
            }
            guard rule.lessOrEqual ? value<=rule.threshold:value>rule.threshold else{return inherited()}
        }
        guard let chosen=candidates.first(where:{$0.key==rule.key}),chosen.consumedIndices.isEmpty,
              chosen.polygon.count==4,chosen.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        for reversed in [false,true] {
            let q=reversed ? Array(chosen.polygon.reversed()):chosen.polygon
            for shift in 0..<4 {
                if (0..<4).allSatisfy({i in hypot(q[(i+shift)%4].x-incoming[i].x,q[(i+shift)%4].y-incoming[i].y)<=1e-8}) {return inherited()}
            }
        }
        return chosen
    }
}

/// Source geometry and RF text evidence only; no targets or source identities.
@available(iOS 18.0, *)
enum NativeOCRResidualRFTextFeatures {
    struct Scope {
        let rect: CGRect
        let confidence: Double
        let semanticClass: Int
    }
    static let featureNames = ["rfTextPresent", "rfTextConfidence", "rfTextSourceCoverage", "rfTextScopeCoverage",
        "rfTextNormalSpanRatio", "rfTextAlongSpanRatio", "rfTextNormalCenterOffsetWidths", "rfTextAlongCenterOffsetWidths"]

    static func features(_ polygon: [CGPoint], scopes: [Scope]) -> [Double] {
        let empty = [Double](repeating: 0, count: 8)
        guard polygon.count == 4, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return empty }
        let sourceArea = area(polygon)
        let turns = polygon.indices.map { i -> CGFloat in
            let a = polygon[i], b = polygon[(i + 1) % 4], c = polygon[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        guard sourceArea.isFinite, sourceArea > 2,
              turns.allSatisfy({ $0 >= 0 }) || turns.allSatisfy({ $0 <= 0 }) else { return empty }
        let e1 = CGPoint(x: polygon[1].x - polygon[0].x, y: polygon[1].y - polygon[0].y)
        let e3 = CGPoint(x: polygon[3].x - polygon[0].x, y: polygon[3].y - polygon[0].y)
        let edge = hypot(e1.x, e1.y) >= hypot(e3.x, e3.y) ? e1 : e3
        let length = hypot(edge.x, edge.y)
        guard length.isFinite, length > 0 else { return empty }
        let along = CGPoint(x: edge.x / length, y: edge.y / length)
        let normal = CGPoint(x: along.y, y: -along.x)
        let origin = CGPoint(x: polygon.reduce(0) { $0 + $1.x } / 4, y: polygon.reduce(0) { $0 + $1.y } / 4)
        func project(_ p: CGPoint) -> CGPoint {
            let x = p.x - origin.x, y = p.y - origin.y
            return .init(x: x * normal.x + y * normal.y, y: x * along.x + y * along.y)
        }
        let local = polygon.map(project), width = span(local.map(\.x)), height = span(local.map(\.y))
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return empty }
        var winner: Scope?, bestRank: [Double] = [], bestIntersection: CGFloat = 0
        for scope in scopes {
            let r = scope.rect
            guard scope.semanticClass == 0, scope.confidence.isFinite, scope.confidence >= 0.5,
                  [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite), r.width > 0, r.height > 0 else { continue }
            let intersection = area(clipped(polygon, to: r)), scopeArea = r.width * r.height
            guard intersection.isFinite, intersection > 0, scopeArea.isFinite else { continue }
            let iou = Double(intersection / (sourceArea + scopeArea - intersection))
            let rank = [iou * scope.confidence, iou, scope.confidence, -Double(scopeArea), -Double(r.minX), -Double(r.minY)]
            if winner == nil || lexGreater(rank, bestRank) {
                winner = scope; bestRank = rank; bestIntersection = intersection
            }
        }
        guard let scope = winner else { return empty }
        let r = scope.rect, corners = [CGPoint(x:r.minX,y:r.minY), CGPoint(x:r.maxX,y:r.minY),
            CGPoint(x:r.maxX,y:r.maxY), CGPoint(x:r.minX,y:r.maxY)].map(project)
        let center = project(.init(x:r.midX,y:r.midY))
        let values = [1, scope.confidence, Double(bestIntersection / sourceArea), Double(bestIntersection / (r.width * r.height)),
            Double(span(corners.map(\.x)) / width), Double(span(corners.map(\.y)) / height), Double(center.x / width), Double(center.y / width)]
        return values.allSatisfy(\.isFinite) ? values : empty
    }
    private static func lexGreater(_ a: [Double], _ b: [Double]) -> Bool {
        for (x, y) in zip(a, b) { if x != y { return x > y } }
        return false
    }
    private static func span(_ values: [CGFloat]) -> CGFloat { (values.max() ?? 0) - (values.min() ?? 0) }
    private static func area(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        // Translate before summing to reduce cancellation for small far-from-origin crops.
        let origin = points[0]
        return abs(points.indices.reduce(CGFloat(0)) { sum, i in
            let a = points[i], b = points[(i + 1) % points.count]
            return sum + (a.x - origin.x) * (b.y - origin.y) - (b.x - origin.x) * (a.y - origin.y)
        }) / 2
    }
    private static func clipped(_ points: [CGPoint], to rect: CGRect) -> [CGPoint] {
        var result = points
        for axis in [0, 1] {
            for lower in [true, false] {
                let bound = axis == 0 ? (lower ? rect.minX : rect.maxX) : (lower ? rect.minY : rect.maxY)
                func value(_ p: CGPoint) -> CGFloat { axis == 0 ? p.x : p.y }
                func inside(_ p: CGPoint) -> Bool { lower ? value(p) >= bound : value(p) <= bound }
                let input = result; result = []
                guard let last = input.last else { return [] }
                var previous = last
                for current in input {
                    let oldInside = inside(previous), newInside = inside(current)
                    if oldInside != newInside {
                        let divisor = value(current) - value(previous)
                        guard divisor.isFinite, divisor != 0 else { return [] }
                        let t = (bound - value(previous)) / divisor
                        result.append(.init(x: previous.x + t * (current.x - previous.x),
                                            y: previous.y + t * (current.y - previous.y)))
                    }
                    if newInside { result.append(current) }
                    previous = current
                }
            }
        }
        return result
    }
}


/// Conservative source-only prefix admission; fallback is ENTIRE inherited policy.
/// No ownership/GT/palette/identity input. Retain both original along endpoints
/// within a one-source-pixel raster tolerance, independent of winding/sign.
enum NativeOCRNoAlongEndLoss {
    static func allows(inherited: [CGPoint], proposed: [CGPoint], fringe: CGFloat = 1) -> Bool {
        guard inherited.count == 4, proposed.count == 4, fringe.isFinite, fringe >= 0,
              (inherited + proposed).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        func convex(_ q: [CGPoint]) -> Bool {
            let c = q.indices.map { i -> CGFloat in
                let a = q[i], b = q[(i + 1) % 4], d = q[(i + 2) % 4]
                return (b.x-a.x)*(d.y-b.y)-(b.y-a.y)*(d.x-b.x)
            }
            return c.allSatisfy({ $0 > 1e-7 }) || c.allSatisfy({ $0 < -1e-7 })
        }
        guard convex(inherited), convex(proposed) else { return false }
        let a = CGPoint(x: inherited[1].x-inherited[0].x, y: inherited[1].y-inherited[0].y)
        let b = CGPoint(x: inherited[3].x-inherited[0].x, y: inherited[3].y-inherited[0].y)
        let e = hypot(a.x,a.y) >= hypot(b.x,b.y) ? a : b
        let length = hypot(e.x,e.y)
        guard length.isFinite, length > 0 else { return false }
        let origin = inherited[0]
        func projection(_ p: CGPoint) -> CGFloat {
            (p.x-origin.x)*(e.x/length)+(p.y-origin.y)*(e.y/length)
        }
        let before = inherited.map(projection), after = proposed.map(projection)
        return after.min()! <= before.min()! + fringe + 1e-7 &&
            after.max()! >= before.max()! - fringe - 1e-7
    }
}

/// Optional selection of already safe/semantic-admitted peer chains. No generation/admission change.
@available(iOS 18.0, *)
enum NativeOCRResidualPeerChainSelection {
    static let reachableKeys: Set<String> = [
        "peer-chain-v1-p2-head-rf050-sfx060-balloon090-gap1p6-offset0p22",
        "peer-chain-v1-p2-tail-rf050-sfx060-balloon090-gap1p6-offset0p22",
        "peer-chain-v1-p3-head-rf050-sfx060-balloon090-gap1p6-offset0p22",
        "peer-chain-v1-p3-tail-rf050-sfx060-balloon090-gap1p6-offset0p22",
        "peer-chain-v1-p3-both-rf050-sfx060-balloon090-gap1p6-offset0p22",
        "peer-chain-v1-p4-head-rf050-sfx060-balloon090-gap1p6-offset0p22",
        "peer-chain-v1-p4-tail-rf050-sfx060-balloon090-gap1p6-offset0p22",
        "peer-chain-v1-p4-both-rf050-sfx060-balloon090-gap1p6-offset0p22",
    ]
    static func preferred(_ admitted: [NativeOCRResidualCandidate], features: [Double]) -> NativeOCRResidualCandidate? {
        guard features.count >= 22, features[21].isFinite, features[21] >= 0.94 else { return nil }
        return admitted.filter {
            reachableKeys.contains($0.key) && (1...3).contains($0.consumedIndices.count) &&
                Set($0.consumedIndices).count == $0.consumedIndices.count &&
                $0.polygon.count == 4 && $0.polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }.sorted { a, b in
            if a.consumedIndices.count != b.consumedIndices.count {
                return a.consumedIndices.count > b.consumedIndices.count
            }
            let aa = area(a.polygon), bb = area(b.polygon)
            return aa == bb ? a.key < b.key : aa < bb
        }.first
    }
    private static func area(_ q: [CGPoint]) -> Double {
        // Subtract a common vertex to avoid cancellation at large source coordinates.
        let o = q[0]
        var twice: Double = 0
        for i in 0..<q.count {
            let a = q[i], b = q[(i + 1) % q.count]
            twice += Double((a.x-o.x)*(b.y-o.y) - (b.x-o.x)*(a.y-o.y))
        }
        return abs(twice) * 0.5
    }
}

@available(iOS 18.0, *)
extension NativeOCRResidualPrioritySelection {
    // Ordered shared rules: latest EFFECTIVE matching rule wins; a miss retains
    // all prior same-class rules, then the COMPLETE actualv3259470 parent policy.
    static func selectR3AngleEnvelope80Child(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let sourceClass:String;let cuts:[Cut];let key:String}
        enum Table {static let rules:[Rule]=[
            Rule(sourceClass: "2|medium|fit|fit", cuts: [], key: "angle-envelope-v1-m1-r0-n0-a0"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 17, threshold: 0.15252525, lessOrEqual: false), Cut(feature: 19, threshold: 0.045867329999999998, lessOrEqual: true)], key: "angle-envelope-v1-p4-r0-n10-a10"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 4, threshold: 0.46405984235408404, lessOrEqual: true), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "angle-envelope-v1-p4-r1-n25-a25"),
            Rule(sourceClass: "0|medium|fit|short", cuts: [Cut(feature: 51, threshold: 3.3488372100000001, lessOrEqual: true), Cut(feature: 10, threshold: -0.080000000000000002, lessOrEqual: true)], key: "angle-envelope-v1-p1-r1-n0-a0"),
            Rule(sourceClass: "1|medium|fit|fit", cuts: [Cut(feature: 27, threshold: 1.2557525599999999, lessOrEqual: true), Cut(feature: 24, threshold: 0.98947819000000004, lessOrEqual: true)], key: "angle-envelope-v1-m2-r0-n0-a0"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 10, threshold: 0.048275862068965468, lessOrEqual: false), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "angle-envelope-v1-m2-r0-n0-a0"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 7, threshold: 0.080937245175425637, lessOrEqual: false), Cut(feature: 13, threshold: 0.050000000000000003, lessOrEqual: false)], key: "angle-envelope-v1-p05-r0-n0-a05"),
        ]}
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}),incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values+rfText
        for f in 16..<30 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        func value(_ f:Int)->Double? {
            if f>=0 && f<v.count{return v[f]}
            guard f==51 else{return nil}
            let raw=v[1]*v[3]/max(1e-9,abs(v[2])),scaled=raw*100000000.0
            guard scaled.isFinite else{return nil}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return nil}
            return rounded==0 ? 0:rounded
        }
        var selected:NativeOCRResidualCandidate? = nil
        for rule in Table.rules.reversed() where rule.sourceClass==sourceClass {
            var match=true
            for cut in rule.cuts {
                guard let x=value(cut.feature),cut.lessOrEqual ? x<=cut.threshold:x>cut.threshold else {match=false;break}
            }
            guard match,let q=candidates.first(where:{$0.key==rule.key}),q.consumedIndices.isEmpty,
                  q.polygon.count==4,q.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),!sameQuad(q.polygon,incoming) else{continue}
            selected=q;break
        }
        guard let chosen=selected else{return inherited()}
        let priorPreferred=inherited()
        var priorPolygon=priorPreferred?.polygon
        if priorPolygon==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys=encoded.components(separatedBy:" >> ")
            if rankedKeys.count<=3 && rankedKeys.allSatisfy({!$0.isEmpty}) {
                for key in rankedKeys {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if rankedKeys.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    priorPolygon=q.polygon;break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited:priorPolygon ?? incoming,proposed:chosen.polygon) else{return priorPreferred}
        return chosen
    }

}

@available(iOS 18.0, *)
extension NativeOCRResidualPrioritySelection {
    // Ordered shared rules: latest EFFECTIVE matching rule wins; a miss retains
    // all prior same-class rules, then the COMPLETE actual9479 parent policy.
    static func selectActual9479OldMenu80Child(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let sourceClass:String;let cuts:[Cut];let key:String}
        enum Table {static let rules:[Rule]=[
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 11, threshold: -0.040000000000000001, lessOrEqual: true), Cut(feature: 25, threshold: 0.24787401000000001, lessOrEqual: false)], key: "support-blend-v1-axis-bins-envelope-v1-half-f75"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 7, threshold: 0.024495890911581497, lessOrEqual: true), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "side-envelope-v1-right-grid"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 3, threshold: 0.87667762537492089, lessOrEqual: true), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "normal-complete-v1-s050-w010"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 23, threshold: 0.93336713000000004, lessOrEqual: false), Cut(feature: 25, threshold: 0.35706465999999998, lessOrEqual: false)], key: "axis-bins-envelope-v1-half"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 11, threshold: 0.0051739762877686547, lessOrEqual: false), Cut(feature: 29, threshold: -0.026982059999999999, lessOrEqual: true)], key: "support-blend-v1-side-envelope-v1-right-ink-quarter-f75"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 23, threshold: 0.77354853999999995, lessOrEqual: true), Cut(feature: 25, threshold: 0.45827066999999999, lessOrEqual: false), Cut(feature: 5, threshold: 31, lessOrEqual: false)], key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 14, threshold: 0, lessOrEqual: false), Cut(feature: 26, threshold: 2.1182556199999998, lessOrEqual: true), Cut(feature: 23, threshold: 0.77121156000000002, lessOrEqual: true)], key: "terminal-tail-side-joint-v1|side-envelope-v1-normal-tail-grid|terminal-tail-palette-gap065-reach3-v1"),
        ]}
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}),incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values+rfText
        for f in 16..<30 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        func value(_ f:Int)->Double? {
            guard f>=0,f<v.count else{return nil}
            return v[f]
        }
        var selected:NativeOCRResidualCandidate? = nil
        for rule in Table.rules.reversed() where rule.sourceClass==sourceClass {
            var match=true
            for cut in rule.cuts {
                guard let x=value(cut.feature),cut.lessOrEqual ? x<=cut.threshold:x>cut.threshold else {match=false;break}
            }
            guard match,let q=candidates.first(where:{$0.key==rule.key}),q.consumedIndices.isEmpty,
                  q.polygon.count==4,q.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),!sameQuad(q.polygon,incoming) else{continue}
            selected=q;break
        }
        guard let chosen=selected else{return inherited()}
        let priorPreferred=inherited()
        var priorPolygon=priorPreferred?.polygon
        if priorPolygon==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys=encoded.components(separatedBy:" >> ")
            if rankedKeys.count<=3 && rankedKeys.allSatisfy({!$0.isEmpty}) {
                for key in rankedKeys {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if rankedKeys.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    priorPolygon=q.polygon;break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited:priorPolygon ?? incoming,proposed:chosen.polygon) else{return priorPreferred}
        return chosen
    }


    static func selectV327Common90Recovery(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let sourceClass:String;let cuts:[Cut];let key:String}
        enum Table {static let rules:[Rule]=[
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 17, threshold: 0.15252525, lessOrEqual: false), Cut(feature: 18, threshold: 0.070026660000000004, lessOrEqual: true)], key: "normal-complete-v1-s050-w010|enclose25"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 2, threshold: 0.75354170692106803, lessOrEqual: false), Cut(feature: 5, threshold: 23, lessOrEqual: false)], key: "input-footprint-v1-original-axis-normal-current-along"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 3, threshold: 0.9281612562990742, lessOrEqual: true), Cut(feature: 50, threshold: 0.01274409, lessOrEqual: true)], key: "input-footprint-v1-original-axis-normal-current-along"),
            Rule(sourceClass: "0|medium|wide|fit", cuts: [Cut(feature: 20, threshold: 0, lessOrEqual: false), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "side-envelope-v1-normal-grid"),
            Rule(sourceClass: "1|long|fit|fit", cuts: [Cut(feature: 25, threshold: 0.19530744999999999, lessOrEqual: false), Cut(feature: 20, threshold: -0.14631479, lessOrEqual: true)], key: "support-blend-v1-axis-bins-center-v1-retain-span-f50"),
            Rule(sourceClass: "0|medium|wide|fit", cuts: [Cut(feature: 7, threshold: 0.029055772975002774, lessOrEqual: true), Cut(feature: 27, threshold: 0.95372442000000002, lessOrEqual: true)], key: "support-margin-v1-n0-a0"),
            Rule(sourceClass: "1|long|fit|fit", cuts: [Cut(feature: 28, threshold: 0, lessOrEqual: false), Cut(feature: 26, threshold: 1.1472741, lessOrEqual: true)], key: "support-minrect-v1-bounded-mar-tight-p0"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 2, threshold: 0.64585622333257531, lessOrEqual: true), Cut(feature: 10, threshold: -0.043836302537910307, lessOrEqual: true)], key: "support-margin-v1-n10-a15"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 4, threshold: 0.46405984235408404, lessOrEqual: true), Cut(feature: 19, threshold: 0, lessOrEqual: true)], key: "support-minrect-v1-incoming-axis-control-retain-span-p1"),
            Rule(sourceClass: "1|long|fit|fit", cuts: [Cut(feature: 0, threshold: 0.81381779261785125, lessOrEqual: false), Cut(feature: 26, threshold: 1.1472741, lessOrEqual: true)], key: "support-minrect-v1-bounded-mar-retain-span-p0"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 2, threshold: 0.50873908628616393, lessOrEqual: true), Cut(feature: 49, threshold: 11, lessOrEqual: false)], key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 17, threshold: 0, lessOrEqual: true), Cut(feature: 24, threshold: 0.80975794999999995, lessOrEqual: true)], key: "normal-complete-v1-s100-w025"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 49, threshold: 6, lessOrEqual: true), Cut(feature: 50, threshold: 0.068305350000000001, lessOrEqual: true)], key: "support-blend-v1-side-envelope-v1-left-grid-f75"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 3, threshold: 0.86326491839842501, lessOrEqual: true), Cut(feature: 18, threshold: 0.070026660000000004, lessOrEqual: true)], key: "support-blend-v1-side-envelope-v1-normal-ink-half-f50"),
            Rule(sourceClass: "0|medium|wide|fit", cuts: [Cut(feature: 6, threshold: 1.3196781596584799, lessOrEqual: false), Cut(feature: 16, threshold: 0, lessOrEqual: false)], key: "terminal-trim-v1|tail|pad04|enclose25"),
            Rule(sourceClass: "0|medium|fit|short", cuts: [Cut(feature: 21, threshold: 0.86964923999999999, lessOrEqual: true), Cut(feature: 50, threshold: 0.12146089, lessOrEqual: false)], key: "support-blend-v1-side-envelope-v1-left-grid-f75"),
            Rule(sourceClass: "2|long|fit|fit", cuts: [Cut(feature: 3, threshold: 0.99743675390811004, lessOrEqual: false), Cut(feature: 19, threshold: 0, lessOrEqual: true)], key: "axis-bins-envelope-v1-half"),
            Rule(sourceClass: "1|medium|fit|fit", cuts: [Cut(feature: 21, threshold: 0.91932501, lessOrEqual: false), Cut(feature: 26, threshold: 4.0212344099999999, lessOrEqual: true)], key: "support-minrect-v1-bounded-mar-tight-p05"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 14, threshold: 0.050000000000000003, lessOrEqual: false), Cut(feature: 26, threshold: 3.0381052099999999, lessOrEqual: true)], key: "terminal-tail-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 2, threshold: 0.89130434782608692, lessOrEqual: true), Cut(feature: 10, threshold: 0.080000000000000002, lessOrEqual: false)], key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 17, threshold: 0.15252525, lessOrEqual: false), Cut(feature: 19, threshold: 0.045867329999999998, lessOrEqual: true)], key: "normal-complete-v1-s050-w010|enclose25"),
            Rule(sourceClass: "1|medium|fit|fit", cuts: [Cut(feature: 10, threshold: 0.03898509683812685, lessOrEqual: true), Cut(feature: 24, threshold: 0.98947819000000004, lessOrEqual: true)], key: "support-minrect-v1-bounded-mar-tight-p1"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 14, threshold: 0, lessOrEqual: false), Cut(feature: 25, threshold: 0.34056893999999999, lessOrEqual: false)], key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 4, threshold: 0.52105948072315966, lessOrEqual: false), Cut(feature: 5, threshold: 23, lessOrEqual: false)], key: "side-envelope-v1-right-ink-half|enclose25"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 11, threshold: -0.040000000000000001, lessOrEqual: true), Cut(feature: 29, threshold: 0.052407330000000002, lessOrEqual: true)], key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 28, threshold: -1.0122070299999999, lessOrEqual: true), Cut(feature: 50, threshold: 0.072333919999999996, lessOrEqual: false)], key: "scope-terminal-tail-rf075-u015-c060-v1"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 10, threshold: 0.080000000000000002, lessOrEqual: false), Cut(feature: 24, threshold: 0.89791949000000004, lessOrEqual: true)], key: "input-footprint-v1-original-direct"),
        ]}
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}),incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values+rfText
        for f in 16..<30 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        func value(_ f:Int)->Double? {
            if f<30{return v[f]}
            let raw:Double
            if f==46 {raw=v[5]/max(1,v[1])}
            else if f==47 {raw=v[10]/max(1e-9,abs(v[2]))}
            else if f==48 {raw=v[11]/max(1e-9,abs(v[3]))}
            else if f==49 {raw=v[5]/max(1,v[1]*max(1e-9,abs(v[3])))}
            else if f==50 {raw=hypot(v[10]/max(1e-9,abs(v[2])),v[11]/max(1e-9,abs(v[3])))}
            else if f==51 {raw=v[1]*v[3]/max(1e-9,abs(v[2]))}
            else{return nil}
            let scaled=raw*100000000.0
            guard scaled.isFinite else{return nil}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            return rounded.isFinite ? (rounded==0 ? 0:rounded):nil
        }
        var selected:NativeOCRResidualCandidate? = nil
        for rule in Table.rules.reversed() where rule.sourceClass==sourceClass {
            var match=true
            for cut in rule.cuts {
                guard let x=value(cut.feature),cut.lessOrEqual ? x<=cut.threshold:x>cut.threshold else {match=false;break}
            }
            guard match,let q=candidates.first(where:{$0.key==rule.key}),q.consumedIndices.isEmpty,
                  q.polygon.count==4,q.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),!sameQuad(q.polygon,incoming) else{continue}
            selected=q;break
        }
        guard let chosen=selected else{return inherited()}
        let priorPreferred=inherited()
        var priorPolygon=priorPreferred?.polygon
        if priorPolygon==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys=encoded.components(separatedBy:" >> ")
            if rankedKeys.count<=3 && rankedKeys.allSatisfy({!$0.isEmpty}) {
                for key in rankedKeys {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if rankedKeys.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    priorPolygon=q.polygon;break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited:priorPolygon ?? incoming,proposed:chosen.polygon) else{return priorPreferred}
        return chosen
    }



    // Call after authentic peer-first. inherited() is ENTIRE actual v327.
    static func selectV327CombinedOldMenu80Then90(_ values:[Double], rfText:[Double],
        candidates:[NativeOCRResidualCandidate], incoming:[CGPoint],
        inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        let prior=inherited()
        var baseline=prior?.polygon
        if baseline==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let ranked=encoded.components(separatedBy:" >> ")
            if ranked.count<=3 && ranked.allSatisfy({!$0.isEmpty}) {
                for key in ranked {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if ranked.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    baseline=q.polygon;break
                }
            }
        }
        let p80=selectActual9479OldMenu80Child(values,rfText:rfText,candidates:candidates,
            incoming:incoming,inherited:{prior})
        if let q=p80,!sameQuad(q.polygon,baseline ?? incoming) {return q}
        let p90=selectV327Common90Recovery(values,rfText:rfText,candidates:candidates,
            incoming:incoming,inherited:{prior})
        if let q=p90,!sameQuad(q.polygon,baseline ?? incoming) {return q}
        return prior
    }

}

@available(iOS 18.0, *)
extension NativeOCRResidualPrioritySelection {
    // Ordered shared rules: latest EFFECTIVE matching rule wins; a miss retains
    // all prior same-class rules, then the COMPLETE actual9486 parent policy.
    static func selectActual9486Padding80Child(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let sourceClass:String;let cuts:[Cut];let key:String}
        enum Table {static let rules:[Rule]=[
            Rule(sourceClass: "0|long|fit|short", cuts: [], key: "angle-padding-v1-0-r0-tail20"),
            Rule(sourceClass: "1|medium|fit|short", cuts: [], key: "angle-padding-v1-0-r1-tail20"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 6, threshold: 1, lessOrEqual: false), Cut(feature: 28, threshold: -1.0122070299999999, lessOrEqual: true)], key: "angle-padding-v1-m05-r0-head20"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 0, threshold: 0.94738674807400525, lessOrEqual: false), Cut(feature: 21, threshold: 0.96714957999999995, lessOrEqual: false)], key: "angle-padding-v1-0-r0-right20"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 28, threshold: 1.3335905299999999, lessOrEqual: false), Cut(feature: 29, threshold: -0.099338940000000001, lessOrEqual: true)], key: "angle-padding-v1-0-r0-right20"),
        ]}
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}),incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values+rfText
        for f in 16..<30 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        func value(_ f:Int)->Double? {
            guard f>=0,f<v.count else{return nil}
            return v[f]
        }
        var selected:NativeOCRResidualCandidate? = nil
        for rule in Table.rules.reversed() where rule.sourceClass==sourceClass {
            var match=true
            for cut in rule.cuts {
                guard let x=value(cut.feature),cut.lessOrEqual ? x<=cut.threshold:x>cut.threshold else {match=false;break}
            }
            guard match,let q=candidates.first(where:{$0.key==rule.key}),q.consumedIndices.isEmpty,
                  q.polygon.count==4,q.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),!sameQuad(q.polygon,incoming) else{continue}
            selected=q;break
        }
        guard let chosen=selected else{return inherited()}
        let priorPreferred=inherited()
        var priorPolygon=priorPreferred?.polygon
        if priorPolygon==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys=encoded.components(separatedBy:" >> ")
            if rankedKeys.count<=3 && rankedKeys.allSatisfy({!$0.isEmpty}) {
                for key in rankedKeys {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if rankedKeys.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    priorPolygon=q.polygon;break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited:priorPolygon ?? incoming,proposed:chosen.polygon) else{return priorPreferred}
        return chosen
    }

    static func selectV328Common90Recovery(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let sourceClass:String;let cuts:[Cut];let key:String}
        enum Table {static let rules:[Rule]=[
            Rule(sourceClass: "1|long|fit|fit", cuts: [], key: "support-blend-v1-side-envelope-v1-full-ink-quarter-f75"),
            Rule(sourceClass: "1|medium|fit|fit", cuts: [Cut(feature: 27, threshold: 1.2557525599999999, lessOrEqual: true), Cut(feature: 24, threshold: 0.98947819000000004, lessOrEqual: true)], key: "normal-complete-v1-s050-w010|enclose25"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 0, threshold: 0.90071588136372627, lessOrEqual: false), Cut(feature: 51, threshold: 2.5714285700000001, lessOrEqual: true)], key: "asymmetric-support-v1-p60"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 23, threshold: 0.88162004999999999, lessOrEqual: false), Cut(feature: 26, threshold: 0.97729043000000004, lessOrEqual: true)], key: "side-envelope-v1-right-ink-half"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 1, threshold: 2.1543622488966334, lessOrEqual: false), Cut(feature: 20, threshold: 5.9833436500000001, lessOrEqual: false)], key: "support-blend-v1-side-envelope-v1-right-ink-half-f50"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 3, threshold: 0.87703019283489914, lessOrEqual: true), Cut(feature: 11, threshold: 0.019833405030523228, lessOrEqual: false)], key: "input-footprint-v1-original-direct"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 5, threshold: 19, lessOrEqual: false), Cut(feature: 20, threshold: 4.7924514900000004, lessOrEqual: false)], key: "input-footprint-v1-original-direct"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 0, threshold: 0.91993089781293835, lessOrEqual: false), Cut(feature: 25, threshold: 0.20829550999999999, lessOrEqual: false)], key: "support-blend-v1-side-envelope-v1-left-ink-half-f50"),
            Rule(sourceClass: "0|medium|fit|short", cuts: [Cut(feature: 0, threshold: 0.93315554490511932, lessOrEqual: false), Cut(feature: 24, threshold: 0.91689425000000002, lessOrEqual: true)], key: "normal-complete-v1-s100-w025|enclose25"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 3, threshold: 0.9256987912727177, lessOrEqual: false), Cut(feature: 5, threshold: 19, lessOrEqual: false)], key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 3, threshold: 0.94974573736165102, lessOrEqual: true), Cut(feature: 9, threshold: 0, lessOrEqual: true)], key: "terminal-tail-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 4, threshold: 0.52225489812400927, lessOrEqual: false), Cut(feature: 5, threshold: 8, lessOrEqual: true)], key: "input-footprint-v1-original-rf-text-c050-r1-normal-current-along"),
        ]}
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}),incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values+rfText
        for f in 16..<30 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        func value(_ f:Int)->Double? {
            if f<30{return v[f]}
            let raw:Double
            if f==46 {raw=v[5]/max(1,v[1])}
            else if f==47 {raw=v[10]/max(1e-9,abs(v[2]))}
            else if f==48 {raw=v[11]/max(1e-9,abs(v[3]))}
            else if f==49 {raw=v[5]/max(1,v[1]*max(1e-9,abs(v[3])))}
            else if f==50 {raw=hypot(v[10]/max(1e-9,abs(v[2])),v[11]/max(1e-9,abs(v[3])))}
            else if f==51 {raw=v[1]*v[3]/max(1e-9,abs(v[2]))}
            else{return nil}
            let scaled=raw*100000000.0
            guard scaled.isFinite else{return nil}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            return rounded.isFinite ? (rounded==0 ? 0:rounded):nil
        }
        var selected:NativeOCRResidualCandidate? = nil
        for rule in Table.rules.reversed() where rule.sourceClass==sourceClass {
            var match=true
            for cut in rule.cuts {
                guard let x=value(cut.feature),cut.lessOrEqual ? x<=cut.threshold:x>cut.threshold else {match=false;break}
            }
            guard match,let q=candidates.first(where:{$0.key==rule.key}),q.consumedIndices.isEmpty,
                  q.polygon.count==4,q.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),!sameQuad(q.polygon,incoming) else{continue}
            selected=q;break
        }
        guard let chosen=selected else{return inherited()}
        let priorPreferred=inherited()
        var priorPolygon=priorPreferred?.polygon
        if priorPolygon==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys=encoded.components(separatedBy:" >> ")
            if rankedKeys.count<=3 && rankedKeys.allSatisfy({!$0.isEmpty}) {
                for key in rankedKeys {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if rankedKeys.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    priorPolygon=q.polygon;break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited:priorPolygon ?? incoming,proposed:chosen.polygon) else{return priorPreferred}
        return chosen
    }


    // Call after authentic peer-first. inherited() is ENTIRE actual v328.
    static func selectV328CombinedPadding80Then90(_ values:[Double], rfText:[Double],
        candidates:[NativeOCRResidualCandidate], incoming:[CGPoint],
        inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        let prior=inherited()
        var baseline=prior?.polygon
        if baseline==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let ranked=encoded.components(separatedBy:" >> ")
            if ranked.count<=3 && ranked.allSatisfy({!$0.isEmpty}) {
                for key in ranked {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if ranked.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    baseline=q.polygon;break
                }
            }
        }
        let p80=selectActual9486Padding80Child(values,rfText:rfText,candidates:candidates,
            incoming:incoming,inherited:{prior})
        if let q=p80,!sameQuad(q.polygon,baseline ?? incoming) {return q}
        let p90=selectV328Common90Recovery(values,rfText:rfText,candidates:candidates,
            incoming:incoming,inherited:{prior})
        if let q=p90,!sameQuad(q.polygon,baseline ?? incoming) {return q}
        return prior
    }

    static func selectPruned9491Common80Child(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let sourceClass:String;let cuts:[Cut];let key:String}
        enum Table {static let rules:[Rule]=[
            Rule(sourceClass: "0|medium|fit|fit", cuts: [], key: "evidence-forward-v1-side-envelope-v1-normal-head-ink-quarter"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 3, threshold: 0.94974573736165102, lessOrEqual: true), Cut(feature: 7, threshold: 0.059951620466011782, lessOrEqual: false)], key: "angle-padding-v1-m05-r1-head20"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 11, threshold: -0.015455976271221462, lessOrEqual: true), Cut(feature: 19, threshold: 0.10794777999999999, lessOrEqual: false)], key: "support-minrect-v1-bounded-mar-tight-p05"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 7, threshold: 0.022534907561808797, lessOrEqual: true), Cut(feature: 18, threshold: 0.15077752, lessOrEqual: false)], key: "support-blend-v1-side-envelope-v1-normal-ink-quarter-f50"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 5, threshold: 15, lessOrEqual: false), Cut(feature: 18, threshold: 0.0015671400000000001, lessOrEqual: true), Cut(feature: 1, threshold: 2.4997455191409554, lessOrEqual: true)], key: "angle-padding-v1-m05-r1-right20"),
            Rule(sourceClass: "0|long|fit|fit", cuts: [Cut(feature: 1, threshold: 10.980835306101678, lessOrEqual: false), Cut(feature: 21, threshold: 0.91711030999999998, lessOrEqual: true), Cut(feature: 28, threshold: 0.04827269, lessOrEqual: true)], key: "asymmetric-support-v1-p66"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 2, threshold: 0.7539970579198213, lessOrEqual: false), Cut(feature: 26, threshold: 0.97729043000000004, lessOrEqual: true), Cut(feature: 1, threshold: 3.6147264159045331, lessOrEqual: true)], key: "normal-complete-v1-s050-w010"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 1, threshold: 6.3207403206162649, lessOrEqual: false), Cut(feature: 37, threshold: 0.87210884, lessOrEqual: false), Cut(feature: 26, threshold: 4.5885358500000004, lessOrEqual: false)], key: "evidence-forward-v1-support-minrect-v1-bounded-mar-retain-span-p1"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 27, threshold: 1.0080943200000001, lessOrEqual: true), Cut(feature: 33, threshold: 0.0026860400000000002, lessOrEqual: false), Cut(feature: 1, threshold: 4.0033066272687474, lessOrEqual: false)], key: "evidence-forward-v1-side-envelope-v1-left-grid"),
            Rule(sourceClass: "0|medium|narrow|short", cuts: [Cut(feature: 4, threshold: 0.42580202080461171, lessOrEqual: true), Cut(feature: 24, threshold: 0.87606448000000003, lessOrEqual: true), Cut(feature: 0, threshold: 0.85316998837615354, lessOrEqual: true)], key: "angle-envelope-v1-m05-r1-n0-a0"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 0, threshold: 0.85412665071516591, lessOrEqual: true), Cut(feature: 6, threshold: 1.4143021957696438, lessOrEqual: false), Cut(feature: 18, threshold: 0.12378809, lessOrEqual: false)], key: "angle-envelope-v1-m1-r1-n0-a0"),
            Rule(sourceClass: "0|medium|narrow|short", cuts: [Cut(feature: 18, threshold: 0.16146956000000001, lessOrEqual: false), Cut(feature: 23, threshold: 0.70309924999999995, lessOrEqual: true), Cut(feature: 46, threshold: 6.82378135, lessOrEqual: true)], key: "angle-padding-v1-0-r0-head20"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 3, threshold: 0.9281612562990742, lessOrEqual: true), Cut(feature: 28, threshold: 1.3335905299999999, lessOrEqual: false), Cut(feature: 1, threshold: 10.23867924528302, lessOrEqual: false)], key: "angle-envelope-v1-0-r0-n10-a10"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 0, threshold: 0.93428431941855361, lessOrEqual: false), Cut(feature: 24, threshold: 0.80975794999999995, lessOrEqual: true), Cut(feature: 27, threshold: 1.18274345, lessOrEqual: true)], key: "asymmetric-support-v1-p33"),
        ]}
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}),incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values+rfText
        for f in 16..<30 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        // Source-only canonical geometry; no GT and no ownership/erasure claims.
        func canonicalOffsetAndCoverage()->(Double,Double) {
            guard let c=candidates.first(where:{$0.key=="evidence-forward-v1-support-minrect-v1-bounded-mar-retain-span-p0"}),c.consumedIndices.isEmpty,c.polygon.count==4,c.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return (0,0)}
            let p=incoming,q=c.polygon
            func cross(_ a:CGPoint,_ b:CGPoint,_ c:CGPoint)->Double {Double((b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x))}
            func signedArea(_ p:[CGPoint])->Double {guard p.count>=3 else{return 0};var s=0.0;for i in p.indices {let j=(i+1)%p.count;s+=Double(p[i].x*p[j].y-p[j].x*p[i].y)};return s/2}
            let area=abs(signedArea(p));guard area.isFinite,area>0,abs(signedArea(q))>0 else{return (0,0)}
            let e1=CGPoint(x:p[1].x-p[0].x,y:p[1].y-p[0].y),e3=CGPoint(x:p[3].x-p[0].x,y:p[3].y-p[0].y)
            let e=hypot(e1.x,e1.y)>=hypot(e3.x,e3.y) ? e1:e3,n=hypot(e.x,e.y)
            guard n.isFinite,n>0 else{return (0,0)}
            let normal=CGPoint(x:e.y/n,y:-e.x/n)
            let origin=CGPoint(x:p.reduce(0){$0+$1.x}/4,y:p.reduce(0){$0+$1.y}/4)
            let center=CGPoint(x:q.reduce(0){$0+$1.x}/4,y:q.reduce(0){$0+$1.y}/4)
            let projections=p.map{Double(($0.x-origin.x)*normal.x+($0.y-origin.y)*normal.y)}
            let width=projections.max()!-projections.min()!;guard width>0,width.isFinite else{return (0,0)}
            let offset=Double((center.x-origin.x)*normal.x+(center.y-origin.y)*normal.y)/width
            var clipped=p;let orientation=signedArea(q)>=0 ? 1.0 : -1.0
            for i in 0..<4 {
                guard !clipped.isEmpty else{break}
                let a=q[i],b=q[(i+1)%4];var output:[CGPoint]=[]
                var prev=clipped.last!,dp=orientation*cross(a,b,prev)
                for point in clipped {
                    let dc=orientation*cross(a,b,point)
                    if (dp>=0) != (dc>=0) {let t=dp/(dp-dc);output.append(CGPoint(x:prev.x+CGFloat(t)*(point.x-prev.x),y:prev.y+CGFloat(t)*(point.y-prev.y)))}
                    if dc>=0 {output.append(point)}
                    prev=point;dp=dc
                }
                clipped=output
            }
            let coverage=abs(signedArea(clipped))/area
            return (offset,coverage)
        }
        func routed(_ x:Double)->Double? {
            let scaled=x*100000000.0;guard scaled.isFinite else{return nil}
            let result=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard result.isFinite else{return nil};return result==0 ? 0:result
        }
        func value(_ f:Int)->Double? {
            if f==46 {return routed(v[5]/max(1,v[1]))}
            if f==33 || f==37 {let pair=canonicalOffsetAndCoverage();return routed(f==33 ? pair.0:pair.1)}
            guard f>=0,f<v.count else{return nil}
            return v[f]
        }
        var selected:NativeOCRResidualCandidate? = nil
        for rule in Table.rules.reversed() where rule.sourceClass==sourceClass {
            var match=true
            for cut in rule.cuts {
                guard let x=value(cut.feature),cut.lessOrEqual ? x<=cut.threshold:x>cut.threshold else {match=false;break}
            }
            guard match,let q=candidates.first(where:{$0.key==rule.key}),q.consumedIndices.isEmpty,
                  q.polygon.count==4,q.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),!sameQuad(q.polygon,incoming) else{continue}
            selected=q;break
        }
        guard let chosen=selected else{return inherited()}
        let priorPreferred=inherited()
        var priorPolygon=priorPreferred?.polygon
        if priorPolygon==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys=encoded.components(separatedBy:" >> ")
            if rankedKeys.count<=3 && rankedKeys.allSatisfy({!$0.isEmpty}) {
                for key in rankedKeys {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if rankedKeys.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    priorPolygon=q.polygon;break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited:priorPolygon ?? incoming,proposed:chosen.polygon) else{return priorPreferred}
        return chosen
    }


    static func selectNative9505Common80Child(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let sourceClass:String;let cuts:[Cut];let key:String}
        enum Table {static let rules:[Rule]=[
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 0, threshold: 0.93428431941855361, lessOrEqual: false), Cut(feature: 27, threshold: 0.95872181000000001, lessOrEqual: true)], key: "support-blend-v1-side-envelope-v1-normal-ink-quarter-f75"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 0, threshold: 0.93428431941855361, lessOrEqual: false), Cut(feature: 24, threshold: 0.80975794999999995, lessOrEqual: true)], key: "asymmetric-support-v1-p66"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 11, threshold: -0.015455976271221462, lessOrEqual: true), Cut(feature: 19, threshold: 0.10794777999999999, lessOrEqual: false)], key: "support-blend-v1-normal.owned-shell.v1-f75"),
        ]}
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}),incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values+rfText
        for f in 16..<30 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        func value(_ f:Int)->Double? {
            guard f>=0,f<v.count else{return nil}
            return v[f]
        }
        var selected:NativeOCRResidualCandidate? = nil
        for rule in Table.rules.reversed() where rule.sourceClass==sourceClass {
            var match=true
            for cut in rule.cuts {
                guard let x=value(cut.feature),cut.lessOrEqual ? x<=cut.threshold:x>cut.threshold else {match=false;break}
            }
            guard match,let q=candidates.first(where:{$0.key==rule.key}),q.consumedIndices.isEmpty,
                  q.polygon.count==4,q.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),!sameQuad(q.polygon,incoming) else{continue}
            selected=q;break
        }
        guard let chosen=selected else{return inherited()}
        let priorPreferred=inherited()
        var priorPolygon=priorPreferred?.polygon
        if priorPolygon==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys=encoded.components(separatedBy:" >> ")
            if rankedKeys.count<=3 && rankedKeys.allSatisfy({!$0.isEmpty}) {
                for key in rankedKeys {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if rankedKeys.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    priorPolygon=q.polygon;break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited:priorPolygon ?? incoming,proposed:chosen.polygon) else{return priorPreferred}
        return chosen
    }


    static func selectV330Common90Recovery(_ values:[Double], rfText:[Double], candidates:[NativeOCRResidualCandidate],
        incoming:[CGPoint], inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        struct Cut {let feature:Int;let threshold:Double;let lessOrEqual:Bool}
        struct Rule {let sourceClass:String;let cuts:[Cut];let key:String}
        enum Table {static let rules:[Rule]=[
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 3, threshold: 0.9064359751497989, lessOrEqual: false), Cut(feature: 20, threshold: -4.0856167799999996, lessOrEqual: true)], key: "angle-padding-v1-p1-r1-left20"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 3, threshold: 0.9281612562990742, lessOrEqual: true), Cut(feature: 50, threshold: 0.01274409, lessOrEqual: true)], key: "support-margin-v1-n0-a15"),
            Rule(sourceClass: "0|medium|fit|short", cuts: [Cut(feature: 17, threshold: 0.04516129, lessOrEqual: false), Cut(feature: 22, threshold: 0, lessOrEqual: true)], key: "support-margin-v1-n10-a10"),
            Rule(sourceClass: "0|compact|narrow|short", cuts: [Cut(feature: 20, threshold: 5.9833436500000001, lessOrEqual: false), Cut(feature: 49, threshold: 15.072413790000001, lessOrEqual: false)], key: "input-footprint-v1-original-axis-normal-current-along"),
            Rule(sourceClass: "0|compact|narrow|fit", cuts: [Cut(feature: 1, threshold: 2.7105157555182173, lessOrEqual: false), Cut(feature: 19, threshold: 0.11795764, lessOrEqual: true)], key: "asymmetric-support-v1-p58"),
            Rule(sourceClass: "0|long|wide|fit", cuts: [Cut(feature: 3, threshold: 0.9281612562990742, lessOrEqual: true), Cut(feature: 50, threshold: 0.01274409, lessOrEqual: true)], key: "input-footprint-v1-original-axis-normal-current-along"),
            Rule(sourceClass: "0|medium|fit|short", cuts: [Cut(feature: 7, threshold: 0.023850239025411522, lessOrEqual: true), Cut(feature: 49, threshold: 6.6017315999999999, lessOrEqual: true)], key: "side-envelope-v1-head-ink-half"),
            Rule(sourceClass: "0|medium|fit|fit", cuts: [Cut(feature: 51, threshold: 5.6875, lessOrEqual: true), Cut(feature: 10, threshold: -0.080000000000000002, lessOrEqual: true)], key: "terminal-tail-palette-gap065-reach3-v1"),
            Rule(sourceClass: "0|medium|narrow|fit", cuts: [Cut(feature: 20, threshold: -0.86805144999999995, lessOrEqual: true), Cut(feature: 50, threshold: 0.077727119999999997, lessOrEqual: false)], key: "support-blend-v1-side-envelope-v1-normal-grid-f50"),
        ]}
        guard values.count==22,rfText.count==8,incoming.count==4,
              values.allSatisfy({$0.isFinite}),rfText.allSatisfy({$0.isFinite}),incoming.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return inherited()}
        var v=values+rfText
        for f in 16..<30 {
            let scaled=v[f]*100000000.0
            guard scaled.isFinite else{return inherited()}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            guard rounded.isFinite else{return inherited()}
            v[f]=rounded==0 ? 0:rounded
        }
        guard let kind=Int(exactly:v[8]) else{return inherited()}
        let aspect=v[1]<3 ? "compact":v[1]<8 ? "medium":"long"
        let normal=v[2]<0.8 ? "narrow":v[2]<1.05 ? "fit":"wide"
        let along=v[3]<0.85 ? "short":v[3]<1.05 ? "fit":"long"
        let sourceClass=[String(kind),aspect,normal,along].joined(separator:"|")
        func value(_ f:Int)->Double? {
            if f<30{return v[f]}
            let raw:Double
            if f==46 {raw=v[5]/max(1,v[1])}
            else if f==47 {raw=v[10]/max(1e-9,abs(v[2]))}
            else if f==48 {raw=v[11]/max(1e-9,abs(v[3]))}
            else if f==49 {raw=v[5]/max(1,v[1]*max(1e-9,abs(v[3])))}
            else if f==50 {raw=hypot(v[10]/max(1e-9,abs(v[2])),v[11]/max(1e-9,abs(v[3])))}
            else if f==51 {raw=v[1]*v[3]/max(1e-9,abs(v[2]))}
            else{return nil}
            let scaled=raw*100000000.0
            guard scaled.isFinite else{return nil}
            let rounded=scaled.rounded(.toNearestOrAwayFromZero)/100000000.0
            return rounded.isFinite ? (rounded==0 ? 0:rounded):nil
        }
        var selected:NativeOCRResidualCandidate? = nil
        for rule in Table.rules.reversed() where rule.sourceClass==sourceClass {
            var match=true
            for cut in rule.cuts {
                guard let x=value(cut.feature),cut.lessOrEqual ? x<=cut.threshold:x>cut.threshold else {match=false;break}
            }
            guard match,let q=candidates.first(where:{$0.key==rule.key}),q.consumedIndices.isEmpty,
                  q.polygon.count==4,q.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),!sameQuad(q.polygon,incoming) else{continue}
            selected=q;break
        }
        guard let chosen=selected else{return inherited()}
        let priorPreferred=inherited()
        var priorPolygon=priorPreferred?.polygon
        if priorPolygon==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let rankedKeys=encoded.components(separatedBy:" >> ")
            if rankedKeys.count<=3 && rankedKeys.allSatisfy({!$0.isEmpty}) {
                for key in rankedKeys {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if rankedKeys.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    priorPolygon=q.polygon;break
                }
            }
        }
        guard NativeOCRNoAlongEndLoss.allows(inherited:priorPolygon ?? incoming,proposed:chosen.polygon) else{return priorPreferred}
        return chosen
    }


    static func selectV330CombinedCommon80Then90(_ values:[Double], rfText:[Double],
        candidates:[NativeOCRResidualCandidate], incoming:[CGPoint],
        inherited:()->NativeOCRResidualCandidate?) -> NativeOCRResidualCandidate? {
        let prior=inherited()
        var baseline=prior?.polygon
        if baseline==nil,let encoded=NativeOCRResidualCandidateBank.selectedKey(values) {
            let ranked=encoded.components(separatedBy:" >> ")
            if ranked.count<=3 && ranked.allSatisfy({!$0.isEmpty}) {
                for key in ranked {
                    guard let q=candidates.first(where:{$0.key==key}) else{continue}
                    if ranked.count>1 {guard q.consumedIndices.isEmpty,!sameQuad(q.polygon,incoming) else{continue}}
                    baseline=q.polygon;break
                }
            }
        }
        let p80=selectNative9505Common80Child(values,rfText:rfText,candidates:candidates,
            incoming:incoming,inherited:{prior})
        if let q=p80,!sameQuad(q.polygon,baseline ?? incoming) {return q}
        let p90=selectV330Common90Recovery(values,rfText:rfText,candidates:candidates,
            incoming:incoming,inherited:{prior})
        if let q=p90,!sameQuad(q.polygon,baseline ?? incoming) {return q}
        return prior
    }

}

// Isolated OFFLINE-calibrated policy. Parent must first bind fresh native admission.
// Existing source22 + RF8 from raw incoming m.polygon; no inherited-prior lookup.
// Only keys already present in the admitted candidate menu may be returned.
// Return nil => ENTIRE existing selectedKey/inherited fallback unchanged.
enum NativeOCRPriorEnvelope345Selection {
    static func preferredKey(source22: [Double], rf8: [Double], admittedKeys: Set<String>) -> String? {
        guard source22.count == 22, rf8.count == 8,
              source22.allSatisfy({ $0.isFinite }), rf8.allSatisfy({ $0.isFinite }) else { return nil }
        var v = source22 + rf8
        for i in 16..<30 {
            let scaled = v[i] * 100000000.0
            guard scaled.isFinite else { return nil }
            let q = scaled.rounded(.toNearestOrAwayFromZero) / 100000000.0
            guard q.isFinite else { return nil }
            v[i] = q == 0 ? 0 : q
        }
        if admittedKeys.contains("prior-envelope-v1-n15-a10"), (v[8] == 1) && (v[1] >= 3 && v[1] < 8) && (v[3] > 0.99267347281654139) && (v[0] <= 0.85880810995708878) { return "prior-envelope-v1-n15-a10" }
        if admittedKeys.contains("prior-envelope-v1-n20-a10"), (v[8] == 0) && (v[1] >= 8) && (v[27] > 1.62806479) && (v[29] <= -0.25063355849999996) { return "prior-envelope-v1-n20-a10" }
        if admittedKeys.contains("prior-envelope-v1-n15-a10"), (v[8] == 0) && (v[3] < 0.85) && (v[29] > 2.5354273324999999) && (v[10] > 0.051347904108405298) && (v[26] > 6.0980581950000001) { return "prior-envelope-v1-n15-a10" }
        if admittedKeys.contains("prior-envelope-v1-n15-a15"), (v[8] == 1) && (v[2] >= 0.8 && v[2] < 1.05) && (v[4] <= 0.4014376711934543) && (v[26] > 4.12942638) { return "prior-envelope-v1-n15-a15" }
        return nil
    }
}

// Geometry-evidence entrypoint. Existing preference is the complete fallback.
@available(iOS 18.0, *)
extension NativeOCRResidualPrioritySelection {
    static func priorV348WithGeometry(_ candidates: [NativeOCRResidualCandidate], features: [Double],
        incoming: [CGPoint], rfScopes: [NativeOCRResidualRFTextFeatures.Scope],
        geometryFeatures: [String: [Double]]) -> NativeOCRResidualCandidate? {
        let admitted = Set(candidates.map(\.key))
        if let key = NativeOCRPriorEnvelopeV2Selection.preferredKey(source22: features,
            rf8: NativeOCRResidualRFTextFeatures.features(incoming, scopes: rfScopes),
            geometryForKey: { admitted.contains($0) ? geometryFeatures[$0] : nil }),
            let candidate = candidates.first(where: { $0.key == key }) {
            return candidate
        }
        return preferredWithRF(candidates, features: features, incoming: incoming, rfScopes: rfScopes)
    }
}

// NEW v2 family only. Existing v1 generation and old preferredWithRF remain unchanged.
// Parent H preferredWithGeometry calls this, then falls back to ENTIRE old v346 preferredWithRF.
// geometryForKey must expose fixed12 only for an admitted v2 candidate in the current row.
// No NativeCandidate core field, encoded-prior lookup, GT, IDs or world-axis branch.
enum NativeOCRPriorEnvelopeV2Selection {
    static func preferredKey(source22: [Double], rf8: [Double],
        geometryForKey: (String) -> [Double]?) -> String? {
        guard source22.count == 22, rf8.count == 8,
              source22.allSatisfy({ $0.isFinite }), rf8.allSatisfy({ $0.isFinite }) else { return nil }
        var base = source22 + rf8
        func quantize(_ x: Double) -> Double? {
            let scaled = x * 100000000.0
            guard x.isFinite, scaled.isFinite else { return nil }
            let q = scaled.rounded(.toNearestOrAwayFromZero) / 100000000.0
            return q.isFinite ? (q == 0 ? 0 : q) : nil
        }
        for i in 16..<30 {
            guard let q = quantize(base[i]) else { return nil }
            base[i] = q
        }
        func vector(_ key: String) -> [Double]? {
            guard let geometry = geometryForKey(key), geometry.count == 12,
                  geometry.allSatisfy({ $0.isFinite }) else { return nil }
            var v = base
            for x in geometry {
                guard let q = quantize(x) else { return nil }
                v.append(q)
            }
            return v
        }
        if let v = vector("prior-envelope-v2-n20-a10"), (v[8] == 0) && (v[20] > 4.7604709624999879) && (v[16] > 0.16815110749999934) && (v[2] <= 0.66273518914460539) { return "prior-envelope-v2-n20-a10" }
        if let v = vector("prior-envelope-v2-n15-a10"), (v[8] == 0) && (v[3] >= 0.85 && v[3] < 1.05) && (v[20] > 1.2577054340000033) && (v[22] <= 0) && (v[11] > 0.03417095937655347) { return "prior-envelope-v2-n15-a10" }
        if let v = vector("prior-envelope-v2-n25-a20"), (v[8] == 0) && (v[2] >= 0.8 && v[2] < 1.05) && (v[11] > 0.056606252640472886) && (v[26] > 6.1057676169999962) && (v[5] <= 0) { return "prior-envelope-v2-n25-a20" }
        if let v = vector("prior-envelope-v2-n15-a20"), (v[8] == 0) && (v[3] >= 0.85 && v[3] < 1.05) && (v[37] > 0.20000000000000001) && (v[11] > 0.03403279386405731) { return "prior-envelope-v2-n15-a20" }
        if let v = vector("prior-envelope-v2-n15-a10"), (v[8] == 0) && (v[3] >= 0.85 && v[3] < 1.05) && (v[38] > 0.10000000000000001) && (v[18] > 0.20337904000000012) { return "prior-envelope-v2-n15-a10" }
        return nil
    }
}

// New width repairs preserve the entire existing preference and group graph.
@available(iOS 18.0, *)
extension NativeOCRResidualPrioritySelection {
    static func preferredWithGeometry(_ candidates: [NativeOCRResidualCandidate], features: [Double],
        incoming: [CGPoint], rfScopes: [NativeOCRResidualRFTextFeatures.Scope],
        geometryFeatures: [String: [Double]]) -> NativeOCRResidualCandidate? {
        let prior = priorV348WithGeometry(candidates, features: features, incoming: incoming,
            rfScopes: rfScopes, geometryFeatures: geometryFeatures)
        let admitted = Set(candidates.map(\.key))
        guard let key = NativeOCRPriorEnvelopeAfter348Selection.preferredKey(source22: features,
            rf8: NativeOCRResidualRFTextFeatures.features(incoming, scopes: rfScopes),
            geometryForKey: { admitted.contains($0) ? geometryFeatures[$0] : nil }),
            let candidate = candidates.first(where: { $0.key == key }),
            candidate.consumedIndices.sorted() == (prior?.consumedIndices ?? []).sorted(),
            preservesPrior(candidate.polygon, prior: prior?.polygon ?? incoming) else { return prior }
        // A width repair must not also stretch a fitted longitudinal body by >5%.
        if features[2] >= 1.05,
            let geometry = geometryFeatures[key], geometry.count == 12, geometry[4] > 1.05 {
            return prior
        }
        if !candidate.consumedIndices.isEmpty,
            (candidate.associationKey ?? candidate.key) != (prior?.associationKey ?? prior?.key) {
            return prior
        }
        return candidate
    }
    // Difference-first signed edge distances; tolerance is numerical restoration only.
    static func preservesPrior(_ polygon: [CGPoint], prior: [CGPoint]) -> Bool {
        guard polygon.count == 4, prior.count == 4,
            (polygon + prior).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let scale = (polygon + prior).reduce(1.0) { max($0, max(abs(Double($1.x)), abs(Double($1.y)))) }
        let tolerance = 64 * Double.ulpOfOne * scale
        var positive = true, negative = true
        for i in 0..<4 {
            let origin = polygon[i], end = polygon[(i + 1) % 4]
            let dx = Double(end.x - origin.x), dy = Double(end.y - origin.y)
            let length = hypot(dx, dy)
            guard length > 0 else { return false }
            for point in prior {
                let x = Double(point.x - origin.x), y = Double(point.y - origin.y)
                let distance = (dx * y - dy * x) / length
                positive = positive && distance >= -tolerance
                negative = negative && distance <= tolerance
            }
        }
        return positive || negative
    }
}

// ADDITIVE child over ENTIRE adopted348 geometry selector. Old five rules are untouched.
// Same native v2 menu, generated against346; fixed12 sidecar contract unchanged.
// No GT, IDs, world coordinates, prior-resolver or geometry generation here.
enum NativeOCRPriorEnvelopeAfter348Selection {
    static func preferredKey(source22: [Double], rf8: [Double],
        geometryForKey: (String) -> [Double]?) -> String? {
        guard source22.count == 22, rf8.count == 8,
              source22.allSatisfy({ $0.isFinite }), rf8.allSatisfy({ $0.isFinite }) else { return nil }
        var base = source22 + rf8
        func quantize(_ x: Double) -> Double? {
            let scaled = x * 100000000.0
            guard x.isFinite, scaled.isFinite else { return nil }
            let q = scaled.rounded(.toNearestOrAwayFromZero) / 100000000.0
            return q.isFinite ? (q == 0 ? 0 : q) : nil
        }
        for i in 16..<30 {
            guard let q = quantize(base[i]) else { return nil }
            base[i] = q
        }
        func vector(_ key: String) -> [Double]? {
            guard let geometry = geometryForKey(key), geometry.count == 12,
                  geometry.allSatisfy({ $0.isFinite }) else { return nil }
            var v = base
            for x in geometry {
                guard let q = quantize(x) else { return nil }
                v.append(q)
            }
            return v
        }
        if let v = vector("prior-envelope-v2-n20-a10"), (v[18] > 0.22088340000000001) && (v[32] > 1.4416681200000001) && (v[4] > 0.54086634056773231) { return "prior-envelope-v2-n20-a10" }
        if let v = vector("prior-envelope-v2-n15-a20"), (v[8] == 0) && (v[2] >= 1.05) && (v[20] <= -0.19010412599999998) && (v[25] <= 0.053886502000000003) { return "prior-envelope-v2-n15-a20" }
        return nil
    }
}



/// Offline-calibrated candidate policy PROPOSAL. Parent keeps defaultOFF until
/// native selection parity and local physical review. No scalar record sidecar.
enum NativeOCRSourceBody357PolicyProposal {
    static let key = "source-body-cc-v3-incoming-pad0"

    /// source22 are the actual Bank values; source0/1 retain raw native precision.
    /// prior is the resolved actual old351 effective prior, not raw ingress.
    /// Call only for the corresponding already-admitted body candidate.
    static func matches(source22: [Double], proposed: [CGPoint], prior: [CGPoint]) -> Bool {
        guard source22.count >= 22, source22[0].isFinite, source22[1].isFinite,
              source22[1] > 21.021733583846014,
              source22[0] <= 0.8871504233061767,
              let ratio = alongRatio(proposed: proposed, prior: prior) else { return false }
        return ratio > 0.99555941
    }

    /// F23: proposed span / prior span along the prior's longest edge.
    /// Exact search convention: edge01 wins equal lengths; source coordinates,
    /// arbitrary rotation/winding, then nearest-away1e-8 normalization.
    static func alongRatio(proposed: [CGPoint], prior: [CGPoint]) -> Double? {
        guard proposed.count == 4, prior.count == 4,
              (proposed + prior).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let e1 = CGPoint(x: prior[1].x - prior[0].x, y: prior[1].y - prior[0].y)
        let e2 = CGPoint(x: prior[3].x - prior[0].x, y: prior[3].y - prior[0].y)
        let l1 = Double(e1.x) * Double(e1.x) + Double(e1.y) * Double(e1.y)
        let l2 = Double(e2.x) * Double(e2.x) + Double(e2.y) * Double(e2.y)
        let edge = l1 >= l2 ? e1 : e2, length = hypot(Double(edge.x), Double(edge.y))
        guard length > 0, length.isFinite else { return nil }
        let ax = Double(edge.x) / length, ay = Double(edge.y) / length
        let ox = prior.reduce(0.0) { $0 + Double($1.x) } / 4
        let oy = prior.reduce(0.0) { $0 + Double($1.y) } / 4
        func span(_ q: [CGPoint]) -> Double {
            let projected = q.map { (Double($0.x) - ox) * ax + (Double($0.y) - oy) * ay }
            return projected.max()! - projected.min()!
        }
        let old = span(prior)
        guard old > 0 else { return nil }
        let raw = span(proposed) / old
        guard raw.isFinite else { return nil }
        return (abs(raw) * 1e8 + 0.5).rounded(.down) / 1e8 * (raw < 0 ? -1 : 1)
    }
}



/// Frozen363 four-rule policy. Source-only routing, never admission/ownership.
/// The caller supplies ONLY freshly admitted normal candidates and the actual361 prior.
enum NativeOCRSourceNormalPolicy364 {
    struct Candidate {
        let key: String
        let polygon: [CGPoint]
        let supportPoints: [CGPoint] // Actual candidate mandatory list. No masks/hull filling.
    }
    struct Geometry {
        let f22: Double // Proposed normal span / prior normal span.
        let f28: Double // (proposedNormalMax-priorNormalMax) / prior normal span.
        let f34: Double // Actual support normal span / prior normal span.
        let f35: Double // Actual support along span / prior along span.
        let f40: Double // (priorAlongMin-supportAlongMin) / prior normal span.
    }
    static let keys = ["source-normal-private-v1-current-pad025",
                       "source-normal-private-v1-current-pad050",
                       "source-normal-private-v1-current-pad075",
                       "source-normal-private-v1-current-pad300"]
    static let reachableKeys = Set(keys)

    /// Rule4 has no source22 cuts. A correct necessary-only source preflight cannot
    /// narrow the full policy. Do not invent score/kind/ownership exclusions.
    static func sourceNormalMayGenerate(_ s: [Double]) -> Bool {
        s.count >= 22 && s.prefix(22).allSatisfy(\.isFinite)
    }
    static func sourceNormalPreferredKey(_ candidates: [Candidate], source22 s: [Double], prior: [CGPoint]) -> String? {
        guard sourceNormalMayGenerate(s) else { return nil }
        var selected: String?
        // Exact frozen precedence: LAST matching rule wins, first candidate for key.
        for index in keys.indices {
            guard let c = candidates.first(where: { $0.key == keys[index] }),
                  let g = geometry(proposed: c.polygon, supportPoints: c.supportPoints, prior: prior) else { continue }
            if matches(rule: index, source22: s, geometry: g) { selected = c.key }
        }
        return selected
    }
    static func matches(rule: Int, source22 s: [Double], geometry g: Geometry) -> Bool {
        guard sourceNormalMayGenerate(s) else { return false }
        switch rule {
        case 0:
            return g.f22 > 1.0464294 && s[0] <= 0.8182684338076122 &&
                g.f28 <= 0.02497546 && s[0] > 0.7985355394479315
        case 1:
            return g.f34 > 1.00200126 && s[11] <= -0.010741271045114029 && s[2] <= 1.0
        case 2:
            return s[1] > 16.693386877004926 && s[7] > 0.06253382441707703 && g.f35 <= 0.98915808
        case 3:
            return g.f40 <= -0.54869048 && g.f40 > -0.55546048
        default: return false
        }
    }
    static func geometry(proposed: [CGPoint], supportPoints: [CGPoint], prior: [CGPoint]) -> Geometry? {
        guard proposed.count == 4, prior.count == 4, !supportPoints.isEmpty,
              (proposed + prior + supportPoints).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let x1=Double(prior[1].x-prior[0].x), y1=Double(prior[1].y-prior[0].y)
        let x2=Double(prior[3].x-prior[0].x), y2=Double(prior[3].y-prior[0].y)
        let first=x1*x1+y1*y1 >= x2*x2+y2*y2
        let ex=first ? x1 : x2, ey=first ? y1 : y2, length=hypot(ex,ey)
        guard length > 0, length.isFinite else { return nil }
        let ax=ex/length, ay=ey/length, nx=ay, ny = -ax
        let ox=prior.reduce(0.0) { $0+Double($1.x) }/4, oy=prior.reduce(0.0) { $0+Double($1.y) }/4
        func bounds(_ points: [CGPoint]) -> (Double,Double,Double,Double) {
            var n0=Double.infinity,n1 = -Double.infinity,a0=Double.infinity,a1 = -Double.infinity
            for p in points {
                let x=Double(p.x)-ox,y=Double(p.y)-oy,n=x*nx+y*ny,a=x*ax+y*ay
                n0=min(n0,n);n1=max(n1,n);a0=min(a0,a);a1=max(a1,a)
            }
            return(n0,n1,a0,a1)
        }
        let old=bounds(prior),q=bounds(proposed),support=bounds(supportPoints)
        let width=old.1-old.0,height=old.3-old.2
        guard width > 0,height > 0,width.isFinite,height.isFinite else { return nil }
        func quant(_ x: Double) -> Double? {
            let scaled=abs(x)*1e8,shifted=scaled+0.5
            guard x.isFinite,scaled.isFinite,shifted.isFinite else { return nil }
            let result=(floor(shifted)/1e8)*(x < 0 ? -1 : 1)
            return result.isFinite ? result : nil
        }
        guard let f22=quant((q.1-q.0)/width),let f28=quant((q.1-old.1)/width),
              let f34=quant((support.1-support.0)/width),let f35=quant((support.3-support.2)/height),
              let f40=quant((old.2-support.2)/width) else { return nil }
        return .init(f22:f22,f28:f28,f34:f34,f35:f35,f40:f40)
    }
}



/// Isolated proposal, NOT production-activated or compiled here.
/// Additional source-only preference AFTER the complete current366 fallback is resolved.
/// Candidate admission/ownership/child membership remain caller responsibilities.
enum NativeOCRSourceNormalRouting367 {
    static let key = "source-normal-private-v1-current-pad300"
    struct Candidate {
        let key: String
        let polygon: [CGPoint]
        let supportPoints: [CGPoint]
        /// Source-only snapshot of the resolved prior used to generate/admit this offer.
        let generatedFromPrior: [CGPoint]
    }
    static func mayGenerate(_ s: [Double]) -> Bool {
        s.count >= 22 && s.prefix(22).allSatisfy(\.isFinite) &&
        (s[14] > 0.9164864864864857 || s[1] > 16.567177502889503)
    }
    static func matches(source22 s: [Double], proposalPriorIoU: Double,
                        mandatoryAlongRatio: Double) -> Bool {
        guard mayGenerate(s), proposalPriorIoU.isFinite, mandatoryAlongRatio.isFinite else { return false }
        let i = quant(proposalPriorIoU), a = quant(mandatoryAlongRatio)
        return (s[14] > 0.9164864864864857 && i > 0.94763437 && a > 0.88738377) ||
               (s[1] > 16.567177502889503 && i > 0.94823604 && i <= 0.95225054)
    }
    /// Pass ONLY native-admitted candidates retaining the exact current source graph.
    /// All8offer source RGB union must already be fixed before this preference/preflight.
    static func preferredKey(_ admitted: [Candidate], source22 s: [Double],
                             current366Prior prior: [CGPoint]) -> String? {
        guard mayGenerate(s), let c = admitted.first(where: { $0.key == key }),
              equivalent(c.generatedFromPrior, prior),
              let g = geometry(prior: prior, proposed: c.polygon, support: c.supportPoints),
              matches(source22: s, proposalPriorIoU: g.0, mandatoryAlongRatio: g.1) else { return nil }
        return key
    }
    static func quant(_ x: Double) -> Double {
        (floor(abs(x) * 1e8 + 0.5) / 1e8) * (x < 0 ? -1 : 1)
    }
    static func equivalent(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        guard a.count == 4, b.count == 4 else { return false }
        for reversed in [false, true] {
            let q = reversed ? Array(b.reversed()) : b
            for k in 0..<4 where (0..<4).allSatisfy({ i in
                abs(a[i].x-q[(i+k)%4].x) <= 1e-8 && abs(a[i].y-q[(i+k)%4].y) <= 1e-8
            }) { return true }
        }
        return false
    }
    static func geometry(prior: [CGPoint], proposed: [CGPoint], support: [CGPoint]) -> (Double,Double)? {
        guard prior.count == 4, proposed.count == 4, !support.isEmpty,
              (prior+proposed+support).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let e1 = CGPoint(x:prior[1].x-prior[0].x,y:prior[1].y-prior[0].y)
        let e2 = CGPoint(x:prior[3].x-prior[0].x,y:prior[3].y-prior[0].y)
        let e = e1.x*e1.x+e1.y*e1.y >= e2.x*e2.x+e2.y*e2.y ? e1 : e2
        let len = hypot(Double(e.x),Double(e.y))
        guard len > 0, len.isFinite else { return nil }
        let ax=Double(e.x)/len, ay=Double(e.y)/len
        let ox=prior.reduce(0.0){$0+Double($1.x)}/4, oy=prior.reduce(0.0){$0+Double($1.y)}/4
        func alongSpan(_ p: [CGPoint]) -> Double {
            let v=p.map{(Double($0.x)-ox)*ax+(Double($0.y)-oy)*ay}
            return v.max()!-v.min()!
        }
        let h=alongSpan(prior), intersection=area(clip(proposed,to:prior))
        let union=area(prior)+area(proposed)-intersection
        guard h > 0, union > 0 else { return nil }
        let i=intersection/union, a=alongSpan(support)/h
        guard i.isFinite, a.isFinite else { return nil }
        return (quant(i),quant(a))
    }
    static func signedArea(_ p: [CGPoint]) -> Double {
        guard p.count >= 3 else { return 0 }
        return p.indices.reduce(0.0){total,i in
            let q=p[(i+1)%p.count]
            return total+Double(p[i].x*q.y-q.x*p[i].y)
        }/2
    }
    static func area(_ p: [CGPoint]) -> Double { abs(signedArea(p)) }
    static func clip(_ subject: [CGPoint], to polygon: [CGPoint]) -> [CGPoint] {
        let sign:CGFloat=signedArea(polygon) >= 0 ? 1 : -1
        var out=subject
        for i in polygon.indices {
            let a=polygon[i],b=polygon[(i+1)%polygon.count],input=out
            out=[]
            guard var previous=input.last else { return [] }
            func d(_ p:CGPoint)->CGFloat { sign*((b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)) }
            var pd=d(previous)
            for current in input {
                let cd=d(current)
                if (cd >= 0) != (pd >= 0) {
                    let t=pd/(pd-cd)
                    out.append(.init(x:previous.x+t*(current.x-previous.x),y:previous.y+t*(current.y-previous.y)))
                }
                if cd >= 0 { out.append(current) }
                previous=current;pd=cd
            }
        }
        return out
    }
}
