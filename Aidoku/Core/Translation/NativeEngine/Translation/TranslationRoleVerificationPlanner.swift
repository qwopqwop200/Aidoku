import Foundation

/// A bounded second look at filtered lettering, never an output-role override.
/// Invoke once after the primary provider call, below any cache/canonical-ID mapping.
/// Execute candidates through the lower-level transport, not `translate` again.
enum TranslationRoleVerificationPlanner {
    static let maximumCandidates = 4
    static let version = "source-bound-focused-role-verification-v262"

    /// Keep the exact sent request with the response: an ID alone cannot bind a
    /// verification to current source text, image, geometry or translation context.
    struct Verification: Sendable {
        let request: RemoteTranslationRequest
        let result: RemoteTranslationBatchResult
    }

    static func candidates(
        request: RemoteTranslationRequest,
        result: RemoteTranslationBatchResult
    ) -> [RemoteTranslationRequest] {
        // An already isolated request offers no new focus; this also makes
        // accidental planning of a verification request terminate immediately.
        guard request.segments.count > 1, request.filtersSFX == true,
              request.filtersBackground == true, request.imageJPEG != nil,
              let identity = request.roleEvidenceSourceImageIdentity,
              (try? request.validate()) != nil,
              let outcomes = indexed(result, matching: request.segments.map(\.id)) else { return [] }

        var focused: [RemoteTranslationRequest] = []
        for segment in request.segments {
            guard focused.count < maximumCandidates else { break }
            guard let outcome = outcomes[segment.id], isFiltered(outcome),
                  outcome.text == segment.text,
                  let evidence = boundEvidence(segment, identity: identity),
                  !hasEffectSupport(evidence) else { continue }

            // Agreement is a reason to inspect, not proof of speech. A partial
            // native contour can instead be supported by an independently bound
            // admitted neighbor sharing this same RF owner and enclosing bounds.
            let geometricConflict = evidence.sourceContourAndRFMaskAgree
            let admittedPeers = request.segments.filter { neighbor in
                guard neighbor.id != segment.id,
                      let peerOutcome = outcomes[neighbor.id], isAdmitted(peerOutcome),
                      boundEvidence(neighbor, identity: identity) != nil else { return false }
                return true
            }
            let neighbors = admittedPeers.filter { neighbor in
                guard let peer = boundEvidence(neighbor, identity: identity),
                      peer.sourceContourAndRFMaskAgree,
                      let owner = evidence.rfMaskOwnerQuery, owner == peer.rfMaskOwnerQuery,
                      let container = evidence.rfBalloonBounds,
                      container == peer.rfBalloonBounds,
                      let bounds = segment.bounds, let peerBounds = neighbor.bounds else { return false }
                return contains(container, bounds) && contains(container, peerBounds)
            }
            let neighborConflict = evidence.contourVerified == true && evidence.contourModelEstimated == false &&
                (evidence.contourBBoxCoverage ?? 0) >= 0.5 && !neighbors.isEmpty
            // Unboxed utterances have no contour or RF balloon owner. Strong
            // text support on both sources plus substantial bbox overlap with
            // an admitted source warrants inspecting this ID independently.
            // RF text is not speech truth; do not infer a shared detector owner
            // from equal scores or copy the admitted neighbor's words/role.
            let overlappingPeers = admittedPeers.filter { neighbor in
                guard hasTextSupport(evidence),
                      let peer = boundEvidence(neighbor, identity: identity), hasTextSupport(peer),
                      !hasEffectSupport(peer),
                      let bounds = segment.bounds, let peerBounds = neighbor.bounds else { return false }
                return overlapFraction(bounds, peerBounds) >= 0.5
            }
            guard geometricConflict || neighborConflict || !overlappingPeers.isEmpty else { continue }

            // RF/neighbor evidence is local nomination data. Do not leak it into
            // the provider's context on the focused visual request.
            var isolated = RemoteTranslationRequest(sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage, segments: [segment])
            isolated.copyImageRepresentation(from: request)
            isolated.filtersSFX = request.filtersSFX
            isolated.filtersBackground = request.filtersBackground
            isolated.translatesPageLettering = request.translatesPageLettering
            guard (try? isolated.validate()) != nil else { continue }
            // Keep full-page coordinates/image identity. Existing detail-image
            // generation now spends its bounded crop budget on this ID alone.
            focused.append(isolated)
        }
        return focused
    }

    /// Independently accept only well-formed, explicitly admitted provider
    /// outcomes from the exact planned request. Failed/unresolved checks leave
    /// the primary outcome intact; siblings and known effects cannot be changed.
    static func merging(
        request: RemoteTranslationRequest,
        original: RemoteTranslationBatchResult,
        verifications: [Verification]
    ) -> RemoteTranslationBatchResult {
        guard !verifications.isEmpty, verifications.count <= maximumCandidates else { return original }
        let planned = candidates(request: request, result: original)
        let counts = verifications.reduce(into: [String: Int]()) { counts, verification in
            if verification.request.segments.count == 1 {
                counts[verification.request.segments[0].id, default: 0] += 1
            }
        }
        var replacements: [String: RemoteTranslatedSegment] = [:]
        for verification in verifications {
            guard let expected = planned.first(where: { $0 == verification.request }),
                  let source = expected.segments.first, counts[source.id] == 1,
                  verification.result.source == .network,
                  let indexed = indexed(verification.result, matching: [source.id]),
                  let translated = indexed[source.id], isAdmitted(translated),
                  !translated.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  translated.text.utf8.count <= RemoteTranslationConfiguration.maximumResponseBytesLimit,
                  translated.text.trimmingCharacters(in: .whitespacesAndNewlines) !=
                    source.text.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            replacements[source.id] = translated
        }
        guard !replacements.isEmpty else { return original }
        return RemoteTranslationBatchResult(
            translations: original.translations.map { replacements[$0.id] ?? $0 },
            source: .network,
            // Multiple real calls compose this batch; no single request ID
            // represents it. The caller can log each Verification's receipt.
            providerRequestID: nil)
    }

    private static func indexed(
        _ result: RemoteTranslationBatchResult, matching ids: [String]
    ) -> [String: RemoteTranslatedSegment]? {
        guard result.translations.count == ids.count, Set(ids).count == ids.count else { return nil }
        var indexed: [String: RemoteTranslatedSegment] = [:]
        let allowed = Set(ids)
        for segment in result.translations {
            guard allowed.contains(segment.id), indexed.updateValue(segment, forKey: segment.id) == nil else { return nil }
        }
        return indexed
    }

    private static func isFiltered(_ result: RemoteTranslatedSegment) -> Bool {
        (result.textRole == .background && result.isSFX == false) ||
            (result.textRole == .sfx && result.isSFX == true) ||
            (result.textRole == .error && result.isSFX == false)
    }

    private static func isAdmitted(_ result: RemoteTranslatedSegment) -> Bool {
        guard result.isSFX == false else { return false }
        switch result.textRole {
        case .dialogue, .narration, .storyText: return true
        default: return false
        }
    }

    private static func boundEvidence(
        _ segment: RemoteTranslationSegment, identity: String
    ) -> NativeTranslationRoleEvidence? {
        guard let bounds = segment.bounds, let evidence = segment.roleEvidence,
              evidence.isBound(source: segment.text, bounds: bounds, imageIdentity: identity) else { return nil }
        return evidence
    }

    private static func hasEffectSupport(_ evidence: NativeTranslationRoleEvidence) -> Bool {
        // A native outline can be a false contour on actual effect lettering.
        // Never use neighboring speech or an outline to undo positive RF SFX.
        (evidence.rfSFXConfidence ?? 0) >= 0.5 && (evidence.rfSFXBBoxCoverage ?? 0) > 0
    }

    private static func hasTextSupport(_ evidence: NativeTranslationRoleEvidence) -> Bool {
        (evidence.rfTextConfidence ?? 0) >= 0.8 && (evidence.rfTextBBoxCoverage ?? 0) >= 0.9
    }

    private static func overlapFraction(_ bounds: [Double], _ peer: [Double]) -> Double {
        let width = max(0, min(bounds[0] + bounds[2], peer[0] + peer[2]) - max(bounds[0], peer[0]))
        let height = max(0, min(bounds[1] + bounds[3], peer[1] + peer[3]) - max(bounds[1], peer[1]))
        return min(1, width * height / (bounds[2] * bounds[3]))
    }

    private static func contains(_ container: [Double], _ bounds: [Double]) -> Bool {
        // Both arrays already passed Evidence.isBound's finite geometry checks.
        container[0] <= bounds[0] && container[1] <= bounds[1] &&
            container[0] + container[2] >= bounds[0] + bounds[2] &&
            container[1] + container[3] >= bounds[1] + bounds[3]
    }
}
