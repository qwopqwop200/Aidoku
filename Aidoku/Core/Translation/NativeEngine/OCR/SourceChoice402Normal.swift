import Foundation
import CoreGraphics

/// Source-only nomination from the already computed normal402/396 receipts.
/// Never reads images, GT, source IDs or external state; never grants admission.
enum SourceChoice402Normal {
    typealias K = NativeOCRSharedBoundary396
    private struct CellWitness {let index:Int;let point:CGPoint;let rgb:[Int];let gg:Bool;let native:Bool}
    private struct Component {
        let id:Int;let runs:[[Int]];let pixels:Int;let gg:Int;let anchors:Int;let closed:Bool
        let contrast:Int;let contrastIndices:[[Int]];let colour:[Int];let contacts:[(Int,Int)];let nativeContrast:Bool
    }
    private struct Frame {let width:Int;let origin:CGPoint}
    private struct Assessment {let index:Int;let score:Double;let movement:Double;let eligible:Bool;let receipt:[String:Any]}
    private static func number(_ v:Any?)->Double? {guard let n=v as? NSNumber,n.doubleValue.isFinite else{return nil};return n.doubleValue}
    private static func integer(_ v:Any?)->Int? {guard let n=number(v),n.rounded()==n,n>=0,n<600_001 else{return nil};return Int(n)}
    private static func point(_ v:Any?)->CGPoint? {guard let a=v as? [Any],a.count==2,let x=number(a[0]),let y=number(a[1]) else{return nil};return .init(x:x,y:y)}
    private static func witness(_ value:Any)->CellWitness? {
        guard let d=value as? [String:Any],let index=integer(d["actualLocalPixelIndex"]),let p=point(d["center"]),
            let c=d["RGB"] as? [Int],c.count==3,c.allSatisfy({(0...255).contains($0)}) else{return nil}
        return .init(index:index,point:p,rgb:c,gg:d["rootGGBody"] as? Bool==true,native:d["nativeRootCell"] as? Bool==true)
    }
    private static func delta(_ a:[Int],_ b:[Int])->Int {max(abs(a[0]-b[0]),abs(a[1]-b[1]),abs(a[2]-b[2]))}
    private static func valid(_ q:[CGPoint])->Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return false}
        let c=(0..<4).map{i -> CGFloat in let a=q[i],b=q[(i+1)%4],d=q[(i+2)%4];return (b.x-a.x)*(d.y-b.y)-(b.y-a.y)*(d.x-b.x)}
        return c.allSatisfy{$0>1e-8} || c.allSatisfy{$0 < -1e-8}
    }
    private static func frame(_ samples:[CellWitness])->Frame? {
        guard let first=samples.first else{return nil}
        for other in samples.dropFirst() {
            let dy=other.point.y-first.point.y,dx=other.point.x-first.point.x
            guard abs(dy)>0.5 else{continue}
            let value=(Double(other.index-first.index)-Double(dx))/Double(dy)
            guard value.isFinite,value>2,value<=600_000,abs(value-value.rounded())<1e-6 else{continue}
            let width=Int(value.rounded()),origin=CGPoint(x:first.point.x-CGFloat(first.index%width)-0.5,y:first.point.y-CGFloat(first.index/width)-0.5)
            if samples.allSatisfy({abs($0.point.x-origin.x-CGFloat($0.index%width)-0.5)<1e-6 && abs($0.point.y-origin.y-CGFloat($0.index/width)-0.5)<1e-6}) {return .init(width:width,origin:origin)}
        };return nil
    }
    private static func assessments(output:K.Output,actualOld old:[CGPoint],basis:K.Basis,nativeW:CGFloat)->[Assessment] {
        func stop(_ reason:String)->[Assessment] {[.init(index:-1,score:0,movement:0,eligible:false,receipt:["eligible":false,"reason":reason,"admissionGranted":false])]}
        guard valid(old),output.proposals.count<=8,nativeW.isFinite,nativeW>0,
            abs(hypot(basis.normal.x,basis.normal.y)-1)<1e-6,abs(hypot(basis.along.x,basis.along.y)-1)<1e-6,
            abs(basis.normal.x*basis.along.x+basis.normal.y*basis.along.y)<1e-6,
            let source=output.receipt["source396Observation"] as? [String:Any],let raw=source["sourceSupportComponents"] as? [[String:Any]],raw.count<=20_000 else{return stop("missing-actual-396-source-component-receipts")}
        var components:[Component]=[],samples:[CellWitness]=[],pixelCount=0
        for d in raw {
            guard let id=integer(d["componentID"]),let runs=d["actualLocalRunsYXCount"] as? [[Int]],let count=integer(d["actualPixelCount"]),
                let gg=integer(d["originalGGBodyPixels"]),let anchors=integer(d["actualRootPrivateBodyAnchors"]),
                let colour=d["RGB"] as? [Int],colour.count==3,colour.allSatisfy({(0...255).contains($0)}) else{return stop("incomplete-actual-RGB-component")}
            var contrast=0,contrastIndices:[[Int]]=[],nativeContrast=false,contacts:[(Int,Int)]=[],total=0
            for run in runs {guard run.count==3,run[0]>=0,run[1]>=0,run[2]>0,run[2]<=600_000,total<=600_000-run[2] else{return stop("invalid-actual-RGB-RLE")};total += run[2]}
            guard total==count,pixelCount<=600_000-total else{return stop("source-pixel-budget-or-count-mismatch")};pixelCount += total
            for triple in (d["positiveSourceContrast"] as? [[Any]]) ?? [] {
                let w=triple.compactMap(witness)
                guard w.count==3,Set(w.map{$0.index}).count==3,
                    delta(w[0].rgb,w[1].rgb)>=40,delta(w[1].rgb,w[2].rgb)<=16,
                    abs(w[1].point.x-w[0].point.x)+abs(w[1].point.y-w[0].point.y)>0.999999,
                    abs(w[1].point.x-w[0].point.x)+abs(w[1].point.y-w[0].point.y)<1.000001,
                    abs((w[2].point.x-w[1].point.x)-(w[1].point.x-w[0].point.x))<1e-6,
                    abs((w[2].point.y-w[1].point.y)-(w[1].point.y-w[0].point.y))<1e-6 else{continue}
                contrast += 1;contrastIndices.append(w.map{$0.index});nativeContrast = nativeContrast || w[0].native
                if samples.count<1024{samples.append(contentsOf:w)}
            }
            for pair in (d["positiveRGBContact"] as? [[Any]]) ?? [] {
                let w=pair.compactMap(witness)
                guard w.count==2,abs(w[0].point.x-w[1].point.x)+abs(w[0].point.y-w[1].point.y)<1.000001,
                    hypot(w[0].point.x-w[1].point.x,w[0].point.y-w[1].point.y)>0.5 else{continue}
                contacts.append((w[0].index,w[1].index));if samples.count<1024{samples.append(contentsOf:w)}
            }
            components.append(.init(id:id,runs:runs,pixels:count,gg:gg,anchors:anchors,closed:d["originalRGBCCClippedAtCapture"] as? Bool==false,
                contrast:contrast,contrastIndices:contrastIndices,colour:colour,contacts:contacts,nativeContrast:nativeContrast))
        }
        guard Set(components.map{$0.id}).count==components.count,let grid=frame(samples) else{return stop("actual-pixel-coordinate-grid-not-uniquely-supported")}
        // This index maps actual recorded RGB component cells only. It is NOT an
        // ownership mask and never rasterizes a source/hull/quad or RF rectangle.
        var componentAtPixel:[Int:Int]=[:]
        for c in components {for run in c.runs {
            guard run[0]<=600_000/grid.width,run[1]<grid.width,run[2]<=grid.width-run[1] else{return stop("RGB-run-outside-observed-coordinate-grid")}
            for x in run[1]..<(run[1]+run[2]) {let i=run[0]*grid.width+x;guard i<600_000,componentAtPixel.updateValue(c.id,forKey:i)==nil else{return stop("overlapping-actual-RGB-component-runs")}}
        }}
        let byID=Dictionary(uniqueKeysWithValues:components.map{($0.id,$0)})
        let verifiedContrast=Dictionary(uniqueKeysWithValues:components.map { c in
            (c.id,c.contrastIndices.filter{triple in componentAtPixel[triple[0]]==c.id && componentAtPixel[triple[1]] != c.id && componentAtPixel[triple[2]] != c.id}.count)
        })
        var qualified=Set(components.filter{$0.closed && (verifiedContrast[$0.id] ?? 0)>=3 && $0.gg>0}.map{$0.id})
        // A thin finite rim can be too narrow for the fill component's own
        // two-cell exterior witness. Qualify the measured fill->rim contact
        // jointly with the rim's real stable exterior, without inventing ink.
        var closureCount:[Int:Int]=[:],jointClosure:[Int:[Int]]=[:]
        for c in components where c.closed && (verifiedContrast[c.id] ?? 0)>=3 {
            var parents:[Int:Set<Int>]=[:]
            for link in c.contacts {
                guard let parentID=componentAtPixel[link.0],componentAtPixel[link.1]==c.id,
                    let parent=byID[parentID],parent.closed,parent.gg>0,parent.anchors>=2,
                    delta(parent.colour,c.colour)>=40,
                    abs(link.0%grid.width-link.1%grid.width)+abs(link.0/grid.width-link.1/grid.width)==1 else{continue}
                parents[parentID,default:[]].insert(link.1)
            }
            for (parent,points) in parents where points.count>=3 {
                qualified.insert(parent);qualified.insert(c.id)
                closureCount[parent]=max(closureCount[parent] ?? 0,verifiedContrast[c.id] ?? 0)
                jointClosure[parent]=[parent,c.id];jointClosure[c.id]=[parent,c.id]
            }
        }
        let nativeRootColours=components.filter{qualified.contains($0.id) && $0.anchors>=2}.map{$0.colour}
        guard !qualified.isEmpty,!nativeRootColours.isEmpty else{return stop("no-closed-root-GG-and-real-native-anchor-agreement")}
        for c in components where c.closed && (verifiedContrast[c.id] ?? 0)>=3 && c.nativeContrast && nativeRootColours.contains(where:{delta($0,c.colour)<=24}) {qualified.insert(c.id)}
        for _ in 0..<3 {
            var add=Set<Int>()
            for c in components where c.closed && (verifiedContrast[c.id] ?? 0)>=3 && !qualified.contains(c.id) {
                let links=c.contacts.filter{p in
                    guard let parent=componentAtPixel[p.0],componentAtPixel[p.1]==c.id else{return false}
                    let dx=abs(p.0%grid.width-p.1%grid.width),dy=abs(p.0/grid.width-p.1/grid.width)
                    return qualified.contains(parent) && dx+dy==1
                }
                if Set(links.map{$0.1}).count>=3 {add.insert(c.id)}
            }
            qualified.formUnion(add);if add.isEmpty{break}
        }
        let foreground=components.filter{qualified.contains($0.id)},anchorCount=foreground.reduce(0){$0+$1.anchors}
        func dot(_ p:CGPoint,_ n:CGPoint)->CGFloat {p.x*n.x+p.y*n.y}
        let winding=(old[1].x-old[0].x)*(old[2].y-old[1].y)-(old[1].y-old[0].y)*(old[2].x-old[1].x)
        var normals:[CGPoint]=[],planes:[CGFloat]=[]
        for i in 0..<4 {let a=old[i],b=old[(i+1)%4],dx=b.x-a.x,dy=b.y-a.y,l=hypot(dx,dy)
            let n=winding>0 ? CGPoint(x:dy/l,y:-dx/l):CGPoint(x:-dy/l,y:dx/l);normals.append(n);planes.append(dot(a,n))}
        func alongAlignment(_ i:Int)->CGFloat {let a=old[i],b=old[(i+1)%4];return abs((b.x-a.x)*basis.along.x+(b.y-a.y)*basis.along.y)/hypot(b.x-a.x,b.y-a.y)}
        let sides=alongAlignment(0)+alongAlignment(2)>alongAlignment(1)+alongAlignment(3) ? [0,2]:[1,3]
        let caps=(0..<4).filter{!sides.contains($0)}
        var extents=[CGFloat](repeating:-CGFloat.infinity,count:4),extremeComponents=[Int](repeating:-1,count:4),oldObservedPixels=0
        for c in foreground {for run in c.runs {for x in run[1]..<(run[1]+run[2]) {
            let p=CGPoint(x:grid.origin.x+CGFloat(x)+0.5,y:grid.origin.y+CGFloat(run[0])+0.5)
            guard K.contains(old,p) else{continue};oldObservedPixels += 1
            for edge in sides {let v=dot(p,normals[edge])+(abs(normals[edge].x)+abs(normals[edge].y))*0.5
                if v>extents[edge]{extents[edge]=v;extremeComponents[edge]=c.id}}
        }}}
        guard oldObservedPixels>0 else{return stop("no-closed-source-support-inside-actual-old")}
        var results:[Assessment]=[]
        for (index,p) in output.proposals.enumerated() {
            let q=p.polygon,rec=p.receipt
            var hard:[String]=[]
            guard valid(q),q.allSatisfy({K.contains(old,$0)}) else{results.append(.init(index:index,score:0,movement:0,eligible:false,receipt:["index":index,"eligible":false,"reason":"not-valid-inward-old-axis-proposal"]));continue}
            guard let prior=rec["actual386Old"] as? [[Double]],prior.count==4,zip(prior,old).allSatisfy({pair in let a=pair.0,b=pair.1;return a.count==2 && abs(a[0]-Double(b.x))<1e-6 && abs(a[1]-Double(b.y))<1e-6}),
                rec["family"] as? String=="repair402-normal-contraction",rec["originalHeadTailEdgePlanesExact"] as? Bool==true,
                rec["noAlongContraction"] as? Bool==true,let ggLoss=integer(rec["actualRootGGNewlyExcludedPixels"]) else{results.append(.init(index:index,score:0,movement:0,eligible:false,receipt:["index":index,"eligible":false,"reason":"missing-normal402-source-retention-receipts"]));continue}
            if ggLoss>0{hard.append("recorded-actual-root-GG-loss")}
            var newPlanes:[CGFloat]=[]
            for edge in 0..<4 {
                let a=q[edge],b=q[(edge+1)%4],n=normals[edge]
                if abs(dot(a,n)-dot(b,n))>1e-6{hard.append("old-edge-direction-changed")}
                newPlanes.append(dot(a,n))
            }
            if !caps.allSatisfy({abs(newPlanes[$0]-planes[$0])<1e-6}){hard.append("original-cap-plane-changed")}
            let changed=sides.filter{planes[$0]-newPlanes[$0]>0.25}
            if changed.isEmpty{hard.append("no-material-normal-contraction")}
            let movement=changed.reduce(Double(0)){$0+Double(max(0,planes[$1]-newPlanes[$1])/nativeW)}
            var lost=0,witnesses:[[Double]]=[]
            for c in foreground {for run in c.runs {for x in run[1]..<(run[1]+run[2]) {
                let v=CGPoint(x:grid.origin.x+CGFloat(x)+0.5,y:grid.origin.y+CGFloat(run[0])+0.5)
                if K.contains(old,v) && !K.contains(q,v){lost += 1;if witnesses.count<4{witnesses.append([Double(v.x),Double(v.y)])}}
            }}}
            if lost>0{hard.append("actual-closed-source-fill-or-rim-pixel-loss")}
            var closure=0.0,margin=0.0,edgeEvidence:[[String:Any]]=[]
            for edge in changed {
                guard let c=byID[extremeComponents[edge]],extents[edge].isFinite else{hard.append("no-actual-source-extreme-for-contracted-side");continue}
                let padding=max(0,Double(newPlanes[edge]-extents[edge])/Double(nativeW))
                let positiveClosure=max(verifiedContrast[c.id] ?? 0,closureCount[c.id] ?? 0)
                margin += padding;closure += 0.5+0.5*min(1,Double(positiveClosure)/6)
                edgeEvidence.append(["oldEdge":edge,"sourceComponentID":c.id,"verifiedContrastRelations":max(verifiedContrast[c.id] ?? 0,closureCount[c.id] ?? 0),"actualFillRimClosurePath":jointClosure[c.id] ?? [c.id],
                    "actualSourceCellExtremePlane":Double(extents[edge]),"proposalPlane":Double(newPlanes[edge]),"remainingSourceMarginOverNativeW":padding])
            }
            let count=Double(max(1,changed.count));closure /= count;margin /= count
            let extent=1/(1+4*margin),retention=lost==0 && ggLoss==0 ? 1.0:0.0
            let detector=rec["rootDetectorActualCellAgreement"] as? Bool==true
            let rf = ((rec["rootRFTextQueries"] as? [Int]) ?? []).isEmpty == false
            let corroboration=(anchorCount>=2 ? 0.5:0)+(detector ? 0.3:0)+(rf ? 0.2:0)
            let benefit=min(1,movement)
            let score=min(1,max(0,0.30*closure+0.30*extent+0.20*retention+0.15*corroboration+0.05*benefit))
            if score<0.72{hard.append("source-agreement-score-below-nomination-minimum")}
            let receipt:[String:Any]=["index":index,"eligible":hard.isEmpty,"sourceScore":score,"minimumSourceScore":0.72,
                "evidenceTerms":["closedRGBSupport":closure,"normalExtentAgreement":extent,"actualSupportRetention":retention,"GGNativeDetectorRFCorroboration":corroboration,"normalizedMarginRemoval":benefit],
                "weights":["closure":0.30,"extent":0.30,"retention":0.20,"corroboration":0.15,"benefit":0.05],
                "edgeEvidence":edgeEvidence,"qualifiedActualSourceComponentIDs":Array(qualified).sorted(),
                "verifiedActualRGBPixelsInsideOld":oldObservedPixels,"newlyExcludedQualifiedSourcePixels":lost,"lossWitnesses":witnesses,
                "recordedGGNewlyExcludedPixels":ggLoss,"nativeCellGeometryLossDiagnosticOnly":rec["actualNativeCellCentersNewlyExcluded"] ?? NSNull(),
                "nativeGeometryLossUsedAsForegroundVeto":false,"originalCapPlanesRetained":!hard.contains("original-cap-plane-changed"),"geometricCapPlanesAreNotPureProtectedCapsProof":true,"pureDirectProtectedCapsOriginCheckRequired":true,
                "hardNominationFailures":hard,"completeForegroundOrOwnershipClaimed":false,"admissionGranted":false,
                "nominationOnly":true,"scoreIsCalibratedProbability":false,"typedPureCap401AndAllActualNativeGatesRequired":true,"unrecordedDetachedQuoteDiacriticAssociationStillRequired":true]
            results.append(.init(index:index,score:score,movement:movement,eligible:hard.isEmpty,receipt:receipt))
        };return results
    }
    static func preferred(output:NativeOCRSharedBoundary396.Output,actualOld:[CGPoint],basis:NativeOCRSharedBoundary396.Basis,nativeW:CGFloat)->(index:Int,score:Double,receipt:[String:Any])? {
        let candidates=assessments(output:output,actualOld:actualOld,basis:basis,nativeW:nativeW).filter{$0.eligible}.sorted {
            if abs($0.score-$1.score)>1e-12{return $0.score>$1.score}
            if abs($0.movement-$1.movement)>1e-12{return $0.movement<$1.movement}
            return $0.index<$1.index
        }
        guard let best=candidates.first else{return nil}
        return(best.index,best.score,best.receipt)
    }
    /// Optional parent telemetry for nil nomination; no external lookup/review.
    static func diagnostics(output:K.Output,actualOld:[CGPoint],basis:K.Basis,nativeW:CGFloat)->[[String:Any]] {
        assessments(output:output,actualOld:actualOld,basis:basis,nativeW:nativeW).map{$0.receipt}
    }
}
