import Foundation
import CoreGraphics

// Geometry NOMINATIONS from408 actual sampled visual support. Unknown, model
// cells and GG bits are never promoted to foreground; native/409 owns admission.
enum NativeOCRFillBodyEnvelope410 {
    typealias K = NativeOCRSharedBoundary396
    typealias R = SourceContrastRole408
    typealias V = NativeOCRSourceShapeFeatures410
    static func generate(actualOld: [CGPoint], basis: K.Basis, nativeW: CGFloat,
                         evidence: K.Evidence, includeAA: Bool = false) -> K.Output {
        let observation = R.assess(evidence: evidence, basis: basis, nativeW: nativeW,
                                  seedMode: .originalNativeSupport)
        return generate(actualOld: actualOld, basis: basis, nativeW: nativeW,
                        evidence: evidence, roleObservation: observation, includeAA: includeAA)
    }
    static func generate(actualOld old: [CGPoint], basis f: K.Basis, nativeW mw: CGFloat,
                         evidence e: K.Evidence, roleObservation o: R.Output,
                         includeAA: Bool = false) -> K.Output {
        func none(_ status: String) -> K.Output {
            .init(proposals: [], receipt: ["family":"visual-body-envelope410","status":status,
                "sourceOnly":true,"ownershipClaimed":false,"admissionGranted":false])
        }
        guard old.count == 4, old.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              mw.isFinite, mw > 0, mw < 100_000,
              let samples = V.validatedSamples(basis: f, evidence: e, observation: o, includeAA: includeAA),
              samples.count >= 12, Set(samples.map(\.row)).count >= 3 else {
            return none("missing-actual408-visual-samples-or-valid-prior")
        }
        let turns = (0..<4).map { i -> CGFloat in
            let a=old[i],b=old[(i+1)%4],c=old[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        guard turns.allSatisfy({ $0 > 1e-8 }) || turns.allSatisfy({ $0 < -1e-8 }) else { return none("nonconvex-prior") }
        let r=e.rgba,w=r.width,h=r.height
        func world(_ i: Int) -> CGPoint { .init(x:r.origin.x+CGFloat(i%w)+0.5,y:r.origin.y+CGFloat(i/w)+0.5) }
        func project(_ p: CGPoint) -> CGPoint {
            let x=p.x-f.origin.x,y=p.y-f.origin.y
            return .init(x:x*f.normal.x+y*f.normal.y,y:x*f.along.x+y*f.along.y)
        }
        let nr=(abs(f.normal.x)+abs(f.normal.y))*0.5,ar=(abs(f.along.x)+abs(f.along.y))*0.5
        let points=samples.map { project($0.point) }
        let extrema=[points.indices.min{points[$0].x<points[$1].x}!,points.indices.max{points[$0].x<points[$1].x}!,
                     points.indices.min{points[$0].y<points[$1].y}!,points.indices.max{points[$0].y<points[$1].y}!]
        let bounds=[points[extrema[0]].x-nr,points[extrema[1]].x+nr,points[extrema[2]].y-ar,points[extrema[3]].y+ar]
        let oldP=old.map(project)
        let oldBounds=[oldP.map(\.x).min()!,oldP.map(\.x).max()!,oldP.map(\.y).min()!,oldP.map(\.y).max()!]
        let union=[min(bounds[0],oldBounds[0]),max(bounds[1],oldBounds[1]),min(bounds[2],oldBounds[2]),max(bounds[3],oldBounds[3])]
        let variants: [(String,[CGFloat])] = [
            ("measured-visual",bounds),
            ("prior-preserving-visual-expansion",union),
            ("normal-visual-old-along-union",[bounds[0],bounds[1],union[2],union[3]]),
            ("along-visual-old-normal-union",[union[0],union[1],bounds[2],bounds[3]])]
        func name(_ role: R.Role) -> String {
            switch role {
            case .fill: return "fill"
            case .unoutlinedPositive: return "unoutlinedPositive"
            case .stableRimCore: return "stableRimCore"
            case .aaTransition: return "aaTransition"
            default: return "not-visual-support"
            }
        }
        func proof(_ s: V.Sample) -> [String:Any] {
            let v=s.witness
            return ["actualLocalPixelIndex":s.index,"center":[Double(v.center.x),Double(v.center.y)],"RGB":v.rgb,
                "role408":Int(s.role.rawValue),"role408Name":name(s.role),"actual408RowIndex":s.row,
                "actual408ComponentID":s.component,"rootGGBody":v.rootGG,"actualNativeRootCell":v.actualNativeRootCell,
                "originalDetectorArrayPositions":v.detectorArrayPositions,
                "originalNativeRootDetectorArrayPositions":v.nativeRootDetectorArrayPositions,"RFArrayPositions":v.rfArrayPositions,
                "ownershipClaimed":false]
        }
        func runs(_ indices: [Int]) -> [[Int]] {
            var result:[[Int]]=[]
            for i in indices.sorted() {
                if let last=result.last,last[0]==i/w,last[1]+last[2]==i%w {result[result.count-1][2] += 1}
                else {result.append([i/w,i%w,1])}
            }
            return result
        }
        let fill=samples.filter{$0.role == .fill || $0.role == .unoutlinedPositive}
        let rim=samples.filter{$0.role == .stableRimCore},aa=samples.filter{$0.role == .aaTransition}
        var proposals:[K.Proposal]=[],seen=Set<String>(),outsideCapture=0
        for (variant,b) in variants {
            func restore(_ n:CGFloat,_ a:CGFloat)->CGPoint {
                .init(x:f.origin.x+n*f.normal.x+a*f.along.x,y:f.origin.y+n*f.normal.y+a*f.along.y)
            }
            let rectangle=[restore(b[0],b[2]),restore(b[1],b[2]),restore(b[1],b[3]),restore(b[0],b[3])]
            guard rectangle.allSatisfy({$0.x>=r.origin.x && $0.x<=r.origin.x+CGFloat(w) && $0.y>=r.origin.y && $0.y<=r.origin.y+CGFloat(h)})
            else {outsideCapture += 1;continue}
            var q=rectangle,cost=CGFloat.infinity
            for reversed in [false,true] {
                let z=reversed ? Array(rectangle.reversed()):rectangle
                for offset in 0..<4 {
                    let candidate=(0..<4).map{z[($0+offset)%4]}
                    let c=(0..<4).reduce(CGFloat(0)){sum,i in let dx=candidate[i].x-old[i].x,dy=candidate[i].y-old[i].y;return sum+dx*dx+dy*dy}
                    if c<cost {cost=c;q=candidate}
                }
            }
            let key=q.map{String(format:"%.8f,%.8f",Double($0.x),Double($0.y))}.joined(separator:";")
            guard seen.insert(key).inserted else {continue}
            let ggLoss=e.body.indices.filter{e.body[$0] != 0 && K.contains(old,world($0)) && !K.contains(q,world($0))}
            let nativeLoss=e.nativeCellCenters.filter{K.contains(old,$0) && !K.contains(q,$0)}
            let newVisual=samples.filter{!K.contains(old,$0.point) && K.contains(q,$0.point)}
            let unknownLoss=ggLoss.filter{o.role(atActualLocalPixelIndex:$0) == .unknown}
            let conflictLoss=ggLoss.filter{o.role(atActualLocalPixelIndex:$0) == .conflicting}
            let rec:[String:Any]=["family":"visual-body-envelope410","variant":variant,"roleObserver":"source-contrast-role408",
                "actualOld":old.map{[Double($0.x),Double($0.y)]},"actualOldEnclosed":old.allSatisfy{K.contains(q,$0)},
                "proposedSourcePlanes":b.map(Double.init),"measuredVisualSourcePlanes":bounds.map(Double.init),
                "sourcePlaneOrder":["normalLow","normalHigh","alongLow","alongHigh"],
                "sourceBasisUnchanged":true,"edgeActualPixelSquareSupport":extrema.map{proof(samples[$0])},
                "edgePlaneProvenance":(0..<4).map{b[$0]==bounds[$0] ? "actual408-visual-pixel-square":"actual-old-or-observed-visual-envelope"},
                "observedPositiveFillPixels":fill.count,"observedStableRimCorePixels":rim.count,"observedAAPixels":aa.count,
                "observedPositiveVisualPixels":samples.count,"allObservedVisualPixelSquaresEnclosed":true,"includeAA":includeAA,
                "newOutsideOldObservedVisualPixels":newVisual.count,"newObservedVisualWitnesses":newVisual.prefix(4).map(proof),
                "newlyExcludedOriginalGGBodyPixels":ggLoss.count,"newlyExcludedUnknownRoleGGBodyPixels":unknownLoss.count,
                "newlyExcludedConflictingRoleGGBodyPixels":conflictLoss.count,
                "GGBodyLossWitnessIndices":Array(ggLoss.prefix(8)),"newlyExcludedActualNativeCellCenters":nativeLoss.count,
                "nativeCellLossWitnesses":nativeLoss.prefix(4).map{[Double($0.x),Double($0.y)]},
                "nativeOrGGFallbackUsed":false,"unmeasuredPaddingUsed":false,"unknownPixelsPromoted":false,
                "observedRimCountsAsBodyFill":false,"roleEvidenceIsOwnership":false,
                "sourceCompletenessClaimed":false,"nativeAdmissionSuiteRun":false,"admissionGranted":false]
            var obligations=["actual-native-and409-typed-admission-required","all-member-whole-dense-GG-terminal-peer-gates-required",
                "observed-visual-envelope-is-not-source-completeness","unsampled-caption-head-tail-and-detached-marks-unresolved",
                "no-erasure-or-ownership-authority","new-peer-foreign-acquisition-check-required"]
            if !ggLoss.isEmpty || !nativeLoss.isEmpty {obligations.append("actual-source-support-loss-observed-native-verdict-required")}
            proposals.append(.init(suffix:"visual-envelope410-"+variant,polygon:q,receipt:rec,obligations:obligations))
        }
        return .init(proposals:proposals,receipt:["family":"visual-body-envelope410","status":"actual408-visual-envelopes-only",
            "proposalCount":proposals.count,"maximumProposals":4,"maximumContractProposals":8,
            "role408Observation":o.receipt,"observedPositiveFillActualRuns":runs(fill.map(\.index)),
            "observedStableRimActualRuns":runs(rim.map(\.index)),"observedAAActualRuns":runs(aa.map(\.index)),
            "observedVisualActualRuns":runs(samples.map(\.index)),"visualPointWitnessCount":samples.count,
            "sourceRows":Set(samples.map(\.row)).count,"sourceComponents":Set(samples.map(\.component)).count,
            "includeAA":includeAA,"rejectedOutOfCaptureGeometry":outsideCapture,"unknownPixelsPromoted":false,
            "nativeOrGGFallbackUsed":false,"ownershipClaimed":false,"sourceCompletenessClaimed":false,
            "GTRead":false,"admissionGranted":false])
    }
}
