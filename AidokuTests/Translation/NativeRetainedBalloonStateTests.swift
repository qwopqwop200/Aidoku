import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeRetainedBalloonStateTests {
    typealias S = NativeBalloonPlacement.RetainedState
    private func packet(order: Int = 0) -> NativeBalloonPlacement {
        .init(crossAlignment:.end,bodyID:"synthetic-body",rectNormalized:[0.05,0.05,0.9,0.9],
            preserveSourceOffsets:true,finalReadabilityGaps:true,biasNormalized:[0.1,-0.1],flow:.row,
            paddingEm:0.1,gapEm:0.4,maskSHA256:String(repeating:"a",count:64),order:order)
    }
    private func rejects(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }
    @Test func allPacketFieldsAndOptionalFlagsRoundTripWithoutRawNormalizationEquality() throws {
        for preserve in [nil,false,true] as [Bool?] {
            for readability in [nil,false,true] as [Bool?] {
                var p = packet(); p.preserveSourceOffsets = preserve; p.finalReadabilityGaps = readability
                for alignment in [nil,.start,.center,.end] as [NativeBalloonPlacement.CrossAlignment?] {
                    p.crossAlignment = alignment
                    let state = try S.capture(owner:"a",inputPacket:p,effectivePacket:p,groupOwners:["b","a"],
                        relaxed:true,targetPlaced:false,fallbackReason:"inherited-relaxation")
                    let encoded = try S.encode(state)
                    let recovered = try S.decode(encoded,owner:"a",declaredRequest:.packet(p))
                    #expect(recovered == state)
                    #expect(recovered.effectivePacket == p)
                    #expect(recovered.balloonTargetRelaxed == true)
                    #expect(recovered.groupOwners == ["a","b"])
                    var raw = p; raw.flow = .column; raw.order = 9; raw.rectNormalized = [0.1,0.1,0.8,0.8]
                    raw.preserveSourceOffsets = nil; raw.finalReadabilityGaps = nil
                    #expect(try S.decode(encoded,owner:"a",declaredRequest:.packet(raw)) == state)
                }
            }
        }
    }
    @Test func missingExplicitAbsenceBindingAndBoundedMalformedSchemas() throws {
        if case .missing = try S.read([:],owner:"a") {} else { Issue.record("missing must stay unknown") }
        let absent = try S.capture(owner:"a",inputPacket:nil,effectivePacket:nil,groupOwners:["a"],
            relaxed:false,targetPlaced:false,fallbackReason:nil)
        let encoded = try S.encode(absent)
        #expect(try S.decode(encoded,owner:"a",declaredRequest:.absent).presence == .absent)
        #expect(rejects { _ = try S.read([S.auditKey:NSNull()],owner:"a") })
        #expect(rejects { _ = try S.decode(encoded,owner:"a",declaredRequest:.packet(packet())) })
        let p = packet()
        let present = try S.encode(S.capture(owner:"a",inputPacket:p,effectivePacket:p,groupOwners:["a"],
            relaxed:false,targetPlaced:true,fallbackReason:nil))
        var wrongBody = p; wrongBody = .init(bodyID:"different",rectNormalized:p.rectNormalized,
            biasNormalized:p.biasNormalized,flow:p.flow,paddingEm:p.paddingEm,gapEm:p.gapEm,maskSHA256:p.maskSHA256,order:0)
        #expect(rejects { _ = try S.decode(present,owner:"a",declaredRequest:.packet(wrongBody)) })
        let wrongMask = NativeBalloonPlacement(bodyID:p.bodyID,rectNormalized:p.rectNormalized,biasNormalized:p.biasNormalized,
            flow:p.flow,paddingEm:p.paddingEm,gapEm:p.gapEm,maskSHA256:String(repeating:"b",count:64),order:0)
        #expect(rejects { _ = try S.decode(present,owner:"a",declaredRequest:.packet(wrongMask)) })
        #expect(rejects { _ = try S.decode(present,owner:"other") })
        var malformed = present; malformed.removeValue(forKey:"balloonTargetRelaxed")
        #expect(rejects { _ = try S.decode(malformed,owner:"a") })
        malformed = present; malformed["schema"] = 999
        #expect(rejects { _ = try S.decode(malformed,owner:"a") })
        malformed = present; malformed["groupOwners"] = Array(repeating:"a",count:257)
        #expect(rejects { _ = try S.decode(malformed,owner:"a") })
        malformed = present; malformed["owner"] = String(repeating:"x",count:70_000)
        #expect(rejects { _ = try S.decode(malformed,owner:"a") })
        malformed = present
        var incomplete = try #require(present["effectivePacket"] as? [String:Any]); incomplete.removeValue(forKey:"finalReadabilityGaps")
        malformed["effectivePacket"] = incomplete
        #expect(rejects { _ = try S.decode(malformed,owner:"a") })
    }
    private func fixture() throws -> S.Tuple {
        typealias N = NativeFinalTextPaintAdmission
        let page = CGRect(x:0,y:0,width:160,height:120)
        var rgba = [UInt8](repeating:0,count:6*4*4)
        for p in 0..<24 { rgba[p*4+3] = p%6 == 5 ? 1:255 }
        let image = try NativeMandatoryDisplayStroke.image(rgba,width:6,height:4)
        let policy = NativeTextExpansionPolicy(allowedRectNormalized:[0.01,0.01,0.98,0.98],
            candidates:[[0.01,0.01,0.98,0.98]],maskCoverage:[1],backgroundRisk:[0],sourceFontPixels:10,
            kind:"inside-balloon-mask",maskRectNormalized:[0.01,0.01,0.98,0.98],
            maskSpansNormalized:[0.01,0.99,0.01,0.99])
        var fills: [S.Primitive] = []
        for i in 0..<3 {
            let frame = CGRect(x:20+i*45,y:i == 2 ? 85:40,width:6,height:4)
            var f = S.Primitive(image:image,frame:frame,fontOutputPixels:10)
            f.ownerID = ["a","b","peer"][i]; f.hasFinalEffects = true
            f.textExpansionPolicy = policy; f.placementDomain = { policy.allows($0,page:page) }
            f.textPlacementGuide = .init(rectNormalized:[frame.minX/160,frame.minY/120,frame.width/160,frame.height/120].map(Double.init),
                horizontal:.left,vertical:.top)
            if i < 2 { f.balloonPlacement = packet(order:i); f.balloonTargetRelaxed = true }
            fills.append(f)
        }
        let fixed = try Dictionary(uniqueKeysWithValues:fills.map { ($0.ownerID!,try N.retainedFootprint($0).bounds.origin) })
        var tuple = try N.place(fills,page:page,fixedOrigins:fixed)
        for i in tuple.audit.indices { tuple.audit[i]["legacySentinel"] = "unchanged" }
        return tuple
    }
    @Test func completeGroupRecoveryPinsPeersAndLegacyUncertaintyUntilNewAdmission() throws {
        let page = CGRect(x:0,y:0,width:160,height:120)
        let original = try fixture()
        let captured = try S.rehydrate(original,page:page)
        #expect(captured.unknownOwners.isEmpty)
        #expect(captured.fills.map(\.balloonPlacement) == original.fills.map(\.balloonPlacement))
        var legacy = original
        legacy.audit[0].removeValue(forKey:S.auditKey); legacy.audit[1].removeValue(forKey:S.auditKey)
        legacy.audit[2].removeValue(forKey:S.auditKey)
        legacy.audit[0]["balloonBodyID"] = NSNull() // surviving contradictory legacy evidence remains untouched.
        legacy.audit[1].removeValue(forKey:"balloonTargetRelaxed")
        legacy.fills[0].balloonPlacement = nil // partial effective historical carrier.
        var declaredA = packet(), declaredB = packet(order:1)
        declaredA.flow = .column; declaredA.order = 1; declaredA.preserveSourceOffsets = nil; declaredA.finalReadabilityGaps = nil
        declaredB.flow = .column; declaredB.order = 0; declaredB.preserveSourceOffsets = nil; declaredB.finalReadabilityGaps = nil
        let raw = try S.AuthenticatedRawGroup(packets:["a":declaredA,"b":declaredB],expectedOwnerIDs:["a","b"],sourceIdentity:"synthetic-original")
        let plan = try S.rehydrate(legacy,page:page,rawGroups:[raw],declaredAbsentOwners:["peer"],declaredSourceIdentity:"synthetic-original")
        #expect(NSDictionary(dictionary:plan.audit[0]).isEqual(to:legacy.audit[0]))
        #expect(NSDictionary(dictionary:plan.audit[1]).isEqual(to:legacy.audit[1]))
        #expect(plan.unknownOwners == ["a","b","peer"])
        #expect(plan.fixedOrigins.count == 3)
        #expect(plan.states["a"]?.requiresFixedOriginRevalidation == true)
        #expect(plan.states["a"]?.historicalStateExact == false)
        #expect(plan.states["b"]?.balloonTargetRelaxed == nil)
        #expect(plan.states["peer"]?.presence == .absent)
        #expect(plan.states["peer"]?.target == .unknown)
        #expect(plan.fills[0].balloonPlacement?.flow == .row) // normalized COMPLETE group, not raw column.
        let candidate = try #require(plan.states["a"])
        #expect(try S.decode(S.encode(candidate),owner:"a").requiresFixedOriginRevalidation)
        let validated = try S.revalidateFixedOrigins(plan,page:page)
        for i in original.fills.indices {
            #expect(validated.fills[i].frame == original.fills[i].frame)
            #expect(validated.fills[i].fontOutputPixels == original.fills[i].fontOutputPixels)
            #expect(try NativeMandatoryDisplayStroke.rgba(validated.fills[i].image) == NativeMandatoryDisplayStroke.rgba(original.fills[i].image))
            #expect(validated.audit[i]["legacySentinel"] as? String == "unchanged")
            if case .state(let state) = try S.read(validated.audit[i],owner:validated.fills[i].ownerID!) {
                #expect(state.provenance == .fixedOriginRevalidated)
                #expect(!state.historicalStateExact && !state.requiresFixedOriginRevalidation)
            } else { Issue.record("validated state missing") }
        }
        #expect(validated.fills[2].balloonPlacement == original.fills[2].balloonPlacement)
        #expect(validated.fills[2].balloonTargetRelaxed == original.fills[2].balloonTargetRelaxed)
        #expect(rejects { _ = try S.AuthenticatedRawGroup(packets:["a":declaredA],expectedOwnerIDs:["a","b"],sourceIdentity:"synthetic-original") })
        let partial = (fills:Array(original.fills.prefix(1)),audit:Array(original.audit.prefix(1)))
        #expect(rejects { _ = try S.rehydrate(partial,page:page) })
        var mixed = original; mixed.audit[1].removeValue(forKey:S.auditKey)
        #expect(rejects { _ = try S.rehydrate(mixed,page:page,rawGroups:[raw]) })
        let unbound = try S.rehydrate(legacy,page:page)
        #expect(rejects { _ = try S.revalidateFixedOrigins(unbound,page:page) })
    }
}

extension NativeRetainedBalloonStateTests {
    @Test func wholeBodyMembershipCannotBePartitionedOrCarryContradictoryTargetFlags() throws {
        let a = try S.capture(owner:"a",inputPacket:packet(),effectivePacket:packet(),groupOwners:["a"],
            relaxed:true,targetPlaced:false,fallbackReason:"inherited-relaxation")
        let b = try S.capture(owner:"b",inputPacket:packet(),effectivePacket:packet(),groupOwners:["b"],
            relaxed:true,targetPlaced:false,fallbackReason:"inherited-relaxation")
        #expect(rejects { try S.validateGroups(["a":a,"b":b]) }) // self partitions AND duplicate order.
        let wholeA = try S.capture(owner:"a",inputPacket:packet(),effectivePacket:packet(),groupOwners:["a","b"],
            relaxed:true,targetPlaced:false,fallbackReason:"inherited-relaxation")
        let wholeB = try S.capture(owner:"b",inputPacket:packet(order:1),effectivePacket:packet(order:1),groupOwners:["a","b"],
            relaxed:true,targetPlaced:false,fallbackReason:"inherited-relaxation")
        try S.validateGroups(["a":wholeA,"b":wholeB])
        #expect(rejects { try S.validateGroups(["a":wholeA]) })
        let placedB = try S.capture(owner:"b",inputPacket:packet(order:1),effectivePacket:packet(order:1),groupOwners:["a","b"],
            relaxed:false,targetPlaced:true,fallbackReason:nil)
        #expect(rejects { try S.validateGroups(["a":wholeA,"b":placedB]) })
        var incomplete = try S.encode(wholeB)
        incomplete["balloonTargetRelaxed"] = false // same fallback target, conflicting effective relaxation.
        let relaxedMismatch = try S.decode(incomplete,owner:"b")
        #expect(rejects { try S.validateGroups(["a":wholeA,"b":relaxedMismatch]) })
        incomplete = try S.encode(wholeB); incomplete["provenance"] = "fixedOriginRevalidated"; incomplete["historicalStateExact"] = false
        let provenanceMismatch = try S.decode(incomplete,owner:"b")
        #expect(rejects { try S.validateGroups(["a":wholeA,"b":provenanceMismatch]) })
    }
}

extension NativeRetainedBalloonStateTests {
    @Test func unchangedFreshAdmissionPreservesWholeRevalidatedSnapshotAndPolicyReason() throws {
        let original = try fixture()
        var prior = original.audit
        for i in prior.indices {
            let owner = original.fills[i].ownerID!
            let s = try S.decode(prior[i][S.auditKey]!,owner:owner)
            var raw = s.inputPacket
            if raw != nil { raw!.preserveSourceOffsets = nil; raw!.finalReadabilityGaps = nil; raw!.flow = .column }
            let state = S.Snapshot(schema:s.schema,owner:owner,presence:s.presence,inputPacket:raw,
                effectivePacket:s.effectivePacket,groupOwners:s.groupOwners,balloonTargetRelaxed:s.balloonTargetRelaxed,
                target:s.target,fallbackReason:s.presence == .present ? "proved-joint-sourceward-improvement":nil,
                provenance:.fixedOriginRevalidated,requiresFixedOriginRevalidation:false,historicalStateExact:false,
                sourceIdentity:"authenticated-synthetic-original")
            prior[i][S.auditKey] = try S.encode(state)
            prior[i]["balloonTargetFallbackReason"] = state.fallbackReason as Any? ?? NSNull()
        }
        // Actual default native readmission recaptures nativeAdmission/true/nil
        // and receives EFFECTIVE packets, not historical pre-normalization input.
        let page = CGRect(x:0,y:0,width:160,height:120)
        let fixed = try Dictionary(uniqueKeysWithValues:original.fills.map {
            ($0.ownerID!,try NativeFinalTextPaintAdmission.retainedFootprint($0).bounds.origin)
        })
        let fresh = try NativeFinalTextPaintAdmission.place(original.fills,page:page,fixedOrigins:fixed)
        let freshState = try S.decode(fresh.audit[0][S.auditKey]!,owner:"a")
        #expect(freshState.provenance == .nativeAdmission && freshState.historicalStateExact && freshState.sourceIdentity == nil)
        let kept = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:fresh.audit,unknownPolicy:.reject)
        for i in kept.indices {
            let owner = original.fills[i].ownerID!
            let before = try S.decode(prior[i][S.auditKey]!,owner:owner)
            let after = try S.decode(kept[i][S.auditKey]!,owner:owner)
            #expect(after == before)
            #expect(after.provenance == .fixedOriginRevalidated && !after.historicalStateExact)
            #expect(after.sourceIdentity == "authenticated-synthetic-original")
            #expect(NSDictionary(dictionary:try #require(kept[i][S.auditKey] as? [String:Any]))
                .isEqual(to:try #require(prior[i][S.auditKey] as? [String:Any])))
            #expect(kept[i]["finalFootprintOutputPixels"] as? [CGFloat] == fresh.audit[i]["finalFootprintOutputPixels"] as? [CGFloat])
            #expect(kept[i]["balloonTargetFallbackReason"] as? String == before.fallbackReason)
        }
        #expect(kept[0]["balloonTargetFallbackReason"] as? String == "proved-joint-sourceward-improvement")
        let reversed = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:Array(fresh.audit.reversed()),unknownPolicy:.reject)
        #expect(reversed.map { $0["owner"] as? String } == fresh.audit.reversed().map { $0["owner"] as? String })
        #expect(try S.decode(reversed.last![S.auditKey]!,owner:"a") == S.decode(prior[0][S.auditKey]!,owner:"a"))
        // A different source of admission input requires explicit policy.
        var sameInput = fresh.audit
        for i in sameInput.indices {
            var object = try #require(sameInput[i][S.auditKey] as? [String:Any])
            object["inputPacket"] = try #require(prior[i][S.auditKey] as? [String:Any])["inputPacket"]!
            sameInput[i][S.auditKey] = object
        }
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:sameInput,unknownPolicy:.reject) })
        let explicit = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:sameInput,unknownPolicy:.reject,inputPolicy:.unchangedInputPacket)
        #expect(try S.decode(explicit[0][S.auditKey]!,owner:"a") == S.decode(prior[0][S.auditKey]!,owner:"a"))
        // Neither input array is modified, including the fresh generic reason.
        #expect(fresh.audit[0]["balloonTargetFallbackReason"] as? String == "inherited-relaxation")
    }

    @Test func lineageUtilityRejectsPartialGroupsSemanticChangesAndUnboundFreshFlags() throws {
        let original = try fixture()
        let prior = original.audit
        var fresh = prior
        fresh[0]["balloonTargetRelaxed"] = false
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:fresh,unknownPolicy:.reject) })
        fresh = prior; fresh[0]["balloonBodyPlaced"] = true
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:fresh,unknownPolicy:.reject) })
        fresh = prior; fresh[0]["balloonCapacityFallback"] = false
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:fresh,unknownPolicy:.reject) })
        fresh = prior; fresh[0]["balloonBodyID"] = "wrong-body"
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:fresh,unknownPolicy:.reject) })
        fresh = prior; fresh[0]["balloonTargetRelaxed"] = NSNumber(value:1) // not a JSON Boolean.
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:fresh,unknownPolicy:.reject) })
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:Array(prior.dropLast()),unknownPolicy:.reject) })
        fresh = prior; fresh[1] = fresh[0]
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:fresh,unknownPolicy:.reject) })
        fresh = prior; fresh[1].removeValue(forKey:S.auditKey)
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:fresh,unknownPolicy:.preservePriorUncertainty) })
        // Full coherent target/flag change is still NOT an unchanged transition:
        // explicit body recovery must authorize it outside this utility.
        fresh = prior
        for i in 0..<2 {
            var object = try #require(fresh[i][S.auditKey] as? [String:Any])
            object["target"] = "placed"; object["balloonTargetRelaxed"] = false
            fresh[i][S.auditKey] = object; fresh[i]["balloonBodyPlaced"] = true
            fresh[i]["balloonCapacityFallback"] = false; fresh[i]["balloonTargetRelaxed"] = false
        }
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:fresh,unknownPolicy:.reject) })
        fresh = prior
        for i in 0..<2 {
            var object = try #require(fresh[i][S.auditKey] as? [String:Any])
            var p = try #require(object["effectivePacket"] as? [String:Any]); p["finalReadabilityGaps"] = false
            object["effectivePacket"] = p; fresh[i][S.auditKey] = object
        }
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:fresh,unknownPolicy:.reject) })
    }

    @Test func lineageUnknownPolicyKeepsCandidateOrMissingWithoutInventingCertainty() throws {
        let original = try fixture()
        var prior = original.audit
        for i in 0..<2 {
            let s = try S.decode(prior[i][S.auditKey]!,owner:original.fills[i].ownerID!)
            let candidate = S.Snapshot(schema:s.schema,owner:s.owner,presence:s.presence,inputPacket:s.inputPacket,
                effectivePacket:s.effectivePacket,groupOwners:s.groupOwners,balloonTargetRelaxed:nil,target:.unknown,
                fallbackReason:s.fallbackReason,provenance:.authenticatedLegacyCandidate,
                requiresFixedOriginRevalidation:true,historicalStateExact:false,sourceIdentity:"uncertain-synthetic-source")
            prior[i][S.auditKey] = try S.encode(candidate)
        }
        prior[2].removeValue(forKey:S.auditKey)
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:original.audit,unknownPolicy:.reject) })
        let kept = try S.preservingKnownSnapshots(priorAudit:prior,admittedAudit:original.audit,unknownPolicy:.preservePriorUncertainty)
        for i in 0..<2 {
            let owner = original.fills[i].ownerID!
            let state = try S.decode(kept[i][S.auditKey]!,owner:owner)
            let expected = try S.decode(prior[i][S.auditKey]!,owner:owner)
            #expect(state == expected)
            #expect(state.requiresFixedOriginRevalidation && !state.historicalStateExact)
            #expect(state.balloonTargetRelaxed == nil && state.target == .unknown)
            #expect(state.sourceIdentity == "uncertain-synthetic-source")
        }
        #expect(kept[2][S.auditKey] == nil)
        #expect(kept[2]["balloonBodyPlaced"] as? Bool == original.audit[2]["balloonBodyPlaced"] as? Bool)
    }
}

extension NativeRetainedBalloonStateTests {
    private func physicalReadmissionFixture() throws -> (prior: [[String:Any]], fresh: S.Tuple) {
        let seed = try fixture(), page = CGRect(x:0,y:0,width:160,height:120)
        var strict = seed.fills
        for i in 0..<2 { strict[i].balloonTargetRelaxed = false }
        let origins = try Dictionary(uniqueKeysWithValues:strict.map {
            ($0.ownerID!,try NativeFinalTextPaintAdmission.retainedFootprint($0).bounds.origin)
        })
        let active = try NativeFinalTextPaintAdmission.place(strict,page:page,fixedOrigins:origins)
        var prior = active.audit
        for i in prior.indices {
            let owner = strict[i].ownerID!, old = try S.decode(prior[i][S.auditKey]!,owner:owner)
            var declared = old.inputPacket
            if declared != nil { declared!.flow = .column; declared!.preserveSourceOffsets = nil; declared!.finalReadabilityGaps = nil }
            let known = S.Snapshot(schema:old.schema,owner:owner,presence:old.presence,inputPacket:declared,
                effectivePacket:old.effectivePacket,groupOwners:old.groupOwners,balloonTargetRelaxed:old.balloonTargetRelaxed,
                target:old.target,fallbackReason:old.fallbackReason,provenance:.fixedOriginRevalidated,
                requiresFixedOriginRevalidation:false,historicalStateExact:false,sourceIdentity:"physical-source-binding")
            prior[i][S.auditKey] = try S.encode(known)
        }
        // A real native fixed-raster repair moves only a. The strict target
        // must relax for the COMPLETE body; stationary b's audit must refresh.
        var repair = active.fills, repairedOrigins = origins
        for i in 0..<2 { repair[i].balloonTargetRelaxed = true }
        repairedOrigins["a"]!.x += 1
        let fresh = try NativeFinalTextPaintAdmission.place(repair,page:page,fixedOrigins:repairedOrigins)
        let footprints = try fresh.fills.map { try NativeFinalTextPaintAdmission.retainedFootprint($0) }
        try NativeFinalTextPaintAdmission.verifyRetainedPlacement(fresh.fills,footprints:footprints,page:page)
        #expect(fresh.fills[0].frame == active.fills[0].frame.offsetBy(dx:1,dy:0))
        #expect(fresh.fills[1].frame == active.fills[1].frame)
        #expect(fresh.fills[2].frame == active.fills[2].frame)
        for i in active.fills.indices {
            #expect(try NativeMandatoryDisplayStroke.rgba(fresh.fills[i].image) == NativeMandatoryDisplayStroke.rgba(active.fills[i].image))
        }
        return (prior,fresh)
    }

    @Test func physicalReadmissionRefreshesCompleteStrictBodyAndRetainsAllSourceLineage() throws {
        let fixture = try physicalReadmissionFixture()
        #expect(rejects { _ = try S.preservingKnownSnapshots(priorAudit:fixture.prior,admittedAudit:fixture.fresh.audit,unknownPolicy:.reject) })
        let rows = try S.preservingPhysicalReadmission(priorAudit:fixture.prior,admittedAudit:fixture.fresh.audit,
            transitionedBodyIDs:["synthetic-body"],unknownPolicy:.reject)
        for i in 0..<2 {
            let owner = fixture.fresh.fills[i].ownerID!
            let old = try S.decode(fixture.prior[i][S.auditKey]!,owner:owner)
            let state = try S.decode(rows[i][S.auditKey]!,owner:owner)
            #expect(old.balloonTargetRelaxed == false && old.target == .placed)
            #expect(state.balloonTargetRelaxed == true && state.target == .fallback)
            #expect(state.inputPacket == old.inputPacket && state.effectivePacket == old.effectivePacket)
            #expect(state.groupOwners == old.groupOwners)
            #expect(state.sourceIdentity == old.sourceIdentity && !state.historicalStateExact)
            #expect(state.provenance == .nativeAdmission)
            #expect(state.fallbackReason == "physical-readmission-body-relaxation")
            #expect(rows[i]["balloonBodyPlaced"] as? Bool == false)
            #expect(rows[i]["balloonCapacityFallback"] as? Bool == true)
            #expect(rows[i]["balloonTargetRelaxed"] as? Bool == true)
            #expect(rows[i]["balloonTargetFallbackReason"] as? String == state.fallbackReason)
            let marker = try #require(rows[i]["retainedBalloonPhysicalReadmission"] as? [String:Any])
            #expect(marker["completeGroup"] as? Bool == true)
            #expect(marker["members"] as? [String] == ["a","b"])
            #expect(marker["physicalContainmentMeasured"] as? Bool == false)
        }
        let peer = try S.decode(rows[2][S.auditKey]!,owner:"peer")
        #expect(try peer == S.decode(fixture.prior[2][S.auditKey]!,owner:"peer"))
        #expect(rows[2]["retainedBalloonPhysicalReadmission"] == nil)
        #expect(rows[1]["finalFootprintOutputPixels"] as? [CGFloat] == fixture.fresh.audit[1]["finalFootprintOutputPixels"] as? [CGFloat])
        let reversed = try S.preservingPhysicalReadmission(priorAudit:fixture.prior,
            admittedAudit:Array(fixture.fresh.audit.reversed()),transitionedBodyIDs:["synthetic-body"],unknownPolicy:.reject)
        #expect(reversed.first?["owner"] as? String == "peer")
    }

    @Test func physicalReadmissionRejectsReversePartialUnknownAndUnboundGroupTransitions() throws {
        let fixture = try physicalReadmissionFixture()
        #expect(rejects { _ = try S.preservingPhysicalReadmission(priorAudit:fixture.prior,admittedAudit:fixture.fresh.audit,
            transitionedBodyIDs:[],unknownPolicy:.reject) })
        #expect(rejects { _ = try S.preservingPhysicalReadmission(priorAudit:fixture.prior,admittedAudit:fixture.fresh.audit,
            transitionedBodyIDs:["nonexistent"],unknownPolicy:.reject) })
        #expect(rejects { _ = try S.preservingPhysicalReadmission(priorAudit:fixture.fresh.audit,admittedAudit:fixture.prior,
            transitionedBodyIDs:["synthetic-body"],unknownPolicy:.reject) })
        var partial = fixture.fresh.audit; partial[1] = fixture.prior[1]
        #expect(rejects { _ = try S.preservingPhysicalReadmission(priorAudit:fixture.prior,admittedAudit:partial,
            transitionedBodyIDs:["synthetic-body"],unknownPolicy:.reject) })
        var unknown = fixture.prior
        for i in 0..<2 { unknown[i].removeValue(forKey:S.auditKey) }
        #expect(rejects { _ = try S.preservingPhysicalReadmission(priorAudit:unknown,admittedAudit:fixture.fresh.audit,
            transitionedBodyIDs:["synthetic-body"],unknownPolicy:.preservePriorUncertainty) })
        // No undeclared transition of an unknown group may hide behind the
        // explicit uncertainty preservation policy either.
        #expect(rejects { _ = try S.preservingPhysicalReadmission(priorAudit:unknown,admittedAudit:fixture.fresh.audit,
            transitionedBodyIDs:[],unknownPolicy:.preservePriorUncertainty) })
        var unbound = fixture.fresh.audit; unbound[1]["balloonTargetRelaxed"] = false
        #expect(rejects { _ = try S.preservingPhysicalReadmission(priorAudit:fixture.prior,admittedAudit:unbound,
            transitionedBodyIDs:["synthetic-body"],unknownPolicy:.reject) })
        var changed = fixture.fresh.audit
        for i in 0..<2 {
            var state = try #require(changed[i][S.auditKey] as? [String:Any])
            var p = try #require(state["effectivePacket"] as? [String:Any]); p["finalReadabilityGaps"] = false
            state["effectivePacket"] = p; changed[i][S.auditKey] = state
        }
        #expect(rejects { _ = try S.preservingPhysicalReadmission(priorAudit:fixture.prior,admittedAudit:changed,
            transitionedBodyIDs:["synthetic-body"],unknownPolicy:.reject) })
    }
}

extension NativeRetainedBalloonStateTests {
    @Test(arguments: [false,true])
    func repeatedFixedOriginSavesPreserveEveryKnownSnapshotField(nativeProvenance: Bool) throws {
        let page = CGRect(x:0,y:0,width:160,height:120)
        var before = try fixture()
        for i in before.audit.indices {
            let owner = before.fills[i].ownerID!
            let old = try S.decode(before.audit[i][S.auditKey]!,owner:owner)
            var declared = old.inputPacket
            if declared != nil { declared!.flow = .column; declared!.preserveSourceOffsets = nil; declared!.finalReadabilityGaps = nil }
            let known = S.Snapshot(schema:old.schema,owner:owner,presence:old.presence,inputPacket:declared,
                effectivePacket:old.effectivePacket,groupOwners:old.groupOwners,balloonTargetRelaxed:old.balloonTargetRelaxed,
                target:old.target,fallbackReason:old.presence == .present ? "proved-joint-sourceward-improvement":nil,
                provenance:nativeProvenance ? .nativeAdmission:.fixedOriginRevalidated,
                requiresFixedOriginRevalidation:false,historicalStateExact:false,sourceIdentity:"known-original-source")
            before.audit[i][S.auditKey] = try S.encode(known)
            before.audit[i]["balloonTargetFallbackReason"] = known.fallbackReason as Any? ?? NSNull()
            before.audit[i]["retainedBalloonRevalidation"] = ["status":"existing-known-authority","sentinel":i]
        }
        var current = before
        for _ in 0..<2 {
            let plan = try S.rehydrate(current,page:page)
            #expect(plan.unknownOwners.isEmpty)
            current = try S.revalidateFixedOrigins(plan,page:page)
            for i in current.fills.indices {
                let owner = before.fills[i].ownerID!
                let old = try S.decode(before.audit[i][S.auditKey]!,owner:owner)
                let state = try S.decode(current.audit[i][S.auditKey]!,owner:owner)
                #expect(state == old)
                #expect(state.provenance == old.provenance && !state.historicalStateExact)
                #expect(state.sourceIdentity == "known-original-source")
                #expect(!state.requiresFixedOriginRevalidation)
                if i < 2 {
                    #expect(old.inputPacket != old.effectivePacket)
                    #expect(state.inputPacket == old.inputPacket)
                    #expect(state.fallbackReason == "proved-joint-sourceward-improvement")
                    #expect(current.audit[i]["balloonTargetFallbackReason"] as? String == state.fallbackReason)
                }
                #expect(NSDictionary(dictionary:try #require(current.audit[i][S.auditKey] as? [String:Any]))
                    .isEqual(to:try #require(before.audit[i][S.auditKey] as? [String:Any])))
                #expect(NSDictionary(dictionary:try #require(current.audit[i]["retainedBalloonRevalidation"] as? [String:Any]))
                    .isEqual(to:try #require(before.audit[i]["retainedBalloonRevalidation"] as? [String:Any])))
                #expect(current.fills[i].frame == before.fills[i].frame)
                #expect(current.fills[i].fontOutputPixels == before.fills[i].fontOutputPixels)
                #expect(current.fills[i].balloonPlacement == before.fills[i].balloonPlacement)
                #expect(current.fills[i].balloonTargetRelaxed == before.fills[i].balloonTargetRelaxed)
                #expect(try NativeMandatoryDisplayStroke.rgba(current.fills[i].image) == NativeMandatoryDisplayStroke.rgba(before.fills[i].image))
            }
        }
    }

    @Test func selectiveUnknownRevalidationDoesNotRecaptureKnownStationaryPeer() throws {
        let page = CGRect(x:0,y:0,width:160,height:120)
        var before = try fixture()
        let peer = try S.decode(before.audit[2][S.auditKey]!,owner:"peer")
        let knownPeer = S.Snapshot(schema:peer.schema,owner:peer.owner,presence:peer.presence,inputPacket:peer.inputPacket,
            effectivePacket:peer.effectivePacket,groupOwners:peer.groupOwners,balloonTargetRelaxed:peer.balloonTargetRelaxed,
            target:peer.target,fallbackReason:peer.fallbackReason,provenance:.nativeAdmission,
            requiresFixedOriginRevalidation:false,historicalStateExact:false,sourceIdentity:"known-peer-original")
        before.audit[2][S.auditKey] = try S.encode(knownPeer)
        var declarations: [String:NativeBalloonPlacement] = [:]
        for i in 0..<2 {
            declarations[before.fills[i].ownerID!] = before.fills[i].balloonPlacement!
            before.audit[i].removeValue(forKey:S.auditKey)
        }
        let raw = try S.AuthenticatedRawGroup(packets:declarations,expectedOwnerIDs:["a","b"],sourceIdentity:"unknown-body-original")
        let plan = try S.rehydrate(before,page:page,rawGroups:[raw])
        #expect(plan.unknownOwners == ["a","b"])
        let after = try S.revalidateFixedOrigins(plan,page:page)
        for i in 0..<2 {
            let state = try S.decode(after.audit[i][S.auditKey]!,owner:after.fills[i].ownerID!)
            #expect(state.provenance == .fixedOriginRevalidated && !state.historicalStateExact)
            #expect(state.sourceIdentity == "unknown-body-original" && !state.requiresFixedOriginRevalidation)
            #expect((after.audit[i]["retainedBalloonRevalidation"] as? [String:Any])?["status"] as? String == "new-fixed-origin-admission")
        }
        #expect(try S.decode(after.audit[2][S.auditKey]!,owner:"peer") == knownPeer)
        #expect(after.audit[2]["retainedBalloonRevalidation"] == nil)
        let secondPlan = try S.rehydrate(after,page:page)
        #expect(secondPlan.unknownOwners.isEmpty)
        let second = try S.revalidateFixedOrigins(secondPlan,page:page)
        for i in after.audit.indices {
            let owner = after.fills[i].ownerID!
            #expect(try S.decode(second.audit[i][S.auditKey]!,owner:owner) == S.decode(after.audit[i][S.auditKey]!,owner:owner))
        }
    }
}
