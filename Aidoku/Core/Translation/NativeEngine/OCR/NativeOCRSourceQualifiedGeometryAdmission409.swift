import Foundation
import CoreGraphics
import CryptoKit

/// Retypes ONLY caller-attested derived endpoint geometry AFTER the original
/// PointCapture401 has obtained actual source pixel proofs. Actual observed marks
/// stay explicitly protected. Native392 performs the unchanged real admission.
@available(iOS 18.0, *)
enum NativeOCRSourceQualifiedGeometryAdmission409 {
    typealias F = NativeOCRSourceLocalJoint369
    typealias P = NativeOCRPointObligation401
    static func assess(prior: NativeOCRCurrentPrior351.Resolution,
        graph: NativeOCRSourceLocalJoint369Capture.FinalGraph,
        measurement: F.M, frame: NativeOCRRGBAFrame, peerEvidence: F.PeerEvidence,
        live: F.LiveObservation, proposals: [NativeOCRResidualCandidate],
        derivedEndpointGeometryForSource: (F.M) -> [CGPoint]?,
        explicitObservedMarksForSource: ((F.M) -> [CGPoint]?)? = nil,
        originalOwnedSupport: (Int) -> [CGPoint],
        accepts: (Int, [CGPoint]) -> Bool) -> NativeOCRSourceLiveAdmission392.Output {
        func unavailable(_ reason: String) -> NativeOCRSourceLiveAdmission392.Output {
            .init(candidates: [], records: proposals.map {
                ["key": $0.key, "polygon": $0.polygon.map { [Double($0.x), Double($0.y)] },
                    "admitted": false, "hardRejections": [String](), "softRejections": [reason],
                    "pointPolicy": "typed409", "ownershipOrGraphChanged": false,
                    "automaticSelection": false, "sourceEvidenceFabricated": false]
            })
        }
        guard proposals.count <= 128, live.sources.count == live.bodies.count,
              live.sources.map(\.index) == [measurement.index] + prior.consumedIndices,
              !live.sources.isEmpty, graph.prior(measurement.index)?.polygon == prior.polygon else {
            return unavailable("typed409-actual-live-member-order-unavailable")
        }
        let r = live.rgba
        let sourceIdentity = digest(frame.bytes)
        let rgbaHash = digest(r.bytes)
        var sessions: [Int: P.SourceSession] = [:], members: [P.MemberPoints] = []
        do {
            for ordinal in live.sources.indices {
                let m = live.sources[ordinal], body = live.bodies[ordinal], fp = body.actualFullFootprint
                guard let original = m.privateObservation?.footprint,
                      m.privateObservation?.missingPrivateRGBPixels == 0,
                      fp.width == original.width, fp.height == original.height,
                      fp.scaleX == original.scaleX, fp.scaleY == original.scaleY,
                      fp.cells == original.cells, !fp.cells.isEmpty,
                      body.prepared.inherited == prior.polygon,
                      body.sourceLocalRGBA.bytes == r.bytes,
                      body.sourceLocalRGBA.origin == r.origin,
                      body.sourceLocalRGBA.width == r.width, body.sourceLocalRGBA.height == r.height,
                      body.sourceAuthenticatedContrastBodyMask.count == r.width * r.height,
                      let caps = derivedEndpointGeometryForSource(m) else {
                    return unavailable("typed409-real-footprint-GG-or-derived-endpoint-callback-unavailable")
                }
                let marks: [CGPoint]
                if let provider = explicitObservedMarksForSource {
                    guard let observedMarks = provider(m) else {
                        return unavailable("typed409-explicit-observed-mark-callback-unavailable")
                    }
                    marks = observedMarks
                } else {
                    // No new explicit semantic provider was supplied. This does
                    // not claim that unobserved marks/foreground are absent.
                    marks = []
                }
                let bodyMask = body.sourceAuthenticatedContrastBodyMask
                let binding = P.Binding(actualOld: prior.polygon, sourceOrdinal: ordinal,
                    sourceSHA256: sourceIdentity, rgbaSHA256: rgbaHash,
                    rootGGBodySHA256: digest(bodyMask), nativeFullFootprintSHA256: footprintHash(fp),
                    actualNativeFullFootprintVerified: true)
                let evidence = P.Evidence(rgba: .init(bytes: r.bytes, width: r.width, height: r.height,
                    stride: r.bytesPerRow, origin: r.origin), rootGGBody: bodyMask,
                    nativeContains: { fp.contains($0) }, nativeW: m.rect.width,
                    normal: m.normal, along: m.along)
                sessions[ordinal] = try P.SourceSession(binding: binding, evidence: evidence)
                let centers = fp.cells.sorted().map { cell in
                    CGPoint(x: (CGFloat(cell % fp.width) + 0.5) * fp.scaleX,
                        y: (CGFloat(cell / fp.width) + 0.5) * fp.scaleY)
                }
                members.append(.init(sourceOrdinal: ordinal, actualExplicitCaps: caps,
                    originalOwnedSupport: originalOwnedSupport(m.index), measurementGuardPoints: m.guardPoints,
                    restoredPrivateHull: m.privateHull.map(m.restore), nativeCellCenters: centers,
                    explicitlyProtectedMarks: marks))
            }
            let inherited = prior.candidate?.supportPoints ?? []
            let observed = try captureDerivedEndpoints(actualOld: prior.polygon, members: members,
                priorConstructorUntypedSupport: inherited, sessions: sessions)
            guard sessions.values.allSatisfy({ !$0.budgetExhausted }), observed.explicitCapsComplete else {
                return unavailable("typed409-positive-source-qualification-budget-or-caps-incomplete")
            }
            let protected = observed.points.filter(\.mustPreserve).map { $0.point.position }
            let qualifiedLive = F.LiveObservation(window: live.window, rgba: live.rgba,
                sources: live.sources, bodies: live.bodies, mandatory: protected,
                peerBodies: live.peerBodies, scopes: live.scopes)
            // The inherited support list has now been inspected with typed source
            // provenance. Preserve any genuinely additional producer support.
            let qualifiedProposals = proposals.map { candidate in
                let extra = candidate.supportPoints == inherited ? [] : candidate.supportPoints.filter { !inherited.contains($0) }
                return NativeOCRResidualCandidate(key: candidate.key, polygon: candidate.polygon,
                    consumedIndices: candidate.consumedIndices, supportPoints: extra,
                    associationKey: candidate.associationKey)
            }
            let native = NativeOCRSourceLiveAdmission392.assess(prior: prior, graph: graph,
                measurement: measurement, frame: frame, peerEvidence: peerEvidence,
                live: qualifiedLive, proposals: qualifiedProposals, accepts: accepts)
            var counts: [String: Int] = [:]
            for point in observed.points { counts[point.qualification.rawValue, default: 0] += 1 }
            let stats: [[String: Any]] = sessions.keys.sorted().map { ordinal in
                ["sourceOrdinal": ordinal, "summary": sessions[ordinal]!.summary()]
            }
            let records = native.records.map { original -> [String: Any] in
                var record = original
                record["pointPolicy"] = "typed409"
                record["actualDerivedEndpointGeometryCount"] = members.reduce(0) { $0 + ($1.actualExplicitCaps?.count ?? 0) }
                record["actualExplicitObservedMarkCount"] = members.reduce(0) { $0 + $1.explicitlyProtectedMarks.count }
                record["explicitObservedMarkProviderSupplied"] = explicitObservedMarksForSource != nil
                record["derivedEndpointGeometryRequiresActualPositivePixelProof"] = true
                record["observedMarksRemainExplicitProtection"] = true
                record["pointCaptureAndSourceSessionBudgetsUnchanged"] = true
                record["derivedGeometryDeferralIsBackgroundOrErasureAuthority"] = false
                record["pointQualificationCounts"] = counts
                record["qualifiedProtectedPointCount"] = protected.count
                record["pointSourceSessions"] = stats
                record["sourceIdentityRepresentation"] = "actual-full-native-RGBA-byte-stream"
                record["actualSourceRGBA_SHA256"] = sourceIdentity
                record["allOriginalNativePixelSemanticPeerForeignChecksPreserved"] = true
                record["unknownDetectorGeometryPromotedToForeground"] = false
                if let q = SourceBoundary400Policy.points(record["polygon"]) {
                    let lost = observed.points.filter { !P.contains(q, $0.point.position) }
                    record["legacyUntypedPointGateWouldReject"] = !lost.isEmpty
                    record["lostQualifiedProtectedPointCount"] = lost.filter(\.mustPreserve).count
                    record["deferredGeometryLostCount"] = lost.filter { !$0.mustPreserve }.count
                    record["protectedLossWitnesses"] = lost.filter(\.mustPreserve).prefix(4).map { $0.receipt() }
                    record["deferredGeometryWitnesses"] = lost.filter { !$0.mustPreserve }.prefix(4).map { $0.receipt() }
                }
                return record
            }
            return .init(candidates: native.candidates, records: records, performance: native.performance)
        } catch {
            return unavailable("typed409-unavailable-actual-point-evidence: " + String(describing: error))
        }
    }
    /// members.actualExplicitCaps must contain ONLY the exact output of the
    /// derivedEndpointGeometryForSource callback. Actual semantic marks belong
    /// in members.explicitlyProtectedMarks, even at the same coordinate.
    static func captureDerivedEndpoints(actualOld: [CGPoint], members: [P.MemberPoints],
        priorConstructorUntypedSupport: [CGPoint], sessions: [Int: P.SourceSession]) throws -> P.Observation {
        let captured = try P.capture(actualOld: actualOld, members: members,
            priorConstructorUntypedSupport: priorConstructorUntypedSupport, sessions: sessions)
        let qualified = captured.points.map { old -> P.Classified in
            guard old.point.role == .explicitEndpointCap else { return old }
            let point = P.Point(ordinal: old.point.ordinal, sourceOrdinal: old.point.sourceOrdinal,
                position: old.point.position, role: .derivedEndpointGeometry,
                provenance: "derivedEndpointGeometryForSource(actualMeasurement); captured-by-" + old.point.provenance)
            let qualification: P.Qualification
            if old.pixel.positive { qualification = .measuredClosedForeground }
            else if old.pixel.receipt["sourcePixelObserved"] as? Bool == true {
                qualification = .detectionGeometryUnqualified
            } else { qualification = .unresolvedSourceEvidence }
            // Reuse the EXACT existing pixel proof. No re-probe, fabricated
            // empty mask, altered RGB, owner reassignment or blanket cap drop.
            return P.Classified(point: point, qualification: qualification,
                mustPreserve: old.pixel.positive, pixel: old.pixel)
        }
        return P.Observation(actualOld: captured.actualOld, points: qualified,
            explicitCapsComplete: captured.explicitCapsComplete)
    }

    private static func digest(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
    private static func footprintHash(_ fp: NativeOCRDensePrivateFootprintGuard.Footprint) -> String {
        var bytes = Data()
        func append(_ value: UInt64) {
            var word = value.littleEndian
            withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) }
        }
        append(UInt64(fp.width)); append(UInt64(fp.height))
        append(Double(fp.scaleX).bitPattern); append(Double(fp.scaleY).bitPattern)
        for cell in fp.cells.sorted() { append(UInt64(cell)) }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
