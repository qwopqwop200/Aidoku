import Foundation
import CoreGraphics

/// Source-only veto BEFORE nomination/native assessment; not admission.
/// No dependency on the application, selector, model, GT, IDs, keys, or hashes.
enum SourceChoice402CommonGuard {
    struct Decision {
        let allowed: Bool
        let reasons: [String]
        let receipt: [String:Any]
    }
    struct Limits {
        // Provisional conservative source tolerances, NOT GT correctness bounds.
        var maximumAxisResidual: Double = 0.05
        var maximumPlaneMovementWidths: Double = 0.25
        var maximumAreaRatio: Double = 1.35
        var minimumNewBodyPixels: Double = 8
        var minimumNewBodyAreaDensity: Double = 0.05
    }
    private static func number(_ v: Any?) -> Double? {
        guard let v=v,!(v is NSNull) else{return nil}
        if let d=v as? NSNumber,d.doubleValue.isFinite{return d.doubleValue};return nil
    }
    private static func vector(_ v: Any?,count: Int) -> [Double]? {
        guard let a=v as? [Any],a.count==count else{return nil}
        let n=a.compactMap{number($0)};return n.count==count ? n:nil
    }
    private static func points(_ v: Any?) -> [CGPoint]? {
        guard let a=v as? [Any],a.count==4 else{return nil}
        var q:[CGPoint]=[]
        for item in a {
            if let p=item as? CGPoint,p.x.isFinite,p.y.isFinite {q.append(p)}
            else if let xy=vector(item,count:2) {q.append(CGPoint(x:xy[0],y:xy[1]))}
            else if let p=item as? [String:Any],let x=number(p["x"]),let y=number(p["y"]) {q.append(CGPoint(x:x,y:y))}
            else {return nil}
        }
        return q
    }
    private static func area(_ q:[CGPoint]) -> Double {
        // Translate before shoelace to avoid cancellation at large image origins.
        let o=q[0]
        return abs((0..<4).reduce(0.0) { sum,i in
            let a=q[i],b=q[(i+1)%4]
            return sum+Double((a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x))
        })*0.5
    }
    private static func convex(_ q:[CGPoint]) -> Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return false}
        let t=(0..<4).map { i -> CGFloat in
            let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        return t.allSatisfy({$0>1e-8}) || t.allSatisfy({$0 < -1e-8})
    }
    private static func contains(_ q:[CGPoint],_ p:CGPoint) -> Bool {
        var positive=false,negative=false
        for i in 0..<4 {
            let a=q[i],b=q[(i+1)%4],z=(b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
            positive = positive || z>1e-6;negative = negative || z < -1e-6
        }
        return !positive || !negative
    }
    static func allows(rawOffer:[String:Any], actualPrior:[CGPoint],
                       sourceFeaturePrefix:[Double], nativeW:CGFloat) -> Bool {
        evaluate(rawOffer:rawOffer,actualPrior:actualPrior,
                 sourceFeaturePrefix:sourceFeaturePrefix,nativeW:nativeW).allowed
    }
    static func evaluate(rawOffer:[String:Any], actualPrior old:[CGPoint],
                         sourceFeaturePrefix f:[Double], nativeW:CGFloat,
                         limits:Limits = Limits()) -> Decision {
        var reasons:[String]=[],features:[String:Any]=[:]
        func finish() -> Decision {
            .init(allowed:reasons.isEmpty,reasons:reasons,receipt:[
                "family":"source-choice402-common-guard","allowed":reasons.isEmpty,"reasons":reasons,
                "sourceFeatures":features,"oldAlreadyGoodKnown":false,"GTRead":false,
                "sourceNominationOnly":true,"allForegroundComplete":false,
                "nativeAllGuardsStillRequired":true,"admissionGranted":false,
                "thresholdValidationScope":"provisional 8-page observed-output diagnostics; full126 and actual matching still required"])
        }
        guard convex(old),nativeW.isFinite,nativeW>0,nativeW<100_000,
              f.count>=10,f.prefix(10).allSatisfy(\.isFinite),f[7]>=0,
              let r=rawOffer["sourceReceipt"] as? [String:Any],
              let q=points(rawOffer["polygon"]),convex(q),
              let bound=points(r["actualOld"] ?? r["actual386Old"] ?? r["actualCurrentPrior"]),
              zip(bound,old).allSatisfy({hypot($0.0.x-$0.1.x,$0.0.y-$0.1.y)<1e-6}),
              let reported=vector(r["signedEdgePlaneChanges"],count:4),
              let loss=number(r["newlyExcludedOriginalGGBodyPixels"]) else {
            reasons.append("missing-or-unbound-actual-source-geometry-and-loss-receipt");return finish()
        }
        let raw=r["rawProducerReceipt"] as? [String:Any] ?? r
        features["axisResidual"]=f[7];features["hasInkProof"]=f[9]
        if f[9] != 1 {reasons.append("missing-source-ink-proof")}
        if f[7]>limits.maximumAxisResidual {reasons.append("source-axis-fit-insufficient-for-edge-extrema-refit")}
        if loss != 0 {reasons.append("recorded-original-GG-body-loss")}
        // These counts are uncertainty vetoes, never a claim cells are ink.
        for key in ["newlyExcludedActualNativeCellCenters","newlyExcludedOriginalNativeCellCenters","newlyExcludedActualFootprintPixels"] {
            if let value=number(r[key] ?? raw[key]),value>0 {reasons.append("unresolved-original-support-loss")}
        }
        let oldArea=area(old),newArea=area(q)
        guard oldArea>0,newArea.isFinite,newArea>0 else {reasons.append("invalid-local-quad-area");return finish()}
        let ratio=newArea/oldArea;features["areaRatio"]=ratio
        if ratio < 1-1e-6 {reasons.append("net-contraction-lacks-authenticated-erased-region-background")}
        if ratio>limits.maximumAreaRatio {reasons.append("large-acquisition-not-justified-by-local-nomination")}
        let turn=(old[1].x-old[0].x)*(old[2].y-old[1].y)-(old[1].y-old[0].y)*(old[2].x-old[1].x)
        let ccw=turn>0,epsilon=max(1e-5,Double(nativeW)*1e-6)
        var normals:[CGPoint]=[],planes:[Double]=[],changes:[Double]=[]
        for edge in 0..<4 {
            let a=old[edge],b=old[(edge+1)%4],dx=b.x-a.x,dy=b.y-a.y,len=hypot(dx,dy)
            let n=ccw ? CGPoint(x:dy/len,y:-dx/len):CGPoint(x:-dy/len,y:dx/len)
            let oldPlane=Double(n.x*a.x+n.y*a.y),newPlane=Double(n.x*q[edge].x+n.y*q[edge].y)
            normals.append(n);planes.append(newPlane);changes.append(newPlane-oldPlane)
            if abs(Double(n.x*q[(edge+1)%4].x+n.y*q[(edge+1)%4].y)-newPlane)>epsilon || abs(changes[edge]-reported[edge])>epsilon {
                reasons.append("axis-or-corner-order-changed-without-compatible-plane-evidence")
            }
        }
        let moved=(0..<4).filter{abs(changes[$0])>0.25}
        let outward=moved.filter{changes[$0]>0},inward=moved.filter{changes[$0]<0}
        features["changedEdges"]=moved;features["outwardEdges"]=outward;features["inwardEdges"]=inward
        features["signedPlaneChangesNativeW"]=changes.map{$0/Double(nativeW)}
        if outward.isEmpty {reasons.append("no-source-supported-outside-old-recovery")}
        if changes.contains(where:{abs($0)/Double(nativeW)>limits.maximumPlaneMovementWidths}) {reasons.append("plane-movement-exceeds-local-source-width-budget")}
        // Every CHANGED plane requires a direct actual root GG body pixel square.
        // Colour-only CCs, contour colours and mask membership cannot substitute.
        let edgeRecords=(r["edgeActualSupport"] ?? raw["edgeActualSupport"] ?? raw["actualEdgePixelCellSupport"]) as? [[String:Any]]
        var outwardActualBodyEdges=0,verifiedEdges:[Int]=[]
        for edge in moved {
            guard let records=edgeRecords,records.count==4 else {reasons.append("missing-four-edge-direct-body-witness-array");break}
            let witness=records[edge]
            guard witness["rootGGBody"] as? Bool == true,
                  let pixel=number(witness["actualLocalPixelIndex"]),pixel>=0,pixel<600_000,pixel.rounded()==pixel,
                  let xy=vector(witness["center"],count:2),
                  let rgb=vector(witness["RGB"],count:3),rgb.allSatisfy({$0>=0 && $0<=255 && $0.rounded()==$0}) else {
                reasons.append("changed-plane-extremum-is-not-direct-actual-GG-body");continue
            }
            let p=CGPoint(x:xy[0],y:xy[1]),n=normals[edge]
            let squarePlane=Double(n.x*p.x+n.y*p.y+(abs(n.x)+abs(n.y))*0.5)
            guard contains(q,p),abs(squarePlane-planes[edge])<=epsilon else {
                reasons.append("changed-plane-does-not-match-actual-body-pixel-square");continue
            }
            verifiedEdges.append(edge)
            if changes[edge]>0 && !contains(old,p) {outwardActualBodyEdges += 1}
        }
        features["verifiedDirectBodyEdges"]=verifiedEdges
        features["newOutsideOldBodyExtremeEdges"]=outwardActualBodyEdges
        if inward.isEmpty {
            let recovered=number(r["previouslyOutsideOldGGBodyNowIncluded"] ?? raw["previouslyOutsideOldGGBodyNowIncluded"])
            let acquiredArea=max(0,newArea-oldArea)
            let density=(recovered ?? 0)/max(1,acquiredArea)
            features["newGGBodyPixelsCountAvailable"]=recovered != nil
            features["newGGBodyAreaDensity"]=density
            guard let count=recovered,count.rounded()==count,count>=limits.minimumNewBodyPixels,
                  density>=limits.minimumNewBodyAreaDensity else {
                reasons.append("expansion-lacks-quantified-substantial-new-GG-body-recovery");return finish()
            }
        } else {
            // A mixed refit may recover side undercoverage while removing cap
            // slack. Multiple newly outside-old direct body planes must justify
            // that trade; GG-loss zero alone does not establish old completeness.
            if outwardActualBodyEdges<2 {reasons.append("mixed-refit-lacks-multiple-new-direct-body-planes")}
            if number(raw["newlyExcludedActualFootprintPixels"]) != 0 || number(raw["newlyExcludedOriginalNativeCellCenters"]) != 0 {
                reasons.append("mixed-refit-original-support-retention-not-explicit")
            }
        }
        return finish()
    }
}
