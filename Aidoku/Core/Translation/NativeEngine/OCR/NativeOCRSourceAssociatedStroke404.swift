import Foundation
import CoreGraphics

/// Source-only contraction repair. Caller binds actualOld/RGBA/GG/full-native
/// membership and original RF/DB to the SAME source. No ownership mutation.
/// Final output still requires all original native guards and parent admission.
enum NativeOCRSourceAssociatedStroke404 {
    typealias K = NativeOCRSharedBoundary396
    struct RepairResult { let polygon:[CGPoint]?; let receipt:[String:Any] }
    fileprivate struct Plane { let n:CGPoint; let d:CGFloat }
    private struct Ray { let path:[Int]; let exterior:[Int]; let transition:[Int] }
    private struct Pair { let seed:Int; let low:Ray; let high:Ray; let axis:String }
    private struct Component {
        let pixels:[Int]; let colour:SIMD3<Int>; let roots:[Int]
        let privateCount:Int; let ggCount:Int; let foreignCount:Int; let uncertainCount:Int
        let closed:Bool; let n0:CGFloat; let n1:CGFloat; let a0:CGFloat; let a1:CGFloat
        let perimeter:Int
        var pairs:[Pair]=[]; var db=Set<Int>(); var rf=Set<Int>()
        var rooted:Bool { roots.count>=2 || (privateCount>=2 && ggCount>=2) }
    }
    private static func dot(_ a:CGPoint,_ b:CGPoint)->CGFloat {a.x*b.x+a.y*b.y}
    private static func colourDistance(_ a:SIMD3<Int>,_ b:SIMD3<Int>)->Int {
        max(abs(a.x-b.x),abs(a.y-b.y),abs(a.z-b.z))
    }
    private static func planes(_ q:[CGPoint])->[Plane]? {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return nil}
        let turns=(0..<4).map {i -> CGFloat in
            let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        guard turns.allSatisfy({$0>1e-8}) || turns.allSatisfy({$0 < -1e-8}) else{return nil}
        var out:[Plane]=[]
        for i in 0..<4 {
            let a=q[i],b=q[(i+1)%4],dx=b.x-a.x,dy=b.y-a.y,len=hypot(dx,dy)
            guard len>1e-7 else{return nil}
            let n=turns[0]>0 ? CGPoint(x:dy/len,y:-dx/len):CGPoint(x:-dy/len,y:dx/len)
            out.append(.init(n:n,d:dot(n,a)))
        }
        return out
    }
    private static func inside(_ p:CGPoint,_ planes:[Plane],_ eps:CGFloat=1e-7)->Bool {
        planes.allSatisfy{dot($0.n,p)<=$0.d+eps}
    }
    private static func vertices(_ normals:[Plane],_ d:[CGFloat])->[CGPoint]? {
        var q:[CGPoint]=[]
        for i in 0..<4 {
            let j=(i+3)%4,a=normals[j].n,b=normals[i].n,det=a.x*b.y-a.y*b.x
            guard abs(det)>1e-9 else{return nil}
            q.append(.init(x:(d[j]*b.y-a.y*d[i])/det,y:(a.x*d[i]-d[j]*b.x)/det))
        }
        return planes(q)==nil ? nil:q
    }
    // Intersect an actual unit pixel CELL with old. No outside-old cell corner
    // becomes a new acquisition. Hulls/RF rectangles are never rasterized as ink.
    private static func clippedCell(_ p:CGPoint,_ old:[Plane])->[CGPoint] {
        var poly=[CGPoint(x:p.x-0.5,y:p.y-0.5),CGPoint(x:p.x+0.5,y:p.y-0.5),
                  CGPoint(x:p.x+0.5,y:p.y+0.5),CGPoint(x:p.x-0.5,y:p.y+0.5)]
        for edge in old {
            if poly.isEmpty {break}
            var next:[CGPoint]=[]
            for j in poly.indices {
                let a=poly[j],b=poly[(j+1)%poly.count]
                let da=dot(edge.n,a)-edge.d,db=dot(edge.n,b)-edge.d
                if da<=1e-9 {next.append(a)}
                if (da<0 && db>0) || (da>0 && db<0) {
                    let t=da/(da-db)
                    next.append(.init(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t))
                }
            }
            poly=next
        }
        return poly
    }
    /// Geometry over caller-supplied418-positive ACTUAL pixel centers only.
    /// Retain proposed side angles; enclose old-clipped unit pixel cells by
    /// outward plane updates. This supplies NO acquisition/ownership authority.
    /// Caller MUST409-readmit any resulting expansion through actual native gates.
    static func enclosingMeasuredCells(proposed q:[CGPoint],actualOld old:[CGPoint],
                                       centers:[CGPoint])->[CGPoint]? {
        guard centers.count<=4096,centers.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              let qp=planes(q),let op=planes(old),
              (qp+op).allSatisfy({$0.n.x.isFinite && $0.n.y.isFinite && $0.d.isFinite}) else{return nil}
        if centers.isEmpty {return q}
        var ds=qp.map(\.d)
        for center in centers {
            // Preserve ONLY the real cell's intersection with actualOld. A
            // supplied cell outside old does not grant outside-old pixel rights.
            let corners=clippedCell(center,op)
            for corner in corners {
                guard corner.x.isFinite,corner.y.isFinite else{return nil}
                for edge in 0..<4 {
                    let support=dot(qp[edge].n,corner)
                    guard support.isFinite else{return nil}
                    ds[edge]=max(ds[edge],support)
                }
            }
        }
        if ds==qp.map(\.d) {return q}
        return vertices(qp,ds)
    }
    final class Session {
        private let old:[CGPoint],oldPlanes:[Plane],rgba:K.RGBA
        private let pixels:[Int],ambiguous:[Int],componentAt:[Int],supportAt:[Int]
        private let rayAt:[Int:[Int]]
        private let extrema:[CGFloat],edgePixel:[Int]
        let receipt:[String:Any]
        fileprivate init(old:[CGPoint],planes:[Plane],rgba:K.RGBA,pixels:[Int],ambiguous:[Int],
                         componentAt:[Int],supportAt:[Int],rayAt:[Int:[Int]],receipt:[String:Any]) {
            self.old=old;self.oldPlanes=planes;self.rgba=rgba;self.pixels=pixels
            self.ambiguous=ambiguous;self.componentAt=componentAt;self.supportAt=supportAt;self.receipt=receipt
            self.rayAt=rayAt
            var limits=[CGFloat](repeating:-CGFloat.infinity,count:4),indices=[Int](repeating:-1,count:4)
            for i in pixels {
                let p=CGPoint(x:rgba.origin.x+CGFloat(i%rgba.width)+0.5,y:rgba.origin.y+CGFloat(i/rgba.width)+0.5)
                let cell=NativeOCRSourceAssociatedStroke404.clippedCell(p,planes)
                for edge in 0..<4 {
                    let z=cell.map{NativeOCRSourceAssociatedStroke404.dot(planes[edge].n,$0)}.max() ?? -CGFloat.infinity
                    if z>limits[edge] {limits[edge]=min(planes[edge].d,z);indices[edge]=i}
                }
            }
            self.extrema=limits;self.edgePixel=indices
        }
        private func world(_ i:Int)->CGPoint {
            .init(x:rgba.origin.x+CGFloat(i%rgba.width)+0.5,y:rgba.origin.y+CGFloat(i/rgba.width)+0.5)
        }
        private func proof(_ i:Int)->[String:Any] {
            let p=world(i),k=(i/rgba.width)*rgba.bytesPerRow+(i%rgba.width)*4
            var out:[String:Any]=["actualLocalPixelIndex":i,"componentID":componentAt[i],
                "associationComponentID":supportAt[i],
                "center":[Double(p.x),Double(p.y)],"RGB":(0..<3).map{Int(rgba.bytes[k+$0])},
                "oldClippedActualPixelCell":NativeOCRSourceAssociatedStroke404.clippedCell(p,oldPlanes).map{[Double($0.x),Double($0.y)]}]
            if let path=rayAt[i] {
                out["actualFiniteAARimPathToThreeStableExteriorPixels"]=path.map {j -> [String:Any] in
                    let p=world(j),o=(j/rgba.width)*rgba.bytesPerRow+(j%rgba.width)*4
                    return ["actualLocalPixelIndex":j,"center":[Double(p.x),Double(p.y)],
                        "RGB":(0..<3).map{Int(rgba.bytes[o+$0])}]
                }
            }
            return out
        }
        /// Read-only actual evidence-cell centers for the EXACT unresolved-loss
        /// predicate used by repair. A center can be inside q while part of its
        /// old-clipped pixel cell is lost. No synthetic seed/vertex is returned.
        /// nil: invalid/non-inward candidate or >4096 lost cells; []: no loss.
        /// This does not qualify/erase evidence or bypass any existing404 veto.
        func unresolvedLostPositions(proposed q:[CGPoint])->[CGPoint]? {
            guard let qp=NativeOCRSourceAssociatedStroke404.planes(q),
                  q.allSatisfy({NativeOCRSourceAssociatedStroke404.inside($0,oldPlanes)}) else{return nil}
            var positions:[CGPoint]=[]
            for i in ambiguous {
                if NativeOCRSourceAssociatedStroke404.clippedCell(world(i),oldPlanes).contains(where:{
                    !NativeOCRSourceAssociatedStroke404.inside($0,qp)
                }) {
                    guard positions.count<4096 else{return nil}
                    positions.append(world(i))
                }
            }
            return positions
        }
        /// Actual404 positively associated pixel-cell centers only, including
        /// observed AA/rim. Not a newly assigned ownership or full glyph mask.
        /// Never return a truncated list as if it were complete.
        func protectedAssociatedCellCenters()->[CGPoint]? {
            guard pixels.count<=4096 else{return nil}
            return pixels.map(world)
        }
        func repair(proposed q:[CGPoint])->RepairResult {
            func result(_ polygon:[CGPoint]?,_ status:String,_ extra:[String:Any]=[:])->RepairResult {
                var r=receipt;r["status"]=status;r["admissionGranted"]=false
                r["nativeGuardsMustRerunOnRepairedPolygon"]=true;r["robustIoURequiredByParent"]=true
                r["rawCandidate"]=q.map{[Double($0.x),Double($0.y)]}
                for (k,v) in extra {r[k]=v}
                if let polygon=polygon {r["repairedPolygon"]=polygon.map{[Double($0.x),Double($0.y)]}}
                return .init(polygon:polygon,receipt:r)
            }
            guard let qp=NativeOCRSourceAssociatedStroke404.planes(q) else{return result(nil,"veto-invalid-candidate")}
            guard q.allSatisfy({NativeOCRSourceAssociatedStroke404.inside($0,oldPlanes)}) else {
                return result(nil,"veto-not-inward-old-contraction")
            }
            // Ambiguous native-root evidence is not silently forgotten. Known
            // unrooted foreign peers are excluded during prepare, not enclosed.
            if let i=ambiguous.first(where:{ i in
                NativeOCRSourceAssociatedStroke404.clippedCell(world(i),oldPlanes).contains{
                    !NativeOCRSourceAssociatedStroke404.inside($0,qp)
                }
            }) {return result(nil,"veto-lost-unresolved-source-stroke",["actualEvidence":proof(i)])}
            let parallel=oldPlanes.allSatisfy { old in
                qp.contains {NativeOCRSourceAssociatedStroke404.dot(old.n,$0.n)>1-1e-9}
            }
            if !parallel {
                if let i=pixels.first(where:{ i in
                    NativeOCRSourceAssociatedStroke404.clippedCell(world(i),oldPlanes).contains{
                        !NativeOCRSourceAssociatedStroke404.inside($0,qp)
                    }
                }) {return result(nil,"veto-nonparallel-candidate-loses-associated-stroke",["actualEvidence":proof(i),"rotationInvented":false])}
                return result(q,"unchanged-nonparallel-preserves-associated-strokes",["rotationInvented":false])
            }
            let raw=oldPlanes.map{p in q.map{NativeOCRSourceAssociatedStroke404.dot(p.n,$0)}.max()!}
            var repaired=raw,edges:[[String:Any]]=[]
            for edge in 0..<4 where edgePixel[edge]>=0 && extrema[edge]>raw[edge]+1e-7 {
                repaired[edge]=min(oldPlanes[edge].d,max(raw[edge],extrema[edge]))
                edges.append(["edge":edge,"rawPlane":Double(raw[edge]),"repairedPlane":Double(repaired[edge]),
                    "actualOldPlane":Double(oldPlanes[edge].d),"actualCellExtremum":proof(edgePixel[edge])])
            }
            if edges.isEmpty {return result(q,"unchanged-preserves-associated-strokes",["clampedEdges":edges])}
            guard let fixed=NativeOCRSourceAssociatedStroke404.vertices(oldPlanes,repaired),
                  fixed.allSatisfy({NativeOCRSourceAssociatedStroke404.inside($0,oldPlanes)}),
                  q.allSatisfy({p in (0..<4).allSatisfy{NativeOCRSourceAssociatedStroke404.dot(oldPlanes[$0].n,p)<=repaired[$0]+1e-7}}),
                  (0..<4).allSatisfy({repaired[$0]>=raw[$0]-1e-7 && repaired[$0]<=oldPlanes[$0].d+1e-7}) else {
                return result(nil,"veto-inconsistent-plane-clamp")
            }
            // Independently verify every protected old-clipped actual pixel cell.
            guard let fp=NativeOCRSourceAssociatedStroke404.planes(fixed),pixels.allSatisfy({i in
                NativeOCRSourceAssociatedStroke404.clippedCell(world(i),oldPlanes).allSatisfy{
                    NativeOCRSourceAssociatedStroke404.inside($0,fp)
                }
            }) else{return result(nil,"veto-repaired-cell-containment-failed")}
            return result(fixed,"repaired-parallel-inward-contraction",["clampedEdges":edges,
                "rawCandidateContained":true,"repairedContainedInActualOld":true,
                "outsideOldPixelAcquisition":false,"rotationInvented":false])
        }
    }
    static func prepare(actualOld old:[CGPoint],basis f:K.Basis,nativeW mw:CGFloat,
                        evidence e:K.Evidence,foreignAt:(CGPoint)->Bool,
                        uncertainAt:(CGPoint)->Bool)->Session? {
        let r=e.rgba,w=r.width,h=r.height
        guard let oldPlanes=planes(old),w>2,h>2,w<=600_000/h,w<=Int.max/4,
              r.bytesPerRow>=w*4,r.bytesPerRow<=Int.max/h,r.bytes.count==h*r.bytesPerRow,
              e.body.count==w*h,
              mw.isFinite,mw>0,mw<100_000,
              [r.origin,f.origin,f.normal,f.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              abs(hypot(f.normal.x,f.normal.y)-1)<1e-6,abs(hypot(f.along.x,f.along.y)-1)<1e-6,
              abs(dot(f.normal,f.along))<1e-6,e.detectors.count<=64,e.rf.count<=160,
              e.rf.allSatisfy({$0.bounds.count==4 && $0.bounds.allSatisfy({$0.isFinite}) && $0.confidence.isFinite}) else{return nil}
        func world(_ i:Int)->CGPoint {.init(x:r.origin.x+CGFloat(i%w)+0.5,y:r.origin.y+CGFloat(i/w)+0.5)}
        func rgb(_ i:Int)->SIMD3<Int> {let k=(i/w)*r.bytesPerRow+(i%w)*4;return .init(Int(r.bytes[k]),Int(r.bytes[k+1]),Int(r.bytes[k+2]))}
        func projected(_ p:CGPoint)->CGPoint {let d=CGPoint(x:p.x-f.origin.x,y:p.y-f.origin.y);return .init(x:dot(d,f.normal),y:dot(d,f.along))}
        // All pixel inspection stays in bbox +/-15%, never a page-wide scan.
        let xs=old.map(\.x),ys=old.map(\.y),dx=(xs.max()!-xs.min()!)*0.15,dy=(ys.max()!-ys.min()!)*0.15
        func bounded(_ z:CGFloat,_ limit:Int)->Int {Int(max(0,min(CGFloat(limit),z)))}
        let x0=bounded(floor(xs.min()!-dx-r.origin.x),w),x1=bounded(ceil(xs.max()!+dx-r.origin.x),w)
        let y0=bounded(floor(ys.min()!-dy-r.origin.y),h),y1=bounded(ceil(ys.max()!+dy-r.origin.y),h)
        guard x1>x0+2,y1>y0+2,
              old.allSatisfy({$0.x>=r.origin.x && $0.y>=r.origin.y && $0.x<=r.origin.x+CGFloat(w) && $0.y<=r.origin.y+CGFloat(h)}) else{return nil}
        func index(_ x:Int,_ y:Int)->Int? {x>=x0 && x<x1 && y>=y0 && y<y1 ? y*w+x:nil}
        var label=[Int](repeating:-2,count:w*h),priv=[Bool](repeating:false,count:w*h)
        var foreign=priv,uncertain=priv,oldInside=priv,font:[SIMD3<Int>]=[],fontCounts:[Int]=[]
        for y in y0..<y1 {for x in x0..<x1 {
            let i=y*w+x,k=y*r.bytesPerRow+x*4
            guard r.bytes[k+3]==255 else{continue}
            label[i] = -1;let p=world(i);oldInside[i]=inside(p,oldPlanes)
            priv[i]=e.privateAt(p)
            if oldInside[i] {foreign[i]=foreignAt(p);uncertain[i]=uncertainAt(p)}
            if oldInside[i] && priv[i] && e.body[i] != 0 {
                let c=rgb(i)
                if let j=font.firstIndex(where:{colourDistance($0,c)<=24}) {fontCounts[j]+=1}
                else if font.count<32 {font.append(c);fontCounts.append(1)}
            }
        }}
        font=font.indices.filter{fontCounts[$0]>=2}.map{font[$0]}
        guard !font.isEmpty else{return nil}
        let around=[(-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)]
        let cardinal=[(-1,0),(1,0),(0,-1),(0,1)]
        let nr=(abs(f.normal.x)+abs(f.normal.y))*0.5,ar=(abs(f.along.x)+abs(f.along.y))*0.5
        var cc:[Component]=[]
        for y in y0..<y1 {for x in x0..<x1 {
            let seed=y*w+x
            guard label[seed] == -1 else{continue}
            guard cc.count<20_000 else{return nil}
            let id=cc.count,reference=rgb(seed)
            var pixels=[seed],cursor=0;label[seed]=id
            while cursor<pixels.count {
                let i=pixels[cursor];cursor+=1
                for (dx,dy) in around {
                    guard let j=index(i%w+dx,i/w+dy),label[j] == -1,
                          colourDistance(rgb(j),reference)<=32,colourDistance(rgb(i),rgb(j))<=24 else{continue}
                    label[j]=id;pixels.append(j)
                }
            }
            var roots:[Int]=[],native=0,gg=0,foreignCount=0,uncertainCount=0,closed=true,perimeter=0
            var n0=CGFloat.infinity,n1 = -CGFloat.infinity,a0=CGFloat.infinity,a1 = -CGFloat.infinity
            for i in pixels {
                let v=projected(world(i));n0=min(n0,v.x-nr);n1=max(n1,v.x+nr);a0=min(a0,v.y-ar);a1=max(a1,v.y+ar)
                if oldInside[i] {
                    if priv[i] {native+=1};if e.body[i] != 0 {gg+=1}
                    if priv[i] && e.body[i] != 0 {roots.append(i)}
                    if foreign[i] {foreignCount+=1};if uncertain[i] {uncertainCount+=1}
                }
                for (dx,dy) in cardinal {
                    guard let j=index(i%w+dx,i/w+dy),label[j] != -2 else{closed=false;perimeter+=1;continue}
                    if label[j] != id {perimeter+=1}
                }
            }
            cc.append(.init(pixels:pixels,colour:reference,roots:roots,privateCount:native,ggCount:gg,
                foreignCount:foreignCount,uncertainCount:uncertainCount,closed:closed,
                n0:n0,n1:n1,a0:a0,a1:a1,perimeter:perimeter))
        }}
        // Labels are complete before testing real RGB paths. A boundary is not
        // inferred from a single sharp i->j->k gradient or from a fixed blank color.
        var rayQueries=0,queryExhausted=false
        func sample(_ p:CGPoint)->Int? {
            rayQueries+=1
            if rayQueries>6_000_000 {queryExhausted=true;return nil}
            let x=floor(p.x-r.origin.x),y=floor(p.y-r.origin.y)
            guard x>=CGFloat(x0),x<CGFloat(x1),y>=CGFloat(y0),y<CGFloat(y1),
                  let i=index(Int(x),Int(y)),label[i]>=0 else{return nil}
            return i
        }
        func ray(_ seed:Int,_ direction:CGPoint,_ component:Int)->Ray? {
            let p=world(seed),initial=rgb(seed),limit=min(512,max(12,Int(ceil(mw*1.8))+12))
            var path=[seed],last=seed
            for step in 1...limit {
                guard let i=sample(.init(x:p.x+direction.x*CGFloat(step),y:p.y+direction.y*CGFloat(step))) else{return nil}
                if i==last {continue};last=i;path.append(i)
                guard path.count>=4 else{continue}
                let exterior=Array(path.suffix(3))
                guard exterior.allSatisfy({label[$0] != component && colourDistance(initial,rgb($0))>=40}),
                      colourDistance(rgb(exterior[0]),rgb(exterior[1]))<=18,
                      colourDistance(rgb(exterior[1]),rgb(exterior[2]))<=18,
                      colourDistance(rgb(exterior[0]),rgb(exterior[2]))<=28 else{continue}
                let prefix=Array(path.dropLast(3))
                let transition=prefix.filter{label[$0] != component}
                guard transition.count<=max(8,Int(ceil(mw*0.45))+4) else{continue}
                // One real white-rim overshoot/channel is legal. Small AA noise
                // does not impose a fictitious zero-gradient exterior requirement.
                var finite=true
                for channel in 0..<3 {
                    var sign=0,turns=0
                    let firstOutside=path.firstIndex{label[$0] != component} ?? path.count
                    for k in max(1,firstOutside)..<(path.count-2) {
                        let d=rgb(path[k])[channel]-rgb(path[k-1])[channel]
                        if abs(d)<=10 {continue}
                        let s=d>0 ? 1:-1
                        if sign != 0 && sign != s {turns+=1}
                        sign=s
                    }
                    if turns>1 {finite=false}
                }
                if finite {return .init(path:path,exterior:exterior,transition:transition)}
            }
            return nil
        }
        let oldProjected=old.map(projected),oldN0=oldProjected.map(\.x).min()!,oldN1=oldProjected.map(\.x).max()!
        var candidates:[Int]=[],unresolved=Set<Int>(),rootIDs=Set<Int>()
        for id in cc.indices {
            let c=cc[id]
            let coherent=font.contains{colourDistance($0,c.colour)<=32}
            let inLine=(c.n0+c.n1)*0.5>=oldN0-mw*0.2 && (c.n0+c.n1)*0.5<=oldN1+mw*0.2
            if c.rooted && (!c.closed || c.n1-c.n0>mw*1.7) {
                unresolved.formUnion(c.pixels.filter{oldInside[$0]});continue
            }
            guard c.closed,c.pixels.count>=2,c.pixels.count<=200_000,c.n1-c.n0<=mw*1.7,
                  c.rooted || inLine || coherent else{continue}
            candidates.append(id)
            guard candidates.count<=2048 else{return nil}
            // Distinct actual along positions, near the CC normal midpoint.
            let sorted=c.pixels.sorted {l,r in
                let a=projected(world(l)),b=projected(world(r));return a.y==b.y ? a.x<b.x:a.y<b.y
            }
            var pairs:[Pair]=[],previousA = -CGFloat.infinity
            for k in 0..<min(12,sorted.count) {
                let i=sorted[k*(sorted.count-1)/max(1,min(12,sorted.count)-1)]
                let av=projected(world(i)).y
                if av-previousA<0.75 {continue}
                if let low=ray(i,.init(x:-f.normal.x,y:-f.normal.y),id),let high=ray(i,f.normal,id) {
                    pairs.append(.init(seed:i,low:low,high:high,axis:"normal"));previousA=av
                    if pairs.count==4 {break}
                }
            }
            // A tiny comma may occupy only one along column. Require an actual
            // second-axis closed RGB proof instead of discarding punctuation for
            // lack of two distinct along sample positions. Long strokes still
            // require normal closure at multiple actual along positions.
            if pairs.count==1,c.a1-c.a0<=mw*0.5,c.n1-c.n0<=mw*0.5,
               let seed=pairs.first?.seed,
               let low=ray(seed,.init(x:-f.along.x,y:-f.along.y),id),let high=ray(seed,f.along,id) {
                pairs.append(.init(seed:seed,low:low,high:high,axis:"along-small-punctuation-confirmation"))
            }
            cc[id].pairs=pairs
            if c.rooted {
                if pairs.count>=2 {rootIDs.insert(id)}
                else {unresolved.formUnion(c.pixels.filter{oldInside[$0]})}
            }
        }
        guard !queryExhausted,rootIDs.count<=256,!rootIDs.isEmpty else{return nil}
        let sourceLineN0=rootIDs.map{cc[$0].n0}.min()!,sourceLineN1=rootIDs.map{cc[$0].n1}.max()!
        var detectorQueries=0
        for id in candidates where cc[id].pairs.count>=2 {
            let p=cc[id].pixels,count=min(24,p.count)
            for k in 0..<count {
                let i=p[k*(p.count-1)/max(1,count-1)],point=world(i)
                for (j,d) in e.detectors.enumerated() {
                    detectorQueries+=1;guard detectorQueries<=2_000_000 else{return nil}
                    if d.cells.contains(point) {cc[id].db.insert(j)}
                }
                for rf in e.rf where rf.confidence>=0.4 && rf.contains(point) {cc[id].rf.insert(rf.query)}
            }
            // Root intersection itself must be represented; random CC sampling
            // cannot lose the RF/DB identity of the upper part of a long bar.
            for i in cc[id].roots.prefix(8) {
                let point=world(i)
                for (j,d) in e.detectors.enumerated() {
                    detectorQueries+=1;guard detectorQueries<=2_000_000 else{return nil}
                    if d.cells.contains(point) {cc[id].db.insert(j)}
                }
                for rf in e.rf where rf.confidence>=0.4 && rf.contains(point) {cc[id].rf.insert(rf.query)}
            }
        }
        var reached=rootIDs,reasons:[Int:String]=[:],links:[Int:Int]=[:],graphWork=0
        for id in rootIDs {reasons[id]="actual-native-GG-rooted-RGB-CC-whole-component"}
        // Every new link has positive actual line/color or literal rim evidence.
        // Foreign/uncertain UNROOTED CCs do not inherit borrowed-root privileges.
        for _ in 0..<8 {
            var added:[(Int,Int,String)]=[]
            for id in candidates where !reached.contains(id) && cc[id].pairs.count>=2 {
                let c=cc[id]
                if c.foreignCount>0 || c.uncertainCount>0 {
                    if c.uncertainCount>0 && font.contains(where:{colourDistance($0,c.colour)<=32}) {
                        unresolved.formUnion(c.pixels.filter{oldInside[$0]})
                    }
                    continue
                }
                for parent in reached.sorted() {
                    graphWork+=1;guard graphWork<=2_000_000 else{return nil}
                    let b=cc[parent],gap=max(0,max(c.a0-b.a1,b.a0-c.a1))
                    let sameColour=colourDistance(c.colour,b.colour)<=32
                    let sameRF = !c.rf.intersection(b.rf).isEmpty
                    let sameDB = !c.db.intersection(b.db).isEmpty
                    let line=abs((c.n0+c.n1-b.n0-b.n1)*0.5)<=mw*0.55
                        && c.n0>=sourceLineN0-mw*0.2 && c.n1<=sourceLineN1+mw*0.2
                    if sameColour && line && gap<=mw*(sameRF || sameDB ? 1.25:0.6) {
                        added.append((id,parent,sameDB ? "same-original-DB-actual-pixels-and-font-line" : sameRF ? "same-RF-word-actual-pixels-and-font-line" : "actual-closed-same-font-line-continuation"));break
                    }
                    // Actual short RGB paths may connect finite rim CCs. Never
                    // replace those literal pixels by the RF box or a filled hull.
                    let contacts=b.pairs.reduce(0) {sum,pair in
                        sum+[pair.low,pair.high].filter {ray in (ray.transition+ray.exterior).contains{label[$0]==id}}.count
                    }
                    let rimThin=CGFloat(c.pixels.count)/CGFloat(max(1,c.perimeter))<=max(3,mw*0.25)
                    if contacts>=2 && rimThin && c.n0>=b.n0-mw*0.4 && c.n1<=b.n1+mw*0.4
                        && c.a0>=b.a0-mw*0.4 && c.a1<=b.a1+mw*0.4 {
                        added.append((id,parent,"actual-finite-RGB-rim-path-from-associated-CC"));break
                    }
                }
            }
            if added.isEmpty {break}
            for (id,parent,reason) in added {reached.insert(id);links[id]=parent;reasons[id]=reason}
        }
        var protect=Set<Int>(),records:[[String:Any]]=[],supportAt=label,rayAt:[Int:[Int]]=[:]
        func pixelProof(_ i:Int)->[String:Any] {
            let p=world(i),c=rgb(i)
            return ["actualLocalPixelIndex":i,"center":[Double(p.x),Double(p.y)],"RGB":[c.x,c.y,c.z],
                "GGBody":e.body[i] != 0,"nativeContains":priv[i],"foreignCallback":foreign[i],"uncertainCallback":uncertain[i]]
        }
        func rayProof(_ ray:Ray)->[String:Any] {
            ["actualPath":ray.path.map(pixelProof),"stableContrastingActualExterior":ray.exterior.map(pixelProof),
             "finiteAARimTransition":ray.transition.map(pixelProof),"whiteRimOvershootAllowed":true]
        }
        for id in reached.sorted() {
            let c=cc[id]
            protect.formUnion(c.pixels.filter{oldInside[$0]})
            // All observed AA/rim cells from positive closure paths are retained;
            // stable exterior cells themselves are never promoted as ink.
            for pair in c.pairs {for ray in [pair.low,pair.high] {
                for i in ray.transition where oldInside[i] && !uncertain[i] && (!foreign[i] || (c.rooted && priv[i])) {protect.insert(i);supportAt[i]=id;rayAt[i]=ray.path}
            }}
            // Every real boundary is eligible, not just a handful of closure
            // samples. This retains AA tips on T/corners and long thin tails.
            var aaBoundaryPaths=0
            for i in c.pixels where oldInside[i] {
                for (dx,dy) in cardinal {
                    guard let j=index(i%w+dx,i/w+dy),label[j]>=0,label[j] != id else{continue}
                    if let boundary=ray(i,.init(x:CGFloat(dx),y:CGFloat(dy)),id) {
                        aaBoundaryPaths+=1
                        for p in boundary.transition where oldInside[p] && !uncertain[p]
                            && (!foreign[p] || (c.rooted && priv[p])) {
                            protect.insert(p);supportAt[p]=id;rayAt[p]=boundary.path
                        }
                    }
                }
            }
            var record:[String:Any]=["componentID":id,"reason":reasons[id]!,"actualPixels":c.pixels.count,
                "opaqueClosedRGBCC":c.closed,
                "protectedOldPixelCount":c.pixels.filter{oldInside[$0]}.count,"rootAnchors":c.roots.prefix(8).map(pixelProof),
                "actualPrivatePixels":c.privateCount,"actualGGPixels":c.ggCount,
                "borrowedForeignPixelsRetainedOnlyForRootedCC":c.rooted ? c.foreignCount:0,
                "rootedUncertainCallbackPixels":c.rooted ? c.uncertainCount:0,
                "normalSpan":Double(c.n1-c.n0),"alongSpan":Double(c.a1-c.a0),"glyphHeightCapApplied":false,
                "verifiedFiniteAABoundaryPaths":aaBoundaryPaths,
                "actualDBDetectorIndices":c.db.sorted(),"actualRFQueries":c.rf.sorted(),
                "pairedNormalClosure":c.pairs.map{["axis":$0.axis,"seed":pixelProof($0.seed),"low":rayProof($0.low),"high":rayProof($0.high)] as [String:Any]}]
            if let parent=links[id] {record["fromComponentID"]=parent}
            records.append(record)
        }
        // A positively associated component takes priority over an unresolved
        // fragment nomination of the very same actual pixel.
        unresolved.subtract(protect)
        guard !queryExhausted,!protect.isEmpty else{return nil}
        let receipt:[String:Any]=["family":"source-associated-stroke404","status":"prepared",
            "actualOld":old.map{[Double($0.x),Double($0.y)]},"nativeW":Double(mw),
            "localPixelROI":[x0,y0,x1,y1],"rgbaOrigin":[Double(r.origin.x),Double(r.origin.y)],
            "rgbaWidth":w,"rgbaHeight":h,"rootComponentCount":rootIDs.count,
            "actualRootLineNormalBounds":[Double(sourceLineN0),Double(sourceLineN1)],
            "associatedComponentCount":reached.count,"protectedActualOldPixels":protect.count,
            "unresolvedSourcePixels":unresolved.count,"components":records,
            "excludedUnrootedForeignComponents":candidates.filter{!reached.contains($0) && cc[$0].foreignCount>0}.count,
            "unresolvedUnrootedPeerComponents":candidates.filter{!reached.contains($0) && cc[$0].uncertainCount>0}.count,
            "RGBRayQueries":rayQueries,"detectorQueries":detectorQueries,"associationQueries":graphWork,
            "RFRectangleForcedAsInk":false,"hullFilledAsInk":false,"ownershipChanged":false,
            "outsideOldPixelAcquisition":false,"admissionGranted":false]
        return Session(old:old,planes:oldPlanes,rgba:r,pixels:protect.sorted(),ambiguous:unresolved.sorted(),
                       componentAt:label,supportAt:supportAt,rayAt:rayAt,receipt:receipt)
    }
}
