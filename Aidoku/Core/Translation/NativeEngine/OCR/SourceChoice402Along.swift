import Foundation
import CoreFoundation
import CoreGraphics

// Nomination over the frozen generator's actual receipts, never native admission.
// No source re-read, page/ID routing, alternate geometry, or GT is used.
enum SourceChoice402Along {
    typealias K = NativeOCRSharedBoundary396
    static func preferred(output: K.Output, actualOld old: [CGPoint], basis f: K.Basis,
                          nativeW mw: CGFloat) -> (index: Int, score: Double, receipt: [String:Any])? {
        func number(_ value: Any?) -> Double? {
            guard let n=value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let v=n.doubleValue; return v.isFinite ? v : nil
        }
        func integer(_ value: Any?) -> Int? {
            guard let v=number(value), v >= 0, v <= 600_000, floor(v)==v else {return nil}
            return Int(v)
        }
        func integers(_ value: Any?) -> [Int]? {
            guard let list=value as? [Any] else {return nil}
            let parsed=list.compactMap(integer); return parsed.count==list.count ? parsed:nil
        }
        func numbers(_ value: Any?) -> [Double]? {
            guard let list=value as? [Any] else {return nil}
            let parsed=list.compactMap(number); return parsed.count==list.count ? parsed:nil
        }
        func points(_ value: Any?) -> [CGPoint]? {
            guard let rows=value as? [Any] else {return nil}
            var points:[CGPoint]=[]
            for row in rows {guard let xy=numbers(row),xy.count==2 else{return nil};points.append(CGPoint(x:xy[0],y:xy[1]))}
            return points
        }
        guard output.receipt["family"] as? String == "repair402-along",
              output.receipt["admissionGranted"] as? Bool == false,
              output.receipt["GTRead"] as? Bool == false, old.count==4,
              old.allSatisfy({$0.x.isFinite && $0.y.isFinite}),mw.isFinite,mw>0,mw<100_000,
              abs(hypot(f.normal.x,f.normal.y)-1)<1e-6,
              abs(hypot(f.along.x,f.along.y)-1)<1e-6,
              abs(f.normal.x*f.along.x+f.normal.y*f.along.y)<1e-6,
              output.proposals.count<=8 else {return nil}
        let turns=(0..<4).map { i -> CGFloat in
            let a=old[i],b=old[(i+1)%4],c=old[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        guard turns.allSatisfy({$0>1e-8}) || turns.allSatisfy({$0 < -1e-8}) else{return nil}
        let ccw=turns[0]>0
        var normals:[CGPoint]=[],planes:[CGFloat]=[]
        for i in 0..<4 {
            let a=old[i],b=old[(i+1)%4],dx=b.x-a.x,dy=b.y-a.y,len=hypot(dx,dy)
            let n=ccw ? CGPoint(x:dy/len,y:-dx/len):CGPoint(x:-dy/len,y:dx/len)
            normals.append(n);planes.append(n.x*a.x+n.y*a.y)
        }
        // The generator stores vertices as intersections of the SAME old planes.
        func changes(_ polygon:[CGPoint]) -> [CGFloat]? {
            guard polygon.count==4,polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite && K.contains(old,$0)}) else{return nil}
            let cross=(0..<4).map { i -> CGFloat in
                let a=polygon[i],b=polygon[(i+1)%4],c=polygon[(i+2)%4]
                return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
            }
            guard ccw ? cross.allSatisfy({$0>1e-8}):cross.allSatisfy({$0 < -1e-8}) else{return nil}
            var delta:[CGFloat]=[]
            for i in 0..<4 {
                let a=polygon[i],b=polygon[(i+1)%4],n=normals[i]
                let first=n.x*a.x+n.y*a.y,second=n.x*b.x+n.y*b.y
                guard abs(first-second)<1e-5 else{return nil}
                delta.append(first-planes[i])
            }
            return delta
        }
        var best:(index:Int,score:Double,receipt:[String:Any])?
        for (index,proposal) in output.proposals.enumerated() {
            let r=proposal.receipt
            guard r["family"] as? String == "repair402-along",
                  r["supportMode"] as? String == "contact-rim",
                  r["admissionGranted"] as? Bool == false,
                  r["GTRead"] as? Bool == false,
                  r["normalEdgesUnchanged"] as? Bool == true,
                  r["oldEdgeDirectionsPreserved"] as? Bool == true,
                  r["candidateInsideActualOld"] as? Bool == true,
                  r["geometryOrPaletteUsedAsForegroundMask"] as? Bool == false,
                  r["completeForegroundPreservationClaimed"] as? Bool == false,
                  r["stableBackgroundStripCertified"] as? Bool == false,
                  let boundOld=points(r["actualOld"]),boundOld.count==4,
                  zip(boundOld,old).allSatisfy({hypot($0.0.x-$0.1.x,$0.0.y-$0.1.y)<1e-6}),
                  integer(r["newlyExcludedOriginalGGBodyPixels"])==0,
                  integer(r["newlyExcludedActualNativeCellCenters"])==0,
                  integer(r["selectedSupportPixelLossCount"])==0,
                  let roots=integers(r["rootAnchoredComponentIDs"]),!roots.isEmpty,
                  let ids=integers(r["sourceSupportComponentIDs"]),Set(roots).isSubset(of:Set(ids)),
                  let endEdges=integers(r["movedOldEdgeIndices"]),!endEdges.isEmpty,
                  endEdges.count<=2,Set(endEdges).count==endEdges.count,endEdges.allSatisfy({$0<4}),
                  let delta=changes(proposal.polygon),
                  let reported=numbers(r["signedEdgePlaneChanges"]),reported.count==4,
                  (0..<4).allSatisfy({abs(delta[$0]-CGFloat(reported[$0]))<1e-5}),
                  let witnesses=r["edgeActualPixelWitnesses"] as? [[String:Any]],witnesses.count==endEdges.count,
                  let detached=r["RFDBDetachedSupport"] as? [[String:Any]],
                  let pairs=r["contactPairs"] as? [[String:Any]],
                  let runRows=r["sourceSupportActualPixelRuns"] as? [[Any]],!runRows.isEmpty else{continue}
            let changed=(0..<4).filter {delta[$0] < -0.5}
            guard !changed.isEmpty, changed.allSatisfy({endEdges.contains($0)}),
                  (0..<4).allSatisfy({i in
                    if endEdges.contains(i) {return delta[i]<=1e-6 && abs(normals[i].x*f.along.x+normals[i].y*f.along.y)>0.8}
                    return abs(delta[i])<1e-6
                  }) else{continue}
            var actualRunPixels=0,valid=true,lastRow = -1,lastEnd = -1
            for row in runRows {
                guard let run=integers(row),run.count==3,run[2]>0,
                      run[0]>=lastRow,run[0] != lastRow || run[1]>=lastEnd else {valid=false;break}
                actualRunPixels += run[2];lastRow=run[0];lastEnd=run[1]+run[2]
                if actualRunPixels>600_000 {valid=false;break}
            }
            guard valid,actualRunPixels>=2*roots.count else{continue}
            // Reconstruct only the receipt's component contact graph, never a mask.
            var supported=Set(roots),detachedCount=0
            for d in detached {
                guard let id=integer(d["componentID"]),
                      let db=integers(d["actualRootDetectorOrdinals"]),!db.isEmpty,
                      let rf=integers(d["RFQueryIDs"]),!rf.isEmpty,
                      d["colourMatchRequired"] as? Bool == false,
                      d["associationProven"] as? Bool == false else{valid=false;break}
                supported.insert(id);detachedCount += 1
            }
            guard valid else{continue}
            var contacts:[(Int,Int,Int)]=[]
            for p in pairs {
                guard let from=integer(p["from"]),let to=integer(p["to"]),
                      let count=integer(p["actualCardinalContacts"]) else{valid=false;break}
                if count>=2 {contacts.append((from,to,count))}
            }
            guard valid else{continue}
            let anchors=supported
            for contact in contacts where anchors.contains(contact.0) {supported.insert(contact.1)}
            let idSet=Set(ids)
            let contourIDs=idSet.subtracting(anchors)
            guard idSet.isSubset(of:supported),!contourIDs.isEmpty else{continue}
            var actualWitnesses:[[String:Any]]=[]
            for edge in changed {
                guard let ordinal=endEdges.firstIndex(of:edge) else{valid=false;break}
                let witness=witnesses[ordinal],n=normals[edge]
                guard integer(witness["actualLocalPixelIndex"]) != nil,
                      let xy=numbers(witness["center"]),xy.count==2,
                      let rgb=integers(witness["RGB"]),rgb.count==3,rgb.allSatisfy({$0<=255}),
                      witness["ownershipClaimed"] as? Bool == false else{valid=false;break}
                let support=n.x*CGFloat(xy[0])+n.y*CGFloat(xy[1])+(abs(n.x)+abs(n.y))*0.5
                guard abs(support-(planes[edge]+delta[edge]))<1e-5 else{valid=false;break}
                actualWitnesses.append(witness)
            }
            guard valid else{continue}
            // Fill/rim agreement is a measured optional check, not independent ownership.
            var agreements=0
            let tolerance=max(1.0,mw*0.2)
            for edge in changed {
                if output.proposals.contains(where:{ other in
                    let s=other.receipt
                    guard s["family"] as? String == "repair402-along",
                          s["supportMode"] as? String == "root-detached-fill",
                          let otherOld=points(s["actualOld"]),otherOld.count==4,
                          zip(otherOld,old).allSatisfy({hypot($0.0.x-$0.1.x,$0.0.y-$0.1.y)<1e-6}),
                          let otherRoots=integers(s["rootAnchoredComponentIDs"]),Set(otherRoots)==Set(roots),
                          let d=changes(other.polygon),d[edge] < -0.5 else{return false}
                    return abs(d[edge]-delta[edge])<=tolerance
                }) {agreements += 1}
            }
            // Comparable bounded evidence score, not correctness probability.
            // Hard gates already demand CC/contact provenance, exact pixel endpoint
            // agreement and zero loss in the THREE actual observations above.
            let rootBreadth=min(1.0,Double(roots.count)/3.0)
            let agreement=Double(agreements)/Double(changed.count)
            let supportStrength=min(1.0,Double(actualRunPixels)/(Double(mw*mw)*2.0))
            let terms:[String:Double]=["zeroObservedGGNativeAndSelectedLoss":0.30,
                "pixelSquareEndPlaneAgreement":0.25,"finiteRootAndContourContactGraph":0.20,
                "rootComponentBreadth":0.10*rootBreadth,"observedSupportSize":0.05*supportStrength,
                "fillRimEndpointAgreement":0.10*agreement]
            let score=min(1.0,max(0.0,terms.values.reduce(0,+)))
            guard score>=0.80 else{continue}
            let receipt:[String:Any]=["family":"repair402-along-source-choice","preferredIndex":index,
                "score":score,"scoreRange":[0.0,1.0],"scoreIsCorrectnessProbability":false,"scoreComponents":terms,
                "actualChangedOldEdgeIndices":changed,"actualEndpointPixelWitnesses":actualWitnesses,
                "actualRootComponentIDs":roots,"actualSupportedContourComponentIDs":contourIDs.sorted(),
                "actualComponentContactPairs":contacts.filter {anchors.contains($0.0) && idSet.contains($0.1)}.map {[$0.0,$0.1,$0.2]},
                "actualSupportRunCount":runRows.count,"actualSupportPixelCount":actualRunPixels,
                "independentlyRFAndDBSupportedDetachedCount":detachedCount,
                "fillRimAgreeingChangedEndCount":agreements,"fillRimAgreementTolerance":Double(tolerance),
                "allObservedGGNativeSelectedLossCountsZero":true,"completeForegroundPreservationClaimed":false,
                "stableBackgroundStripCertified":false,"detachedAssociationProven":false,
                "normalOmissionsRepaired":false,"nominationOnly":true,"admissionGranted":false,"GTRead":false,
                "nativeObligations":proposal.obligations]
            if let prior=best {
                // Equal support score prefers more independently supported end repairs;
                // then lower index. Removed area is never a quality/ownership signal.
                let priorEdges=prior.receipt["actualChangedOldEdgeIndices"] as? [Int] ?? []
                if score>prior.score+1e-12 || (abs(score-prior.score)<=1e-12 && changed.count>priorEdges.count) {
                    best=(index,score,receipt)
                }
            } else {best=(index,score,receipt)}
        }
        return best
    }
}
