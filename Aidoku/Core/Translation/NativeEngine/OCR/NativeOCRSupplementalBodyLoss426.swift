import Foundation
import CoreGraphics

// Supplemental original-source pixel veto/repair nomination, not admission.
// Caller must bind RGBA and basis to the CURRENT native captured root session.
enum NativeOCRSupplementalBodyLoss426 {
    typealias K = NativeOCRSharedBoundary396
    enum Decision:String { case noRemovedPixel, rejectObservedLoss, unresolved }
    struct Output {
        let decision:Decision
        let repair:[CGPoint]?
        let receipt:[String:Any]
    }
    static func assess(actualOld:[CGPoint], proposed:[CGPoint], basis:K.Basis,
                       nativeW:CGFloat, rgba:K.RGBA, maximumQueries:Int=192, stopAfterFirstPositive:Bool=false) -> Output {
        func unknown(_ reason:String,_ extra:[String:Any]=[:])->Output {
            var receipt=extra
            receipt["family"]="source-supplemental-body-loss426";receipt["status"]=reason
            receipt["unknownMeansBackground"]=false;receipt["nativeAdmissionGranted"]=false
            receipt["ownershipClaimed"]=false;receipt["erasureAuthority"]="none"
            return .init(decision:.unresolved,repair:nil,receipt:receipt)
        }
        func valid(_ q:[CGPoint])->Bool {
            guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return false}
            let turns=(0..<4).map{i -> CGFloat in
                let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4]
                return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
            }
            return turns.allSatisfy{$0>1e-8} || turns.allSatisfy{$0 < -1e-8}
        }
        let w=rgba.width,h=rgba.height
        guard valid(actualOld),valid(proposed),w>2,h>2,w<=600_000/h,
              rgba.bytesPerRow>=w*4,rgba.bytesPerRow<=Int.max/h,
              rgba.bytes.count==h*rgba.bytesPerRow,nativeW.isFinite,nativeW>0,nativeW<100_000,
              maximumQueries>=1,maximumQueries<=512,
              [rgba.origin,basis.origin,basis.normal,basis.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              abs(hypot(basis.normal.x,basis.normal.y)-1)<1e-6,
              abs(hypot(basis.along.x,basis.along.y)-1)<1e-6,
              abs(basis.normal.x*basis.along.x+basis.normal.y*basis.along.y)<1e-6 else{return unknown("invalid-actual-capture-or-basis")}
        func world(_ i:Int)->CGPoint {.init(x:rgba.origin.x+CGFloat(i%w)+0.5,y:rgba.origin.y+CGFloat(i/w)+0.5)}
        func rgb(_ i:Int)->[Int] {let k=(i/w)*rgba.bytesPerRow+(i%w)*4;return (0..<3).map{Int(rgba.bytes[k+$0])}}
        func opaque(_ i:Int)->Bool {rgba.bytes[(i/w)*rgba.bytesPerRow+(i%w)*4+3]==255}
        func distance(_ a:[Int],_ b:[Int])->Int {(0..<3).map{abs(a[$0]-b[$0])}.max()!}
        func contained(_ i:Int)->Bool {K.contains(actualOld,world(i))}
        // Lost actual pixel cells only. Merely new background is never scanned.
        // No NN/GG/private membership is required to nominate a query.
        var removed:[Int]=[],seeds:[(Int,Int)]=[]
        for i in 0..<(w*h) where opaque(i) && contained(i) && !K.contains(proposed,world(i)) {
            removed.append(i)
            let x=i%w,y=i/w
            guard x>0,x<w-1,y>0,y<h-1 else{continue}
            let neighbours=[i-1,i+1,i-w,i+w]
            guard neighbours.allSatisfy(opaque) else{continue}
            let c=rgb(i),gradient=neighbours.map{distance(c,rgb($0))}.max()!
            if gradient>=40 {seeds.append((i,gradient))}
        }
        guard !removed.isEmpty else {
            return .init(decision:.noRemovedPixel,repair:nil,receipt:["family":"source-supplemental-body-loss426",
                "status":"no-original-opaque-pixel-centre-removed","pixelCellSquareLossNotCertified":true,
                "nativeAdmissionGranted":false,"completeForegroundPreserved":false])
        }
        // Spatially distribute the capped source probes across the entire lost
        // strip, not just its first AA edge. Source bounds have no glyph meaning.
        let bucketSize=max(1,Int(nativeW*0.15))
        var buckets=[Int:[(Int,Int)]]()
        for value in seeds {
            let p=world(value.0),z=(p.x-basis.origin.x)*basis.along.x+(p.y-basis.origin.y)*basis.along.y
            buckets[Int(floor(z/CGFloat(bucketSize))),default:[]].append(value)
        }
        for key in buckets.keys {buckets[key]!.sort{$0.1==$1.1 ? $0.0<$1.0:$0.1>$1.1}}
        let keys=buckets.keys.sorted()
        var probes:[Int]=[],depth=0
        while probes.count<maximumQueries {
            var added=false
            for key in keys where probes.count<maximumQueries {
                if depth<buckets[key]!.count {probes.append(buckets[key]![depth].0);added=true}
            }
            if !added{break};depth += 1
        }
        var protected=Set<Int>(),witnesses:[[String:Any]]=[],queries=0
        var counts=[String:Int]()
        for i in probes {
            queries += 1
            let p=world(i)
            // Image-gradient structure tensor nominates a local crossing axis.
            // Actual source basis axes provide deterministic backup, without any
            // world-angle branches, page IDs, NN/GG association or fitted GT.
            var xx=Double(0),xy=Double(0),yy=Double(0)
            let px=i%w,py=i/w
            if px>=2 && px<w-2 && py>=2 && py<h-2 {
                for dy in -1...1 {for dx in -1...1 {
                    let j=(py+dy)*w+px+dx
                    if [j-1,j+1,j-w,j+w].allSatisfy(opaque) {
                        let l=rgb(j-1),r=rgb(j+1),u=rgb(j-w),d=rgb(j+w)
                        for channel in 0..<3 {
                            let gx=Double(r[channel]-l[channel]),gy=Double(d[channel]-u[channel])
                            xx += gx*gx;xy += gx*gy;yy += gy*gy
                        }
                    }
                }}
            }
            var axes:[(CGPoint,CGPoint)]=[]
            if xx+yy>0 {
                let theta=0.5*atan2(2*xy,xx-yy)
                let n=CGPoint(x:cos(theta),y:sin(theta))
                axes.append((n,CGPoint(x:-n.y,y:n.x)))
            }
            for pair in [(basis.normal,basis.along),(basis.along,basis.normal)] {
                if !axes.contains(where:{abs($0.0.x*pair.0.x+$0.0.y*pair.0.y)>0.9999}){axes.append(pair)}
            }
            // Refine a crossing direction only from three distinct actual,
            // collinear same-fill pixel centres. No global-angle snap or NN seed.
            let initialAxes=axes
            func sourceIndex(_ q:CGPoint)->Int? {
                let x=Int(floor(q.x-rgba.origin.x)),y=Int(floor(q.y-rgba.origin.y))
                guard x>=0,x<w,y>=0,y<h else{return nil}
                let j=y*w+x;return opaque(j) ? j:nil
            }
            for (_,tangent) in initialAxes {
                for offsets in [[CGFloat(-1),0,1],[0,1,2],[0,-1,-2]] {
                    let ids=offsets.compactMap{sourceIndex(.init(x:p.x+tangent.x*$0,y:p.y+tangent.y*$0))}
                    guard ids.count==3,Set(ids).count==3,ids.allSatisfy({distance(rgb(i),rgb($0))<=16}) else{continue}
                    let u=world(ids[0]),v=world(ids[1]),z=world(ids[2])
                    let dx=z.x-u.x,dy=z.y-u.y,len=hypot(dx,dy)
                    guard len>=1.5,abs(dx*(v.y-u.y)-dy*(v.x-u.x))<1e-7 else{continue}
                    let n=CGPoint(x:dy/len,y:-dx/len),a=CGPoint(x:dx/len,y:dy/len)
                    if !axes.contains(where:{abs($0.0.x*n.x+$0.0.y*n.y)>0.999999}) {axes.append((n,a))}
                }
            }
            var accepted=false
            for (normal,along) in axes {
                let thin=SourceClosedFiniteFill426.assess(rgba:rgba,queryPoint:p,normal:normal,along:along,nativeW:nativeW)
                if thin.positive {
                    for row in thin.rows where row.positive {
                        for v in (row.low?.fill ?? [])+(row.high?.fill ?? []) where contained(v.index) && !K.contains(proposed,v.center){protected.insert(v.index)}
                    }
                    counts["finite-fill426",default:0] += 1
                    if witnesses.count<12{witnesses.append(["queryIndex":i,"queryCenter":[Double(p.x),Double(p.y)],"RGB":rgb(i),"actualProbeNormal":[Double(normal.x),Double(normal.y)],"primitive":thin.receipt])}
                    accepted=true;break
                }
                let outlined=SourceClosedOutlinedPair426.assess(rgba:rgba,queryPoint:p,normal:normal,along:along,nativeW:nativeW)
                if outlined.positive {
                    for row in outlined.rows where row.positive {
                        for v in (row.low?.fill ?? [])+(row.high?.fill ?? []) where contained(v.index) && !K.contains(proposed,v.center){protected.insert(v.index)}
                    }
                    counts["outlined-pair426",default:0] += 1
                    if witnesses.count<12{witnesses.append(["queryIndex":i,"queryCenter":[Double(p.x),Double(p.y)],"RGB":rgb(i),"actualProbeNormal":[Double(normal.x),Double(normal.y)],"primitive":outlined.receipt])}
                    accepted=true;break
                }
            }
            if !accepted{counts["unresolved",default:0] += 1}
            if stopAfterFirstPositive && !protected.isEmpty { break }
        }
        var receipt:[String:Any]=["family":"source-supplemental-body-loss426","actualRemovedPixelCentres":removed.count,
            "contrastQuerySeeds":seeds.count,"queries":queries,"queryBudget":maximumQueries,
            "probeBudgetTruncated":probes.count<seeds.count,"positiveCounts":counts,
            "actualLostCorePixelCount":protected.count,"positiveWitnesses":witnesses,
            "GGOrNativeMembershipUsedAsForeground":false,"unknownMeansBackground":false,
            "ownershipClaimed":false,"erasureAuthority":"none","nativeAdmissionGranted":false,
            "completeForegroundPreserved":false,"allOriginalMemberAndPeerGuardsRemainRequired":true,"sourcePixelCentreDirectionRefinement":true,"fixedFillTolerance426":20,"outlineExteriorPixelsPerSidePerRow426":2,"outlineMinimumDistinctExteriorPixelsPerSide426":6,"outlineOppositeExteriorColourEqualityRequired426":false]
        if stopAfterFirstPositive {
            receipt["stopAfterFirstPositiveRequested"] = true
            receipt["stoppedAfterFirstPositive"] = !protected.isEmpty && queries<probes.count
            receipt["positiveCellInventoryComplete"] = false
            receipt["partialPositiveReceiptNotFullCellInventory"] = true
        }
        guard !protected.isEmpty else{return unknown("removed-source-has-no-positive-closure-not-an-allow",receipt)}
        receipt["status"]="positive-original-source-core-loss"
        receipt["lostPixelIndices"]=protected.sorted()
        // Repair is a fresh geometry nomination and must be re-admitted. It is
        // bounded by actualOld, so it never acquires outside-old pixels.
        let repaired=repair(actualOld:actualOld,proposed:proposed,points:protected.sorted().map(world))
        receipt["repairNeedsFreshDescriptorsAndAllNativeGuards"]=true
        receipt["repairOutsideOldAcquisitionAllowed"]=false
        return .init(decision:.rejectObservedLoss,repair:repaired,receipt:receipt)
    }
    private static func repair(actualOld old:[CGPoint],proposed:[CGPoint],points:[CGPoint])->[CGPoint] {
        let ccw=(old[1].x-old[0].x)*(old[2].y-old[1].y)-(old[1].y-old[0].y)*(old[2].x-old[1].x)>0
        var normals:[CGPoint]=[],planes:[CGFloat]=[]
        for i in 0..<4 {
            let a=old[i],b=old[(i+1)%4],dx=b.x-a.x,dy=b.y-a.y,len=hypot(dx,dy)
            let n=ccw ? CGPoint(x:dy/len,y:-dx/len):CGPoint(x:-dy/len,y:dx/len)
            let na=proposed[i],nb=proposed[(i+1)%4],ex=nb.x-na.x,ey=nb.y-na.y
            if dx*ex+dy*ey<=0 || abs(dx*ey-dy*ex)>1e-6*max(1,len*hypot(ex,ey)){return old}
            let oldPlane=n.x*a.x+n.y*a.y,newPlane=n.x*na.x+n.y*na.y
            let observed=points.map{n.x*$0.x+n.y*$0.y+(abs(n.x)+abs(n.y))*0.5}.max()!
            normals.append(n);planes.append(min(oldPlane,max(newPlane,observed)))
        }
        var output:[CGPoint]=[]
        for i in 0..<4 {
            let j=(i+3)%4,a=normals[j],b=normals[i],det=a.x*b.y-a.y*b.x
            if abs(det)<1e-8{return old}
            let p=CGPoint(x:(planes[j]*b.y-a.y*planes[i])/det,y:(a.x*planes[i]-planes[j]*b.x)/det)
            if !p.x.isFinite || !p.y.isFinite || !K.contains(old,p){return old}
            output.append(p)
        }
        let turns=(0..<4).map{i -> CGFloat in
            let a=output[i],b=output[(i+1)%4],c=output[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        let convex=ccw ? turns.allSatisfy{$0>1e-8}:turns.allSatisfy{$0 < -1e-8}
        return convex && points.allSatisfy({K.contains(output,$0)}) ? output:old
    }
}
