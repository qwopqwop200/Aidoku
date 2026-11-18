import CoreGraphics
import CryptoKit
import Foundation

/// Actual independent mean-only376 corrected records. Default off; no utility,
/// query-provenance ownership, GT, recognition gate or recursive learned inputs.
@available(iOS 18.0, *)
enum NativeOCRLearnedBoundaryGeometry376 {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias V3 = NativeOCRLearnedBoundaryGeometryV2
    typealias SourceContext = V3.SourceContext
    typealias Owner = NativeOCRDBRawProducerOwnerResolution
    typealias Source = NativeOCRLearnedBoundarySource376
    typealias Generator = NativeOCRLearnedBoundaryGenerator376
    static let environmentKey = "AIDOKU_OCR_LEARNED_BOUNDARY_376_MODELS"
    static let policyEnvironmentKey = "AIDOKU_OCR_LEARNED_BOUNDARY_376_POLICY"
    static let policy = "single-mean"
    static let utilityPolicy = "unused-not-loaded"
    static let modelFile = "generator-runtime-376.json"
    static let manifestFile = "feature-abi.json"
    static let manifestSchema = "aidoku-learned-boundary-feature-abi-376-v1"
    static let featureABI = Generator.featureABI

    enum Outcome: String, Codable, Sendable {
        case corrected, unchanged, invalidInput, ambiguousInput, conflictingIdentity, featureUnavailable, invalidProposal, nonSourceStageInput, sourceConsensusInput
    }
    enum Failure: Error {
        case invalidModels(String), invalidPolicy(String), modelFilesChanged, sourceIndexOverflow
        case invalidFrame, sourceContextUnavailable, nonFiniteInput(Int)
    }
    struct DBProof: Codable, Sendable {
        let contextID: String
        let sourceOwnerResolutionABI: String
        let sourceOwnerContextStage: String
        let ownerIndices: [Int]
        let proofKinds: [String]
        let fullSeedPayloadSHA256: [String]
        let ownerReason: String?
        let numericReason: String?
        let available: Bool
        let neighborScanAvailable: Bool
        let ownershipTransferredToOutput: Bool
    }
    struct ContextProof: Codable, Sendable {
        let contextID: String
        let nativeReceiptCodec: String
        let frameBinding: Owner.FrameBinding
        let canonicalRGBAVisibleSHA256: String
        let sourceContextSHA256: String
        let originalCount: Int
        let actualRefinementCount: Int
        let actualRefinementHeadCounts: [String: Int]
        let fullOriginalSeedSHA256: [String?]
        let sourceDBNormalABI: String
        let sourceOwnerResolutionABI: String
        let sourceOwnerContextStage: String
        let acceptedPacketsPolicy: String
        let queryMetadataPolicy: String
    }
    struct CodableProof: Codable, Sendable {
        let requestID: String
        let inputOrdinal: Int
        let baseMaximumSourceIndex: Int
        let inputIndividual: G.Individual
        let inputRecord: G.Record?
        let inputQuad: [G.Point]
        let chosenQuad: [G.Point]
        let predictedResidual: [Double]?
        let modelSHA: String
        let fileSHA256: [String: String]
        let featureABI: String
        let sourceFeatureFreezeSHA256: String
        let featureDigest: String?
        let source344Digest: String?
        let db32Digest: String?
        let geometricBaselineAssociation: NativeOCRGeometricBaselineAssociation.Proof
        let baselineUsed: Bool
        let db32: DBProof?
        let policy: String
        let score: Double?
        let internalOfferCount: Int
        let utilityInvoked: Bool
        let outputSourceIndex: Int?
        let outputAlternativeID: String?
        let sourceConsensus: NativeOCRLearnedBoundaryGeometry.ConsensusProof?
        let outcome: Outcome
    }
    struct Production: Sendable {
        let records: [G.Record]
        let decisions: [CodableProof]
        let sourceContextProof: ContextProof?
    }
    private struct Models {
        let generator: Generator.Model
        let fileHashes: [String: String]
        let bundleHash: String
        let featureFreeze: String
    }
    private final class ModelCache: @unchecked Sendable {
        private let lock = NSLock()
        private var path: String?
        private var signatures: [String] = []
        private var cached: Models?
        func load(_ directory: String) throws -> Models {
            lock.lock(); defer { lock.unlock() }
            let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
            var current: [String] = []
            for name in [modelFile, manifestFile] {
                let target = root.appendingPathComponent(name).resolvingSymlinksInPath()
                let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
                guard let size = attributes[.size] as? NSNumber, size.intValue > 0,
                      size.intValue <= 64 * 1024 * 1024,
                      let modified = attributes[.modificationDate] as? Date else { throw Failure.invalidModels(name) }
                current.append("\(target.path):\(size.intValue):\(modified.timeIntervalSince1970):\(attributes[.systemFileNumber] ?? 0)")
            }
            if path == root.path, let cached {
                guard current == signatures else { throw Failure.modelFilesChanged }
                return cached
            }
            let data = try Data(contentsOf: root.appendingPathComponent(modelFile), options: .mappedIfSafe)
            let manifest = try Data(contentsOf: root.appendingPathComponent(manifestFile), options: .mappedIfSafe)
            guard !data.isEmpty, data.count <= 64 * 1024 * 1024,
                  !manifest.isEmpty, manifest.count <= 64 * 1024 * 1024 else { throw Failure.invalidModels("file size") }
            let hashes = [modelFile: digest(data), manifestFile: digest(manifest)]
            let freeze = try validateManifest(manifest, modelHash: hashes[modelFile]!)
            let generator = try Generator.Model(data: data, expectedFeatureFreezeSHA256: freeze)
            let identity = featureABI + "\npolicy:" + policy + "\n" +
                [modelFile, manifestFile].map { $0 + ":" + hashes[$0]! }.joined(separator: "\n")
            let result = Models(generator: generator, fileHashes: hashes,
                bundleHash: digest(Data(identity.utf8)), featureFreeze: freeze)
            path = root.path; signatures = current; cached = result
            return result
        }
    }
    private static let cache = ModelCache()

    /// input is the SAME immutable baseline supplied to other independent heads.
    /// Reserve their returned IDs separately; never supply their learned quads as input.
    static func corrections(requestID: String, input: [G.Individual], frame: NativeOCRRGBAFrame,
                            baselines: [Int: [CGPoint]] = [:], reservedSourceIndices: [Int] = [],
                            sourceContext: SourceContext? = nil,
                            originals: [Owner.Original], actualPrecomputedRefinements: [G.Refinement]?,
                            frameBinding: Owner.FrameBinding) throws -> Production {
        guard let directory = ProcessInfo.processInfo.environment[environmentKey], !directory.isEmpty,
              !input.isEmpty else { return .init(records: [], decisions: [], sourceContextProof: nil) }
        let requestedPolicy = ProcessInfo.processInfo.environment[policyEnvironmentKey] ?? policy
        guard requestedPolicy == policy else { throw Failure.invalidPolicy(requestedPolicy) }
        // Independent heads calibrate the same immutable source-stage observations.
        // Refinements still participate in features, context and ID reservations.
        let inputPolicy = try NativeOCRLearnedBoundaryGeometry.inputPolicy()
        let consensus = try NativeOCRLearnedBoundaryGeometry.consensusPreflight(
            requestID: requestID, input: input, policy: inputPolicy)
        guard !requestID.isEmpty, frame.width > 0, frame.height > 0,
              frame.width <= Int.max / 4, frame.bytesPerRow >= frame.width * 4,
              frame.bytesPerRow <= Int.max / frame.height,
              frame.bytes.count >= frame.bytesPerRow * frame.height,
              frameBinding.width == frame.width, frameBinding.height == frame.height,
              frameBinding.producerRequestID == requestID else { throw Failure.invalidFrame }
        guard let sourceContext, sourceContext.detectorCaptureAvailable, sourceContext.rfCaptureAvailable else {
            throw Failure.sourceContextUnavailable
        }
        for (ordinal, row) in input.enumerated() {
            let points = row.polygon + row.provenance.flatMap(\.polygon) + row.refinements.flatMap { $0.record.polygon }
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw Failure.nonFiniteInput(ordinal) }
        }
        let prepared = try Source.prepare(originals: originals, width: frame.width, height: frame.height,
            actualPrecomputedRefinements: actualPrecomputedRefinements, frame: frameBinding)
        let models = try cache.load(directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let seeds = try originals.map { original -> String? in
            try original.detectorSeedEvidence.map { digest(try encoder.encode($0)) }
        }
        var headCounts: [String: Int] = [:]
        for refinement in actualPrecomputedRefinements ?? [] { headCounts[refinement.head.rawValue, default: 0] += 1 }
        let contextProof = ContextProof(contextID: prepared.contextID, nativeReceiptCodec: Owner.nativeReceiptCodec,
            frameBinding: frameBinding, canonicalRGBAVisibleSHA256: frameDigest(frame),
            sourceContextSHA256: digest(try encoder.encode(sourceContext)), originalCount: originals.count,
            actualRefinementCount: prepared.actualRefinementCount, actualRefinementHeadCounts: headCounts,
            fullOriginalSeedSHA256: seeds, sourceDBNormalABI: Generator.sourceDBNormalABI,
            sourceOwnerResolutionABI: Generator.sourceOwnerResolutionABI, sourceOwnerContextStage: Generator.sourceOwnerContextStage,
            acceptedPacketsPolicy: "EXCLUDED", queryMetadataPolicy: "IGNORED")
        let associationIndex = NativeOCRGeometricBaselineAssociation.build(requestID: requestID, input: input, baselines: baselines)
        var maximum = (reservedSourceIndices + Array(baselines.keys)).filter { $0 >= 0 }.max() ?? -1
        if !originals.isEmpty { maximum = max(maximum, originals.count - 1) }
        let suppliedRecords = input.flatMap { $0.provenance + $0.refinements.map(\.record) } +
            (actualPrecomputedRefinements ?? []).map(\.record)
        for record in suppliedRecords {
            for value in [record.sourceIndex, record.sourceParent] + Array(record.sourceMembers) +
                (record.originalDetectorIndex.map { [$0] } ?? []) where value >= 0 { maximum = max(maximum, value) }
        }
        let start = maximum.addingReportingOverflow(1)
        let end = start.partialValue.addingReportingOverflow(input.count - 1)
        guard !start.overflow, !end.overflow else { throw Failure.sourceIndexOverflow }
        let identities = input.map { representative($0, requestID: requestID) }
        var identityQuads: [String: [G.Point]] = [:], conflicting = Set<String>()
        for (row, record) in zip(input, identities) {
            guard let record else { continue }
            if let previous = identityQuads[record.alternativeID], !sameQuad(previous, row.polygon) {
                conflicting.insert(record.alternativeID)
            }
            identityQuads[record.alternativeID] = row.polygon
        }
        var used = Set(suppliedRecords.map(\.alternativeID)), records: [G.Record] = [], proofs: [CodableProof] = []
        // With opt-in consensus, establish the highest REAL emitted reservation
        // first. Keep evaluating the tail until one emits; only lower ordinals may
        // skip. This preserves downstream heads' maxima without synthetic records.
        let ordinals = consensus.isEmpty ? Array(input.indices) : Array(input.indices.reversed())
        for ordinal in ordinals {
            let row = input[ordinal]
            let record = identities[ordinal], association = associationIndex.association(for: row.polygon)
            var chosen = row.polygon, residual: [Double]?, featureHash: String?, baseHash: String?, blockHash: String?
            var ownerProof: DBProof?, offerCount = 0
            var outIndex: Int?, outID: String?, outcome: Outcome = .invalidInput
            let baseline = association.auxiliaryBaseline?.map { [$0.x, $0.y] }
            if let record, validQuad(row.polygon) {
                let alternativeID = "learned-boundary-376/\(models.bundleHash)/\(record.alternativeID)"
                if conflicting.contains(record.alternativeID) || used.contains(alternativeID) {
                    outcome = .conflictingIdentity
                } else if row.provenance.contains(where: { $0.requestID != requestID || $0.sourceParent != record.sourceParent }) {
                    outcome = .ambiguousInput
                } else if !NativeOCRLearnedBoundaryGeometry.acceptsInput(record, policy: inputPolicy) {
                    outcome = .nonSourceStageInput
                } else if consensus[ordinal] != nil && !records.isEmpty {
                    outcome = .sourceConsensusInput
                } else if let base = V3.sourceFeatures(individual: row, frame: frame, baseline: baseline, sourceContext: sourceContext),
                          let source = try Source.extract(source344: base, queryQuad: pairs(row.polygon), context: prepared) {
                    featureHash = featureDigest(source.features, abi: featureABI)
                    baseHash = featureDigest(base, abi: V3.featureABI)
                    blockHash = featureDigest(Array(source.features.suffix(32)), abi: Generator.sourceDBNormalABI)
                    ownerProof = .init(contextID: source.ownership.contextID,
                        sourceOwnerResolutionABI: source.ownership.authABI, sourceOwnerContextStage: source.ownership.stageABI,
                        ownerIndices: source.ownership.ownerIndices, proofKinds: source.ownership.proofKinds,
                        fullSeedPayloadSHA256: source.ownership.ownerIndices.compactMap { seeds[$0] },
                        ownerReason: source.ownership.reason, numericReason: source.numericReason,
                        available: source.features[344] == 1, neighborScanAvailable: source.features[375] == 1,
                        ownershipTransferredToOutput: false)
                    // All rows, including zero32, receive exactly ONE global mean prediction.
                    offerCount = 1
                    residual = models.generator.mean(source376: source.features)
                    let candidate = residual.flatMap { NativeOCRLearnedBoundaryGeometry442.polygon(
                        residual: $0, current: pairs(row.polygon), frame: [Double(frame.width), Double(frame.height)]) }
                    chosen = candidate?.map { .init(x: $0[0], y: $0[1]) } ?? row.polygon
                    if candidate == nil || !validQuad(chosen) { outcome = .invalidProposal; chosen = row.polygon }
                    else if sameQuad(chosen, row.polygon) { outcome = .unchanged }
                    else {
                        let known = !record.sourceMembers.isEmpty && record.sourceMembers.allSatisfy { $0 >= 0 } &&
                            row.provenance.allSatisfy { $0.sourceMembers == record.sourceMembers }
                        let members = known ? record.sourceMembers : []
                        let original = known && record.originalDetectorIndex.map({ members.contains($0) }) == true ?
                            record.originalDetectorIndex : nil
                        let index = start.partialValue + ordinal
                        records.append(.init(requestID: requestID, sourceIndex: index, sourceParent: record.sourceParent,
                            sourceMembers: members, alternativeID: alternativeID, origin: .corrected,
                            originalDetectorIndex: original, polygon: chosen))
                        used.insert(alternativeID); outIndex = index; outID = alternativeID; outcome = .corrected
                    }
                } else { outcome = .featureUnavailable }
            }
            proofs.append(.init(requestID: requestID, inputOrdinal: ordinal, baseMaximumSourceIndex: maximum,
                inputIndividual: row, inputRecord: record, inputQuad: row.polygon, chosenQuad: chosen,
                predictedResidual: residual, modelSHA: models.bundleHash, fileSHA256: models.fileHashes,
                featureABI: featureABI, sourceFeatureFreezeSHA256: models.featureFreeze,
                featureDigest: featureHash, source344Digest: baseHash, db32Digest: blockHash,
                geometricBaselineAssociation: association, baselineUsed: baseline != nil, db32: ownerProof,
                policy: policy, score: nil, internalOfferCount: offerCount, utilityInvoked: false,
                outputSourceIndex: outIndex, outputAlternativeID: outID, sourceConsensus: outcome == .sourceConsensusInput ? consensus[ordinal] : nil, outcome: outcome))
        }
        return .init(records: consensus.isEmpty ? records : Array(records.reversed()),
            decisions: consensus.isEmpty ? proofs : Array(proofs.reversed()), sourceContextProof: contextProof)
    }

    private static func validateManifest(_ data: Data, modelHash: String) throws -> String {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(o.keys) == ["schema", "featureCount", "featureABI", "sourceDBNormalABI", "sourceOwnerResolutionABI",
                "sourceOwnerContextStage", "sourceContextABI", "sourceRGBDecoderABI", "baselineAssociationABI",
                "sourceFeatureFreezeSHA256", "policy", "utilityPolicy", "modelSHA256"],
              o["schema"] as? String == manifestSchema, o["featureCount"] as? Int == 376,
              o["featureABI"] as? String == featureABI,
              o["sourceDBNormalABI"] as? String == Generator.sourceDBNormalABI,
              o["sourceOwnerResolutionABI"] as? String == Generator.sourceOwnerResolutionABI,
              o["sourceOwnerContextStage"] as? String == Generator.sourceOwnerContextStage,
              o["sourceContextABI"] as? String == Generator.sourceContextABI,
              o["sourceRGBDecoderABI"] as? String == Generator.sourceRGBDecoderABI,
              o["baselineAssociationABI"] as? String == Generator.baselineAssociationABI,
              o["policy"] as? String == policy, o["utilityPolicy"] as? String == utilityPolicy,
              let hashes = o["modelSHA256"] as? [String: String], hashes == [modelFile: modelHash],
              let freeze = o["sourceFeatureFreezeSHA256"] as? String, freeze.utf8.count == 64,
              freeze.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalidModels("explicit376 manifest/ABI/hash")
        }
        return freeze
    }
    private static func representative(_ row: G.Individual, requestID: String) -> G.Record? {
        guard !row.provenance.isEmpty, row.provenance.allSatisfy({ $0.requestID == requestID &&
            $0.sourceIndex >= 0 && $0.sourceParent >= 0 && !$0.alternativeID.isEmpty && sameQuad($0.polygon, row.polygon) }) else { return nil }
        let corrected = row.provenance.filter { $0.origin == .corrected }
        return corrected.count == 1 ? corrected[0] : row.provenance[0]
    }
    private static func pairs(_ q: [G.Point]) -> [[Double]] { q.map { [$0.x, $0.y] } }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func featureDigest(_ features: [Double], abi: String) -> String {
        var data = Data(abi.utf8)
        for value in features { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) } }
        return digest(data)
    }
    private static func frameDigest(_ frame: NativeOCRRGBAFrame) -> String {
        var hash = SHA256()
        for y in 0..<frame.height { hash.update(data: Data(frame.bytes[(y * frame.bytesPerRow)..<(y * frame.bytesPerRow + frame.width * 4)])) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
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
}
