import Foundation
import CoreGraphics

/// <=8 source-derived inward normal hypotheses. Original cap edge planes stay
/// exact; point qualification401 and all original native gates are separate.
enum NativeOCRRepair402Normal {
    typealias K = NativeOCRSharedBoundary396
    static func generate(actualOld old:[CGPoint],basis:K.Basis,nativeW:CGFloat,evidence:K.Evidence)->K.Output {
        let shared=K.generate(actualOld:old,basis:basis,nativeW:nativeW,evidence:evidence)
        guard old.count==4 else{return .init(proposals:[],receipt:["status":"invalid-actual-old","admissionGranted":false])}
        func area(_ q:[CGPoint])->CGFloat {abs((0..<4).reduce(CGFloat(0)){v,i in let a=q[i],b=q[(i+1)%4];return v+a.x*b.y-a.y*b.x})*0.5}
        func parallelAlong(_ edge:Int)->CGFloat {let a=old[edge],b=old[(edge+1)%4],dx=b.x-a.x,dy=b.y-a.y;return abs(dx*basis.along.x+dy*basis.along.y)/max(1e-9,hypot(dx,dy))}
        let sides=parallelAlong(0)+parallelAlong(2)>parallelAlong(1)+parallelAlong(3) ? [0,2]:[1,3]
        let caps=(0..<4).filter{!sides.contains($0)}
        func edgeDistance(_ edge:Int,_ point:CGPoint)->CGFloat {let a=old[edge],b=old[(edge+1)%4];return ((b.x-a.x)*(point.y-a.y)-(b.y-a.y)*(point.x-a.x))/max(1e-9,hypot(b.x-a.x,b.y-a.y))}
        var best:[Int:K.Proposal]=[:]
        for p in shared.proposals {
            let q=p.polygon
            guard q.count==4,q.allSatisfy({K.contains(old,$0)}),area(q)<area(old)-0.25,
                caps.allSatisfy({edge in abs(edgeDistance(edge,q[edge]))<1e-6 && abs(edgeDistance(edge,q[(edge+1)%4]))<1e-6}) else{continue}
            var mask=0
            for (ordinal,edge) in sides.enumerated() where abs(edgeDistance(edge,q[edge]))>0.25 {mask |= 1 << ordinal}
            guard mask>0 else{continue}
            if best[mask]==nil || area(q)<area(best[mask]!.polygon){best[mask]=p}
        }
        var proposals:[K.Proposal]=[],seen=Set<String>()
        for mask in [1,2,3] {
            guard let base=best[mask] else{continue}
            let fractions:[CGFloat]=mask==3 ? [0.25,0.5,0.75,1]:[0.5,1]
            for fraction in fractions {
                let q=(0..<4).map{i in CGPoint(x:old[i].x+(base.polygon[i].x-old[i].x)*fraction,y:old[i].y+(base.polygon[i].y-old[i].y)*fraction)}
                let key=q.map{String(format:"%.7f,%.7f",Double($0.x),Double($0.y))}.joined(separator:";")
                guard seen.insert(key).inserted else{continue}
                var lostGG:[Int]=[]
                let r=evidence.rgba
                for i in evidence.body.indices where evidence.body[i] != 0 {
                    let p=CGPoint(x:r.origin.x+CGFloat(i%r.width)+0.5,y:r.origin.y+CGFloat(i/r.width)+0.5)
                    if K.contains(old,p) && !K.contains(q,p){lostGG.append(i)}
                }
                let nativeLoss=evidence.nativeCellCenters.filter{K.contains(old,$0) && !K.contains(q,$0)}
                var rec=base.receipt
                rec["family"]="repair402-normal-contraction";rec["source396BaseKey"]=base.suffix
                rec["source396BaseGeometry"]=base.polygon.map{[Double($0.x),Double($0.y)]}
                rec["normalContractionFraction"]=Double(fraction);rec["normalSideMask"]=mask
                rec["originalHeadTailEdgePlanesExact"]=true;rec["noAlongContraction"]=true
                rec["actualRootGGNewlyExcludedPixels"]=lostGG.count
                rec["actualNativeCellCentersNewlyExcluded"]=nativeLoss.count
                rec["GGPixelLossWitnessIndices"]=Array(lostGG.prefix(8))
                rec["nativeCellGeometryIsForeground"]=false;rec["mandatoryPointQualification401Required"]=true
                rec["baseSourceSupportOmissionsMustBeRecheckedAfterInterpolation"]=true
                rec["actual386PriorEnclosed"]=old.allSatisfy{K.contains(q,$0)}
                rec["wholeDenseGGAndAllMemberSemanticForeignGatesRequired"]=true
                rec["admissionGranted"]=false
                proposals.append(.init(suffix:"normal-contraction-side\(mask)-f\(Int(fraction*100))",polygon:q,receipt:rec,
                    obligations:["typed-point-obligation401-preflight-required","actual-root-and-all-members-whole-dense-GG-required",
                        "original-explicit-caps-and-real-glyph-quote-diacritic-preservation-required","semantic-foreign-ownership-gates-required"]))
            }
        }
        return .init(proposals:proposals,receipt:["family":"repair402-normal-contraction","status":"source-derived-normal-hypotheses",
            "source396Observation":shared.receipt,"candidateCount":proposals.count,"maximumCandidates":8,
            "headTailCapPlanesPreserved":true,"actualNativeGateRun":false,"admissionGranted":false])
    }
}
