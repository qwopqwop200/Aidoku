import Foundation
import CoreGraphics

/// Runtime opt-in only. The pure geometry producer owns configuration math;
/// root owns cache/CLI fencing. Nil leaves the existing path untouched.
enum NativeSimpleOCRBoundaryExpansionRuntime {
    @TaskLocal static var configuration: NativeSimpleOCRBoundaryExpansion.Configuration? = nil

    enum Failure: Error { case incompatiblePolicy, invalidSourceBinding }

    static func validateCompatibility(mode: NativeOCRRawCanonicalPolicy.SourceAnchorMode,
                                      usesSimpleDeduplication: Bool,
                                      observingModules: Bool,
                                      compactAgreementEnabled: Bool) throws {
        // Old module-bank stage schemas bind bbox and preREC polygons exactly.
        // Never silently apply a new transform inside that old observation ABI.
        guard mode == .noPreRecognition, usesSimpleDeduplication,
              !observingModules, compactAgreementEnabled else { throw Failure.incompatiblePolicy }
    }

    /// Shared actual packet seam for live runtime and source-bound CPU replay.
    /// All raw DET observations remain context. No old165/15 or text/geometry
    /// association is inferred by overlap. Bind ALL returned packets before NMS.
    @available(iOS 18.0, *)
    static func packets(reads: [NativeCoreMLRecognizedRegion],
                        originalAnchors: NativeOCRIndividualGeometryHypotheses.Output,
                        source165Indices: [Int], originals: [NativeCoreMLDetectionBox],
                        preserveOriginalMetadata: Bool) throws -> [NativeCoreMLOCRLine] {
        let detectors = NativeOCRPremergeCandidateFeatures.prepareDetectorInventory(originals.map { box in
            NativeOCRPremergeCandidateFeatures.DetectorBox(
                polygon:box.polygon.map { .init(x:Double($0.x),y:Double($0.y)) },score:Double(box.score))
        })
        return try reads.map { read in
            let q = read.polygon.map { NativeOCRPremergeCandidateFeatures.Point(x:Double($0.x),y:Double($0.y)) }
            let detector = NativePostLLMContentReclassifier.detectorSignals(polygon:q,baseline:nil,
                inventory:detectors,recognitionConfidence:read.confidence)
            let observedSource: NativeCoreMLDetectionBox?
            if preserveOriginalMetadata {
                guard source165Indices.indices.contains(read.sourceIndex),
                      originalAnchors.individuals.indices.contains(source165Indices[read.sourceIndex]) else {
                    throw Failure.invalidSourceBinding
                }
                let row = originalAnchors.individuals[source165Indices[read.sourceIndex]]
                guard row.provenance.count == 1, let parent = row.provenance.first,
                      parent.sourceMembers.isEmpty, parent.originalDetectorIndex == nil,
                      originals.indices.contains(parent.sourceParent),
                      parent.sourceIndex == originals.count+parent.sourceParent,
                      parent.polygon == row.polygon,
                      parent.polygon.map({ CGPoint(x:$0.x,y:$0.y) }) == originals[parent.sourceParent].polygon else {
                    throw Failure.invalidSourceBinding
                }
                observedSource = originals[parent.sourceParent]
            } else { observedSource = nil }
            return .init(polygon:read.polygon,text:read.text,score:read.confidence,
                orientation:NativeCoreMLOCRPipeline.orientation(for:read.polygon),orientationIsEstimated:true,
                erasurePolygons:observedSource?.erasurePolygons ?? [],
                detectorSeedEvidence:observedSource.flatMap { source in source.detectorSeedEvidence.map { [$0] } },
                acceptedSource:.init(detectorSignals:detector))
        }
    }
}
