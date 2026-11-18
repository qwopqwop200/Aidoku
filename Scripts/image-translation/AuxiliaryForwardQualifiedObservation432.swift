import Foundation
import CoreGraphics

/// Genuine production Context output with EXPLICIT nonexclusive/provisional lineage.
/// This is auxiliary recognition evidence, never a new original-owner Measurement/cache entry.
@available(iOS 18.0, *)
enum AuxiliaryForwardQualifiedObservation432 {
    typealias M = NativeOCRSourceComponentMeasurements.Measurement
    struct Observation {
        let sampledRecognitionEvidence: M
        let exactOriginalPlan: NativeOCRResidualEvidenceForwarding.Plan
        let unchangedOriginalRolePackets: [NativeOCRDetectorSeedEvidence]
        let provider = "genuine-existing-Context-from-forward-qualified-original-NN-cells-and-original-RGB"
        let scope = "derived positive NN observation for recognitioncrop,noerasure"
        let isOriginalOwnedNNTruth = false
        let replacesCanonicalMeasurement = false
        fileprivate init(sampled:M,plan:NativeOCRResidualEvidenceForwarding.Plan) {
            sampledRecognitionEvidence=sampled;exactOriginalPlan=plan;unchangedOriginalRolePackets=plan.evidence
        }
    }
    struct Assessment {
        let originalBaseline:M?
        let plan:NativeOCRResidualEvidenceForwarding.Plan?
        let actualSampled:M?
        let auxiliary:Observation?
        let reason:String
        let checkedCells:Int
        let excludedForeignCells:Int
    }
    static func observe(index:Int,polygon:[CGPoint],hasInk:Bool,
        originals:[NativeCoreMLDetectionBox],prepared:[NativeCoreMLDetectionBox],groups:[Int:[Int]],
        actualRFScopes:[NativeOCRSourceComponentMeasurements.Scope],actualFrame:NativeOCRRGBAFrame)->Assessment {
        let canonical=NativeOCRSourceComponentMeasurements.Context(originals:originals,prepared:prepared,
            groups:groups,scopes:actualRFScopes,frameProvider:{actualFrame})
        let old=canonical.measure(index:index,polygon:polygon,hasInk:hasInk,
            capturePrivateObservation:true,captureDensePrivateFootprint:true)
        let assessed=NativeOCRResidualEvidenceForwarding.assess(index:index,polygon:polygon,
            originals:originals,prepared:prepared,groups:groups)
        guard let baseline=old,let plan=assessed.plan else {
            return .init(originalBaseline:old,plan:nil,actualSampled:nil,auxiliary:nil,
                reason:assessed.reason,checkedCells:assessed.checkedCells,excludedForeignCells:assessed.excludedForeignCells)
        }
        let temporary=NativeOCRSourceComponentMeasurements.Context(originals:originals,prepared:prepared,
            groups:groups,scopes:actualRFScopes,frameProvider:{actualFrame},provisionalPlans:[index:plan])
        let sampled=temporary.measure(index:index,polygon:polygon,hasInk:hasInk,
            capturePrivateObservation:true,captureDensePrivateFootprint:true)
        let bound=sampled.map {m in
            m.index==baseline.index && m.polygon==baseline.polygon && m.origin==baseline.origin &&
            m.normal==baseline.normal && m.along==baseline.along && m.rect==baseline.rect &&
            m.score==baseline.score && m.kind==baseline.kind && m.hasInk==baseline.hasInk &&
            m.status=="measured" && m.privateSamples>=4 && !m.provisionalOwners.isEmpty &&
            plan.sourceIndex==index && plan.polygon==polygon && plan.allowedCells.count>=4 &&
            plan.evidence.allSatisfy{e in originals.contains{$0.detectorSeedEvidence==e}}
        } ?? false
        return .init(originalBaseline:baseline,plan:plan,actualSampled:sampled,
            auxiliary:bound ? Observation(sampled:sampled!,plan:plan):nil,reason:assessed.reason,
            checkedCells:assessed.checkedCells,excludedForeignCells:assessed.excludedForeignCells)
    }
}
