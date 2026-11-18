import Foundation
import CoreGraphics

// Receipt-only nomination. This policy neither changes geometry nor admits it.
enum SourceChoice402Outline {
    private struct Component {
        let id:Int, anchors:Int, count:Int, contrast:Int
        let pixels:[Int], bounds:[Double], detectors:Set<Int>
    }
    private struct Ranked {
        let index:Int, recovered:Int, area:Double, base:Double
        var receipt:[String:Any]
    }
    private static func distance(_ a:[Int],_ b:[Int])->Int {
        zip(a,b).map{pair in abs(pair.0-pair.1)}.max() ?? 0
    }
    private static func point(_ w:[String:Any])->CGPoint? {
        guard let xy=w["center"] as? [Double],xy.count==2,xy.allSatisfy({$0.isFinite}),
              let i=w["actualLocalPixelIndex"] as? Int,i>=0,
              let rgb=w["RGB"] as? [Int],rgb.count==3,rgb.allSatisfy({0...255 ~= $0}) else{return nil}
        return CGPoint(x:xy[0],y:xy[1])
    }
    private static func area(_ q:[CGPoint])->Double {
        abs((0..<4).reduce(0.0){s,i in
            let a=q[i],b=q[(i+1)%4];return s+Double(a.x*b.y-a.y*b.x)
        })*0.5
    }
    private static func convex(_ q:[CGPoint])->Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return false}
        let turns=(0..<4).map {i -> CGFloat in
            let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        return turns.allSatisfy{$0>1e-8} || turns.allSatisfy{$0 < -1e-8}
    }
    static func preferred(output:NativeOCRSharedBoundary396.Output,actualOld:[CGPoint],
                          basis:NativeOCRSharedBoundary396.Basis,nativeW:CGFloat)
        -> (index:Int,score:Double,receipt:[String:Any])? {
        guard convex(actualOld),nativeW.isFinite,nativeW>0,nativeW<100_000,
              basis.origin.x.isFinite,basis.origin.y.isFinite,
              abs(hypot(basis.normal.x,basis.normal.y)-1)<1e-6,
              abs(hypot(basis.along.x,basis.along.y)-1)<1e-6,
              abs(basis.normal.x*basis.along.x+basis.normal.y*basis.along.y)<1e-6,
              output.proposals.count<=8,!output.proposals.isEmpty,
              output.receipt["family"] as? String=="repair402-outline-extension",
              output.receipt["detectorSamplingBudgetReached"] as? Bool==false,
              let rows=output.receipt["sourceSupportComponents"] as? [[String:Any]],rows.count<=20_000 else{return nil}

        // Reconstruct only the capture's indexing transform from existing actual
        // contrast witnesses. Do not manufacture pixels or reread an image.
        var width:Int?, origin:CGPoint?
        var triples:[[[String:Any]]]=[]
        for row in rows {
            triples += row["positiveSourceContrast"] as? [[[String:Any]]] ?? []
        }
        for t in triples where t.count==3 {
            guard let p=point(t[0]),let q=point(t[1]),
                  let i=t[0]["actualLocalPixelIndex"] as? Int,
                  let j=t[1]["actualLocalPixelIndex"] as? Int else{continue}
            let dx=Double(q.x-p.x),dy=Double(q.y-p.y)
            guard abs(dx.rounded()-dx)<1e-6,abs(dy.rounded()-dy)<1e-6,abs(dy)>0.5 else{continue}
            let value=(Double(j-i)-dx)/dy
            guard value.isFinite,value>=3,value<=600_000,abs(value.rounded()-value)<1e-6 else{return nil}
            let w=Int(value.rounded())
            if let prior=width,prior != w{return nil};width=w
        }
        guard let w=width else{return nil}
        for t in triples {
            for v in t {
                guard let p=point(v),let i=v["actualLocalPixelIndex"] as? Int,i<600_000 else{return nil}
                let o=CGPoint(x:p.x-CGFloat(i%w)-0.5,y:p.y-CGFloat(i/w)-0.5)
                if let prior=origin,abs(prior.x-o.x)>1e-6 || abs(prior.y-o.y)>1e-6{return nil}
                origin=o
            }
        }
        guard let o=origin else{return nil}
        func world(_ i:Int)->CGPoint {CGPoint(x:o.x+CGFloat(i%w)+0.5,y:o.y+CGFloat(i/w)+0.5)}
        func validWitness(_ v:[String:Any])->Bool {
            guard let p=point(v),let i=v["actualLocalPixelIndex"] as? Int,i<600_000 else{return false}
            let q=world(i);return abs(p.x-q.x)<1e-6 && abs(p.y-q.y)<1e-6
        }
        var components=[Int:Component](),pixelOwner=[Int:Int]()
        for row in rows {
            guard let id=row["componentID"] as? Int,components[id]==nil,
                  row["originalRGBCCClippedAtCapture"] as? Bool==false,
                  let count=row["actualPixelCount"] as? Int,count>0,count<=200_000,
                  let anchors=row["actualRootPrivateBodyAnchors"] as? Int,anchors>=0,anchors<=count,
                  let bounds=row["projectedActualCellBounds"] as? [Double],bounds.count==4,
                  bounds.allSatisfy({$0.isFinite}),bounds[0]<=bounds[2],bounds[1]<=bounds[3],
                  let runs=row["actualLocalRunsYXCount"] as? [[Int]] else{return nil}
            var pixels:[Int]=[]
            for run in runs {
                guard run.count==3,run[0]>=0,run[0]<600_000/w,run[1]>=0,run[2]>0,
                      run[2]<=w,run[1]<=w-run[2],pixels.count<=count-run[2] else{return nil}
                for x in run[1]..<(run[1]+run[2]) {
                    let i=run[0]*w+x
                    guard pixelOwner[i]==nil else{return nil}
                    pixelOwner[i]=id;pixels.append(i)
                }
            }
            guard pixels.count==count else{return nil}
            // Bind the supplied basis to the already computed source-cell bounds.
            // A stale/rotated caller basis must not reinterpret detached spacing.
            let nr=Double(abs(basis.normal.x)+abs(basis.normal.y))*0.5
            let ar=Double(abs(basis.along.x)+abs(basis.along.y))*0.5
            var measured=[Double.infinity,Double.infinity,-Double.infinity,-Double.infinity]
            for i in pixels {
                let p=world(i),x=p.x-basis.origin.x,y=p.y-basis.origin.y
                let n=Double(x*basis.normal.x+y*basis.normal.y)
                let a=Double(x*basis.along.x+y*basis.along.y)
                measured[0]=min(measured[0],n-nr);measured[2]=max(measured[2],n+nr)
                measured[1]=min(measured[1],a-ar);measured[3]=max(measured[3],a+ar)
            }
            guard (0..<4).allSatisfy({abs(measured[$0]-bounds[$0])<1e-5}) else{return nil}
            var contrast=0
            for t in row["positiveSourceContrast"] as? [[[String:Any]]] ?? [] {
                guard t.count==3,t.allSatisfy(validWitness),
                      let i=t[0]["actualLocalPixelIndex"] as? Int,pixelOwner[i]==id,
                      let a=t[0]["RGB"] as? [Int],let b=t[1]["RGB"] as? [Int],let c=t[2]["RGB"] as? [Int],
                      let p=point(t[0]),let q=point(t[1]),let z=point(t[2]) else{continue}
                let dx=q.x-p.x,dy=q.y-p.y
                if abs(abs(dx)+abs(dy)-1)<1e-6,abs(z.x-q.x-dx)<1e-6,abs(z.y-q.y-dy)<1e-6,
                   distance(a,b)>=40,distance(b,c)<=16 {contrast += 1}
            }
            components[id] = .init(id:id,anchors:anchors,count:count,contrast:contrast,pixels:pixels,
                bounds:bounds,detectors:Set(row["detectorOrdinals"] as? [Int] ?? []))
        }
        let ccw=(actualOld[1].x-actualOld[0].x)*(actualOld[2].y-actualOld[1].y) -
            (actualOld[1].y-actualOld[0].y)*(actualOld[2].x-actualOld[1].x)>0
        let normals=(0..<4).map {i -> CGPoint in
            let a=actualOld[i],b=actualOld[(i+1)%4],dx=b.x-a.x,dy=b.y-a.y,len=hypot(dx,dy)
            return ccw ? CGPoint(x:dy/len,y:-dx/len):CGPoint(x:-dy/len,y:dx/len)
        }
        func plane(_ p:CGPoint,_ n:CGPoint)->Double {Double(p.x*n.x+p.y*n.y)}
        let oldPlanes=(0..<4).map{plane(actualOld[$0],normals[$0])}
        let chains=output.receipt["sourceTerminalChains"] as? [[String:Any]] ?? []
        var ranked:[Ranked]=[]
        for (index,p) in output.proposals.enumerated() {
            let r=p.receipt
            guard convex(p.polygon),actualOld.allSatisfy({NativeOCRSharedBoundary396.contains(p.polygon,$0)}),
                  r["family"] as? String=="repair402-outline-extension",
                  r["actual386PriorEnclosed"] as? Bool==true,r["sourceOnlyExpansionNoPadding"] as? Bool==true,
                  r["newlyExcludedOriginalGGBodyPixels"] as? Int==0,
                  r["newlyExcludedActualNativeCellCenters"] as? Int==0,
                  r["authenticatedRGBAIsActualCaptureLimit"] as? Bool==true,
                  let capturedOld=r["actual386Old"] as? [[Double]],capturedOld.count==4,
                  (0..<4).allSatisfy({capturedOld[$0].count==2 && abs(capturedOld[$0][0]-Double(actualOld[$0].x))<1e-6 && abs(capturedOld[$0][1]-Double(actualOld[$0].y))<1e-6}),
                  let list=r["sourceSupportComponentIDs"] as? [Int],!list.isEmpty,
                  let extrema=r["edgeActualSupport"] as? [[String:Any]],extrema.count==4,
                  let changes=r["signedEdgePlaneChanges"] as? [Double],changes.count==4 else{continue}
            let selected=Set(list)
            guard selected.count==list.count,selected.allSatisfy({components[$0] != nil}) else{continue}
            var reached=Set(selected.filter{components[$0]!.anchors>=2 && components[$0]!.contrast>=3})
            let roots=reached
            guard !roots.isEmpty else{continue}
            let paths=r["actualSelectedContactPaths"] as? [[String:Any]] ?? []
            var usedContacts:[[String:Any]]=[],usedChains:[[String:Any]]=[]
            let rf=Set(r["rootRFTextQueries"] as? [Int] ?? [])
            for _ in 0..<11 {
                var additions=Set<Int>()
                for path in paths {
                    guard let parent=path["fromComponentID"] as? Int,reached.contains(parent),
                          let child=path["componentID"] as? Int,selected.contains(child),!reached.contains(child),
                          let count=path["actualCardinalContactCount"] as? Int,count>=3,
                          let pairs=path["actualPixelContactWitnesses"] as? [[[String:Any]]] else{continue}
                    let valid=pairs.filter {pair in
                        guard pair.count==2,pair.allSatisfy(validWitness),let a=point(pair[0]),let b=point(pair[1]),
                              let i=pair[0]["actualLocalPixelIndex"] as? Int,pixelOwner[i]==parent,
                              let j=pair[1]["actualLocalPixelIndex"] as? Int,pixelOwner[j]==child else{return false}
                        return abs(abs(a.x-b.x)+abs(a.y-b.y)-1)<1e-6
                    }
                    let c=components[child]!
                    if valid.count>=3 && (c.contrast>=3 || c.count<=max(16,Int(nativeW*2))) {
                        additions.insert(child);usedContacts.append(path)
                    }
                }
                for chain in chains {
                    guard let parent=chain["fromComponentID"] as? Int,reached.contains(parent),
                          let child=chain["componentID"] as? Int,selected.contains(child),!reached.contains(child),
                          let db=chain["actualRootDetectorOrdinals"] as? [Int],!db.isEmpty,
                          let queries=chain["commonRootRFTextQueries"] as? [Int],!rf.intersection(queries).isEmpty,
                          let scale=chain["gapScaleNativeW"] as? Double,scale>0,scale<=1,
                          let c=components[child],c.contrast>=3 else{continue}
                    let a=components[parent]!.bounds,b=c.bounds
                    let gap=max(0,max(a[1]-b[3],b[1]-a[3]))
                    let lateral=abs((a[0]+a[2]-b[0]-b[2])*0.5)
                    if gap<=Double(nativeW)*scale+1e-6,lateral<=Double(nativeW)*0.6+1e-6 {
                        additions.insert(child);usedChains.append(chain)
                    }
                }
                if additions.isEmpty{break};reached.formUnion(additions)
            }
            // No unexplained selected colour components or omitted observed caps.
            guard reached==selected else{continue}
            let foreign=Set(r["otherDetectorEvidenceOrdinals"] as? [Int] ?? [])
            var recovered=0,total=0,foreignAcquisition=false,fullyEnclosed=true
            for id in selected {
                let c=components[id]!
                for i in c.pixels {
                    let v=world(i);total += 1
                    if !NativeOCRSharedBoundary396.contains(p.polygon,v){fullyEnclosed=false}
                    if !NativeOCRSharedBoundary396.contains(actualOld,v) {
                        recovered += 1
                        if !c.detectors.intersection(foreign).isEmpty{foreignAcquisition=true}
                    }
                }
            }
            guard fullyEnclosed,recovered>=3,!foreignAcquisition else{continue}
            var moved=0,edgeAgreement=true
            for edge in 0..<4 {
                let n=normals[edge],qPlane=plane(p.polygon[edge],n),delta=qPlane-oldPlanes[edge]
                guard changes[edge].isFinite,abs(delta-changes[edge])<1e-5,delta>=(-1e-6) else{edgeAgreement=false;break}
                if delta>0.25 {
                    guard validWitness(extrema[edge]),let v=point(extrema[edge]),
                          let i=extrema[edge]["actualLocalPixelIndex"] as? Int,
                          let id=pixelOwner[i],reached.contains(id) else{edgeAgreement=false;break}
                    let observedPlane=plane(v,n)+Double(abs(n.x)+abs(n.y))*0.5
                    if abs(observedPlane-qPlane)>1e-5 {edgeAgreement=false;break}
                    moved += 1
                }
            }
            guard edgeAgreement,moved>0 else{continue}
            let anchorCount=roots.reduce(0){$0+components[$1]!.anchors}
            let anchorStrength=min(1,Double(anchorCount)/8)
            let closureStrength=Double(selected.filter{components[$0]!.contrast>=3}.count)/Double(selected.count)
            // 0.60..0.90 before source recovery/compactness comparison below.
            let base=0.60+0.15*anchorStrength+0.15*closureStrength
            ranked.append(.init(index:index,recovered:recovered,area:area(p.polygon),base:base,receipt:[
                "policy":"source-choice402-outline","sourceOnlyNomination":true,
                "rootComponentIDs":roots.sorted(),"validatedComponentIDs":selected.sorted(),
                "actualPrivateRootGGAnchors":anchorCount,"verifiedStableContrastComponents":selected.filter{components[$0]!.contrast>=3}.sorted(),
                "actualContactPaths":usedContacts,"RFDBDetachedLinks":usedChains,
                "observedSelectedPixels":total,"observedOutsideOldPixelsRecovered":recovered,
                "actualSourceBasisBoundsVerified":true,"observedSelectedSourceExtentEnclosed":true,"movedEdgesWithActualSupport":moved,
                "newlyExcludedGGBodyPixels":0,"newlyExcludedNativeCellCenters":0,
                "foreignDetectorAcquisitionObserved":false,"captureWidthInferredFromActualWitnesses":w,
                "clippedUnresolvedComponents":output.receipt["clippedUnresolvedComponents"] ?? 0,
                "completeSourceForegroundPreservationClaimed":false,"ownershipClaimed":false,
                "nativeAdmissionGranted":false,"allNativeGuardsStillRequired":true,
                "unresolved":"Open/unexported components, terminal semantics and unobserved foreign pixels remain unresolved."
            ]))
        }
        guard let maximum=ranked.map({$0.recovered}).max(),maximum>0 else{return nil}
        let oldArea=area(actualOld)
        var best:(index:Int,score:Double,receipt:[String:Any])?
        for var candidate in ranked {
            let recoveryAgreement=Double(candidate.recovered)/Double(maximum)
            // A smaller alternative must not omit strongly observed extent.
            guard recoveryAgreement>=0.98 else{continue}
            let compactness=min(1,oldArea/max(oldArea,candidate.area))
            let score=min(1,max(0,candidate.base+0.08*recoveryAgreement+0.02*compactness))
            candidate.receipt["scoreTerms"]=["anchoredClosedSourceBase":candidate.base,
                "observedRecoveryAgreement":recoveryAgreement,"oldToProposedAreaRatio":compactness]
            candidate.receipt["scoreIsProbabilityOrCompleteness"]=false
            candidate.receipt["score"]=score
            if best==nil || score>best!.score+1e-12 {
                best=(candidate.index,score,candidate.receipt)
            }
        }
        return best
    }
}
