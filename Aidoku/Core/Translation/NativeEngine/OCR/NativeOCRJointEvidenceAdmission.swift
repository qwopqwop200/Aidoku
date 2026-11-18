import Foundation

/// Optional post-RF/post-finalCover admission. The caller must retain the original
/// bbox-admitted reference bank and pass qualities aligned to this exact input.
/// Producer families establish diversity only, never ownership or independence.
enum NativeOCRJointEvidenceAdmission {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias D = NativeOCRGeometryDeduplication
    typealias A = NativeOCRRFSemanticAdmission

    struct Configuration: Sendable {
        var countWitnessEnabled = true
    }
    struct Signals: Codable, Equatable, Sendable {
        let quality: Double
        let rfTextMean: Double
        let observedRecognitionAgreement: Double
        let secondFamilyOverlap: Double
        let supportingFamilyCount80: Int
        var rank: Double { quality + secondFamilyOverlap }
    }
    struct Replacement: Codable, Equatable, Sendable {
        let inputIndex: Int
        let retainedIndex: Int
        let polygonIoU: Double
        let rule: String
    }
    struct Report: Codable, Equatable, Sendable {
        let inputCount: Int
        let referenceInventoryCount: Int
        let keptIndices: [Int]
        let weakJointEvidenceRejectedIndices: [Int]
        let replacements: [Replacement]
        let missingEvidenceKeptIndices: [Int]
        let signals: [Signals?]
        let countWitnessEnabled: Bool
    }
    struct Result: Sendable { let output: G.Output; let report: Report }

    static func producerFamilies(_ row: G.Individual) -> Set<String> {
        Set(row.provenance.map { record in
            let parts = record.alternativeID.split(separator: "/", omittingEmptySubsequences: false)
            if parts.first == "source-paint", parts.count > 3 { return String(parts[3]) }
            return parts.first.map(String.init) ?? ""
        })
    }

    static func apply(_ input: G.Output, referenceInventory: G.Output?,
                      grid: NativeRFDETRSemanticGrid?, recognition: [A.Observation],
                      frozenQualityScores: [Double?]?, sourceEvidenceAvailable: Bool,
                      configuration: Configuration = .init(),
                      cancellationCheck: () throws -> Void = {}) throws -> Result {
        let rows = input.individuals
        let shapes = rows.map { D.Shape($0.polygon) }
        let references = referenceInventory?.individuals ?? []
        let referenceShapes = references.map { D.Shape($0.polygon) }
        let referenceFamilies = references.map(producerFamilies)
        let allFamilies = Set(referenceFamilies.flatMap { $0 }).sorted()
        let rowFamilies = rows.map(producerFamilies)
        let anchors = rowFamilies.map { !$0.isDisjoint(with: Set(["original", "corrected", "layout"])) }
        let observed = recognition.compactMap { item -> (D.Shape, Double)? in
            let shape = D.Shape(item.polygon)
            guard shape.convex, shape.area.isFinite, shape.area > 0,
                  item.confidence.isFinite, item.confidence > 0, item.confidence <= 1 else { return nil }
            return (shape, item.confidence)
        }
        // An unavailable bank, grid, source context or quality binding cannot reject.
        let available = sourceEvidenceAvailable && grid?.isValid == true && !observed.isEmpty
            && referenceInventory != nil && !references.isEmpty
            && frozenQualityScores?.count == rows.count
            && referenceShapes.allSatisfy { $0.convex && $0.area.isFinite && $0.area > 0 }
        var signals = [Signals?](repeating: nil, count: rows.count)
        for index in rows.indices {
            try cancellationCheck()
            guard available, let grid, let quality = frozenQualityScores?[index], quality.isFinite,
                  let bbox = rows[index].bboxConfidence, bbox.isFinite, (0...1).contains(bbox),
                  shapes[index].convex, shapes[index].area.isFinite, shapes[index].area > 0 else { continue }
            let text = A.means(rows[index].polygon, grid: grid)[0]
            let recognitionAgreement = observed.reduce(0.0) {
                max($0, D.intersectionIoU(shapes[index], $1.0, minimum: 0) * $1.1)
            }
            guard text.isFinite, recognitionAgreement.isFinite,
                  (0...1).contains(text), (0...1).contains(recognitionAgreement) else { continue }
            // One vote per family, max over immutable reference polygons; exclude
            // every own family. Reference support never shrinks with this output.
            var votes = Dictionary(uniqueKeysWithValues: allFamilies.map { ($0, 0.0) })
            for other in references.indices {
                try cancellationCheck()
                let overlap = D.intersectionIoU(shapes[index], referenceShapes[other], minimum: 0)
                for family in referenceFamilies[other] where !rowFamilies[index].contains(family) {
                    votes[family] = max(votes[family] ?? 0, overlap)
                }
            }
            let ordered = votes.values.sorted(by: >)
            let second = ordered.count >= 2 ? ordered[1] : 0
            signals[index] = .init(quality: quality, rfTextMean: text,
                observedRecognitionAgreement: recognitionAgreement, secondFamilyOverlap: second,
                supportingFamilyCount80: ordered.filter { $0 >= 0.8 }.count)
        }
        var keep = [Bool](repeating: true, count: rows.count)
        var weak: [Int] = [], replacements: [Replacement] = []
        let missing = rows.indices.filter { signals[$0] == nil }
        for index in rows.indices where !anchors[index] {
            if let s = signals[index], s.quality * (s.rfTextMean + s.observedRecognitionAgreement) < 0.1 {
                keep[index] = false
                weak.append(index)
            }
        }
        let order = rows.indices.sorted {
            let a = signals[$0]?.rank ?? -Double.infinity
            let b = signals[$1]?.rank ?? -Double.infinity
            return a == b ? $0 < $1 : a > b
        }
        var retained: [Int] = []
        for index in order where keep[index] {
            try cancellationCheck()
            guard !anchors[index], let candidate = signals[index] else {
                retained.append(index)
                continue
            }
            var replacement: Replacement?
            for other in retained {
                guard let witness = signals[other], witness.secondFamilyOverlap >= 0.8 else { continue }
                let strict = witness.secondFamilyOverlap >= candidate.secondFamilyOverlap
                let count = configuration.countWitnessEnabled
                    && witness.supportingFamilyCount80 >= candidate.supportingFamilyCount80 + 4
                    && witness.observedRecognitionAgreement >= candidate.observedRecognitionAgreement
                guard strict || count else { continue }
                let overlap = D.intersectionIoU(shapes[index], shapes[other], minimum: 0)
                let strictAccepted = strict && overlap >= 0.9
                let countAccepted = count && overlap >= 0.85
                if strictAccepted || countAccepted {
                    replacement = .init(inputIndex: index, retainedIndex: other, polygonIoU: overlap,
                        rule: strictAccepted ? "second-family-consensus-direct-090" : "four-more-families-observed-direct-085")
                    break
                }
            }
            if let replacement {
                keep[index] = false
                replacements.append(replacement)
            } else { retained.append(index) }
        }
        let kept = rows.indices.filter { keep[$0] }
        return .init(output: G.selecting(input, indices: kept), report: .init(inputCount: rows.count,
            referenceInventoryCount: references.count, keptIndices: kept,
            weakJointEvidenceRejectedIndices: weak, replacements: replacements,
            missingEvidenceKeptIndices: missing, signals: signals,
            countWitnessEnabled: configuration.countWitnessEnabled))
    }
}
