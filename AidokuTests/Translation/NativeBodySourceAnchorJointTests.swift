import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeBodySourceAnchorJointTests {
    typealias R = NativeBodySourceAnchorRecovery
    typealias N = NativeFinalTextPaintAdmission
    private let page = CGRect(x:0,y:0,width:240,height:160)
    private func normalized(_ rect: CGRect) -> [Double] {
        [rect.minX/240,rect.minY/160,rect.width/240,rect.height/160].map(Double.init)
    }
    private func active(offset: CGFloat = 4) throws -> R.Tuple {
        var rgba = [UInt8](repeating:0,count:10*8*4)
        for p in 0..<80 { rgba[p*4+3] = p%10 == 9 ? 1:255 }
        let image = try NativeMandatoryDisplayStroke.image(rgba,width:10,height:8)
        let allowed = normalized(CGRect(x:4,y:4,width:232,height:152))
        let policy = NativeTextExpansionPolicy(allowedRectNormalized:allowed,candidates:[allowed],maskCoverage:[1],backgroundRisk:[0],
            sourceFontPixels:10,kind:"inside-balloon-mask",maskRectNormalized:allowed,
            maskSpansNormalized:[4.0/240,236.0/240,4.0/240,236.0/240])
        var fills: [R.Primitive] = []
        for i in 0..<3 {
            var f = R.Primitive(image:image,frame:CGRect(x:50+i*30,y:i == 2 ? 120:50,width:10,height:8),fontOutputPixels:10)
            f.ownerID = ["left","right","peer"][i]; f.hasFinalEffects = true
            f.textExpansionPolicy = policy; f.placementDomain = { [page] in policy.allows($0,page:page) }
            if i < 2 {
                f.balloonPlacement = .init(bodyID:"joint-body",rectNormalized:normalized(CGRect(x:40,y:30,width:120,height:40)),
                    preserveSourceOffsets:false,biasNormalized:[0,0],flow:.row,paddingEm:0,gapEm:0.6,
                    maskSHA256:String(repeating:"a",count:64),order:i)
            }
            fills.append(f)
        }
        let placed = try N.place(fills,page:page)
        fills = placed.fills
        for i in 0..<2 {
            fills[i].textPlacementGuide = .init(rectNormalized:normalized(fills[i].frame.offsetBy(dx:offset,dy:0)),horizontal:.left,vertical:.top)
        }
        let fixed = try Dictionary(uniqueKeysWithValues:fills.map { ($0.ownerID!,try N.retainedFootprint($0).bounds.origin) })
        return try N.place(fills,page:page,fixedOrigins:fixed)
    }
    @Test func activeBodyCoMovesWithoutPruningAgainstStationaryOwnPeers() throws {
        let before = try active()
        #expect(before.audit[0]["balloonBodyPlaced"] as? Bool == true)
        #expect(!before.fills[0].balloonTargetRelaxed)
        let after = R.refine(before,page:page)
        for i in 0..<2 {
            #expect(after.fills[i].frame == before.fills[i].frame.offsetBy(dx:4,dy:0))
            #expect(after.fills[i].balloonPlacement == before.fills[i].balloonPlacement)
            #expect(after.fills[i].balloonTargetRelaxed)
            #expect(after.audit[i]["balloonBodyPlaced"] as? Bool == false)
            #expect(after.audit[i]["balloonCapacityFallback"] as? Bool == true)
            #expect(after.audit[i]["balloonTargetFallbackReason"] as? String == "proved-joint-sourceward-improvement")
            #expect(try NativeMandatoryDisplayStroke.rgba(after.fills[i].image) == NativeMandatoryDisplayStroke.rgba(before.fills[i].image))
            #expect(after.fills[i].fontOutputPixels == before.fills[i].fontOutputPixels)
        }
        #expect(after.fills[2].frame == before.fills[2].frame)
        #expect(after.fills[2].balloonTargetRelaxed == before.fills[2].balloonTargetRelaxed)
        #expect(R.validateTerminal(before,terminal:after,recoveredBodyIDs:["joint-body"],page:page).accepted)
        let reversed: R.Tuple = (Array(before.fills.reversed()),Array(before.audit.reversed()))
        let reverseAfter = R.refine(reversed,page:page)
        for f in reverseAfter.fills { #expect(f.frame == after.fills.first { $0.ownerID == f.ownerID }?.frame) }
    }
    @Test func blockedPeerCanStayWhileOtherMovesAndUnknownGateDefersGroup() throws {
        let before = try active()
        var calls = 0
        let after = R.refine(before,page:page,boundaryGate:{ old,_ in
            calls += 1
            return (old.bounds.minX != before.fills[0].frame.minX,["evidenceAvailable":true])
        })
        #expect(after.fills[0].frame == before.fills[0].frame)
        #expect(after.fills[1].frame == before.fills[1].frame.offsetBy(dx:4,dy:0))
        #expect(after.fills[0].balloonTargetRelaxed && after.fills[1].balloonTargetRelaxed)
        #expect(calls <= 16)
        let info = try #require(after.audit[1]["bodySourceAnchorRecovery"] as? [String:Any])
        #expect(info["exactOptimumClaimed"] as? Bool == false)
        #expect(info["boundaryCalls"] as? Int == calls)
        var unknownCalls = 0
        let unknown = R.refine(before,page:page,boundaryGate:{ _,_ in
            unknownCalls += 1; return (nil,["status":"sample-budget","evidenceAvailable":false])
        })
        #expect(unknownCalls == 1)
        #expect(unknown.fills.map(\.frame) == before.fills.map(\.frame))
        #expect(unknown.fills.map(\.balloonTargetRelaxed) == before.fills.map(\.balloonTargetRelaxed))
        #expect((unknown.audit[0]["bodySourceBoundaryGate"] as? [String:Any])?["boundaryBudgetDeferred"] as? Bool == true)
        #expect(!R.validateTerminal(before,terminal:after,recoveredBodyIDs:["joint-body"],page:page,
            boundaryGate:{ _,_ in (nil,["evidenceAvailable":false]) }).accepted)
    }
    @Test func allZeroUnknownProtectedAndTamperedTransactionsCannotReleaseTargets() throws {
        let aligned = try active(offset:0)
        let unchanged = R.refine(aligned,page:page)
        #expect(unchanged.fills.map(\.frame) == aligned.fills.map(\.frame))
        #expect(unchanged.fills.map(\.balloonTargetRelaxed) == aligned.fills.map(\.balloonTargetRelaxed))
        #expect(NSDictionary(dictionary:unchanged.audit[0]).isEqual(to:aligned.audit[0]))
        let before = try active()
        var unknown = before; unknown.audit[0].removeValue(forKey:NativeBalloonPlacement.RetainedState.auditKey)
        #expect(R.refine(unknown,page:page).fills.map(\.frame) == before.fills.map(\.frame))
        #expect(R.refine(before,page:page,protectedOwners:["left"]).fills.map(\.frame) == before.fills.map(\.frame))
        let good = R.refine(before,page:page)
        var bad = good; bad.audit[0].removeValue(forKey:"bodySourceAnchorRecoveryPolicy")
        #expect(!R.validateTerminal(before,terminal:bad,recoveredBodyIDs:["joint-body"],page:page).accepted)
        bad = good; bad.fills[2].balloonTargetRelaxed = true
        #expect(!R.validateTerminal(before,terminal:bad,recoveredBodyIDs:["joint-body"],page:page).accepted)
        bad = good; bad.fills[0].balloonPlacement!.order += 1
        #expect(!R.validateTerminal(before,terminal:bad,recoveredBodyIDs:["joint-body"],page:page).accepted)
        bad = good; bad.fills[0].frame.origin.y += 1
        #expect(!R.validateTerminal(before,terminal:bad,recoveredBodyIDs:["joint-body"],page:page).accepted)
    }
}

extension NativeBodySourceAnchorJointTests {
    @Test func controlledBodyTransitionRetainsDeclaredInputAndRevalidatedSourceLineage() throws {
        typealias S = NativeBalloonPlacement.RetainedState
        var before = try active()
        for i in 0..<2 {
            let owner = before.fills[i].ownerID!
            let state = try S.decode(before.audit[i][S.auditKey]!,owner:owner)
            var declared = try #require(state.inputPacket)
            declared.flow = .column; declared.preserveSourceOffsets = nil; declared.finalReadabilityGaps = nil
            let bound = S.Snapshot(schema:state.schema,owner:owner,presence:state.presence,inputPacket:declared,
                effectivePacket:state.effectivePacket,groupOwners:state.groupOwners,balloonTargetRelaxed:state.balloonTargetRelaxed,
                target:state.target,fallbackReason:state.fallbackReason,provenance:.fixedOriginRevalidated,
                requiresFixedOriginRevalidation:false,historicalStateExact:false,sourceIdentity:"bound-original-source")
            before.audit[i][S.auditKey] = try S.encode(bound)
        }
        let after = R.refine(before,page:page)
        for i in 0..<2 {
            let owner = before.fills[i].ownerID!
            let prior = try S.decode(before.audit[i][S.auditKey]!,owner:owner)
            let changed = try S.decode(after.audit[i][S.auditKey]!,owner:owner)
            #expect(after.fills[i].frame == before.fills[i].frame.offsetBy(dx:4,dy:0))
            #expect(prior.inputPacket != prior.effectivePacket)
            #expect(changed.inputPacket == prior.inputPacket)
            #expect(changed.effectivePacket == prior.effectivePacket)
            #expect(!changed.historicalStateExact && changed.sourceIdentity == prior.sourceIdentity)
            #expect(changed.provenance == .nativeAdmission && changed.target == .fallback && changed.balloonTargetRelaxed == true)
        }
        #expect(R.validateTerminal(before,terminal:after,recoveredBodyIDs:["joint-body"],page:page).accepted)
    }
}

extension NativeBodySourceAnchorJointTests {
    @Test func unrelatedCompleteFallbackBodyKeepsExactSnapshotAndPolicyReasonThroughFreshAdmission() throws {
        typealias S = NativeBalloonPlacement.RetainedState
        let seed = try active()
        var carriers = seed.fills
        for i in 0..<2 {
            var f = seed.fills[0]
            f.ownerID = "stationary-peer-\(i)"
            f.frame = CGRect(x:40+i*30,y:100,width:10,height:8)
            f.textPlacementGuide = .init(rectNormalized:normalized(f.frame),horizontal:.left,vertical:.top)
            f.balloonPlacement = .init(bodyID:"stationary-peer-body",rectNormalized:[0.05,0.5,0.8,0.3],
                preserveSourceOffsets:false,biasNormalized:[0,0],flow:.row,paddingEm:0,gapEm:0.6,
                maskSHA256:String(repeating:"b",count:64),order:i)
            f.balloonTargetRelaxed = true; carriers.append(f)
        }
        let fixed = try Dictionary(uniqueKeysWithValues:carriers.map { ($0.ownerID!,try N.retainedFootprint($0).bounds.origin) })
        var before = try N.place(carriers,page:page,fixedOrigins:fixed)
        for i in 3..<5 {
            let s = try S.decode(before.audit[i][S.auditKey]!,owner:before.fills[i].ownerID!)
            var declared = s.inputPacket!; declared.flow = .column
            let state = S.Snapshot(schema:s.schema,owner:s.owner,presence:s.presence,inputPacket:declared,
                effectivePacket:s.effectivePacket,groupOwners:s.groupOwners,balloonTargetRelaxed:s.balloonTargetRelaxed,
                target:s.target,fallbackReason:"retained-peer-policy",provenance:.fixedOriginRevalidated,
                requiresFixedOriginRevalidation:false,historicalStateExact:false,sourceIdentity:"retained-peer-original")
            before.audit[i][S.auditKey] = try S.encode(state)
            before.audit[i]["balloonTargetFallbackReason"] = state.fallbackReason!
        }
        let after = R.refine(before,page:page)
        #expect(after.fills[0].frame == before.fills[0].frame.offsetBy(dx:4,dy:0))
        for i in 3..<5 {
            let owner = before.fills[i].ownerID!
            #expect(after.fills[i].frame == before.fills[i].frame)
            #expect(after.fills[i].balloonTargetRelaxed == before.fills[i].balloonTargetRelaxed)
            #expect(try S.decode(after.audit[i][S.auditKey]!,owner:owner) == S.decode(before.audit[i][S.auditKey]!,owner:owner))
            #expect(after.audit[i]["balloonTargetFallbackReason"] as? String == "retained-peer-policy")
            #expect(after.audit[i]["balloonBodyPlaced"] as? Bool == false)
            #expect(after.audit[i]["balloonCapacityFallback"] as? Bool == true)
            #expect(after.audit[i]["bodySourceAnchorRecoveryPolicy"] == nil)
            #expect(try NativeMandatoryDisplayStroke.rgba(after.fills[i].image) == NativeMandatoryDisplayStroke.rgba(before.fills[i].image))
        }
    }
}
