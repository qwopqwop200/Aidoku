import Foundation
import CoreGraphics

/// Raw435 audit only. Prediction is geometry, never admission/selection authority.
@available(iOS 18.0, *)
enum NativeOCRSourceLiveRegression435 {
    typealias K = NativeOCRSourceBoundaryRegression435
    typealias F = NativeOCRSourceLocalJoint369
    struct Output {
        let proposals: [NativeOCRResidualCandidate]
        let records: [[String: Any]]
        let receipt: [String: Any]
        let source435: K.Extracted?
        init(proposals: [NativeOCRResidualCandidate], records: [[String: Any]],
             receipt: [String: Any], source435: K.Extracted? = nil) {
            self.proposals = proposals; self.records = records; self.receipt = receipt
            self.source435 = source435
        }
    }
    static func generate(prior: NativeOCRCurrentPrior351.Resolution,
        graph: NativeOCRSourceLocalJoint369Capture.FinalGraph, measurement m: F.M,
        live: F.LiveObservation, frame: NativeOCRRGBAFrame,
        actualFallback: [CGPoint]?, actualFallback8: [Double]?,
        canonicalBaseline: [CGPoint]?, baselineBinding: [String: Any],
        sourcePrefix22: [Double], sourceFactoryReceipt: [String: Any],
        context: NativeOCRSourceShapeFeatures406.Context?,
        sourceRF layout: NativeRFDETRLayoutResult?, meanOnly: Bool = false,
        geometryOnlyForUtility: Bool = false) -> Output {
        var receipt: [String: Any] = ["family": "source-regression435-qualified425",
            "modelSHA256": SourceBoundaryRegression435Calibration.frozenBundleSHA256,
            "maximumNewProposals": 8, "automaticSelection": false,
            "GTRead": false, "RFOrDetectorTreatedAsForeground": false,
            "baselineBinding": baselineBinding, "outsideCapturePolicy": "explicit-unavailable-no-clipping"]
        if meanOnly {
            receipt["family"] = "source-regression435-mean-qualified425"
            receipt["maximumNewProposals"] = 1
            receipt["fixedProposalKind"] = "mean"
            receipt["meanOnly"] = true
        }
        receipt["geometryOnlyForSourceUtility"] = geometryOnlyForUtility
        func fail(_ reason: String) -> Output {
            receipt["status"] = reason
            return .init(proposals: [], records: [], receipt: receipt)
        }
        guard let actual = graph.prior(m.index), actual.polygon == prior.polygon,
              actual.consumedIndices == prior.consumedIndices,
              actual.inheritedAssociationKey == prior.inheritedAssociationKey,
              live.sources.map(\.index) == [m.index] + prior.consumedIndices,
              live.sources.count == live.bodies.count, let body = live.bodies.first,
              body.prepared.inherited == prior.polygon,
              let fallback = actualFallback, let fallback8 = actualFallback8,
              fallback.count == 4, fallback8.count == 8, sourcePrefix22.count == 22,
              let context, context.basis.origin == m.origin,
              context.basis.normal == m.normal, context.basis.along == m.along,
              context.nativeW == m.rect.width, !context.support.isEmpty,
              let actualOld8 = context.features(fallback, fallback: fallback),
              zip(actualOld8, fallback8).allSatisfy({ abs($0.0 - $0.1) <= 1e-8 }),
              let bundle = SourceBoundaryRegression435Calibration.bundle else {
            return fail("unavailable-actualV3-fresh-context-model-or-root-binding")
        }
        let detector = canonicalBaseline ?? fallback
        guard detector.count == 4, baselineBinding["indicesOffsetBound"] as? Bool == true,
              body.sourceLocalRGBA.bytes == live.rgba.bytes,
              body.sourceLocalRGBA.origin == live.rgba.origin,
              body.sourceLocalRGBA.width == live.rgba.width,
              body.sourceLocalRGBA.height == live.rgba.height else {
            return fail("unavailable-canonical-baseline-or-live-byte-binding")
        }
        var rf: [[Double]] = []
        if let layout {
            guard layout.sourceWidth == frame.width, layout.sourceHeight == frame.height else {
                return fail("unavailable-RF-original-frame-binding")
            }
            //435 was trained on ALL original semanticClass0 rectangles in order,
            // not the >=0.4 local subset used by source-shape support extraction.
            for p in layout.primitives where p.semanticClass.rawValue == 0 {
                let b = p.sourceBounds
                rf.append([Double(b.minX), Double(b.minY), Double(b.width), Double(b.height), Double(p.confidence)])
            }
        }
        guard let mode = sourceFactoryReceipt["sourceShapeFeatureSupportMode406"] as? String,
              let confidence = sourceFactoryReceipt["sourceShapeFeatureSupportConfidence406"] as? Double,
              let supportCount = sourceFactoryReceipt["sourceShapeFeatureSupportPointCount406"] as? Int,
              let nativeCount = sourceFactoryReceipt["actualNativeCellCenterCount"] as? Int,
              mode == context.supportMode, confidence == context.supportConfidence,
              supportCount == context.support.count,
              nativeCount == body.actualFullFootprint.cells.count else {
            return fail("unavailable-actual-generated406-support-summary-binding")
        }
        receipt["supportSummaryBinding"] = ["generatedMode": mode, "generatedConfidence": confidence,
            "generatedSupportPointCount": supportCount, "typedContextSupportPointCount": context.support.count,
            "generatedNativeCellCenterCount": nativeCount,
            "rootBodyFullFootprintCellCount": body.actualFullFootprint.cells.count,
            "allActualMemberIndices": live.sources.map(\.index),
            "rootCountEqualityVerified": true, "groupUnionInvented": false] as [String: Any]
        let summary = [confidence, min(20, Double(supportCount) / 1000),
                       min(20, Double(nativeCount) / 1000)]
        let input = K.Input(prefix22: sourcePrefix22, fallback8: fallback8,
            actualV3: fallback.map { K.Point(Double($0.x), Double($0.y)) },
            originalDetector: detector.map { K.Point(Double($0.x), Double($0.y)) },
            rf: rf, frame: [Double(frame.width), Double(frame.height)], mode: mode, summary3: summary)
        guard let extracted = K.extract(input) else { return fail("unavailable-finite-exact50-source-input") }
        receipt["predictorInput"] = ["source_prefix22": sourcePrefix22, "fallback_source8": fallback8,
            "actual_v3_quad": fallback.map { [Double($0.x), Double($0.y)] },
            "original_detector_quad": detector.map { [Double($0.x), Double($0.y)] },
            "source_rf_text_rectangles": rf, "actual_frame_width_height": [frame.width, frame.height],
            "source_support_mode": mode, "source_support_confidence_samples_cells": summary] as [String: Any]
        receipt["sourceFeatures50"] = extracted.features
        receipt["actualV3InputAfterIndependent392Readmission"] = true
        receipt["baselineAbsentUsesFrozenFallbackRule"] = canonicalBaseline == nil
        receipt["sourceContextMeasuredFreshOnActualLive"] = true
        let r = live.rgba
        let allGeometry = K.proposals(bundle, extracted)
        // Filter before fresh descriptors, actual425 and424/426. No source/GT routing.
        let geometry = meanOnly ? allGeometry.filter { $0.kind == "mean" } : allGeometry
        guard geometry.count <= (meanOnly ? 1 : 8) else { return fail("invalid-producer-offer-budget") }
        var proposals: [NativeOCRResidualCandidate] = [], records: [[String: Any]] = []
        var outside = 0, missing = 0
        for offer in geometry {
            let q = offer.polygon.map { CGPoint(x: $0.x, y: $0.y) }
            let key = "source-regression435-" + offer.kind
            var row: [String: Any] = ["key": key, "polygon": offer.polygon.map { [$0.x, $0.y] },
                "rawOffer": ["key": key, "polygon": offer.polygon.map { [$0.x, $0.y] },
                    "sourceReceipt": offer.receipt, "hardRejections": [String](),
                    "softRejections": ["actual-native425-and-positive-loss-feasibility-required"]],
                "nativeAssessmentRun": false, "nativeAdmissionPassed": false,
                "automaticSelection": false, "sourceHardRejections": [String](),
                "sourcePixelObservationComplete": false]
            if geometryOnlyForUtility {
                row["sourceOnlyGeometryProposal"] = true
                row["legacy425PermissionClaimed"] = false
                row["physicalCoreCompletenessCertified"] = false
                records.append(row)
                continue
            }
            guard q.count == 4, q.allSatisfy({ $0.x > r.origin.x + 1 && $0.y > r.origin.y + 1 &&
                $0.x < r.origin.x + CGFloat(r.width) - 1 && $0.y < r.origin.y + CGFloat(r.height) - 1 }) else {
                row["unavailableReason"] = "new435-quad-outside-actual-live-capture-fresh-recapture-required"
                outside += 1; records.append(row); continue
            }
            guard let fresh8 = context.features(q, fallback: fallback),
                  let descriptor = SourceCost416FeatureAdapter.features(candidatePolygon: q,
                    fallbackPolygon: fallback, candidate8features406: fresh8,
                    fallback8features406: actualOld8, sourceFeaturePrefix22: sourcePrefix22,
                    sourceMode406: mode, sourceSupportConfidence406: confidence,
                    sourceSupportPointCount406: supportCount,
                    actualNativeCellCenterCount: nativeCount) else {
                row["unavailableReason"] = "new435-fresh-support-descriptor-unavailable"
                missing += 1; records.append(row); continue
            }
            row["sourceShapeFeatures406"] = fresh8
            row["freshFallbackShapeFeatures406"] = actualOld8
            row["sourceDescriptor52"] = descriptor
            row["descriptorMeasuredAgainstExact435Candidate"] = true
            proposals.append(.init(key: key, polygon: q, consumedIndices: prior.consumedIndices,
                supportPoints: prior.candidate?.supportPoints ?? [], associationKey: prior.inheritedAssociationKey))
            records.append(row)
        }
        receipt["status"] = "actual-live-raw435-generated-no-selection"
        receipt["geometryProposalCount"] = geometry.count
        receipt["insideCaptureFreshDescriptorCount"] = proposals.count
        receipt["outsideCaptureUnavailableCount"] = outside
        receipt["freshDescriptorUnavailableCount"] = missing
        receipt["liveRGBAOrigin"] = [Double(r.origin.x), Double(r.origin.y)]
        receipt["liveRGBAWidth"] = r.width; receipt["liveRGBAHeight"] = r.height
        return .init(proposals: proposals, records: records, receipt: receipt, source435: extracted)
    }
}
