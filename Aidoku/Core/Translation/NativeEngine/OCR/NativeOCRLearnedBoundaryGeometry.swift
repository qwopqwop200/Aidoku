import CoreGraphics
import CryptoKit
import Foundation

/// Default-off actual learned corrections. No GT, per-row catalogs, text or recognition.
/// Source344 stays Double; one mean prediction preserves the frozen model identity.
@available(iOS 18.0, *)
enum NativeOCRLearnedBoundaryGeometry {
    typealias G = NativeOCRIndividualGeometryHypotheses
    static let environmentKey = "AIDOKU_OCR_LEARNED_BOUNDARY_MODELS"
    static let policyEnvironmentKey = "AIDOKU_OCR_LEARNED_BOUNDARY_POLICY"
    static let inputPolicyEnvironmentKey = "AIDOKU_OCR_LEARNED_BOUNDARY_INPUTS"
    enum InputPolicy: String, Codable, Sendable {
        case sourceStages = "source-stages"
    }
    static func inputPolicy(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> InputPolicy {
        guard let name = environment[inputPolicyEnvironmentKey], !name.isEmpty else { return .sourceStages }
        guard let policy = InputPolicy(rawValue: name) else { throw Failure.invalidPolicy("\(inputPolicyEnvironmentKey)=\(name)") }
        return policy
    }
    /// A stage is a recorded localization, never ownership of text inside it.
    /// Do not recalibrate refinements, contextual copies or learned outputs.
    /// Keeping all three source stages also preserves canonical paint seeds.
    static func acceptsInput(_ record: G.Record, policy: InputPolicy) -> Bool {
        switch record.origin {
        case .corrected: return record.alternativeID == "corrected/\(record.sourceIndex)"
        case .sourceOriginal: return record.alternativeID == "original/\(record.sourceIndex)"
        case .sourceLayout: return record.alternativeID.hasPrefix("layout/")
        case .sourceRefinement: return false
        }
    }
    static let consensusEnvironmentKey = "AIDOKU_OCR_LEARNED_BOUNDARY_CONSENSUS"
    static let consensusIoUEnvironmentKey = "AIDOKU_OCR_LEARNED_BOUNDARY_CONSENSUS_IOU"
    enum ConsensusPolicy: String, Sendable {
        case off
        case reciprocalCorrected080 = "reciprocal-corrected-080"
    }
    struct ConsensusProof: Codable, Sendable {
        let policy: String
        let original: G.Record
        let corrected: G.Record
        let intersectionOverUnion: Double
    }
    /// Preflight only for the legacy and 376 heads. V2/current, legacy/original,
    /// and 376/layout remain canonical paint seeds. Never filter the input array:
    /// reservations, ordinals, source evidence and independent-head contexts stay intact.
    static func consensusPreflight(requestID: String, input: [G.Individual], policy: InputPolicy,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [Int: ConsensusProof] {
        let name = environment[consensusEnvironmentKey] ?? ConsensusPolicy.off.rawValue
        guard let consensus = ConsensusPolicy(rawValue: name) else {
            throw Failure.invalidPolicy("\(consensusEnvironmentKey)=\(name)")
        }
        guard consensus == .reciprocalCorrected080 else { return [:] }
        let minimumName = environment[consensusIoUEnvironmentKey] ?? "0.8"
        guard let minimumIoU = Double(minimumName), minimumIoU.isFinite, (0.8...1).contains(minimumIoU) else {
            throw Failure.invalidPolicy("\(consensusIoUEnvironmentKey)=\(minimumName)")
        }
        guard policy == .sourceStages, !requestID.isEmpty else { return [:] }
        var originals: [String: G.Record] = [:], corrected: [String: G.Record] = [:]
        var conflicts = Set<String>()
        for row in input {
            for record in row.provenance {
                guard record.requestID == requestID, record.sourceIndex >= 0, record.sourceParent >= 0,
                      validQuad(record.polygon), sameQuad(record.polygon, row.polygon) else { continue }
                let isOriginal = record.origin == .sourceOriginal && record.alternativeID == "original/\(record.sourceIndex)"
                let isCorrected = record.origin == .corrected && record.alternativeID == "corrected/\(record.sourceIndex)"
                guard isOriginal || isCorrected else { continue }
                if let previous = originals[record.alternativeID] ?? corrected[record.alternativeID],
                   !sameQuad(previous.polygon, record.polygon) { conflicts.insert(record.alternativeID) }
                if isOriginal { originals[record.alternativeID] = record }
                else { corrected[record.alternativeID] = record }
            }
        }
        // A conflicting observation makes the entire association unavailable.
        guard conflicts.isEmpty else { return [:] }
        let raw = originals.values.sorted { $0.alternativeID < $1.alternativeID }
        let current = corrected.values.sorted { $0.alternativeID < $1.alternativeID }
        guard !raw.isEmpty, !current.isEmpty else { return [:] }
        struct Best {
            var index: Int?
            var score: Double = 0
            var tied = false
            mutating func observe(_ score: Double, index: Int) {
                if score > self.score { self.score = score; self.index = index; tied = false }
                else if score == self.score { tied = true }
            }
        }
        var rawBest = Array(repeating: Best(), count: raw.count)
        var currentBest = Array(repeating: Best(), count: current.count)
        for i in raw.indices {
            for j in current.indices {
                let score = NativeOCRGeometryDeduplication.polygonIoU(raw[i].polygon, current[j].polygon)
                rawBest[i].observe(score, index: j)
                currentBest[j].observe(score, index: i)
            }
        }
        var agreement: [String: ConsensusProof] = [:]
        for j in current.indices {
            let best = currentBest[j]
            guard !best.tied, best.score >= minimumIoU, let i = best.index,
                  !rawBest[i].tied, rawBest[i].index == j else { continue }
            agreement[current[j].alternativeID] = .init(policy: consensus.rawValue,
                original: raw[i], corrected: current[j], intersectionOverUnion: best.score)
        }
        // Duplicate identities can make first-emitter precedence significant.
        // Leave their original traversal untouched rather than choose a new winner.
        let identities = input.compactMap { representative($0, requestID: requestID)?.alternativeID }
        guard Set(identities).count == identities.count else { return [:] }
        var skipped: [Int: ConsensusProof] = [:]
        for (ordinal, row) in input.enumerated() {
            guard let first = row.provenance.first, let proof = agreement[first.alternativeID],
                  row.refinements.isEmpty,
                  row.provenance.allSatisfy({ $0.requestID == requestID && $0.origin == .corrected &&
                      $0.alternativeID == proof.corrected.alternativeID &&
                      $0.sourceIndex == proof.corrected.sourceIndex && $0.sourceParent == proof.corrected.sourceParent &&
                      sameQuad($0.polygon, row.polygon) }) else { continue }
            // Any original/layout/refinement alias protects this complete row.
            skipped[ordinal] = proof
        }
        return skipped
    }
    enum Policy: String, Codable, Sendable {
        case meanDepth6 = "mean-depth6"
    }
    static let modelFiles = ["generator0-runtime.json", "generator1-runtime.json", "utility-runtime.json"]
    static let featureABI = "442-near132-n0.4-a1-wide132-n0.8-a4-geometry80-baseline-only-authentic50nil-utility13float32-v1"

    enum Outcome: String, Codable, Sendable {
        case corrected, unchanged, invalidInput, ambiguousInput, conflictingIdentity, featureUnavailable, invalidProposal, nonSourceStageInput, sourceConsensusInput
    }
    struct CodableProof: Codable, Sendable {
        let requestID: String
        let inputOrdinal: Int
        let baseMaximumSourceIndex: Int
        let inputIndividual: G.Individual
        let inputRecord: G.Record?
        let inputQuad: [G.Point]
        let chosenQuad: [G.Point]
        let modelSHA: String
        let policy: Policy
        let fileSHA256: [String: String]
        let score: Double?
        let featureDigest: String?
        let featureABI: String
        let baselineUsed: Bool
        let internalOfferCount: Int
        let outputSourceIndex: Int?
        let outputAlternativeID: String?
        let sourceConsensus: ConsensusProof?
        let outcome: Outcome
    }
    struct Production: Sendable {
        let records: [G.Record]
        let decisions: [CodableProof]
    }
    enum Failure: Error {
        case invalidModels(String), invalidPolicy(String), modelFilesChanged, sourceIndexOverflow, invalidFrame, nonFiniteInput(Int)
    }

    private struct Models {
        let generator: NativeOCRLearnedBoundaryModel442.Bundle
        let fileHashes: [String: String]
        let bundleHash: String
    }
    /// Immutable forest values are shared behind a synchronous lock; no model/global mutation.
    private final class ModelCache: @unchecked Sendable {
        private let lock = NSLock()
        private var path: String?
        private var signatures: [String] = []
        private var cached: Models?
        func load(_ directory: String) throws -> Models {
            lock.lock(); defer { lock.unlock() }
            let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
            var current: [String] = []
            for name in modelFiles {
                let url = root.appendingPathComponent(name)
                let target = url.resolvingSymlinksInPath()
                let a = try FileManager.default.attributesOfItem(atPath: target.path)
                guard let bytes = a[.size] as? NSNumber, bytes.intValue > 0, bytes.intValue <= 64 * 1024 * 1024,
                      let date = a[.modificationDate] as? Date else { throw Failure.invalidModels(name) }
                current.append("\(target.path):\(bytes.intValue):\(date.timeIntervalSince1970):\(a[.systemFileNumber] ?? 0)")
            }
            if path == root.path, let cached {
                guard signatures == current else { throw Failure.modelFilesChanged }
                return cached
            }
            var data: [Data] = [], hashes: [String: String] = [:]
            for name in modelFiles {
                let bytes = try Data(contentsOf: root.appendingPathComponent(name), options: .mappedIfSafe)
                guard !bytes.isEmpty, bytes.count <= 64 * 1024 * 1024 else { throw Failure.invalidModels(name) }
                data.append(bytes); hashes[name] = digest(bytes)
            }
            try validateGeneratorJSON(data[0]); try validateGeneratorJSON(data[1]); try validateUtilityJSON(data[2])
            let generator = try NativeOCRLearnedBoundaryProposal442.Generator(data: data[0]).model
            // Retired sibling/utility files remain validated identity inputs: their
            // hashes bind existing candidate IDs, but they never generate offers.
            _ = try NativeOCRLearnedBoundaryProposal442.Generator(data: data[1])
            _ = try NativeOCRLearnedBoundaryUtility3.Model(data: data[2])
            let identity = featureABI + "\n" + modelFiles.map { $0 + ":" + hashes[$0]! }.joined(separator: "\n")
            let models = Models(generator: generator, fileHashes: hashes,
                                bundleHash: digest(Data(identity.utf8)))
            path = root.path; signatures = current; cached = models
            return models
        }
    }
    private static let modelCache = ModelCache()

    /// Parent calls baseline G.emit first, then passes these records into the SECOND
    /// G.emit corrected input alongside ALL baseline corrected rows. No G API changes.
    static func corrections(requestID: String, input: [G.Individual], frame: NativeOCRRGBAFrame,
                            baselines: [Int: [CGPoint]] = [:], reservedSourceIndices: [Int] = []) throws -> Production {
        guard let directory = ProcessInfo.processInfo.environment[environmentKey], !directory.isEmpty,
              !input.isEmpty else { return .init(records: [], decisions: []) }
        guard !requestID.isEmpty, frame.width > 0, frame.height > 0,
              frame.width <= Int.max / 4, frame.bytesPerRow >= frame.width * 4,
              frame.bytesPerRow <= Int.max / frame.height,
              frame.bytes.count >= frame.bytesPerRow * frame.height else { throw Failure.invalidFrame }
        for (ordinal, row) in input.enumerated() {
            let points = row.polygon + row.provenance.flatMap(\.polygon) + row.refinements.flatMap { $0.record.polygon }
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw Failure.nonFiniteInput(ordinal) }
        }
        let policyName = ProcessInfo.processInfo.environment[policyEnvironmentKey] ?? Policy.meanDepth6.rawValue
        guard let policy = Policy(rawValue: policyName) else { throw Failure.invalidPolicy(policyName) }
        let inputPolicy = try inputPolicy()
        let consensus = try consensusPreflight(requestID: requestID, input: input, policy: inputPolicy)
        let models = try modelCache.load(directory)
        let modelHash = digest(Data((models.bundleHash + "\npolicy:" + policy.rawValue).utf8))
        // Reserve the WHOLE currently observed namespace. Identity never enters features.
        var maximum = (reservedSourceIndices + Array(baselines.keys)).filter { $0 >= 0 }.max() ?? -1
        for individual in input {
            for r in individual.provenance + individual.refinements.map(\.record) {
                for value in [r.sourceIndex, r.sourceParent] + Array(r.sourceMembers) + (r.originalDetectorIndex.map { [$0] } ?? []) {
                    if value >= 0 { maximum = max(maximum, value) }
                }
            }
        }
        let start = maximum.addingReportingOverflow(1)
        let end = start.partialValue.addingReportingOverflow(input.count - 1)
        guard !start.overflow, !end.overflow else { throw Failure.sourceIndexOverflow }
        let identities = input.map { representative($0, requestID: requestID) }
        var identityQuads: [String: [G.Point]] = [:], conflicting = Set<String>()
        for (row, record) in zip(input, identities) {
            guard let record else { continue }
            if let old = identityQuads[record.alternativeID], !sameQuad(old, row.polygon) { conflicting.insert(record.alternativeID) }
            identityQuads[record.alternativeID] = row.polygon
        }
        var used = Set(input.flatMap(\.provenance).map(\.alternativeID))
        var records: [G.Record] = [], proofs: [CodableProof] = []
        // With opt-in consensus, establish the highest REAL emitted reservation
        // first. Keep evaluating the tail until one emits; only lower ordinals may
        // skip. This preserves downstream heads' maxima without synthetic records.
        let ordinals = consensus.isEmpty ? Array(input.indices) : Array(input.indices.reversed())
        for ordinal in ordinals {
            let row = input[ordinal]
            let record = identities[ordinal]
            var chosen = row.polygon, score: Double?, featureHash: String?, baselineUsed = false, offerCount = 0
            var outIndex: Int?, outID: String?, outcome: Outcome = .invalidInput
            if let record, validQuad(row.polygon) {
                let candidateID = "learned-boundary/\(modelHash)/\(record.alternativeID)"
                if conflicting.contains(record.alternativeID) || used.contains(candidateID) {
                    outcome = .conflictingIdentity
                } else if row.provenance.contains(where: { $0.requestID != requestID || $0.sourceParent != record.sourceParent }) {
                    outcome = .ambiguousInput
                } else if !acceptsInput(record, policy: inputPolicy) {
                    outcome = .nonSourceStageInput
                } else if consensus[ordinal] != nil && !records.isEmpty {
                    outcome = .sourceConsensusInput
                } else {
                    let baseline = baselineFor(row, requestID: requestID, baselines: baselines)
                    baselineUsed = baseline != nil
                    if let features = sourceFeatures(individual: row, frame: frame, baseline: baseline) {
                        featureHash = featureDigest(features)
                        // Exactly one mean prediction; model file identity stays frozen.
                        offerCount = 1; score = nil
                        let candidate = models.generator.predict(features: features).flatMap {
                            NativeOCRLearnedBoundaryGeometry442.polygon(residual: $0,
                                current: pairs(row.polygon), frame: [Double(frame.width), Double(frame.height)])
                        }
                        chosen = candidate?.map { G.Point(x: $0[0], y: $0[1]) } ?? row.polygon
                        if candidate == nil || !validQuad(chosen) { outcome = .invalidProposal; chosen = row.polygon }
                        else if sameQuad(chosen, row.polygon) { outcome = .unchanged }
                        else {
                            let proofSets = row.provenance.map(\.sourceMembers)
                            let known = !record.sourceMembers.isEmpty && record.sourceMembers.allSatisfy { $0 >= 0 } &&
                                proofSets.allSatisfy { $0 == record.sourceMembers }
                            let members = known ? record.sourceMembers : []
                            // Metadata unknown stays unknown, never promoted from virtual IDs.
                            let original = known && record.originalDetectorIndex.map({ members.contains($0) }) == true ? record.originalDetectorIndex : nil
                            let index = start.partialValue + ordinal
                            records.append(.init(requestID: requestID, sourceIndex: index,
                                sourceParent: record.sourceParent, sourceMembers: members, alternativeID: candidateID,
                                origin: .corrected, originalDetectorIndex: original, polygon: chosen))
                            used.insert(candidateID); outIndex = index; outID = candidateID; outcome = .corrected
                        }
                    } else { outcome = .featureUnavailable }
                }
            }
            proofs.append(.init(requestID: requestID, inputOrdinal: ordinal, baseMaximumSourceIndex: maximum, inputIndividual: row,
                inputRecord: record, inputQuad: row.polygon, chosenQuad: chosen,
                modelSHA: modelHash, policy: policy, fileSHA256: models.fileHashes, score: score,
                featureDigest: featureHash, featureABI: featureABI, baselineUsed: baselineUsed,
                internalOfferCount: offerCount, outputSourceIndex: outIndex, outputAlternativeID: outID, sourceConsensus: outcome == .sourceConsensusInput ? consensus[ordinal] : nil, outcome: outcome))
        }
        return .init(records: consensus.isEmpty ? records : Array(records.reversed()),
            decisions: consensus.isEmpty ? proofs : Array(proofs.reversed()))
    }

    /// Same frozen 344 extractor as agent1; no authentic50 or invented metadata.
    static func sourceFeatures(individual: G.Individual, frame: NativeOCRRGBAFrame,
                               baseline: [[Double]]?) -> [Double]? {
        let q = pairs(individual.polygon)
        guard let near = NativeOCRLearnedBoundaryRGB442.features(rgba: frame.bytes, width: frame.width,
            height: frame.height, bytesPerRow: frame.bytesPerRow, polygon: q),
              let wide = NativeOCRLearnedBoundaryRGB442.features(rgba: frame.bytes, width: frame.width,
            height: frame.height, bytesPerRow: frame.bytesPerRow, polygon: q, normalPadding: 0.8, alongPadding: 4),
              let geometry = NativeOCRLearnedBoundaryGeometry442.geometricFeatures(current: q,
                metadata: [baseline, nil, nil, nil], authenticSource50: nil) else { return nil }
        let features = near + wide + geometry
        return features.count == 344 && features.allSatisfy(\.isFinite) ? features : nil
    }
    private static func representative(_ row: G.Individual, requestID: String) -> G.Record? {
        guard !row.provenance.isEmpty, row.provenance.allSatisfy({
            $0.requestID == requestID && $0.sourceIndex >= 0 && $0.sourceParent >= 0 && !$0.alternativeID.isEmpty &&
                sameQuad($0.polygon, row.polygon)
        }) else { return nil }
        let corrected = row.provenance.filter { $0.origin == .corrected }
        return corrected.count == 1 ? corrected[0] : row.provenance[0]
    }
    private static func baselineFor(_ row: G.Individual, requestID: String,
                                    baselines: [Int: [CGPoint]]) -> [[Double]]? {
        let corrected = row.provenance.filter { $0.origin == .corrected }
        guard corrected.count == 1 else { return nil }
        let record = corrected[0]
        guard record.requestID == requestID, record.alternativeID == "corrected/\(record.sourceIndex)",
              let baseline = baselines[record.sourceIndex], baseline.count == 4,
              baseline.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return baseline.map { [Double($0.x), Double($0.y)] }
    }
    private static func pairs(_ q: [G.Point]) -> [[Double]] { q.map { [$0.x, $0.y] } }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func featureDigest(_ values: [Double]) -> String {
        var data = Data(featureABI.utf8)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return digest(data)
    }
    private static func sameQuad(_ a: [G.Point], _ b: [G.Point]) -> Bool {
        guard a.count == 4, b.count == 4 else { return false }
        for start in 0..<4 {
            if (0..<4).allSatisfy({ a[$0] == b[(start + $0) % 4] }) { return true }
            if (0..<4).allSatisfy({ a[$0] == b[(start - $0 + 4) % 4] }) { return true }
        }
        return false
    }
    private static func validQuad(_ q: [G.Point]) -> Bool {
        guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 1e7 && abs($0.y) < 1e7 }) else { return false }
        let turns = (0..<4).map { i -> Double in
            let a = q[i], b = q[(i+1)%4], c = q[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        return turns.allSatisfy { $0 > 0 } || turns.allSatisfy { $0 < 0 }
    }

    private static let forestKeys: Set<String> = ["enabled", "fallbackPrediction", "featureNames", "format", "initialBias",
        "learningRate", "margin", "maximumDepth", "nodeFields", "trees"]
    private static func validateGeneratorJSON(_ data: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(o.keys) == ["schema", "featureCount", "targetNames", "models", "trainingResidualQuantiles", "labelOrRowTablesIncluded"],
              o["labelOrRowTablesIncluded"] as? Bool == false, let models = o["models"] as? [[String: Any]], models.count == 5 else {
            throw Failure.invalidModels("generator schema/row tables")
        }
        for model in models {
            guard Set(model.keys).isSubset(of: forestKeys), model["enabled"] as? Bool == true,
                  model["featureNames"] as? [String] == (0..<344).map({ "f\($0)" }) else {
                throw Failure.invalidModels("generator feature ABI")
            }
        }
    }
    private static func validateUtilityJSON(_ data: Data) throws {
        let extras = ["relativeNormalLow", "relativeNormalHigh", "relativeAlongLow", "relativeAlongHigh", "relativeAngle",
                      "candidateCurrentArea", "candidateCurrentWidth", "candidateCurrentLength", "centerNormalOverCurrentW",
                      "centerAlongOverCurrentW", "sin2Angle", "cos2Angle", "cornerRMSOverCurrentW"]
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(o.keys).isSubset(of: forestKeys),
              o["enabled"] as? Bool == true,
              o["featureNames"] as? [String] == (0..<344).map({ "actualSource344-\($0)" }) + extras else {
            throw Failure.invalidModels("utility357 ABI/row tables")
        }
    }
}
