import Foundation

/// RF probability-field admission AFTER representative election. No RGB, shape
/// classifier, runtime GT, query ownership or copied candidate recognition.
enum NativeOCRRFSemanticAdmission {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias D = NativeOCRGeometryDeduplication
    struct Rule: Codable, Sendable {
        let otherClass: Int
        let minOtherMean: Double
        let maxTextMean: Double
        let maxObservedRecognitionAgreement: Double
        let maxBBoxConfidence: Double?
    }
    /// Relative RF-field evidence only. Thresholds are global, never page routed.
    struct SpatialRule: Codable, Sendable {
        let score: String
        let threshold: Double
        let maxObservedRecognitionAgreement: Double?
        let maxBBoxConfidence: Double?
    }
    struct Policy: Decodable, Sendable {
        let schema: String
        let rules: [Rule]
        let preserveSourceStageAnchors: Bool
        let gridSide: Int
        let quadratureSide: Int
        let semanticClassOrder: [String]
        let requiresObservedRecognitionContext: Bool
        var spatialRules: [SpatialRule]? = nil
        var finalCoverAdaptiveEnabled: Bool? = nil
        var finalCoverAdaptiveMinimumQualityMargin: Double? = nil
        var finalCoverBoundaryTolerance: Double? = nil
        var jointEvidenceAdmission: Bool? = nil
        var finalCoverRanking: String?
        var finalCoverThreshold: Double?
        var modelWeightsSHA256: String?
    }
    struct Observation: Codable, Sendable { let polygon: [G.Point]; let confidence: Double }
    struct Rejection: Codable, Equatable, Sendable {
        let inputIndex: Int
        let ruleIndex: Int
        let textMean: Double
        let otherMean: Double
        let observedRecognitionAgreement: Double
        var spatialScore: String? = nil
        var spatialValue: Double? = nil
    }
    struct Report: Codable, Equatable, Sendable {
        let inputCount: Int
        let keptIndices: [Int]
        let rejected: [Rejection]
        let missingEvidenceKeptIndices: [Int]
        let gridAvailable: Bool
        let allQueryCount: Int
        let freshCandidateRecognition: Bool
        let observedRecognitionContextAvailable: Bool
        var finalCover: NativeOCRDirectFinalCover.Report? = nil
        /// Maps finalCover's local input indices back to this report's original input.
        var finalCoverInputIndices: [Int]? = nil
        var jointEvidence: NativeOCRJointEvidenceAdmission.Report? = nil
        var jointEvidenceInputIndices: [Int]? = nil
    }
    struct Result: Sendable { let output: G.Output; let report: Report }
    enum Failure: Error { case invalidPolicy }

    static func configured(_ input: G.Output, grid: NativeRFDETRSemanticGrid?,
                           recognition: [Observation], qualityScores: [Double?]? = nil,
                           referenceInventory: G.Output? = nil, cancellationCheck: () throws -> Void = {}) throws -> Result? {
        guard let path = ProcessInfo.processInfo.environment[NativeRFDETRSemanticGrid.environmentKey], !path.isEmpty else { return nil }
        let policy = try JSONDecoder().decode(Policy.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        return try apply(input, grid: grid, recognition: recognition, qualityScores: qualityScores,
            referenceInventory: referenceInventory, policy: policy, cancellationCheck: cancellationCheck)
    }

    /// Square quadrature is invariant to cyclic start/winding. Samples only RF
    /// predicted fields in original coordinates, never source-image pixels.
    private static func sample(_ polygon: [G.Point], grid: NativeRFDETRSemanticGrid,
                               u: Double, v: Double, semantic: Int) -> Double {
        let weights = [(1-u)*(1-v), u*(1-v), u*v, (1-u)*v]
        let px = zip(polygon, weights).reduce(0.0) { $0 + $1.0.x * $1.1 }
        let py = zip(polygon, weights).reduce(0.0) { $0 + $1.0.y * $1.1 }
        let gx = min(Double(grid.side-1), max(0, px * Double(grid.side) / Double(grid.width) - 0.5))
        let gy = min(Double(grid.side-1), max(0, py * Double(grid.side) / Double(grid.height) - 0.5))
        let x0 = Int(gx), y0 = Int(gy), x1 = min(grid.side-1, x0+1), y1 = min(grid.side-1, y0+1)
        let dx = gx-Double(x0), dy = gy-Double(y0), base = semantic*grid.side*grid.side
        func at(_ x: Int, _ y: Int) -> Double { Double(grid.probabilities[base+y*grid.side+x]) }
        return (at(x0,y0)*(1-dx)+at(x1,y0)*dx)*(1-dy)+(at(x0,y1)*(1-dx)+at(x1,y1)*dx)*dy
    }

    static func means(_ polygon: [G.Point], grid: NativeRFDETRSemanticGrid) -> [Double] {
        var result = [Double](repeating: 0, count: 4)
        for y in 0..<16 { for x in 0..<16 {
            for c in 0..<4 {
                result[c] += sample(polygon, grid: grid, u: (Double(x)+0.5)/16,
                                    v: (Double(y)+0.5)/16, semantic: c)/256
            }
        }}
        return result
    }

    /// Concentration, quantile and relative interior/ring contrast of RF300 fields.
    /// The ring extends 25% beyond each side in the candidate's own coordinates.
    static func spatialEvidence(_ polygon: [G.Point], grid: NativeRFDETRSemanticGrid) -> [String: Double] {
        var text = [Double](), sfx = [Double](), balloon = [Double]()
        for y in 0..<16 { for x in 0..<16 {
            let u = (Double(x)+0.5)/16, v = (Double(y)+0.5)/16
            text.append(sample(polygon, grid: grid, u: u, v: v, semantic: 0))
            sfx.append(sample(polygon, grid: grid, u: u, v: v, semantic: 1))
            balloon.append(sample(polygon, grid: grid, u: u, v: v, semantic: 2))
        }}
        var balloonRing = 0.0
        for y in 0..<24 { for x in 0..<24 {
            guard x < 4 || x >= 20 || y < 4 || y >= 20 else { continue }
            balloonRing += sample(polygon, grid: grid, u: (Double(x)+0.5)/16-0.25,
                                  v: (Double(y)+0.5)/16-0.25, semantic: 2)/320
        }}
        let total = text.reduce(0,+), sortedSFX = sfx.sorted()
        let q75 = sortedSFX[191]*0.75+sortedSFX[192]*0.25
        return ["text_top25mass": text.sorted().suffix(64).reduce(0,+)/max(total,1e-12),
                "balloon_contrast": -(balloon.reduce(0,+)/256-balloonRing),
                "sfx_q75": q75, "balloon_peak": -(balloon.max() ?? 0)]
    }

    static func apply(_ input: G.Output, grid: NativeRFDETRSemanticGrid?, recognition: [Observation],
                      qualityScores: [Double?]? = nil, referenceInventory: G.Output? = nil,
                      policy: Policy, cancellationCheck: () throws -> Void = {}) throws -> Result {
        guard policy.schema == "rf-semantic-source-observation-rules-v1", policy.gridSide == 162,
              policy.quadratureSide == 16, policy.preserveSourceStageAnchors,
              policy.finalCoverAdaptiveMinimumQualityMargin.map({ $0.isFinite && $0 >= 0 }) ?? true,
              policy.finalCoverBoundaryTolerance.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              policy.finalCoverRanking.map({ $0 == "representative-quality" }) ?? true,
              policy.finalCoverThreshold == nil || policy.finalCoverRanking == "representative-quality",
              policy.finalCoverThreshold.map({ $0.isFinite && $0 > 0 && $0 <= 1 }) ?? true,
              policy.semanticClassOrder == ["text", "soundEffect", "balloon", "frame"], policy.rules.count <= 16,
              policy.rules.allSatisfy({ (1...3).contains($0.otherClass)
                  && [$0.minOtherMean,$0.maxTextMean,$0.maxObservedRecognitionAgreement].allSatisfy { $0.isFinite && (0...1).contains($0) }
                  && ($0.maxBBoxConfidence.map { $0.isFinite && (0...1).contains($0) } ?? true) }) else {
            throw Failure.invalidPolicy
        }
        let spatialRules = policy.spatialRules ?? []
        guard spatialRules.count <= 6, spatialRules.allSatisfy({ rule in
            ["text_top25mass", "balloon_contrast", "sfx_q75", "balloon_peak"].contains(rule.score)
                && rule.threshold.isFinite && (-1...1).contains(rule.threshold)
                && (rule.maxObservedRecognitionAgreement.map { $0.isFinite && (0...1).contains($0) } ?? true)
                && (rule.maxBBoxConfidence.map { $0.isFinite && (0...1).contains($0) } ?? true)
        }) else { throw Failure.invalidPolicy }
        let rows = input.individuals
        let observed = recognition.compactMap { item -> (D.Shape, Double)? in
            let shape = D.Shape(item.polygon)
            guard shape.convex, item.confidence.isFinite, item.confidence > 0, item.confidence <= 1 else { return nil }
            return (shape,item.confidence)
        }
        let gridAvailable = grid?.isValid == true
            && (policy.modelWeightsSHA256 == nil || grid?.modelWeightsSHA256 == policy.modelWeightsSHA256)
        let available = gridAvailable && (!policy.requiresObservedRecognitionContext || !observed.isEmpty)
        var kept = [Int](), rejected = [Rejection](), missing = [Int]()
        for index in rows.indices {
            try cancellationCheck()
            let shape = D.Shape(rows[index].polygon)
            guard available, let grid, shape.convex, shape.area.isFinite, shape.area > 0 else {
                kept.append(index); missing.append(index); continue
            }
            let anchor = rows[index].provenance.contains {
                ["original", "corrected", "layout"].contains($0.alternativeID.split(separator:"/").first.map(String.init) ?? "")
            }
            if anchor { kept.append(index); continue }
            let sampled = means(rows[index].polygon, grid: grid)
            let agreement = observed.reduce(0.0) { max($0,D.intersectionIoU(shape,$1.0,minimum:0)*$1.1) }
            if let rule = policy.rules.indices.first(where: {
                sampled[policy.rules[$0].otherClass] >= policy.rules[$0].minOtherMean
                    && sampled[0] < policy.rules[$0].maxTextMean
                    && agreement < policy.rules[$0].maxObservedRecognitionAgreement
                    && (policy.rules[$0].maxBBoxConfidence.map { maximum in
                        guard let confidence = rows[index].bboxConfidence, confidence.isFinite,
                              (0...1).contains(confidence) else { return false }
                        return confidence < maximum
                    } ?? true)
            }) {
                rejected.append(.init(inputIndex:index,ruleIndex:rule,textMean:sampled[0],
                    otherMean:sampled[policy.rules[rule].otherClass],observedRecognitionAgreement:agreement))
            } else { kept.append(index) }
        }
        // Semantic evidence is evaluated before the terminal direct cover. Frozen
        // quality scores remain aligned to the original elected rows below.
        if !spatialRules.isEmpty, available, !observed.isEmpty, let grid {
            kept = try kept.filter { index in
                try cancellationCheck()
                let row = rows[index], shape = D.Shape(row.polygon)
                guard shape.convex, shape.area.isFinite, shape.area > 0,
                      let bbox = row.bboxConfidence, bbox.isFinite, (0...1).contains(bbox),
                      !row.provenance.contains(where: {
                          ["original", "corrected", "layout"].contains($0.alternativeID.split(separator: "/").first.map(String.init) ?? "")
                      }) else { return true }
                let agreement = observed.reduce(0.0) { max($0,D.intersectionIoU(shape,$1.0,minimum:0)*$1.1) }
                let evidence = spatialEvidence(row.polygon, grid: grid)
                if let ruleIndex = spatialRules.indices.first(where: { i in
                    let rule = spatialRules[i]
                    return (rule.maxObservedRecognitionAgreement.map { agreement < $0 } ?? true)
                        && (rule.maxBBoxConfidence.map { bbox < $0 } ?? true)
                        && (evidence[rule.score].map { $0.isFinite && $0 < rule.threshold } ?? false)
                }) {
                    let rule = spatialRules[ruleIndex], sampled = means(row.polygon, grid: grid)
                    rejected.append(.init(inputIndex: index, ruleIndex: policy.rules.count+ruleIndex,
                        textMean: sampled[0], otherMean: sampled[2], observedRecognitionAgreement: agreement,
                        spatialScore: rule.score, spatialValue: evidence[rule.score]))
                    return false
                }
                return true
            }
        }
        var finalCover: NativeOCRDirectFinalCover.Report?
        var coverInputIndices: [Int]?
        if let threshold = policy.finalCoverThreshold, available, !observed.isEmpty {
            let qualityAligned = qualityScores?.count == rows.count
            // Freeze exact election-score alignment before selecting a subset.
            // Missing/invalid bindings keep every row; no substitute confidence.
            let scores: [Double?] = kept.map { qualityAligned ? qualityScores![$0] : nil }
            let result = try NativeOCRDirectFinalCover.apply(G.selecting(input, indices: kept), frozenQualityScores: scores,
                configuration: .init(overlapThreshold: threshold,
                    adaptiveOverlapThreshold: policy.finalCoverAdaptiveEnabled == false ? 1 : 0.8,
                    minimumQualityMargin: policy.finalCoverAdaptiveMinimumQualityMargin ?? 0.1,
                    boundaryTolerance: policy.finalCoverBoundaryTolerance ?? 0.2), cancellationCheck: cancellationCheck)
            let originalKept = kept
            coverInputIndices = originalKept
            kept = result.report.keptIndices.map { originalKept[$0] }
            finalCover = result.report
        }
        var jointEvidence: NativeOCRJointEvidenceAdmission.Report?
        var jointEvidenceInputIndices: [Int]?
        if policy.jointEvidenceAdmission == true {
            let aligned = qualityScores?.count == rows.count
            let scores: [Double?] = kept.map { aligned ? qualityScores![$0] : nil }
            let result = try NativeOCRJointEvidenceAdmission.apply(G.selecting(input, indices: kept),
                referenceInventory: referenceInventory, grid: grid, recognition: recognition,
                frozenQualityScores: scores, sourceEvidenceAvailable: available,
                cancellationCheck: cancellationCheck)
            jointEvidenceInputIndices = kept
            let originalKept = kept
            kept = result.report.keptIndices.map { originalKept[$0] }
            jointEvidence = result.report
        }
        return .init(output:G.selecting(input,indices:kept),report:.init(inputCount:rows.count,keptIndices:kept,
            rejected:rejected,missingEvidenceKeptIndices:missing,gridAvailable:gridAvailable,allQueryCount:gridAvailable ? 300 : 0,
            freshCandidateRecognition:false,observedRecognitionContextAvailable:!observed.isEmpty,
            finalCover:finalCover,finalCoverInputIndices:coverInputIndices,
            jointEvidence:jointEvidence,jointEvidenceInputIndices:jointEvidenceInputIndices))
    }
}
