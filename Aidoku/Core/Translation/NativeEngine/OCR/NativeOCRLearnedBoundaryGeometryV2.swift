import CoreGraphics
import CryptoKit
import Foundation

/// NEW association revision, separate from frozen V2. V1 remains untouched.
/// Exact baseline geometry is AUX agreement only; output ownership is immutable.
/// No GT, per-row catalogs, text, recognition or inferred ownership.
/// Source344 stays Double; one mean prediction preserves the frozen model identity.
@available(iOS 18.0, *)
enum NativeOCRLearnedBoundaryGeometryV2 {
    typealias G = NativeOCRIndividualGeometryHypotheses
    static let environmentKey = "AIDOKU_OCR_LEARNED_BOUNDARY_V2_MODELS"
    static let policyEnvironmentKey = "AIDOKU_OCR_LEARNED_BOUNDARY_V2_POLICY"
    enum Policy: String, Codable, Sendable {
        case meanDepth6 = "mean-depth6"
    }
    static let modelFiles = ["generator-runtime-v2.json", "utility-runtime-v2.json"]
    static let featureABI = "442-native-cg-source293-geometric-baseline-agreement-context50-v2-availability1-utility13float32-v3"
    static let baselineAssociationABI = NativeOCRGeometricBaselineAssociation.abi
    static let manifestFile = "feature-abi.json"
    static let manifestSchema = "aidoku-learned-boundary-feature-abi-v2"
    /// All inputs are source-pixel observations in original order. RF classes are canonical
    /// wire 0 frame / 1 text / 2 balloon / 3 sfx, never semantic enum rawValue.
    struct SourceContext: Codable, Sendable {
        let detector: [NativeOCRSourceContext50V2.Detector]
        let primitives: [NativeOCRSourceContext50V2.Primitive]
        let detectorCaptureAvailable: Bool
        let rfCaptureAvailable: Bool
    }
    struct SourceContextProof: Codable, Sendable {
        let contextABI: String
        let inputSHA256: String
        let detectorInputCount: Int
        let primitiveInputCount: Int
        let canonicalClassInputCounts: [Int]
        let detectorCaptureAvailable: Bool
        let rfCaptureAvailable: Bool
    }

    enum Outcome: String, Codable, Sendable {
        case corrected, unchanged, invalidInput, ambiguousInput, conflictingIdentity, featureUnavailable, invalidProposal, nonSourceStageInput
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
        let sourceFeatureFreezeSHA256: String
        let sourceRGBDecoderABI: String
        let sourceContextSHA256: String
        let geometricBaselineAssociation: NativeOCRGeometricBaselineAssociation.Proof
        let baselineUsed: Bool
        let internalOfferCount: Int
        let outputSourceIndex: Int?
        let outputAlternativeID: String?
        let outcome: Outcome
    }
    struct Production: Sendable {
        let records: [G.Record]
        let decisions: [CodableProof]
        let sourceContextProof: SourceContextProof?
    }
    enum Failure: Error {
        case invalidModels(String), invalidPolicy(String), modelFilesChanged, sourceIndexOverflow, invalidFrame, nonFiniteInput(Int), sourceContextUnavailable
    }

    private struct Models {
        let generator: NativeOCRLearnedBoundaryModel442.Bundle
        let fileHashes: [String: String]
        let bundleHash: String
        let sourceFeatureFreezeSHA256: String
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
            for name in modelFiles + [manifestFile] {
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
            for name in modelFiles + [manifestFile] {
                let bytes = try Data(contentsOf: root.appendingPathComponent(name), options: .mappedIfSafe)
                guard !bytes.isEmpty, bytes.count <= 64 * 1024 * 1024 else { throw Failure.invalidModels(name) }
                data.append(bytes); hashes[name] = digest(bytes)
            }
            let freeze = try validateManifest(data[2], hashes: hashes)
            // Validate NEW nativeCG V2 file boundary BEFORE adapting only the frozen
            // numerical forest representation. Never accept old/CV ABI aliases.
            let generatorData = try validatedGeneratorData(data[0], freeze: freeze)
            let utilityData = try validatedUtilityData(data[1], freeze: freeze)
            let generator = try NativeOCRLearnedBoundaryProposal442.Generator(data: generatorData).model
            // Validate the frozen utility file as an identity input only.
            _ = try NativeOCRLearnedBoundaryUtility3.Model(data: utilityData)
            let identity = featureABI + "\n" + (modelFiles + [manifestFile]).map { $0 + ":" + hashes[$0]! }.joined(separator: "\n")
            let models = Models(generator: generator, fileHashes: hashes,
                                bundleHash: digest(Data(identity.utf8)), sourceFeatureFreezeSHA256: freeze)
            path = root.path; signatures = current; cached = models
            return models
        }
    }
    private static let modelCache = ModelCache()

    /// Parent calls baseline G.emit first, then passes these records into the SECOND
    /// G.emit corrected input alongside ALL baseline corrected rows. No G API changes.
    static func corrections(requestID: String, input: [G.Individual], frame: NativeOCRRGBAFrame,
                            baselines: [Int: [CGPoint]] = [:], reservedSourceIndices: [Int] = [],
                            sourceContext: SourceContext? = nil) throws -> Production {
        guard let directory = ProcessInfo.processInfo.environment[environmentKey], !directory.isEmpty,
              !input.isEmpty else { return .init(records: [], decisions: [], sourceContextProof: nil) }
        guard !requestID.isEmpty, frame.width > 0, frame.height > 0,
              frame.width <= Int.max / 4, frame.bytesPerRow >= frame.width * 4,
              frame.bytesPerRow <= Int.max / frame.height,
              frame.bytes.count >= frame.bytesPerRow * frame.height else { throw Failure.invalidFrame }
        guard let sourceContext, sourceContext.detectorCaptureAvailable, sourceContext.rfCaptureAvailable else {
            throw Failure.sourceContextUnavailable
        }
        let contextProof = receipt(sourceContext)
        let associationIndex = NativeOCRGeometricBaselineAssociation.build(requestID: requestID, input: input, baselines: baselines)
        for (ordinal, row) in input.enumerated() {
            let points = row.polygon + row.provenance.flatMap(\.polygon) + row.refinements.flatMap { $0.record.polygon }
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw Failure.nonFiniteInput(ordinal) }
        }
        let policyName = ProcessInfo.processInfo.environment[policyEnvironmentKey] ?? Policy.meanDepth6.rawValue
        guard let policy = Policy(rawValue: policyName) else { throw Failure.invalidPolicy(policyName) }
        let inputPolicy = try NativeOCRLearnedBoundaryGeometry.inputPolicy()
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
        for (ordinal, row) in input.enumerated() {
            let record = identities[ordinal]
            let association = associationIndex.association(for: row.polygon)
            var chosen = row.polygon, score: Double?, featureHash: String?, baselineUsed = false, offerCount = 0
            var outIndex: Int?, outID: String?, outcome: Outcome = .invalidInput
            if let record, validQuad(row.polygon) {
                let candidateID = "learned-boundary-v2/\(modelHash)/\(record.alternativeID)"
                if conflicting.contains(record.alternativeID) || used.contains(candidateID) {
                    outcome = .conflictingIdentity
                } else if row.provenance.contains(where: { $0.requestID != requestID || $0.sourceParent != record.sourceParent }) {
                    outcome = .ambiguousInput
                } else if !NativeOCRLearnedBoundaryGeometry.acceptsInput(record, policy: inputPolicy) {
                    outcome = .nonSourceStageInput
                } else {
                    let baseline = association.auxiliaryBaseline?.map { [$0.x, $0.y] }
                    baselineUsed = baseline != nil
                    if let features = sourceFeatures(individual: row, frame: frame, baseline: baseline, sourceContext: sourceContext) {
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
                featureDigest: featureHash, featureABI: featureABI, sourceFeatureFreezeSHA256: models.sourceFeatureFreezeSHA256,
                sourceRGBDecoderABI: NativeOCRV2SourcePixelDecoder.abi, sourceContextSHA256: contextProof.inputSHA256, geometricBaselineAssociation: association, baselineUsed: baselineUsed,
                internalOfferCount: offerCount, outputSourceIndex: outIndex, outputAlternativeID: outID, outcome: outcome))
        }
        return .init(records: records, decisions: proofs, sourceContextProof: contextProof)
    }

    /// Source293 uses frozen numerical extraction with NEW feature-only geometric baseline association;
    /// context50 and its independent availability replace
    /// the legacy zero authentic50 slots. No Float32 rounding of source293.
    static func sourceFeatures(individual: G.Individual, frame: NativeOCRRGBAFrame,
                               baseline: [[Double]]?, sourceContext: SourceContext) -> [Double]? {
        guard sourceContext.detectorCaptureAvailable, sourceContext.rfCaptureAvailable,
              let original = NativeOCRLearnedBoundaryGeometry.sourceFeatures(
                individual: individual, frame: frame, baseline: baseline),
              let context = NativeOCRSourceContext50V2.extract(candidate: pairs(individual.polygon),
                detector: sourceContext.detector, primitives: sourceContext.primitives,
                detectorCaptureAvailable: sourceContext.detectorCaptureAvailable,
                rfCaptureAvailable: sourceContext.rfCaptureAvailable), context.available == 1 else { return nil }
        let features = Array(original.prefix(293)) + context.features + [context.available]
        return features.count == 344 && features.allSatisfy(\.isFinite) ? features : nil
    }
    private static func receipt(_ context: SourceContext) -> SourceContextProof {
        // Binary length framing preserves original order and exact raw Double bits,
        // including invalid records the context helper discards. Not a model feature.
        var bytes = Data(NativeOCRSourceContext50V2.abi.utf8)
        func integer(_ value: Int) {
            var bits = UInt64(bitPattern: Int64(value)).littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        func number(_ value: Double) {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        func polygon(_ quad: [[Double]]) {
            integer(quad.count)
            for point in quad { integer(point.count); for value in point { number(value) } }
        }
        integer(context.detectorCaptureAvailable ? 1 : 0); integer(context.rfCaptureAvailable ? 1 : 0)
        integer(context.detector.count)
        for d in context.detector { number(d.score); polygon(d.polygon) }
        integer(context.primitives.count)
        for p in context.primitives { integer(p.canonicalClass); number(p.confidence); polygon(p.polygon) }
        return .init(contextABI: NativeOCRSourceContext50V2.abi, inputSHA256: digest(bytes),
            detectorInputCount: context.detector.count, primitiveInputCount: context.primitives.count,
            canonicalClassInputCounts: (0..<4).map { cl in context.primitives.filter { $0.canonicalClass == cl }.count },
            detectorCaptureAvailable: context.detectorCaptureAvailable, rfCaptureAvailable: context.rfCaptureAvailable)
    }
    private static func representative(_ row: G.Individual, requestID: String) -> G.Record? {
        guard !row.provenance.isEmpty, row.provenance.allSatisfy({
            $0.requestID == requestID && $0.sourceIndex >= 0 && $0.sourceParent >= 0 && !$0.alternativeID.isEmpty &&
                sameQuad($0.polygon, row.polygon)
        }) else { return nil }
        let corrected = row.provenance.filter { $0.origin == .corrected }
        return corrected.count == 1 ? corrected[0] : row.provenance[0]
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

    private static func validateManifest(_ data: Data, hashes: [String: String]) throws -> String {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(o.keys) == ["schema", "featureABI", "contextABI", "featureCount", "modelSHA256",
                              "sourceRGBDecoderABI", "sourceFeatureFreezeSHA256", "baselineAssociationABI"],
              o["schema"] as? String == manifestSchema, o["featureABI"] as? String == featureABI,
              o["contextABI"] as? String == NativeOCRSourceContext50V2.abi,
              o["baselineAssociationABI"] as? String == baselineAssociationABI,
              o["sourceRGBDecoderABI"] as? String == NativeOCRV2SourcePixelDecoder.abi,
              o["featureCount"] as? Int == 344, let freeze = o["sourceFeatureFreezeSHA256"] as? String,
              validSHA256(freeze),
              let expected = o["modelSHA256"] as? [String: String], Set(expected.keys) == Set(modelFiles),
              modelFiles.allSatisfy({ expected[$0] == hashes[$0] }) else {
            throw Failure.invalidModels("V2 feature/decoder ABI manifest/hash mismatch")
        }
        return freeze
    }
    private static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static let forestKeys: Set<String> = ["enabled", "fallbackPrediction", "featureNames", "format", "initialBias",
        "learningRate", "margin", "maximumDepth", "nodeFields", "trees"]
    private static func validatedGeneratorData(_ data: Data, freeze: String) throws -> Data {
        guard var o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(o.keys) == ["schema", "featureCount", "targetNames", "models", "trainingResidualQuantiles",
                              "labelOrRowTablesIncluded", "sourceFeatureABI", "sourceFeatureFreezeSHA256", "sourceRGBDecoderABI", "baselineAssociationABI"],
              o["schema"] as? String == "source-rgb-rfdet-context50-v2-residual-runtime-v1",
              o["featureCount"] as? Int == 344,
              o["sourceFeatureABI"] as? String == NativeOCRSourceContext50V2.abi,
              o["baselineAssociationABI"] as? String == baselineAssociationABI,
              o["sourceRGBDecoderABI"] as? String == NativeOCRV2SourcePixelDecoder.abi,
              o["sourceFeatureFreezeSHA256"] as? String == freeze,
              o["labelOrRowTablesIncluded"] as? Bool == false, let models = o["models"] as? [[String: Any]], models.count == 5 else {
            throw Failure.invalidModels("nativeCG V2 generator schema/freeze/row tables")
        }
        for model in models {
            guard Set(model.keys).isSubset(of: forestKeys), model["enabled"] as? Bool == true,
                  model["featureNames"] as? [String] == (0..<344).map({ "f\($0)" }) else {
                throw Failure.invalidModels("V2 generator feature ABI")
            }
        }
        o.removeValue(forKey: "sourceFeatureABI"); o.removeValue(forKey: "sourceFeatureFreezeSHA256")
        o.removeValue(forKey: "sourceRGBDecoderABI"); o.removeValue(forKey: "baselineAssociationABI")
        o["schema"] = "source-current72-pixel-residual-runtime-v1"
        return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }
    private static func validatedUtilityData(_ data: Data, freeze: String) throws -> Data {
        let extras = ["relativeNormalLow", "relativeNormalHigh", "relativeAlongLow", "relativeAlongHigh", "relativeAngle",
                      "candidateCurrentArea", "candidateCurrentWidth", "candidateCurrentLength", "centerNormalOverCurrentW",
                      "centerAlongOverCurrentW", "sin2Angle", "cos2Angle", "cornerRMSOverCurrentW"]
        guard var o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(o.keys).isSubset(of: forestKeys.union(["sourceFeatureABI", "sourceFeatureFreezeSHA256", "sourceRGBDecoderABI", "baselineAssociationABI"])),
              o["format"] as? String == "source-rgb-rfdet-context50-v2-coverage-utility-runtime-v1",
              o["sourceFeatureABI"] as? String == NativeOCRSourceContext50V2.abi,
              o["baselineAssociationABI"] as? String == baselineAssociationABI,
              o["sourceRGBDecoderABI"] as? String == NativeOCRV2SourcePixelDecoder.abi,
              o["sourceFeatureFreezeSHA256"] as? String == freeze,
              o["enabled"] as? Bool == true,
              o["featureNames"] as? [String] == (0..<344).map({ "actualSource344-\($0)" }) + extras else {
            throw Failure.invalidModels("nativeCG V2 utility357 ABI/freeze/row tables")
        }
        o.removeValue(forKey: "sourceFeatureABI"); o.removeValue(forKey: "sourceFeatureFreezeSHA256")
        o.removeValue(forKey: "sourceRGBDecoderABI"); o.removeValue(forKey: "baselineAssociationABI")
        o["format"] = "source-current72-pixel-utility-v1"
        return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }
}
