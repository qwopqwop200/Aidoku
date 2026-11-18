import Foundation
import CoreGraphics

/// Native model geometry ONLY. No RGB/GG classifier, ink mask or admission.
enum NativeOCRModelSupportEnvelope407 {
    typealias K = NativeOCRSharedBoundary396
    private struct Support {
        let center:CGPoint
        let halfX:CGFloat,halfY:CGFloat
        let nativeIndex:Int // >=0: genuine original native center, cell size unknown
        let detector:Int,cellX:Int,cellY:Int // >=0: original nativeRoot RLE cell
        let n:CGFloat,a:CGFloat
    }
    private struct Key:Hashable {let x:UInt64,y:UInt64}
    private struct Fit {let name:String;let radians:CGFloat;let credibility:Double}
    private struct Envelope {let b:[CGFloat];let witness:[Int]}
    static func generate(actualOld old:[CGPoint],basis f:K.Basis,nativeW mw:CGFloat,evidence e:K.Evidence) -> K.Output {
        func none(_ reason:String) -> K.Output {
            .init(proposals:[],receipt:["family":"model-support-envelope407","status":reason,
                "modelGeometryOnly":true,"modelSupportIsForeground":false,"admissionGranted":false,"GTRead":false])
        }
        let r=e.rgba,w=r.width,h=r.height
        guard w>0,h>0,w<=600_000/h,w<=Int.max/4,r.bytesPerRow>=w*4,
              h<=Int.max/r.bytesPerRow,r.bytes.count==h*r.bytesPerRow,e.body.count==w*h,
              old.count==4,old.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              [r.origin,f.origin,f.normal,f.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              mw.isFinite,mw>0,mw<100_000,abs(hypot(f.normal.x,f.normal.y)-1)<1e-6,
              abs(hypot(f.along.x,f.along.y)-1)<1e-6,abs(f.normal.x*f.along.x+f.normal.y*f.along.y)<1e-6,
              e.nativeCellCenters.count<=200_000,e.nativeCellCenters.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              e.detectors.count<=64,e.rf.count<=160,
              e.rf.allSatisfy({$0.bounds.count==4 && $0.bounds.allSatisfy(\.isFinite) && $0.confidence.isFinite}) else{return none("invalid-or-over-budget-captured-model-session")}
        let turns=(0..<4).map { i -> CGFloat in
            let a=old[i],b=old[(i+1)%4],c=old[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        guard turns.allSatisfy({$0>1e-8}) || turns.allSatisfy({$0 < -1e-8}) else{return none("invalid-actual-old-convexity")}
        func project(_ p:CGPoint) -> CGPoint {
            let x=p.x-f.origin.x,y=p.y-f.origin.y
            return CGPoint(x:x*f.normal.x+y*f.normal.y,y:x*f.along.x+y*f.along.y)
        }
        func inCapture(_ p:CGPoint) -> Bool {p.x>=r.origin.x && p.x<=r.origin.x+CGFloat(w) && p.y>=r.origin.y && p.y<=r.origin.y+CGFloat(h)}
        var support:[Support]=[],unique=Set<Key>(),fitCenters:[CGPoint]=[]
        func append(_ p:CGPoint,_ hx:CGFloat,_ hy:CGFloat,_ ni:Int,_ di:Int,_ x:Int,_ y:Int) {
            let q=project(p)
            support.append(.init(center:p,halfX:hx,halfY:hy,nativeIndex:ni,detector:di,cellX:x,cellY:y,n:q.x,a:q.y))
            let key=Key(x:Double(p.x).bitPattern,y:Double(p.y).bitPattern)
            if unique.insert(key).inserted {fitCenters.append(q)}
        }
        // Consume the FULL supplied native packet before any ROI tests. The API
        // has no native cell scale: NEVER infer one from point spacing or nativeW.
        for (index,p) in e.nativeCellCenters.enumerated() {append(p,0,0,index,-1,-1,-1)}
        var gridQueries=0,packets:[[String:Any]]=[],missingPackets=0,exactCells=0
        let gridBudget=2_000_000,supportBudget=200_000
        for (position,d) in e.detectors.enumerated() where d.nativeRoot {
            let cells=d.cells,remaining=gridBudget-gridQueries
            //396 keeps sparse rows private. Enumerate the actual model lattice
            // with its membership predicate; never reconstruct/fill its hull.
            guard cells.height<=remaining,cells.width<=remaining/cells.height else {
                missingPackets += 1
                packets.append(["detectorArrayPosition":position,"status":"full-packet-enumeration-budget-unavailable","scale":[Double(cells.scaleX),Double(cells.scaleY)],"complete":false]);continue
            }
            var packet:[(CGPoint,Int,Int)]=[],overflow=false
            for y in 0..<cells.height {
                for x in 0..<cells.width {
                    gridQueries += 1
                    let p=CGPoint(x:(CGFloat(x)+0.5)*cells.scaleX,y:(CGFloat(y)+0.5)*cells.scaleY)
                    if cells.contains(p) {
                        if support.count+packet.count<supportBudget {packet.append((p,x,y))}
                        else {overflow=true}
                    }
                }
            }
            guard !overflow else {
                missingPackets += 1
                packets.append(["detectorArrayPosition":position,"status":"whole-packet-omitted-support-budget","complete":false]);continue
            }
            for (p,x,y) in packet {append(p,cells.scaleX*0.5,cells.scaleY*0.5,-1,position,x,y)}
            exactCells += packet.count
            packets.append(["detectorArrayPosition":position,"ordinal":d.ordinal,"status":"exact-original-full-RLE-enumerated",
                "gridWidth":cells.width,"gridHeight":cells.height,"scale":[Double(cells.scaleX),Double(cells.scaleY)],
                "actualMemberCells":packet.count,"enumeratedBeforeROIClipping":true,"complete":true])
        }
        guard !support.isEmpty,!fitCenters.isEmpty else {
            return .init(proposals:[],receipt:["family":"model-support-envelope407","status":"missing-genuine-native-model-support",
                "rootPacketReceipts":packets,"missingRootRLEPackets":missingPackets,"modelMembershipQueries":gridQueries,
                "originalNativeCenterCount":e.nativeCellCenters.count,"modelGeometryOnly":true,"admissionGranted":false])
        }
        // PCA on UNIQUE actual model centers, never on a filled model rectangle.
        let count=CGFloat(fitCenters.count)
        let mn=fitCenters.reduce(CGFloat(0)){$0+$1.x}/count,ma=fitCenters.reduce(CGFloat(0)){$0+$1.y}/count
        var nn:CGFloat=0,aa:CGFloat=0,na:CGFloat=0
        for p in fitCenters {let x=p.x-mn,y=p.y-ma;nn += x*x;aa += y*y;na += x*y}
        nn /= count;aa /= count;na /= count
        let spread=hypot(nn-aa,2*na),major=max(0,(nn+aa+spread)*0.5),minor=max(0,(nn+aa-spread)*0.5)
        let anisotropy=Double(major/max(minor,1e-9))
        func normalize(_ a:CGFloat) -> CGFloat {
            var t=a
            while t < -CGFloat.pi/2 {t += CGFloat.pi}
            while t >= CGFloat.pi/2 {t -= CGFloat.pi}
            return t
        }
        let pcaAngle=normalize(CGFloat.pi/2-0.5*atan2(2*na,nn-aa))
        var fits=[Fit(name:"source-basis",radians:0,credibility:1)]
        if fitCenters.count>=3,major>1e-6,anisotropy>=1.5 {
            fits.append(.init(name:"model-PCA",radians:pcaAngle,credibility:min(1,(anisotropy-1)/3)))
        }
        // Monotone-chain hull is only an orientation search structure; it is
        // NEVER rasterized as foreground or substituted for original RLE cells.
        let sorted=fitCenters.sorted{$0.x==$1.x ? $0.y<$1.y:$0.x<$1.x}
        func cross(_ o:CGPoint,_ a:CGPoint,_ b:CGPoint) -> CGFloat {(a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x)}
        var lower:[CGPoint]=[],upper:[CGPoint]=[]
        for p in sorted {while lower.count>=2 && cross(lower[lower.count-2],lower[lower.count-1],p)<=0 {lower.removeLast()};lower.append(p)}
        for p in sorted.reversed() {while upper.count>=2 && cross(upper[upper.count-2],upper[upper.count-1],p)<=0 {upper.removeLast()};upper.append(p)}
        let hull=Array(lower.dropLast())+Array(upper.dropLast())
        func axes(_ t:CGFloat) -> (CGPoint,CGPoint) {
            let c=cos(t),s=sin(t)
            return (CGPoint(x:f.normal.x*c-f.along.x*s,y:f.normal.y*c-f.along.y*s),
                    CGPoint(x:f.normal.x*s+f.along.x*c,y:f.normal.y*s+f.along.y*c))
        }
        func envelope(_ t:CGFloat,_ fraction:CGFloat) -> Envelope {
            let c=cos(t),s=sin(t),(n,a)=axes(t)
            var b=[CGFloat.infinity,-CGFloat.infinity,CGFloat.infinity,-CGFloat.infinity],witness=[0,0,0,0]
            for (i,p) in support.enumerated() {
                let nc=p.n*c-p.a*s,ac=p.n*s+p.a*c
                let nr=fraction*(abs(n.x)*p.halfX+abs(n.y)*p.halfY)
                let ar=fraction*(abs(a.x)*p.halfX+abs(a.y)*p.halfY)
                let v=[nc-nr,nc+nr,ac-ar,ac+ar]
                if v[0]<b[0] {b[0]=v[0];witness[0]=i};if v[1]>b[1] {b[1]=v[1];witness[1]=i}
                if v[2]<b[2] {b[2]=v[2];witness[2]=i};if v[3]>b[3] {b[3]=v[3];witness[3]=i}
            }
            return .init(b:b,witness:witness)
        }
        // Full-cell area is evaluated on all actual support, not the hull area.
        // Limit search directions by work budget; disclose approximate minrect.
        let angleCount=min(hull.count,min(128,max(1,4_000_000/max(1,support.count))))
        var searched=0,bestAngle=CGFloat(0),bestArea=CGFloat.infinity,bestAspect=CGFloat(0)
        if hull.count>=2 {
            for k in 0..<angleCount {
                let i=k*hull.count/angleCount,p=hull[i],q=hull[(i+1)%hull.count]
                let angle=normalize(atan2(q.y-p.y,q.x-p.x))
                // This source-space direction is a NORMAL candidate. If its
                // long axis is transverse, rotate the frame by90 uniformly.
                var t=normalize(-angle),v=envelope(t,1).b
                if v[1]-v[0]>v[3]-v[2] {t=normalize(t+CGFloat.pi/2);v=envelope(t,1).b}
                let width=v[1]-v[0],length=v[3]-v[2],area=width*length
                searched += 1
                if area>0 && area<bestArea {bestArea=area;bestAngle=t;bestAspect=length/max(width,1e-9)}
            }
            if bestArea.isFinite,bestAspect>=1.5 {fits.append(.init(name:"model-bounded-minrect",radians:bestAngle,credibility:min(1,Double(bestAspect-1)/3)))}
        }
        // Three fractions are actual lattice half-width multipliers:0=center,
        // .5=half cell uncertainty,1=all original cell corners. Unknown-scale
        // native centers remain points at EVERY fraction; never fabricate size.
        var specifications:[(Fit,CGFloat)]=[]
        for fit in fits {
            let fractions:[CGFloat]=fit.name=="model-bounded-minrect" ? [0,1]:[0,0.5,1]
            for fraction in fractions {specifications.append((fit,fraction))}
        }
        var proposals:[K.Proposal]=[],seen=Set<String>(),outOfCapture=0
        let rootCells=support.indices.filter{support[$0].detector>=0}
        let supportCentersOutside=support.filter{!inCapture($0.center)}.count
        func witness(_ i:Int) -> [String:Any] {
            let p=support[i]
            var out:[String:Any]=["worldCenter":[Double(p.center.x),Double(p.center.y)],"sourceProjection":[Double(p.n),Double(p.a)],
                "kind":p.nativeIndex>=0 ? "original-native-center-unknown-cell-size":"exact-original-nativeRoot-RLE-cell",
                "isInkWitness":false,"ownershipClaimed":false]
            if p.nativeIndex>=0 {out["originalNativeCenterIndex"]=p.nativeIndex;out["cellSizeKnown"]=false}
            else {
                out["detectorArrayPosition"]=p.detector;out["originalCellXY"]=[p.cellX,p.cellY]
                out["actualCellScale"]=[Double(p.halfX*2),Double(p.halfY*2)];out["cellSizeKnown"]=true
                out["actualFullCellBounds"]=[Double(p.center.x-p.halfX),Double(p.center.y-p.halfY),Double(p.center.x+p.halfX),Double(p.center.y+p.halfY)]
            }
            return out
        }
        for (fit,fraction) in specifications {
            let en=envelope(fit.radians,fraction),b=en.b,(n,a)=axes(fit.radians)
            guard b.allSatisfy(\.isFinite),b[1]-b[0]>1e-6,b[3]-b[2]>1e-6 else {continue}
            func restore(_ x:CGFloat,_ y:CGFloat) -> CGPoint {CGPoint(x:f.origin.x+x*n.x+y*a.x,y:f.origin.y+x*n.y+y*a.y)}
            let raw=[restore(b[0],b[2]),restore(b[1],b[2]),restore(b[1],b[3]),restore(b[0],b[3])]
            guard raw.allSatisfy(inCapture) else{outOfCapture += 1;continue}
            var q=raw,cost=CGFloat.infinity
            for reverse in [false,true] {
                let z=reverse ? Array(raw.reversed()):raw
                for offset in 0..<4 {
                    let v=(0..<4).map{z[($0+offset)%4]}
                    let d=(0..<4).reduce(CGFloat(0)) { total,i in let x=v[i].x-old[i].x,y=v[i].y-old[i].y;return total+x*x+y*y }
                    if d<cost {cost=d;q=v}
                }
            }
            let key=q.map{String(format:"%.8f,%.8f",Double($0.x),Double($0.y))}.joined(separator:";")
            guard seen.insert(key).inserted,proposals.count<8 else {continue}
            let nativeLost=e.nativeCellCenters.filter{K.contains(old,$0) && !K.contains(q,$0)}
            var cornersOutside=0
            for i in rootCells {
                let p=support[i]
                for dx in [-p.halfX,p.halfX] {for dy in [-p.halfY,p.halfY] {
                    if !K.contains(q,CGPoint(x:p.center.x+dx,y:p.center.y+dy)) {cornersOutside += 1}
                }}
            }
            var ggLoss=0
            for i in e.body.indices where e.body[i] != 0 {
                let p=CGPoint(x:r.origin.x+CGFloat(i%w)+0.5,y:r.origin.y+CGFloat(i/w)+0.5)
                if K.contains(old,p) && !K.contains(q,p) {ggLoss += 1}
            }
            // RF corroborates actual support locations only; never RF geometry.
            var rfHits=Set<Int>()
            for k in 0..<min(16,support.count) {
                let p=support[k*(support.count-1)/max(1,min(16,support.count)-1)].center
                for (j,v) in e.rf.enumerated() where v.confidence>=0.4 && v.contains(p) {rfHits.insert(j)}
            }
            let rec:[String:Any]=["family":"model-support-envelope407","fit":fit.name,
                "angleRadiansRelativeToActualSource":Double(fit.radians),"angleCredibilityGeometryOnly":fit.credibility,
                "cellUncertaintyFraction":Double(fraction),"fractionMeaning":"0 center,0.5 half genuine model-cell uncertainty,1 exact original root model-cell corners",
                "normal":[Double(n.x),Double(n.y)],"along":[Double(a.x),Double(a.y)],
                "sourceBasisOrigin":[Double(f.origin.x),Double(f.origin.y)],"sourcePlanes":b.map(Double.init),
                "planeOrder":["normalLow","normalHigh","alongLow","alongHigh"],"planeActualModelSupport":en.witness.map(witness),
                "actualOld":old.map{[Double($0.x),Double($0.y)]},"actualOldEnclosed":old.allSatisfy{K.contains(q,$0)},
                "allSuppliedNativeCentersUsedBeforeROIClipping":true,"allSuppliedModelCentersEnclosed":true,
                "modelSupportCentersOutsideCapture":supportCentersOutside,"originalNativeCenterCount":e.nativeCellCenters.count,
                "exactRootRLECellsUsed":exactCells,"missingRootRLEPackets":missingPackets,
                "nativeCenterCellSizeUnknown":true,"cellScaleInferredFromNativeWOrSpacing":false,
                "fullRootCellCornersOutsideProposal":cornersOutside,"newlyExcludedActualNativeCellCenters":nativeLost.count,
                "newlyExcludedOriginalGGBodyPixels":ggLoss,"RFActualSupportArrayPositions":rfHits.sorted(),
                "modelGeometryOnly":true,"modelSupportIsForeground":false,"GGBodyInvented":false,
                "RFGeometryFilled":false,"hullRasterizedAsInk":false,"geometryIsOwnership":false,
                "pixelFillRimRolesEstablished":false,"sourceForegroundCompletenessClaimed":false,
                "nativePacketCompletenessIndependentlyAuthenticated":false,"nativeAdmissionSuiteRun":false,"admissionGranted":false]
            var obligations=["model-cell-support-is-not-foreground-or-target-ownership","unknown-native-cell-size-requires-actual-packet-not-inferred-scale",
                "actual-RGBA-fill-rim-foreign-ruby-and-all-native-guards-required","no-erasure-authority","source-only-no-admission"]
            if fraction<1 && exactCells>0 {obligations.append("partial-cell-uncertainty-may-exclude-real-cell-corners-not-a-glyph-loss-proof")}
            if ggLoss>0 {obligations.append("recorded-original-GG-loss-requires-actual-pixel-role-and-native-evaluation")}
            if missingPackets>0 {obligations.append("original-root-model-RLE-enumeration-incomplete")}
            proposals.append(.init(suffix:"model-envelope407-\(fit.name)-cell\(Int(fraction*100))",polygon:q,receipt:rec,obligations:obligations))
        }
        return .init(proposals:proposals,receipt:["family":"model-support-envelope407","status":proposals.isEmpty ? "no-bounded-nondegenerate-full-support-envelope":"source-model-geometry-only",
            "proposalCount":proposals.count,"maximumProposals":8,"originalNativeCentersUsed":e.nativeCellCenters.count,
            "allSuppliedNativeCentersConsumedBeforeROIClipping":true,"nativeCentersFrameCompletenessIsCallerPacketContract":true,
            "supportCentersOutsideCapture":supportCentersOutside,"exactRootRLECells":exactCells,"rootPacketReceipts":packets,
            "missingRootRLEPackets":missingPackets,"modelMembershipQueries":gridQueries,"modelMembershipQueryBudget":gridBudget,
            "modelSupportCount":support.count,"uniqueModelFitCenters":fitCenters.count,"PCAAnisotropy":anisotropy,
            "minrectHullVertices":hull.count,"minrectAnglesEvaluated":searched,"minrectSearchIsExactGlobalMinimum":false,
            "rejectedOutOfCaptureCandidates":outOfCapture,"supportClippedToROI":false,"modelGeometryOnly":true,
            "absoluteBrightnessRuleUsed":false,"nativeCellSizeInvented":false,"GGBodyInvented":false,
            "runtimeGTOrIDRouting":false,"sourceForegroundCompletenessClaimed":false,"admissionGranted":false])
    }
}
