import Foundation
import CoreGraphics

/// Source proposals only. Four independently measured levels; no GT or ownership inference.
enum NativeOCRIndependentBoundaryLevels {
    typealias K = NativeOCRSharedBoundary396
    enum Control: String {
        case scalarOld = "scalar-old"
        case rgbContact = "RGB-contact"
        case ggBody = "GG-body"
        case nativeBasis3 = "native-basis-three-orientations"
    }
    static let maximumOffers = 48 // <=3 observed bases * 2^4 independent side choices.
    private struct Frame { let name:String;let normal:CGPoint;let along:CGPoint }
    private struct Level {let value:CGFloat;let source:String;let witness:[String:Any]}

    static func generate(actualOld old:[CGPoint],basis f:K.Basis,nativeW:CGFloat,
        evidence e:K.Evidence, control: Control = .nativeBasis3,
        closedRGBObservation: K.Output? = nil) -> K.Output {
        func none(_ reason:String)->K.Output {
            .init(proposals:[],receipt:["family":"source-independent-boundary-levels","status":reason,
                "sourceOnly":true,"GTRead":false,"admissionGranted":false])
        }
        let r=e.rgba,w=r.width,h=r.height
        guard w>2,h>2,w<=600_000/h,r.bytesPerRow>=w*4,h<=Int.max/r.bytesPerRow,
              r.bytes.count==h*r.bytesPerRow,e.body.count==w*h,valid(old),
              r.origin.x.isFinite,r.origin.y.isFinite,
              nativeW.isFinite,nativeW>0,nativeW<100_000,
              [f.origin,f.normal,f.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              abs(hypot(f.normal.x,f.normal.y)-1)<1e-6,
              abs(hypot(f.along.x,f.along.y)-1)<1e-6,
              abs(f.normal.x*f.along.x+f.normal.y*f.along.y)<1e-6 else {return none("invalid-actual-source-session")}
        func world(_ i:Int)->CGPoint {.init(x:r.origin.x+CGFloat(i%w)+0.5,y:r.origin.y+CGFloat(i/w)+0.5)}
        func dot(_ p:CGPoint,_ v:CGPoint)->CGFloat {(p.x-f.origin.x)*v.x+(p.y-f.origin.y)*v.y}
        func opaque(_ i:Int)->Bool {r.bytes[(i/w)*r.bytesPerRow+(i%w)*4+3]==255}
        let body=e.body.indices.filter{e.body[$0] != 0 && opaque($0)}
        let anchors=body.filter{K.contains(old,world($0)) && e.privateAt(world($0))}
        guard anchors.count>=2 else {return none("no-actual-private-root-GG-anchors")}
        if control == .scalarOld {
            return .init(proposals:[.init(suffix:"scalar-old-control",polygon:old,
                receipt:["family":"source-independent-boundary-levels","control":control.rawValue,
                    "actualCurrentPrior":old.map{[Double($0.x),Double($0.y)]},"admissionGranted":false,
                    "scalarOldNotPixelSupport":true,"sourceOnly":true],
                obligations:["actual-native-readmission-required","scalar-old-control-not-admission"])],
                receipt:["family":"source-independent-boundary-levels","control":control.rawValue,
                    "proposals":1,"sourceOnly":true,"GTRead":false,"admissionGranted":false])
        }
        // This existing pure source observer supplies ONLY actual closed RGB CC RUNS.
        // Its proposed polygons never become ink or side-level supports.
        let observed:K.Output = control == .ggBody ? .init(proposals:[],receipt:["status":"GG-only-control-no-RGB-CC-observer"]) :
            (closedRGBObservation ?? K.generate(actualOld:old,basis:f,nativeW:nativeW,evidence:e))
        let cc=observed.receipt["sourceSupportComponents"] as? [[String:Any]] ?? []
        var rootCells=Set<Int>(),contactCells=Set<Int>()
        for c in cc {
            guard c["originalRGBCCClippedAtCapture"] as? Bool == false,
                  let runs=c["actualLocalRunsYXCount"] as? [[Int]] else {continue}
            var cells:[Int]=[]
            for run in runs {
                guard run.count==3,run[0]>=0,run[0]<h,run[1]>=0,run[2]>0,run[2]<=w-run[1] else {
                    return none("invalid-observer-source-pixel-runs")
                }
                for x in run[1]..<(run[1]+run[2]) {cells.append(run[0]*w+x)}
            }
            contactCells.formUnion(cells)
            if (c["actualRootPrivateBodyAnchors"] as? Int ?? 0)>=2 {rootCells.formUnion(cells)}
        }
        var groups:[(String,[Int])]=[]
        if control != .ggBody && !rootCells.isEmpty {groups.append(("closed-root-private-GG-anchored-RGB-CC",rootCells.sorted()))}
        if control != .ggBody && !contactCells.isEmpty {groups.append(("observed-root-contact-and-source-chain-CC",contactCells.sorted()))}
        if control != .rgbContact {groups.append(("actual-root-GG-body",body))}
        guard !groups.isEmpty else {return none("requested-control-has-no-observed-source-support")}
        var frames=[Frame(name:"actual-source-basis",normal:f.normal,along:f.along)]
        func appendFrame(_ frame:Frame) {
            // Sign-insensitive geometry identity. No horizontal/vertical shortcut.
            if !frames.contains(where:{abs($0.normal.x*frame.normal.x+$0.normal.y*frame.normal.y)>1-1e-10}) {frames.append(frame)}
        }
        // Actual retained directions are a geometric hypothesis, never source ink.
        var longestEdge: Int = 0
        var longestLength: CGFloat = -1
        for index in 0..<4 {
            let nextIndex: Int = (index + 1) % 4
            let dx: CGFloat = old[nextIndex].x - old[index].x
            let dy: CGFloat = old[nextIndex].y - old[index].y
            let edgeLength: CGFloat = hypot(dx, dy)
            if edgeLength > longestLength {
                longestLength = edgeLength
                longestEdge = index
            }
        }
        do {
            let nextIndex: Int = (longestEdge + 1) % 4
            let dx: CGFloat = old[nextIndex].x - old[longestEdge].x
            let dy: CGFloat = old[nextIndex].y - old[longestEdge].y
            var a = CGPoint(x: dx / longestLength, y: dy / longestLength)
            if a.x*f.along.x+a.y*f.along.y<0 {a=CGPoint(x:-a.x,y:-a.y)}
            let handed=f.normal.x*f.along.y-f.normal.y*f.along.x
            appendFrame(.init(name:"actual-retained-long-edge",normal:CGPoint(x:handed*a.y,y:-handed*a.x),along:a))
        }
        var angleConfidence=CGFloat(0)
        if anchors.count>=8 {
            let points=anchors.map{CGPoint(x:dot(world($0),f.normal),y:dot(world($0),f.along))}
            let mean=points.reduce(CGPoint.zero){.init(x:$0.x+$1.x,y:$0.y+$1.y)}
            let mn=mean.x/CGFloat(points.count),ma=mean.y/CGFloat(points.count)
            var nn:CGFloat=0,aa:CGFloat=0,na:CGFloat=0
            for p in points {let n=p.x-mn,a=p.y-ma;nn+=n*n;aa+=a*a;na+=n*a}
            angleConfidence=hypot(aa-nn,2*na)/max(1,aa+nn)
            if angleConfidence>=0.2 {
                let angle=atan2(2*na,aa-nn)*0.5,c=cos(angle),s=sin(angle)
                appendFrame(.init(name:"actual-private-GG-covariance-consensus",
                    normal:.init(x:f.normal.x*c-f.along.x*s,y:f.normal.y*c-f.along.y*s),
                    along:.init(x:f.normal.x*s+f.along.x*c,y:f.normal.y*s+f.along.y*c)))
            }
        }
        var offers:[K.Proposal]=[],seen=Set<String>(),frameReceipts:[[String:Any]]=[]
        for frame in frames.prefix(3) {
            let vectors=[frame.normal,frame.along]
            var levels=[[Level]](repeating:[],count:4)
            for (source,cells) in groups {
                for axis in 0..<2 {
                    let v=vectors[axis],radius=(abs(v.x)+abs(v.y))*0.5
                    for upper in [false,true] {
                        let side=axis*2+(upper ? 1:0)
                        guard let i=cells.min(by:{lhs,rhs in
                            let a=dot(world(lhs),v),b=dot(world(rhs),v)
                            return upper ? a>b:a<b
                        }) else {continue}
                        let p=world(i),value=dot(p,v)+(upper ? radius:-radius)
                        if levels[side].count<2 && !levels[side].contains(where:{abs($0.value-value)<1e-6}) {
                            let k=(i/w)*r.bytesPerRow+(i%w)*4
                            levels[side].append(.init(value:value,source:source,witness:["actualLocalPixelIndex":i,
                                "center":[Double(p.x),Double(p.y)],"RGBA":Array(r.bytes[k..<(k+4)]).map{Int($0)},
                                "rootGGBody":e.body[i] != 0,"actualNativeCell":e.privateAt(p),
                                "pixelCellProjectionRadius":Double(radius),"ownershipClaimed":false]))
                        }
                    }
                }
            }
            guard levels.allSatisfy({!$0.isEmpty}) else {continue}
            frameReceipts.append(["name":frame.name,"normal":[Double(frame.normal.x),Double(frame.normal.y)],
                "along":[Double(frame.along.x),Double(frame.along.y)],"independentSideLevelCounts":levels.map{$0.count}])
            for bits in 0..<16 {
                let selected=(0..<4).map{side in levels[side][min(levels[side].count-1,(bits>>side)&1)]}
                let n0=selected[0].value,n1=selected[1].value,a0=selected[2].value,a1=selected[3].value
                guard n1>n0,a1>a0 else {continue}
                func restore(_ n:CGFloat,_ a:CGFloat)->CGPoint {
                    .init(x:f.origin.x+n*frame.normal.x+a*frame.along.x,y:f.origin.y+n*frame.normal.y+a*frame.along.y)
                }
                let q=[restore(n0,a0),restore(n1,a0),restore(n1,a1),restore(n0,a1)]
                guard valid(q),q.allSatisfy({$0.x>=r.origin.x && $0.y>=r.origin.y && $0.x<=r.origin.x+CGFloat(w) && $0.y<=r.origin.y+CGFloat(h)}) else {continue}
                let identity=q.map{String(Double($0.x).bitPattern,radix:16)+","+String(Double($0.y).bitPattern,radix:16)}.joined(separator:";")
                guard seen.insert(identity).inserted else {continue}
                let bodyLoss=body.filter{K.contains(old,world($0)) && !K.contains(q,world($0))}.count
                let nativeLoss=e.nativeCellCenters.filter{K.contains(old,$0) && !K.contains(q,$0)}.count
                let receipt:[String:Any]=["family":"source-independent-boundary-levels","actualCurrentPrior":old.map{[Double($0.x),Double($0.y)]},
                    "control":control.rawValue,"basisSource":frame.name,"sideBits":bits,"independentObservedLevels":selected.map{Double($0.value)},
                    "sideLevelSources":selected.map{$0.source},"sideWitnesses":selected.map{$0.witness},
                    "actualInputPriorEnclosed":old.allSatisfy{K.contains(q,$0)},"newlyExcludedOriginalGGBodyPixels":bodyLoss,
                    "newlyExcludedActualNativeCellCenters":nativeLoss,"wholeRFOrDetectorPolygonForced":false,
                    "detachedAssociationProven":false,"allSourceSupportObserved":false,"admissionGranted":false,
                    "sourceOnly":true,"GTRead":false,"ownershipChanged":false,"nativeAdmissionSuiteRun":false]
                offers.append(.init(suffix:frame.name+"-sidebits"+String(bits),polygon:q,receipt:receipt,
                    obligations:["all-member-semantic-cap-whole-dense-GG-readmission-required",
                        "independent-side-mixture-source-association-unproven","peer-foreign-new-acquisition-required",
                        "partial-source-observation-not-completeness","no-erasure-authority"]))
            }
        }
        return .init(proposals:offers,receipt:["family":"source-independent-boundary-levels","sourceOnly":true,"GTRead":false,"control":control.rawValue,
            "status":"independent-actual-source-side-level-cartesian-hypotheses","maximumOffers":maximumOffers,
            "proposals":offers.count,"frames":frameReceipts,"anchorPixels":anchors.count,"PCAAnisotropy":Double(angleConfidence),
            "closedRGBObservationReused":closedRGBObservation != nil && control != .ggBody,
            "observedRootRGBCells":rootCells.count,"observedContactChainRGBCells":contactCells.count,
            "sourceObservation":observed.receipt,"allAnglesSameAlgorithm":true,"candidateQuadUsedAsInk":false,
            "allSourceSupportObserved":false,"actualInputPriorAndGraphUnchanged":true,"ownershipChanged":false,
            "admissionGranted":false,"nativeAdmissionSuiteRun":false])
    }
    private static func valid(_ q:[CGPoint])->Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {return false}
        let c=(0..<4).map{i -> CGFloat in let a=q[i],b=q[(i+1)%4],d=q[(i+2)%4];return (b.x-a.x)*(d.y-b.y)-(b.y-a.y)*(d.x-b.x)}
        return c.allSatisfy{$0>1e-8} || c.allSatisfy{$0 < -1e-8}
    }
}
