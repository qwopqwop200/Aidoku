import Foundation
import CoreGraphics

/// Actual native re-admission for independently generated source proposals.
/// Does not select, change ownership or replace the legacy producer's guards.
@available(iOS 18.0, *)
enum NativeAdmission425 {
    typealias F = NativeOCRSourceLocalJoint369
    typealias Output = NativeOCRSourceLiveAdmission392.Output
    typealias A = NonDestructiveAuthority425

    static func assess(prior: NativeOCRCurrentPrior351.Resolution,
        graph: NativeOCRSourceLocalJoint369Capture.FinalGraph,
        measurement: F.M, frame: NativeOCRRGBAFrame,
        peerEvidence: F.PeerEvidence, live: F.LiveObservation,
        proposals: [NativeOCRResidualCandidate], accepts: (Int, [CGPoint]) -> Bool) -> Output {
        guard proposals.count <= 128, let actual = graph.prior(measurement.index),
              actual.polygon == prior.polygon,
              actual.consumedIndices == prior.consumedIndices,
              actual.inheritedAssociationKey == prior.inheritedAssociationKey,
              live.sources.map(\.index) == [measurement.index] + prior.consumedIndices,
              live.sources.count == live.bodies.count, !live.bodies.isEmpty,
              frame.width == peerEvidence.frameSize.width, frame.height == peerEvidence.frameSize.height,
              live.bodies.allSatisfy({ $0.prepared.inherited == prior.polygon &&
                  $0.sourceLocalRGBA.origin == live.rgba.origin &&
                  $0.sourceLocalRGBA.width == live.rgba.width &&
                  $0.sourceLocalRGBA.height == live.rgba.height }) else {
            return .init(candidates: [], records: [["admitted": false,
                "hardRejections": ["actual-current-live-graph-body-binding"]]])
        }
        let rgba = live.rgba
        let roi = CGRect(x: rgba.origin.x, y: rgba.origin.y,
            width: CGFloat(rgba.width), height: CGFloat(rgba.height))
        guard peerEvidence.probeROI.contains(roi), rgba.width > 2, rgba.height > 2,
              rgba.width <= 600_000 / rgba.height else {
            return .init(candidates: [], records: [["admitted": false,
                "hardRejections": ["actual-current-local-ROI-binding"]]])
        }
        // Exact source/frame row binding is used only for the narrow new
        // authority rule; no missing/empty field is converted to a zero count.
        let frameScopeBound425 = exactFrameAndMembers(live:live,frame:frame)
        let terminalCache = NativeOCRLocalJointGGCache387(bodies: live.bodies)
        var admitted: [NativeOCRResidualCandidate] = [], records: [[String: Any]] = []
        for proposal in proposals {
            let q = proposal.polygon
            guard q.count == 4, F.valid(q) else {
                records.append(["key": proposal.key, "admitted": false,
                    "hardRejections": ["outside-image-or-invalid-geometry"]])
                continue
            }
            var hard: [String] = [], soft: [String] = [], peers: [[String: Any]] = []
            if proposal.key.isEmpty || !F.valid(q) || !q.allSatisfy({
                $0.x >= 0 && $0.y >= 0 && $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height)
            }) { hard.append("outside-image-or-invalid-geometry") }
            if proposal.consumedIndices != prior.consumedIndices ||
                proposal.associationKey != prior.inheritedAssociationKey {
                hard.append("source-association-or-children-changed")
            }
            let encloses = prior.polygon.allSatisfy { F.contains(q, $0) }
            if !q.allSatisfy({ roi.insetBy(dx: 1, dy: 1).contains($0) }) {
                soft.append("proposal-reaches-live-observation-edge")
            }
            if !(live.mandatory + proposal.supportPoints).allSatisfy({ F.contains(q, $0) }) {
                hard.append("lost-actual-cap-guard-or-explicit-support")
            }
            if !live.sources.allSatisfy({ accepts($0.index, q) }) {
                hard.append("existing-root-member-semantic-reject")
            }
            // All failures are append-only. A rejected proposal cannot become admitted
            // by executing later RGB checks, so do not repeat them just for diagnostics.
            if !hard.isEmpty {
                records.append(["key":proposal.key,"polygon":q.map{[Double($0.x),Double($0.y)]},
                    "admitted":false,"hardRejections":hard,"softRejections":soft,
                    "laterChecksSkippedBecauseAlreadyRejected":true,
                    "skipStage":"geometry-mandatory-or-existing-member-semantics",
                    "actualPriorEnclosed":encloses,"automaticSelection":false,"ownershipOrGraphChanged":false])
                continue
            }
            let foreign = F.acquiredCells(q, old: prior.polygon, footprints: peerEvidence.knownForeignCells)
            let uncertain = F.acquiredCells(q, old: prior.polygon, footprints: peerEvidence.uncertainCells)
            if foreign > 0 { hard.append("acquired-actual-external-owner-cells") }
            if uncertain > 0 { soft.append("acquired-ambiguous-or-competing-DB-cells") }
            var peerFacts425: [A.PeerFact] = []
            for peer in peerEvidence.peers {
                let delta = F.intersectionArea(q, peer.polygon) - F.intersectionArea(prior.polygon, peer.polygon)
                guard delta > 1e-6 else { continue }
                let contrast = NativeOCRContrastSupport380.acquiresCoherentPeerContrast382(
                    old: prior.polygon, proposed: q, peer: peer.polygon, rgba: rgba)
                if contrast { soft.append("acquired-original-contrast-in-actual-peer-region") }
                var acquired = 0
                if let body = live.peerBodies[peer.sourceIndex],
                   body.sourceLocalRGBA.origin == rgba.origin,
                   body.sourceLocalRGBA.width == rgba.width, body.sourceLocalRGBA.height == rgba.height,
                   body.sourceAuthenticatedContrastBodyMask.count == rgba.width * rgba.height {
                    for i in body.sourceAuthenticatedContrastBodyMask.indices where
                        body.sourceAuthenticatedContrastBodyMask[i] != 0 {
                        let p = CGPoint(x: rgba.origin.x + CGFloat(i % rgba.width) + 0.5,
                            y: rgba.origin.y + CGFloat(i / rgba.width) + 0.5)
                        if F.contains(q, p) && !F.contains(prior.polygon, p) { acquired += 1 }
                    }
                    if acquired > 0 { soft.append("acquired-peer-authenticated-contrast-body") }
                } else if peer.missingLocalEvidence || peer.measurement?.privateObservation == nil {
                    soft.append("relevant-peer-local-physical-evidence-unavailable")
                }
                let observed425 = A.peerFact(peer:peer,body:live.peerBodies[peer.sourceIndex],
                    rgba:rgba,old:prior.polygon,proposed:q,coherent:contrast)
                peerFacts425.append(observed425)
                peers.append(["peerSourceIndex": peer.sourceIndex, "newQuadIntersectionArea": Double(delta),
                    "acquiredObservedContrastBodyPixels": acquired,
                    "acquiredCoherentPeerRegionContrast382": contrast, "quadOverlapAloneVeto": false,
                    "authenticPeerBodyBinding425":observed425.authenticBodyBound,
                    "actualObservedPeerBodyAcquired425":observed425.observedAcquiredBodyPixels as Any? ?? NSNull()])
            }
            var pixelChecks:[[String:Any]]=[]
            var memberFacts425: [A.MemberLossFact] = []
            let lost425 = (live.mandatory+proposal.supportPoints).filter{!F.contains(q,$0)}.count
            func facts425() -> A.Facts {
                A.Facts(actualOld:prior.polygon,proposed:q,
                    graphAndMergeRelationsFixed:proposal.consumedIndices == prior.consumedIndices &&
                        proposal.associationKey == prior.inheritedAssociationKey,
                    actualFrameAndSourceScopeBound:frameScopeBound425,
                    lostProtectedPoints:lost425,actualForeignAcquisitions:foreign,
                    actualUncertainAcquisitions:uncertain,expandedPeers:peerFacts425,
                    expectedMembers:live.sources.count,memberLossChecks:memberFacts425,
                    hardRejections:hard,softRejections:soft)
            }
            // Full enclosure never skips the actual native loss checks when it
            // is proposed as authority to defer coherent-only uncertainty.
            let prospective425 = A.mayDefer(facts425(),requireExecutedLossChecks:false)
            let needsLossChecks = (!encloses && hard.isEmpty && soft.isEmpty) || prospective425
            if needsLossChecks {
                let denseRGBA=NativeOCRDensePrivateFootprintGuard.RGBA(bytes:rgba.bytes,width:rgba.width,
                    height:rgba.height,stride:rgba.bytesPerRow,origin:rgba.origin)
                for (ordinal,body) in live.bodies.enumerated() {
                    let m=live.sources[ordinal],p=body.prepared
                    let oldNormal=prior.polygon.map{m.project($0).x}
                    let whole=NativeOCRResidualTurningStrokeGuardHistogram.assess(old:prior.polygon,new:q,
                        rgba:rgba,authenticatedPalettes:p.actualPalettes,
                        privateRGBSampleCount:m.privateObservation?.privateRGBSamples ?? 0,
                        frameOrigin:m.origin,normal:m.normal,along:m.along,sourceWidth:m.rect.width,
                        inheritedNormalBounds:oldNormal.min()!...oldNormal.max()!)
                    let dense=NativeOCRDensePrivateFootprintGuard.assess(old:prior.polygon,proposed:q,rgba:denseRGBA,
                        footprints:[p.actualFullFootprint],origin:m.origin,normal:m.normal,along:m.along,sourceWidth:m.rect.width)
                    let terminal=terminalCache.terminalObservation(memberOrdinal:ordinal,proposed:q)
                    if whole.decision == "reject" {hard.append("whole-source-reject")}
                    else if whole.decision != "no-entire-closed-component-loss-observed" {soft.append("whole-source-uncertain")}
                    if dense.decision == "reject" {hard.append("dense-source-reject")}
                    else if dense.decision != "no-substantial-source-relative-loss-observed" {soft.append("dense-source-uncertain")}
                    if terminal?.decision == "reject" || terminal?.witnesses.isEmpty == false {hard.append("actual-terminal-loss")}
                    else if terminal?.decision != "no-qualified-terminal-loss-observed" {soft.append("terminal-observation-unavailable")}
                    memberFacts425.append(.init(sourceOrdinal:ordinal,whole:whole.decision,dense:dense.decision,
                        terminal:terminal?.decision,terminalWitnessesEmpty:terminal?.witnesses.isEmpty == true))
                    pixelChecks.append(["sourceIndex":m.index,"sourceOrdinal":ordinal,
                        "whole":whole.decision,"dense":dense.decision,
                        "terminal":terminal?.decision as Any? ?? NSNull(),
                        "terminalPairs":terminal?.examinedPairs ?? 0])
                }
            }
            let authorityFacts425 = facts425()
            let deferred425 = A.mayDefer(authorityFacts425)
            if deferred425 {
                // Only this one reason is deferred. Real peer/body/foreign,
                // uncertain, whole/dense/GG/semantic failures are untouched.
                soft.removeAll { $0 == A.coherentOnlyReason }
            }
            let passed = hard.isEmpty && soft.isEmpty
            if passed { admitted.append(proposal) }
            records.append(["key": proposal.key, "polygon": q.map { [Double($0.x), Double($0.y)] },
                "admitted": passed, "hardRejections": hard, "softRejections": soft,
                "actualForeignCellAcquisitions": foreign, "uncertainCellAcquisitions": uncertain,
                "peerReceipts": peers, "pixelChecks": pixelChecks, "actualPriorEnclosed": encloses,
                "sourceLossChecksSkippedBecauseNoPriorPixelCanBeRemoved": encloses && !needsLossChecks,
                "nonDestructiveAuthority425":A.receipt(authorityFacts425,deferred:deferred425),
                "sourceLossChecksExecutedDespiteEnclosure425":encloses && needsLossChecks,
                "coherentContrastObservationPreserved425":true,
                "sourceLossChecksExecuted":needsLossChecks,
                "sourceLossChecksSkippedBecauseAlreadyRejected": !encloses && !needsLossChecks,
                "nativeRootMemberSemanticsExecuted": live.sources.map(\.index),
                "ownershipOrGraphChanged": false, "automaticSelection": false])
        }
        let stats=terminalCache.statistics
        let performance:[String:Any]=["totalSourcePixels":stats.totalSourcePixels,
            "preparedMembers":stats.preparedMembers,"warmMaskMismatches":stats.warmMaskMismatches,
            "sourcePreparations":stats.sourcePreparations,"estimatedCachedRayBytes":stats.estimatedCachedRayBytes,
            "rayHits":stats.rayHits,"staticCalls":stats.staticCalls,
            "rayBudgetFallbackMembers":stats.rayBudgetFallbackMembers,
            "rootScopedOnly":true,"peerBodiesNotCached":true]
        if stats.warmMaskMismatches>0 {
            admitted.removeAll()
            for i in records.indices {
                records[i]["admitted"]=false
                records[i]["hardRejections"]=(records[i]["hardRejections"] as? [String] ?? [])+["cached-terminal-warm-binding-mismatch"]
            }
        }
        return .init(candidates: admitted, records: records, performance:performance)
    }
    private static func exactFrameAndMembers(live:F.LiveObservation,frame:NativeOCRRGBAFrame)->Bool {
        let r=live.rgba,w=r.width,h=r.height
        guard w>2,h>2,w<=600_000/h,r.bytesPerRow>=w*4,h<=Int.max/r.bytesPerRow,
              r.bytes.count==h*r.bytesPerRow,
              live.window.frameSize.width==frame.width,live.window.frameSize.height==frame.height,
              live.window.left>=0,live.window.top>=0,
              live.window.width==w,live.window.height==h,
              live.window.left<=frame.width-w,live.window.top<=frame.height-h,
              r.origin==CGPoint(x:live.window.left,y:live.window.top),
              live.sources.count==live.bodies.count,!live.sources.isEmpty else{return false}
        for y in 0..<h {
            let a=(live.window.top+y)*frame.bytesPerRow+live.window.left*4,b=y*r.bytesPerRow
            if !frame.bytes[a..<(a+w*4)].elementsEqual(r.bytes[b..<(b+w*4)]) {return false}
        }
        for (ordinal,m) in live.sources.enumerated() {
            let b=live.bodies[ordinal],f=b.actualFullFootprint
            guard let retained=m.privateObservation,let original=retained.footprint,
                  retained.missingPrivateRGBPixels==0,m.status=="measured",!original.cells.isEmpty,
                  f.width==original.width,f.height==original.height,f.scaleX==original.scaleX,
                  f.scaleY==original.scaleY,f.cells==original.cells,
                  b.prepared.sourceOrigin==m.origin,b.prepared.normal==m.normal,b.prepared.along==m.along,
                  b.prepared.sourceWidth==Double(m.rect.width),
                  b.sourceLocalRGBA.bytes==r.bytes,b.sourceLocalRGBA.bytesPerRow==r.bytesPerRow,
                  b.sourceLocalRGBA.origin==r.origin,b.sourceLocalRGBA.width==w,b.sourceLocalRGBA.height==h,
                  b.sourceAuthenticatedContrastBodyMask.count==w*h else{return false}
        }
        return true
    }
}
