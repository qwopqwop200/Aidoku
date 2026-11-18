import Foundation
import CoreGraphics
import CryptoKit

// Proposal observation only. Neither a fitted line nor a rectangle assigns pixels.
// Every envelope below is computed from ORIGINAL pixel supports, never a filled hull.
enum NativeOCRSourceOrientation391 {
    struct LocalRGBA {
        let bytes:[UInt8]
        let width:Int
        let height:Int
        let bytesPerRow:Int
        let origin:CGPoint
    }
    /// Value-only source contract. The closure must query the ORIGINAL footprint.
    /// Completeness describes the supplied footprint, never inferred from an envelope.
    /// capturedRawSHA256 is nil for live native evidence: no capture file exists there.
    struct Source {
        let tag:String
        let rgba:LocalRGBA
        let width:Double
        let origin:CGPoint
        let normal:CGPoint
        let along:CGPoint
        let originalFootprintContains:(CGPoint)->Bool
        let originalFootprintComplete:Bool
        let nativePalettes:[[Int]]
        let actualRGBA_SHA256:String
        let capturedRawSHA256:String?
    }
    private static func sha(_ data:Data)->String {
        SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    }
    private static func contains(_ q:[CGPoint],_ p:CGPoint)->Bool {
        var plus=false,minus=false
        for i in 0..<4 {
            let a=q[i],b=q[(i+1)%4],c=(b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
            if c>1e-7{plus=true};if c < -1e-7{minus=true}
        }
        return !plus || !minus
    }
    struct Result {let offers:[[String:Any]];let receipt:[String:Any]}
    struct Sample {let pixel:Int;let n:Double;let a:Double}
    struct Fit {let degrees:Double;let score:Double}
    static let maxOffers=48
    static let angleLimit=24.0

    static func quantile(_ sorted:[Double],_ q:Double)->Double {
        let t=Double(sorted.count-1)*q,i=Int(floor(t)),j=min(i+1,sorted.count-1)
        return sorted[i]+(sorted[j]-sorted[i])*(t-Double(i))
    }
    static func generate(prior:[CGPoint],root:Source,members:[Source],sharedBody:[UInt8])->Result {
        let r=root.rgba,w=r.width,h=r.height,width=root.width
        let origin=root.origin,normal=root.normal,along=root.along
        let bodySHA=sha(Data(sharedBody))
        func world(_ i:Int)->CGPoint {CGPoint(x:r.origin.x+CGFloat(i%w)+0.5,y:r.origin.y+CGFloat(i/w)+0.5)}
        func rgb(_ i:Int)->[Int] {let k=(i/w)*r.bytesPerRow+(i%w)*4;return [Int(r.bytes[k]),Int(r.bytes[k+1]),Int(r.bytes[k+2])]}
        func opaque(_ i:Int)->Bool {r.bytes[(i/w)*r.bytesPerRow+(i%w)*4+3]==255}
        func delta(_ a:[Int],_ b:[Int])->Int {(0..<3).map{abs(a[$0]-b[$0])}.max()!}
        func sample(_ i:Int)->Sample {
            let p=world(i),x=Double(p.x-origin.x),y=Double(p.y-origin.y)
            return Sample(pixel:i,n:x*Double(normal.x)+y*Double(normal.y),a:x*Double(along.x)+y*Double(along.y))
        }
        var privatePixels=Set<Int>(),memberPixels:[[Int]]=[]
        // All original retained RLE supports in this EXACT captured window, including
        // supports already outside the actual prior. No colour/CC/size filtering here.
        for m in members {
            var pixels:[Int]=[]
            for i in 0..<w*h where m.originalFootprintContains(world(i)) {pixels.append(i);privatePixels.insert(i)}
            memberPixels.append(pixels)
        }
        let body=Set(sharedBody.indices.filter{sharedBody[$0] != 0 && opaque($0)})
        var rim=Set<Int>()
        let colours=members.flatMap{$0.nativePalettes}
        // A bounded, original-pixel rim HYPOTHESIS. Require adjacency to at least two
        // actual GG body pixels, an exported palette colour, and observed local contrast.
        // This does not promote the neighbour to a private cell or assert ownership.
        for i in body.sorted() {
            let x=i%w,y=i/w
            for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                let xx=x+dx,yy=y+dy
                guard xx>0,yy>0,xx<w-1,yy<h-1 else{continue}
                let j=yy*w+xx
                guard !body.contains(j),!rim.contains(j),opaque(j) else{continue}
                let neighbours=[j-1,j+1,j-w,j+w]
                guard neighbours.filter({body.contains($0)}).count>=2 else{continue}
                let c=rgb(j)
                guard colours.contains(where:{delta(c,$0)<=20}),
                      neighbours.contains(where:{opaque($0) && delta(c,rgb($0))>=24}) else{continue}
                rim.insert(j)
            }
        }
        let retained=body.union(privatePixels).union(rim)
        let all=retained.sorted().map(sample)
        var metadata:[String:Any]=[
            "family":"source-axis-orientation391","sourceOnly":true,"GTRead":false,
            "nativeW":width,"sharedActualBodySHA256":bodySHA,
            "sharedActualBodyPixels":body.count,"actualPrivatePixelCount":privatePixels.count,
            "observedPaletteNeighbourRimPixels":rim.count,"allSupportPixels":all.count,
            "rimIsOwnershipClaim":false,"allRetainedSupportsUsedForEndpoints":true,
            "RLEHullFilled":false,"axisHorizontalVerticalShortcut":false,
            "priorEnclosureForced":false,"maxOffers":maxOffers,"angleLimitDegrees":angleLimit,
            "searchLanesMaximum":64,"coarseAngleStepDegrees":1.0,"refineAngleStepDegrees":0.125,
            "admissionGranted":false,"nativeAdmissionSuiteRun":false]
        guard !body.isEmpty,all.count>=8 else {
            metadata["status"]="insufficient-observed-support";return Result(offers:[],receipt:metadata)
        }
        let aMin=all.map(\.a).min()!,aMax=all.map(\.a).max()!
        guard aMax-aMin>1 else {metadata["status"]="degenerate-observed-span";return Result(offers:[],receipt:metadata)}
        func rotated(_ s:Sample,_ degrees:Double)->(Double,Double) {
            let t=degrees * Double.pi/180,c=cos(t),v=sin(t)
            // Rotate in the authenticated source frame, preserving its handedness.
            return (s.n*c-s.a*v,s.n*v+s.a*c)
        }
        func basis(_ degrees:Double)->(CGPoint,CGPoint) {
            let t=degrees * Double.pi/180,c=CGFloat(cos(t)),s=CGFloat(sin(t))
            return (CGPoint(x:normal.x*c-along.x*s,y:normal.y*c-along.y*s),
                    CGPoint(x:normal.x*s+along.x*c,y:normal.y*s+along.y*c))
        }
        func witness(_ s:Sample)->[String:Any] {
            let p=world(s.pixel)
            return ["actualLocalPixelIndex":s.pixel,"center":[Double(p.x),Double(p.y)],"RGBA":rgb(s.pixel)+[Int(r.bytes[(s.pixel/w)*r.bytesPerRow+(s.pixel%w)*4+3])],
                "sharedActualBodyAtPixel":body.contains(s.pixel),"actualPrivateRLEContainsCenter":privatePixels.contains(s.pixel),
                "observedPaletteNeighbourRim":rim.contains(s.pixel),"alreadyOutsideActualPrior":!contains(prior,p)]
        }
        // Each occupied along lane contributes its observed 5/50/95% transverse
        // quantiles. All original samples enter lane statistics. The angle search
        // uses at most 192 statistics; final geometry and losses use ALL samples.
        func summaries(_ samples:[Sample])->[Sample] {
            let lo=samples.map(\.a).min()!,hi=samples.map(\.a).max()!
            var lanes=[[Sample]](repeating:[],count:64)
            for s in samples {let k=min(63,max(0,Int((s.a-lo)/max(hi-lo,1)*64)));lanes[k].append(s)}
            var out:[Sample]=[]
            for lane in lanes where !lane.isEmpty {
                let sorted=lane.sorted{$0.n == $1.n ? $0.pixel<$1.pixel:$0.n<$1.n}
                for q in [0.05,0.5,0.95] {out.append(sorted[Int(Double(sorted.count-1)*q)])}
            }
            return out
        }
        func fit(_ stats:[Sample],_ degrees:Double)->Fit {
            let projected=stats.map{rotated($0,degrees).0}.sorted()
            let breadth=quantile(projected,0.95)-quantile(projected,0.05)
            // Robust transverse spread; no page-axis, prior-width, content, or ID route.
            let med=quantile(projected,0.5)
            let deviations=projected.map{abs($0-med)}.sorted()
            return Fit(degrees:degrees,score:(breadth+0.35*quantile(deviations,0.5))/width)
        }
        func angles(_ samples:[Sample])->([Fit],[String:Any]) {
            let stats=summaries(samples)
            var search=(-24...24).map{fit(stats,Double($0))}
            func ordered(_ a:Fit,_ b:Fit)->Bool {
                if abs(a.score-b.score)>1e-12{return a.score<b.score}
                if abs(a.degrees) != abs(b.degrees){return abs(a.degrees)<abs(b.degrees)}
                return a.degrees<b.degrees
            }
            let coarse=search.sorted(by:ordered).first!
            for j in -8...8 {
                let d=max(-angleLimit,min(angleLimit,coarse.degrees+Double(j)*0.125))
                search.append(fit(stats,d))
            }
            let ranked=search.sorted(by:ordered),best=ranked.first!
            var chosen=[best]
            if let secondary=ranked.first(where:{abs($0.degrees-best.degrees)>=2}){chosen.append(secondary)}
            chosen.append(fit(stats,0))
            // Include a local shoulder for weakly determined slants, then deduplicate.
            chosen.append(fit(stats,max(-angleLimit,min(angleLimit,best.degrees+(best.degrees<=0 ? 0.75:-0.75)))))
            var unique:[Fit]=[]
            for item in chosen where !unique.contains(where:{abs($0.degrees-item.degrees)<0.0625}){unique.append(item)}
            return (unique,["summaryStatistics":stats.count,"allInputSupportSamples":samples.count,
                "bestDegrees":best.degrees,"bestScore":best.score,
                "sourceAngleScore":fit(stats,0).score,
                "searchBoundaryReached":abs(best.degrees)>=angleLimit-0.125,
                "angleEvidenceWeak":fit(stats,0).score-best.score<0.02,
                "chosenAngles":unique.map{["degrees":$0.degrees,"score":$0.score]}])
        }
        var offers:[[String:Any]]=[],seen=Set<String>(),searchReceipts:[[String:Any]]=[]
        let families:[(String,[Sample])]=[("shared-body-rim",body.union(rim).sorted().map(sample)),("all-retained",all)]
        for (family,support) in families where support.count>=8 {
            let (fits,search)=angles(support)
            searchReceipts.append(["supportFamily":family,"search":search])
            for f in fits {
                let (n,a)=basis(f.degrees)
                let nRadius=(abs(Double(n.x))+abs(Double(n.y)))*0.5
                let aRadius=(abs(Double(a.x))+abs(Double(a.y)))*0.5
                let ns=support.map{rotated($0,f.degrees).0}.sorted()
                let projectedAll=all.map{rotated($0,f.degrees)}
                let alongLo=projectedAll.map{$0.1}.min()!-aRadius
                let alongHi=projectedAll.map{$0.1}.max()!+aRadius
                let endpointLo=all.indices.min{projectedAll[$0].1<projectedAll[$1].1}!
                let endpointHi=all.indices.max{projectedAll[$0].1<projectedAll[$1].1}!
                // Protect real source endpoint strips, including tied extrema and
                // detached retained strokes. The actual prior is NOT an endpoint.
                let endDepth=max(1.0,width*0.1)
                let terminal=all.indices.filter{projectedAll[$0].1<=alongLo+aRadius+endDepth || projectedAll[$0].1>=alongHi-aRadius-endDepth}
                let endpointNLo=terminal.map{projectedAll[$0].0-nRadius}.min()!
                let endpointNHi=terminal.map{projectedAll[$0].0+nRadius}.max()!
                for q in [0.0,0.025,0.075] {
                    let lowQ=quantile(ns,q),highQ=quantile(ns,1-q)
                    for pad in [0.0,0.05] {
                        let proposedLow=lowQ-nRadius-width*pad,proposedHigh=highQ+nRadius+width*pad
                        let low=min(proposedLow,endpointNLo),high=max(proposedHigh,endpointNHi)
                        guard high>low,alongHi>alongLo else{continue}
                        func restore(_ nn:Double,_ aa:Double)->CGPoint {
                            CGPoint(x:origin.x+CGFloat(nn)*n.x+CGFloat(aa)*a.x,y:origin.y+CGFloat(nn)*n.y+CGFloat(aa)*a.y)
                        }
                        let raw=[restore(low,alongLo),restore(high,alongLo),restore(high,alongHi),restore(low,alongHi)]
                        // Preserve the actual prior's corner order for downstream interpolation.
                        var polygon=raw,bestCost=Double.infinity
                        for reverse in [false,true] {
                            let z=reverse ? Array(raw.reversed()):raw
                            for offset in 0..<4 {
                                let v=(0..<4).map{z[($0+offset)%4]}
                                let cost=(0..<4).reduce(0.0){acc,i in
                                    let dx=Double(v[i].x-prior[i].x),dy=Double(v[i].y-prior[i].y)
                                    return acc+dx*dx+dy*dy
                                }
                                if cost<bestCost {bestCost=cost;polygon=v}
                            }
                        }
                        let identity=polygon.map{String(format:"%.5f,%.5f",Double($0.x),Double($0.y))}.joined(separator:";")
                        guard seen.insert(identity).inserted,offers.count<maxOffers else{continue}
                        let insideCapture=polygon.allSatisfy{$0.x>=r.origin.x && $0.y>=r.origin.y && $0.x<=r.origin.x+CGFloat(w) && $0.y<=r.origin.y+CGFloat(h)}
                        let lost=all.indices.filter{projectedAll[$0].0-nRadius<low-1e-7 || projectedAll[$0].0+nRadius>high+1e-7}
                        let lostBody=lost.filter{body.contains(all[$0].pixel)}.count
                        let lostPrivate=lost.filter{privatePixels.contains(all[$0].pixel)}.count
                        let clipped=members.contains{!$0.originalFootprintComplete}
                        let touchesBoundary=all.contains{s in let x=s.pixel%w,y=s.pixel/w;return x==0 || y==0 || x==w-1 || y==h-1}
                        let memberLosses=memberPixels.enumerated().map{ordinal,pixels -> [String:Any] in
                            let loss=pixels.filter {i in let v=rotated(sample(i),f.degrees);return v.0-nRadius<low-1e-7 || v.0+nRadius>high+1e-7}
                            return ["tag":members[ordinal].tag,"actualRLEPixelCenters":pixels.count,"normalCellSupportOutsideProposal":loss.count,
                                "lossWitnesses":loss.prefix(4).map{witness(sample($0))}]
                        }
                        var obligations=["native-guard-readmission-required","ownership-unproven","semantic-and-mandatory-suite-not-run",
                            "RLE-cell-support-is-not-a-foreground-ownership-claim","detached-support-association-unproven"]
                        if !insideCapture {obligations.append("candidate-exceeds-capture-fresh-local-source-read-required")}
                        if clipped {obligations.append("local-RLE-not-global-source-completeness")}
                        if touchesBoundary {obligations.append("support-touches-capture-edge-fresh-local-read-required")}
                        if low<proposedLow-1e-7 || high>proposedHigh+1e-7 {obligations.append("actual-endpoint-support-limits-normal-correction")}
                        if !contains(polygon,world(all[endpointLo].pixel)) || !contains(polygon,world(all[endpointHi].pixel)) {
                            obligations.append("endpoint-normal-support-not-enclosed")
                        }
                        if all.contains(where:{!opaque($0.pixel)}) {obligations.append("nonopaque-original-RLE-samples-require-review")}
                        if lostBody>0 {obligations.append("observed-body-cell-support-loss")}
                        if lostPrivate>0 {obligations.append("observed-retained-RLE-cell-support-loss")}
                        if abs(f.degrees)>=angleLimit-0.125 {obligations.append("angle-search-boundary-fresh-search-required")}
                        let lowWitness=support.min{abs(rotated($0,f.degrees).0-lowQ)<abs(rotated($1,f.degrees).0-lowQ)}!
                        let highWitness=support.min{abs(rotated($0,f.degrees).0-highQ)<abs(rotated($1,f.degrees).0-highQ)}!
                        let priorNormal=prior.map{p -> Double in Double(p.x-origin.x)*Double(n.x)+Double(p.y-origin.y)*Double(n.y)}
                        let receipt:[String:Any]=[
                            "family":"source-axis-orientation391","supportFamily":family,"nativeW":width,
                            "sharedActualBodySHA256":bodySHA,"angleDegreesRelativeToActualSource":f.degrees,
                            "normal":[Double(n.x),Double(n.y)],"along":[Double(a.x),Double(a.y)],
                            "origin":[Double(origin.x),Double(origin.y)],"angleSearchObjective":f.score,
                            "actualCurrentPrior":prior.map{[Double($0.x),Double($0.y)]},
                            "actualRootRawSHA256":root.capturedRawSHA256.map { $0 as Any } ?? NSNull(),"actualRGBA_SHA256":root.actualRGBA_SHA256,
                            "memberReceiptTags":members.map{$0.tag},
                            "normalQuantile":q,"normalPaddingNativeW":pad,"normalBounds":[low,high],"alongBounds":[alongLo,alongHi],
                            "unconstrainedQuantileNormalBounds":[proposedLow,proposedHigh],
                            "actualEndpointStripDepth":endDepth,"actualEndpointStripPixels":terminal.count,
                            "actualEndpointNormalBounds":[endpointNLo,endpointNHi],
                            "normalCenterCorrectionFromPrior":(low+high-priorNormal.min()!-priorNormal.max()!)*0.5,
                            "allObservedRetainedEndpointsEnclosedAlong":true,"endpointsEnclosedInPolygon":contains(polygon,world(all[endpointLo].pixel)) && contains(polygon,world(all[endpointHi].pixel)),
                            "actualLowSupportWitness":witness(lowWitness),"actualHighSupportWitness":witness(highWitness),
                            "actualEndpointWitnesses":[witness(all[endpointLo]),witness(all[endpointHi])],
                            "normalBodyCellSupportLoss":lostBody,"normalRLECellSupportLoss":lostPrivate,
                            "memberSupportLosses":memberLosses,"actualPriorContainsProposal":polygon.allSatisfy{contains(prior,$0)},
                            "proposalContainsActualPrior":prior.allSatisfy{contains(polygon,$0)},"candidateFullyInCapturedRGBA":insideCapture,
                            "globalRLECompleteForEveryMember":!clipped,"allSourceForegroundPreservedClaimed":false,"originalRLEGeometryNotReconstructedFromRGBA":true,
                            "sourceAssociationInferred":false,"RLEHullFilled":false,"admissionGranted":false]
                        let key="source-axis-orientation391-"+family+"-a"+String(format:"%.3f",f.degrees)+"-q"+String(q)+"-p"+String(pad)
                        offers.append(["key":key,"polygon":polygon.map{[Double($0.x),Double($0.y)]},"sourceReceipt":receipt,
                            "hardRejections":insideCapture ? []:["candidate-outside-authenticated-RGBA"],
                            "softRejections":obligations,"obligations":obligations,"admissionGranted":false,
                            "automaticSelection":false,"nativeAdmissionSuiteRun":false])
                    }
                }
            }
        }
        metadata["status"]=offers.isEmpty ? "no-observed-angle-envelope":"candidate-geometry-only"
        metadata["searches"]=searchReceipts;metadata["proposalCount"]=offers.count
        return Result(offers:offers,receipt:metadata)
    }
}
