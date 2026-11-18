import Foundation
import CoreGraphics

// Source-only nomination. Never grants native admission or ownership.
// Derived from the existing396 bounded RGB observer; original396 remains unchanged.
enum NativeOCRRepair402Outline {
    typealias Basis = NativeOCRSharedBoundary396.Basis
    typealias Evidence = NativeOCRSharedBoundary396.Evidence
    typealias Proposal = NativeOCRSharedBoundary396.Proposal
    typealias Output = NativeOCRSharedBoundary396.Output
    private struct CC {
        let pixels:[Int];let anchors:Int;let body:Int;let clipped:Bool;let perimeter:Int
        let n0:CGFloat;let n1:CGFloat;let a0:CGFloat;let a1:CGFloat
        let edgeMax:[CGFloat];let edgePixels:[Int];let colour:SIMD3<Int>
        let contrast:[[Int]]
    }
    static func contains(_ q:[CGPoint],_ p:CGPoint)->Bool {
        var positive=false,negative=false
        for i in 0..<4 {let a=q[i],b=q[(i+1)%4],c=(b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
            positive = positive || c>1e-7;negative = negative || c < -1e-7}
        return !positive || !negative
    }
    static func generate(actualOld old:[CGPoint],basis f:Basis,nativeW mw:CGFloat,evidence e:Evidence)->Output {
        func none(_ s:String)->Output {.init(proposals:[],receipt:["family":"repair402-outline-extension","status":s,"admissionGranted":false])}
        let r=e.rgba,w=r.width,h=r.height
        guard w>2,h>2,w<=600_000/h,r.bytesPerRow>=w*4,h<=Int.max/r.bytesPerRow,
            r.bytes.count==h*r.bytesPerRow,e.body.count==w*h,old.count==4,
            old.allSatisfy({$0.x.isFinite && $0.y.isFinite}),r.origin.x.isFinite,r.origin.y.isFinite,f.origin.x.isFinite,f.origin.y.isFinite,mw.isFinite,mw>0,mw<100_000,
            abs(hypot(f.normal.x,f.normal.y)-1)<1e-6,abs(hypot(f.along.x,f.along.y)-1)<1e-6,
            abs(f.normal.x*f.along.x+f.normal.y*f.along.y)<1e-6,e.detectors.count<=64,e.rf.count<=160,
            e.nativeCellCenters.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
            e.rf.allSatisfy({$0.bounds.count==4 && $0.bounds.allSatisfy({$0.isFinite}) &&
                $0.bounds[0]<=$0.bounds[2] && $0.bounds[1]<=$0.bounds[3] && $0.confidence.isFinite}) else{return none("invalid-bounded-source-session")}
        let turns=(0..<4).map{i -> CGFloat in let a=old[i],b=old[(i+1)%4],c=old[(i+2)%4];return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)}
        guard turns.allSatisfy({$0>1e-8}) || turns.allSatisfy({$0 < -1e-8}) else{return none("invalid-actual-old-convexity")}
        let ccw=turns[0]>0
        var normals:[CGPoint]=[],planes:[CGFloat]=[]
        for i in 0..<4 {
            let a=old[i],b=old[(i+1)%4],dx=b.x-a.x,dy=b.y-a.y,len=hypot(dx,dy)
            let n=ccw ? CGPoint(x:dy/len,y:-dx/len):CGPoint(x:-dy/len,y:dx/len)
            normals.append(n);planes.append(n.x*a.x+n.y*a.y)
        }
        func world(_ i:Int)->CGPoint {CGPoint(x:r.origin.x+CGFloat(i%w)+0.5,y:r.origin.y+CGFloat(i/w)+0.5)}
        func project(_ p:CGPoint)->CGPoint {let x=p.x-f.origin.x,y=p.y-f.origin.y;return CGPoint(x:x*f.normal.x+y*f.normal.y,y:x*f.along.x+y*f.along.y)}
        func rgb(_ i:Int)->SIMD3<Int> {let k=(i/w)*r.bytesPerRow+(i%w)*4;return .init(Int(r.bytes[k]),Int(r.bytes[k+1]),Int(r.bytes[k+2]))}
        func dist(_ a:SIMD3<Int>,_ b:SIMD3<Int>)->Int {max(abs(a.x-b.x),abs(a.y-b.y),abs(a.z-b.z))}
        func index(_ x:Int,_ y:Int)->Int? {x>=0 && x<w && y>=0 && y<h ? y*w+x:nil}
        let pp=old.map(project),oldN0=pp.map(\.x).min()!,oldN1=pp.map(\.x).max()!,oldA0=pp.map(\.y).min()!,oldA1=pp.map(\.y).max()!
        var labels=[Int](repeating:-1,count:w*h),colours:[SIMD3<Int>]=[],colourCounts:[Int]=[],bodyIndices:[Int]=[]
        for i in labels.indices {
            if r.bytes[(i/w)*r.bytesPerRow+(i%w)*4+3] != 255{labels[i] = -2;continue}
            if e.body[i] != 0 {
                bodyIndices.append(i)
                if contains(old,world(i)) && e.privateAt(world(i)) {
                    let c=rgb(i)
                    if let k=colours.firstIndex(where:{dist($0,c)<=24}){colourCounts[k] += 1}
                    else if colours.count<16{colours.append(c);colourCounts.append(1)}
                }
            }
        }
        colours=colours.indices.filter{colourCounts[$0]>=2}.map{colours[$0]}
        guard !colours.isEmpty else{return none("no-actual-private-root-body-colours")}
        let dirs=[(-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)],card=[(-1,0),(1,0),(0,-1),(0,1)]
        let nr=(abs(f.normal.x)+abs(f.normal.y))*0.5,ar=(abs(f.along.x)+abs(f.along.y))*0.5
        var components:[CC]=[]
        for seed in labels.indices where labels[seed] == -1 {
            guard components.count<20_000 else{return none("component-budget-exceeded")}
            let id=components.count,reference=rgb(seed)
            var queue=[seed],cursor=0,anchors=0,bodyCount=0
            labels[seed]=id
            while cursor<queue.count {
                let i=queue[cursor];cursor += 1
                if e.body[i] != 0 {bodyCount += 1;if e.privateAt(world(i)) && contains(old,world(i)){anchors += 1}}
                for (dx,dy) in dirs {
                    guard let j=index(i%w+dx,i/w+dy),labels[j] == -1,dist(rgb(j),reference)<=32,dist(rgb(j),rgb(i))<=24 else{continue}
                    labels[j]=id;queue.append(j)
                }
            }
            var loN=CGFloat.infinity,hiN = -CGFloat.infinity,loA=CGFloat.infinity,hiA = -CGFloat.infinity
            var ex=[CGFloat](repeating:-CGFloat.infinity,count:4),ep=[Int](repeating:seed,count:4)
            var clipped=false,perimeter=0,contrast:[[Int]]=[]
            for i in queue {
                let p=world(i),v=project(p)
                loN=min(loN,v.x-nr);hiN=max(hiN,v.x+nr);loA=min(loA,v.y-ar);hiA=max(hiA,v.y+ar)
                for edge in 0..<4 {let n=normals[edge],z=n.x*p.x+n.y*p.y+(abs(n.x)+abs(n.y))*0.5
                    if z>ex[edge]{ex[edge]=z;ep[edge]=i}}
                for (dx,dy) in card {
                    guard let j=index(i%w+dx,i/w+dy),labels[j] != -2 else{clipped=true;perimeter += 1;continue}
                    if labels[j]==id{continue};perimeter += 1
                    if contrast.count<12,let k=index(i%w+2*dx,i/w+2*dy),labels[k] != -2,
                        dist(rgb(i),rgb(j))>=40,dist(rgb(j),rgb(k))<=16{contrast.append([i,j,k])}
                }
            }
            components.append(.init(pixels:queue,anchors:anchors,body:bodyCount,clipped:clipped,perimeter:perimeter,
                n0:loN,n1:hiN,a0:loA,a1:hiA,edgeMax:ex,edgePixels:ep,colour:reference,contrast:contrast))
        }
        // Only real finite CC boundaries drive an endpoint. Other clipped/open
        // components remain an uncertainty; they do NOT veto independent offers.
        let roots=components.indices.filter{components[$0].anchors>=2 && components[$0].contrast.count>=3 && !components[$0].clipped && components[$0].pixels.count<=200_000}
        guard !roots.isEmpty else{return none("no-finite-root-anchored-source-components")}
        guard roots.count<=256 else{return none("root-component-budget-exceeded")}
        var dbVotes=[Int:Set<Int>](),rfVotes=[Int:Set<Int>](),detectorQueries=0,queryBudgetHit=false
        let allPotential=components.indices.filter { id in
            let c=components[id],center=(c.n0+c.n1)*0.5
            return !c.clipped && c.pixels.count>=3 && c.pixels.count<=200_000 && c.contrast.count>=3 &&
                c.n1-c.n0<=mw*2 && c.a1-c.a0<=mw*2 && center>=oldN0-mw*0.25 && center<=oldN1+mw*0.25
        }
        // Limit graph work by source-relative proximity, never root/page IDs.
        let potential=Array(allPotential.sorted { lhs,rhs in
            let l=components[lhs],r=components[rhs]
            let lg=max(0,max(oldA0-l.a1,l.a0-oldA1)),rg=max(0,max(oldA0-r.a1,r.a0-oldA1))
            return lg==rg ? lhs<rhs:lg<rg
        }.prefix(512))
        // Component evidence query work is independently bounded. Truncating this
        // optional sampling never manufactures negative detector or RF evidence.
        for id in Array(Set(roots+potential)).sorted() {
            let pixels=components[id].pixels,count=min(16,pixels.count)
            var db=Set<Int>(),rf=Set<Int>(),dbHits=[Int:Int]()
            for k in 0..<count {
                let i=pixels[count==1 ? 0:k*(pixels.count-1)/(count-1)],p=world(i)
                for (ordinal,d) in e.detectors.enumerated() {
                    if detectorQueries>=2_000_000{queryBudgetHit=true;break}
                    detectorQueries += 1;if d.cells.contains(p){dbHits[ordinal,default:0] += 1;if dbHits[ordinal,default:0]>=2{db.insert(ordinal)}}
                }
                for v in e.rf where v.confidence>=0.5 && v.contains(p){rf.insert(v.query)}
            }
            dbVotes[id]=db;rfVotes[id]=rf
        }
        let rootRF=roots.reduce(into:Set<Int>()){$0.formUnion(rfVotes[$1] ?? [])}
        let rootDB=roots.contains { id in (dbVotes[id] ?? []).contains{e.detectors[$0].nativeRoot} }
        var contacts=[Int:[Int:Int]](),contactWitness=[Int:[[Int]]](),pairWitness=[Int:[Int:[[Int]]]]()
        // Actual short RGB contacts may add outer contour colours without any
        // palette ownership rule or hull fill. No ray/execution path from 395.
        var contactEdges=0
        for parent in components.indices where !components[parent].clipped && components[parent].pixels.count<=200_000 && components[parent].n1-components[parent].n0<=mw*2 {
            for i in components[parent].pixels {
                for (dx,dy) in card {
                    guard let j=index(i%w+dx,i/w+dy),labels[j]>=0,labels[j] != parent else{continue}
                    let id=labels[j],c=components[id]
                    guard !c.clipped,c.pixels.count<=200_000,c.perimeter>0,
                        c.n1-c.n0<=mw*2,c.a1-c.a0<=max(mw*3,components[parent].a1-components[parent].a0+mw),
                        CGFloat(c.pixels.count)/CGFloat(c.perimeter)<=max(2,mw*0.3) else{continue}
                    if contacts[parent]?[id]==nil {contactEdges += 1;if contactEdges>100_000{return none("RGB-contact-edge-budget-exceeded")}}
                    contacts[parent,default:[:]][id,default:0] += 1
                    if contactWitness[id,default:[]].count<6{contactWitness[id,default:[]].append([i,j])}
                    if (pairWitness[parent]?[id]?.count ?? 0) < 4 {
                        var row=pairWitness[parent] ?? [:];row[id,default:[]].append([i,j]);pairWitness[parent]=row
                    }
                }
            }
        }
        func witness(_ i:Int)->[String:Any] {let p=world(i),c=rgb(i);return ["actualLocalPixelIndex":i,"center":[Double(p.x),Double(p.y)],"RGB":[c.x,c.y,c.z],"rootGGBody":e.body[i] != 0,"nativeRootCell":e.privateAt(p),"outsideActualOld":!contains(old,p),"ownershipClaimed":false]}
        func runs(_ pixels:[Int])->[[Int]] {var out:[[Int]]=[];for i in pixels.sorted(){if let v=out.last,v[0]==i/w,v[1]+v[2]==i%w{out[out.count-1][2] += 1}else{out.append([i/w,i%w,1])}};return out}
        // Detached support requires independent actual sparse-root DB hits and
        // a shared RF text query. Colour equality is deliberately not required.
        // RF is a corroborating rectangle, never a foreground or ownership mask.
        var choices:[(String,Set<Int>,Bool)]=[("root-contact",Set(roots),true)]
        var chainReceipts:[[String:Any]]=[]
        for gapScale in [CGFloat(0.5),1.0] {
            var reached=Set(roots)
            for hop in 1...8 {
                var added=Set<Int>()
                for id in potential where !reached.contains(id) {
                    let db=(dbVotes[id] ?? []).filter{e.detectors[$0].nativeRoot}
                    let rf=(rfVotes[id] ?? []).intersection(rootRF)
                    guard !db.isEmpty,!rf.isEmpty else{continue}
                    let c=components[id]
                    let parent=reached.sorted().first { other in
                        let p=components[other]
                        let gap=max(0,max(c.a0-p.a1,p.a0-c.a1))
                        let lateral=abs((c.n0+c.n1-p.n0-p.n1)*0.5)
                        return gap<=mw*gapScale && lateral<=mw*0.6
                    }
                    guard let parent=parent else{continue}
                    added.insert(id)
                    chainReceipts.append(["componentID":id,"fromComponentID":parent,"hop":hop,
                        "gapScaleNativeW":Double(gapScale),"commonRootRFTextQueries":rf.sorted(),
                        "actualRootDetectorOrdinals":db.map{e.detectors[$0].ordinal}.sorted(),
                        "colourEqualityRequired":false,"sourceTerminalAssociationProven":false])
                }
                if added.isEmpty{break};reached.formUnion(added)
            }
            choices.append(("RF-DB-g\(Int(gapScale*100))-contact",reached,true))
        }
        choices.append(("root-fill",Set(roots),false))
        let variants=choices
        // Edge roles come from the supplied basis, not horizontal/vertical IDs.
        let normalBits=(0..<4).reduce(0) { bits,edge in
            let n=normals[edge]
            return abs(n.x*f.normal.x+n.y*f.normal.y)>=0.707106 ? bits | (1 << edge):bits
        }
        var offers:[Proposal]=[],seen=Set<String>(),supportUsed=Set<Int>(),rejectedGeometry=0
        for (name,base,includeContact) in variants {
            var ids=base
            var contactPaths:[[String:Any]]=[]
            var frontier=includeContact ? base:Set<Int>()
            for _ in 0..<3 {
                var added=Set<Int>()
                for parent in frontier.sorted() {
                    for id in (contacts[parent] ?? [:]).keys.sorted() where contacts[parent]![id]!>=3 && !ids.contains(id) {
                        added.insert(id)
                        contactPaths.append(["fromComponentID":parent,"componentID":id,
                            "actualCardinalContactCount":contacts[parent]![id]!,
                            "actualPixelContactWitnesses":(pairWitness[parent]?[id] ?? []).map{$0.map(witness)},
                            "ownershipClaimed":false])
                    }
                }
                ids.formUnion(added);frontier=added
                if added.isEmpty{break}
            }
            var target=[CGFloat](repeating:-CGFloat.infinity,count:4),extrema=[Int](repeating:-1,count:4)
            for id in ids.sorted() {for edge in 0..<4 where components[id].edgeMax[edge]>target[edge] {target[edge]=components[id].edgeMax[edge];extrema[edge]=components[id].edgePixels[edge]}}
            let edgeChoices=[15,normalBits]
            for bits in edgeChoices {
                if offers.count>=8{break}
                let proposed=(0..<4).map{bits & (1 << $0) != 0 ? max(planes[$0],target[$0]):planes[$0]}
                guard (0..<4).contains(where:{abs(proposed[$0]-planes[$0])>0.25}) else{continue}
                var q:[CGPoint]=[],valid=true
                for i in 0..<4 {
                    let j=(i+3)%4,a=normals[j],b=normals[i],u=proposed[j],v=proposed[i],det=a.x*b.y-a.y*b.x
                    if abs(det)<1e-8{valid=false;break}
                    q.append(CGPoint(x:(u*b.y-a.y*v)/det,y:(a.x*v-u*b.x)/det))
                }
                guard valid,q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.x>=r.origin.x && $0.x<=r.origin.x+CGFloat(w) && $0.y>=r.origin.y && $0.y<=r.origin.y+CGFloat(h)}) else{rejectedGeometry += 1;continue}
                let cross=(0..<4).map{i -> CGFloat in let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4];return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)}
                let convex=ccw ? cross.allSatisfy({$0>1e-8}):cross.allSatisfy({$0 < -1e-8})
                guard convex else{rejectedGeometry += 1;continue}
                let key=q.map{String(format:"%.7f,%.7f",Double($0.x),Double($0.y))}.joined(separator:";")
                guard seen.insert(key).inserted else{continue}
                let nativeLoss=e.nativeCellCenters.filter{contains(old,$0) && !contains(q,$0)}
                let bodyLoss=bodyIndices.filter{contains(old,world($0)) && !contains(q,world($0))}
                let selected=Array(ids).sorted(),foreignDB=selected.reduce(into:Set<Int>()) { result,id in result.formUnion((dbVotes[id] ?? []).filter{!e.detectors[$0].nativeRoot}) }
                let aq=q.map(project),beyond=aq.contains{$0.y<oldA0-mw || $0.y>oldA1+mw}
                let rec:[String:Any]=["family":"repair402-outline-extension","extentChoice":name,"edgeBits":bits,"actualContourContactAdded":includeContact,
                    "actual386Old":old.map{[Double($0.x),Double($0.y)]},"originalOldEdgeDirectionsPreserved":true,"sourceOnlyExpansionNoPadding":true,
                    "nativeAdmissionSuiteRun":false,"associationIsNominationNotOwnership":true,
                    "signedEdgePlaneChanges":(0..<4).map{Double(proposed[$0]-planes[$0])},
                    "sourceSupportComponentIDs":selected,"actualSelectedContactPaths":contactPaths,"edgeActualSupport":extrema.filter{$0>=0}.map(witness),
                    "rootDetectorActualCellAgreement":rootDB,"rootRFTextQueries":Array(rootRF).sorted(),
                    "otherDetectorEvidenceOrdinals":foreignDB.map{e.detectors[$0].ordinal}.sorted(),
                    "newlyExcludedActualNativeCellCenters":nativeLoss.count,"newlyExcludedOriginalGGBodyPixels":bodyLoss.count,
                    "GGBodyLossWitnesses":bodyLoss.prefix(4).map(witness),"nativeCellLossWitnesses":nativeLoss.prefix(4).map{[Double($0.x),Double($0.y)]},
                    "oldPlusNativeWAlongExceeded":beyond,"authenticatedRGBAIsActualCaptureLimit":true,
                    "actual386PriorEnclosed":old.allSatisfy{contains(q,$0)},"completeSourceForegroundPreservationClaimed":false,
                    "sourceNativeOldAndGraphRemainActual386":true,"wholeRFOrDetectorPolygonForced":false,
                    "geometryOrColourIsOwnership":false,"detachedTerminalAndQuoteAssociationRequired":true,
                    "foreignPeerAcquisitionSemanticsUnresolved":true,"erasureAuthority":"none","admissionGranted":false,
                    "unrelatedOpenComponentsVetoAllOffers":false,"existingGT80FloorRequiresParentEvaluation":true]
                var obligations=["actual-native-whole-dense-GG-and-semantic-gates-required","source-terminal-association-unproven",
                    "foreign-peer-new-acquisition-and-separately-retained-box-check-required","no-erasure-authority","partial-observation-not-completeness"]
                if !bodyLoss.isEmpty || !nativeLoss.isEmpty{obligations.append("positive-actual-source-loss-recorded-final-native-verdict-required")}
                offers.append(.init(suffix:"outline402-"+name+"-edges\(bits)",polygon:q,receipt:rec,obligations:obligations));supportUsed.formUnion(ids)
            }
        }
        let support:[[String:Any]]=supportUsed.sorted().map { id in
            let c=components[id]
            return ["componentID":id,"actualLocalRunsYXCount":runs(c.pixels),"actualPixelCount":c.pixels.count,
                "actualRootPrivateBodyAnchors":c.anchors,"originalGGBodyPixels":c.body,"RGB":[c.colour.x,c.colour.y,c.colour.z],
                "projectedActualCellBounds":[Double(c.n0),Double(c.a0),Double(c.n1),Double(c.a1)],
                "positiveSourceContrast":c.contrast.map{$0.map(witness)},"positiveRGBContact":(contactWitness[id] ?? []).map{$0.map(witness)},
                "detectorOrdinals":Array(dbVotes[id] ?? []).map{e.detectors[$0].ordinal}.sorted(),"RFTextQueryIDs":Array(rfVotes[id] ?? []).sorted(),
                "originalRGBCCClippedAtCapture":c.clipped,"sourceOwnershipClaimed":false]
        }
        return .init(proposals:offers,receipt:["family":"repair402-outline-extension","status":offers.isEmpty ? "no-source-supported-outward-change" : "prior-enclosing-observed-outline-recovery",
            "sourceSupportComponents":support,"arbitraryPaddingUsed":false,"sourceOnlyExpansion":true,"sourceTerminalChains":chainReceipts,"originalRGBComponents":components.count,"detachedContrastHypotheses":allPotential.count,"compactFillHypothesesSampled":potential.count,
            "rootAnchoredComponents":roots.count,"actualRGBContactEdges":contactEdges,"clippedUnresolvedComponents":components.filter{$0.clipped}.count,
            "unrelatedOpenComponentsVetoAllOffers":false,"detectorCellQueries":detectorQueries,"detectorSamplingBudgetReached":queryBudgetHit,
            "RFIsGeometricCorroborationOnly":true,"detectorCellsAreActualSparseRuns":true,"wholeRFForced":false,
            "originalOldAxisRetained":true,"captureBoundIsAuthenticatedRGBAInsteadOfOldPlusW":true,
            "candidates":offers.count,"geometryOutsideActualCaptureOrInvalid":rejectedGeometry,
            "budgets":["RGBA":600_000,"components":20_000,"rootComponents":256,"compactFillHypotheses":512,"detectorQueries":2_000_000,"contactEdges":100_000,"contactDepth":3,"chainHops":8,"candidates":8],
            "oldSourceLossThresholdsChanged":false,"actualOld":old.map{[Double($0.x),Double($0.y)]},
            "oldGGBodyPixelsOutsidePrior":bodyIndices.filter{!contains(old,world($0))}.count,
            "oldNativeCellCentersOutsidePrior":e.nativeCellCenters.filter{!contains(old,$0)}.count,"nativeAdmissionSuiteRun":false,"ownershipChanged":false,"admissionGranted":false])
    }
}
