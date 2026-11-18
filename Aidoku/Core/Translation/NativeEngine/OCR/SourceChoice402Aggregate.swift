import Foundation
import CoreGraphics

/// Sole integration owner: this file. Receipt-only, no generator/native execution.
/// Scores rank observed source evidence; they are not admission probabilities.
enum SourceChoice402Aggregate {
    typealias K = NativeOCRSharedBoundary396
    typealias Choice = (index: Int, score: Double, receipt: [String:Any])
    struct Nominee {
        let index: Int
        /// Exact suffix in the INPUT aggregate menu, no prefix reconstruction.
        let key: String
        let score: Double
        let receipt: [String:Any]
    }
    struct Result {
        let preferred: Nominee?
        let nominees: [Nominee]
        /// Includes abstention, conflict witnesses, and per-operator nil outcomes.
        let receipt: [String:Any]
    }
    private struct Role {
        let producer: String, family: String
        let choose: (K.Output,[CGPoint],K.Basis,CGFloat) -> Choice?
    }
    private struct Ranked {
        let nominee: Nominee
        let witnesses: [CGPoint]
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n=value as? NSNumber,n.doubleValue.isFinite else {return nil}
        return n.doubleValue
    }
    private static func term(_ value: Any?) -> Double? {
        guard let d=number(value),d>=0,d<=1 else {return nil};return d
    }
    private static func dict(_ r: [String:Any],_ key: String) -> [String:Any] {r[key] as? [String:Any] ?? [:]}
    private static func zero(_ value: Any?) -> Bool {number(value)==0}
    private static func valid(_ q: [CGPoint]) -> Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {return false}
        let turns=(0..<4).map { i -> CGFloat in
            let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        return turns.allSatisfy({$0>1e-8}) || turns.allSatisfy({$0 < -1e-8})
    }
    /// Four COMMON bounded descriptors; provenance/scopes stay in each receipt.
    /// Missing evidence abstains. Native cells never become foreground evidence.
    private static func descriptors(_ role: String,_ r: [String:Any],_ p: K.Proposal) -> [String:Double]? {
        var closure: Double?,extent: Double?,agreement: Double?,retained=false
        switch role {
        case "terminal402":
            let c=dict(r,"components")
            closure=term(c["finiteTouchedComponentClosure"])
            extent=term(c["observedSourceExtentCoverage"])
            agreement=term(c["knownNewPixelSupportAgreement"])
            retained=zero(p.receipt["newlyExcludedOriginalGGBodyPixels"])
        case "outline402":
            guard let ids=r["validatedComponentIDs"] as? [Int],!ids.isEmpty,
                  let verified=r["verifiedStableContrastComponents"] as? [Int],
                  Set(verified).isSubset(of:Set(ids)),let anchors=number(r["actualPrivateRootGGAnchors"]),anchors>=0 else {return nil}
            closure=Double(Set(verified).count)/Double(Set(ids).count)
            extent=term(dict(r,"scoreTerms")["observedRecoveryAgreement"])
            agreement=min(1,anchors/8) // repeated actual GG anchors, not independent RF evidence
            retained=zero(r["newlyExcludedGGBodyPixels"]) && r["observedSelectedSourceExtentEnclosed"] as? Bool == true
        case "normal402":
            let c=dict(r,"evidenceTerms")
            closure=term(c["closedRGBSupport"]);extent=term(c["normalExtentAgreement"])
            agreement=term(c["GGNativeDetectorRFCorroboration"])
            retained=zero(r["newlyExcludedQualifiedSourcePixels"]) && zero(r["recordedGGNewlyExcludedPixels"])
        case "along402":
            let c=dict(r,"scoreComponents")
            if let weighted=number(c["finiteRootAndContourContactGraph"]) {closure=weighted/0.20}
            if let weighted=number(c["pixelSquareEndPlaneAgreement"]) {extent=weighted/0.25}
            if let count=number(r["fillRimAgreeingChangedEndCount"]),
               let edges=r["actualChangedOldEdgeIndices"] as? [Int],!edges.isEmpty {agreement=count/Double(edges.count)}
            retained=r["allObservedGGNativeSelectedLossCountsZero"] as? Bool == true
        case "axis402":
            let c=dict(r,"normalizedTerms")
            // This is repeated finite root CC support strength, NOT complete CC coverage.
            closure=term(c["finiteCC"]);extent=term(c["selectedObservedExtentPreserved"])
            agreement=term(c["rowCCProjectionAgreement"])
            retained=zero(p.receipt["newlyExcludedOriginalGGBodyPixels"]) && p.receipt["allSelectedPixelSquaresPreserved"] as? Bool == true
        case "peer402":
            let c=dict(r,"scoreComponents")
            closure=term(c["observedStableContrastClosure"]);extent=term(c["sourceCellExtentFit"])
            agreement=term(c["anchorWeightedRootRLEAndRFAgreement"])
            retained=(r["originalGGFootprintAndNativeCenterLossCounts"] as? [Int]) == [0,0,0]
        default:return nil
        }
        guard retained,let cl=closure,let ex=extent,let ag=agreement,
              [cl,ex,ag].allSatisfy({$0.isFinite && $0>=0 && $0<=1}) else {return nil}
        return ["observedSupportRetention":1,"finiteClosureOrRootRepetition":cl,
                "observedExtentAgreement":ex,"sourceSupportAgreement":ag]
    }
    /// Conflict witnesses are explicit actual RGB pixels exported by the selector
    /// or proposal. No rectangle, interpolated point, footprint, or hull is ink.
    private static func witnesses(_ values: [Any],inside q: [CGPoint]) -> [CGPoint] {
        var points:[CGPoint]=[],nodes=0
        func visit(_ value: Any,_ depth: Int) {
            guard nodes<20_000,depth<=10,points.count<256 else {return};nodes += 1
            if let r=value as? [String:Any] {
                if let i=number(r["actualLocalPixelIndex"]),i>=0,i<600_000,i.rounded()==i,
                   let xy=r["center"] as? [Double],xy.count==2,xy.allSatisfy(\.isFinite),
                   let rgb=r["RGB"] as? [Int],rgb.count==3,rgb.allSatisfy({(0...255).contains($0)}),
                   r["ownershipClaimed"] as? Bool != true {
                    let p=CGPoint(x:xy[0],y:xy[1])
                    if K.contains(q,p),!points.contains(p) {points.append(p)}
                }
                for key in r.keys.sorted() {if let v=r[key] {visit(v,depth+1)}}
            } else if let a=value as? [Any] {for v in a {visit(v,depth+1)}}
        }
        for value in values {visit(value,0)}
        return points
    }
    /// Input must be the actual existing NativeOCRRepair402Aggregate output.
    /// Nothing is regenerated, combined, snapped, or written back to that menu.
    static func evaluate(output: K.Output, actualOld: [CGPoint], basis: K.Basis,
                         nativeW: CGFloat) -> Result {
        func empty(_ reason: String) -> Result {
            .init(preferred:nil,nominees:[],receipt:["family":"source-choice402-aggregate","status":reason,
                "sourceOnly":true,"GTRead":false,"admissionGranted":false,"nativeAllGuardsStillRequired":true])
        }
        guard valid(actualOld),nativeW.isFinite,nativeW>0,nativeW<100_000,
              [basis.origin,basis.normal,basis.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              abs(hypot(basis.normal.x,basis.normal.y)-1)<1e-6,
              abs(hypot(basis.along.x,basis.along.y)-1)<1e-6,
              abs(basis.normal.x*basis.along.x+basis.normal.y*basis.along.y)<1e-6,
              output.receipt["family"] as? String == "source-repair402",
              output.proposals.count<=128,
              let operators=output.receipt["operatorReceipts"] as? [[String:Any]],operators.count<=7 else {return empty("invalid-actual-aggregate-input")}
        // All six APIs were read directly. No generator dependency or dynamic dispatch.
        let roles:[Role]=[
            .init(producer:"terminal402",family:"repair402-terminal-extension",choose:SourceChoice402Terminal.preferred),
            .init(producer:"outline402",family:"repair402-outline-extension",choose:SourceChoice402Outline.preferred),
            .init(producer:"normal402",family:"repair402-normal-contraction",choose:SourceChoice402Normal.preferred),
            .init(producer:"along402",family:"repair402-along",choose:SourceChoice402Along.preferred),
            .init(producer:"axis402",family:"repair402-axis",choose:SourceChoice402Axis.preferred),
            .init(producer:"peer402",family:"repair402-peer-separation",choose:SourceChoice402Peer.preferred)]
        var ranked:[Ranked]=[],audit:[[String:Any]]=[]
        for role in roles {
            let metadata=operators.filter{$0["family"] as? String == role.producer}
            guard metadata.count==1,let receipt=metadata[0]["receipt"] as? [String:Any],
                  receipt["family"] as? String == role.family else {
                audit.append(["operator":role.producer,"status":"missing-or-ambiguous-original-operator-receipt"]);continue
            }
            let indices=output.proposals.indices.filter {
                let r=output.proposals[$0].receipt
                return r["originalProducer"] as? String == role.producer && r["family"] as? String == role.family
            }
            guard !indices.isEmpty,indices.count<=8 else {
                audit.append(["operator":role.producer,"status":"no-retained-exact-operator-menu"]);continue
            }
            let local=K.Output(proposals:indices.map{output.proposals[$0]},receipt:receipt)
            guard let choice=role.choose(local,actualOld,basis,nativeW) else {
                audit.append(["operator":role.producer,"status":"source-policy-abstained","retainedMenuCount":indices.count]);continue
            }
            guard indices.indices.contains(choice.index),choice.score.isFinite,choice.score>=0,choice.score<=1 else {
                audit.append(["operator":role.producer,"status":"invalid-source-choice-result"]);continue
            }
            let index=indices[choice.index],p=output.proposals[index]
            guard valid(p.polygon),let terms=descriptors(role.producer,choice.receipt,p) else {
                audit.append(["operator":role.producer,"status":"missing-common-evidence-descriptor"]);continue
            }
            // Equal weights, identical range, no removed area/role/ID bonus.
            let score=terms.values.reduce(0,+)/4
            let actualWitnesses=witnesses([choice.receipt,p.receipt],inside:p.polygon)
            guard score>=0.75,!actualWitnesses.isEmpty else {
                audit.append(["operator":role.producer,"status":"insufficient-common-source-evidence","commonScore":score]);continue
            }
            let evidence:[String:Any]=["operator":role.producer,"localIndex":choice.index,"aggregateIndex":index,
                "exactInputKey":p.suffix,"operatorScore":choice.score,"commonScore":score,"commonTerms":terms,
                "operatorEvidence":choice.receipt,"proposalObligations":p.obligations,
                "conflictWitnessCount":actualWitnesses.count,"sourceObservationScope":"exported selected support only; no global completeness",
                "nominationOnly":true,"admissionGranted":false,"nativeAllGuardsStillRequired":true]
            ranked.append(.init(nominee:.init(index:index,key:p.suffix,score:score,receipt:evidence),witnesses:actualWitnesses))
            audit.append(["operator":role.producer,"status":"source-nominated","aggregateIndex":index,"commonScore":score])
        }
        ranked.sort {
            if abs($0.nominee.score-$1.nominee.score)>1e-12 {return $0.nominee.score>$1.nominee.score}
            return $0.nominee.index<$1.nominee.index
        }
        var conflicts:[[String:Any]]=[],survivors:[Ranked]=[]
        for candidate in ranked {
            let q=output.proposals[candidate.nominee.index].polygon
            var losesWitness=false
            for other in ranked where other.nominee.index != candidate.nominee.index {
                let excluded=other.witnesses.filter{!K.contains(q,$0)}
                if !excluded.isEmpty {
                    losesWitness=true
                    conflicts.append(["candidateIndex":candidate.nominee.index,"otherNomineeIndex":other.nominee.index,
                        "status":"excludes-other-nominated-actual-RGB-witness","excludedWitnessCount":excluded.count,
                        "witnessCenters":excluded.prefix(4).map{[Double($0.x),Double($0.y)]},
                        "ownershipResolved":false])
                }
            }
            if !losesWitness {survivors.append(candidate)}
        }
        // Close, materially different surviving envelopes remain ambiguous. A
        // geometry distance resolves disagreement only, never proves foreground.
        var chosen=survivors.first?.nominee,ambiguous=false
        if survivors.count>=2 {
            let first=survivors[0].nominee,second=survivors[1].nominee
            if first.score-second.score<0.05 {
                let a=output.proposals[first.index].polygon,b=output.proposals[second.index].polygon
                var distance=CGFloat.infinity
                for reverse in [false,true] {
                    let z=reverse ? Array(b.reversed()):b
                    for shift in 0..<4 {
                        var d:CGFloat=0
                        for i in 0..<4 {let p=z[(i+shift)%4];d=max(d,hypot(a[i].x-p.x,a[i].y-p.y)/nativeW)}
                        distance=min(distance,d)
                    }
                }
                if distance>0.20 {ambiguous=true;chosen=nil}
            }
        }
        let status=chosen != nil ? "source-nominee-awaiting-all-native-guards":
            (ambiguous ? "abstain-near-tie-with-different-extents":(ranked.isEmpty ? "abstain-no-source-nominee":"abstain-conflicting-source-pixel-witnesses"))
        return .init(preferred:chosen,nominees:ranked.map(\.nominee),receipt:[
            "family":"source-choice402-aggregate","status":status,"operatorResults":audit,"conflicts":conflicts,
            "commonScoreRange":[0.0,1.0],"commonMinimum":0.75,"commonTermWeights":[0.25,0.25,0.25,0.25],
            "rawOperatorScoresComparedAcrossRoles":false,"geometryAltered":false,"sourceReadOrModelCall":false,
            "crossRoleComparisonRisk":"Common source evidence scores are explicit heuristics over different role scopes, not calibrated probabilities. Shared observations are correlated. Exact-key nomination must still pass all actual native guards; source ranking alone cannot admit a candidate.",
            "droppedExactDuplicatesCannotRecoverOriginalOperatorEvidence":true,
            "conflictScope":"bounded exported actual RGB witness centers; unexported source remains unresolved",
            "supportWitnessesProveOwnership":false,"allForegroundCompletenessClaimed":false,
            "GTRead":false,"admissionGranted":false,"nativeAllGuardsStillRequired":true])
    }
    typealias FamilyNominee = (family:String,index:Int,score:Double,receipt:[String:Any])

    /// Required parent API. Input indices are preserved independently per family.
    /// Return ALL nonconflicting source nominees, in INPUT FAMILY ORDER. It is
    /// unsafe to treat an arbitrary cross-role maximum as an admission decision.
    static func preferred(outputs: [(String,K.Output)], actualOld:[CGPoint],
                          basis:K.Basis,nativeW:CGFloat) -> [(family:String,index:Int,score:Double,receipt:[String:Any])] {
        evaluate(outputs:outputs,actualOld:actualOld,basis:basis,nativeW:nativeW).nominees
    }

    /// One-call telemetry alternative: includes reasons even when preferred is [].
    static func evaluate(outputs: [(String,K.Output)], actualOld:[CGPoint],
                         basis:K.Basis,nativeW:CGFloat) -> (nominees:[FamilyNominee],receipt:[String:Any]) {
        let producerByFamily=[
            "repair402-terminal-extension":"terminal402", "repair402-outline-extension":"outline402",
            "repair402-normal-contraction":"normal402", "repair402-along":"along402",
            "repair402-axis":"axis402", "repair402-peer-separation":"peer402"]
        var metadata:[[String:Any]]=[],proposals:[K.Proposal]=[]
        var origins:[(family:String,index:Int,ordinal:Int)]=[],seen=Set<String>(),seenLabels=Set<String>()
        guard outputs.count<=6 else {
            return ([],["status":"too-many-source-operators","admissionGranted":false])
        }
        for (ordinal,item) in outputs.enumerated() {
            let (family,output)=item
            guard let sourceFamily=output.receipt["family"] as? String,
                  let producer=producerByFamily[sourceFamily],seen.insert(producer).inserted,
                  seenLabels.insert(family).inserted,output.proposals.count<=8,
                  Set(output.proposals.map(\.suffix)).count==output.proposals.count else {
                return ([],["status":"unknown-duplicate-or-unbounded-operator-output","inputOrdinal":ordinal,"admissionGranted":false])
            }
            metadata.append(["family":producer,"receipt":output.receipt])
            for (index,p) in output.proposals.enumerated() {
                // Metadata annotation in a VALUE COPY only. Preserve original
                // suffix, receipt fields, polygon vertices, and obligation list.
                var r=p.receipt;r["originalProducer"]=producer
                proposals.append(.init(suffix:p.suffix,polygon:p.polygon,receipt:r,obligations:p.obligations))
                origins.append((family,index,ordinal))
            }
        }
        let input=K.Output(proposals:proposals,receipt:["family":"source-repair402","operatorReceipts":metadata])
        let report=evaluate(output:input,actualOld:actualOld,basis:basis,nativeW:nativeW)
        let conflicts=report.receipt["conflicts"] as? [[String:Any]] ?? []
        let blocked=Set(conflicts.compactMap{$0["candidateIndex"] as? Int})
        var result:[FamilyNominee]=[]
        // Do not choose a global cross-role maximum. The parent receives each
        // surviving family's own nominee for ACTUAL native gate evaluation.
        let ordered=report.nominees.sorted { origins[$0.index].ordinal < origins[$1.index].ordinal }
        for nominee in ordered where !blocked.contains(nominee.index) {
            let origin=origins[nominee.index]
            var r=nominee.receipt
            r["family"]=origin.family;r["index"]=origin.index;r["key"]=nominee.key
            r["indexSpace"]="original-input-family-menu"
            r["sourceWitnessConflictObserved"]=false
            r["crossRoleMaximumChosen"]=false
            r["crossRoleComparisonRisk"]="Each role validates different observed scopes and defines its own score. Equal common descriptor weights are an explicit evidence-priority heuristic, not calibrated probabilities or proof that one role is better. Shared GG/CC observations are correlated; agreement does not create independent evidence. Parent must run actual native guards and selection."
            result.append((origin.family,origin.index,nominee.score,r))
        }
        var receipt=report.receipt
        receipt["status"]=result.isEmpty ? "abstain-no-nonconflicting-source-nominee":"family-nominees-awaiting-native-guards"
        receipt["returnedFamilyNominees"]=result.count
        receipt["inputMenuIndexMap"]=origins.enumerated().map { item -> [String:Any] in
            ["flattenedIndex":item.offset,"family":item.element.family,"localIndex":item.element.index,
             "key":proposals[item.offset].suffix]
        }
        receipt["returnOrder"]="input-family-order-not-cross-role-score-order"
        receipt["crossRoleMaximumChosen"]=false
        receipt["rawOperatorScoresAreCalibratedAcrossRoles"]=false
        receipt["commonScorePolicy"]="equal-weight observed retention, finite closure/repetition, extent agreement, support agreement; role scopes explicitly preserved"
        receipt["conflictsAreOwnershipProof"]=false
        receipt["sharedEvidenceIsIndependentCorroboration"]=false
        receipt["droppedExactDuplicatesCannotRecoverOriginalOperatorEvidence"]=false
        return (result,receipt)
    }
}
