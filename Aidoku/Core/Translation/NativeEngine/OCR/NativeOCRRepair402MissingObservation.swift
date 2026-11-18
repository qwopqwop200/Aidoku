import Foundation
import CoreGraphics

/// Alternate source ROLE observations and strictly enclosing expansion. No private body is fabricated.
enum NativeOCRRepair402MissingObservation {
    typealias S = NativeOCRSharedBoundary396
    private struct CC {
        let pixels:[Int];let colour:SIMD3<Int>;let n0:CGFloat;let n1:CGFloat;let a0:CGFloat;let a1:CGFloat
        let anchors:Int;let db:Set<Int>;let rf:Set<Int>;let contrast:[[Int]]
    }
    static func generate(actualOld old:[CGPoint],basis f:S.Basis,nativeW W:CGFloat,evidence e:S.Evidence)->S.Output {
        func none(_ why:String)->S.Output {.init(proposals:[],receipt:["family":"repair402-missing-observation",
            "status":why,"nativePrivateObservationFabricated":false,"admissionGranted":false])}
        let r=e.rgba,w=r.width,h=r.height
        guard valid(old),W.isFinite,W>=3,w>2,h>2,w<=600000/h,w<=Int.max/4,
              r.bytesPerRow>=w*4,h<=Int.max/r.bytesPerRow,r.bytes.count==h*r.bytesPerRow,
              [r.origin,f.origin,f.normal,f.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              abs(hypot(f.normal.x,f.normal.y)-1)<1e-6,abs(hypot(f.along.x,f.along.y)-1)<1e-6,
              abs(f.normal.x*f.along.x+f.normal.y*f.along.y)<1e-6,e.detectors.count<=256,e.rf.count<=256,
              (e.body.isEmpty || e.body.count==w*h) else{return none("invalid-source-local-session")}
        let roi=CGRect(x:r.origin.x,y:r.origin.y,width:CGFloat(w),height:CGFloat(h))
        guard old.allSatisfy({roi.contains($0)}) else{return none("actual-old-not-covered-by-source-ROI")}
        func world(_ i:Int)->CGPoint {.init(x:r.origin.x+CGFloat(i%w)+0.5,y:r.origin.y+CGFloat(i/w)+0.5)}
        func project(_ p:CGPoint)->CGPoint {let x=p.x-f.origin.x,y=p.y-f.origin.y;return .init(x:x*f.normal.x+y*f.normal.y,y:x*f.along.x+y*f.along.y)}
        func at(_ i:Int)->Int {(i/w)*r.bytesPerRow+(i%w)*4}
        func rgb(_ i:Int)->SIMD3<Int> {let j=at(i);return .init(Int(r.bytes[j]),Int(r.bytes[j+1]),Int(r.bytes[j+2]))}
        func distance(_ a:SIMD3<Int>,_ b:SIMD3<Int>)->Int {max(abs(a.x-b.x),abs(a.y-b.y),abs(a.z-b.z))}
        let oldP=old.map(project),on0=oldP.map(\.x).min()!,on1=oldP.map(\.x).max()!,oa0=oldP.map(\.y).min()!,oa1=oldP.map(\.y).max()!
        let nr=(abs(f.normal.x)+abs(f.normal.y))*0.5,ar=(abs(f.along.x)+abs(f.along.y))*0.5
        var labels=[Int](repeating:-1,count:w*h)
        for i in labels.indices where r.bytes[at(i)+3] != 255 {labels[i] = -2}
        let dirs=[(-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)]
        let card=[(-1,0),(1,0),(0,-1),(0,1)]
        var components:[CC]=[],enumerated=0,open=0,overscale=0,queries=0
        for start in labels.indices where labels[start] == -1 {
            enumerated+=1
            if enumerated>30000 {return none("source-RGB-component-budget-unavailable")}
            let reference=rgb(start);var queue=[start],cursor=0;labels[start]=enumerated
            while cursor<queue.count {
                let i=queue[cursor];cursor+=1
                for (dx,dy) in dirs {
                    let x=i%w+dx,y=i/w+dy
                    if x>=0,y>=0,x<w,y<h {let j=y*w+x
                        if labels[j] == -1,distance(rgb(j),reference)<=32,distance(rgb(j),rgb(i))<=24 {
                            labels[j]=enumerated;queue.append(j)
                        }
                    }
                }
            }
            if queue.count<4 {continue}
            let xs=queue.map{$0%w},ys=queue.map{$0/w}
            if xs.min()==0 || ys.min()==0 || xs.max()==w-1 || ys.max()==h-1 {open+=1;continue}
            let pp=queue.map{project(world($0))}
            let n0=pp.map(\.x).min()!-nr,n1=pp.map(\.x).max()!+nr,a0=pp.map(\.y).min()!-ar,a1=pp.map(\.y).max()!+ar
            if n1-n0>2.5*W || a1-a0>3*W {overscale+=1;continue}
            // Source query already bounds along reach. Do not drop the second/third
            // real exterior glyph solely because its centre lies more than one W past old.
            if n1<on0-W || n0>on1+W {continue}
            // Literal original-pixel fill->contrast->stable-neighbour triples; zero gradient is never blank proof.
            var triples:[[Int]]=[]
            for i in queue {
                for (dx,dy) in card {
                    let x=i%w+dx,y=i/w+dy,xx=i%w+2*dx,yy=i/w+2*dy
                    guard x>=0,y>=0,x<w,y<h,xx>=0,yy>=0,xx<w,yy<h else{continue}
                    let j=y*w+x,k=yy*w+xx
                    if labels[j] != -2,labels[k] != -2,distance(rgb(i),rgb(j))>=24,distance(rgb(j),rgb(k))<=16 {
                        triples.append([i,j,k]);if triples.count>=12 {break}
                    }
                }
                if triples.count>=12 {break}
            }
            guard triples.count>=3 else{continue}
            var db=Set<Int>(),rf=Set<Int>(),anchors=0
            // Bounded sampled original detector/RF observations. NativeRoot=false is NOT foreign/private truth.
            for i in queue.enumerated().filter({$0.offset % max(1,queue.count/32)==0}).prefix(32).map(\.element) {
                let p=world(i);var dbHere=false,rfHere=false
                for d in e.detectors {
                    queries+=1;if queries>2000000 {return none("original-detector-query-budget-unavailable")}
                    if d.cells.contains(p) {db.insert(d.ordinal);dbHere=true}
                }
                for q in e.rf where q.bounds.count==4 && q.bounds.allSatisfy(\.isFinite) && q.confidence.isFinite && q.confidence>0 && q.contains(p) {
                    rf.insert(q.query);rfHere=true
                }
                let bodyHere = !e.body.isEmpty && e.body[i] != 0
                if S.contains(old,p) && (bodyHere || (dbHere && rfHere)) {anchors+=1}
            }
            guard !db.isEmpty || !rf.isEmpty else{continue}
            guard components.count<2048 else{return none("qualified-source-observation-budget-unavailable")}
            components.append(.init(pixels:queue,colour:reference,n0:n0,n1:n1,a0:a0,a1:a1,
                anchors:anchors,db:db,rf:rf,contrast:triples))
        }
        var chosen=Set(components.indices.filter{components[$0].anchors>=2})
        guard !chosen.isEmpty else{return none("no-positive-original-detector-RF-contrast-anchor")}
        // Closed same-column glyph continuation, with real detector or shared RF witnesses.
        // Three bounded passes allow detached punctuation/terminals without changing ownership.
        for _ in 0..<3 {
            let previous=chosen
            for i in components.indices where !chosen.contains(i) {
                let c=components[i]
                if previous.contains(where:{ j in
                    let p=components[j],overlap=min(c.n1,p.n1)-max(c.n0,p.n0)
                    let gap=max(0,max(c.a0-p.a1,p.a0-c.a1))
                    let sameEvidence = !c.db.intersection(p.db).isEmpty || !c.rf.intersection(p.rf).isEmpty
                    return sameEvidence && distance(c.colour,p.colour)<=32 && gap<=W &&
                        overlap>=0.35*min(c.n1-c.n0,p.n1-p.n0) && abs((c.n0+c.n1-p.n0-p.n1)*0.5)<=0.65*W
                }) {chosen.insert(i)}
            }
            if chosen==previous {break}
        }
        var selectedPixels=Set<Int>()
        for i in chosen {selectedPixels.formUnion(components[i].pixels)}
        let pp=selectedPixels.map{project(world($0))}
        let n0=min(on0,pp.map(\.x).min()!-nr),n1=max(on1,pp.map(\.x).max()!+nr)
        let a0=min(oa0,pp.map(\.y).min()!-ar),a1=max(oa1,pp.map(\.y).max()!+ar)
        let bounds:[(String,CGFloat,CGFloat,CGFloat,CGFloat)]=[
            ("normal-low",n0,on1,oa0,oa1),("normal-high",on0,n1,oa0,oa1),
            ("head",on0,on1,a0,oa1),("tail",on0,on1,oa0,a1),("all-observed",n0,n1,a0,a1)]
        var proposals:[S.Proposal]=[]
        for (suffix,l,rn,t,b) in bounds {
            let changed=l<on0-1e-6 || rn>on1+1e-6 || t<oa0-1e-6 || b>oa1+1e-6
            if !changed {continue}
            func restore(_ n:CGFloat,_ a:CGFloat)->CGPoint {.init(x:f.origin.x+n*f.normal.x+a*f.along.x,y:f.origin.y+n*f.normal.y+a*f.along.y)}
            let epsilon:CGFloat=1e-6
            let q=[restore(l-epsilon,t-epsilon),restore(rn+epsilon,t-epsilon),restore(rn+epsilon,b+epsilon),restore(l-epsilon,b+epsilon)]
            guard valid(q),old.allSatisfy({strictContains(q,$0)}),q.allSatisfy({roi.insetBy(dx:1,dy:1).contains($0)}) else{continue}
            let witness=chosen.sorted().prefix(12).map { i -> [String:Any] in
                let c=components[i]
                return ["observedCC":i,"pixels":c.pixels.count,"RGB":[c.colour.x,c.colour.y,c.colour.z],
                    "originalDetectorOrdinals":c.db.sorted(),"RFQueries":c.rf.sorted(),
                    "actualContrastPixelTriples":c.contrast.map {triple in triple.map {j -> [String:Any] in
                        let p=world(j),v=rgb(j);return ["localPixel":j,"world":[Double(p.x),Double(p.y)],"RGB":[v.x,v.y,v.z]]
                    }}]
            }
            proposals.append(.init(suffix:"missing402-enclosing-"+suffix,polygon:q,
                receipt:["actualOldEnclosed":true,"proof":"all-old-convex-vertices-inside-new-convex-quad",
                    "actualObservedSourcePixels":selectedPixels.count,"witnesses":witness,
                    "nativeBodyAvailable":!e.body.isEmpty,"nonexclusiveRLEIsOwnership":false,
                    "privateObservationFabricated":false,"admissionGranted":false],
                obligations:["actual-current-graph-caps-and-inherited-support","known-foreign-and-uncertain-cell-gates",
                    "actual-peer-contrast-and-body-gates","actual-root-member-semantic-gates"]))
        }
        return .init(proposals:proposals,receipt:["family":"repair402-missing-observation",
            "status":proposals.isEmpty ? "no-covered-enclosing-change":"enclosing-source-observations",
            "sourceComponentsEnumeratedOnce":enumerated,"qualifiedComponents":components.count,
            "selectedComponents":chosen.count,"openUnresolved":open,"overscaleUnresolved":overscale,
            "detectorQueries":queries,"nativeBodyAvailable":!e.body.isEmpty,
            "oldSourcePixelsCannotBeExcludedByEnclosure":true,"admissionGranted":false])
    }
    static func valid(_ q:[CGPoint])->Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return false}
        let c=(0..<4).map{i -> CGFloat in let a=q[i],b=q[(i+1)%4],d=q[(i+2)%4];return (b.x-a.x)*(d.y-b.y)-(b.y-a.y)*(d.x-b.x)}
        return c.allSatisfy{$0>1e-8} || c.allSatisfy{$0 < -1e-8}
    }
    static func strictContains(_ q:[CGPoint],_ p:CGPoint)->Bool {
        guard valid(q),p.x.isFinite,p.y.isFinite else{return false}
        let c=(0..<4).map{i -> CGFloat in let a=q[i],b=q[(i+1)%4];return (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)}
        return c.allSatisfy{$0>=0} || c.allSatisfy{$0<=0}
    }
}
