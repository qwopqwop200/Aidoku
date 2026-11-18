import Foundation
import CoreGraphics

/// Opt-in read-only transport. No Host symbol, file IO, model/GT lookup or native
/// permission is defined here. All source objects are the actual immutable session.
@available(iOS 18.0, *)
enum NativeOCRSourceAdmissionWitness436 {
    typealias F = NativeOCRSourceLocalJoint369
    typealias K = NativeOCRSharedBoundary396
    final class SourceBox: @unchecked Sendable {
        // Filled synchronously during this root's actual source factory only.
        var evidence: K.Evidence?
        var basis: K.Basis?
        var roles405: SourceFillRimRole405.Output?
    }
    final class PointsBox: @unchecked Sendable {
        // Filled synchronously AFTER the actual native result has been computed.
        var observation: NativeOCRPointObligation401.Observation?
    }
    final class Packet: @unchecked Sendable {
        let prior: NativeOCRCurrentPrior351.Resolution
        let graph: NativeOCRSourceLocalJoint369Capture.FinalGraph
        let measurement: F.M
        let live: F.LiveObservation
        let frame: NativeOCRRGBAFrame
        let originals: [NativeCoreMLDetectionBox]
        let prepared: [NativeCoreMLDetectionBox]
        let groups: [Int: [Int]]
        let rfScopes: [NativeOCRSourceComponentMeasurements.Scope]
        let proposals: [NativeOCRResidualCandidate]
        let candidateRecords: [[String: Any]]
        let points: NativeOCRPointObligation401.Observation?
        let source: SourceBox?
        init(prior: NativeOCRCurrentPrior351.Resolution,
            graph: NativeOCRSourceLocalJoint369Capture.FinalGraph, measurement: F.M,
            live: F.LiveObservation, frame: NativeOCRRGBAFrame,
            originals: [NativeCoreMLDetectionBox], prepared: [NativeCoreMLDetectionBox],
            groups: [Int: [Int]], rfScopes: [NativeOCRSourceComponentMeasurements.Scope],
            proposals: [NativeOCRResidualCandidate], candidateRecords: [[String: Any]],
            points: NativeOCRPointObligation401.Observation?, source: SourceBox?) {
            self.prior=prior;self.graph=graph;self.measurement=measurement;self.live=live;self.frame=frame
            self.originals=originals;self.prepared=prepared;self.groups=groups;self.rfScopes=rfScopes
            self.proposals=proposals;self.candidateRecords=candidateRecords;self.points=points;self.source=source
        }
    }
    // Synchronous diagnostic scopes only. HostDirectionAudit never suspends
    // within these operations. No TaskLocal runtime metadata push is involved.
    typealias Sink = @Sendable (Packet) -> [String: Any]
    typealias PointObserver = @Sendable (NativeOCRPointObligation401.Observation) -> Void
    private final class SinkSlot: NSObject {
        let callback: Sink
        init(_ callback: @escaping Sink) {self.callback=callback;super.init()}
    }
    private final class PointsSlot: NSObject {
        let callback: PointObserver
        init(_ callback: @escaping PointObserver) {self.callback=callback;super.init()}
    }
    private static let sinkKey = "org.aidoku.source-witness436.synchronous-sink"
    private static let pointsKey = "org.aidoku.source-witness436.synchronous-points"
    static var sink: Sink? { (Thread.current.threadDictionary[sinkKey] as? SinkSlot)?.callback }
    static var pointObserver: PointObserver? { (Thread.current.threadDictionary[pointsKey] as? PointsSlot)?.callback }
    // Diagnostic identity only, used to verify nested scoped restoration. It
    // never controls source classification, native admission or root selection.
    static var sinkScopeIdentity: ObjectIdentifier? {
        (Thread.current.threadDictionary[sinkKey] as? SinkSlot).map {ObjectIdentifier($0)}
    }
    static var pointScopeIdentity: ObjectIdentifier? {
        (Thread.current.threadDictionary[pointsKey] as? PointsSlot).map {ObjectIdentifier($0)}
    }
    static func withSink<Result>(_ callback: @escaping Sink,
        operation: () throws -> Result) rethrows -> Result {
        let dictionary=Thread.current.threadDictionary,previous=dictionary[sinkKey]
        dictionary[sinkKey]=SinkSlot(callback)
        defer {
            if let previous {dictionary[sinkKey]=previous}
            else {dictionary.removeObject(forKey:sinkKey)}
        }
        return try operation()
    }
    static func withPointObserver<Result>(_ callback: @escaping PointObserver,
        operation: () throws -> Result) rethrows -> Result {
        let dictionary=Thread.current.threadDictionary,previous=dictionary[pointsKey]
        dictionary[pointsKey]=PointsSlot(callback)
        defer {
            if let previous {dictionary[pointsKey]=previous}
            else {dictionary.removeObject(forKey:pointsKey)}
        }
        return try operation()
    }
    static func wants(_ record: [String: Any]) -> Bool {
        guard record["nativeAdmissionPassed"] as? Bool != true,
              record["nativeAssessmentRun"] as? Bool == true else { return false }
        let reasons: Set<String> = ["lost-actual-cap-guard-or-explicit-support", "actual-terminal-loss",
            "whole-source-reject", "dense-source-reject", "acquired-actual-external-owner-cells",
            "acquired-peer-authenticated-contrast-body", "acquired-original-contrast-in-actual-peer-region",
            "whole-source-uncertain", "dense-source-uncertain", "terminal-observation-unavailable",
            "relevant-peer-local-physical-evidence-unavailable"]
        return (record["nativeOutcome"] as? [[String: Any]] ?? []).contains { outcome in
            let found=(outcome["hardRejections"] as? [String] ?? [])+(outcome["softRejections"] as? [String] ?? [])
            return !reasons.isDisjoint(with: found) || (outcome["lostQualifiedProtectedPointCount"] as? Int ?? 0)>0
        }
    }
}
