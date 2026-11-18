import Foundation
import CoreGraphics

/// Runtime source-only correction of actual retained geometry. Membership and
/// original measurements stay fixed; every nominated box enters native admission.
@available(iOS 18.0, *)
enum NativeOCRSourcePolicyRuntime403 {
    static let enabled = false
    typealias F = NativeOCRSourceLocalJoint369
    typealias M = F.M
    struct Result {
        let polygons: [Int: [CGPoint]]
        let applied: [Int: NativeOCRResidualCandidate]
        let measurements: [Int: M]
        let records: [[String: Any]]
    }
    static func apply(graph: NativeOCRSourceLocalJoint369Capture.FinalGraph,
        order: [Int], measurements originalMeasurements: [Int: M], sourcePrefixes: [Int: [Double]],
        originals: [NativeCoreMLDetectionBox], layout: NativeRFDETRLayoutResult?,
        width: Int, height: Int, frameProvider: () -> NativeOCRRGBAFrame?,
        freshMeasurement: (Int, M) -> M?, capsForSource: (M) -> [CGPoint]?,
        originalOwnedSupport: (Int) -> [CGPoint], accepts: (Int, [CGPoint]) -> Bool) -> Result {
        var changes: [Int: [CGPoint]] = [:], applied: [Int: NativeOCRResidualCandidate] = [:]
        var records: [[String: Any]] = [], measurements = originalMeasurements
        let roots = order.filter { index in
            guard graph.live.contains(index), let prior = graph.prior(index),
                  let m = originalMeasurements[index] else { return false }
            return SourceBoundary400Policy.mayGenerateFrozenCandidateV1(actualPrior: prior.polygon,
                nativeW: Double(m.rect.width), actualPrecoordSourcePrefix: sourcePrefixes[index] ?? [])
        }
        guard !roots.isEmpty else {
            return .init(polygons: changes, applied: applied, measurements: measurements, records: records)
        }
        // Identical passive enrichment to the proven native audit. No legacy
        // context/probe cache or ordinary measurement field is overwritten.
        for index in order {
            guard let old = originalMeasurements[index] else { continue }
            if NativeOCRSourceLocalJoint369Capture.hasCompletePrivate392(old, width: width, height: height) { continue }
            guard let fresh = freshMeasurement(index, old),
                  NativeOCRSourceLocalJoint369Capture.metadataDifferences392(old, fresh).isEmpty,
                  NativeOCRSourceLocalJoint369Capture.hasCompletePrivate392(fresh, width: width, height: height) else {
                measurements.removeValue(forKey: index); continue
            }
            var enriched = old
            enriched.privateObservation = fresh.privateObservation
            measurements[index] = enriched
        }
        guard let frame = frameProvider(), frame.width == width, frame.height == height else {
            return .init(polygons: changes, applied: applied, measurements: measurements, records: records)
        }
        for index in roots {
            guard let prior = graph.prior(index), let m = measurements[index],
                  ([index] + prior.consumedIndices).allSatisfy({ measurements[$0] != nil }),
                  let search = F.probe(prior: prior.polygon, sourceWidth: m.rect.width,
                    frameSize: .init(width: width, height: height)) else { continue }
            let roi = CGRect(x: CGFloat(search.window.left), y: CGFloat(search.window.top),
                width: CGFloat(search.window.width), height: CGFloat(search.window.height))
            let certification = NativeOCRSourceLocalJoint369Capture.localPeerEvidence(root: index,
                graph: graph, measurements: measurements, originals: originals,
                frameSize: .init(width: width, height: height), probeROI: roi, layout: layout)
            guard let peers = certification.evidence else { continue }
            let scopes = (layout?.primitives ?? []).filter { $0.sourceBounds.intersects(roi) }.map {
                F.Scope(rect: $0.sourceBounds, semanticClass: $0.semanticClass.rawValue,
                    confidence: Double($0.confidence))
            }
            guard let live = F.captureLive(currentPrior: prior, actualGraph: graph, measurement: m,
                originalFrame: frame, localPeerEvidence: peers, measurements: measurements,
                capsForSource: capsForSource, originalOwnedSupport: originalOwnedSupport,
                scopes: scopes, sharedWindow: search.window) else { continue }
            let generated = NativeOCRSourceLiveSharedBoundary400.generateFromLive(prior: prior,
                graph: graph, measurement: m, live: live,
                actualOriginalSeedEvidence: originals, sourceRF: layout)
            let prefix = sourcePrefixes[index] ?? []
            var rawByKey: [String: [String: Any]] = [:], nominees: [NativeOCRResidualCandidate] = []
            for raw in generated.offers {
                guard let key = raw["key"] as? String, !key.isEmpty, rawByKey[key] == nil,
                      let hard = raw["hardRejections"] as? [String], hard.isEmpty,
                      let q = SourceBoundary400Policy.points(raw["polygon"]),
                      let features = SourceBoundary400Policy.describe(rawOffer: raw,
                        actualPrior: prior.polygon, nativeW: Double(m.rect.width),
                        factoryReceipt: generated.receipt, sourcePrefix: prefix, sourceScore: m.score),
                      SourceBoundary400Policy.passes(features, policy: .frozenCandidateV1) else { continue }
                rawByKey[key] = raw
                nominees.append(.init(key: key, polygon: q, consumedIndices: prior.consumedIndices,
                    supportPoints: prior.candidate?.supportPoints ?? [],
                    associationKey: prior.inheritedAssociationKey))
            }
            guard !nominees.isEmpty else { continue }
            let assessed = NativeOCRSourceLiveAdmission392.assess(prior: prior, graph: graph,
                measurement: m, frame: frame, peerEvidence: peers, live: live,
                proposals: nominees, accepts: accepts)
            var outcomes: [String: [String: Any]] = [:]
            for r in assessed.records { if let key = r["key"] as? String { outcomes[key] = r } }
            let ordered: [SourceBoundary400Policy.NativeOffer] = nominees.compactMap { candidate in
                guard let raw = rawByKey[candidate.key], let outcome = outcomes[candidate.key] else { return nil }
                return .init(rawOffer: raw, nativeAdmissionPassed: outcome["admitted"] as? Bool == true,
                    sourceHardRejections: raw["hardRejections"] as? [String] ?? ["missing-source-receipt"],
                    originalRecord: outcome)
            }
            guard let choice = SourceBoundary400Policy.choose(nativeOrdered: ordered,
                actualPrior: prior.polygon, nativeW: Double(m.rect.width), factoryReceipt: generated.receipt,
                sourcePrefix: prefix, sourceScore: m.score, policy: .frozenCandidateV1),
                let key = choice.offer.rawOffer["key"] as? String,
                let candidate = nominees.first(where: { $0.key == key }) else { continue }
            changes[index] = candidate.polygon
            applied[index] = candidate
            records.append(["family": "source-runtime403", "sourceIndex": index,
                "selectedKey": key, "polygon": candidate.polygon.map { [Double($0.x), Double($0.y)] },
                "actualPreviousPrior": prior.polygon.map { [Double($0.x), Double($0.y)] },
                "actualNativeAdmission": choice.offer.originalRecord,
                "sourceFeatures": Dictionary(uniqueKeysWithValues: choice.features.values.map { ($0.key.rawValue, $0.value) }),
                "sourceOnlySelection": true, "nativeAdmissionPassed": true,
                "outputOrGraphMutated": true, "ownershipChanged": false,
                "consumedIndices": prior.consumedIndices,
                "associationKey": prior.inheritedAssociationKey as Any? ?? NSNull()])
        }
        return .init(polygons: changes, applied: applied, measurements: measurements, records: records)
    }
}
