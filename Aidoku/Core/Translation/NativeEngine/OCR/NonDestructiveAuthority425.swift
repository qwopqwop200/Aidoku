import Foundation
import CoreGraphics

/// Narrow OCR-crop authority rule. No erasure, owner/mask mutation or assertion
/// that unobserved/empty evidence means background. All facts are actual events.
@available(iOS 18.0, *)
enum NonDestructiveAuthority425 {
    typealias F=NativeOCRSourceLocalJoint369
    struct PeerFact {
        let coherentRegionContrast: Bool
        let authenticBodyBound: Bool
        let observedAcquiredBodyPixels: Int?
    }
    struct MemberLossFact {
        let sourceOrdinal: Int
        let whole: String
        let dense: String
        let terminal: String?
        let terminalWitnessesEmpty: Bool
    }
    struct Facts {
        let actualOld: [CGPoint]
        let proposed: [CGPoint]
        let graphAndMergeRelationsFixed: Bool
        let actualFrameAndSourceScopeBound: Bool
        let lostProtectedPoints: Int?
        let actualForeignAcquisitions: Int?
        let actualUncertainAcquisitions: Int?
        let expandedPeers: [PeerFact]
        let expectedMembers: Int
        let memberLossChecks: [MemberLossFact]
        let hardRejections: [String]
        let softRejections: [String]
    }
    static let coherentOnlyReason="acquired-original-contrast-in-actual-peer-region"
    static func mayDefer(_ facts:Facts,requireExecutedLossChecks:Bool=true)->Bool {
        guard F.valid(facts.actualOld),F.valid(facts.proposed),
              facts.actualOld.allSatisfy({F.contains(facts.proposed,$0)}),
              facts.graphAndMergeRelationsFixed,facts.actualFrameAndSourceScopeBound,
              facts.lostProtectedPoints == 0,facts.actualForeignAcquisitions == 0,
              facts.actualUncertainAcquisitions == 0,facts.hardRejections.isEmpty,
              !facts.softRejections.isEmpty,
              facts.softRejections.allSatisfy({$0 == coherentOnlyReason}),
              !facts.expandedPeers.isEmpty,
              facts.expandedPeers.contains(where:{$0.coherentRegionContrast}),
              facts.expandedPeers.allSatisfy({$0.authenticBodyBound && $0.observedAcquiredBodyPixels == 0}),
              facts.expectedMembers > 0,facts.expectedMembers <= 64 else {return false}
        if !requireExecutedLossChecks {return true} // nomination to RUN the unchanged checks, never an admission
        guard facts.memberLossChecks.count == facts.expectedMembers,
              Set(facts.memberLossChecks.map(\.sourceOrdinal)) == Set(0..<facts.expectedMembers),
              facts.memberLossChecks.allSatisfy({
                  $0.whole == "no-entire-closed-component-loss-observed" &&
                  $0.dense == "no-substantial-source-relative-loss-observed" &&
                  $0.terminal == "no-qualified-terminal-loss-observed" && $0.terminalWitnessesEmpty
              }) else {return false}
        return true
    }
    static func peerFact(peer:F.Peer,body:NativeOCRSourceAuthenticatedBodyEvidence.Evidence?,
                         rgba:F.RGBA,old:[CGPoint],proposed:[CGPoint],coherent:Bool)->PeerFact {
        func missing()->PeerFact {
            .init(coherentRegionContrast:coherent,authenticBodyBound:false,observedAcquiredBodyPixels:nil)
        }
        guard !peer.missingLocalEvidence,let m=peer.measurement,let body,let retained=m.privateObservation,
              let original=retained.footprint,retained.missingPrivateRGBPixels == 0,
              !original.cells.isEmpty,m.status == "measured",m.index == peer.sourceIndex,
              body.sourceLocalRGBA.bytes == rgba.bytes,
              body.sourceLocalRGBA.bytesPerRow == rgba.bytesPerRow,
              body.sourceLocalRGBA.origin == rgba.origin,
              body.sourceLocalRGBA.width == rgba.width,body.sourceLocalRGBA.height == rgba.height,
              body.sourceAuthenticatedContrastBodyMask.count == rgba.width*rgba.height,
              body.prepared.sourceOrigin == m.origin,body.prepared.normal == m.normal,
              body.prepared.along == m.along,body.prepared.sourceWidth == Double(m.rect.width),
              body.actualFullFootprint.width == original.width,body.actualFullFootprint.height == original.height,
              body.actualFullFootprint.scaleX == original.scaleX,body.actualFullFootprint.scaleY == original.scaleY,
              body.actualFullFootprint.cells == original.cells else {return missing()}
        var acquired=0
        for i in body.sourceAuthenticatedContrastBodyMask.indices where body.sourceAuthenticatedContrastBodyMask[i] != 0 {
            let p=CGPoint(x:rgba.origin.x+CGFloat(i%rgba.width)+0.5,
                          y:rgba.origin.y+CGFloat(i/rgba.width)+0.5)
            if F.contains(proposed,p) && !F.contains(old,p) {acquired += 1}
        }
        // Zero is an observed acquisition count, not proof of background,
        // complete glyph inventory, harmless foreign ink or erasure authority.
        return .init(coherentRegionContrast:coherent,authenticBodyBound:true,observedAcquiredBodyPixels:acquired)
    }
    static func receipt(_ facts:Facts,deferred:Bool)->[String:Any] {
        ["policy":"non-destructive-OCR-crop-coherent-only425","coherentOnlyVetoDeferred":deferred,
         "actualOldFullyEnclosed":F.valid(facts.proposed) && facts.actualOld.allSatisfy{F.contains(facts.proposed,$0)},
         "actualGraphAndMergeRelationsFixed":facts.graphAndMergeRelationsFixed,
         "actualFrameAndSourceScopeBound":facts.actualFrameAndSourceScopeBound,
         "lostProtectedPoints":facts.lostProtectedPoints as Any? ?? NSNull(),
         "actualForeignAcquisitions":facts.actualForeignAcquisitions as Any? ?? NSNull(),
         "actualUncertainAcquisitions":facts.actualUncertainAcquisitions as Any? ?? NSNull(),
         "expandedPeerObservations":facts.expandedPeers.map{[
             "coherentPeerRegionContrast":$0.coherentRegionContrast,
             "authenticActualPeerBodyBound":$0.authenticBodyBound,
             "observedAcquiredPeerBodyPixels":$0.observedAcquiredBodyPixels as Any? ?? NSNull()] as [String:Any]},
         "executedNativeMemberLossChecks":facts.memberLossChecks.count,
         "scope":"recognition-crop-only-with-fixed-merge-relations",
         "coherentColourOverPeerQuadIsProofOfForeignBody":false,
         "zeroObservedAcquisitionMeansBackground":false,"peerForegroundCompletenessClaimed":false,
         "maskOrPrivateMeasurementFabricated":false,"ownershipChanged":false,"erasureAuthority":"none"]
    }
}
