import CoreGraphics
import CoreML
import CryptoKit
import Foundation

/// Explicit host-only candidate admission; normal app model selection is unchanged.
enum HostModelRefresh {
    static var recordsAllControls: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_HOST_TRAINING_CAPTURE"] == "1" &&
            ProcessInfo.processInfo.environment["AIDOKU_HOST_TRAINING_ALL_CONTROLS"] == "1"
    }
    /// Offline native replay only. The normal runtime keeps research ensembles
    /// unadmitted until full corrected-output and merge-relation validation.
    static func allowsStage1Replay(_ model: NativeOCRPremergeCandidateModel) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AIDOKU_HOST_STAGE1_REPLAY"] == "1",
              let path = environment["AIDOKU_OCR_PREMERGE_MODEL"], !path.isEmpty,
              model.isAvailable, model.usesOnlyConfidenceAndRF else { return false }
        return true
    }

    private static let stage0ReplayModel: NativeOCRPremergeCandidateModel? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AIDOKU_HOST_STAGE0_REPLAY"] == "1",
              let path = environment["AIDOKU_OCR_PREREC_MODEL"], !path.isEmpty else { return nil }
        let model = NativeOCRPremergeCandidateModel(contentsOf: URL(fileURLWithPath: path))
        return model.isAvailable && model.usesOnlyConfidenceAndRF ? model : nil
    }()

    private static let stage2ReplayPolicy: NativeFinalOutputContentFilter.Policy? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AIDOKU_HOST_STAGE2_REPLAY"] == "1",
              let path = environment["AIDOKU_OCR_POSTMERGE_POLICY"], !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 65_536,
              let policy = try? JSONDecoder().decode(NativeFinalOutputContentFilter.Policy.self, from: data),
              policy.version == 1, policy.rules.count <= 4,
              policy.featureNames == NativeFinalOutputContentFilter.featureNames ||
                policy.featureNames == NativePostLLMContentReclassifier.featureNames,
              policy.rules.allSatisfy({ rule in
                  (2...5).contains(rule.count) && Set(rule.map(\.feature)).count == rule.count &&
                  rule.allSatisfy { condition in
                      policy.featureNames.indices.contains(condition.feature) &&
                      (condition.lower != nil || condition.upper != nil) &&
                      [condition.lower,condition.upper].compactMap { $0 }.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
                      (condition.lower ?? 0) <= (condition.upper ?? 1)
                  }
              }) else { return nil }
        return policy
    }()

    static func stage2Keep(features: [Double]?, detectorFeatures: [Double]?) -> Bool? {
        guard let policy = stage2ReplayPolicy else { return nil }
        guard let features, features.count == NativeFinalOutputContentFilter.featureNames.count else { return true }
        var values = features
        if policy.featureNames.count == NativePostLLMContentReclassifier.featureNames.count {
            guard let detectorFeatures, detectorFeatures.count == 15 else { return true }
            values += detectorFeatures
        }
        guard values.count == policy.featureNames.count,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return true }
        return !policy.rules.contains { rule in
            rule.allSatisfy { condition in
                let value = values[condition.feature]
                return (condition.lower.map { value >= $0 } ?? true) &&
                    (condition.upper.map { value <= $0 } ?? true)
            }
        }
    }

    private static func learnedSelection(stage: Int) -> NativeOCRPremergeCandidateSelection? {
        let env = ProcessInfo.processInfo.environment
        guard env["AIDOKU_HOST_STAGE\(stage)_DEDUP_REPLAY"] == "1",
              let quality = env["AIDOKU_OCR_STAGE\(stage)_QUALITY_MODEL"],
              let duplicates = env["AIDOKU_OCR_STAGE\(stage)_DUPLICATE_POLICY"] else { return nil }
        let selection = NativeOCRPremergeCandidateSelection(qualityURL: URL(fileURLWithPath: quality),
            policyURL: URL(fileURLWithPath: duplicates))
        guard selection.isAvailable, selection.usesOnlyLearnedSignalQuality,
              stage != 0 || selection.usesOnlyPreRecognitionSignalQuality else { return nil }
        return selection
    }
    private static let stage0ReplaySelection = learnedSelection(stage: 0)
    static let stage1ReplaySelection = learnedSelection(stage: 1)

    /// Equivalence includes every crop/photometric/retry parameter. Source
    /// identity is excluded from the request value but retained as parent
    /// provenance, so one owner cannot consume a different original source.
    private static func neutralCrop(_ r: NativeCoreMLRecognitionRegion) -> NativeCoreMLRecognitionRegion {
        .init(sourceIndex: 0, polygon: r.polygon, samplingPolygon: r.samplingPolygon,
            isThinFinePrintRecovery: r.isThinFinePrintRecovery, finePrintRetryPolygons: r.finePrintRetryPolygons,
            useProvidedOrder: r.useProvidedOrder, minimumSequenceWidth: r.minimumSequenceWidth,
            recognitionColumnEvidence: r.recognitionColumnEvidence, photometricMode: r.photometricMode)
    }

    private struct RoleReplayPolicy: Decodable, Sendable {
        let version: Int
        let featureNames: [String]
        let rolePolicies: [NativePostLLMContentReclassifier.RolePolicy]
    }
    struct RoleReplayDecision: Sendable {
        let action: NativePostLLMContentReclassifier.Action?
    }
    private static let roleReplayPolicy: RoleReplayPolicy? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AIDOKU_HOST_ROLE_REPLAY"] == "1",
              let path = environment["AIDOKU_POST_LLM_ROLE_POLICY"], !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 1_048_576,
              let policy = try? JSONDecoder().decode(RoleReplayPolicy.self, from: data),
              policy.version == 5, policy.featureNames == NativePostLLMContentReclassifier.featureNames,
              policy.rolePolicies.count == 6,
              Set(policy.rolePolicies.map { $0.role.rawValue }) == Set(["dialogue","narration","story_text","sfx","background","error"]),
              policy.rolePolicies.allSatisfy({ entry in
                  entry.rules.count <= 16 && (entry.role != .error || entry.rules.isEmpty) &&
                  entry.rules.allSatisfy { rule in
                      (2...5).contains(rule.conditions.count) &&
                      Set(rule.conditions.map(\.feature)).count == rule.conditions.count &&
                      rule.conditions.allSatisfy { condition in
                          policy.featureNames.indices.contains(condition.feature) &&
                          (condition.lower != nil || condition.upper != nil) &&
                          [condition.lower,condition.upper].compactMap { $0 }.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
                          (condition.lower ?? 0) <= (condition.upper ?? 1)
                      }
                  }
              }) else { return nil }
        return policy
    }()

    static func roleReplayDecision(_ segment: RemoteTranslatedSegment,
                                   evidence: NativePostLLMContentReclassifier.Evidence?) -> RoleReplayDecision? {
        guard let policy = roleReplayPolicy else { return nil }
        guard let evidence, evidence.isValid, let detector = evidence.detectorFeatures,
              detector.count == 15, let role = segment.textRole,
              let entry = policy.rolePolicies.first(where: { $0.role == role }) else {
            return .init(action: nil)
        }
        let values = evidence.features + detector
        guard values.count == policy.featureNames.count else { return .init(action: nil) }
        let admitted = segment.isSFX != true && [.dialogue,.narration,.storyText].contains(role)
        for rule in entry.rules {
            switch rule.action {
            case .retain:
                guard admitted, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            case .rescue:
                guard !admitted, [.sfx,.background].contains(role),
                      !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            case .suppress:
                guard admitted else { continue }
            }
            if rule.conditions.allSatisfy({ condition in
                let value = values[condition.feature]
                return (condition.lower.map { value >= $0 } ?? true) &&
                    (condition.upper.map { value <= $0 } ?? true)
            }) { return .init(action: rule.action) }
        }
        return .init(action: nil)
    }

    private struct RoleSignalRow: Decodable {
        let page: String
        let id: String
        let features: [Double]?
        let segment: RemoteTranslatedSegment
    }
    private struct RoleSignalBatch: Decodable {
        let schema: String
        let policySHA256: String
        let featureNames: [String]
        let rows: [RoleSignalRow]
    }
    /// Evaluate the actual candidate/native resolved() path without any images,
    /// provider calls or target labels. Receipts retain IDs only for association.
    static func runRoleSignalReplay(request: URL, output: URL) throws -> Int32 {
        guard NativePostLLMContentReclassifier.hostRoleReplayHook,
              let policy = roleReplayPolicy,
              let path = ProcessInfo.processInfo.environment["AIDOKU_POST_LLM_ROLE_POLICY"] else {
            throw HostError.message("No valid candidate role policy loaded")
        }
        let spec = try JSONDecoder().decode(RoleSignalBatch.self, from: Data(contentsOf: request))
        let policyData = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = SHA256.hash(data: policyData).map { String(format: "%02x", $0) }.joined()
        guard spec.schema == "native-role-signal-replay-v1", digest == spec.policySHA256,
              spec.featureNames == policy.featureNames, !spec.rows.isEmpty, spec.rows.count <= 50_000 else {
            throw HostError.message("Role replay source/policy contract differs")
        }
        var decisions: [[String: Any]] = []
        func kept(_ segment: RemoteTranslatedSegment) -> Bool {
            segment.isSFX != true && [.dialogue,.narration,.storyText].contains(segment.textRole)
        }
        for row in spec.rows {
            guard row.id == row.segment.id else { throw HostError.message("Role replay alias mismatch") }
            let evidence = row.features.flatMap { values -> NativePostLLMContentReclassifier.Evidence? in
                guard values.count == policy.featureNames.count else { return nil }
                return .init(features: Array(values.prefix(92)), detectorFeatures: Array(values.suffix(15)))
            }
            guard let candidate = roleReplayDecision(row.segment, evidence: evidence) else {
                throw HostError.message("Candidate role replay unexpectedly disabled")
            }
            let resolved = NativePostLLMContentReclassifier.resolved(row.segment, evidence: evidence)
            var expected = row.segment
            if let action = candidate.action {
                expected = NativePostLLMContentReclassifier.applying(action, to: row.segment)
            }
            let renamed = RemoteTranslatedSegment(id: "identity-control", text: row.segment.text,
                isSFX: row.segment.isSFX, textRole: row.segment.textRole)
            guard resolved == expected, resolved.id == row.segment.id, resolved.text == row.segment.text,
                  roleReplayDecision(renamed, evidence: evidence)?.action == candidate.action else {
                throw HostError.message("Native role hook or identity invariant failed")
            }
            decisions.append(["page": row.page, "id": row.id, "rawKeep": kept(row.segment),
                "keep": kept(resolved), "action": candidate.action?.rawValue as Any? ?? NSNull(),
                "role": resolved.textRole?.rawValue as Any? ?? NSNull()])
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: decisions, options: [.sortedKeys]).write(
            to: output.appendingPathComponent("NATIVE-DECISIONS.json"), options: .atomic)
        try JSONEncoder().encode(policy.rolePolicies).write(
            to: output.appendingPathComponent("NATIVE-ROLE-POLICIES.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: ["rows": decisions.count, "policySHA256": digest,
            "providerCalls": 0, "sourceImagesRead": 0, "nativeDecisionHookVerified": true,
            "identityInvarianceVerified": true], options: [.sortedKeys]).write(
            to: output.appendingPathComponent("NATIVE-VERIFICATION.json"), options: .atomic)
        return 0
    }

    private final class ObservationBuffer: @unchecked Sendable {
        let lock = NSLock()
        var rows: [URL: [[String: Any]]] = [:]
    }
    private static let observations = ObservationBuffer()

    private struct CropContract: Encodable {
        let polygon: [CGPoint]
        let samplingPolygon: [CGPoint]?
        let thin: Bool
        let retryPolygons: [[CGPoint]]
        let providedOrder: Bool
        let minimumSequenceWidth: Int
        let column: NativeOCRDetectorColumnEvidence?
        let photometricMode: String
    }
    private static func cropContract(_ r: NativeCoreMLRecognitionRegion) -> String? {
        let value = CropContract(polygon: r.polygon, samplingPolygon: r.samplingPolygon,
            thin: r.isThinFinePrintRecovery, retryPolygons: r.finePrintRetryPolygons,
            providedOrder: r.useProvidedOrder, minimumSequenceWidth: r.minimumSequenceWidth,
            column: r.recognitionColumnEvidence, photometricMode: r.photometricMode.rawValue)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func observe(_ event: NativeCoreMLRecognitionAuditEvent) {
        guard ProcessInfo.processInfo.environment["AIDOKU_HOST_TRAINING_CAPTURE"] == "1",
              let context = HostDump.context else { return }
        guard case let .decoded(request, region, text, confidence, threshold, cacheHit) = event else { return }
        let row: [String: Any] = ["requestID": request, "sourceIndex": region.sourceIndex,
            "polygon": region.polygon.map { [Double($0.x), Double($0.y)] },
            "samplingPolygon": region.samplingPolygon.map { $0.map { [Double($0.x), Double($0.y)] } } as Any? ?? NSNull(),
            "text": text, "confidence": confidence, "admissionThreshold": threshold, "cacheHit": cacheHit,
            "cropContractSHA256": cropContract(region) as Any? ?? NSNull()]
        observations.lock.lock()
        observations.rows[context.directory, default: []].append(row)
        observations.lock.unlock()
    }

    static func flushObservations() {
        guard ProcessInfo.processInfo.environment["AIDOKU_HOST_TRAINING_CAPTURE"] == "1",
              let context = HostDump.context else { return }
        observations.lock.lock()
        let rows = observations.rows.removeValue(forKey: context.directory) ?? []
        observations.lock.unlock()
        context.captureJSONObject("all-rec-training-input", ["schema": "native-all-decoded-crops-v1",
            "includesEmptyAndLowConfidence": true, "RFWeightsSHA256": weightsSHA256, "rows": rows])
    }

    @discardableResult
    static func capturePreRecognition(stage: String, regions: [NativeCoreMLRecognitionRegion],
                                     boxes: [NativeCoreMLDetectionBox], layout: NativeRFDETRLayoutResult?,
                                     references: [Int: [CGPoint]], parents: [Int: Int], keep: [Bool]) -> [Int: Bool]? {
        let capture = ProcessInfo.processInfo.environment["AIDOKU_HOST_TRAINING_CAPTURE"] == "1"
        let model = stage0ReplayModel
        let selection = stage0ReplaySelection
        guard capture || model != nil || selection != nil else { return nil }
        typealias F = NativeOCRPremergeCandidateFeatures
        func points(_ p: [CGPoint]) -> [F.Point] { p.map { .init(x: Double($0.x), y: Double($0.y)) } }
        let detectors = boxes.map { F.DetectorBox(polygon: points($0.polygon), score: Double($0.score)) }
        let primitives = layout?.primitives.map { p in
            F.RFPrimitive(x: Double(p.sourceBounds.minX), y: Double(p.sourceBounds.minY),
                width: Double(p.sourceBounds.width), height: Double(p.sourceBounds.height),
                confidence: Double(p.confidence), semanticClass: p.semanticClass.rawValue,
                mask: p.mask.flatMap { F.RFMask(sourceWidth: $0.sourceWidth, sourceHeight: $0.sourceHeight,
                    side: NativeRFDETRLayoutResource.maskSide, logits: $0.logits) }, queryID: p.queryID)
        }
        let rows: [[String: Any]] = regions.enumerated().map { index, region in
            let polygon = points(region.polygon)
            let parent = parents[region.sourceIndex] ?? region.sourceIndex
            func evidence(mask: Bool) -> [Double]? {
                guard let primitives else { return nil }
                guard var f = F.extract(polygon: polygon,
                    baseline: references[parent].map(points), detectorBoxes: detectors, rfPrimitives: primitives,
                    recognition: .init(polygon: polygon, text: "", confidence: 0), signalsOnly: true,
                    useRFMaskOverlap: mask) else { return nil }
                // Recognition has not happened: mark it unavailable, not as an
                // observed empty decode or a fabricated zero-confidence read.
                for i in 29..<55 { f[i] = 0 }
                return f
            }
            let box = evidence(mask: false), mask = evidence(mask: true)
            return ["sourceIndex": region.sourceIndex, "sourceParent": parent,
                "polygon": region.polygon.map { [Double($0.x), Double($0.y)] },
                "samplingPolygon": region.samplingPolygon.map { $0.map { [Double($0.x), Double($0.y)] } } as Any? ?? NSNull(),
                "boxFeatures": box as Any? ?? NSNull(), "features": mask as Any? ?? NSNull(),
                "featuresValid": mask != nil, "boxFeaturesValid": box != nil, "incumbentKeep": keep[index],
                "cropContractSHA256": cropContract(region) as Any? ?? NSNull()]
        }
        if capture {
            HostDump.captureJSONObject(stage, ["schema": "native-before-recognition-signals-v1",
                "RFWeightsSHA256": weightsSHA256, "featureNames": NativeOCRPremergeCandidateModel.featureNames,
                "recognitionAvailable": false, "rows": rows])
        }
        guard model != nil || selection != nil else { return nil }
        let decisions = rows.enumerated().map { index, row in
            model?.evaluate(features: row["features"] as? [Double]) ??
                NativeOCRPremergeCandidateModel.Decision(keep: keep[index], score: 0, failure: nil, punctuationPreserved: false)
        }
        var retained = decisions.map(\.keep)
        if let selection {
            var groups: [Int: [[Int]]] = [:]
            for (index, region) in regions.enumerated() {
                let parent = parents[region.sourceIndex] ?? region.sourceIndex
                var local = groups[parent] ?? []
                if let match = local.firstIndex(where: { neutralCrop(regions[$0[0]]) == neutralCrop(region) }) {
                    local[match].append(index)
                } else { local.append([index]) }
                groups[parent] = local
            }
            for group in groups.values.flatMap({ $0 }) where (2...64).contains(group.count) {
                let result = selection.select(polygons: group.map { points(regions[$0].polygon) },
                    features: group.map { rows[$0]["features"] as? [Double] }, content: group.map { decisions[$0] })
                for (index, value) in zip(group, result.keep) { retained[index] = value }
            }
        }
        return Dictionary(regions.enumerated().map { ($0.element.sourceIndex, retained[$0.offset]) },
                          uniquingKeysWith: { $0 || $1 })
    }

    static var weightsSHA256: String {
        ProcessInfo.processInfo.environment["AIDOKU_HOST_RF_PACKAGE"] == nil
            ? NativeRFDETRLayoutResource.sourceWeightsSHA256
            : NativeRFDETRLayoutResource.highresSourceWeightsSHA256
    }
    static var revision: String {
        ProcessInfo.processInfo.environment["AIDOKU_HOST_RF_PACKAGE"] == nil
            ? NativeRFDETRLayoutResource.sourceRevision : NativeRFDETRLayoutResource.highresSourceRevision
    }
    static func validate(model: MLModel) throws {
        try NativeRFDETRLayoutTensorContract.validate(model: model,
            expectedWeightsSHA256: weightsSHA256, expectedSourceRevision: revision)
    }

    /// Capture already-computed source evidence before admission. Labels never
    /// enter this path; offline matching/selection is a separate process.
    static func capture(regions: [NativeCoreMLRecognizedRegion], layout: NativeRFDETRLayoutResult,
                        boxFeatures: [[Double]?], maskFeatures: [[Double]?],
                        detectorBoxes: [NativeCoreMLDetectionBox], references: [Int: [CGPoint]], keep: [Bool]) {
        guard ProcessInfo.processInfo.environment["AIDOKU_HOST_TRAINING_CAPTURE"] == "1" else { return }
        typealias F = NativeOCRPremergeCandidateFeatures
        func points(_ p: [CGPoint]) -> [F.Point] { p.map { .init(x:Double($0.x),y:Double($0.y)) } }
        let primitives = layout.primitives.map { p in
            F.RFPrimitive(x:Double(p.sourceBounds.minX),y:Double(p.sourceBounds.minY),
                width:Double(p.sourceBounds.width),height:Double(p.sourceBounds.height),
                confidence:Double(p.confidence),semanticClass:p.semanticClass.rawValue,
                mask:p.mask.flatMap { F.RFMask(sourceWidth:$0.sourceWidth,sourceHeight:$0.sourceHeight,
                    side:NativeRFDETRLayoutResource.maskSide,logits:$0.logits) },queryID:p.queryID)
        }
        let queries = layout.classEvidence.map { q in
            NativeOCRPremergeSpatialEvidence.Query(x:Double(q.sourceBounds.minX),y:Double(q.sourceBounds.minY),
                width:Double(q.sourceBounds.width),height:Double(q.sourceBounds.height),
                probabilities:q.probabilities.map(Double.init),queryID:q.queryID)
        }
        let spatial = NativeOCRPremergeSpatialEvidence(width:layout.sourceWidth,height:layout.sourceHeight,
            primitives:primitives,queries:queries)
        let relations = NativeOCRPremergeQueryRelations(primitives:primitives,queries:queries)
        var groups: [String:Int] = [:]
        let observations = detectorBoxes.enumerated().map { index, box in
            let key = box.detectorSeedEvidence?.ownerID ?? "original-observation:\(index)"
            if groups[key] == nil { groups[key] = groups.count }
            return NativeOCRPremergeDetectorAgreement.Observation(polygon:points(box.polygon),
                score:Double(box.score),sourceGroups:[groups[key]!])
        }
        let agreement = NativeOCRPremergeDetectorAgreement.Context(observations:observations)
        let rows: [[String:Any]] = regions.enumerated().map { index, region in
            let polygon = points(region.polygon)
            var supplemental: [Double] = []
            if let s = spatial?.extract(polygon:polygon),
               let a = agreement?.extract(polygon:polygon,reference:references[region.sourceIndex].map(points)) {
                var detector = a.featureVector
                for i in 0..<3 { detector[i] = min(detector[i],4)/4 }
                supplemental = s + detector
            }
            return ["sourceIndex":region.sourceIndex,"polygon":region.polygon.map{[Double($0.x),Double($0.y)]},
                "baseline":references[region.sourceIndex]?.map{[Double($0.x),Double($0.y)]} ?? [],
                "text":region.text,"confidence":region.confidence,
                "boxFeatures":boxFeatures[index].map { $0 as Any } ?? NSNull(),
                "features":maskFeatures[index].map { $0 as Any } ?? NSNull(),
                "boxFeaturesValid":boxFeatures[index] != nil,"featuresValid":maskFeatures[index] != nil,
                "supplemental":supplemental,"joint":relations?.extract(polygon:polygon) ?? [],"incumbentKeep":keep[index]]
        }
        HostDump.captureJSONObject("premerge-training-input",["schema":"source-signals-refresh-v1",
            "sourceIdentity":layout.imageIdentity,"width":layout.sourceWidth,"height":layout.sourceHeight,
            "RFWeightsSHA256":weightsSHA256,"featureNames":NativeOCRPremergeCandidateModel.featureNames,"rows":rows])
    }
}
