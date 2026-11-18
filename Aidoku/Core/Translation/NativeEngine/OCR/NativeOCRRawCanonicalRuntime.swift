import CoreGraphics
import Foundation

enum NativeOCRRawCanonicalPolicy {
    enum SourceAnchorMode: String, Sendable {
        case disabled
        case fixedPreRecognition = "source-anchor-fixed-prerec-v1"
        case noPreRecognition = "source-anchor-no-prerec-v1"
        case noPreRecognitionTerminalRecovery = "source-anchor-no-prerec-terminal-v2"
    }
    // Whole TRAIN-group CV/DEV found the pre-REC head kept every raw row.
    // Keep raw geometry and bypass that auxiliary head on both app and host.
    static let defaultSourceAnchorMode: SourceAnchorMode = .noPreRecognition
    static let version = "main-source-anchor-long104-legacy-short-consensus-isolated-groups-wide-complement-dedup-v5"
    static let disabledComparisonVersion = "main-raw8d-source165-det085-rec030-direct085-v1"
    static let detectorAlternatePolicyVersion = "main-source-anchor-db-cell-alternate-recapture-v1"
    static func resolvedSourceAnchorMode(override: String?) -> SourceAnchorMode? {
        guard let override else { return defaultSourceAnchorMode }
        return SourceAnchorMode(rawValue: override)
    }

    /// Post-REC estimate of the visible line extent. The crop used to decode
    /// the text, including its immutable source packet, retains its own quad.
    static func estimatedLineExtent(_ points: [CGPoint], width: Int, height: Int) -> [CGPoint] {
        guard points.count == 4, width > 0, height > 0 else { return points }
        let p = points
        let across = CGPoint(x: (p[1].x-p[0].x) + (p[2].x-p[3].x),
                             y: (p[1].y-p[0].y) + (p[2].y-p[3].y))
        let down = CGPoint(x: (p[2].x-p[1].x) + (p[3].x-p[0].x),
                           y: (p[2].y-p[1].y) + (p[3].y-p[0].y))
        let horizontal = hypot(across.x, across.y) > hypot(down.x, down.y)
        let axis = horizontal ? across : down
        // The vector sums two full edges. One percent of that sum extends
        // each end by two percent, retaining line width and skew.
        let expanded = points.enumerated().map { index, point in
            let positive = horizontal ? index == 1 || index == 2 : index >= 2
            let factor = positive ? 0.01 : -0.01
            return CGPoint(x: point.x + factor * axis.x, y: point.y + factor * axis.y)
        }
        return expanded.allSatisfy { (0...CGFloat(width)).contains($0.x) && (0...CGFloat(height)).contains($0.y) }
            ? expanded : points
    }
}

/// MAIN's live DET -> source localization -> pre-REC admission -> actual REC
/// -> direct retained witness path. No replay inputs or source/GT catalogs.
@available(iOS 18.0, *)
enum NativeOCRRawCanonicalRuntime {
    static let policyVersion = NativeOCRRawCanonicalPolicy.version
    static let detectorFloor = 0.085
    typealias SourceAnchorMode = NativeOCRRawCanonicalPolicy.SourceAnchorMode
    struct TerminalReceipt: Equatable, Sendable {
        let proposedParents: Int
        let bboxAdmittedParents: Int
        let retryRequestedRegions: Int
        let retryPredictedRegions: Int
        let acceptedReplacements: [NativeOCRSourceTerminalRecovery.Proof]
        var duplicateGeometryRejected: Int = 0
        var invalidGeometryRejected: Int = 0
    }
    struct DetectorAlternateReceipt: Equatable, Sendable {
        let proposed: Int
        let bboxAdmitted: Int
        let recognitionAdmitted: Int
        let retained: Int
    }
    @TaskLocal static var sourceAnchorMode: SourceAnchorMode = NativeOCRRawCanonicalPolicy.defaultSourceAnchorMode
    static var usesLegacyComplement: Bool {
        sourceAnchorMode == .noPreRecognition &&
            simpleDeduplication == defaultSimpleDeduplication &&
            NativeSimpleRecognitionAdmission.configuration == nil &&
            NativeSimpleOCRBoundaryExpansionRuntime.configuration == nil &&
            !NativeCoreMLDBPostprocessor.alternateCellEnvelopeEnabled && moduleObserver == nil
    }
    /// Full TRAIN group-CV/DEV selected simple baseline. Nil remains the
    /// explicit legacy comparison; callers fence active parameters in caches.
    static let defaultSimpleDeduplication: NativeSimpleOCRDedup.Configuration? = .init(iouThreshold: 0.85, rank: .recognition)
    @TaskLocal static var simpleDeduplication: NativeSimpleOCRDedup.Configuration? = defaultSimpleDeduplication
    /// Optional transport only. The nil default never constructs capture payloads
    /// or binary feature matrices and cannot change model/admission behavior.
    @TaskLocal static var moduleObserver: NativeOCRRawModuleObservation.Observer? = nil
    struct FixedModelPredictionCounts: Equatable, Sendable {
        let primaryGeometryRows: Int
        let sourceGateRows: Int
        let auxiliaryGeometryRows: Int
        let noveltyReferenceRows: Int
        let preRecognitionRows: Int
    }
    struct SourceFeatureEvaluation: Equatable, Sendable {
        enum Mode: String, Sendable { case full165, recognitionAgreement2, notRequired }
        let mode: Mode
        let candidateRows: Int
        let materializedRows: Int
        var scalarColumns: Int {
            switch mode {
            case .full165: 165
            case .recognitionAgreement2: 2
            case .notRequired: 0
            }
        }
    }
    /// Observability only. Reuses the SAME apply report and feature rows;
    /// never calls Model.score, predicts again, imputes evidence or changes keep.
    struct PreRecognitionEvaluation: Equatable, Sendable {
        let executed: Bool
        let availableRows: Int
        let attemptedRows: Int
        let finiteFeatureRows: Int?
        let finiteScoreRows: Int?
        let missingEvidenceKeptRows: Int?
        let keptRows: Int?
        let rejectedRows: Int?
        let threshold: Double?
        let minimumScore: Double?
        let maximumScore: Double?
        let scores: [Double?]?
        let keptIndices: [Int]?
        let missingEvidenceKeptIndices: [Int]?
        static func measured(report: NativeOCRPreRecognitionFilter.Report,
                             features: [[Double]]) -> Self {
            let finiteScores = report.scores.compactMap { $0 }.filter(\.isFinite)
            return .init(executed: true, availableRows: features.count,
                attemptedRows: report.inputCount,
                finiteFeatureRows: features.filter { $0.allSatisfy(\.isFinite) }.count,
                finiteScoreRows: finiteScores.count,
                missingEvidenceKeptRows: report.missingEvidenceKeptIndices.count,
                keptRows: report.keptIndices.count,
                rejectedRows: report.inputCount - report.keptIndices.count,
                threshold: report.threshold, minimumScore: finiteScores.min(), maximumScore: finiteScores.max(),
                scores: report.scores, keptIndices: report.keptIndices,
                missingEvidenceKeptIndices: report.missingEvidenceKeptIndices)
        }
        static func notExecuted(availableRows: Int) -> Self {
            .init(executed: false, availableRows: availableRows, attemptedRows: 0,
                finiteFeatureRows: nil, finiteScoreRows: nil, missingEvidenceKeptRows: nil,
                keptRows: nil, rejectedRows: nil, threshold: nil, minimumScore: nil, maximumScore: nil,
                scores: nil, keptIndices: nil, missingEvidenceKeptIndices: nil)
        }
    }
    struct Receipt: Equatable, Sendable {
        let policyVersion: String
        let primaryObservations: Int
        let auxiliaryObservations: Int
        let generated: Int
        let bboxAdmitted: Int
        let preRecognitionAdmitted: Int
        let recognized: Int
        let retained: Int
        let detectorThreshold: Double
        let recognitionThreshold: Double
        var sourceAnchorMode: String? = nil
        var fixedModelPredictionCounts: FixedModelPredictionCounts? = nil
        var terminalRecovery: TerminalReceipt? = nil
        var preRecognitionEvaluation: PreRecognitionEvaluation? = nil
        /// Consumer policy, distinct from actual API .30 REC observations.
        var simpleRecognitionAdmission: NativeSimpleRecognitionAdmission.Report? = nil
        var sourceFeatureEvaluation: SourceFeatureEvaluation? = nil
        /// Explicit computed output geometry, separate from immutable observed source records.
        var boundaryExpansion: NativeSimpleOCRBoundaryExpansion.Report? = nil
        var detectorAlternates: DetectorAlternateReceipt? = nil
    }
    struct Output: Sendable {
        let lines: [NativeCoreMLOCRLine]
        let recognition: NativeCoreMLRecognitionResult
        let geometry: [NativeOCRIndividualGeometryHypotheses.Individual]
        let receipt: Receipt
    }
    enum Failure: Error {
        case missingEvidence, invalidRecognition, missingAuxiliaryModel
        case incompatibleDetectorAlternates, invalidDetectorAlternate
    }

    /// Both branches have complete page-local packet tables, including suppressed
    /// observations. Rebase all three membership sets before either branch is grouped.
    static func joinedLines(current: [NativeCoreMLOCRLine], legacy: [NativeCoreMLOCRLine],
                            width: Int, height: Int) throws -> [NativeCoreMLOCRLine] {
        let groups = [current, legacy]
        let tables = groups.map { $0.first?.acceptedSource.membership?.table }
        let table = NativeOCRAcceptedSource.PacketTable(packets: tables.compactMap { $0 }.flatMap(\.packets),
            width: width, height: height, legacyPacketStart: tables[0]?.packets.count ?? 0)
        var result: [NativeCoreMLOCRLine] = []
        result.reserveCapacity(current.count + legacy.count)
        var offset = 0
        for (index, lines) in groups.enumerated() where !lines.isEmpty {
            guard let original = tables[index], original.width == width, original.height == height else {
                throw Failure.missingEvidence
            }
            for var line in lines {
                guard let m = line.acceptedSource.membership, m.table === original,
                      m.body.allSatisfy(original.packets.indices.contains),
                      m.readings.allSatisfy(original.packets.indices.contains),
                      m.unknownDedup.allSatisfy(original.packets.indices.contains) else {
                    throw Failure.missingEvidence
                }
                line.acceptedSource = .init(.init(table: table, body: offset == 0 ? m.body : Set(m.body.lazy.map { $0 + offset }),
                    readings: offset == 0 ? m.readings : Set(m.readings.lazy.map { $0 + offset }),
                    unknownDedup: offset == 0 ? m.unknownDedup : Set(m.unknownDedup.lazy.map { $0 + offset }),
                    hasUntrackedInputs: m.hasUntrackedInputs), layoutPolygon: line.acceptedSource.layoutPolygon,
                    detectorSignals: line.acceptedSource.detectorSignals)
                line.isLegacyComplement = index == 1
                result.append(line)
            }
            offset += original.packets.count
        }
        return result
    }

    static func recognize(frame: NativeOCRRGBAFrame, requestID: String,
                          originals: [NativeCoreMLDetectionBox], probability: NativeMainEnsembleOCRProbability.Sample,
                          layout: NativeRFDETRLayoutResult, models: NativeOCRRawGeometryModelBundle.Resolved,
                          sourceAnchorMode: SourceAnchorMode,
                          recognizer: any NativeCoreMLRecognizing, recognitionThreshold: Double,
                          cancellationCheck: @escaping @Sendable () throws -> Void,
                          stageHandler: (@Sendable (NativeCoreMLOCRStage) -> Void)?) async throws -> Output {
        // The pipeline captures one mode BEFORE resource acquisition. Consume
        // that exact mode instead of re-reading a TaskLocal after the load.
        try cancellationCheck()
        let anchorMode = sourceAnchorMode
        let observer = moduleObserver
        let simpleDeduplication = Self.simpleDeduplication
        let simpleRecognitionAdmission = NativeSimpleRecognitionAdmission.configuration
        let compactAgreementEnabled = NativeSimpleRecognitionAdmission.compactAgreementEnabled
        let boundaryExpansion = NativeSimpleOCRBoundaryExpansionRuntime.configuration
        let detectorAlternates = NativeCoreMLDBPostprocessor.alternateCellEnvelopeEnabled
        if let simpleRecognitionAdmission { try NativeSimpleRecognitionAdmission.validate(simpleRecognitionAdmission) }
        if detectorAlternates {
            guard anchorMode == .noPreRecognition, simpleDeduplication != nil,
                  boundaryExpansion == nil, simpleRecognitionAdmission == nil else { throw Failure.incompatibleDetectorAlternates }
        }
        if boundaryExpansion != nil {
            try NativeSimpleOCRBoundaryExpansionRuntime.validateCompatibility(mode:anchorMode,
                usesSimpleDeduplication:simpleDeduplication != nil, observingModules:observer != nil,
                compactAgreementEnabled:compactAgreementEnabled)
        }
        if let observer {
            observer.originalDetector(originals, binding: moduleBinding(requestID: requestID, frame: frame,
                sourceImageIdentity: layout.imageIdentity, mode: anchorMode))
        }
        if anchorMode != .disabled {
            let preRecognitionModel: NativeOCRPreRecognitionFilter.Model?
            switch (anchorMode, models) {
            case (.fixedPreRecognition, .preRecognition(let model)):
                preRecognitionModel = model
            case (.noPreRecognition, .none), (.noPreRecognitionTerminalRecovery, .none):
                preRecognitionModel = nil
            default:
                throw Failure.missingEvidence
            }
            return try await recognizeSourceAnchors(frame:frame,requestID:requestID,originals:originals,
                probability:probability,layout:layout,preRecognitionModel:preRecognitionModel,recognizer:recognizer,
                recognitionThreshold:recognitionThreshold,mode:anchorMode,
                moduleObserver:observer,
                simpleDeduplication:simpleDeduplication,
                simpleRecognitionAdmission:simpleRecognitionAdmission,
                compactAgreementEnabled:compactAgreementEnabled,
                boundaryExpansion:boundaryExpansion,
                detectorAlternates:detectorAlternates,
                cancellationCheck:cancellationCheck,stageHandler:stageHandler)
        }
        guard case .full(let models) = models else { throw Failure.missingEvidence }
        return try await NativeOCRSourcePaintGeometry.$mainCanonicalPolicy.withValue(true) {
            typealias G = NativeOCRIndividualGeometryHypotheses
            typealias F = NativeOCRPreRecognitionFeatures
            guard frame.width == layout.sourceWidth, frame.height == layout.sourceHeight,
                  probability.sourceWidth == frame.width, probability.sourceHeight == frame.height,
                  let grid = layout.semanticGrid, grid.isValid, grid.hasValidWeightedMeanProbabilities,
                  grid.modelWeightsSHA256 == NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                  grid.imageIdentity == layout.imageIdentity, let support = layout.sourceSupportGrid,
                  let rf = NativeOCRSourceSupportFeatures155.PreparedRF(width: frame.width, height: frame.height,
                    native17Fields: support.native17Fields) else { throw Failure.missingEvidence }
            guard let auxiliaryModel = models.auxiliary else { throw Failure.missingAuxiliaryModel }
            let roots = originals.map { box in
                NativeOCRSourceOwnedRailPartition.Original(polygon: box.polygon.map { [Double($0.x),Double($0.y)] },
                    detectorSeedEvidence: box.detectorSeedEvidence)
            }
            let primitives = layout.primitives.map { p in
                NativeOCRRawBoundaryFeatures.RFPrimitive(classID: p.semanticClass.rawValue,
                    confidence: Double(p.confidence), sourceBounds: .init(x:Double(p.sourceBounds.minX),
                        y:Double(p.sourceBounds.minY),width:Double(p.sourceBounds.width),height:Double(p.sourceBounds.height)))
            }
            try cancellationCheck()
            let admission = NativeOCRRawCanonicalGeometry.SourceAdmission(model:models.gate,rf:rf,
                detectorConfidences:originals.map { Double($0.score) })
            let primary = try NativeOCRRawCanonicalGeometry.produce(requestID:requestID,frame:frame,originals:roots,
                rfPrimitives:primitives,grid:grid,model:models.primary,sourceAdmission:admission,
                auxiliaryReferenceModel:models.auxiliaryReference)
            try cancellationCheck()
            let auxiliary = try NativeOCRCanonicalAuxiliarySeeds.produce(probability:probability,
                originals:originals,referencePolygons:primary.auxiliaryReferencePolygons,
                support:support,cancellationCheck:cancellationCheck)
            let auxRoots = auxiliary.map { NativeOCRSourceOwnedRailPartition.Original(
                polygon:$0.polygon,detectorSeedEvidence:nil) }
            // Reuse primary records; do not run its physical factories twice.
            let extra = try NativeOCRRawCanonicalGeometry.produce(requestID:requestID,frame:frame,originals:roots,
                rfPrimitives:primitives,grid:grid,model:auxiliaryModel,auxiliaryOriginals:auxRoots,
                auxiliaryOutputOnly:true)
            let generated = G.emit(requestID:requestID,
                corrected:(primary.output.individuals+extra.output.individuals).flatMap(\.provenance),
                originals:[],layout:[],refinements:[],mode:.sourceOriginalLayoutRefinedAndCorrectedV3)
            if let observer {
                observer.proposals(generated, binding: moduleBinding(requestID: requestID, frame: frame,
                    sourceImageIdentity: layout.imageIdentity, mode: anchorMode))
            }
            let bbox = try NativeOCRBBoxConfidenceAdmission.apply(generated,probability:probability,
                sourceWidth:frame.width,sourceHeight:frame.height,enabled:true,cancellationCheck:cancellationCheck)
            guard bbox.report.applied else { throw Failure.missingEvidence }
            if let observer {
                observer.bboxAdmission(bbox, binding: moduleBinding(requestID: requestID, frame: frame,
                    sourceImageIdentity: layout.imageIdentity, mode: anchorMode))
            }
            let sourceObservations = zip(roots,originals).map { root, box in
                F.SourceObservation(polygon:root.polygon,score:Double(box.score),detectorSeedEvidence:root.detectorSeedEvidence)
            } + auxiliary.map { F.SourceObservation(polygon:$0.polygon,score:$0.score,detectorSeedEvidence:nil) }
            let sources = try bbox.output.individuals.map { row -> F.SourceObservation in
                guard row.provenance.count == 1, let proof = row.provenance.first,
                      proof.requestID == requestID, sourceObservations.indices.contains(proof.sourceParent),
                      proof.sourceMembers.isEmpty, proof.originalDetectorIndex == nil else { throw Failure.missingEvidence }
                return sourceObservations[proof.sourceParent]
            }
            // Original immutable scored bank supplies all165 context before ANY
            // numeric deletion. Retained rows are gathered, never recomputed.
            let source165 = try F.extract(input:bbox.output,sourceObservations:sources,
                detectorObservations:sourceObservations,rf:rf,sourceWidth:frame.width,sourceHeight:frame.height)
            let pre = try NativeOCRPreRecognitionFilter.apply(bbox.output,features:source165,model:models.preRecognition)
            if let observer {
                observer.preRecognition(input: bbox.output, scheduled: pre.output, source165: source165, report: pre.report,
                    binding: moduleBinding(requestID: requestID, frame: frame,
                        sourceImageIdentity: layout.imageIdentity, mode: anchorMode))
            }
            let regions = pre.output.individuals.enumerated().map { i,row in
                NativeCoreMLRecognitionRegion(sourceIndex:i,polygon:row.polygon.map { CGPoint(x:$0.x,y:$0.y) })
            }
            try cancellationCheck()
            stageHandler?(.recognizing(regionCount:regions.count))
            // REC .30 is a confidence setting, not OCR model v0.3. Honor the
            // caller's explicit setting; no sibling-recovery floor bypasses it.
            let threshold = min(1,max(0,recognitionThreshold))
            let decoded = try await recognizer.recognize(frame:frame,regions:regions,requestID:requestID,
                confidenceThreshold:threshold,cancellationCheck:cancellationCheck)
            try cancellationCheck()
            guard decoded.requestID == requestID, Set(decoded.regions.map(\.sourceIndex)).count == decoded.regions.count else {
                throw Failure.invalidRecognition
            }
            var reads = decoded.regions.sorted { $0.sourceIndex < $1.sourceIndex }
            guard reads.allSatisfy({ read in
                regions.indices.contains(read.sourceIndex) && read.polygon == regions[read.sourceIndex].polygon
                    && read.confidence.isFinite && read.confidence >= threshold && read.confidence <= 1 && !read.text.isEmpty
            }) else { throw Failure.invalidRecognition }
            let recognitionAdmission: NativeSimpleRecognitionAdmission.Report?
            if let configuration = simpleRecognitionAdmission {
                let admitted = try NativeSimpleRecognitionAdmission.apply(reads, source165: source165,
                    source165Indices: pre.report.keptIndices, configuration: configuration)
                reads = admitted.reads
                recognitionAdmission = admitted.report
            } else { recognitionAdmission = nil }
            let input = G.selecting(pre.output,indices:reads.map(\.sourceIndex))
            let source166: [[Double]]?
            if simpleDeduplication == nil || observer != nil {
                let accepted165 = reads.map { source165[pre.report.keptIndices[$0.sourceIndex]] }
                let measured = try NativeOCRPostRecognitionFeatures.extract(input:input,source165:accepted165,
                    recognitionConfidences:reads.map(\.confidence))
                source166 = measured
                if let observer {
                    observer.postRecognition(scheduled: pre.output, input: input, reads: reads,
                        source165Indices: reads.map { pre.report.keptIndices[$0.sourceIndex] },
                        accepted165: accepted165, source166: measured, binding: moduleBinding(requestID: requestID, frame: frame,
                            sourceImageIdentity: layout.imageIdentity, mode: anchorMode))
                }
            } else { source166 = nil }
            let dedup: NativeOCRPostRecognitionDeduplication.Result
            if let configuration = simpleDeduplication {
                dedup = try NativeSimpleOCRDedup.apply(input, reads: reads, configuration: configuration)
            } else {
                guard let source166 else { throw Failure.missingEvidence }
                dedup = try NativeOCRPostRecognitionDeduplication.apply(input,source166:source166)
            }
            if let observer {
                observer.deduplication(input: input, result: dedup, binding: moduleBinding(requestID: requestID, frame: frame,
                    sourceImageIdentity: layout.imageIdentity, mode: anchorMode))
            }
            let detectors = NativeOCRPremergeCandidateFeatures.prepareDetectorInventory(sourceObservations.map { F in
                NativeOCRPremergeCandidateFeatures.DetectorBox(polygon:F.polygon.map { .init(x:$0[0],y:$0[1]) },score:F.score)
            })
            let packets = reads.map { read -> NativeCoreMLOCRLine in
                let q = read.polygon.map { NativeOCRPremergeCandidateFeatures.Point(x:Double($0.x),y:Double($0.y)) }
                let detector = NativePostLLMContentReclassifier.detectorSignals(polygon:q,baseline:nil,
                    inventory:detectors,recognitionConfidence:read.confidence)
                // Detached raw predictions retain no fabricated detector owner.
                return .init(polygon:read.polygon,text:read.text,score:read.confidence,
                    orientation:NativeCoreMLOCRPipeline.orientation(for:read.polygon),orientationIsEstimated:true,
                    acceptedSource:.init(detectorSignals:detector))
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(packets,width:frame.width,height:frame.height)
            let lines = dedup.report.keptIndices.map { index -> NativeCoreMLOCRLine in
                var line = bound[index]
                if let m = line.acceptedSource.membership {
                    let removed = Set(dedup.report.replacements.filter { $0.retainedIndex == index }.map(\.inputIndex))
                    line.acceptedSource = .init(.init(table:m.table,body:m.body,readings:m.readings,
                        unknownDedup:removed,hasUntrackedInputs:false),detectorSignals:line.acceptedSource.detectorSignals)
                }
                return line
            }
            if let observer {
                observer.acceptedMembership(lines, binding: moduleBinding(requestID: requestID, frame: frame,
                    sourceImageIdentity: layout.imageIdentity, mode: anchorMode))
            }
            return .init(lines:lines,recognition:decoded,geometry:dedup.output.individuals,
                receipt:.init(policyVersion:NativeOCRRawCanonicalPolicy.disabledComparisonVersion,primaryObservations:originals.count,auxiliaryObservations:auxiliary.count,
                    generated:generated.individuals.count,bboxAdmitted:bbox.output.individuals.count,
                    preRecognitionAdmitted:pre.output.individuals.count,recognized:decoded.regions.count,retained:lines.count,
                    detectorThreshold:try NativeOCRBBoxConfidenceAdmission.threshold(),recognitionThreshold:threshold,
                    sourceAnchorMode:SourceAnchorMode.disabled.rawValue,
                    preRecognitionEvaluation:.measured(report:pre.report,features:source165),
                    simpleRecognitionAdmission:recognitionAdmission,
                    sourceFeatureEvaluation:.init(mode:.full165,candidateRows:source165.count,materializedRows:source165.count)))
        }
    }

    private static func moduleBinding(requestID: String, frame: NativeOCRRGBAFrame,
                                      sourceImageIdentity: String, mode: SourceAnchorMode) -> NativeOCRRawModuleObservation.Binding {
        let version: String
        if mode == .disabled {
            version = NativeOCRRawCanonicalPolicy.disabledComparisonVersion
        } else if NativeCoreMLDBPostprocessor.alternateCellEnvelopeEnabled {
            version = NativeOCRRawCanonicalPolicy.detectorAlternatePolicyVersion
        } else {
            version = policyVersion
        }
        return .init(requestID: requestID, sourceImageIdentity: sourceImageIdentity, width: frame.width, height: frame.height,
            sourceAnchorMode: mode.rawValue, runtimePolicyVersion: version)
    }

    /// Complete source-anchor path. No legacy recovery/correction route, no
    /// alternate learned weights. RF result is the actual upstream full result.
    /// Pre-REC keeps the complete source165 context. The optional simple NMS
    /// consumes actual crop-bound reads without a post-REC feature matrix.
    private static func recognizeSourceAnchors(
        frame: NativeOCRRGBAFrame, requestID: String,
        originals: [NativeCoreMLDetectionBox], probability: NativeMainEnsembleOCRProbability.Sample,
        layout: NativeRFDETRLayoutResult, preRecognitionModel: NativeOCRPreRecognitionFilter.Model?,
        recognizer: any NativeCoreMLRecognizing, recognitionThreshold: Double,
        mode: SourceAnchorMode, moduleObserver observer: NativeOCRRawModuleObservation.Observer?,
        simpleDeduplication: NativeSimpleOCRDedup.Configuration?,
        simpleRecognitionAdmission: NativeSimpleRecognitionAdmission.Configuration?,
        compactAgreementEnabled: Bool,
        boundaryExpansion: NativeSimpleOCRBoundaryExpansion.Configuration?,
        detectorAlternates: Bool,
        cancellationCheck: @escaping @Sendable () throws -> Void,
        stageHandler: (@Sendable (NativeCoreMLOCRStage) -> Void)?
    ) async throws -> Output {
        typealias G = NativeOCRIndividualGeometryHypotheses
        typealias F = NativeOCRPreRecognitionFeatures
        try cancellationCheck()
        guard mode != .disabled, frame.width == layout.sourceWidth, frame.height == layout.sourceHeight,
              probability.sourceWidth == frame.width, probability.sourceHeight == frame.height,
              let grid = layout.semanticGrid, grid.isValid, grid.hasValidWeightedMeanProbabilities,
              grid.modelWeightsSHA256 == NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
              grid.imageIdentity == layout.imageIdentity, let support = layout.sourceSupportGrid,
              let rf = NativeOCRSourceSupportFeatures155.PreparedRF(width:frame.width,height:frame.height,
                native17Fields:support.native17Fields) else { throw Failure.missingEvidence }
        let detectorSources = originals.map { box in
            F.SourceObservation(polygon:box.polygon.map { [Double($0.x),Double($0.y)] },
                score:Double(box.score),detectorSeedEvidence:box.detectorSeedEvidence)
        }
        // SourceParent authenticates the exact observed raw query; a detached
        // candidate does not invent text ownership or claim a detector owner.
        // .corrected is the existing detached-bank wire family, NOT a claim
        // that geometry-model inference ran. Policy+counts below distinguish it.
        let originalRecords = originals.enumerated().map { index, box in
            G.Record(requestID:requestID,sourceIndex:originals.count+index,sourceParent:index,
                sourceMembers:[],alternativeID:"source-anchor-only/\(index)",origin:.corrected,
                originalDetectorIndex:nil,polygon:box.polygon.map { .init(x:Double($0.x),y:Double($0.y)) })
        }
        let alternateRecords = detectorAlternates ? try detectorAlternateRecords(requestID: requestID,
            originals: originals, width: frame.width, height: frame.height) : []
        let records = alternateRecords.isEmpty ? originalRecords : originalRecords + alternateRecords
        let generated = G.emit(requestID:requestID,corrected:records,originals:[],layout:[],refinements:[],
            mode:.sourceOriginalLayoutRefinedAndCorrectedV3)
        if let observer {
            observer.proposals(generated, binding: moduleBinding(requestID: requestID, frame: frame,
                sourceImageIdentity: layout.imageIdentity, mode: mode))
        }
        // Never merge exact same quads from different roots into guessed owners.
        guard generated.individuals.count == records.count,
              generated.individuals.allSatisfy({ $0.provenance.count == 1 }) else { throw Failure.missingEvidence }
        let bbox = try NativeOCRBBoxConfidenceAdmission.apply(generated,probability:probability,
            sourceWidth:frame.width,sourceHeight:frame.height,enabled:true,cancellationCheck:cancellationCheck)
        guard bbox.report.applied else { throw Failure.missingEvidence }
        if let observer {
            observer.bboxAdmission(bbox, binding: moduleBinding(requestID: requestID, frame: frame,
                sourceImageIdentity: layout.imageIdentity, mode: mode))
        }
        let candidateSources = try bbox.output.individuals.map { row -> F.SourceObservation in
            guard row.provenance.count == 1, let p = row.provenance.first,
                  p.requestID == requestID, p.sourceMembers.isEmpty, p.originalDetectorIndex == nil,
                  detectorSources.indices.contains(p.sourceParent),
                  p.polygon == row.polygon,
                  (p == originalRecords[p.sourceParent] || alternateRecords.contains(p)) else {
                throw Failure.missingEvidence
            }
            return detectorSources[p.sourceParent]
        }
        let recognitionInput: G.Output
        let boundaryExpansionReport: NativeSimpleOCRBoundaryExpansion.Report?
        if let configuration = boundaryExpansion {
            let signals = try NativeSimpleOCRBoundaryExpansion.extract(input:bbox.output,rf:rf,
                sourceWidth:frame.width,sourceHeight:frame.height)
            let expanded = try NativeSimpleOCRBoundaryExpansion.apply(bbox.output,signals:signals,configuration:configuration)
            // The transform cannot delete/reorder roots, infer an owner, or
            // turn its computed output into a newly observed detector packet.
            guard expanded.output.individuals.count == bbox.output.individuals.count,
                  zip(bbox.output.individuals,expanded.output.individuals).allSatisfy({ before,after in
                      before.provenance.count == after.provenance.count &&
                      zip(before.provenance,after.provenance).allSatisfy({ old,new in
                          old.requestID == new.requestID && old.sourceIndex == new.sourceIndex &&
                          old.sourceParent == new.sourceParent && old.sourceMembers == new.sourceMembers
                      })
                  }) else { throw NativeSimpleOCRBoundaryExpansionRuntime.Failure.invalidSourceBinding }
            recognitionInput = expanded.output
            boundaryExpansionReport = expanded.report
        } else {
            recognitionInput = bbox.output
            boundaryExpansionReport = nil
        }
        // Actual RAW scored bank supplies the full context before any deletion.
        // Its DB means are recalculated by the same bbox raster, never compared
        // to contour confidence as if the two scores were calibrated equally.
        let featureRequirement = NativeSimpleRecognitionAdmission.featureRequirement(compactEnabled: compactAgreementEnabled,
            allowsCompactMode: mode == .noPreRecognition, usesSimpleDeduplication: simpleDeduplication != nil,
            observingModules: observer != nil, configuration: simpleRecognitionAdmission)
        let source165: [[Double]]?
        let recognitionAgreement: [F.RecognitionAgreement]?
        let sourceFeatureEvaluation: SourceFeatureEvaluation
        switch featureRequirement {
        case .full165:
            let measured = try F.extract(input:recognitionInput,sourceObservations:candidateSources,
                detectorObservations:detectorSources,rf:rf,sourceWidth:frame.width,sourceHeight:frame.height)
            source165 = measured
            recognitionAgreement = nil
            sourceFeatureEvaluation = .init(mode:.full165,candidateRows:bbox.output.individuals.count,materializedRows:measured.count)
        case .recognitionAgreement2:
            let measured = try F.extractRecognitionAgreement(input:recognitionInput,detectorObservations:detectorSources,
                rf:rf,sourceWidth:frame.width,sourceHeight:frame.height)
            source165 = nil
            recognitionAgreement = measured
            sourceFeatureEvaluation = .init(mode:.recognitionAgreement2,candidateRows:bbox.output.individuals.count,materializedRows:measured.count)
        case .notRequired:
            source165 = nil
            recognitionAgreement = nil
            sourceFeatureEvaluation = .init(mode:.notRequired,candidateRows:bbox.output.individuals.count,materializedRows:0)
        }
        let scheduled: G.Output
        let preIndices: [Int]
        let preEvaluation: PreRecognitionEvaluation
        if mode == .fixedPreRecognition {
            guard let preRecognitionModel, let source165 else { throw Failure.missingEvidence }
            let pre = try NativeOCRPreRecognitionFilter.apply(recognitionInput,features:source165,model:preRecognitionModel)
            scheduled = pre.output; preIndices = pre.report.keptIndices
            preEvaluation = .measured(report:pre.report,features:source165)
            if let observer {
                observer.preRecognition(input: recognitionInput, scheduled: scheduled, source165: source165, report: pre.report,
                    binding: moduleBinding(requestID: requestID, frame: frame,
                        sourceImageIdentity: layout.imageIdentity, mode: mode))
            }
        } else {
            scheduled = recognitionInput; preIndices = Array(recognitionInput.individuals.indices)
            preEvaluation = .notExecuted(availableRows:bbox.output.individuals.count)
            if let observer {
                guard let source165 else { throw Failure.missingEvidence }
                observer.preRecognition(input: recognitionInput, scheduled: scheduled, source165: source165, report: nil,
                    binding: moduleBinding(requestID: requestID, frame: frame,
                        sourceImageIdentity: layout.imageIdentity, mode: mode))
            }
        }
        let regions = scheduled.individuals.enumerated().map { index,row in
            NativeCoreMLRecognitionRegion(sourceIndex:index,polygon:row.polygon.map { CGPoint(x:$0.x,y:$0.y) })
        }
        try cancellationCheck()
        stageHandler?(.recognizing(regionCount:regions.count))
        let threshold = min(1,max(0,recognitionThreshold))
        let decoded = try await recognizer.recognize(frame:frame,regions:regions,requestID:requestID,
            confidenceThreshold:threshold,cancellationCheck:cancellationCheck)
        try cancellationCheck()
        guard decoded.requestID == requestID,
              Set(decoded.regions.map(\.sourceIndex)).count == decoded.regions.count else { throw Failure.invalidRecognition }
        var reads = decoded.regions.sorted { $0.sourceIndex < $1.sourceIndex }
        guard reads.allSatisfy({ read in
            regions.indices.contains(read.sourceIndex) && read.polygon == regions[read.sourceIndex].polygon
                && read.confidence.isFinite && read.confidence >= threshold && read.confidence <= 1 && !read.text.isEmpty
        }) else { throw Failure.invalidRecognition }
        var effectiveBank = scheduled
        var effectiveSource165 = source165
        var effectiveRecognition = decoded
        var terminalReceipt: TerminalReceipt?
        if mode == .noPreRecognitionTerminalRecovery {
            typealias T = NativeOCRSourceTerminalRecovery
            guard preIndices == Array(scheduled.individuals.indices) else { throw Failure.missingEvidence }
            let nominated = try T.proposals(bank:scheduled,reads:reads,originals:originals,layout:layout,
                probability:probability,cancellationCheck:cancellationCheck)
            let geometrySelection = T.uniqueProposalGeometry(nominated)
            let proposed = geometrySelection.proposals
            terminalReceipt = .init(proposedParents:nominated.count,bboxAdmittedParents:0,
                retryRequestedRegions:0,retryPredictedRegions:0,acceptedReplacements:[],
                duplicateGeometryRejected:geometrySelection.duplicateGeometryRejected,
                invalidGeometryRejected:geometrySelection.invalidGeometryRejected)
            if !proposed.isEmpty {
            let candidateRecords = proposed.map { p -> G.Record in
                let old = scheduled.individuals[p.parentBankIndex].provenance[0]
                return .init(requestID:requestID,sourceIndex:old.sourceIndex,sourceParent:old.sourceParent,
                    sourceMembers:[],alternativeID:"source-anchor-terminal-v2/\(p.parentSource)+\(p.terminalSource)",
                    origin:.corrected,originalDetectorIndex:nil,polygon:p.polygon)
            }
            let candidateBank = G.emit(requestID:requestID,corrected:candidateRecords,originals:[],
                layout:[],refinements:[],mode:.correctedOnly)
            let candidateBBox = try NativeOCRBBoxConfidenceAdmission.apply(candidateBank,probability:probability,
                sourceWidth:frame.width,sourceHeight:frame.height,enabled:true,cancellationCheck:cancellationCheck)
            guard candidateBBox.report.applied,candidateBBox.report.rows.count == proposed.count else { throw Failure.missingEvidence }
            let admitted = candidateBBox.report.rows.filter(\.kept).map { row in (proposed[row.inputOrdinal],row.bboxConfidence) }
            if !admitted.isEmpty {
                let retryRegions = admitted.map { p,_ in
                    NativeCoreMLRecognitionRegion(sourceIndex:p.parentBankIndex,
                        polygon:p.polygon.map { CGPoint(x:$0.x,y:$0.y) })
                }
                stageHandler?(.recognizing(regionCount:retryRegions.count))
                let retry = try await recognizer.recognize(frame:frame,regions:retryRegions,requestID:requestID,
                    confidenceThreshold:threshold,cancellationCheck:cancellationCheck)
                try cancellationCheck()
                let byParent = Dictionary(uniqueKeysWithValues:admitted.map { ($0.0.parentBankIndex,$0) })
                let originalReads = Dictionary(uniqueKeysWithValues:reads.map { ($0.sourceIndex,$0) })
                guard retry.requestID == requestID,
                      Set(retry.regions.map(\.sourceIndex)).count == retry.regions.count,
                      retry.regions.allSatisfy({ read in
                        guard let item=byParent[read.sourceIndex] else { return false }
                        return read.polygon == item.0.polygon.map { CGPoint(x:$0.x,y:$0.y) }
                            && read.confidence.isFinite && read.confidence>=threshold && read.confidence<=1 && !read.text.isEmpty
                      }) else { throw Failure.invalidRecognition }
                var updated = scheduled.individuals
                var accepted = originalReads
                var proofs = [T.Proof]()
                for read in retry.regions.sorted(by:{ $0.sourceIndex<$1.sourceIndex }) {
                    guard let (p,score)=byParent[read.sourceIndex],let parent=originalReads[read.sourceIndex],
                          T.preservesAndAdds(parent:parent.text,retry:read.text) else { continue }
                    let old = scheduled.individuals[p.parentBankIndex].provenance[0]
                    let proof = G.Record(requestID:requestID,sourceIndex:old.sourceIndex,sourceParent:old.sourceParent,
                        sourceMembers:[],alternativeID:"source-anchor-terminal-v2/\(p.parentSource)+\(p.terminalSource)",
                        origin:.corrected,originalDetectorIndex:nil,polygon:p.polygon)
                    updated[p.parentBankIndex] = .init(polygon:p.polygon,provenance:[proof],bboxConfidence:score)
                    accepted[read.sourceIndex] = read
                    proofs.append(.init(requestID:requestID,sourceImageIdentity:layout.imageIdentity,
                        parentSource:p.parentSource,terminalSource:p.terminalSource,rfQueryID:p.rfQueryID,
                        polygon:p.polygon,bboxConfidence:score,recognitionConfidence:read.confidence,
                        prefixUTF8Count:parent.text.utf8.count,appendedCharacterCount:read.text.count-parent.text.count,
                        parentPrivatePixels:p.parentPrivatePixels,terminalPrivatePixels:p.terminalPrivatePixels))
                }
                if !proofs.isEmpty {
                    effectiveBank = .init(mode:scheduled.mode,individuals:updated,counts:scheduled.counts,events:scheduled.events)
                    // Recompute on the ACTUAL whole scored bank; no cached165
                    // context or old REC confidence follows a changed polygon.
                    effectiveSource165 = try F.extract(input:effectiveBank,sourceObservations:candidateSources,
                        detectorObservations:detectorSources,rf:rf,sourceWidth:frame.width,sourceHeight:frame.height)
                    reads = accepted.values.sorted { $0.sourceIndex<$1.sourceIndex }
                }
                effectiveRecognition = .init(requestID:requestID,regions:reads,
                    diagnostics:decoded.diagnostics.addingRecovery(retry.diagnostics,acceptedCount:reads.count,
                        includingRecoveryRequests:true))
                terminalReceipt = .init(proposedParents:nominated.count,bboxAdmittedParents:admitted.count,
                    retryRequestedRegions:retryRegions.count,retryPredictedRegions:retry.diagnostics.predictedRegions,
                    acceptedReplacements:proofs,duplicateGeometryRejected:geometrySelection.duplicateGeometryRejected,
                    invalidGeometryRejected:geometrySelection.invalidGeometryRejected)
            } else {
                terminalReceipt = .init(proposedParents:nominated.count,bboxAdmittedParents:0,
                    retryRequestedRegions:0,retryPredictedRegions:0,acceptedReplacements:[],
                    duplicateGeometryRejected:geometrySelection.duplicateGeometryRejected,
                    invalidGeometryRejected:geometrySelection.invalidGeometryRejected)
            }
            }
        }
        let recognitionAdmission: NativeSimpleRecognitionAdmission.Report?
        if let configuration = simpleRecognitionAdmission {
            let admitted: NativeSimpleRecognitionAdmission.Result
            if let effectiveSource165 {
                admitted = try NativeSimpleRecognitionAdmission.apply(reads, source165: effectiveSource165,
                    source165Indices: preIndices, configuration: configuration)
            } else if let recognitionAgreement {
                admitted = try NativeSimpleRecognitionAdmission.apply(reads, agreement: recognitionAgreement,
                    source165Indices: preIndices, configuration: configuration)
            } else {
                admitted = try NativeSimpleRecognitionAdmission.apply(reads, configuration: configuration)
            }
            reads = admitted.reads
            recognitionAdmission = admitted.report
        } else { recognitionAdmission = nil }
        let elected = !alternateRecords.isEmpty
            ? detectorAlternateElection(reads: reads, bank: effectiveBank, originalCount: originals.count)
            : nil
        let electedReads = elected.map { election in election.kept.map { reads[$0] } } ?? reads
        let recognized = G.selecting(effectiveBank,indices:electedReads.map(\.sourceIndex))
        let source166: [[Double]]?
        if simpleDeduplication == nil || observer != nil {
            guard let effectiveSource165 else { throw Failure.missingEvidence }
            let accepted165 = electedReads.map { effectiveSource165[preIndices[$0.sourceIndex]] }
            let measured = try NativeOCRPostRecognitionFeatures.extract(input:recognized,source165:accepted165,
                recognitionConfidences:electedReads.map(\.confidence))
            source166 = measured
            if let observer {
                observer.postRecognition(scheduled: effectiveBank, input: recognized, reads: electedReads,
                    source165Indices: electedReads.map { preIndices[$0.sourceIndex] }, accepted165: accepted165, source166: measured,
                    binding: moduleBinding(requestID: requestID, frame: frame,
                        sourceImageIdentity: layout.imageIdentity, mode: mode))
            }
        } else { source166 = nil }
        let dedup: NativeOCRPostRecognitionDeduplication.Result
        if let configuration = simpleDeduplication {
            dedup = try NativeSimpleOCRDedup.apply(recognized, reads: electedReads, configuration: configuration)
        } else {
            guard let source166 else { throw Failure.missingEvidence }
            dedup = try NativeOCRPostRecognitionDeduplication.apply(recognized,source166:source166)
        }
        if let observer {
            observer.deduplication(input: recognized, result: dedup, binding: moduleBinding(requestID: requestID, frame: frame,
                sourceImageIdentity: layout.imageIdentity, mode: mode))
        }
        let packets = try NativeSimpleOCRBoundaryExpansionRuntime.packets(reads:reads,
            originalAnchors:bbox.output,source165Indices:preIndices,originals:originals,
            preserveOriginalMetadata:boundaryExpansion != nil)
        let bound = NativeOCRAcceptedSource.bindingPrimary(packets,width:frame.width,height:frame.height)
        let lines = dedup.report.keptIndices.map { index -> NativeCoreMLOCRLine in
            let winner = elected?.kept[index] ?? index
            var line = bound[winner]
            if let membership = line.acceptedSource.membership {
                let removed = dedup.report.replacements.filter { $0.retainedIndex == index }.map(\.inputIndex)
                var unknown: Set<Int>
                if let elected {
                    let removedReads = removed.map { elected.kept[$0] }
                    unknown = Set(removedReads)
                    unknown.formUnion(([winner] + removedReads).compactMap { elected.suppressedByWinner[$0] })
                } else {
                    unknown = Set(removed)
                }
                line.acceptedSource = .init(.init(table:membership.table,body:membership.body,readings:membership.readings,
                    unknownDedup:unknown,hasUntrackedInputs:false),detectorSignals:line.acceptedSource.detectorSignals)
            }
            guard mode == .noPreRecognition, boundaryExpansion == nil, !detectorAlternates else { return line }
            let extent = NativeOCRRawCanonicalPolicy.estimatedLineExtent(line.polygon, width: frame.width, height: frame.height)
            guard extent != line.polygon else { return line }
            var calibrated = NativeCoreMLOCRLine(polygon: extent, text: line.text, score: line.score,
                orientation: line.orientation, orientationIsEstimated: line.orientationIsEstimated,
                sourceTileBounds: line.sourceTileBounds, erasurePolygons: line.erasurePolygons,
                detectorSeedEvidence: line.detectorSeedEvidence, acceptedSource: line.acceptedSource)
            calibrated.preCalibrationPolygon = line.polygon
            return calibrated
        }
        if let observer {
            observer.acceptedMembership(lines, binding: moduleBinding(requestID: requestID, frame: frame,
                sourceImageIdentity: layout.imageIdentity, mode: mode))
        }
        let alternateReceipt: DetectorAlternateReceipt? = detectorAlternates ? .init(proposed: alternateRecords.count,
            bboxAdmitted: bbox.output.individuals.filter { isDetectorAlternate($0, originalCount: originals.count) }.count,
            recognitionAdmitted: reads.filter { isDetectorAlternate(effectiveBank.individuals[$0.sourceIndex], originalCount: originals.count) }.count,
            retained: dedup.output.individuals.filter { isDetectorAlternate($0, originalCount: originals.count) }.count) : nil
        return .init(lines:lines,recognition:effectiveRecognition,geometry:dedup.output.individuals,
            receipt:.init(policyVersion:detectorAlternates ? NativeOCRRawCanonicalPolicy.detectorAlternatePolicyVersion : mode.rawValue,
                primaryObservations:originals.count,auxiliaryObservations:0,
                generated:generated.individuals.count,bboxAdmitted:bbox.output.individuals.count,
                preRecognitionAdmitted:scheduled.individuals.count,recognized:effectiveRecognition.regions.count,retained:lines.count,
                detectorThreshold:try NativeOCRBBoxConfidenceAdmission.threshold(),recognitionThreshold:threshold,
                sourceAnchorMode:mode.rawValue,fixedModelPredictionCounts:.init(primaryGeometryRows:0,sourceGateRows:0,
                    auxiliaryGeometryRows:0,noveltyReferenceRows:0,
                    preRecognitionRows:preEvaluation.attemptedRows),terminalRecovery:terminalReceipt,
                preRecognitionEvaluation:preEvaluation,simpleRecognitionAdmission:recognitionAdmission,
                sourceFeatureEvaluation:sourceFeatureEvaluation,boundaryExpansion:boundaryExpansionReport,detectorAlternates:alternateReceipt))
    }

    static func detectorAlternateRecords(requestID: String, originals: [NativeCoreMLDetectionBox], width: Int, height: Int) throws
        -> [NativeOCRIndividualGeometryHypotheses.Record] {
        typealias G = NativeOCRIndividualGeometryHypotheses
        typealias D = NativeOCRGeometryDeduplication
        let candidates = try originals.enumerated().compactMap { index, box -> G.Record? in
            guard let alternate = box.alternateRecognitionPolygon else { return nil }
            let raw = D.Shape(box.polygon.map { .init(x: Double($0.x), y: Double($0.y)) })
            let changed = D.Shape(alternate.map { .init(x: Double($0.x), y: Double($0.y)) })
            guard raw.convex, changed.convex, raw.area.isFinite, changed.area.isFinite, changed.area > raw.area,
                  changed.minX >= 0, changed.minY >= 0, changed.maxX <= Double(width), changed.maxY <= Double(height) else {
                throw Failure.invalidDetectorAlternate
            }
            let iou = D.intersectionIoU(raw, changed, minimum: 0)
            let overlap = iou * (raw.area + changed.area) / (1 + iou)
            guard overlap >= raw.area - 1e-7 else { throw Failure.invalidDetectorAlternate }
            return .init(requestID: requestID, sourceIndex: 2 * originals.count + index, sourceParent: index,
                sourceMembers: [], alternativeID: "source-anchor-db-cell-alternate-v1/\(index)",
                origin: .corrected, originalDetectorIndex: nil, polygon: changed.polygon)
        }
        guard candidates.count <= NativeCoreMLDBPostprocessor.maximumAlternateCellEnvelopes else {
            throw Failure.invalidDetectorAlternate
        }
        return candidates
    }

    struct DetectorAlternateElection {
        let kept: [Int]
        let suppressedByWinner: [Int: Int]
    }

    private static func isDetectorAlternate(_ row: NativeOCRIndividualGeometryHypotheses.Individual, originalCount: Int) -> Bool {
        row.provenance[0].sourceIndex >= 2 * originalCount
    }

    static func detectorAlternateElection(reads: [NativeCoreMLRecognizedRegion], bank: NativeOCRIndividualGeometryHypotheses.Output,
                                          originalCount: Int) -> DetectorAlternateElection {
        var originalReads: [Int: Int] = [:]
        for (index, read) in reads.enumerated() {
            let row = bank.individuals[read.sourceIndex]
            if !isDetectorAlternate(row, originalCount: originalCount) { originalReads[row.provenance[0].sourceParent] = index }
        }
        var suppressedByWinner: [Int: Int] = [:]
        for (index, read) in reads.enumerated() {
            let row = bank.individuals[read.sourceIndex]
            guard isDetectorAlternate(row, originalCount: originalCount),
                  let parent = originalReads[row.provenance[0].sourceParent] else { continue }
            // If both crops were read, a changed geometry can win only after an
            // independent REC returned the exact same text at no lower confidence.
            if read.text.utf8.elementsEqual(reads[parent].text.utf8), read.confidence >= reads[parent].confidence {
                suppressedByWinner[index] = parent
            } else {
                suppressedByWinner[parent] = index
            }
        }
        let removed = Set(suppressedByWinner.values)
        let kept = reads.indices.filter { !removed.contains($0) }.sorted { left, right in
            bank.individuals[reads[left].sourceIndex].provenance[0].sourceParent
                < bank.individuals[reads[right].sourceIndex].provenance[0].sourceParent
        }
        return .init(kept: kept, suppressedByWinner: suppressedByWinner)
    }
}

/// The diagnostic line bank preserves both geometries. Only distinct source
/// lines enter translation, in stable primary-then-complement order.
@available(iOS 18.0, *)
enum NativeOCRLegacyComplementFilter {
    private typealias Geometry = NativeOCRGeometryDeduplication

    static func representatives(_ lines: [NativeCoreMLOCRLine], width: Int, height: Int) -> [NativeCoreMLOCRLine] {
        guard lines.contains(where: \.isLegacyComplement) else { return lines }
        var primary = lines.filter { !$0.isLegacyComplement }
        let legacy = lines.filter(\.isLegacyComplement)
        guard !primary.isEmpty else { return legacy }
        var primaryKeys = [String?](repeating: nil, count: primary.count)
        let shapes = primary.map { shape($0.polygon) }
        var bestLegacy = Array(repeating: (index: -1, iou: 0.0), count: primary.count)
        var owners = Array(repeating: -1, count: legacy.count)
        var extra: [NativeCoreMLOCRLine] = []
        for (j, line) in legacy.enumerated() {
            let candidate = shape(line.polygon)
            var textKey: String?
            var best = (index: -1, iou: 0.0)
            var supportsBoundary = false
            var suppressExtra = false
            for i in shapes.indices {
                let shape = shapes[i]
                guard shape.minX < candidate.maxX, candidate.minX < shape.maxX,
                      shape.minY < candidate.maxY, candidate.minY < shape.maxY else { continue }
                let iou = Geometry.intersectionIoU(shape, candidate, minimum: 0.15)
                if iou > best.iou { best = (i, iou) }
                if iou > bestLegacy[i].iou { bestLegacy[i] = (j, iou) }
                if iou >= 0.80 { supportsBoundary = true }
                if iou >= 0.95 { suppressExtra = true }
                guard iou >= 0.15, !supportsBoundary || (!suppressExtra && iou >= 0.70) else { continue }
                // Normalize only when text can still change a decision for this legacy line.
                let legacyKey = textKey ?? NativeFinalOutputDuplicateResolver.textKey(line.text)
                textKey = legacyKey
                let primaryKey = primaryKeys[i] ?? NativeFinalOutputDuplicateResolver.textKey(primary[i].text)
                primaryKeys[i] = primaryKey
                if closeText(legacyKey, primaryKey) {
                    supportsBoundary = true
                    if iou >= 0.70 { suppressExtra = true }
                }
            }
            if !suppressExtra { extra.append(line) }
            // A second extent can support the primary boundary and still be a
            // distinct candidate for downstream grouping and duplicate checks.
            if supportsBoundary && best.iou >= 0.35 { owners[j] = best.index }
        }
        for i in primary.indices {
            let j = bestLegacy[i].index
            guard j >= 0, owners[j] == i else { continue }
            primary[i] = consensus(primary[i], legacy[j].polygon, width: width, height: height)
        }
        return primary + extra
    }

    private static func shape(_ points: [CGPoint]) -> Geometry.Shape {
        Geometry.Shape(points.map { .init(x: Double($0.x), y: Double($0.y)) })
    }


    private static func closeText(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty && !b.isEmpty else { return false }
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count >= 3 else { return false }
        if long.contains(short) { return true }
        guard long.count - short.count <= 1 else { return false }
        if short.count == long.count {
            return zip(short, long).lazy.filter { $0.0 != $0.1 }.prefix(2).count == 1
        }
        let first = Array(short), second = Array(long)
        let i = first.indices.first { first[$0] != second[$0] } ?? first.count
        return first[i...].elementsEqual(second[(i+1)...])
    }

    /// Average bounded short-edge offsets in the primary quad's local frame.
    /// A boundary estimate never changes the observed REC pixels or membership.
    private static func consensus(_ line: NativeCoreMLOCRLine, _ alternate: [CGPoint],
                                  width: Int, height: Int) -> NativeCoreMLOCRLine {
        let p = line.polygon
        guard p.count == 4, alternate.count == 4 else { return line }
        let u = CGPoint(x: (p[1].x-p[0].x+p[2].x-p[3].x)/2, y: (p[1].y-p[0].y+p[2].y-p[3].y)/2)
        let v = CGPoint(x: (p[3].x-p[0].x+p[2].x-p[1].x)/2, y: (p[3].y-p[0].y+p[2].y-p[1].y)/2)
        let det = u.x*v.y-u.y*v.x
        guard abs(det) >= 1 else { return line }
        let center = CGPoint(x: p.map(\.x).reduce(0,+)/4, y: p.map(\.y).reduce(0,+)/4)
        let useU = hypot(u.x,u.y) <= hypot(v.x,v.y)
        let axis = useU ? u : v
        let local = alternate.map { point -> CGFloat in
            let x = point.x-center.x, y = point.y-center.y
            return (useU ? x*v.y-y*v.x : u.x*y-u.y*x)/det
        }
        let low = min(0.15, max(-0.15, local.min()! + 0.5))/2
        let high = min(0.15, max(-0.15, local.max()! - 0.5))/2
        let estimated = p.enumerated().map { i, point in
            let delta = (useU ? i == 1 || i == 2 : i >= 2) ? high : low
            return CGPoint(x: point.x + axis.x*delta, y: point.y + axis.y*delta)
        }
        guard estimated.allSatisfy({ (0...CGFloat(width)).contains($0.x) && (0...CGFloat(height)).contains($0.y) })
        else { return line }
        var result = NativeCoreMLOCRLine(polygon: estimated, text: line.text, score: line.score,
            orientation: line.orientation, orientationIsEstimated: line.orientationIsEstimated,
            sourceTileBounds: line.sourceTileBounds, erasurePolygons: line.erasurePolygons,
            detectorSeedEvidence: line.detectorSeedEvidence, acceptedSource: line.acceptedSource)
        result.preCalibrationPolygon = line.preCalibrationPolygon ?? p
        return result
    }
}
