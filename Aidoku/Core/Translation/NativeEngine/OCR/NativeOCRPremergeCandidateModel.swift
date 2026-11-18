import Foundation

/// Standalone numeric inference only. The caller supplies source55-v1 features in featureNames order.
/// No image, text, polygon extraction, candidate identity, or training-label lookup occurs here.
/// Scores are boosted regression outputs, not probabilities. Unavailable/invalid evidence is kept.
struct NativeOCRPremergeCandidateModel: Sendable {
    static let featureNames: [String] = [
        "logShortSide",
        "logLongSide",
        "logAspect",
        "areaFrameFraction",
        "sin2Axis",
        "cos2Axis",
        "normalFrameFraction",
        "alongFrameFraction",
        "detectorAvailable",
        "detectorConfidence",
        "detectorReferenceIoU",
        "detectorCurrentIoU",
        "detectorCurrentCoverage",
        "rf0_maxConfidenceCoverage",
        "rf0_maxCoverage",
        "rf0_maxIoU",
        "rf0_confidenceAtHalfCoverage",
        "rf1_maxConfidenceCoverage",
        "rf1_maxCoverage",
        "rf1_maxIoU",
        "rf1_confidenceAtHalfCoverage",
        "rf2_maxConfidenceCoverage",
        "rf2_maxCoverage",
        "rf2_maxIoU",
        "rf2_confidenceAtHalfCoverage",
        "rf3_maxConfidenceCoverage",
        "rf3_maxCoverage",
        "rf3_maxIoU",
        "rf3_confidenceAtHalfCoverage",
        "recAvailable",
        "recConfidence",
        "recLogCharacters",
        "recHiraganaFraction",
        "recKatakanaFraction",
        "recCJKFraction",
        "recLatinFraction",
        "recDigitFraction",
        "recPunctuationFraction",
        "recMaxCharacterRepeat",
        "recCharacterEntropy",
        "recMinTokenConfidence",
        "recMeanTokenConfidence",
        "recTokensAvailable",
        "recObservedEmpty",
        "recQuestionExclamationOnly",
        "recSymbolFraction",
        "recReferenceIoU",
        "recCurrentIoU",
        "recCurrentCoverage",
        "pixelGrayStd",
        "pixelGradientMean",
        "pixelBorderContrastFraction",
        "pixelSaturationMean",
        "pixelBorderGrayStd",
        "pixelGrayEntropy",
    ]

    enum Failure: String, Error, Sendable {
        case missingModel, malformedModel, invalidFeatures, nonfiniteScore, outsideTrainingSupport
    }

    struct Decision: Sendable {
        let keep: Bool
        let score: Double?
        let failure: Failure?
        let punctuationPreserved: Bool
    }

    // Fixed numeric ABI limits, independent of corpus rows or training labels.
    static let maximumModelBytes = 8 * 1024 * 1024
    private static let booleanIndices: Set<Int> = [8, 29, 42, 43, 44]
    static func featureBounds(at index: Int) -> ClosedRange<Double>? {
        switch index {
        case 0...2: return -32...32 // log lengths/aspect; finite geometry guard
        case 4...5: return (-1 - 1e-12)...(1 + 1e-12)
        case 6...7: return 0...2 // normalized extents; caller owns geometry
        case 10...12, 46...48: return 0...1.05 // float32 polygon association tolerance
        case 31: return 0...32 // log1p character count
        case 3, 8...9, 13...30, 32...45, 49...54: return 0...(1 + 1e-12)
        default: return nil
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func requireKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard Set(container.allKeys.map(\.stringValue)) == expected else { throw Failure.malformedModel }
    }

    private struct Node: Codable, Sendable {
        let feature: Int
        let value: Double?
        let threshold: Double?
        let left: Int?
        let right: Int?

        enum CodingKeys: String, CodingKey { case feature, value, threshold, left, right }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            feature = try container.decode(Int.self, forKey: .feature)
            if feature == -1 {
                try NativeOCRPremergeCandidateModel.requireKeys(decoder, ["feature", "value"])
                value = try container.decode(Double.self, forKey: .value)
                threshold = nil
                left = nil
                right = nil
            } else {
                try NativeOCRPremergeCandidateModel.requireKeys(decoder, ["feature", "threshold", "left", "right"])
                value = nil
                threshold = try container.decode(Double.self, forKey: .threshold)
                left = try container.decode(Int.self, forKey: .left)
                right = try container.decode(Int.self, forKey: .right)
            }
        }
    }

    /// Metadata is validated and retained for provenance; it never selects candidate behavior.
    private struct Payload: Codable, Sendable {
        let schema: String
        let bias: Double
        let learningRate: Double
        let featureNames: [String]
        let trees: [[Node]]
        let keepThreshold: Double
        let punctuationAlwaysKept: Bool
        let punctuationPolicy: String?
        let rfDominanceFactor: Double?
        let role: String
        let trainingTarget: String
        let trainingOnlyGT: Bool

        enum CodingKeys: String, CodingKey {
            case schema, bias, learningRate, featureNames, trees, keepThreshold
            case punctuationAlwaysKept, role, trainingTarget, trainingOnlyGT
            case punctuationPolicy
            case rfDominanceFactor
        }
        init(from decoder: Decoder) throws {
            var keys: Set<String> = [
                "schema", "bias", "learningRate", "featureNames", "trees", "keepThreshold",
                "punctuationAlwaysKept", "role", "trainingTarget", "trainingOnlyGT"
            ]
            let raw = try decoder.container(keyedBy: Key.self)
            if raw.allKeys.contains(where: { $0.stringValue == "punctuationPolicy" }) {
                keys.insert("punctuationPolicy")
            }
            if raw.allKeys.contains(where: { $0.stringValue == "rfDominanceFactor" }) {
                keys.insert("rfDominanceFactor")
            }
            try NativeOCRPremergeCandidateModel.requireKeys(decoder, keys)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try container.decode(String.self, forKey: .schema)
            bias = try container.decode(Double.self, forKey: .bias)
            learningRate = try container.decode(Double.self, forKey: .learningRate)
            featureNames = try container.decode([String].self, forKey: .featureNames)
            trees = try container.decode([[Node]].self, forKey: .trees)
            keepThreshold = try container.decode(Double.self, forKey: .keepThreshold)
            punctuationAlwaysKept = try container.decode(Bool.self, forKey: .punctuationAlwaysKept)
            punctuationPolicy = try container.decodeIfPresent(String.self, forKey: .punctuationPolicy)
            rfDominanceFactor = try container.decodeIfPresent(Double.self, forKey: .rfDominanceFactor)
            role = try container.decode(String.self, forKey: .role)
            trainingTarget = try container.decode(String.self, forKey: .trainingTarget)
            trainingOnlyGT = try container.decode(Bool.self, forKey: .trainingOnlyGT)
        }
    }

    private struct UnionPayload: Decodable {
        let schema: String
        let members: [Payload]
        let support: [Support]

        init(from decoder: Decoder) throws {
            try NativeOCRPremergeCandidateModel.requireKeys(decoder, ["schema", "members", "support"])
            let container = try decoder.container(keyedBy: Key.self)
            schema = try container.decode(String.self, forKey: Key(stringValue: "schema")!)
            members = try container.decode([Payload].self, forKey: Key(stringValue: "members")!)
            support = try container.decode([Support].self, forKey: Key(stringValue: "support")!)
        }
    }

    private struct Support: Decodable, Sendable {
        let feature: Int
        let lower: Double
        let upper: Double
    }

    private let payload: Payload?
    private let alternatives: [Payload]
    private let support: [Support]
    private let groupCalibrated: Bool
    let loadFailure: Failure?
    var isAvailable: Bool { payload != nil || !alternatives.isEmpty }
    var keepThreshold: Double? { payload?.keepThreshold ?? (alternatives.isEmpty ? nil : 0) }
    var keepsStandalonePunctuation: Bool? {
        guard let payload else { return nil }
        if payload.punctuationPolicy == "score" { return nil }
        return payload.punctuationAlwaysKept
    }
    var treeCount: Int { payload?.trees.count ?? alternatives.reduce(0) { $0 + $1.trees.count } }
    var trainingTarget: String? { payload?.trainingTarget ?? alternatives.first?.trainingTarget }
    var isFixedEvidenceRule: Bool {
        payload?.role == "premerge-fixed-confidence-rf-evidence" && payload?.trainingOnlyGT == false && usesOnlyConfidenceAndRF
    }
    var isAdmittedSignalFilter: Bool {
        // Fitted research bundles remain offline after held-out false negatives.
        if groupCalibrated { return false }
        return isFixedEvidenceRule
    }
    var usesOnlyConfidenceAndRF: Bool {
        let models = payload.map { [$0] } ?? alternatives
        return !models.isEmpty && support.allSatisfy({ (8...30).contains($0.feature) }) && models.allSatisfy {
            $0.punctuationPolicy == "score" && $0.trees.allSatisfy { tree in
                tree.allSatisfy { $0.feature == -1 || (8...30).contains($0.feature) }
            }
        }
    }

    /// Missing data and every decoding/validation failure produce a usable fail-open scorer.
    init(data: Data?) {
        guard let data else {
            payload = nil
            alternatives = []
            support = []
            groupCalibrated = false
            loadFailure = .missingModel
            return
        }
        do {
            guard !data.isEmpty, data.count <= Self.maximumModelBytes else { throw Failure.malformedModel }
            let decoder = JSONDecoder()
            if let union = try? decoder.decode(UnionPayload.self, from: data) {
                guard ["source55-conservative-union-v1", "source55-group-calibrated-union-v1"].contains(union.schema),
                      (2...5).contains(union.members.count),
                      union.members.reduce(0, { $0 + $1.trees.count }) <= 512,
                      union.members.allSatisfy({ $0.punctuationPolicy == "score" }),
                      (1...47).contains(union.support.count),
                      Set(union.support.map(\.feature)).count == union.support.count,
                      union.support.allSatisfy({
                          (8..<55).contains($0.feature) && $0.lower.isFinite && $0.upper.isFinite &&
                          $0.lower <= $0.upper && abs($0.lower) <= 1e6 && abs($0.upper) <= 1e6
                      }) else { throw Failure.malformedModel }
                for member in union.members { try Self.validate(member) }
                let grouped = union.schema == "source55-group-calibrated-union-v1"
                if grouped {
                    guard union.members.count == 3, union.support.allSatisfy({ (8...30).contains($0.feature) }),
                          union.members.allSatisfy({ member in
                              member.trees.count == 48 && member.learningRate == 0.1 &&
                              member.trees.allSatisfy { tree in
                                  var depths = Array(repeating: 0, count: tree.count)
                                  for (index, node) in tree.enumerated() {
                                      guard depths[index] <= 2,
                                            node.feature == -1 || (8...30).contains(node.feature) else { return false }
                                      if let left = node.left, let right = node.right {
                                          depths[left] = depths[index] + 1; depths[right] = depths[index] + 1
                                      }
                                  }
                                  return true
                              }
                          }) else { throw Failure.malformedModel }
                }
                payload = nil
                alternatives = union.members
                support = union.support
                groupCalibrated = grouped
            } else {
                let decoded = try decoder.decode(Payload.self, from: data)
                try Self.validate(decoded)
                payload = decoded
                alternatives = []
                support = []
                groupCalibrated = false
            }
            loadFailure = nil
        } catch {
            payload = nil
            alternatives = []
            support = []
            groupCalibrated = false
            loadFailure = .malformedModel
        }
    }

    /// Bounded local-file loading; failure never licenses rejection.
    init(contentsOf url: URL) {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else {
            self.init(data: nil)
            return
        }
        defer { try? handle.close() }
        do {
            let data = try handle.read(upToCount: Self.maximumModelBytes + 1) ?? Data()
            self.init(data: data)
        } catch {
            self.init(data: nil)
        }
    }

    private static func validate(_ model: Payload) throws {
        func bounded(_ value: Double) -> Bool { value.isFinite && abs(value) <= 1e6 }
        guard model.schema == "numeric-hist-gradient-boost-v1",
              model.featureNames == featureNames, featureNames.count == 55,
              ((model.role == "premerge-candidate-content-keep-score" && model.trainingOnlyGT) ||
               (model.role == "premerge-fixed-confidence-rf-evidence" && !model.trainingOnlyGT)),
              !model.trainingTarget.isEmpty, model.trainingTarget.utf8.count <= 256,
              bounded(model.bias), bounded(model.keepThreshold),
              model.punctuationPolicy == nil ||
                (model.punctuationPolicy == "score" && !model.punctuationAlwaysKept),
              model.rfDominanceFactor == nil ||
                (model.role == "premerge-fixed-confidence-rf-evidence" && !model.trainingOnlyGT &&
                 model.rfDominanceFactor!.isFinite && (1...10).contains(model.rfDominanceFactor!)),
              model.learningRate.isFinite, model.learningRate > 0, model.learningRate <= 1,
              (1...512).contains(model.trees.count),
              model.trees.reduce(0, { $0 + $1.count }) <= 65_536 else { throw Failure.malformedModel }
        for tree in model.trees {
            guard (1...127).contains(tree.count) else { throw Failure.malformedModel }
            var parents = Array(repeating: 0, count: tree.count)
            var depths = Array(repeating: 0, count: tree.count)
            for (index, node) in tree.enumerated() {
                guard depths[index] <= 16 else { throw Failure.malformedModel }
                if node.feature == -1 {
                    guard let value = node.value, bounded(value) else { throw Failure.malformedModel }
                } else {
                    guard let bounds = featureBounds(at: node.feature),
                          let threshold = node.threshold, threshold.isFinite, bounds.contains(threshold),
                          let left = node.left, let right = node.right,
                          left > index, right > index, left < tree.count, right < tree.count, left != right
                    else { throw Failure.malformedModel }
                    for child in [left, right] {
                        parents[child] += 1
                        depths[child] = depths[index] + 1
                    }
                }
            }
            // Forward-only children + exactly one parent prove a rooted, acyclic, fully reachable tree.
            guard parents[0] == 0, parents.dropFirst().allSatisfy({ $0 == 1 }) else { throw Failure.malformedModel }
        }
    }

    /// Preserve the established strong box-evidence rule and add an independent
    /// native-mask confirmation path at RF's stock SFX acceptance confidence.
    /// Constants are global model-contract/evidence thresholds, never GT-fitted.
    /// Missing/invalid masks cannot introduce a new rejection.
    func evaluate(boxFeatures: [Double]?, maskFeatures: [Double]?) -> Decision {
        let baseline = evaluate(features: boxFeatures)
        guard baseline.keep, baseline.failure == nil, isAdmittedSignalFilter,
              let mask = maskFeatures, evaluate(features: mask).failure == nil else { return baseline }
        let dominantSFX = mask[8] > 0.5 && mask[29] > 0.5 && mask[9] >= 0.25 && mask[10] >= 0.3 &&
            mask[20] >= 0.2 && mask[18] >= 0.8 && mask[17] >= 0.16 &&
            mask[17] >= 2 * max(mask[13], mask[21])
        guard dominantSFX else { return baseline }
        return Decision(keep: false, score: min(baseline.score ?? 0, (keepThreshold ?? 0) - 1),
                        failure: nil, punctuationPreserved: false)
    }

    func evaluate(features: [Double]?) -> Decision {
        let models = payload.map { [$0] } ?? alternatives
        guard !models.isEmpty else {
            return Decision(keep: true, score: nil, failure: loadFailure, punctuationPreserved: false)
        }
        guard let features, features.count == Self.featureNames.count else {
            return Decision(keep: true, score: nil, failure: .invalidFeatures, punctuationPreserved: false)
        }
        let validatedIndices = usesOnlyConfidenceAndRF ? 8...30 : 0...54
        for index in validatedIndices {
            let value = features[index]
            guard value.isFinite, let bounds = Self.featureBounds(at: index), bounds.contains(value),
                  !Self.booleanIndices.contains(index) || value == 0 || value == 1 else {
                return Decision(keep: true, score: nil, failure: .invalidFeatures, punctuationPreserved: false)
            }
        }
        if support.contains(where: { features[$0.feature] < $0.lower - 1e-6 || features[$0.feature] > $0.upper + 1e-6 }) {
            return Decision(keep: true, score: nil, failure: .outsideTrainingSupport, punctuationPreserved: false)
        }
        var bestScore = -Double.infinity
        var keep = false, punctuationPreserved = false
        for model in models {
            var score = model.bias
            for tree in model.trees {
                var index = 0
                while tree[index].feature != -1 {
                    let node = tree[index]
                    index = features[node.feature] <= node.threshold! ? node.left! : node.right!
                }
                let update = model.learningRate * tree[index].value!
                score += update
            }
            guard score.isFinite else {
                return Decision(keep: true, score: nil, failure: .nonfiniteScore, punctuationPreserved: false)
            }
            if let factor = model.rfDominanceFactor,
               features[17] < factor * max(features[13], features[21]) {
                // SFX must dominate both alternative RF supports; contradiction stays admitted.
                score = max(score, model.keepThreshold)
            }
            let punctuation = model.punctuationPolicy != "score" && features[44] > 0.5
            let accepted = punctuation && model.punctuationPolicy != "score"
                ? model.punctuationAlwaysKept : score >= model.keepThreshold
            keep = keep || accepted
            punctuationPreserved = punctuationPreserved || (accepted && punctuation && model.punctuationAlwaysKept)
            // A union keeps if any member's calibrated margin is nonnegative.
            // Single-model scores retain the original raw-score ABI.
            bestScore = max(bestScore, payload == nil ? score - model.keepThreshold : score)
        }
        return Decision(keep: keep, score: bestScore, failure: nil, punctuationPreserved: punctuationPreserved)
    }
}
