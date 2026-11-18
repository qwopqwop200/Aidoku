/// Joint evidence keeps the class scores bound to the SAME query and mask.
/// A weak text alternative is not detached from its competing SFX hypothesis.
struct NativeOCRPremergeQueryRelations: Sendable {
    typealias F = NativeOCRPremergeCandidateFeatures
    static let featureNames = ["jointSFXTextSupport", "jointSFXSupport", "jointSFXClassShare", "jointSFXMaskCoverage",
        "jointTextSFXSupport", "jointTextSupport", "jointTextClassShare", "jointTextMaskCoverage"]
    private let masks: [(F.RFMask, [Double])]
    init?(primitives: [F.RFPrimitive], queries: [NativeOCRPremergeSpatialEvidence.Query]) {
        guard queries.count == 300, queries.allSatisfy({
            $0.queryID != nil && (0..<300).contains($0.queryID!) && $0.probabilities.count == 5 &&
            $0.probabilities.allSatisfy { $0.isFinite && (0...1).contains($0) }
        }), Set(queries.compactMap(\.queryID)).count == 300, primitives.count <= 160 else { return nil }
        let probabilities = Dictionary(uniqueKeysWithValues: queries.map { ($0.queryID!, $0.probabilities) })
        var seen = Set<Int>(), masks: [(F.RFMask, [Double])] = []
        for p in primitives {
            guard let q = p.queryID, let mask = p.mask, mask.isValid, let scores = probabilities[q] else { return nil }
            if seen.insert(q).inserted { masks.append((mask, scores)) }
        }
        self.masks = masks
    }
    func extract(polygon: [F.Point]) -> [Double]? {
        var bestSFX = -1.0, bestText = -1.0
        var sfx = [0.0, 0, 0, 0], text = [0.0, 0, 0, 0]
        guard !masks.isEmpty else { return sfx + text }
        guard let footprint = F.MaskPolygon(polygon) else { return nil }
        for (mask, scores) in masks {
            // Coverage is at most one. Equal scores keep the first witness.
            guard scores[0] > bestText || scores[1] > bestSFX else { continue }
            let coverage = footprint.coverage(withValidated: mask)
            let a = scores[0] * coverage, b = scores[1] * coverage
            if b > bestSFX { bestSFX = b; sfx = [a, b, scores[1] / max(1e-12, scores[0] + scores[1]), coverage] }
            if a > bestText { bestText = a; text = [b, a, scores[0] / max(1e-12, scores[0] + scores[1]), coverage] }
        }
        return (sfx + text).map { max(0, min(1, $0)) }
    }
}
