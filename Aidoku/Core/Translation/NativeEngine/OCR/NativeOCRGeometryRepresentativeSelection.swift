import Foundation

/// Elects existing polygons using evidence, rather than confidence multiplied by
/// area. A search/query parent is never treated as certified text membership.
enum NativeOCRGeometryRepresentativeSelection {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias D = NativeOCRGeometryDeduplication
    static let environmentKey = "AIDOKU_OCR_GEOMETRY_REPRESENTATIVE_POLICY"

    struct Policy: Decodable, Sendable {
        let model: Model
        let configuration: Configuration
    }

    static func configured(_ input: G.Output, context: Context,
                           referenceInventory: G.Output? = nil,
                           environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Result? {
        guard let path = environment[environmentKey], !path.isEmpty else { return nil }
        let policy = try JSONDecoder().decode(Policy.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        return try apply(input, context: context, model: policy.model, configuration: policy.configuration,
                         referenceInventory: referenceInventory)
    }

    struct Evidence: Codable, Sendable {
        let polygon: [G.Point]
        let confidence: Double
        /// Canonical model order: frame=0, text=1, balloon=2, soundEffect=3.
        /// NativeRFDETRLayoutSemanticClass.rawValue has a DIFFERENT order.
        var semanticClass: Int? = nil
    }
    struct Context: Codable, Sendable {
        var detectors: [Evidence] = []
        /// Observed OCR agreement, NOT fresh recognition of each alternative.
        var recognition: [Evidence] = []
        var layout: [Evidence] = []
    }
    struct Node: Decodable, Sendable {
        let feature: Int
        let threshold: Double?
        let left: Int?
        let right: Int?
        let value: Double?
    }
    struct Model: Decodable, Sendable {
        let schema: String
        let bias: Double
        let learningRate: Double
        let featureNames: [String]
        let trees: [[Node]]

        func validate() throws {
            guard schema == "numeric-hist-gradient-boost-v1", bias.isFinite,
                  learningRate.isFinite, learningRate > 0, !featureNames.isEmpty,
                  featureNames.count <= 512, trees.count <= 256 else { throw Failure.invalidModel }
            for tree in trees {
                var seen = Set<Int>()
                func visit(_ index: Int, depth: Int) throws {
                    guard tree.indices.contains(index), depth <= 16, seen.insert(index).inserted else {
                        throw Failure.invalidModel
                    }
                    let node = tree[index]
                    if node.feature < 0 {
                        guard node.value?.isFinite == true else { throw Failure.invalidModel }
                    } else {
                        guard featureNames.indices.contains(node.feature), node.threshold?.isFinite == true,
                              let left = node.left, let right = node.right else { throw Failure.invalidModel }
                        try visit(left, depth: depth + 1)
                        try visit(right, depth: depth + 1)
                    }
                }
                try visit(0, depth: 0)
                guard seen.count == tree.count else { throw Failure.invalidModel }
            }
        }

        func predict(_ features: [Double]) -> Double {
            var result = bias
            for tree in trees {
                var index = 0
                while tree[index].feature >= 0 {
                    let node = tree[index]
                    index = features[node.feature] <= node.threshold! ? node.left! : node.right!
                }
                result += learningRate * tree[index].value!
            }
            return result
        }
    }
    struct Configuration: Codable, Equatable, Sendable {
        let overlapThreshold: Double
        let scoreMargin: Double
        /// Nil disables content admission. This is not a recognition threshold.
        var minimumScore: Double? = nil
        /// At most one close-scoring alternative per producer branch and
        /// representative. Branch identity is evidence, never text ownership.
        var ambiguityMargin: Double? = nil
        /// Resolve branch ambiguity through observed evidence dominance rather
        /// than retaining one alternative independently for every producer.
        var supportAwarePortfolio: Bool? = nil
        /// Broader direct cover is permitted only with measured multi-producer
        /// agreement and no weaker observed detector localization.
        var supportedOverlapThreshold: Double? = nil
    }
    struct Replacement: Codable, Equatable, Sendable {
        let inputIndex: Int
        let representativeIndex: Int
        let polygonIoU: Double
    }
    struct Report: Codable, Equatable, Sendable {
        let inputCount: Int
        let keptIndices: [Int]
        let scores: [Double?]
        let replacements: [Replacement]
        let admittedOutIndices: [Int]
        let configuration: Configuration
        var ambiguityFallbackIndices: [Int] = []
        var usesObservedRecognitionAgreement: Bool = false
        var freshRecognitionOfAllCandidates: Bool = false
        var referenceInventoryCount: Int? = nil
    }
    struct Result: Sendable { let output: G.Output; let report: Report }
    enum Failure: Error { case invalidModel, invalidConfiguration, unknownFeature(String) }

    static func family(_ record: G.Record) -> String {
        let parts = record.alternativeID.split(separator: "/", omittingEmptySubsequences: false)
        if parts.first == "source-paint", parts.count > 3 { return "paint/" + parts[3] }
        return parts.first.map(String.init) ?? ""
    }

    static func branch(_ record: G.Record) -> String {
        let parts = record.alternativeID.split(separator: "/", omittingEmptySubsequences: false)
        if parts.first?.hasPrefix("learned-boundary") == true, parts.count > 2 {
            // Ignore model hashes and source indices; retain the input evidence kind.
            return String(parts[0]) + "/" + parts[2]
        }
        return family(record)
    }

    /// Directional overlap distinguishes an enclosing boundary from a clipped
    /// one without absolute coordinates, dimensions, aspect ratios or pixels.
    private static func overlap(_ candidate: D.Shape, _ reference: D.Shape) -> (Double, Double, Double) {
        let iou = D.intersectionIoU(candidate, reference, minimum: 0)
        let intersection = iou * (candidate.area + reference.area) / (1 + iou)
        return (iou, intersection / max(candidate.area, 1e-12), intersection / max(reference.area, 1e-12))
    }

    static func features(_ input: G.Output, context: Context, names: [String],
                         referenceInventory: G.Output? = nil) throws -> [[Double]] {
        let rows = input.individuals
        let shapes = rows.map { D.Shape($0.polygon) }
        // Pruning emission must not erase already measured same-frame evidence
        // and silently change the score of a surviving polygon.
        let sourceRows = (referenceInventory ?? input).individuals
        let sourceShapes = sourceRows.map { D.Shape($0.polygon) }
        let families = sourceRows.map { Set($0.provenance.map(family)) }
        let inventory = Set(families.flatMap { $0 })
        let references = Dictionary(uniqueKeysWithValues: inventory.map { name in
            (name, sourceRows.indices.filter { families[$0].contains(name) })
        })
        let detectors = context.detectors.map { D.Shape($0.polygon) }
        let recognition = context.recognition.map { D.Shape($0.polygon) }
        let layout = context.layout.map { D.Shape($0.polygon) }
        return try rows.indices.map { index in
            let shape = shapes[index]
            var values = ["bboxConfidence": rows[index].bboxConfidence ?? 0]
            for (family, indices) in references {
                var best = -1.0
                var winner: Int?
                var coverage = (0.0, 0.0)
                for other in indices {
                    let measured = overlap(shape, sourceShapes[other])
                    if measured.0 > best {
                        best = measured.0; winner = other; coverage = (measured.1, measured.2)
                    }
                }
                values["iou/" + family] = max(0, best)
                values["candidateCoverage/" + family] = coverage.0
                values["referenceCoverage/" + family] = coverage.1
                values["referenceConfidence/" + family] = winner.flatMap { sourceRows[$0].bboxConfidence } ?? 0
            }
            for semantic in 0..<4 {
                var maxima = [0.0, 0, 0, 0]
                for j in context.layout.indices where context.layout[j].semanticClass == semantic {
                    let measured = overlap(shape, layout[j]), confidence = context.layout[j].confidence
                    maxima[0] = max(maxima[0], measured.1 * confidence)
                    maxima[1] = max(maxima[1], measured.1)
                    maxima[2] = max(maxima[2], measured.0)
                    if measured.1 >= 0.5 { maxima[3] = max(maxima[3], confidence) }
                }
                for (j, name) in ["confidenceCoverage", "coverage", "iou", "confidenceAtHalf"].enumerated() {
                    values["rf\(semantic)/\(name)"] = maxima[j]
                }
            }
            var best = -1.0
            for j in detectors.indices {
                let measured = overlap(shape, detectors[j])
                if measured.0 > best {
                    best = measured.0
                    values["detectorIoU"] = measured.0
                    values["detectorCoverage"] = measured.1
                    values["detectorConfidence"] = context.detectors[j].confidence
                }
            }
            for j in recognition.indices {
                let iou = overlap(shape, recognition[j]).0
                values["recognitionIoU"] = max(values["recognitionIoU"] ?? 0, iou)
                values["recognitionConfidenceAgreement"] = max(values["recognitionConfidenceAgreement"] ?? 0,
                    iou * context.recognition[j].confidence)
            }
            return try names.map { name in
                if let value = values[name] { return value }
                let prefix = name.split(separator: "/").first.map(String.init) ?? ""
                if ["iou", "candidateCoverage", "referenceCoverage", "referenceConfidence"].contains(prefix)
                    || name.hasPrefix("detector") || name.hasPrefix("recognition") { return 0 }
                throw Failure.unknownFeature(name)
            }
        }
    }

    private struct InstanceMembership: Hashable {
        let requestID: String
        let members: Set<Int>
    }

    static func apply(_ input: G.Output, context: Context, model: Model,
                      configuration: Configuration, referenceInventory: G.Output? = nil) throws -> Result {
        try model.validate()
        guard configuration.overlapThreshold.isFinite, configuration.overlapThreshold > 0,
              configuration.overlapThreshold <= 1, configuration.scoreMargin.isFinite,
              configuration.scoreMargin >= 0, configuration.minimumScore?.isFinite != false,
              configuration.ambiguityMargin?.isFinite != false,
              (configuration.ambiguityMargin ?? 0) >= 0,
              configuration.supportedOverlapThreshold?.isFinite != false,
              (configuration.supportedOverlapThreshold ?? configuration.overlapThreshold) > 0,
              (configuration.supportedOverlapThreshold ?? configuration.overlapThreshold) <= configuration.overlapThreshold else {
            throw Failure.invalidConfiguration
        }
        let rows = input.individuals
        let matrix = try features(input, context: context, names: model.featureNames, referenceInventory: referenceInventory)
        let shapes = rows.map { D.Shape($0.polygon) }
        let scores: [Double?] = rows.indices.map { index in
            guard shapes[index].convex, let confidence = rows[index].bboxConfidence,
                  confidence.isFinite, (0...1).contains(confidence), matrix[index].allSatisfy(\.isFinite) else { return nil }
            let value = model.predict(matrix[index])
            return value.isFinite ? value : nil
        }
        let detectorColumn = model.featureNames.firstIndex(of: "detectorIoU")
        let recognitionColumn = model.featureNames.firstIndex(of: "recognitionConfidenceAgreement")
        let agreementColumns = model.featureNames.indices.filter {
            model.featureNames[$0].hasPrefix("iou/")
                && !model.featureNames[$0].hasPrefix("iou/paint/")
        }
        func agreement(_ index: Int) -> Int {
            agreementColumns.filter { matrix[index][$0] >= configuration.overlapThreshold }.count
        }
        func supportDominates(_ winner: Int, _ index: Int) -> Bool {
            guard let detectorColumn, let recognitionColumn, !agreementColumns.isEmpty,
                  matrix[winner][detectorColumn] >= matrix[index][detectorColumn],
                  let confidence = rows[index].bboxConfidence,
                  let winnerConfidence = rows[winner].bboxConfidence,
                  winnerConfidence >= 0.85 * confidence,
                  agreement(winner) >= max(2, agreement(index)),
                  matrix[index][recognitionColumn] <= max(0.85, matrix[winner][recognitionColumn]) else { return false }
            return true
        }
        let ranked = rows.indices.sorted {
            let a = scores[$0] ?? -.infinity, b = scores[$1] ?? -.infinity
            if a != b { return a > b }
            let ac = rows[$0].bboxConfidence ?? -1, bc = rows[$1].bboxConfidence ?? -1
            return ac == bc ? $0 < $1 : ac > bc
        }
        var removed = Set<Int>(), retained = Set<Int>(), rejected = [Int](), replacements = [Replacement]()
        for index in ranked where !removed.contains(index) {
            guard let score = scores[index] else { retained.insert(index); continue }
            if let floor = configuration.minimumScore, score < floor {
                rejected.append(index); removed.insert(index); continue
            }
            retained.insert(index)
            for other in rows.indices where other != index && !retained.contains(other) && !removed.contains(other) {
                guard let otherScore = scores[other], score - otherScore >= configuration.scoreMargin else { continue }
                let directThreshold = configuration.supportAwarePortfolio == true
                    && agreement(index) >= 4 && supportDominates(index, other)
                    ? (configuration.supportedOverlapThreshold ?? configuration.overlapThreshold) : configuration.overlapThreshold
                let iou = D.intersectionIoU(shapes[index], shapes[other], minimum: directThreshold)
                if iou >= directThreshold {
                    removed.insert(other)
                    replacements.append(.init(inputIndex: other, representativeIndex: index, polygonIoU: iou))
                }
            }
        }
        var fallback = Set<Int>()
        if let margin = configuration.ambiguityMargin {
            var buckets: [Int: [String: [Int]]] = [:]
            for replacement in replacements {
                let index = replacement.inputIndex, winner = replacement.representativeIndex
                guard let first = scores[winner], let second = scores[index], first - second <= margin else { continue }
                // Admission applies to ambiguity fallbacks too; otherwise a
                // suppressed candidate can bypass the configured score floor.
                if let floor = configuration.minimumScore, second < floor { continue }
                guard Set(rows[index].polygon) != Set(rows[winner].polygon) else { continue }
                // Detached paint/query contexts are not source-backed fallbacks.
                // Retaining all of them would simply recreate the proposal bank.
                let sourceRecords = rows[index].provenance.filter { !$0.alternativeID.hasPrefix("source-paint/") }
                let immutableBoundary = sourceRecords.contains {
                    $0.alternativeID.hasPrefix("original/") || $0.alternativeID.hasPrefix("corrected/")
                        || $0.alternativeID.hasPrefix("layout/")
                }
                // A close learned score alone cannot justify keeping another
                // correction: it also needs no weaker measured DB evidence.
                // Original/current observed boundaries remain safety anchors.
                guard immutableBoundary || (rows[index].bboxConfidence ?? -1) >= (rows[winner].bboxConfidence ?? -1) else {
                    continue
                }
                for name in Set(sourceRecords.map(branch)) {
                    buckets[winner, default: [:]][name, default: []].append(index)
                }
            }
            for branches in buckets.values {
                for indices in branches.values {
                    // Stable quality/confidence order, independently of dictionary iteration.
                    let membership = Set(indices)
                    if let winner = ranked.first(where: { membership.contains($0) }) { fallback.insert(winner) }
                }
            }
            if configuration.supportAwarePortfolio == true {
                // A confidence-only alternative is not independent geometric
                // uncertainty when multiple source producers support the winner.
                for replacement in replacements where fallback.contains(replacement.inputIndex) {
                    let index = replacement.inputIndex, winner = replacement.representativeIndex
                    guard supportDominates(winner, index) else { continue }
                    fallback.remove(index)
                }
            }

            retained.formUnion(fallback)
            replacements.removeAll { fallback.contains($0.inputIndex) }
        }
        // Ambiguity restoration is branch-local; it can leave several almost
        // identical boundaries for the SAME observed membership. Re-elect those
        // boundaries globally using the already measured score/confidence order.
        // Empty membership and differing text groups cannot establish identity.
        // A query/search parent alone is deliberately never an instance key.
        let instanceKeys: [Set<InstanceMembership>?] = rows.map { row in
            guard !row.provenance.isEmpty, row.provenance.allSatisfy({ !$0.sourceMembers.isEmpty }) else { return nil }
            return Set(row.provenance.map { InstanceMembership(requestID: $0.requestID, members: $0.sourceMembers) })
        }
        let instanceOverlap = max(0.98, configuration.overlapThreshold)
        var instances: [Set<InstanceMembership>: [Int]] = [:]
        // A fallback must not reintroduce the same quad with another cyclic
        // start/winding. Choose an existing row; never union its provenance.
        var exact: [Set<G.Point>: Int] = [:]
        var aliases: [Int: Int] = [:]
        for index in ranked where retained.contains(index) && scores[index] != nil && shapes[index].convex {
            let key = Set(rows[index].polygon)
            if let winner = exact[key] {
                retained.remove(index); fallback.remove(index); aliases[index] = winner
            } else if let identity = instanceKeys[index],
                      let winner = instances[identity]?.first(where: {
                          D.intersectionIoU(shapes[$0], shapes[index], minimum: instanceOverlap) >= instanceOverlap
                      }) {
                retained.remove(index); fallback.remove(index); aliases[index] = winner
            } else {
                exact[key] = index
                if let identity = instanceKeys[index] { instances[identity, default: []].append(index) }
            }
        }
        replacements = replacements.map { replacement in
            let winner = aliases[replacement.representativeIndex] ?? replacement.representativeIndex
            let iou = winner == replacement.representativeIndex ? replacement.polygonIoU
                : D.intersectionIoU(shapes[replacement.inputIndex], shapes[winner], minimum: 0)
            return .init(inputIndex: replacement.inputIndex, representativeIndex: winner, polygonIoU: iou)
        }
        replacements += aliases.sorted { $0.key < $1.key }.map {
            .init(inputIndex: $0.key, representativeIndex: $0.value,
                  polygonIoU: D.intersectionIoU(shapes[$0.key], shapes[$0.value], minimum: 0))
        }
        let kept = rows.indices.filter { retained.contains($0) }
        let usesRecognition = model.trees.flatMap { $0 }.contains { node in
            node.feature >= 0 && model.featureNames[node.feature].hasPrefix("recognition")
        }
        return .init(output: G.selecting(input, indices: kept), report: .init(inputCount: rows.count,
            keptIndices: kept, scores: scores, replacements: replacements, admittedOutIndices: rejected,
            configuration: configuration, ambiguityFallbackIndices: fallback.sorted(),
            usesObservedRecognitionAgreement: usesRecognition, freshRecognitionOfAllCandidates: false,
            referenceInventoryCount: (referenceInventory ?? input).individuals.count))
    }
}
