import Foundation
import CoreGraphics

/// A nomination over existing402 receipts only. This never admits or erases.
/// nil means the frozen receipts do not establish the minimum evidence below.
enum SourceChoice402Axis {
    typealias K = NativeOCRSharedBoundary396
    private static func number(_ value: Any?) -> Double? {
        guard let value=value, !(value is NSNull) else { return nil }
        let n: Double?
        if let d=value as? Double { n=d }
        else if let v=value as? NSNumber { n=v.doubleValue }
        else { n=nil }
        guard let d=n,d.isFinite else { return nil };return d
    }
    private static func vector(_ value: Any?, count: Int) -> [Double]? {
        guard let a=value as? [Any],a.count==count else { return nil }
        let v=a.compactMap{number($0)};return v.count==count ? v:nil
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let d=number(value),d>=0,d<=600_000,d.rounded(.towardZero)==d else {return nil}
        return Int(d)
    }
    private static func unit(_ d: Double) -> Double { max(0,min(1,d)) }

    static func preferred(output: NativeOCRSharedBoundary396.Output,
                          actualOld: [CGPoint], basis: NativeOCRSharedBoundary396.Basis,
                          nativeW: CGFloat) -> (index: Int, score: Double, receipt: [String:Any])? {
        // The parent's existing round-robin menu keeps the original operator
        // receipt and exact polygons. Preserve its actual menu index, including
        // when exact geometry deduplication removed some axis alternatives.
        if output.receipt["family"] as? String == "source-repair402" {
            guard let operators=output.receipt["operatorReceipts"] as? [[String:Any]],
                  let source=operators.compactMap({$0["receipt"] as? [String:Any]}).first(where:{$0["family"] as? String == "repair402-axis"}) else {return nil}
            let indices=output.proposals.indices.filter{output.proposals[$0].receipt["family"] as? String == "repair402-axis"}
            let local=K.Output(proposals:indices.map{output.proposals[$0]},receipt:source)
            guard let nomination=preferred(output:local,actualOld:actualOld,basis:basis,nativeW:nativeW) else {return nil}
            let actualIndex=indices[nomination.index]
            var receipt=nomination.receipt
            receipt["operatorLocalRetainedIndex"]=nomination.index
            receipt["index"]=actualIndex
            receipt["indexSpace"]="actual-parent-aggregate-menu"
            receipt["exactAggregatePolygonRetained"]=true
            return (actualIndex,nomination.score,receipt)
        }
        let g=output.receipt
        guard actualOld.count==4,actualOld.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              nativeW.isFinite,nativeW>0,nativeW<100_000,
              [basis.origin,basis.normal,basis.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              abs(hypot(basis.normal.x,basis.normal.y)-1)<1e-6,
              abs(hypot(basis.along.x,basis.along.y)-1)<1e-6,
              abs(basis.normal.x*basis.along.x+basis.normal.y*basis.along.y)<1e-6,
              g["family"] as? String == "repair402-axis",
              g["status"] as? String == "source-only-proposals-frozen",
              g["sourceBasisUsedForEveryAngle"] as? Bool == true,
              g["footprintIsNotForeground"] as? Bool == true,
              g["compactAxisAmbiguous"] as? Bool == false,
              integer(g["nonopaqueBodySamples"]) == 0,
              let roots=integer(g["rootColourComponents"]),roots>=3,
              let rows=integer(g["rowCenters"]),rows>=8,
              let body=integer(g["realGGBodyPixels"]),body>=16,
              let support=integer(g["selectedActualPixels"]),support>=body,
              let row=number(g["rowAngle"]),let cc=number(g["ccAngle"]),
              let projection=number(g["projectionAngle"]),abs(row-cc)<=3,
              abs(row-projection)<=5,abs(cc-projection)<=5,
              !output.proposals.isEmpty,output.proposals.count<=8,
              let offered=integer(g["proposalCount"]),offered>=output.proposals.count,offered<=8 else { return nil }
        var best: (index: Int, score: Double, receipt: [String:Any])?
        for (index,p) in output.proposals.enumerated() {
            let r=p.receipt,q=p.polygon
            let unavailable=["body-touches-capture-edge-new-local-observation-required",
                "open-body-colour-component-extent-unresolved",
                "compact-glyph-axis-ambiguous-native-selection-required"]
            guard !p.obligations.contains(where:{unavailable.contains($0)}),
                  r["family"] as? String == "repair402-axis",
                  r["allFourBoundsRefitted"] as? Bool == true,
                  r["allSelectedPixelSquaresPreserved"] as? Bool == true,
                  r["sourceFootprintsUsedAsForeground"] as? Bool == false,
                  r["RLEHullFilled"] as? Bool == false,r["quadFilledAsInk"] as? Bool == false,
                  r["foregroundCompletenessClaimed"] as? Bool == false,
                  r["admissionGranted"] as? Bool == false,
                  integer(r["newlyExcludedOriginalGGBodyPixels"]) == 0,
                  integer(r["actualOuterPixelSquareSupportCount"]) == support,
                  let cellsLost=integer(r["newlyExcludedNativeCellCenters"]),
                  let outsideBody=integer(r["sourceGGBodyPixelsOutsideOld"]),outsideBody<=body,
                  let angle=number(r["angleDegreesRelativeToSource"]),
                  abs(angle-row)<=3,abs(angle-cc)<=3,abs(angle-projection)<=5,
                  let slopes=vector(r["independentNormalSideSlopes"],count:2),slopes.allSatisfy({abs($0)<=0.35}),
                  let normalBounds=vector(r["normalBounds"],count:2),normalBounds[1]>normalBounds[0],
                  let alongBounds=vector(r["alongBounds"],count:2),alongBounds[1]>alongBounds[0],
                  let detached=r["detachedAssociationWitnesses"] as? [[String:Any]],detached.isEmpty,
                  let ids=r["sourceSupportComponentIDs"] as? [Int],Set(ids).count==ids.count,ids.count>=roots,
                  let recordedOld=r["actualOld"] as? [[Double]],recordedOld.count==4,
                  (0..<4).allSatisfy({ i in
                      recordedOld[i].count==2 && recordedOld[i].allSatisfy(\.isFinite) &&
                      abs(recordedOld[i][0]-Double(actualOld[i].x))<=1e-6 &&
                      abs(recordedOld[i][1]-Double(actualOld[i].y))<=1e-6
                  }),
                  q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
                  let witnesses=r["edgeActualPixelWitnesses"] as? [[String:Any]],witnesses.count==4 else { continue }
            let turns=(0..<4).map { i -> CGFloat in
                let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4]
                return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
            }
            guard turns.allSatisfy({$0>1e-8}) || turns.allSatisfy({$0 < -1e-8}) else {continue}
            var witnessPixels=Set<Int>(),actualWitnesses=true
            for witness in witnesses {
                guard let pixel=integer(witness["actualLocalPixelIndex"]),
                      let center=vector(witness["center"],count:2),
                      let rgb=vector(witness["RGB"],count:3),rgb.allSatisfy({$0>=0 && $0<=255}),
                      witness["ownershipClaimed"] as? Bool == false,
                      K.contains(q,CGPoint(x:center[0],y:center[1])) else {actualWitnesses=false;break}
                witnessPixels.insert(pixel)
            }
            guard actualWitnesses,witnessPixels.count>=2 else {continue}
            // Changes are normalized to the actual source nativeW. Geometry is a
            // restraint term, never foreground or a substitute for source evidence.
            var movement=0.0
            for i in 0..<4 {
                let dx=q[i].x-actualOld[i].x,dy=q[i].y-actualOld[i].y
                let dn=abs(dx*basis.normal.x+dy*basis.normal.y)/nativeW
                let da=abs(dx*basis.along.x+dy*basis.along.y)/nativeW
                movement=max(movement,Double(max(dn,da)))
            }
            guard movement<=3 else {continue}
            let finiteCC=unit(Double(roots)/6)
            let occupiedRows=unit(Double(rows)/24)
            let pairAgreement=unit(1-abs(row-cc)/3)
            let candidateAgreement=unit(1-max(abs(angle-row),abs(angle-cc))/3)
            let projectionAgreement=unit(1-abs(angle-projection)/5)
            let agreement=(pairAgreement+candidateAgreement+projectionAgreement)/3
            let observedExtent=1.0 // four actual witnesses + all selected squares + zero body loss, checked above
            let restraint=unit(1-movement/3)
            let shearPenalty=0.04*unit(max(abs(slopes[0]),abs(slopes[1]))/0.35)
            // Native cells may contain background: loss is disclosed, not an ink
            // veto. No count-based completeness ratio is invented here.
            let footprintPenalty=cellsLost>0 ? 0.02:0
            let score=unit(0.20*finiteCC+0.15*occupiedRows+0.40*agreement+0.20*observedExtent+0.05*restraint-shearPenalty-footprintPenalty)
            guard score>=0.78 else {continue}
            let receipt: [String:Any]=[
                "family":"source-choice402-axis","sourceOnlyNomination":true,"index":index,
                "score":score,"scoreRange":[0.0,1.0],"minimumScore":0.78,
                "scoreMeaning":"bounded source evidence strength; not calibrated admission probability",
                "sourceComponents":["finiteBodyAnchoredCCCount":roots,"occupiedBodyRows":rows,
                    "realGGBodyPixels":body,"selectedActualPixelSquares":support,"actualExtentWitnesses":4,
                    "distinctWitnessPixels":witnessPixels.count,"newlyExcludedGGBodyPixels":0,
                    "originalBodyPixelsAlreadyOutsideOld":outsideBody,"rowDegrees":row,"ccDegrees":cc,
                    "projectionDegrees":projection,"candidateDegrees":angle],
                "normalizedTerms":["finiteCC":finiteCC,"occupiedRows":occupiedRows,
                    "rowCCProjectionAgreement":agreement,"selectedObservedExtentPreserved":observedExtent,
                    "sourceWidthMovementRestraint":restraint,"shearPenalty":shearPenalty,"footprintLossPenalty":footprintPenalty],
                "weights":["finiteCC":0.20,"occupiedRows":0.15,"agreement":0.40,"observedExtent":0.20,"restraint":0.05],
                "candidateNormalSideSlopes":slopes,"maximumCornerMovementNativeW":movement,
                "newlyExcludedNativeCellCenters":cellsLost,"nativeCellsAreForeground":false,
                "finiteRootCCClosureObserved":true,"allBodyCCClosureOrAssociationClaimed":false,
                "allSourceForegroundComplete":false,"outerRimAndPeerOwnershipProven":false,
                "detachedDetectorRFNominationsPresent":false,"actualOldBindingChecked":true,
                "actualOldEnclosed":actualOld.allSatisfy{K.contains(q,$0)},
                "remainingNativeObligations":p.obligations,"nativeAllGuardsStillRequired":true,
                "nativeAdmissionSuiteRun":false,"admissionGranted":false,"GTRead":false]
            // Stable original menu order breaks exact ties; no suffix/ID routing.
            if best == nil || score > best!.score+1e-12 { best=(index,score,receipt) }
        }
        return best
    }
}
