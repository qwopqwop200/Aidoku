import Foundation
import CoreGraphics

/// Source-session performance adapter ONLY. Sequential use, one generateFromLive root.
/// No peer bodies, identity lookup, JSON fixtures, foreground invention or guard changes.
@available(iOS 18.0, *)
final class NativeOCRLocalJointGGCache387 {
    typealias Body = NativeOCRSourceAuthenticatedBodyEvidence
    typealias GG = NativeOCRAlignedGradientTerminalGuard
    typealias Algorithm = NativeOCRAlignedGradientTerminalPrepared373
    struct Statistics {
        let totalSourcePixels: Int // saturated at configured cap+1
        let preparedMembers: Int
        let warmMaskMismatches: Int
        let sourcePreparations: Int
        let estimatedCachedRayBytes: Int
        let rayHits: Int
        let staticCalls: Int
        let rayBudgetFallbackMembers: Int
    }
    private let bodies: [Body.Evidence]
    private let budgets: [Int]
    private var prepared: [Algorithm.Prepared?]
    private var attempted: [Bool]
    private let totalPixels: Int
    private let enabled: Bool
    private var warmMismatches = 0, staticCalls = 0, rayBudgetFallbackMembers = 0

    /// Pass ONLY live.bodies (actual root+residual children), NEVER live.peerBodies.
    /// These are existing immutable typed native observations with original full footprints.
    init(bodies: [Body.Evidence], enabled: Bool = true,
         maximumSourcePixels: Int = 1_200_000, maximumRayBytes: Int = 32*1024*1024) {
        self.bodies = bodies
        // Controls may only REDUCE the hard root budgets; tests exercise zero budget.
        let cap = max(0, min(1_200_000, maximumSourcePixels))
        let rays = max(0, min(32*1024*1024, maximumRayBytes))
        var total = 0
        for body in bodies {
            let r = body.sourceLocalRGBA
            guard r.width > 0, r.height > 0, r.width <= cap / r.height,
                  total <= cap-r.width*r.height else { total=cap+1; break }
            total += r.width*r.height
        }
        totalPixels = total
        self.enabled = enabled && rays > 0 && !bodies.isEmpty && total <= cap
        let count = max(1, bodies.count)
        budgets = bodies.indices.map { rays/count + ($0 < rays%count ? 1:0) }
        prepared = Array(repeating: nil, count: bodies.count)
        attempted = Array(repeating: false, count: bodies.count)
    }
    func terminalObservation(memberOrdinal: Int, proposed: [CGPoint], includeMasks: Bool = false) -> GG.Result? {
        guard bodies.indices.contains(memberOrdinal) else { return nil }
        let body = bodies[memberOrdinal]
        // Exact existing Body.terminalObservation validation, copied unchanged.
        // Invalid queries use the original API, preserving nil vs guard-result behavior.
        guard enabled, Self.validQuad(proposed), proposed.allSatisfy({
            $0.x >= 0 && $0.y >= 0 &&
            $0.x <= CGFloat(body.source.window.frameSize.width) &&
            $0.y <= CGFloat(body.source.window.frameSize.height)
        }) else {
            staticCalls += 1
            return body.terminalObservation(proposed: proposed, includeMasks: includeMasks)
        }
        if !attempted[memberOrdinal] {
            attempted[memberOrdinal] = true
            let p=body.prepared, rgba=body.sourceLocalRGBA, footprint=p.actualFullFootprint
            let candidate=Algorithm.Prepared(old:p.inherited,rgba:rgba,
                authenticatedPalettes:p.actualPalettes,frameOrigin:p.sourceOrigin,
                normal:p.normal,along:p.along,sourceWidth:p.sourceWidth,
                maximumCachedPayloadBytes:budgets[memberOrdinal],
                isPrivatePixel:{x,y in footprint.contains(.init(x:x,y:y))})
            // Compare to the AUTHENTIC old==old Body.observe seed already computed.
            // Never replace the seed mask or reinterpret it as private ownership.
            let warm=candidate.assess(new:p.inherited,includeMasks:true)
            if warm.decision == "no-qualified-terminal-loss-observed" && warm.witnesses.isEmpty &&
                warm.bodyMask == body.sourceAuthenticatedContrastBodyMask &&
                warm.authenticatedBodies == body.nativeBodyCountAcrossPairs &&
                warm.examinedPairs == body.nativeExaminedPalettePairs &&
                warm.bodyMask?.filter({$0 != 0}).count == body.uniqueMaskPixels &&
                warm.noVetoIsNotAdmission && !warm.ownershipMutated {
                if candidate.statistics.uncachedRayBuildsDueToBudget == 0 {
                    prepared[memberOrdinal]=candidate
                } else {
                    rayBudgetFallbackMembers += 1 // Drop session, EXACT static path henceforth.
                }
            } else {
                // Performance fallback ONLY. Keep unchanged original decision path.
                warmMismatches += 1
            }
        }
        if let cache=prepared[memberOrdinal] {
            let result=cache.assess(new:proposed,includeMasks:includeMasks)
            if cache.statistics.uncachedRayBuildsDueToBudget == 0 { return result }
            // First new palette-pair budget miss: discard this member cache and
            // recompute THIS query with the original API, then remain static.
            prepared[memberOrdinal]=nil
            rayBudgetFallbackMembers += 1
        }
        staticCalls += 1
        return body.terminalObservation(proposed:proposed,includeMasks:includeMasks)
    }
    var statistics: Statistics {
        let values=prepared.compactMap {$0?.statistics}
        return .init(totalSourcePixels:totalPixels,preparedMembers:values.count,warmMaskMismatches:warmMismatches,
            sourcePreparations:values.map(\.sourcePreparations).reduce(0,+),
            estimatedCachedRayBytes:values.map(\.estimatedCachedPayloadBytes).reduce(0,+),
            rayHits:values.map(\.rayCacheHits).reduce(0,+),staticCalls:staticCalls,
            rayBudgetFallbackMembers:rayBudgetFallbackMembers)
    }
    // Byte-exact native Body.validQuad algorithm; access is private in native Body.
    private static func validQuad(_ q: [CGPoint]) -> Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return false}
        var area:CGFloat=0,turns:[CGFloat]=[]
        for i in 0..<4 {let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4];area+=a.x*b.y-b.x*a.y
            turns.append((b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x))}
        return abs(area)>1e-7 && (turns.allSatisfy{$0>0} || turns.allSatisfy{$0<0})
    }
}
