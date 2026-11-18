import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Explicit geometry evaluation before any recognition call. The emitted rows
/// are prepared detector/correction output, never crops supplied by evaluator GT.
enum HostIndividualGeometry {
    struct SavedBox: Decodable {
        let polygon: [[Double]]
        let score: Double
        let detectorSeedEvidence: NativeOCRDetectorSeedEvidence?
    }
    struct SavedCorrected: Decodable {
        let sourceIndex: Int
        let polygon: [[Double]]
        let baseline: [[Double]]?
    }
    struct SavedRFBound: Decodable {
        let kind: NativeOCRSourceStrokeGeometry.RFKind
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let confidence: Double
    }
    struct SavedPage: Decodable {
        let page: String
        let source: String
        let sourceSHA256: String
        let width: Int
        let height: Int
        let originals: [SavedBox]
        let corrected: [SavedCorrected]
        let layout: [NativeOCRIndividualGeometryHypotheses.Record]?
        let sourceRFBounds: [SavedRFBound]?
        let sourceContextPrimitives: [NativeOCRSourceContext50V2.Primitive]?
    }

    /// NDJSON input contains immutable detector/corrected model outputs and
    /// original pixels, never GT coordinates. Replays the SAME native geometry
    /// correction/producer used by the pipeline, without detector/OCR/provider calls.
    static func replaySaved(output: URL, mode: NativeOCRIndividualGeometryHypotheses.Mode) async throws -> Int32 {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let binaryHash = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        var seen = Set<String>()
        while let line = readLine() {
            guard let data = line.data(using: .utf8), data.count <= 32_000_000 else {
                throw HostError.message("Invalid saved geometry record")
            }
            let page = try JSONDecoder().decode(SavedPage.self, from: data)
            guard page.page.count == 4, page.page.allSatisfy(\.isNumber), seen.insert(page.page).inserted,
                  page.originals.count <= 4096, page.corrected.count <= 4096,
                  Set(page.corrected.map(\.sourceIndex)).count == page.corrected.count else {
                throw HostError.message("Invalid saved geometry identities")
            }
            let imageBytes = try Data(contentsOf: URL(fileURLWithPath: page.source))
            guard SHA256.hash(data: imageBytes).map({ String(format: "%02x", $0) }).joined() == page.sourceSHA256,
                  let source = CGImageSourceCreateWithData(imageBytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == page.width, image.height == page.height,
                  let frame = await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: image) else {
                throw HostError.message("Saved geometry source mismatch")
            }
            func points(_ polygon: [[Double]]) throws -> [CGPoint] {
                guard polygon.count == 4, polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
                    throw HostError.message("Malformed saved geometry quad")
                }
                return polygon.map { CGPoint(x: $0[0], y: $0[1]) }
            }
            let originals = try page.originals.map {
                NativeCoreMLDetectionBox(polygon: try points($0.polygon), score: $0.score,
                    detectorSeedEvidence: $0.detectorSeedEvidence)
            }
            let before = try page.corrected.map { try points($0.polygon) }
            let changes = NativeOCRBlankGrowthCorrection.changes(polygons: before, originals: originals, frame: frame)
            let replacements = Dictionary(uniqueKeysWithValues: changes.map { ($0.index, $0.polygon) })
            typealias G = NativeOCRIndividualGeometryHypotheses
            func geometry(_ polygon: [CGPoint]) -> [G.Point] { polygon.map { .init(x: Double($0.x), y: Double($0.y)) } }
            let corrected = page.corrected.enumerated().map { index, row in
                G.Record(requestID: page.page, sourceIndex: row.sourceIndex, sourceParent: row.sourceIndex,
                    sourceMembers: [], alternativeID: "corrected/\(row.sourceIndex)", origin: .corrected,
                    originalDetectorIndex: nil, polygon: geometry(replacements[index] ?? before[index]))
            }
            let raw = originals.enumerated().map { index, box in
                G.Record(requestID: page.page, sourceIndex: index, sourceParent: index,
                    sourceMembers: Set([index]), alternativeID: "original/\(index)", origin: .sourceOriginal,
                    originalDetectorIndex: index, polygon: geometry(box.polygon))
            }
            let sourcePaintEnabled = NativeOCRSourcePaintGeometry.enabled
            let sourceFirstGeneration = sourcePaintEnabled && NativeOCRSourcePaintGeometry.sourceFirstGeneration
            let closedEnabled = !sourceFirstGeneration && mode == .sourceOriginalLayoutRefinedAndCorrectedV3 &&
                ProcessInfo.processInfo.environment["AIDOKU_OCR_CLOSED_CONTOUR_GEOMETRY"] == "1"
            let closedPolicyName = closedEnabled ?
                (ProcessInfo.processInfo.environment["AIDOKU_OCR_CLOSED_CONTOUR_POLICY"] ?? "strictOnly") : "strictOnly"
            guard let closedPolicy = NativeOCRSourceClosedContourGeometry.AdmissionPolicy(rawValue: closedPolicyName) else {
                throw HostError.message("Unsupported closed contour admission policy")
            }
            var canonicalFrame = frame
            let learned376Enabled = !sourceFirstGeneration &&
                ProcessInfo.processInfo.environment[NativeOCRLearnedBoundaryGeometry376.environmentKey]?.isEmpty == false
            let sourceRailEnabled = NativeOCRSourceOwnedRailGeometry.enabled
            if closedEnabled || learned376Enabled || sourceRailEnabled || sourcePaintEnabled || ProcessInfo.processInfo.environment[NativeOCRLearnedBoundaryGeometryV2.environmentKey]?.isEmpty == false {
                guard let decoded = NativeOCRV2SourcePixelDecoder.decode(image),
                      let converted = NativeOCRRGBAFrame(width: decoded.width, height: decoded.height,
                          bytesPerRow: decoded.bytesPerRow, bytes: decoded.bytes) else {
                    throw HostError.message("Canonical geometry source decoding failed")
                }
                canonicalFrame = converted
            }
            let closed = try NativeOCRSourceClosedContourGeometry.measure(requestID: page.page,
                frame: canonicalFrame, originals: originals, enabled: closedEnabled, policy: closedPolicy)
            let refinements: [G.Refinement]
            var strokeProofs: [NativeOCRSourceStrokeGeometry.Proof] = []
            var strokeReasons: [String] = []
            if sourceFirstGeneration {
                refinements = NativeOCRSourceFragmentGeometry.refinements(requestID: page.page,
                    originals: originals, width: page.width, height: page.height)
            } else if mode == .sourceOriginalLayoutRefinedAndCorrectedV3 {
                let rfBounds = (page.sourceRFBounds ?? []).map { bound in
                    NativeOCRSourceStrokeGeometry.SourceRFBound(kind: bound.kind,
                        bounds: CGRect(x: bound.x, y: bound.y, width: bound.width, height: bound.height),
                        confidence: bound.confidence)
                }
                let stroke = try NativeOCRSourceStrokeGeometry.produce(requestID: page.page,
                    originals: originals, frame: frame, sourceRFBounds: rfBounds,
                    enabled: ProcessInfo.processInfo.environment["AIDOKU_OCR_SOURCE_STROKE_GEOMETRY"] == "1",
                    applicability: .trainFrozenV3Pruning)
                strokeProofs = stroke.measurements.map(\.proof)
                strokeReasons = stroke.reasons
                refinements = NativeOCROwnedAxisGeometry.refinements(requestID: page.page,
                    originals: originals, width: page.width, height: page.height)
                    + NativeOCRSourceFragmentGeometry.refinements(requestID: page.page,
                        originals: originals, width: page.width, height: page.height)
                    + stroke.refinements + closed.refinements
            } else {
                refinements = []
            }
            // Context-only refinements still own their complete identity namespace.
            let refinementReservations = refinements.flatMap {
                [$0.record.sourceIndex, $0.record.sourceParent] + Array($0.record.sourceMembers)
            }
            let geometryEmissionPlan = G.producerEmissionPlan()
            let baselineResult = G.emit(requestID: page.page,
                corrected: sourceFirstGeneration ? [] : corrected,
                originals: sourceFirstGeneration ? [] : raw,
                layout: sourceFirstGeneration ? [] : page.layout ?? [],
                refinements: sourceFirstGeneration ? [] : refinements, mode: mode, emissionPlan: geometryEmissionPlan)
            let baselines = try Dictionary(uniqueKeysWithValues: page.corrected.compactMap { row -> (Int, [CGPoint])? in
                guard let baseline = row.baseline, !baseline.isEmpty else { return nil }
                return (row.sourceIndex, try points(baseline))
            })
            let learned = try NativeOCRLearnedBoundaryGeometry.corrections(requestID: page.page,
                input: sourceFirstGeneration ? [] : baselineResult.individuals, frame: frame, baselines: baselines,
                reservedSourceIndices: refinementReservations)
            let context = page.sourceContextPrimitives.map { primitives in
                NativeOCRLearnedBoundaryGeometryV2.SourceContext(
                    detector: page.originals.map { .init(polygon: $0.polygon, score: $0.score) },
                    primitives: primitives, detectorCaptureAvailable: true, rfCaptureAvailable: true)
            }
            // Independent heads share the same immutable baseline; never calibrate
            // a learned output recursively or reuse a virtual output identity.
            let learnedV2 = try NativeOCRLearnedBoundaryGeometryV2.corrections(requestID: page.page,
                input: sourceFirstGeneration ? [] : baselineResult.individuals, frame: canonicalFrame, baselines: baselines,
                reservedSourceIndices: refinementReservations + learned.records.map(\.sourceIndex), sourceContext: context)
            var sourceFrameIdentity = ""
            if learned376Enabled {
                let fingerprint = NativeOCRFrameDigestBuilder.fingerprint(of: canonicalFrame)
                sourceFrameIdentity = "\(fingerprint.width)x\(fingerprint.height):\(fingerprint.primary):\(fingerprint.verifier)"
            }
            let learned376 = try NativeOCRLearnedBoundaryGeometry376.corrections(requestID: page.page,
                input: sourceFirstGeneration ? [] : baselineResult.individuals, frame: canonicalFrame, baselines: baselines,
                reservedSourceIndices: refinementReservations + (learned.records + learnedV2.records).map(\.sourceIndex), sourceContext: context,
                originals: page.originals.map { .init(polygon: $0.polygon, detectorSeedEvidence: $0.detectorSeedEvidence) },
                actualPrecomputedRefinements: refinements,
                frameBinding: .init(operationID: page.page, sourceFrameIdentity: sourceFrameIdentity,
                    producerRequestID: page.page, width: page.width, height: page.height))
            let sourceRail = try NativeOCRSourceOwnedRailGeometry.produce(requestID: page.page,
                frame: canonicalFrame,
                originals: page.originals.map { .init(polygon: $0.polygon, detectorSeedEvidence: $0.detectorSeedEvidence) },
                reservedSourceIndices: Array(baselines.keys),
                reservedRecords: baselineResult.individuals.flatMap(\.provenance) + refinements.map(\.record)
                    + learned.records + learnedV2.records + learned376.records,
                enabledOverride: sourceFirstGeneration ? false : nil)
            let admission = NativeOCRLearnedBoundaryAdmission.select(requestID: page.page,
                baseline: baselineResult.individuals, v3: learnedV2, learned376: learned376,
                mode: try NativeOCRLearnedBoundaryAdmission.mode())
            let learnedRecords = learned.records + admission.v3Records + admission.records376 + sourceRail.records
            // One selected seed per original/current/layout source stage;
            // the full admitted/refined candidate bank never becomes pixel work.
            let sourcePaint: NativeOCRSourcePaintGeometry.Production?
            if sourcePaintEnabled {
                let paintOriginals = NativeOCRSourcePaintGeometry.canonicalSeeds(raw, records: learned.records,
                    decisions: learned.decisions.map { ($0.inputIndividual.provenance, $0.outputAlternativeID) })
                let paintCorrections = NativeOCRSourcePaintGeometry.canonicalSeeds(corrected, records: admission.v3Records,
                    decisions: learnedV2.decisions.map { ($0.inputIndividual.provenance, $0.outputAlternativeID) })
                let paintLayout = NativeOCRSourcePaintGeometry.canonicalSeeds(page.layout ?? [], records: admission.records376,
                    decisions: learned376.decisions.map { ($0.inputIndividual.provenance, $0.outputAlternativeID) })
                sourcePaint = try NativeOCRSourcePaintGeometry.produce(requestID: page.page,
                    frame: canonicalFrame,
                    originals: page.originals.map { .init(polygon: $0.polygon, detectorSeedEvidence: $0.detectorSeedEvidence) },
                    currentCorrections: paintCorrections, rf: context?.primitives ?? [],
                    reservedRecords: corrected + raw + (page.layout ?? []) + refinements.map(\.record)
                        + learned.records + learnedV2.records + learned376.records + sourceRail.records,
                    sourceGroups: refinements.filter { $0.head == .fragment }.map(\.record),
                    originalSeeds: paintOriginals, layoutScopes: paintLayout)
            } else { sourcePaint = nil }
            let sourcePaintRecords = sourcePaint?.records ?? []
            // Skip the unused intermediate learned inventory; no pixel query
            // reads it under the canonical-source-stage policy.
            let finalLayout = G.finalLayoutProposals(page.layout ?? [])
            typealias LearnedEmission = NativeOCRConditionalLearnedEmission
            func emissionQuad(_ quad: [G.Point]) -> LearnedEmission.Quad { quad.map { .init(x: $0.x, y: $0.y) } }
            let emissionDecisions = learned.decisions.map { LearnedEmission.Decision(head: .legacy,
                outputAlternativeID: $0.outputAlternativeID, inputQuad: emissionQuad($0.inputQuad), chosenQuad: emissionQuad($0.chosenQuad)) }
                + learnedV2.decisions.map { LearnedEmission.Decision(head: .v2,
                    outputAlternativeID: $0.outputAlternativeID, inputQuad: emissionQuad($0.inputQuad), chosenQuad: emissionQuad($0.chosenQuad)) }
                + learned376.decisions.map { LearnedEmission.Decision(head: .head376,
                    outputAlternativeID: $0.outputAlternativeID, inputQuad: emissionQuad($0.inputQuad), chosenQuad: emissionQuad($0.chosenQuad)) }
            let emittedLearnedRecords = LearnedEmission.emittedRecords(learnedRecords,
                observed: corrected + raw + finalLayout + sourcePaintRecords + sourceRail.records
                    + refinements.filter { geometryEmissionPlan.emits($0) }.map(\.record), decisions: emissionDecisions,
                detectors: page.originals.map { .init(polygon: $0.polygon.map { .init(x: $0[0], y: $0[1]) }, confidence: $0.score) })
            let sourceRecovery = NativeOCRSourcePaintGeometry.sourceFirstRecovery(
                originals: raw, current: corrected + sourcePaintRecords)
            let result = sourceFirstGeneration
                ? G.emit(requestID: page.page, corrected: corrected + sourcePaintRecords,
                    originals: sourceRecovery, layout: [], refinements: [], mode: mode, emissionPlan: geometryEmissionPlan)
                : emittedLearnedRecords.isEmpty && sourcePaintRecords.isEmpty && finalLayout == (page.layout ?? []) ? baselineResult :
                G.emit(requestID: page.page, corrected: corrected + emittedLearnedRecords + sourcePaintRecords,
                       originals: raw, layout: finalLayout, refinements: refinements, mode: mode, emissionPlan: geometryEmissionPlan)
            let sourcePaintProof = sourcePaint?.finalized(actualOutput: result.individuals)
            let sourcePaintJSON = try JSONSerialization.jsonObject(with: encoder.encode(sourcePaintProof), options: [.fragmentsAllowed])
            let admissionProof = admission.finalized(actualOutput: result.individuals)
            let admissionJSON = try JSONSerialization.jsonObject(with: encoder.encode(admissionProof))
            let sourceRailProof = sourceRail.report.enabled ? sourceRail.finalized(actualOutput: result.individuals) : nil
            let sourceRailJSON = try JSONSerialization.jsonObject(with: encoder.encode(sourceRailProof), options: [.fragmentsAllowed])
            let resultJSON = try JSONSerialization.jsonObject(with: encoder.encode(result))
            let strokeJSON = try JSONSerialization.jsonObject(with: encoder.encode(strokeProofs))
            let learnedJSON = try JSONSerialization.jsonObject(with: encoder.encode(learned.decisions))
            let learnedV2JSON = try JSONSerialization.jsonObject(with: encoder.encode(learnedV2.decisions))
            let contextJSON = try JSONSerialization.jsonObject(with: encoder.encode(learnedV2.sourceContextProof),
                                                              options: [.fragmentsAllowed])
            let closedJSON = try JSONSerialization.jsonObject(with: encoder.encode(closed.proofs))
            let learned376JSON = try JSONSerialization.jsonObject(with: encoder.encode(learned376.decisions))
            let learned376ContextJSON = try JSONSerialization.jsonObject(with: encoder.encode(learned376.sourceContextProof),
                                                                       options: [.fragmentsAllowed])
            let record: [String: Any] = ["schema": "native-saved-individual-geometry-replay-v1",
                "page": page.page, "sourceSHA256": page.sourceSHA256,
                "inputSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "binarySHA256": binaryHash, "output": resultJSON,
                "changedGeometryRows": changes.count, "recognizerCalls": 0, "detectorCalls": 0, "providerCalls": 0,
                "sourceStrokeEvidence": strokeJSON, "sourceStrokeReasons": strokeReasons,
                "closedContourEvidence": closedJSON, "closedContourReasons": closed.reasons,
                "learnedBoundaryEvidence": learnedJSON, "learnedBoundaryAdded": learned.records.count,
                "learnedBoundaryV2Evidence": learnedV2JSON, "learnedBoundaryV2Added": learnedV2.records.count,
                "learnedBoundaryV2SourceContext": contextJSON,
                "learnedBoundary376Evidence": learned376JSON, "learnedBoundary376Added": learned376.records.count,
                "learnedBoundary376SourceContext": learned376ContextJSON,
                "learnedBoundaryAdmission": admissionJSON,
                "sourceRail": sourceRailJSON,
                "sourcePaint": sourcePaintJSON,
                "learnedBoundaryV2Computed": learnedV2.records.count,
                "learnedBoundary376Computed": learned376.records.count,
                "learnedBoundaryV2Emitted": admissionProof.counts.emittedV3,
                "learnedBoundary376Emitted": admissionProof.counts.emitted376,
                "learnedBoundaryAddedCountSemantics": "computed-before-admission; actual emission is separately proven",
                "recognitionResultsUsedForAcceptance": false, "GTAtInference": false,
                "sourceMemberProvenance": "unknown for saved corrected rows; explicit for immutable originals",
                "equalityScope": "polygon-set equivalence; exact-duplicate provenance/cardinality can differ from live caller"]
            let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try bytes.write(to: output.appendingPathComponent(page.page + ".json"), options: .atomic)
            print("{\"page\":\"\(page.page)\",\"outputs\":\(result.individuals.count),\"changed\":\(changes.count)}")
            fflush(stdout)
        }
        return 0
    }

    static func captureCorrected(_ output: NativeOCRIndividualGeometryHypotheses.Output,
                                 admissionProof: NativeOCRLearnedBoundaryAdmission.Proof? = nil,
                                 sourceRailProof: NativeOCRSourceOwnedRailGeometry.Report? = nil,
                                 sourcePaintProof: NativeOCRSourcePaintGeometry.Report? = nil,
                                 bboxConfidenceProof: NativeOCRBBoxConfidenceAdmission.Report? = nil,
                                 geometryDeduplicationProof: NativeOCRGeometryDeduplication.Report? = nil,
                                 representativeProof: NativeOCRGeometryRepresentativeSelection.Report? = nil,
                                 signalAdmissionProof: NativeOCRGeometrySignalAdmission.Report? = nil,
                                 witnessAdmissionProof: NativeOCRGeometryWitnessAdmission.Report? = nil,
                                 portfolioAdmissionProof: NativeOCRGeometryPortfolioAdmission.Report? = nil,
                                 rfSemanticAdmissionProof: NativeOCRRFSemanticAdmission.Report? = nil,
                                 physicalPaintAdmissionProof: NativeOCRPhysicalPaintAdmission.Report? = nil,
                                 boundaryModesAdmissionProof: NativeOCRPhysicalPaintAdmission.Report? = nil,
                                 sharedLineAdmissionProof: NativeOCRPhysicalPaintAdmission.Report? = nil) {
        let encoder = JSONEncoder()
        let rows: [[String: Any]] = output.individuals.enumerated().map { index, individual in
            let provenance = (try? encoder.encode(individual.provenance))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
            let refinements = (try? encoder.encode(individual.refinements))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
            var row: [String: Any] = ["sourceIndex": index,
                    "polygon": individual.polygon.map { [$0.x, $0.y] },
                    "provenance": provenance, "refinements": refinements]
            if let confidence = individual.bboxConfidence { row["bboxConfidence"] = confidence }
            return row
        }
        guard let data = try? encoder.encode(output.counts),
              let counts = try? JSONSerialization.jsonObject(with: data) else { return }
        var payload: [String: Any] = [
            "schema": "native-individual-corrected-geometry-output-v1",
            "mode": output.mode.rawValue, "rows": rows, "counts": counts,
            "recognitionResultsUsedForAcceptance": (representativeProof?.usesObservedRecognitionAgreement ?? false)
                || signalAdmissionProof != nil || portfolioAdmissionProof != nil || rfSemanticAdmissionProof != nil
                || physicalPaintAdmissionProof != nil || boundaryModesAdmissionProof != nil || sharedLineAdmissionProof != nil,
            "freshRecognitionOfAllGeometryCandidates": false,
            "outputRole": "pre-content-geometry-candidate-inventory",
            "GTAtInference": false, "actualReturnedIndividualGeometry": true]
        if let admissionProof,
           let bytes = try? encoder.encode(admissionProof),
           let proof = try? JSONSerialization.jsonObject(with: bytes) {
            payload["learnedBoundaryAdmission"] = proof
        }
        if let sourceRailProof,
           let bytes = try? encoder.encode(sourceRailProof),
           let proof = try? JSONSerialization.jsonObject(with: bytes) {
            payload["sourceRail"] = proof
        }
        if let sourcePaintProof,
           let bytes = try? encoder.encode(sourcePaintProof),
           let proof = try? JSONSerialization.jsonObject(with: bytes) {
            payload["sourcePaint"] = proof
        }
        if let bboxConfidenceProof,
           let bytes = try? encoder.encode(bboxConfidenceProof),
           let proof = try? JSONSerialization.jsonObject(with: bytes) {
            payload["bboxConfidenceAdmission"] = proof
        }
        if let geometryDeduplicationProof,
           let bytes = try? encoder.encode(geometryDeduplicationProof),
           let proof = try? JSONSerialization.jsonObject(with: bytes) {
            payload["geometryDeduplication"] = proof
        }
        if let representativeProof,
           let bytes = try? encoder.encode(representativeProof),
           let proof = try? JSONSerialization.jsonObject(with: bytes) {
            payload["geometryRepresentativeSelection"] = proof
        }
        if let signalAdmissionProof,
           let bytes = try? encoder.encode(signalAdmissionProof),
           let proof = try? JSONSerialization.jsonObject(with: bytes) {
            payload["geometrySignalAdmission"] = proof
        }
        if let witnessAdmissionProof,
           let bytes = try? encoder.encode(witnessAdmissionProof),
           let proof = try? JSONSerialization.jsonObject(with: bytes) {
            payload["geometryWitnessAdmission"] = proof
        }
        if let portfolioAdmissionProof,
           let bytes = try? encoder.encode(portfolioAdmissionProof),
           let proof = try? JSONSerialization.jsonObject(with: bytes) {
            payload["geometryPortfolioAdmission"] = proof
        }
        payload["geometryProofIndicesAreStageLocal"] = true
        if let rfSemanticAdmissionProof,
           let bytes = try? encoder.encode(rfSemanticAdmissionProof),
           let proof = try? JSONSerialization.jsonObject(with:bytes) {
            payload["geometryRFSemanticAdmission"] = proof
        }
        if let physicalPaintAdmissionProof,
           let bytes = try? encoder.encode(physicalPaintAdmissionProof),
           let proof = try? JSONSerialization.jsonObject(with: bytes) {
            payload["geometryPhysicalPaintAdmission"] = proof
        }
        if let boundaryModesAdmissionProof,
           let bytes = try? encoder.encode(boundaryModesAdmissionProof),
           let proof = try? JSONSerialization.jsonObject(with: bytes) {
            payload["geometryPhysicalBoundaryModesAdmission"] = proof
        }
        if let sharedLineAdmissionProof,
           let bytes = try? encoder.encode(sharedLineAdmissionProof),
           let proof = try? JSONSerialization.jsonObject(with: bytes) {
            payload["geometrySharedLineAdmission"] = proof
        }
        HostDump.captureJSONObject("individual-corrected-geometry-output", payload)
    }

    static func result(requestID: String, detection: NativeCoreMLDetectionResult,
                       regions: [NativeCoreMLRecognitionRegion],
                       originals: [NativeCoreMLDetectionBox],
                       frameConversionMilliseconds: Double) -> NativeCoreMLOCRResult? {
        guard ProcessInfo.processInfo.environment["AIDOKU_HOST_INDIVIDUAL_GEOMETRY_ONLY"] == "1" else { return nil }
        func quad(_ polygon: [CGPoint]) -> [[Double]] {
            polygon.map { [Double($0.x), Double($0.y)] }
        }
        let rows: [[String: Any]] = regions.map { region in
            ["sourceIndex": region.sourceIndex, "polygon": quad(region.polygon),
             "sourceKind": "selected-prepared",
             "samplingPolygon": region.samplingPolygon.map(quad) as Any? ?? NSNull()]
        }
        // Original coordinates are a separate diagnostic stream. They are not
        // silently unioned with selected output to inflate its recall.
        let raw: [[String: Any]] = originals.enumerated().map { index, box in
            ["sourceIndex": index, "polygon": quad(box.polygon), "sourceKind": "raw-detector"]
        }
        HostDump.captureJSONObject("individual-geometry-output", [
            "schema": "native-individual-geometry-output-v1", "requestID": requestID,
            "width": detection.width, "height": detection.height,
            "RFWeightsSHA256": HostModelRefresh.weightsSHA256,
            "selection": "selected-prepared-only", "rows": rows,
            "recognitionCalls": 0, "recognitionResultsUsedForAcceptance": false,
            "GTAtInference": false])
        HostDump.captureJSONObject("individual-geometry-originals", [
            "schema": "native-individual-geometry-originals-v1", "rows": raw,
            "diagnosticOnly": true])
        return NativeCoreMLOCRResult(requestID: requestID, width: detection.width,
            height: detection.height, lines: [],
            frameConversionMilliseconds: frameConversionMilliseconds,
            detectionMilliseconds: detection.diagnostics.totalMilliseconds,
            recognitionMilliseconds: 0,
            totalMilliseconds: frameConversionMilliseconds + detection.diagnostics.totalMilliseconds,
            detectedBoxes: detection.boxes.count, selectedBoxes: regions.count,
            diagnostics: .init(backend: "coreml-geometry-only",
                frameConversionMilliseconds: frameConversionMilliseconds,
                detectionProvider: detection.diagnostics.executionProvider,
                recognitionProvider: "not-run", detectionComputeUnits: detection.diagnostics.computeUnits,
                recognitionComputeUnits: "not-run", detectionModel: detection.diagnostics.modelName,
                recognitionModel: "not-run", detection: detection.diagnostics, recognition: nil))
    }
}
